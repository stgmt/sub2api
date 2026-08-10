from __future__ import annotations

import json
import os
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SKILL_ROOT = ROOT / "backend" / "docs" / "skills" / "sub2api-claude-code-codex"
HOOK = SKILL_ROOT / "scripts" / "claude-stream-recovery.mjs"
SETUP = SKILL_ROOT / "scripts" / "setup-sub2api-claude-code.ps1"
INSTALL_PS1 = SKILL_ROOT / "scripts" / "install-claude-stream-recovery.ps1"
VERIFY = SKILL_ROOT / "scripts" / "verify-claude-code-sub2api.ps1"
LIVE_PROOF = SKILL_ROOT / "scripts" / "prove-claude-stream-recovery.ps1"
FAULT_UPSTREAM = SKILL_ROOT / "scripts" / "synthetic-anthropic-stream-fault.py"


class _RecoveryHandler(BaseHTTPRequestHandler):
    response_payload = {
        "pending": True,
        "request_id": "request-hook",
        "failure_count": 1,
        "max_attempts": 3,
    }
    received: dict | None = None

    def do_POST(self) -> None:  # noqa: N802
        size = int(self.headers.get("content-length", "0"))
        type(self).received = json.loads(self.rfile.read(size))
        payload = json.dumps(type(self).response_payload).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, _format: str, *_args) -> None:
        return


def _run_hook(payload: dict, endpoint: str) -> dict:
    env = os.environ.copy()
    env["HEADROOM_CLAUDE_RECOVERY_URL"] = endpoint
    result = subprocess.run(
        ["node", str(HOOK)],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        check=True,
        env=env,
        timeout=10,
    )
    return json.loads(result.stdout)


def test_stop_hook_blocks_once_and_preserves_session_identity():
    server = ThreadingHTTPServer(("127.0.0.1", 0), _RecoveryHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        endpoint = f"http://127.0.0.1:{server.server_port}/consume"
        output = _run_hook(
            {
                "hook_event_name": "Stop",
                "session_id": "session-hook",
                "stop_hook_active": False,
            },
            endpoint,
        )
    finally:
        server.shutdown()
        server.server_close()

    assert output["decision"] == "block"
    assert "same session" in output["reason"]
    assert "do not repeat completed actions" in output["reason"]
    assert _RecoveryHandler.received == {
        "session_id": "session-hook",
        "agent_id": "main",
    }


def test_subagent_stop_hook_uses_agent_id_and_allows_when_no_marker():
    _RecoveryHandler.response_payload = {"pending": False}
    server = ThreadingHTTPServer(("127.0.0.1", 0), _RecoveryHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        endpoint = f"http://127.0.0.1:{server.server_port}/consume"
        output = _run_hook(
            {
                "hook_event_name": "SubagentStop",
                "session_id": "session-hook",
                "agent_id": "agent-9",
                "stop_hook_active": True,
            },
            endpoint,
        )
    finally:
        server.shutdown()
        server.server_close()
        _RecoveryHandler.response_payload = {
            "pending": True,
            "request_id": "request-hook",
            "failure_count": 1,
            "max_attempts": 3,
        }

    assert output == {}
    assert _RecoveryHandler.received == {
        "session_id": "session-hook",
        "agent_id": "agent-9",
    }


def test_setup_owns_recovery_env_and_installer():
    setup = SETUP.read_text(encoding="utf-8")
    compose = (Path(__file__).with_name("docker-compose.yml")).read_text(encoding="utf-8")
    verifier = VERIFY.read_text(encoding="utf-8")

    assert 'Join-Path $PSScriptRoot "install-claude-stream-recovery.ps1"' in setup
    assert '"HEADROOM_CLAUDE_STREAM_RECOVERY"' in setup
    assert "HEADROOM_CLAUDE_STREAM_RECOVERY" in compose
    assert "HEADROOM_CLAUDE_STREAM_RECOVERY_MAX_ATTEMPTS" in compose
    assert "Test-ClaudeStreamRecoveryHook" in verifier
    assert "Test-HeadroomClaudeStreamRecoveryProfile" in verifier


def test_live_proof_contract_covers_same_session_continuation():
    proof = LIVE_PROOF.read_text(encoding="utf-8")
    upstream = FAULT_UPSTREAM.read_text(encoding="utf-8")

    for field in (
        "claude_exit",
        "upstream_requests",
        "unique_session_ids",
        "first_part_seen",
        "second_pass_seen",
    ):
        assert field in proof
    assert '$requestCount -ne 2' in proof
    assert '$sessionIds.Count -ne 1' in proof
    assert 'Contains("FIRST_PART")' in proof
    assert 'Contains("SECOND_PASS")' in proof
    assert '"FIRST_PART" if request_index == 1 else "SECOND_PASS"' in upstream
    assert "if request_index > 1:" in upstream
    assert '"message_stop"' in upstream


def test_powershell_installer_is_idempotent_and_preserves_unrelated_hooks(tmp_path: Path):
    claude_home = tmp_path / ".claude"
    claude_home.mkdir()
    settings_path = claude_home / "settings.json"
    settings_path.write_text(
        json.dumps(
            {
                "hooks": {
                    "Stop": [
                        {
                            "hooks": [
                                {
                                    "type": "command",
                                    "command": "node unrelated-stop.mjs",
                                    "timeout": 7,
                                }
                            ]
                        }
                    ]
                }
            }
        ),
        encoding="utf-8",
    )

    for _ in range(2):
        subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(INSTALL_PS1),
                "-ClaudeHome",
                str(claude_home),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )

    settings = json.loads(settings_path.read_text(encoding="utf-8"))
    stop_json = json.dumps(settings["hooks"]["Stop"])
    subagent_stop_json = json.dumps(settings["hooks"]["SubagentStop"])
    assert stop_json.count("claude-stream-recovery.mjs") == 1
    assert subagent_stop_json.count("claude-stream-recovery.mjs") == 1
    assert "unrelated-stop.mjs" in stop_json
    assert (claude_home / "hooks" / "claude-stream-recovery.mjs").is_file()

import json
import os
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parent
SKILL_ROOT = (
    ROOT / "../../backend/docs/skills/sub2api-claude-code-codex"
).resolve()


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_compose_shares_host_rtk_history_with_headroom() -> None:
    compose = read(ROOT / "docker-compose.yml")

    assert (
        "${HEADROOM_RTK_STATE_ROOT:-./data/rtk}:/root/.local/share/rtk"
        in compose
    )


def test_setup_installs_host_and_wsl_rtk_and_persists_state_path() -> None:
    setup = read(SKILL_ROOT / "scripts/setup-sub2api-claude-code.ps1")

    assert '[string]$RtkVersion = "v0.42.4"' in setup
    assert '[string]$RtkStateRoot = ""' in setup
    assert '[switch]$SkipRtk' in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_RTK_WIRING" "enabled"' in setup
    assert 'Set-DotEnvValue $envMap "HEADROOM_RTK_STATE_ROOT" $composeRtkStateRoot' in setup
    assert 'Join-Path $PSScriptRoot "install-claude-rtk.ps1"' in setup
    assert '& $rtkInstaller -Version $RtkVersion -WslDistro $WslDistro' in setup


def test_hook_bridge_is_msys_safe_and_probed_through_git_bash() -> None:
    installer = read(SKILL_ROOT / "scripts/install-claude-rtk.ps1")
    verifier = read(SKILL_ROOT / "scripts/verify-claude-code-sub2api.ps1")

    for script in (installer, verifier):
        assert "MSYS2_ARG_CONV_EXCL" in script
        assert "Git\\bin\\bash.exe" in script
        assert "Invoke-GitBashUtf8Stdin" in script
        assert "[Convert]::ToBase64String" in script
        assert "| base64 -d |" in script
        assert "$payload | & $gitBash" not in script

    assert "MSYS2_ARG_CONV_EXCL='*'" in installer
    assert "-Command $command -InputText $payload" in installer
    assert "$hookExitCode = $probe.ExitCode" in installer
    assert "-InputText $payload" in verifier
    assert '$ErrorActionPreference = "Continue"' in verifier
    assert "$rtkProbeExitCode = $LASTEXITCODE" in verifier


def test_accuracy_exclusions_and_live_gain_checks_are_durable() -> None:
    installer = read(SKILL_ROOT / "scripts/install-claude-rtk.ps1")
    verifier = read(SKILL_ROOT / "scripts/verify-claude-code-sub2api.ps1")

    for command in ("cat", "git diff", "git show", "curl"):
        assert f'"{command}"' in installer
        assert f'"{command}"' in verifier

    assert "init --global --auto-patch" in installer
    assert "rtk gain --format json" in installer
    assert "Test-HeadroomRtkSharedState" in verifier
    assert 'Assert-DockerBindMount -Container "headroom-sub2api" -Destinations @("/root/.local/share/rtk")' in verifier


def test_native_linux_installer_keeps_the_same_rtk_contract() -> None:
    installer = read(SKILL_ROOT / "scripts/install-claude-rtk.sh")

    assert "v0.42.4" in installer
    assert ".bak-rtk-linux-" in installer
    assert '"matcher": "Bash"' in installer
    assert 'f"{target} hook claude"' in installer
    assert "Expected one RTK hook" in installer
    assert "RTK_BINARY_SOURCE" in installer
    assert "rtk-linux-install-probe" in installer
    for command in ("cat", "git diff", "git show", "curl"):
        assert f'"{command}"' in installer


@pytest.mark.skipif(os.name == "nt", reason="runs in Linux CI; live Hyper-V VM covers Windows development")
def test_native_linux_installer_is_idempotent_and_preserves_claude_settings(
    tmp_path: Path,
) -> None:
    installer = SKILL_ROOT / "scripts/install-claude-rtk.sh"
    home = tmp_path / "home"
    claude_dir = home / ".claude"
    claude_dir.mkdir(parents=True)
    settings_path = claude_dir / "settings.json"
    settings_path.write_text(
        json.dumps(
            {
                "env": {"PRESERVE_ME": "yes"},
                "hooks": {
                    "PreToolUse": [
                        {
                            "matcher": "Bash",
                            "hooks": [{"type": "command", "command": "echo keep"}],
                        },
                        {
                            "matcher": "Bash",
                            "hooks": [{"type": "command", "command": "rtk hook claude"}],
                        },
                        {
                            "matcher": "Bash",
                            "hooks": [
                                {"type": "command", "command": "/old/rtk hook claude"}
                            ],
                        },
                    ]
                },
            }
        ),
        encoding="utf-8",
    )

    fake_rtk = tmp_path / "fake-rtk"
    fake_rtk.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version)
    echo 'rtk 0.42.4'
    ;;
  init)
    mkdir -p "$HOME/.claude"
    printf '# RTK test instructions\n' > "$HOME/.claude/RTK.md"
    touch "$HOME/.claude/CLAUDE.md"
    grep -Fqx '@RTK.md' "$HOME/.claude/CLAUDE.md" || printf '@RTK.md\n' >> "$HOME/.claude/CLAUDE.md"
    ;;
  hook)
    python3 -c 'import json,sys; p=json.load(sys.stdin); c=p["tool_input"]["command"]; excluded=("cat", "git diff", "git show", "curl"); print(json.dumps({"hookSpecificOutput":{"updatedInput":{"command":"rtk "+c}}})) if c.startswith("git ") and not c.startswith(excluded) else None'
    ;;
  *)
    exit 2
    ;;
esac
""",
        encoding="utf-8",
    )
    fake_rtk.chmod(0o755)

    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "RTK_BINARY_SOURCE": str(fake_rtk),
            "RTK_INSTALL_DIR": str(home / ".local" / "bin"),
        }
    )
    first = subprocess.run(
        ["bash", str(installer)], env=env, text=True, capture_output=True, check=True
    )
    second = subprocess.run(
        ["bash", str(installer)], env=env, text=True, capture_output=True, check=True
    )

    assert "RTK Linux host install OK" in first.stdout
    assert "RTK Linux host install OK" in second.stdout
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
    assert settings["env"] == {"PRESERVE_ME": "yes"}
    entries = settings["hooks"]["PreToolUse"]
    commands = [hook["command"] for entry in entries for hook in entry["hooks"]]
    assert "echo keep" in commands
    assert sum("rtk hook claude" in command for command in commands) == 1
    assert str(home / ".local" / "bin" / "rtk") in commands[-1]
    assert (home / ".profile").read_text(encoding="utf-8").count("# sub2api-rtk-path") == 1
    assert (home / ".bashrc").read_text(encoding="utf-8").count("# sub2api-rtk-path") == 1
    config = (home / ".config" / "rtk" / "config.toml").read_text(encoding="utf-8")
    assert 'exclude_commands = ["cat", "git diff", "git show", "curl"]' in config
    rtk_md = (home / ".claude" / "RTK.md").read_text(encoding="utf-8")
    assert rtk_md.count("<!-- sub2api:rtk-profile -->") == 1

from __future__ import annotations

import importlib.util
from pathlib import Path


SCRIPT = (
    Path(__file__).resolve().parents[2]
    / "backend/docs/skills/sub2api-claude-code-codex/scripts/wait_sub2api_idle.py"
)
SPEC = importlib.util.spec_from_file_location("wait_sub2api_idle", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def event(request_id: str, name: str) -> str:
    return f'2026-08-13T22:00:00Z INFO {name} {{"request_id":"{request_id}"}}'


def test_tracks_interleaved_requests_until_every_completion() -> None:
    active: set[str] = set()

    MODULE.update_active(active, event("hr_1_000001", "content_moderation.gateway_check_start"))
    MODULE.update_active(active, event("hr_2_000002", "content_moderation.gateway_check_start"))
    MODULE.update_active(active, event("hr_1_000001", "http request completed"))
    assert active == {"hr_2_000002"}

    MODULE.update_active(active, event("hr_2_000002", "http request completed"))
    assert active == set()


def test_ignores_unrelated_and_nonterminal_stream_events() -> None:
    active: set[str] = set()
    MODULE.update_active(active, event("hr_3_000003", "content_moderation.gateway_check_start"))
    MODULE.update_active(active, event("hr_3_000003", "response.in_progress"))
    MODULE.update_active(active, "health check without request id")
    assert active == {"hr_3_000003"}

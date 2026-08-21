"""Patch headroom-ai 0.31.0: inject Codex-shaped session headers upstream.

Real Codex CLI always sends UUID-formatted ``session_id`` and
``conversation_id`` headers with every /responses call. Claude Code does not
send either header, so proxied traffic reached chatgpt.com without them — an
observable fingerprint that the request did not originate from the CLI.

This downstream image patch makes the Anthropic messages handler derive stable
per-conversation session headers from Claude Code's own
``x-claude-code-session-id`` (a real UUIDv4 minted on the user's machine) and
inject them into the upstream-bound header set:

* only fires when neither ``session_id`` nor ``conversation_id`` is present,
  so explicit client values always win;
* only accepts canonical lowercase UUIDs (v1-v7 shapes), never fabricates a
  value when the client did not provide one;
* sub2api re-isolates these per API key downstream while preserving the UUID
  shape, so cross-user isolation semantics are unchanged.
"""

from __future__ import annotations

from pathlib import Path
import py_compile

import headroom


SESSION_HELPER_SENTINEL = "# sub2api downstream Codex session-header helper patch"
SESSION_CALL_SENTINEL = "# sub2api downstream Codex session-header inject patch"

_HELPER_SOURCE = '''
# sub2api downstream Codex session-header helper patch
_CODEX_SESSION_UUID_RE = __import__("re").compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-7][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
)


def _inject_codex_session_headers(headers: dict, request) -> None:
    """Inject Codex-shaped session_id/conversation_id upstream headers.

    Real Codex CLI always sends UUID-formatted session/conversation ids.
    Claude Code does not send them; derive stable per-conversation values from
    its own x-claude-code-session-id so proxied traffic carries the same
    header shape as native Codex sessions. Never invents a value when the
    client provided nothing, and never overrides explicit client headers.
    """
    if "session_id" in headers or "conversation_id" in headers:
        return
    raw = str(request.headers.get("x-claude-code-session-id") or "").strip().lower()
    if not _CODEX_SESSION_UUID_RE.fullmatch(raw):
        return
    headers["session_id"] = raw
    headers["conversation_id"] = raw

'''

_MESSAGES_ANCHOR = '''            headers = _strip_internal_headers(headers)
            log_outbound_headers(
                forwarder="anthropic_messages",
                stripped_count=_pre_strip_count
                - sum(1 for k in headers if k.lower().startswith("x-headroom-")),
                request_id=request_id,
            )
'''

_MESSAGES_REPLACEMENT = _MESSAGES_ANCHOR + f'''            {SESSION_CALL_SENTINEL}
            _inject_codex_session_headers(headers, request)
'''

_HELPER_ANCHOR = 'def _headroom_session_header_from_request(request: Any) -> str | None:'


def _replace_once(text: str, old: str, new: str, path: Path) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"expected exactly one match in {path}: {old!r}, got {count}")
    return text.replace(old, new, 1)


def patch_anthropic(base: Path) -> None:
    path = base / "proxy" / "handlers" / "anthropic.py"
    text = path.read_text(encoding="utf-8")

    if SESSION_HELPER_SENTINEL not in text:
        text = _replace_once(
            text,
            _HELPER_ANCHOR,
            _HELPER_SOURCE + "\n" + _HELPER_ANCHOR,
            path,
        )

    if SESSION_CALL_SENTINEL not in text:
        text = _replace_once(text, _MESSAGES_ANCHOR, _MESSAGES_REPLACEMENT, path)

    path.write_text(text, encoding="utf-8")
    py_compile.compile(str(path), doraise=True)
    print(f"[patch-headroom-codex-session-headers] patched {path}")


def main() -> None:
    base = Path(headroom.__file__).resolve().parent
    patch_anthropic(base)


if __name__ == "__main__":
    main()

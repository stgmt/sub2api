"""Runtime verification of the Codex session-header patch (run inside container)."""
from headroom.proxy.handlers.anthropic import _inject_codex_session_headers


class FakeRequest:
    def __init__(self, headers):
        self.headers = headers


# 1. Real UUIDv7 from user's PC (Codex session) -> injected
r1 = FakeRequest({"x-claude-code-session-id": "01a02425-d4fa-7f93-804a-d0a0935561a0"})
h1 = {}
_inject_codex_session_headers(h1, r1)
assert h1 == {
    "session_id": "01a02425-d4fa-7f93-804a-d0a0935561a0",
    "conversation_id": "01a02425-d4fa-7f93-804a-d0a0935561a0",
}, h1
print("OK v7 injected:", h1["session_id"])

# 2. Real UUIDv4 from user's PC (Claude Code session) -> injected, lowercased
r2 = FakeRequest({"x-claude-code-session-id": "4C5FC92E-AA59-49AF-B630-E4BF891E2499"})
h2 = {}
_inject_codex_session_headers(h2, r2)
assert h2["session_id"] == "4c5fc92e-aa59-49af-b630-e4bf891e2499", h2
print("OK v4 injected+lowercased:", h2["session_id"])

# 3. Explicit client session_id wins -> untouched
r3 = FakeRequest({"x-claude-code-session-id": "01a02425-d4fa-7f93-804a-d0a0935561a0"})
h3 = {"session_id": "client-value"}
_inject_codex_session_headers(h3, r3)
assert h3 == {"session_id": "client-value"}, h3
print("OK explicit preserved:", h3)

# 4. No session header from client -> nothing fabricated
r4 = FakeRequest({})
h4 = {}
_inject_codex_session_headers(h4, r4)
assert h4 == {}, h4
print("OK absent not fabricated:", h4)

# 5. Garbage value -> rejected
r5 = FakeRequest({"x-claude-code-session-id": "not-a-uuid"})
h5 = {}
_inject_codex_session_headers(h5, r5)
assert h5 == {}, h5
print("OK garbage rejected")

print("ALL PATCH TESTS PASSED")

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/.claude/agents"
cat > "$ROOT/.claude/settings.json" <<'JSON'
{
  "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "keep-me"}]}]},
  "env": {"ANTHROPIC_SMALL_FAST_MODEL": "stale-model"}
}
JSON
cat > "$ROOT/.claude/agents/general-purpose.md" <<'MD'
---
name: general-purpose
description: Keep this custom body.
model: stale-model
effort: low
---

CUSTOM_BODY_SENTINEL
MD

HOME="$ROOT" bash "$SCRIPT_DIR/sync-claude-subagent-profile.sh" >/dev/null
HOME="$ROOT" bash "$SCRIPT_DIR/sync-claude-subagent-profile.sh" --check >/dev/null
HOME="$ROOT" python3 - <<'PY'
import json
import os
import pathlib

root = pathlib.Path(os.environ["HOME"])
settings = json.loads((root / ".claude/settings.json").read_text())
assert settings["hooks"]["PreToolUse"][0]["hooks"][0]["command"] == "keep-me"
keys = [
    "ANTHROPIC_SMALL_FAST_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_FABLE_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
]
assert all(settings["env"][key] == "qwen3.8-max-preview" for key in keys)
for name in ["general-purpose", "Explore", "workflow-subagent", "bench-reviewer", "bench-triage"]:
    text = (root / ".claude/agents" / f"{name}.md").read_text()
    assert "model: qwen3.8-max-preview" in text
    assert "effort: high" in text
assert "CUSTOM_BODY_SENTINEL" in (root / ".claude/agents/general-purpose.md").read_text()
print("CLAUDE_SUBAGENT_PROFILE_LINUX_CONTRACT_OK")
PY

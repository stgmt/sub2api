#!/usr/bin/env bash
set -euo pipefail

MODEL="qwen3.8-max-preview"
EFFORT="high"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --effort) EFFORT="$2"; shift 2 ;;
    --claude-home) CLAUDE_HOME="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

export MODEL EFFORT CLAUDE_HOME CHECK_ONLY
python3 - <<'PY'
import json
import os
import re
import sys
from pathlib import Path

model = os.environ["MODEL"]
effort = os.environ["EFFORT"]
claude_home = Path(os.environ["CLAUDE_HOME"]).expanduser()
check_only = os.environ["CHECK_ONLY"] == "1"
model_keys = [
    "ANTHROPIC_SMALL_FAST_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_FABLE_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL",
]
agent_names = ["general-purpose", "Explore", "workflow-subagent", "bench-reviewer", "bench-triage"]
mismatches = []

settings_path = claude_home / "settings.json"
if settings_path.exists():
    settings = json.loads(settings_path.read_text(encoding="utf-8-sig"))
else:
    settings = {}
env = settings.setdefault("env", {})
for key in model_keys:
    if env.get(key) != model:
        mismatches.append(f"settings:{key}")
        env[key] = model

agents_dir = claude_home / "agents"
for name in agent_names:
    path = agents_dir / f"{name}.md"
    existed = path.exists()
    if existed:
        text = path.read_text(encoding="utf-8-sig")
    else:
        text = (
            f"---\nname: {name}\n"
            "description: Global delegated Claude Code worker pinned by the sub2api Qwen profile.\n"
            f"model: {model}\neffort: {effort}\n---\n\n"
            "Execute the delegated task with concrete evidence and return the result to the parent agent.\n"
        )

    if not existed:
        mismatches.append(f"agent:{name}:missing")
    else:
        original_model = re.search(r"^model:\s*(.+)$", text, flags=re.M)
        original_effort = re.search(r"^effort:\s*(.+)$", text, flags=re.M)
        if not original_model or original_model.group(1).strip() != model:
            mismatches.append(f"agent:{name}:model")
        if not original_effort or original_effort.group(1).strip() != effort:
            mismatches.append(f"agent:{name}:effort")

    frontmatter = re.match(r"^---\s.*?\s---", text, flags=re.S)
    if frontmatter:
        if re.search(r"^model:\s*.+$", text, flags=re.M):
            text = re.sub(r"^model:\s*.+$", f"model: {model}", text, flags=re.M)
        else:
            text = re.sub(r"^(description:\s*.+)$", rf"\1\nmodel: {model}", text, count=1, flags=re.M)
        if re.search(r"^effort:\s*.+$", text, flags=re.M):
            text = re.sub(r"^effort:\s*.+$", f"effort: {effort}", text, flags=re.M)
        else:
            text = re.sub(r"^(model:\s*.+)$", rf"\1\neffort: {effort}", text, count=1, flags=re.M)
    else:
        text = (
            f"---\nname: {name}\n"
            "description: Global delegated Claude Code worker pinned by the sub2api Qwen profile.\n"
            f"model: {model}\neffort: {effort}\n---\n\n{text}"
        )

    if not check_only:
        agents_dir.mkdir(parents=True, exist_ok=True)
        path.write_text(text.rstrip() + "\n", encoding="utf-8")

environment_path = claude_home.parent / ".config" / "environment.d" / "90-claude-subagents.conf"
expected_environment = "\n".join(f"{key}={model}" for key in model_keys) + "\n"
if not environment_path.exists() or environment_path.read_text(encoding="utf-8-sig") != expected_environment:
    mismatches.append("environment.d")

if not check_only:
    claude_home.mkdir(parents=True, exist_ok=True)
    settings_path.write_text(json.dumps(settings, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    environment_path.parent.mkdir(parents=True, exist_ok=True)
    environment_path.write_text(expected_environment, encoding="utf-8")

result = {
    "status": "mismatch" if check_only and mismatches else ("ok" if check_only else "synced"),
    "platform": "linux",
    "claude_home": str(claude_home),
    "model": model,
    "effort": effort,
    "agents": agent_names,
    "mismatches": mismatches,
}
print(json.dumps(result, ensure_ascii=False))
if check_only and mismatches:
    sys.exit(1)
PY

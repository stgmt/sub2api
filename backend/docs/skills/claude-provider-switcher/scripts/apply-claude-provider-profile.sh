#!/usr/bin/env bash
set -euo pipefail

PROFILE_PATH=""
GENERATION="0"
CHECK_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile-path) PROFILE_PATH="$2"; shift 2 ;;
    --generation) GENERATION="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$PROFILE_PATH" ]] || { echo "--profile-path is required" >&2; exit 2; }

python3 - "$PROFILE_PATH" "$GENERATION" "$CHECK_ONLY" <<'PY'
import json, os, pathlib, re, sys

profile_path, generation, check_raw = sys.argv[1:]
check_only = check_raw == "1"
profile = json.loads(pathlib.Path(profile_path).read_text(encoding="utf-8"))
home = pathlib.Path.home()
settings_path = home / ".claude" / "settings.json"
agents_path = home / ".claude" / "agents"
environment_path = home / ".config" / "environment.d" / "claude-provider-profile.conf"

if settings_path.exists():
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
else:
    settings = {}
env = settings.setdefault("env", {})
desired = {k: str(v) for k, v in profile["client_env"].items()}
desired["CLAUDE_PROVIDER_PROFILE_GENERATION"] = str(generation)
drift = []
for key, value in desired.items():
    if str(env.get(key, "")) != value:
        drift.append(f"settings.env.{key}")
        if not check_only:
            env[key] = value

if drift and not check_only:
    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings_path.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

agents_checked = 0
if agents_path.exists():
    for agent in agents_path.glob("*.md"):
        text = agent.read_text(encoding="utf-8")
        match = re.match(r"\A---\r?\n(.*?)\r?\n---", text, flags=re.S)
        if not match:
            continue
        agents_checked += 1
        header = match.group(1)
        updated = re.sub(r"(?m)^model:\s*.*$", f"model: {profile['agent_model']}", header)
        if updated == header and not re.search(r"(?m)^model:", header):
            updated += f"\nmodel: {profile['agent_model']}"
        before_effort = updated
        updated = re.sub(r"(?m)^effort:\s*.*$", f"effort: {profile['agent_effort']}", updated)
        if updated == before_effort and not re.search(r"(?m)^effort:", before_effort):
            updated += f"\neffort: {profile['agent_effort']}"
        if updated != header:
            drift.append(f"agent:{agent.name}")
            if not check_only:
                agent.write_text("---\n" + updated + "\n---" + text[match.end():], encoding="utf-8")

environment_text = "\n".join(f"{k}={v}" for k, v in desired.items()) + "\n"
current_environment = environment_path.read_text(encoding="utf-8") if environment_path.exists() else ""
if current_environment != environment_text:
    drift.append(f"environment:{environment_path}")
    if not check_only:
        environment_path.parent.mkdir(parents=True, exist_ok=True)
        environment_path.write_text(environment_text, encoding="utf-8")

print(json.dumps({
    "profile": profile["name"],
    "version": profile["version"],
    "generation": str(generation),
    "settings_path": str(settings_path),
    "agents_checked": agents_checked,
    "drift": drift,
    "status": "synced" if not check_only or not drift else "drifted",
}))
if check_only and drift:
    raise SystemExit(3)
PY

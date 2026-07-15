#!/usr/bin/env bash
set -euo pipefail

version="${RTK_VERSION:-v0.42.4}"
install_dir="${RTK_INSTALL_DIR:-$HOME/.local/bin}"
force=0

usage() {
  cat <<'EOF'
Install RTK for a native Linux Claude Code host.

Usage: install-claude-rtk.sh [--version v0.42.4] [--install-dir PATH] [--force]

The installer preserves existing Claude settings and hooks, installs exactly one
global PreToolUse(Bash) RTK hook, and keeps exact-output commands unmodified.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || { echo "--version requires a value" >&2; exit 2; }
      version="$2"
      shift 2
      ;;
    --install-dir)
      [ "$#" -ge 2 ] || { echo "--install-dir requires a value" >&2; exit 2; }
      install_dir="$2"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$version" in
  v[0-9]*.[0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Invalid RTK version: $version" >&2; exit 2 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) asset='rtk-x86_64-unknown-linux-musl.tar.gz' ;;
  *) echo "Unsupported Linux architecture: $(uname -m)" >&2; exit 2 ;;
esac

plain_version="${version#v}"
version="v${plain_version}"
expected="rtk ${plain_version}"
target="${install_dir%/}/rtk"
settings_path="$HOME/.claude/settings.json"
config_path="$HOME/.config/rtk/config.toml"

mkdir -p "$install_dir" "$HOME/.claude" "$HOME/.cache/rtk"

current=''
if [ -x "$target" ]; then
  current="$($target --version 2>/dev/null || true)"
fi

if [ "$force" -eq 1 ] || [ "$current" != "$expected" ]; then
  if [ -n "${RTK_BINARY_SOURCE:-}" ]; then
    install -m 0755 "$RTK_BINARY_SOURCE" "$target"
  else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    url="https://github.com/rtk-ai/rtk/releases/download/${version}/${asset}"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$url" -o "$tmp/rtk.tar.gz"
    elif command -v wget >/dev/null 2>&1; then
      wget -qO "$tmp/rtk.tar.gz" "$url"
    else
      echo "curl or wget is required to install RTK" >&2
      exit 1
    fi
    tar -xzf "$tmp/rtk.tar.gz" -C "$tmp"
    source="$(find "$tmp" -type f -name rtk -print -quit)"
    [ -n "$source" ] || { echo "RTK archive did not contain rtk" >&2; exit 1; }
    install -m 0755 "$source" "$target"
  fi
fi

actual="$($target --version)"
[ "$actual" = "$expected" ] || {
  echo "Expected ${expected}, installed ${actual}" >&2
  exit 1
}

for rc in "$HOME/.profile" "$HOME/.bashrc"; do
  touch "$rc"
  if ! grep -Fq '# sub2api-rtk-path' "$rc"; then
    printf '\n# sub2api-rtk-path\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$rc"
  fi
done

export PATH="$install_dir:$PATH"
if [ -f "$settings_path" ]; then
  cp -p "$settings_path" "${settings_path}.bak-rtk-linux-$(date +%Y%m%d%H%M%S)"
fi

"$target" init --global --auto-patch </dev/null >"$HOME/.cache/rtk/init.log" 2>&1

python3 - "$target" "$settings_path" "$config_path" <<'PY'
import json
import re
import sys
from pathlib import Path

target = Path(sys.argv[1]).resolve()
settings_path = Path(sys.argv[2])
config_path = Path(sys.argv[3])
home = Path.home()

if not settings_path.exists():
    raise SystemExit(f"Claude settings not found after rtk init: {settings_path}")

settings = json.loads(settings_path.read_text(encoding="utf-8"))
hooks = settings.setdefault("hooks", {})
entries = hooks.get("PreToolUse", [])
retained = []
for entry in entries if isinstance(entries, list) else []:
    commands = [str(hook.get("command", "")) for hook in entry.get("hooks", [])]
    is_rtk_bash = entry.get("matcher") == "Bash" and any(
        re.search(r"(?:^|/)rtk(?:\.exe)?\s+hook\s+claude", command)
        for command in commands
    )
    if not is_rtk_bash:
        retained.append(entry)

hook_command = f"{target} hook claude"
retained.append(
    {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": hook_command}],
    }
)
hooks["PreToolUse"] = retained
settings_path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")

config_path.parent.mkdir(parents=True, exist_ok=True)
exclusions = ["cat", "git diff", "git show", "curl"]
line = "exclude_commands = [" + ", ".join(json.dumps(v) for v in exclusions) + "]"
text = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
section = re.search(r"(?ms)(^\[hooks\]\s*\n)(.*?)(?=^\[|\Z)", text)
if section:
    body = section.group(2)
    if re.search(r"(?m)^\s*exclude_commands\s*=.*$", body):
        body = re.sub(r"(?m)^\s*exclude_commands\s*=.*$", line, body)
    else:
        body = line + "\n" + body
    text = text[: section.start(2)] + body + text[section.end(2) :]
else:
    prefix = text.rstrip()
    text = (prefix + "\n\n" if prefix else "") + "[hooks]\n" + line + "\n"
config_path.write_text(text, encoding="utf-8")

rtk_md_path = home / ".claude" / "RTK.md"
if not rtk_md_path.exists():
    raise SystemExit(f"rtk init did not create {rtk_md_path}")
rtk_text = rtk_md_path.read_text(encoding="utf-8", errors="replace")
managed = """<!-- sub2api:rtk-profile -->
## sub2api accuracy profile

The Claude Code Bash hook is active. Exact source, diff, and raw API commands are excluded from automatic rewriting: cat, git diff, git show, curl. Use `RTK_DISABLED=1 <command>` for any one-off raw command. Use `rtk gain --format json` and `rtk hook-audit` for evidence.
<!-- /sub2api:rtk-profile -->"""
pattern = r"(?ms)<!-- sub2api:rtk-profile -->.*?<!-- /sub2api:rtk-profile -->"
if re.search(pattern, rtk_text):
    rtk_text = re.sub(pattern, managed, rtk_text)
else:
    rtk_text = rtk_text.rstrip() + "\n\n" + managed + "\n"
rtk_md_path.write_text(rtk_text, encoding="utf-8")

claude_md_path = home / ".claude" / "CLAUDE.md"
claude_text = (
    claude_md_path.read_text(encoding="utf-8", errors="replace")
    if claude_md_path.exists()
    else ""
)
if not re.search(r"(?m)^@RTK\.md\s*$", claude_text):
    claude_text = claude_text.rstrip() + "\n\n@RTK.md\n"
    claude_md_path.write_text(claude_text.lstrip("\n"), encoding="utf-8")

rtk_hook_count = sum(
    any("rtk hook claude" in str(hook.get("command", "")) for hook in entry.get("hooks", []))
    for entry in hooks["PreToolUse"]
)
if rtk_hook_count != 1:
    raise SystemExit(f"Expected one RTK hook, found {rtk_hook_count}")
PY

python3 - "$target" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

target = Path(sys.argv[1])
commands = {
    "git status": "rtk git status",
    "git log -1 --oneline": "rtk git log -1 --oneline",
    "cat /etc/os-release": None,
    "git diff --stat": None,
    "git show --stat": None,
    "curl https://example.com": None,
}

for command, expected in commands.items():
    payload = {
        "session_id": "rtk-linux-install-probe",
        "cwd": str(Path.home()),
        "hook_event_name": "PreToolUse",
        "tool_name": "Bash",
        "tool_input": {"command": command},
    }
    run = subprocess.run(
        [str(target), "hook", "claude"],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        timeout=20,
    )
    if run.returncode != 0:
        raise SystemExit(f"RTK hook failed for {command!r}: {run.stderr.strip()}")
    rewritten = None
    if run.stdout.strip():
        parsed = json.loads(run.stdout)
        rewritten = (
            parsed.get("hookSpecificOutput", {})
            .get("updatedInput", {})
            .get("command")
        )
    if rewritten != expected:
        raise SystemExit(
            f"RTK hook mismatch for {command!r}: expected {expected!r}, got {rewritten!r}"
        )
PY

printf 'RTK Linux host install OK\n'
printf '  version: %s\n' "$actual"
printf '  binary: %s\n' "$target"
printf '  Claude hook: %s hook claude\n' "$target"
printf '  exclusions: cat, git diff, git show, curl\n'
printf 'Restart Claude Code before relying on the new hook.\n'

#!/usr/bin/env bash
set -euo pipefail

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_HOOK="$SCRIPT_DIR/claude-stream-recovery.mjs"
TARGET_DIR="$CLAUDE_HOME/hooks"
TARGET_HOOK="$TARGET_DIR/claude-stream-recovery.mjs"
SETTINGS="$CLAUDE_HOME/settings.json"

command -v node >/dev/null 2>&1 || { echo "node is required" >&2; exit 1; }
test -f "$SOURCE_HOOK" || { echo "missing $SOURCE_HOOK" >&2; exit 1; }
mkdir -p "$TARGET_DIR"
install -m 0755 "$SOURCE_HOOK" "$TARGET_HOOK"

node - "$SETTINGS" "$TARGET_HOOK" "$(command -v node)" <<'NODE'
const fs = require("fs");
const [settingsPath, hookPath, nodePath] = process.argv.slice(2);
let settings = {};
if (fs.existsSync(settingsPath)) settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
settings.hooks ||= {};
for (const eventName of ["Stop", "SubagentStop"]) {
  const entries = Array.isArray(settings.hooks[eventName]) ? settings.hooks[eventName] : [];
  const kept = entries.filter((entry) => !JSON.stringify(entry).includes("claude-stream-recovery.mjs"));
  kept.push({
    hooks: [{
      type: "command",
      command: `${JSON.stringify(nodePath)} ${JSON.stringify(hookPath)}`,
      timeout: 5,
    }],
  });
  settings.hooks[eventName] = kept;
}
fs.writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, { mode: 0o600 });
NODE

echo "Installed Claude stream recovery hook: $TARGET_HOOK"
echo "Updated Claude settings: $SETTINGS"

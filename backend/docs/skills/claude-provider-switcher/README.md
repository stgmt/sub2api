# Claude Provider Switcher Skill

Portable Codex skill for fleet-wide switching between the native Claude Code subscription and the current GPT/Qwen profile behind Headroom + sub2api.

The skill owns provider switching, reconciliation, rollback, and live route proof. Stack installation and proxy repair remain in the companion `sub2api-claude-code-codex` skill.

Install the skill and command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/install-claude-route.ps1
```

Then use `claude-route status`, `claude-route anthropic`, `claude-route hybrid`, `claude-route reconcile`, and `claude-route verify`.

No credentials are stored in this bundle. Machine topology is adapter input and offline nodes remain `pending-reconcile`.

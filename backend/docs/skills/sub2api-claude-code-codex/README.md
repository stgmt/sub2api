# sub2api Claude Code Codex Skill

Portable Codex skill bundle for running Claude Code against a local Anthropic-compatible `sub2api` proxy backed by an OpenAI/Codex/ChatGPT subscription.

Primary entrypoint:

- `SKILL.md`

Included support material:

- `references/` - setup notes, routing policy, compact behavior, verification, troubleshooting
- `scripts/` - Windows/PowerShell helpers for setup, verification, and compact recovery hooks
- `evals/` - lightweight eval prompts for the skill behavior

Install into a Codex profile by copying this directory to:

```text
~/.codex/skills/sub2api-claude-code-codex
```

This bundle intentionally does not contain real OAuth tokens, API keys, refresh tokens, passwords, or copied auth files. Scripts generate local secrets at install/runtime.

# sub2api Claude Code Codex Skill

Portable Codex skill bundle for running Claude Code against a local Headroom + Anthropic-compatible `sub2api` proxy chain backed by an OpenAI/Codex/ChatGPT subscription.

Primary entrypoint:

- `SKILL.md`

Companion skill:

- `../claude-provider-switcher/SKILL.md` - fleet-wide provider profile switching, reconciliation, verification, and rollback

Included support material:

- `references/` - setup notes, routing policy, compact behavior, verification, troubleshooting, and the cross-session failure registry
- `scripts/` - Windows and Linux setup, verification, host-profile, autostart, RTK, compact-recovery, routing, and contract-test helpers
- `evals/` - lightweight eval prompts for the skill behavior

The complete reproducible harness also includes the repository's
`deploy/claude-code-codex-headroom`, backend mixed-provider routing, and
frontend messages-dispatch round-trip. Run
`scripts/test-qwen-sdk-cli-harness-contract.ps1` before publishing so those
surfaces cannot be omitted while only the skill entrypoint is updated.

Install into a Codex profile by copying this directory to:

```text
~/.codex/skills/sub2api-claude-code-codex
```

This bundle intentionally does not contain real OAuth tokens, API keys, refresh tokens, passwords, or copied auth files. Scripts generate local secrets at install/runtime.

Default local chain:

```text
Claude Code -> http://127.0.0.1:8787 -> Headroom -> http://sub2api:8080 -> sub2api -> OpenAI/Codex OAuth
```

The direct sub2api port `http://127.0.0.1:18081` is kept for the admin UI, diagnostics, and non-Claude clients. Claude Code should use Headroom on `8787`.

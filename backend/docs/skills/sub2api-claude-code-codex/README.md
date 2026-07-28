# sub2api Claude Code Codex Skill

Portable Codex skill bundle for running Claude Code against a local Headroom + Anthropic-compatible `sub2api` proxy chain and switching the complete Claude Code fleet between the native Claude subscription and the current GPT/Qwen hybrid profile.

Primary entrypoint:

- `SKILL.md`

Included support material:

- `profiles/` - versioned `anthropic-only` and `hybrid-current` provider snapshots
- `references/` - setup notes, provider switching, fleet reconciliation, routing policy, compact behavior, verification, troubleshooting, and the cross-session failure registry
- `scripts/` - Windows and Linux setup, provider controller, verification, host-profile, autostart, RTK, compact-recovery, routing, and contract-test helpers
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

Install the bundled route controller with `scripts/install-claude-route.ps1`, then use `claude-route status|anthropic|hybrid|reconcile|verify`. No separate provider-switcher skill is required.

Every provider profile also enforces the provider-independent Claude Code worker policy: at most 10 concurrent subagents and spawn depth 1. See `references/subagent-concurrency-policy.md` for incident evidence, fleet scope, and verification.

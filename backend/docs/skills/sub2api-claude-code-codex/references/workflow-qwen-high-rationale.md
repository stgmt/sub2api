# Workflow Qwen High Rationale

Use this reference when changing Claude Code workflow/subagent model defaults, compact routing, picker aliases, or setup scripts for the local Headroom + sub2api profile.

## Current Decision

The user explicitly chose one delegated profile:

```text
Lead/main model: gpt-5.6-sol
Subagents: qwen3.8-max-preview, effort high
Workflow workers: qwen3.8-max-preview, effort high
Standalone claude -p / --print: qwen3.8-max-preview, effort high
Small-fast: qwen3.8-max-preview
Compact: qwen3.8-max-preview, effort high
Picker aliases Opus/Fable/Sonnet/Haiku: qwen3.8-max-preview
Normal fallbacks: none unless explicitly requested
OpenAI account compact_model_mapping / compact_model_fallbacks: empty
```

This is a policy choice for this machine and fork, not a generic benchmark law.

## Why It Is This Way

- The lead session stays on `gpt-5.6-sol` so full-power work can still use the Codex/OpenAI OAuth route.
- Delegated/workflow traffic uses Qwen high so agents do not inherit lead Sol/max and burn the limited main route under fan-out.
- `claude -p` uses the same Claude SDK User-Agent family as delegated agents. Local agent frontmatter cannot cover ad-hoc print processes, so the group-level `sdk_cli_mapped_model` and `sdk_cli_reasoning_effort` rule is the authoritative cross-host safety net. Interactive Claude uses `(external, cli)` and remains user-selectable.
- Compact uses group-level `messages_dispatch_model_config.compact_mapped_model=qwen3.8-max-preview` because Claude Code native `/compact` can keep the session main model. sub2api must rewrite compact requests before provider classification so GPT/Codex sessions can cross-route to the Alibaba Token Plan account.
- Account-level OpenAI `compact_model_mapping` is intentionally empty in the current profile. It runs after OpenAI account selection and cannot safely jump to Alibaba/Qwen; leaving old Spark mappings there can silently revive legacy compact behavior.
- Spark remains a historical fast short-summary baseline, but it is not the current workflow default: it is 128k, text-only, and has no reasoning-effort knob.
- Terra-medium remains a supported historical delegated baseline, but the current user-selected profile is Qwen 3.8 Max High.
- Raw Claude/Fable/Haiku/Opus/Sonnet provider aliases are not published. Claude Code picker slots are env aliases and should all point to Qwen high in this profile.

## What To Update Together

When this profile changes, update all of these in one pass:

- `%USERPROFILE%\.claude\settings.json` env.
- Windows User env.
- `%USERPROFILE%\.claude\agents\general-purpose.md`.
- `%USERPROFILE%\.claude\agents\Explore.md`.
- `%USERPROFILE%\.claude\agents\workflow-subagent.md`.
- `%USERPROFILE%\.claude\agents\bench-reviewer.md`.
- `%USERPROFILE%\.claude\agents\bench-triage.md`.
- sub2api group `messages_dispatch_model_config.compact_mapped_model`.
- sub2api group `messages_dispatch_model_config.sdk_cli_mapped_model` and `sdk_cli_reasoning_effort`.
- sub2api group `messages_dispatch_model_config.model_fallbacks.qwen3.8-max-preview=[gpt-5.6-sol]`; this candidate is restricted in code to terminal quota or scheduler-no-Qwen automatic routes.
- `scripts/sync-sub2api-sdk-cli-routing.ps1` for idempotent live DB sync and audit.
- OpenAI account `credentials.compact_model_mapping` and `credentials.compact_model_fallbacks`, normally both `{}`.
- `scripts/setup-sub2api-claude-code.ps1`.
- `scripts/verify-claude-code-sub2api.ps1`.
- `references/fullpower-profile.json`.
- `references/profile-and-context.md`.
- `references/group-and-compact-routing.md`.
- `references/subagent-terra-medium-profile.md`.
- `references/verification.md`.
- `references/troubleshooting.md`.
- `evals/evals.json`.
- The installed Codex skill at `%USERPROFILE%\.codex\skills\sub2api-claude-code-codex`.

## Required Live Proof

Do not trust UI labels alone. After a runtime change, prove it with:

```text
settings/env: all delegated/picker/small-fast slots show qwen3.8-max-preview
agent frontmatter: model=qwen3.8-max-preview, effort=high
group row: compact_mapped_model=qwen3.8-max-preview
group row: model_fallbacks.qwen3.8-max-preview[0]=gpt-5.6-sol
OpenAI account credentials: compact_model_mapping={}, compact_model_fallbacks={}
compact probe: response model qwen3.8-max-preview
usage_logs: compact requested_model=qwen3.8-max-preview, reasoning_effort=high, Alibaba account
usage_logs: Agent/general-purpose requested_model=qwen3.8-max-preview, reasoning_effort=high, Alibaba account
terminal-quota control: automatic request retries as gpt-5.6-sol/high, account rate_limit_reset_at matches provider reset, and a second automatic request creates no new Qwen upstream probe
healthy/transient/direct controls: healthy Qwen stays Qwen; transient failures and direct interactive Qwen do not cross providers
health: headroom-sub2api and sub2api-codex healthy
```

Known good live evidence after the 2026-07-22 switch:

```text
compact post-recreate: usage_logs id 69091 -> qwen3.8-max-preview, high, account_id=2
general-purpose agent: usage_logs id 69092 -> qwen3.8-max-preview, high, account_id=2
large compact/workflow path: usage_logs id 69030 -> qwen3.8-max-preview, high, account_id=2, 365598 input tokens
main GPT sanity: gpt-5.6-sol still routes to account_id=1
commits: 03b26c8b fix: route Claude compact to Qwen high; bee08a19 docs: pin Claude picker slots to Qwen high
```

## Do Not Regress

- Do not reintroduce Spark/Luna as compact defaults without a new user decision.
- Do not reintroduce `haiku` as the hidden small/fast picker default.
- Do not broaden the Qwen-to-Sol candidate beyond terminal Token Plan exhaustion or scheduler-no-Qwen on automatic routes. It must never hide transient failures after account selection or direct-interactive provider/account bugs.
- Do not set persistent `CLAUDE_CODE_EFFORT_LEVEL`; it overrides interactive `/effort`.
- Do not call `370000` or `340000` an upstream model window. They are Claude Code client safety targets.
- Do not install hard Agent-blocking hooks unless the user explicitly asks for them.

---
name: sub2api-claude-code-codex
description: >-
  Use this skill for Claude Code through a Headroom-first Anthropic-compatible local proxy chain backed by an OpenAI/Codex/ChatGPT subscription: Headroom context optimization, sub2api, Docker/WSL Docker, Codex OAuth, GPT-5.6 Sol/Terra/Luna, GPT-5.3 Codex Spark compact acceleration, Claude Opus/Sonnet/Haiku mapping, max reasoning, context window fixes, empty/0-token ghost streams, stale fake 429/503 no-available-accounts cooldowns, and model_rate_limits self-heal debugging. Triggers include "Claude Code через Codex подписку", "Headroom sub2api", "sub2api Docker", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5[400k]", "быстрая компактизация", "gpt-5.3-codex-spark", "usage 0/0", "503 Service temporarily unavailable", "429 rate_limit_error", and "no available accounts".
---

# sub2api Claude Code Codex

This skill is the short entrypoint for running Claude Code through a local Headroom + `sub2api` Anthropic-compatible proxy chain backed by the user's OpenAI/Codex/ChatGPT subscription. Keep this file lean; load the reference files only when the task needs those details.

## Current Profile

Use this profile unless the user explicitly asks for a different model, port, or risk tradeoff:

```text
Fork: https://github.com/stgmt/sub2api
Branch: main
Verified main commit: 8049675b fix: fall back on Anthropic messages model-not-found
Fixed issue: https://github.com/stgmt/sub2api/issues/1
Image: sub2api-codex:local-token-usage
Headroom image: headroom-sub2api:0.31.0 built from headroom-ai[proxy] on PyPI
Docker compose project: sub2api-codex
Deploy profile: deploy/claude-code-codex-headroom
Claude base URL: http://127.0.0.1:8787
Claude chain: Claude Code -> Headroom 127.0.0.1:8787 -> Docker DNS http://sub2api:8080
Direct sub2api URL: http://127.0.0.1:18081 for admin UI, diagnostics, and non-Claude clients only
Main model: gpt-5.6-sol
Small-fast/compact first hop: gpt-5.3-codex-spark with normal model_fallbacks to gpt-5.6-luna, then gpt-5.4-mini
Default Haiku and subagent overrides: gpt-5.6-terra-high while native Spark is quota-limited, so inherited Sol/max does not leak into delegated or default-Haiku paths
Official model windows: GPT-5.6 Sol/Terra/Luna = 1.05M; Claude Fable 5/Opus 4.8/Sonnet 5 = 1M; Claude Haiku 4.5 = 200k
Client context target: CLAUDE_CODE_MAX_CONTEXT_TOKENS=1050000, CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000 (Claude Code client display/planning target for the 1.05M GPT-5.6 route)
Compact model: gpt-5.3-codex-spark, fallback gpt-5.6-luna, then gpt-5.4-mini
Reasoning: main GPT-5.6 uses max; delegated Terra subagents use high unless explicitly raised
```

Claude model mapping:

```text
claude-opus-*   -> gpt-5.6-sol
opus            -> gpt-5.6-sol
claude-sonnet-* -> gpt-5.6-terra
sonnet          -> gpt-5.6-terra
claude-haiku-*  -> gpt-5.3-codex-spark, fallback gpt-5.6-luna, then gpt-5.4-mini
haiku           -> gpt-5.3-codex-spark, fallback gpt-5.6-luna, then gpt-5.4-mini
gpt-5.3-codex-spark -> gpt-5.3-codex-spark, fallback gpt-5.6-luna, then gpt-5.4-mini
gpt-5.6         -> gpt-5.6-sol
gpt-5.6-sol     -> gpt-5.6-sol
gpt-5.6-terra   -> gpt-5.6-terra
gpt-5.6-luna    -> gpt-5.6-luna, fallback gpt-5.3-codex-spark, then gpt-5.4-mini
```

## Reference Map

Read only the file needed for the current task:

- `references/profile-and-context.md`: source-of-truth profile, official GPT-5.6 context facts, compact profile, and context-window caveats.
- `references/install-and-claude-config.md`: Docker/WSL install, OAuth import, Claude Code env/settings, dynamic MCP, and memory/rules configuration.
- `references/group-and-compact-routing.md`: sub2api group JSON, Claude model mapping, compact mapping, fallback SQL, and account credential patches.
- `references/verification.md`: health probes, Claude Code probes, `/v1/messages` checks, usage_logs queries, compact verification, and expected evidence.
- `references/troubleshooting.md`: 429/503/no-available-accounts, stale cooldowns, empty streams, context overflow, Luna availability, localhost relay, and usage-display bugs.
- `references/fullpower-profile.json`: machine-readable profile snapshot when scripts or exact config values are useful.

## Operating Rules

- Do not print OAuth tokens, API keys, refresh tokens, passwords, or copied auth files in chat.
- Prefer request-time `/v1/messages` probes and `usage_logs.upstream_model` over `/v1/models` catalog output.
- Keep Spark as Claude Code small-fast and compact first hop. While native Spark is quota-limited, keep Claude Code `ANTHROPIC_DEFAULT_HAIKU_MODEL` and `CLAUDE_CODE_SUBAGENT_MODEL` on `gpt-5.6-terra-high` so delegated/default-Haiku paths do not accidentally hit Spark and do not inherit parent Sol/max. Pin frequent subagents with frontmatter `model: gpt-5.6-terra-high` and `effort: high`.
- Keep Luna as the second hop after Spark for small-fast/Haiku and compact fallbacks, with `gpt-5.4-mini` as the last-resort fallback. Direct `gpt-5.6-luna` requests fall back to `gpt-5.3-codex-spark`, then `gpt-5.4-mini`.
- For Claude Code `general-purpose`, `Explore`, and `workflow-subagent`, use user-level overrides at `%USERPROFILE%\.claude\agents\*.md` with `model: gpt-5.6-terra-high` and `effort: high` while Spark is quota-limited. The `-high` alias is intentional: patched sub2api strips it to upstream `gpt-5.6-terra` and records `reasoning_effort=high`, overriding inherited parent `max`. Project-specific agents such as `agent-marketplace-agent` should get the same frontmatter when they fan out heavily. Verify with agent JSONL and `usage_logs.reasoning_effort`, not with the Claude UI label alone.
- Do not persist `CLAUDE_CODE_EFFORT_LEVEL` in Windows User/System env or `~/.claude/settings.json env`. It overrides Claude Code's interactive `/effort` command for every session. Use `effortLevel` only as a soft startup default, and prefer `xhigh` for the profile default so users can switch to `max`, `high`, or lower efforts in-session.
- Do not install a global `PreToolUse` / `SubagentStart` / `SubagentStop` hook that blocks Agent calls unless the user explicitly asks for it. Current policy is advisory only: `workflowSizeGuideline=small` plus the `general-purpose` prompt asks for no more than 10 sibling agents and no deep chains. Do not claim Claude Code has a reliable built-in depth cap that prevents hundreds of descendants; local evidence has shown a single parent line can grow into hundreds of spawned agents.
- Never describe `400000` as the GPT-5.6 upstream/model context limit. It was an old conservative Claude Code client target from the GPT-5.5-era instability. Current GPT-5.6 client profile is `CLAUDE_CODE_MAX_CONTEXT_TOKENS=1050000` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000`; still verify real upstream failures from proxy logs before blaming context.
- Treat `stale fake 429/503` as a proxy state bug first: issue #1 fixed quota-origin cooldown recovery, so stale recurrence usually means an old image, stale container, or non-quota cooldown reason.
- For Docker-in-WSL, verify both Headroom and sub2api health plus the Windows route. If Windows cannot reach `127.0.0.1:8787` but WSL/Docker can, publish Headroom on `0.0.0.0` and use the WSL eth0 IP on port `8787`; do not point Claude Code directly at sub2api `18081` except as a temporary diagnostic bypass.
- After code changes, rebuild `sub2api-codex:local-token-usage` or the compose profile, recreate affected services under project `sub2api-codex`, then re-run live probes through Headroom.

## Workflow

1. Inspect current state: `~/.claude/settings.json`, User env, Docker container health, group mapping, account `credentials` compact mappings, and account `extra.model_rate_limits`.
2. If installing or repairing Docker/Claude config, read `references/install-and-claude-config.md` and use the bundled setup script.
3. If changing models or compact routing, read `references/group-and-compact-routing.md` and patch both `groups.messages_dispatch_model_config` and `accounts.credentials`.
4. If debugging limits or errors, read `references/troubleshooting.md` before changing DB state. Preserve non-quota reasons such as `upstream_404_model_not_found` unless deliberately re-probing that model.
5. Verify with `references/verification.md`: Headroom health/upstream, sub2api health, GPT-5.6 probes through Headroom, Claude alias probes, and `usage_logs` mapping evidence.
6. Update this skill only after live verification when a model lineup, context window, or proxy behavior changes.

## Bundled Scripts

- `scripts/setup-sub2api-claude-code.ps1`: create/update `deploy/claude-code-codex-headroom/.env`, start the Headroom + sub2api compose project, and configure Claude Code settings. Defaults to `gpt-5.6-sol`, `gpt-5.3-codex-spark`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS=1050000`, and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000`.
- `scripts/verify-claude-code-sub2api.ps1`: verify Headroom health/upstream, sub2api health, Claude Code settings, and expected upstream model behavior.
- `scripts/install-claude-compact-recovery.ps1`: install Claude Code compact recovery hooks.
- `scripts/compact-recovery.mjs`: lightweight compact recovery hook implementation.

## Minimum Done Criteria

For install/config/debug tasks, do not call it done until these are true or explicitly blocked:

- `headroom-sub2api` and `sub2api-codex` containers are healthy.
- Headroom `/health` reports ready and upstream `http://sub2api:8080`.
- A tiny `/v1/messages` request through `http://127.0.0.1:8787` succeeds for `gpt-5.6-sol` and for Haiku/small-fast through `gpt-5.3-codex-spark` or the configured `gpt-5.6-luna -> gpt-5.4-mini` fallback chain, or a current upstream quota/cooldown blocker is proven as `429`.
- Claude aliases route as expected in `usage_logs` or response/model mapping evidence: Opus -> Sol, Sonnet -> Terra, Haiku -> Spark -> Luna -> mini.
- `~/.claude/settings.json` and User env agree on main/small models and Claude Code client context target.
- Any GitHub issue or fork change the user asked for is pushed and linked.

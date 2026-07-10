---
name: sub2api-claude-code-codex
description: >-
  Use this skill for Claude Code through an Anthropic-compatible local proxy backed by an OpenAI/Codex/ChatGPT subscription: sub2api, Docker/WSL Docker, Codex OAuth, GPT-5.6 Sol/Terra/Luna, GPT-5.3 Codex Spark compact acceleration, Claude Opus/Sonnet/Haiku mapping, max reasoning, context window fixes, empty/0-token ghost streams, stale fake 429/503 no-available-accounts cooldowns, and model_rate_limits self-heal debugging. Triggers include "Claude Code через Codex подписку", "sub2api Docker", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5[400k]", "быстрая компактизация", "gpt-5.3-codex-spark", "usage 0/0", "503 Service temporarily unavailable", "429 rate_limit_error", and "no available accounts".
---

# sub2api Claude Code Codex

This skill is the short entrypoint for running Claude Code through the local `sub2api` Anthropic-compatible proxy backed by the user's OpenAI/Codex/ChatGPT subscription. Keep this file lean; load the reference files only when the task needs those details.

## Current Profile

Use this profile unless the user explicitly asks for a different model, port, or risk tradeoff:

```text
Fork: https://github.com/stgmt/sub2api
Branch: main
Verified main commit: 8049675b fix: fall back on Anthropic messages model-not-found
Fixed issue: https://github.com/stgmt/sub2api/issues/1
Image: sub2api-codex:local-token-usage
Docker compose project: sub2api-codex
Default bind: 0.0.0.0:18081 -> container 8080
Claude base URL: http://<wsl-primary-ip>:18081 when Windows localhost relay is unreliable
Main model: gpt-5.6-sol
Small/Haiku model: gpt-5.3-codex-spark with normal model_fallbacks to gpt-5.6-luna, then gpt-5.4-mini
Official model windows: GPT-5.6 Sol/Terra/Luna = 1.05M; Claude Fable 5/Opus 4.8/Sonnet 5 = 1M; Claude Haiku 4.5 = 200k
Client compact target: CLAUDE_CODE_MAX_CONTEXT_TOKENS=400000, CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000 (conservative Claude Code setting, not the model window)
Compact model: gpt-5.3-codex-spark, fallback gpt-5.6-luna, then gpt-5.4-mini
Reasoning: max in Claude Code, strongest supported OpenAI effort in sub2api logs
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
- Keep Spark as Claude Code small-fast/Haiku and compact first hop. Do not route main Opus/Sonnet/full-power work to Spark.
- Keep Luna as the second hop after Spark for small-fast/Haiku and compact fallbacks, with `gpt-5.4-mini` as the last-resort fallback. Direct `gpt-5.6-luna` requests fall back to `gpt-5.3-codex-spark`, then `gpt-5.4-mini`.
- Never describe `400000` as the proven upstream/model context limit. It is only the current Claude Code client compact/display target; prove larger windows with a live long-context request through the Docker proxy before changing it.
- Treat `stale fake 429/503` as a proxy state bug first: issue #1 fixed quota-origin cooldown recovery, so stale recurrence usually means an old image, stale container, or non-quota cooldown reason.
- For Docker-in-WSL, verify both container health and Windows route. If `127.0.0.1:18081` hangs but WSL IP works, set Claude Code to `http://<wsl-primary-ip>:18081`.
- After code changes, rebuild `sub2api-codex:local-token-usage`, recreate only the `sub2api` service, then re-run live probes.

## Workflow

1. Inspect current state: `~/.claude/settings.json`, User env, Docker container health, group mapping, account `credentials` compact mappings, and account `extra.model_rate_limits`.
2. If installing or repairing Docker/Claude config, read `references/install-and-claude-config.md` and use the bundled setup script.
3. If changing models or compact routing, read `references/group-and-compact-routing.md` and patch both `groups.messages_dispatch_model_config` and `accounts.credentials`.
4. If debugging limits or errors, read `references/troubleshooting.md` before changing DB state. Preserve non-quota reasons such as `upstream_404_model_not_found` unless deliberately re-probing that model.
5. Verify with `references/verification.md`: health, direct GPT-5.6 probes, Claude alias probes, and `usage_logs` mapping evidence.
6. Update this skill only after live verification when a model lineup, context window, or proxy behavior changes.

## Bundled Scripts

- `scripts/setup-sub2api-claude-code.ps1`: create/update the local Docker runtime and Claude Code settings. Defaults to `gpt-5.6-sol`, `gpt-5.3-codex-spark`, and a conservative 400k Claude Code client compact target.
- `scripts/verify-claude-code-sub2api.ps1`: verify health, Claude Code settings, and expected upstream model behavior.
- `scripts/install-claude-compact-recovery.ps1`: install Claude Code compact recovery hooks.
- `scripts/compact-recovery.mjs`: lightweight compact recovery hook implementation.

## Minimum Done Criteria

For install/config/debug tasks, do not call it done until these are true or explicitly blocked:

- `sub2api-codex` container is healthy.
- A tiny `/v1/messages` request succeeds for `gpt-5.6-sol` and for Haiku/small-fast through `gpt-5.3-codex-spark` or the configured `gpt-5.6-luna -> gpt-5.4-mini` fallback chain.
- Claude aliases route as expected in `usage_logs` or response/model mapping evidence: Opus -> Sol, Sonnet -> Terra, Haiku -> Spark -> Luna -> mini.
- `~/.claude/settings.json` and User env agree on main/small models and Claude Code client context target.
- Any GitHub issue or fork change the user asked for is pushed and linked.

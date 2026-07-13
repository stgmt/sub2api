---
name: sub2api-claude-code-codex
description: >-
  Use this skill for Claude Code through a Headroom-first Anthropic-compatible local proxy chain backed by an OpenAI/Codex/ChatGPT subscription: Headroom context optimization, Headroom embedding-server/watchdog sidecar, sub2api, Docker/WSL Docker, Codex OAuth, GPT-5.6 Sol/Terra/Luna, GPT-5.3 Codex Spark compact acceleration, Claude Opus/Sonnet/Haiku mapping, max reasoning, context window fixes, empty/0-token ghost streams, stale fake 429/503 no-available-accounts cooldowns, and model_rate_limits self-heal debugging. Triggers include "Claude Code через Codex подписку", "Headroom sub2api", "sub2api Docker", "embedding-server", "SocketEmbedderClient", "Falling back to per-worker embedder", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5[400k]", "быстрая компактизация", "gpt-5.3-codex-spark", "usage 0/0", "503 Service temporarily unavailable", "429 rate_limit_error", and "no available accounts".
---

# sub2api Claude Code Codex

This skill is the short entrypoint for running Claude Code through a local Headroom + `sub2api` Anthropic-compatible proxy chain backed by the user's OpenAI/Codex/ChatGPT subscription. Keep this file lean; load the reference files only when the task needs those details.

## Current Profile

Use this profile unless the user explicitly asks for a different model, port, or risk tradeoff:

```text
Fork: https://github.com/stgmt/sub2api
Headroom fork: https://github.com/stgmt/headroom
Branch: main
Verified main commit: use `git log -1 --oneline` on https://github.com/stgmt/sub2api main after each stack update
Fixed issue: https://github.com/stgmt/sub2api/issues/1
Image: sub2api-codex:local-token-usage
Headroom image: headroom-sub2api:0.31.0 built from `HEADROOM_GIT_REPO=https://github.com/stgmt/headroom.git` at pinned `HEADROOM_GIT_REF` using `HEADROOM_RUST_TOOLCHAIN=1.88.0`, plus RTK, lean-ctx, TokenSave, ast-grep, difft, scc, and idempotent downstream embedding-server plus Claude Code streaming-overlap patch guardrails
Docker compose project: sub2api-codex
Deploy profile: deploy/claude-code-codex-headroom
Claude base URL: http://127.0.0.1:8787
Claude chain: Claude Code -> Headroom 127.0.0.1:8787 -> Docker DNS http://sub2api:8080
Direct sub2api URL: http://127.0.0.1:18081 for admin UI, diagnostics, and non-Claude clients only
Headroom MCP: user-level Claude MCP named `headroom`, launched through `wsl.exe -e docker exec -i headroom-sub2api headroom mcp serve --proxy-url http://127.0.0.1:8787`
Headroom savings profile: agent-90, target ratio 0.10, context tool RTK, code-aware compression on, memory on, embedding server on, output shaper on
Host state root: `${SUB2API_STATE_ROOT:-./data}` in the deploy profile. All state must be host bind-mounted there, not stored in Docker named volumes.
Headroom persistence: `/root/.headroom` stores `ccr_store.db`, savings, and logs; `/root/.cache/headroom` and `/root/.cache/huggingface` store warmed local tool/model/embedding caches. These paths must be host bind mounts.
Windows autostart: use one scheduled task named `Sub2API Codex Proxy Stack Autostart`, not a Startup-folder `.cmd` and not a separate `headroom-proxy` task. The task must run the canonical stack start script with `RunLevel=Highest` so it can self-heal stale WSL `ext4.vhdx` attach locks.
Main model: gpt-5.6-sol
Small-fast/compact first hop: gpt-5.3-codex-spark with normal model_fallbacks to gpt-5.6-luna, then gpt-5.4-mini
Default Haiku and subagent overrides: gpt-5.6-terra-medium while native Spark is quota-limited, with model_fallbacks to gpt-5.6-sol-medium so empty Terra tool turns do not loop on the same account
Official model windows: GPT-5.6 Sol/Terra/Luna = 1.05M; Claude Fable 5/Opus 4.8/Sonnet 5 = 1M; Claude Haiku 4.5 = 200k
Client context target: CLAUDE_CODE_MAX_CONTEXT_TOKENS=370000, CLAUDE_CODE_AUTO_COMPACT_WINDOW=340000 (Claude Code client compact/display target; lower than the official 1.05M GPT-5.6 window to avoid late upstream overflow and max-output failures)
Compact model: gpt-5.3-codex-spark, fallback gpt-5.6-luna, then gpt-5.4-mini
Reasoning: main GPT-5.6 uses max; delegated Terra subagents use medium unless explicitly raised
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
gpt-5.6-terra-medium -> gpt-5.6-terra, fallback gpt-5.6-sol-medium
gpt-5.6-luna    -> gpt-5.6-luna, fallback gpt-5.3-codex-spark, then gpt-5.4-mini
```

## Reference Map

Read only the file needed for the current task:

- `references/profile-and-context.md`: source-of-truth profile, official GPT-5.6 context facts, compact profile, and context-window caveats.
- `references/install-and-claude-config.md`: Docker/WSL install, OAuth import, Claude Code env/settings, dynamic MCP, and memory/rules configuration.
- `references/group-and-compact-routing.md`: sub2api group JSON, Claude model mapping, compact mapping, fallback SQL, and account credential patches.
- `references/subagent-terra-medium-profile.md`: current delegated-agent profile, exact files/env knobs to set, missing-override behavior, and future GPT-5.7 migration checklist.
- `references/verification.md`: health probes, Claude Code probes, `/v1/messages` checks, usage_logs queries, compact verification, and expected evidence.
- `references/troubleshooting.md`: 429/503/no-available-accounts, stale cooldowns, empty streams, context overflow, Luna availability, localhost relay, and usage-display bugs.
- `references/fullpower-profile.json`: machine-readable profile snapshot when scripts or exact config values are useful.

## Operating Rules

- Do not print OAuth tokens, API keys, refresh tokens, passwords, or copied auth files in chat.
- Do not wait for the user to catch persistence regressions. For every install, repair, Docker compose, Headroom, embedding-server, cache, Postgres, Redis, or "make reusable" task, proactively audit persistence before claiming done. The required proof is `docker inspect` showing `Type=bind` for Headroom `/root/.headroom`, `/root/.cache/headroom`, `/root/.cache/huggingface`, sub2api `/app/data`, Postgres parent `/var/lib/postgresql`, and Redis `/data`, plus `CCR_STORE True <nonzero>` after memory traffic. If any state path is a Docker named volume, fix the compose/profile/scripts first, recreate only the affected services, rerun `scripts/verify-claude-code-sub2api.ps1`, sync the local skill, commit, and push when repo changes were made.
- Prefer request-time `/v1/messages` probes and `usage_logs.upstream_model` over `/v1/models` catalog output.
- Keep Spark as Claude Code small-fast and compact first hop. While native Spark is quota-limited, keep Claude Code `ANTHROPIC_DEFAULT_HAIKU_MODEL` and `CLAUDE_CODE_SUBAGENT_MODEL` on `gpt-5.6-terra-medium` so delegated/default-Haiku paths do not accidentally hit Spark and do not inherit parent Sol/max. Set normal messages `model_fallbacks` so `gpt-5.6-terra-medium` falls back to `gpt-5.6-sol-medium` on empty-output or unavailable-model failures. Pin frequent subagents with frontmatter `model: gpt-5.6-terra-medium` and `effort: medium`.
- Keep Luna as the second hop after Spark for small-fast/Haiku and compact fallbacks, with `gpt-5.4-mini` as the last-resort fallback. Direct `gpt-5.6-luna` requests fall back to `gpt-5.3-codex-spark`, then `gpt-5.4-mini`.
- For Claude Code `general-purpose`, `Explore`, and `workflow-subagent`, use user-level overrides at `%USERPROFILE%\.claude\agents\*.md` with `model: gpt-5.6-terra-medium` and `effort: medium` while Spark is quota-limited. The `-medium` alias is intentional: patched sub2api strips it to upstream `gpt-5.6-terra` and records `reasoning_effort=medium`, overriding inherited parent `max`. If Terra returns a 0-visible-output turn, patched sub2api must preserve fallback effort aliases and switch to `gpt-5.6-sol-medium` (`reasoning_effort=medium`), not bare Sol/medium. Project-specific agents such as `agent-marketplace-agent` should get the same frontmatter when they fan out heavily. Verify with agent JSONL and `usage_logs.reasoning_effort`, not with the Claude UI label alone.
- Do not persist `CLAUDE_CODE_EFFORT_LEVEL` in Windows User/System env or `~/.claude/settings.json env`. It overrides Claude Code's interactive `/effort` command for every session. Use `effortLevel` only as a soft startup default, and prefer `xhigh` for the profile default so users can switch to `max`, `high`, or lower efforts in-session.
- Do not install a global `PreToolUse` / `SubagentStart` / `SubagentStop` hook that blocks Agent calls unless the user explicitly asks for it. Current policy is advisory only: `workflowSizeGuideline=small` plus the `general-purpose` prompt asks for no more than 10 sibling agents and no deep chains. Do not claim Claude Code has a reliable built-in depth cap that prevents hundreds of descendants; local evidence has shown a single parent line can grow into hundreds of spawned agents.
- Never describe `400000`, `370000`, or `340000` as the GPT-5.6 upstream/model context limit. These are Claude Code client compact/display targets. Current safe client profile is `CLAUDE_CODE_MAX_CONTEXT_TOKENS=370000` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=340000`; still verify real upstream failures from proxy logs before blaming context.
- Treat `stale fake 429/503` as a proxy state bug first: issue #1 fixed quota-origin cooldown recovery, so stale recurrence usually means an old image, stale container, or non-quota cooldown reason.
- For Docker-in-WSL, verify both Headroom and sub2api health plus the Windows route. If Windows cannot reach `127.0.0.1:8787` but WSL/Docker can, publish Headroom on `0.0.0.0` and use the WSL eth0 IP on port `8787`; do not point Claude Code directly at sub2api `18081` except as a temporary diagnostic bypass.
- Keep Headroom/RTK/lean-ctx/TokenSave binaries inside Docker for this profile. If `claude mcp list` shows `headroom` or `tokensave` pointing at missing `%USERPROFILE%\.local\bin\*.exe`, remove those stale user MCP entries. Re-add only `headroom` as a Docker-backed stdio server unless the user explicitly asks for a host install.
- Keep `--embedding-server` enabled. The Headroom image must build from `stgmt/headroom` by `HEADROOM_GIT_REPO/HEADROOM_GIT_REF`; the local patch scripts remain as idempotent guardrails for overridden refs. If startup logs show `Falling back to per-worker embedder`, rebuild from the fork-aware Dockerfile and verify the ref labels.
- Keep all service state on host bind mounts under `${SUB2API_STATE_ROOT:-./data}`. Headroom uses `headroom`, `headroom-cache`, and `headroom-huggingface`; sub2api uses `sub2api`; Postgres uses `postgres`; Redis uses `redis`. Do not replace these with Docker named volumes. Do not delete the state root unless the user explicitly wants to wipe memory, embeddings, accounts, database, and cache.
- Keep Windows autostart single-owner. Remove or disable stale `headroom-proxy` scheduled tasks and Startup-folder `sub2api/headroom` `.cmd` launchers. The surviving scheduled task must start the whole Docker compose project, not a host `headroom.exe`, and must be `RunLevel=Highest` when the start script includes WSL VHDX-lock self-heal.
- Keep the Headroom image bootstrap wrapper. `/usr/local/bin/start-headroom-proxy` seeds fresh persistent mounts from `/opt/headroom-seed` before starting `headroom proxy`, so a clean volume preserves memory without hiding bundled RTK/lean-ctx/difft/scc assets.
- Verify Headroom optimization with `docker exec headroom-sub2api headroom tools doctor`, `headroom savings --json`, and `headroom perf --format json`. A healthy stack should show bundled tools on PATH and nonzero proxy savings once traffic has passed through Headroom.
- After code changes, rebuild `sub2api-codex:local-token-usage` or the compose profile, recreate affected services under project `sub2api-codex`, then re-run live probes through Headroom.

## Workflow

1. Inspect current state: `~/.claude/settings.json`, User env, Docker container health, group mapping, account `credentials` compact mappings, and account `extra.model_rate_limits`.
2. If installing or repairing Docker/Claude config, read `references/install-and-claude-config.md` and use the bundled setup script.
3. If the task touches persistence, embeddings, caches, Docker volumes, compose, setup, or "reusable" docs, run the host-bind audit before and after changes. Do not accept Docker named volumes as equivalent to host persistence.
4. If changing models or compact routing, read `references/group-and-compact-routing.md` and patch both `groups.messages_dispatch_model_config` and `accounts.credentials`.
5. If debugging limits or errors, read `references/troubleshooting.md` before changing DB state. Preserve non-quota reasons such as `upstream_404_model_not_found` unless deliberately re-probing that model.
6. Verify with `references/verification.md`: Headroom health/upstream, host bind mounts, sub2api health, GPT-5.6 probes through Headroom, Claude alias probes, and `usage_logs` mapping evidence.
7. Update this skill only after live verification when a model lineup, context window, persistence layout, or proxy behavior changes.

## Bundled Scripts

- `scripts/setup-sub2api-claude-code.ps1`: create/update `deploy/claude-code-codex-headroom/.env`, start the Headroom + sub2api compose project, install/update the single Windows scheduled-task autostart unless `-SkipAutostart` is passed, register the Docker-backed Headroom MCP, remove stale host `tokensave` MCP, and configure Claude Code settings. Defaults to `gpt-5.6-sol`, `gpt-5.3-codex-spark`, `HEADROOM_SAVINGS_PROFILE=agent-90`, `HEADROOM_TARGET_RATIO=0.10`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS=370000`, and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=340000`.
- `scripts/verify-claude-code-sub2api.ps1`: verify Headroom health/upstream, host bind state mounts, persistent memory/cache mounts, embedding-server logs/socket/factory/direct embed probe, sub2api health, Claude Code settings, and expected upstream model behavior.
- `scripts/start-sub2api-proxy-stack.ps1`: idempotent scheduled-task target that starts the WSL Docker compose stack, refreshes Claude Code `ANTHROPIC_BASE_URL` from WSL IP when needed, and self-heals stale WSL VHDX attach locks.
- `scripts/install-sub2api-autostart-task.ps1`: installs the single `Sub2API Codex Proxy Stack Autostart` scheduled task with `RunLevel=Highest`, removes stale `headroom-proxy`, and disables Startup-folder proxy launchers.
- `scripts/install-claude-compact-recovery.ps1`: install Claude Code compact recovery hooks.
- `scripts/compact-recovery.mjs`: lightweight compact recovery hook implementation.

## Minimum Done Criteria

For install/config/debug tasks, do not call it done until these are true or explicitly blocked:

- `headroom-sub2api` and `sub2api-codex` containers are healthy.
- Headroom `/health` reports ready and upstream `http://sub2api:8080`.
- Headroom image has `/usr/local/bin/start-headroom-proxy` and `/opt/headroom-seed` so fresh persistent volumes are seeded without overwriting existing memory.
- Headroom embedding-server logs show `Embedding server: ready.`, no per-worker fallback or missing watchdog module, `/tmp/headroom-embed-8787.sock` exists, and the memory factory returns `headroom.memory.adapters.watchdog SocketEmbedderClient 384`.
- Headroom Claude Code streaming-overlap/watchdog patch is present and tested: `python deploy\claude-code-codex-headroom\test_headroom_claude_code_streaming_patch.py` passes, the installed handler has no `return JSONResponse(content=queued, status_code=202)`, an overlap probe logs `mid_turn_overlap_wait` / `mid_turn_overlap_wait_done` instead of returning private `headroom_queued` to Claude Code, and the handler watchdog live probe prints `WATCHDOG_RETRY_OK` proving a hung primary handler is retried once through Headroom bypass/passthrough before any 504 is returned.
- Headroom, sub2api, Postgres, and Redis state mounts are Docker `bind` mounts to host paths, not Docker named volumes; if memory traffic has already happened, `/root/.headroom/ccr_store.db` exists and is non-empty.
- On Windows/WSL installs, exactly one user autostart remains: `Sub2API Codex Proxy Stack Autostart`, `LastTaskResult=0`, `RunLevel=Highest`, action points at the canonical stack start script, and any old `headroom-proxy` task or Startup-folder launcher is absent/disabled.
- `claude mcp list` shows `headroom` connected through Docker, not a missing host executable; stale host `tokensave` MCP is removed unless deliberately installed on host.
- `docker exec headroom-sub2api headroom tools doctor` shows RTK-related bundled tools available, and `headroom savings --json` / `headroom perf --format json` prove the optimization layer is recording traffic.
- A tiny `/v1/messages` request through `http://127.0.0.1:8787` succeeds for `gpt-5.6-sol` and for Haiku/small-fast through `gpt-5.3-codex-spark` or the configured `gpt-5.6-luna -> gpt-5.4-mini` fallback chain, or a current upstream quota/cooldown blocker is proven as `429`.
- Claude aliases route as expected in `usage_logs` or response/model mapping evidence: Opus -> Sol, Sonnet -> Terra, Haiku -> Spark -> Luna -> mini.
- `~/.claude/settings.json` and User env agree on main/small models and Claude Code client context target.
- Any GitHub issue or fork change the user asked for is pushed and linked.

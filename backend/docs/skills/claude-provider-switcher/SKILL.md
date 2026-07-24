---
name: claude-provider-switcher
description: >-
  Switch every Claude Code traffic class between sub2api provider profiles across the Windows host and Hyper-V guests. Use when the user asks to move all main, compact, claude -p, SDK, picker-alias, and subagent traffic to the native Claude Code subscription or back to the current GPT/Qwen hybrid; audit the active provider, reconcile drift, repair stale model overrides, or prove that no forbidden fallback occurred. Triggers include "switch everything to Anthropic", "switch back to GPT and Qwen", "provider toggle", "anthropic-only", "hybrid-current", "claude-route status", and "переключи все модели".
---

# Claude Provider Switcher

Use this skill for provider-profile switching only. Use `sub2api-claude-code-codex` to install or repair the stack, and `headroom-sub2api-maintainer` for proxy source changes.

## Owned Contract

The switch covers every Claude Code path, not only the visible main model:

- interactive main and picker aliases;
- `/compact` and autocompact;
- `claude -p`, `--print`, and Agent SDK traffic;
- ordinary, named, nested, and workflow subagents;
- explicit stale GPT/Qwen model IDs from resumed sessions;
- Windows user env, `~/.claude/settings.json`, global agent frontmatter, launch wrappers, shell profiles, model caches, and status display.

The authoritative switch is the stable sub2api client key's group binding. Host and VM config synchronization makes new sessions and UI truthful, but an offline guest must not block or roll back the proxy-side switch.

## Profiles

- `anthropic-only`: route every traffic class to the imported native Claude Code subscription account. Block OpenAI and Alibaba fallback. Use the best enabled Opus-class model for main work, Sonnet-class for delegated work, and Haiku-class for compact/small-fast unless the live Anthropic account exposes a different supported set.
- `hybrid-current`: restore the versioned snapshot of the current mixed profile. At creation time this means GPT-5.6 Sol for main work and Qwen 3.8 Max high for picker aliases, compact, small-fast, SDK CLI, and delegated agents, with only the explicitly configured terminal-quota fallback.

Never infer a profile from Claude Code's statusline. Read the active key binding, group config, account membership, and persisted switch generation.

## Commands

The canonical controller must expose:

```text
claude-route status
claude-route anthropic
claude-route hybrid
claude-route reconcile
claude-route verify
```

If the controller is absent, do not emulate a partial switch by editing only `settings.json`. Implement or restore the repo-owned controller first.

Install or refresh the command from this skill bundle:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/install-claude-route.ps1
```

`status` reads the stable key binding and generation. `verify` sends unique main, stale-model, compact, and SDK CLI probes through Headroom and correlates only their tagged `usage_logs` rows.

## Switching Workflow

1. Load `references/profile-contract.md` and the requested profile snapshot.
2. Discover the Windows host plus both Hyper-V guests; never invent a VM name.
3. Validate Headroom, sub2api, the target provider account, OAuth expiry/scopes, and target model availability without printing credentials.
4. Capture the current stable-key group binding and fleet generation as rollback state.
5. Atomically rebind the stable client key to the target group and invalidate the relevant sub2api cache. Do not restart Headroom for a pure route switch.
6. Run one main live probe through Headroom before touching node display config. On failure, restore the old binding and report the exact layer.
7. Increment the profile generation and reconcile all reachable nodes with the OS-specific adapters from `references/fleet-reconcile.md`.
8. Mark offline nodes `pending-reconcile`; their next login/boot self-heal must apply the stored generation.
9. Restart only fresh Claude Code processes needed for proof. Do not kill unrelated user sessions.
10. Run the matrix in `references/verification.md` and prove the selected account/provider from usage logs.

## Safety Rules

- Never print, commit, or copy Claude OAuth credentials to client nodes. Import `%USERPROFILE%/.claude/.credentials.json` into sub2api once; VMs receive only the stable local proxy token.
- Prevent stale token re-import and `refresh_token_reused`; sub2api is the refresh owner after import.
- Re-import local Claude credentials only for a new account, an explicit forced repair, or a changed refresh-token fingerprint whose source expiry is newer than the stored import marker.
- Never enable cross-provider fallback in `anthropic-only`.
- Never claim success from `/v1/models`, health checks, settings files, or the Claude UI alone.
- Patch only owned model/env fields. Preserve hooks, MCP servers, permissions, agent bodies, and unrelated settings.
- A failed node reconcile is drift, not a failed provider switch, after proxy and live upstream proof succeeded.
- A failed target-provider probe before the commit point must leave the previous profile active.

## Reference Map

- `references/profile-contract.md`: profile and atomic-switch invariants.
- `references/fleet-reconcile.md`: Windows, Ubuntu Hyper-V, and Windows Hyper-V synchronization.
- `references/verification.md`: live proof, drift checks, rollback, and done criteria.

## Done Criteria

- The stable key resolves to the requested group and generation.
- Main, compact, `claude -p`, ordinary subagent, and nested subagent probes use only the requested provider family.
- Forbidden provider account IDs have zero new usage rows after the switch boundary.
- Every reachable node reports `synced` at the active generation; offline nodes report `pending-reconcile` with a working boot/login repair path.
- Switching to the other profile and back preserves unrelated Claude configuration and produces the same verified routing.
- If the inactive provider is rate-limited, its probe fails, the stable key is restored, and the old generation remains active.

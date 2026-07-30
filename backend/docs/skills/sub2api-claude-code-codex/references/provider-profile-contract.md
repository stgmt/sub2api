# Provider Profile Contract

## Control Plane

Use one stable client-facing sub2api API key and separate provider groups. Switching means atomically changing that key plus any known legacy fleet key to one group, then invalidating the key/group routing cache. The Windows host and both Hyper-V guests receive the same profile, generation, and stable key. Do not retain per-node provider overrides or rewrite Headroom's upstream URL.

Persist this state outside the container filesystem:

```json
{
  "active_profile": "anthropic-only",
  "generation": 1,
  "stable_key_id": 0,
  "active_group_id": 0,
  "previous_group_id": 0,
  "switched_at": "RFC3339",
  "proxy_verified_at": "RFC3339",
  "nodes": {}
}
```

IDs are discovered at runtime from stable names. Never hardcode IDs copied from one database.

## anthropic-only

- Account membership: only the imported native Claude Code subscription OAuth account.
- Main/picker Opus/Fable: highest enabled Opus-class model.
- Sonnet/delegated/SDK CLI/compact/small-fast/Haiku picker compatibility: enabled Sonnet-class model.
- Haiku is not used by automatic routes because Claude Code can inherit `output_config.effort` plus adaptive thinking, which Haiku 4.5 rejects. Stale Spark/Luna/mini/Haiku IDs therefore force-map to Sonnet before provider classification.
- Explicit stale `gpt-*`, `qwen*`, `glm*`, and `deepseek*` requests: force-map to the matching Claude role before provider classification.
- Fallbacks: empty. OpenAI and Alibaba accounts must not be group members.

Discover the actual supported Claude model IDs from the live account and request probes. Keep role mapping versioned so a future model-line update does not require changing every client node first.

Version 4 pins raw server-side Opus `claude-opus-5`, Fable `claude-fable-5`, and Sonnet `claude-sonnet-5`. Legacy Opus 4.8 inputs upgrade to Opus 5. Compact resolves to Sonnet 5 with `compact_reasoning_effort=low`, while small-fast, delegated, SDK CLI, Haiku compatibility, and stale low-tier GPT/Qwen IDs resolve to Sonnet 5/high. On the Claude Code side, Opus and Sonnet IDs carry `[1m]`, while both `CLAUDE_CODE_MAX_CONTEXT_TOKENS` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` are `1000000`. This is required behind an LLM gateway: Claude Code strips the suffix before transport but uses it for the local context budget. Use Claude Code 2.1.219 or later for Opus 5. Update the versioned profile and its verification expectations together when the enabled line changes.

The local `~/.claude/.credentials.json` is an import source, not the long-term refresh owner. Store a SHA-256 refresh-token fingerprint and source expiry in account `extra`; do not reapply an older unchanged source after sub2api has refreshed its own token.

## hybrid-current

The profile is a versioned snapshot, not an informal restoration guess. Version 2 is a managed group snapshot whose contract is:

- main: `gpt-5.6-sol`, user-selected effort preserved;
- built-in Plan: `gpt-5.6-sol`, effort `high`;
- picker Opus/Fable/Sonnet/Haiku: `qwen3.8-max-preview`, effort high;
- compact/small-fast/subagents/SDK CLI: `qwen3.8-max-preview`, effort high. This includes built-in `Explore` children: they enter through the SDK CLI route and may ignore user-level `Explore.md` plus `CLAUDE_CODE_SUBAGENT_MODEL`;
- provider membership: OpenAI/Codex OAuth plus Alibaba Token Plan;
- automatic fallback: only the existing terminal Alibaba subscription-quota route to `gpt-5.6-sol` for automatic compact/SDK/delegated traffic;
- native Anthropic account: not a member of the hybrid group unless a later profile version explicitly says so.

Before modifying the hybrid profile, save a new version. A switch back must restore the recorded profile version exactly.

## qwen-only

- account membership: only `alibaba-token-plan-anthropic`;
- main, all picker aliases, compact, Plan, small-fast, SDK CLI, and every global/delegated agent: `qwen3.8-max-preview`, effort `high`;
- stale GPT, Claude, GLM, DeepSeek, and older Qwen identifiers: exact-map to `qwen3.8-max-preview` before provider classification;
- model and provider fallbacks: empty;
- explicit model catalog: only `qwen3.8-max-preview`.

## chatgpt-only

Version 4 is a separate managed group, not a mutation of `hybrid-current`:

- account membership: only `codex-chatgpt-subscription` (`openai`, `oauth`);
- main/Opus: `gpt-5.6-sol`; Fable/Sonnet/Haiku/small-fast: `gpt-5.6-terra-medium`;
- every global agent and structurally verified Agent SDK child: `gpt-5.6-terra-medium`, effort `medium`;
- built-in Plan: `gpt-5.6-sol`, effort `high`;
- compact: `gpt-5.6-terra-medium`, effort `medium`, selected only by Headroom's trusted compact header;
- model fallbacks and fallback groups: empty;
- explicit model catalog: GPT/Codex only;
- stale Luna, Claude, Qwen, GLM, and DeepSeek IDs plus direct raw `gpt-5.6-terra`: exact-map to Terra-medium or the matching GPT role before provider classification; raw Terra is not published;
- client context target: `370000`; auto-compact threshold: `340000`;
- remove persistent `CLAUDE_CODE_EFFORT_LEVEL`; preserve the user's interactive `effortLevel` and `/effort` selection.

Before preparing this group, atomically synchronize a validated host `~/.codex/auth.json` into the actual host-bound WSL state path. Compare SHA-256 after copy and never print token data. The first Headroom Sol probe is allowed to trigger sub2api's auth-file recovery, but the switch commits only after the account is `active`, schedulable, and the usage row names account `codex-chatgpt-subscription`.

## Transaction Boundary

1. Prepare and validate the inactive group.
2. Save previous binding.
3. Rebind the stable key and every known legacy fleet key to the same group.
4. Invalidate routing cache.
5. Probe through Headroom.
6. Commit profile generation on success; restore the previous binding on failure.

Node reconciliation happens after step 6 and cannot silently alter the active proxy profile.

The controller persists this state under the host-bound runtime `data/provider-route-state.json`, never in a container layer.

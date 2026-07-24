# Provider Profile Contract

## Control Plane

Use one stable client-facing sub2api API key and separate provider groups. Switching means atomically changing that key's group binding, then invalidating the key/group routing cache. Do not rotate the client token and do not rewrite Headroom's upstream URL.

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
- Sonnet/delegated/SDK CLI: enabled Sonnet-class model.
- Haiku/compact/small-fast: enabled Haiku-class model.
- Explicit stale `gpt-*`, `qwen*`, `glm*`, and `deepseek*` requests: force-map to the matching Claude role before provider classification.
- Fallbacks: empty. OpenAI and Alibaba accounts must not be group members.

Discover the actual supported Claude model IDs from the live account and request probes. Keep role mapping versioned so a future model-line update does not require changing every client node first.

## hybrid-current

The profile is a versioned snapshot, not an informal restoration guess. Its initial contract is:

- main: `gpt-5.6-sol`, user-selected effort preserved;
- picker Opus/Fable/Sonnet/Haiku: `qwen3.8-max-preview`, effort high;
- compact/small-fast/subagents/SDK CLI: `qwen3.8-max-preview`, effort high;
- provider membership: OpenAI/Codex OAuth plus Alibaba Token Plan;
- automatic fallback: only the existing terminal Alibaba subscription-quota route to `gpt-5.6-sol` for automatic compact/SDK/delegated traffic;
- native Anthropic account: not a member of the hybrid group unless a later profile version explicitly says so.

Before modifying the hybrid profile, save a new version. A switch back must restore the recorded profile version exactly.

## Transaction Boundary

1. Prepare and validate the inactive group.
2. Save previous binding.
3. Rebind the stable key in one database/API transaction.
4. Invalidate routing cache.
5. Probe through Headroom.
6. Commit profile generation on success; restore the previous binding on failure.

Node reconciliation happens after step 6 and cannot silently alter the active proxy profile.


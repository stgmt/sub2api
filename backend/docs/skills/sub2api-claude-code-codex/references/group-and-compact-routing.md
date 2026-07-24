# Group And Compact Routing

sub2api OpenAI group JSON, Claude model mapping, Qwen compact routing, fallback SQL, and compact-only routing configuration.

## sub2api Mixed-Provider Group Profile

Create or update one Claude Code group named something like:

```text
codex-gpt56-claude-code
```

Use these fields. The group is still fronted by the Anthropic-compatible
`/v1/messages` endpoint, but patched sub2api classifies each requested model at
request time and forces the right provider platform:

```json
{
  "platform": "openai",
  "allow_messages_dispatch": true,
  "require_oauth_only": false,
  "default_mapped_model": "gpt-5.6-sol",
  "messages_dispatch_model_config": {
    "opus_mapped_model": "qwen3.8-max-preview",
    "sonnet_mapped_model": "qwen3.8-max-preview",
    "haiku_mapped_model": "qwen3.8-max-preview",
    "sdk_cli_mapped_model": "qwen3.8-max-preview",
    "sdk_cli_reasoning_effort": "high",
    "exact_model_mappings": {
      "opus": "qwen3.8-max-preview",
      "fable": "qwen3.8-max-preview",
      "sonnet": "qwen3.8-max-preview",
      "haiku": "qwen3.8-max-preview",
      "claude-opus-4-8": "qwen3.8-max-preview",
      "claude-sonnet-4-6": "qwen3.8-max-preview",
      "claude-haiku-4-5": "qwen3.8-max-preview",
      "claude-haiku-4-5-20251001": "qwen3.8-max-preview",
      "gpt-5.3-codex-spark": "gpt-5.3-codex-spark",
      "gpt-5.6": "gpt-5.6-sol",
      "gpt-5.6-sol": "gpt-5.6-sol",
      "gpt-5.6-terra": "gpt-5.6-terra",
      "gpt-5.6-terra-medium": "gpt-5.6-terra",
      "gpt-5.6-luna": "gpt-5.6-luna",
      "gpt-5.5[400k]": "gpt-5.5",
      "gpt-5.5": "gpt-5.5"
    },
    "compact_mapped_model": "qwen3.8-max-preview",
    "model_fallbacks": {
      "qwen3.8-max-preview": ["gpt-5.6-sol"]
    }
  },
  "models_list_config": {
    "enabled": true,
    "explicit": true,
    "models": [
      "gpt-5.6-sol",
      "gpt-5.6-terra",
      "gpt-5.6-luna",
      "gpt-5.6-terra-medium",
      "gpt-5.6",
      "gpt-5.3-codex-spark",
      "gpt-5.3-codex-spark-fast",
      "gpt-5.3-codex",
      "gpt-5.3-codex-fast",
      "gpt-5.5",
      "gpt-5.5-fast",
      "gpt-5.4",
      "gpt-5.4-fast",
      "gpt-5.4-mini",
      "gpt-5.4-mini-fast",
      "gpt-5.2",
      "gpt-5.2-fast",
      "qwen3.8-max-preview",
      "qwen3.7-max",
      "qwen3.7-plus",
      "qwen3.6-flash",
      "glm-5.2",
      "deepseek-v4-pro"
    ]
  }
}
```

Routing contract:

- GPT/Codex IDs route to the OpenAI/Codex OAuth account and may use GPT effort suffixes such as `-medium`.
- Alibaba Token Plan IDs (`qwen3.8-max-preview`, `qwen3.7-max`, `qwen3.7-plus`, `qwen3.6-flash`, `glm-5.2`, `deepseek-v4-pro`) route to a dedicated account with `platform='anthropic'`, `base_url='https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic'`, and Bearer auth.
- Do not publish raw Claude/Fable names (`fable`, `opus`, `sonnet`, `haiku`, `claude-*`) in this local profile. Keep the hidden exact/family mappings above as compatibility inputs for stale Claude hosts and already-running sessions; they route to Qwen high without adding those aliases to `/v1/models`. Claude Code Opus/Fable/Sonnet/Haiku picker slots should still point to Qwen high (`qwen3.8-max-preview`).
- Mixed-provider routing must apply an explicit Claude alias mapping before provider classification. Otherwise `claude-haiku-4-5-20251001` is sent to native Anthropic passthrough, bypasses the group mapping, and returns a fast `404 no available accounts` even though the Qwen account is healthy.
- The configured `qwen3.8-max-preview -> gpt-5.6-sol` entry is a candidate, not an unconditional provider fallback. sub2api consumes it only for automatic compact/SDK-CLI routes after the exact terminal Token Plan quota body or while every matching Qwen account has that persisted quota circuit open. A selected healthy Qwen stays on Alibaba; ordinary scheduler misses, direct interactive Qwen, transient 429/5xx, context/auth/model errors, and failures after stream bytes remain on the original route.
- `sdk_cli_mapped_model=qwen3.8-max-preview` plus `sdk_cli_reasoning_effort=high` covers every Claude SDK process whose inbound User-Agent contains `claude-cli/... (external, sdk-cli...)`: real `Agent(...)` children, Agent SDK workers, and standalone `claude -p/--print`. This rule intentionally wins over an explicit GPT model in print mode. It must not match the interactive `(external, cli)` User-Agent, so the normal picker and `/model` remain usable.
- Token Plan pricing may be absent from public pricing catalogs. The fork uses an explicit unknown-cost fallback for the listed Token Plan chat models so usage accounting succeeds without logging `pricing not found`.

If exact admin API endpoints differ across sub2api versions, use the admin UI and match these field names. The important fields in current sub2api are `allow_messages_dispatch`, `require_oauth_only`, `default_mapped_model`, and `messages_dispatch_model_config`.

Legacy OpenAI-only compact routing still exists on the OpenAI/Codex OAuth account credentials, but the current Qwen profile keeps it empty. Do not use account-level `compact_model_mapping` as the primary route because it happens after OpenAI account selection and cannot safely jump to an Alibaba Token Plan model. If an old install still contains Spark/Luna mappings there, clear them when enabling Qwen high compact:

```json
{
  "compact_model_mapping": {},
  "compact_model_fallbacks": {}
}
```

The native Claude Code compact route also depends on the paired Headroom
contract. Headroom detects the compact instruction before compression, restores
the exact final message after transforms, skips output shaping, and sends
`x-sub2api-claude-compact: 1`. sub2api accepts that header as authoritative.
For mixed-provider Qwen compact routing, sub2api rewrites the Anthropic
`/v1/messages` request body model to `qwen3.8-max-preview` before route
classification. Do not rely only on matching prompt text after Headroom
optimization.

Qwen high compact uses the normal Alibaba Token Plan Anthropic-compatible path
and keeps `reasoning_effort=high`. It does not use Spark's no-effort special
case. If the provider reports terminal Token Plan exhaustion, the proxy persists
the reset time, prevents repeat probes until that time, and retries this
automatic compact once on `gpt-5.6-sol` with `high` effort.

Spark does not expose a configurable reasoning effort. Legacy Spark compact must
remove `reasoning.effort` instead of clamping inherited Sol/Terra `max` to
`xhigh` or `low`. This applies to the first mapped request and every Spark
chunk/merge fallback request. Luna retains its own configured fallback effort.

Spark does not accept image inputs. If an otherwise valid compact transcript
contains image blocks, the exact Spark HTTP 400 (`does not support image
inputs`) is treated as compact-model unavailability and the configured
`gpt-5.6-luna` fallback performs the compact.

For the local Docker/Postgres install, patch the field without exposing tokens:

```powershell
$skill = "backend/docs/skills/sub2api-claude-code-codex/scripts"
powershell -ExecutionPolicy Bypass -File "$skill/sync-sub2api-sdk-cli-routing.ps1"

$sql = @'
update groups
set messages_dispatch_model_config = jsonb_set(jsonb_set(jsonb_set(jsonb_set(
  coalesce(messages_dispatch_model_config, '{}'::jsonb),
  '{compact_mapped_model}', '"qwen3.8-max-preview"'::jsonb, true),
  '{sdk_cli_mapped_model}', '"qwen3.8-max-preview"'::jsonb, true),
  '{sdk_cli_reasoning_effort}', '"high"'::jsonb, true),
  '{model_fallbacks,qwen3.8-max-preview}', '["gpt-5.6-sol"]'::jsonb, true),
  updated_at = now()
where platform='openai' and allow_messages_dispatch=true;

update accounts
set credentials = jsonb_set(
  jsonb_set(coalesce(credentials, '{}'::jsonb), '{compact_model_mapping}', '{}'::jsonb, true),
  '{compact_model_fallbacks}',
  '{}'::jsonb,
  true
), updated_at = now()
where platform='openai';
'@
wsl.exe -- docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -v ON_ERROR_STOP=1 -c $sql
```

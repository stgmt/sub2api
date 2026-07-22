# Group And Compact Routing

sub2api OpenAI group JSON, Claude model mapping, compact_model_mapping, fallback SQL, and compact-only routing configuration.

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
    "exact_model_mappings": {
      "gpt-5.3-codex-spark": "gpt-5.3-codex-spark",
      "gpt-5.6": "gpt-5.6-sol",
      "gpt-5.6-sol": "gpt-5.6-sol",
      "gpt-5.6-terra": "gpt-5.6-terra",
      "gpt-5.6-terra-medium": "gpt-5.6-terra",
      "gpt-5.6-luna": "gpt-5.6-luna",
      "gpt-5.5[400k]": "gpt-5.5",
      "gpt-5.5": "gpt-5.5"
    },
    "model_fallbacks": {}
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
- Do not publish raw Claude/Fable names (`fable`, `opus`, `sonnet`, `haiku`, `claude-*`) in this local profile. Claude Code Opus/Fable/Sonnet picker slots are env aliases and should point to Qwen high (`qwen3.8-max-preview`).
- Keep normal message `model_fallbacks` empty unless the user explicitly asks for model fallback. Compact fallback is configured on the OpenAI/Codex account separately.
- Token Plan pricing may be absent from public pricing catalogs. The fork uses an explicit unknown-cost fallback for the listed Token Plan chat models so usage accounting succeeds without logging `pricing not found`.

If exact admin API endpoints differ across sub2api versions, use the admin UI and match these field names. The important fields in current sub2api are `allow_messages_dispatch`, `require_oauth_only`, `default_mapped_model`, and `messages_dispatch_model_config`.

Also set compact-only mapping on the OpenAI/Codex OAuth account credentials, not only on the group:

```json
{
  "compact_model_mapping": {
    "gpt-5.6": "gpt-5.3-codex-spark",
    "gpt-5.6-sol": "gpt-5.3-codex-spark",
    "gpt-5.6-terra": "gpt-5.3-codex-spark",
    "gpt-5.6-luna": "gpt-5.3-codex-spark",
    "gpt-5.5": "gpt-5.3-codex-spark",
    "gpt-5.5[400k]": "gpt-5.3-codex-spark",
    "gpt-5.4": "gpt-5.3-codex-spark",
  },
  "compact_model_fallbacks": {
    "gpt-5.3-codex-spark": ["gpt-5.6-luna"],
    "gpt-5.6": ["gpt-5.6-luna"],
    "gpt-5.6-sol": ["gpt-5.6-luna"],
    "gpt-5.6-terra": ["gpt-5.6-luna"],
    "gpt-5.6-luna": ["gpt-5.3-codex-spark"],
    "gpt-5.5": ["gpt-5.6-luna"],
    "gpt-5.5[400k]": ["gpt-5.6-luna"],
    "gpt-5.4": ["gpt-5.6-luna"]
  }
}
```

The native Claude Code compact route also depends on the paired Headroom
contract. Headroom detects the compact instruction before compression, restores
the exact final message after transforms, skips output shaping, and sends
`x-sub2api-claude-compact: 1`. sub2api accepts that header as authoritative.
Do not rely only on matching prompt text after Headroom optimization.

Spark does not expose a configurable reasoning effort. The compact route must
remove `reasoning.effort` instead of clamping inherited Sol/Terra `max` to
`xhigh` or `low`. This applies to the first mapped request and every Spark
chunk/merge fallback request. Luna retains its own configured fallback effort.

Spark does not accept image inputs. If an otherwise valid compact transcript
contains image blocks, the exact Spark HTTP 400 (`does not support image
inputs`) is treated as compact-model unavailability and the configured
`gpt-5.6-luna` fallback performs the compact.

For the local Docker/Postgres install, patch the field without exposing tokens:

```powershell
$sql = @'
update accounts
set credentials = jsonb_set(
  jsonb_set(
    coalesce(credentials, '{}'::jsonb),
    '{compact_model_mapping}',
    '{"gpt-5.6":"gpt-5.3-codex-spark","gpt-5.6-sol":"gpt-5.3-codex-spark","gpt-5.6-terra":"gpt-5.3-codex-spark","gpt-5.6-luna":"gpt-5.3-codex-spark","gpt-5.5":"gpt-5.3-codex-spark","gpt-5.5[400k]":"gpt-5.3-codex-spark","gpt-5.4":"gpt-5.3-codex-spark"}'::jsonb,
    true
  ),
  '{compact_model_fallbacks}',
    '{"gpt-5.3-codex-spark":["gpt-5.6-luna"],"gpt-5.6":["gpt-5.6-luna"],"gpt-5.6-sol":["gpt-5.6-luna"],"gpt-5.6-terra":["gpt-5.6-luna"],"gpt-5.6-luna":["gpt-5.3-codex-spark"],"gpt-5.5":["gpt-5.6-luna"],"gpt-5.5[400k]":["gpt-5.6-luna"],"gpt-5.4":["gpt-5.6-luna"]}'::jsonb,
  true
), updated_at = now()
where platform='openai';
'@
wsl.exe -- docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -v ON_ERROR_STOP=1 -c $sql
```

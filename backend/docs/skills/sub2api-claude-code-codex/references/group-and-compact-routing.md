# Group And Compact Routing

sub2api OpenAI group JSON, Claude model mapping, compact_model_mapping, fallback SQL, and compact-only routing configuration.

## sub2api Group Profile

Create or update one OpenAI group named something like:

```text
codex-gpt56-claude-code
```

Use these fields:

```json
{
  "platform": "openai",
  "allow_messages_dispatch": true,
  "require_oauth_only": true,
  "default_mapped_model": "gpt-5.6-sol",
  "messages_dispatch_model_config": {
    "opus_mapped_model": "gpt-5.6-sol",
    "sonnet_mapped_model": "gpt-5.6-terra",
    "haiku_mapped_model": "gpt-5.3-codex-spark",
    "exact_model_mappings": {
      "claude-opus-4-8": "gpt-5.6-sol",
      "claude-opus-4-8[1m]": "gpt-5.6-sol",
      "claude-opus-4-7": "gpt-5.6-sol",
      "claude-sonnet-4-6": "gpt-5.6-terra",
      "claude-haiku-4-5": "gpt-5.3-codex-spark",
      "claude-haiku-4-5-20251001": "gpt-5.3-codex-spark",
      "opus": "gpt-5.6-sol",
      "sonnet": "gpt-5.6-terra",
      "haiku": "gpt-5.3-codex-spark",
      "gpt-5.3-codex-spark": "gpt-5.3-codex-spark",
      "gpt-5.6": "gpt-5.6-sol",
      "gpt-5.6-sol": "gpt-5.6-sol",
      "gpt-5.6-terra": "gpt-5.6-terra",
      "gpt-5.6-luna": "gpt-5.6-luna",
      "gpt-5.5[400k]": "gpt-5.5",
      "gpt-5.5": "gpt-5.5"
    },
    "model_fallbacks": {
      "gpt-5.3-codex-spark": ["gpt-5.6-luna"],
      "claude-haiku-*": ["gpt-5.6-luna"],
      "haiku": ["gpt-5.6-luna"],
      "gpt-5.6-terra-medium": ["gpt-5.6-sol-medium"],
      "gpt-5.6-luna": ["gpt-5.3-codex-spark"]
    }
  }
}
```

The `gpt-5.6-terra-medium -> gpt-5.6-sol-medium` fallback depends on patched sub2api preserving effort suffixes in `model_fallbacks` while normalizing the routing model for account selection. Without that patch, Sol fallback can silently inherit the wrong parent effort.

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

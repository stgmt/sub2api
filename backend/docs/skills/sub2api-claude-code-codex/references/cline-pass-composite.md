# Cline Pass composite route

This reference describes the repeatable Cline Pass integration for the local
Headroom + sub2api stack. It is intentionally about the runtime contract, not
about copying credentials into chat or source control.

## Source and protocol

- Source: `%USERPROFILE%\.cline\data\settings\providers.json`
- Cline profile: `providers.cline-pass.settings.auth`
- Upstream base URL: `https://api.cline.bot/api/v1`
- Protocol: OpenAI-compatible chat/completions
- Authentication: the installed Cline runtime sends the access token as a
  bearer token with the `workos:` prefix.
- Cline metadata headers are stored as safe account header overrides:
  `HTTP-Referer`, `X-Title`, `X-IS-MULTIROOT`, `X-CLIENT-TYPE`,
  `X-CLIENT-VERSION`, `X-PLATFORM`, `X-PLATFORM-VERSION`, `X-CORE-VERSION`,
  and `User-Agent`.

The sync reads the local session and never prints `accessToken` or
`refreshToken`. When the stored access credential is expired or within five
minutes of expiry, it calls Cline's native JSON refresh endpoint with the same
metadata headers, atomically updates the local Cline provider file, and then
syncs the new pair into sub2api. This is a refresh-token flow, not a browser
reauthorization. If refresh fails or the local session disappears, the
watchdog reports `expired`/`missing` and preserves the last DB credential
instead of replacing it with an empty value.

## Composite group

The account is `cline-pass-subscription`, platform `openai`, type `apikey`, and
is bound to `headroom-openai-grok-composite`. That group must not have
`require_oauth_only=true`: this flag is an account-admission filter, so it
would reject a valid Cline API-key account before model routing. The group
keeps explicit model allowlisting and contains the existing Codex/Grok models
plus these exact ClinePass IDs:

```text
cline-pass/qwen3.8-max
poolside/laguna-s-2.1:free
cline-pass/kimi-k3
cline-pass/minimax-m3
cline-pass/deepseek-v4-flash
cline-pass/deepseek-v4-pro
deepseek/deepseek-v4-flash
cline-pass/mimo-v2.5
cline-pass/mimo-v2.5-pro
cline-pass/glm-5.3
```

The sync also adds the same IDs to the DSH `head` provider in
`%USERPROFILE%\.dsh\settings.yaml`, with context-window metadata from the
installed Cline catalog. The composite API key remains the only key that DSH
needs; the Cline WorkOS credential is stored only inside sub2api's managed
account.

## DSH effort picker

DSH does not infer effort choices from the gateway's `/v1/models` response.
Its `llm.models` catalog only exposes a picker when a model entry declares
`reasoningEfforts`, and the selected value is sent as the provider's native
reasoning control. The managed composite catalog therefore declares:

| Model | DSH choices | Wire field |
| --- | --- | --- |
| `grok-4.6` | `low`, `medium`, `high` | `reasoning.effort` |
| `grok-4.5` | `low`, `medium`, `high` | `reasoning.effort` |
| `gpt-5.6-luna` | `low`, `medium`, `high`, `xhigh`, `max` | `reasoning.effort` |

The Grok levels follow xAI's Responses contract; `xhigh` and `max` are not
advertised for Grok. The declaration is maintained by
`scripts/sync-cline-pass-auth.ps1`, so a Cline catalog refresh keeps the
effort picker instead of reverting to context-only model entries. DSH reads
the settings on the next catalog refresh; no sub2api rebuild is needed for
this client-side metadata change.

## Operations

```powershell
# Read-only source/auth check; prints metadata only.
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-cline-pass-auth.ps1 -CheckOnly

# Reconcile Cline auth, sub2api group/account, and DSH model catalog.
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-cline-pass-auth.ps1

# Deterministic refresh proof; still does not open a browser or print secrets.
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\sync-cline-pass-auth.ps1 -ForceRefresh -NoRestart

# Contract test with a synthetic nested providers.json and fake secrets.
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-cline-pass-auth-sync.ps1
```

After a credential/group change, the script restarts only `sub2api-codex` and
waits for its Docker health check. Headroom is not recreated. Verify the live
route with a tiny request through `http://127.0.0.1:8787/v1`, then correlate
`usage_logs.account_id`, `requested_model`, `upstream_model`, and the Cline
account name. A successful `/v1/models` listing alone is insufficient proof
that a completion used Cline.

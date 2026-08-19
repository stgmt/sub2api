# Grok Build + OpenAI Composite

This profile uses the existing Grok Build CLI login on the Windows host. It does
not start a second OAuth flow and does not copy the host auth file into Git or
into the Headroom image.

## Sources and boundaries

- Source: `%USERPROFILE%\.grok\auth.json`.
- Grok Build subscription endpoint: `https://cli-chat-proxy.grok.com/v1`.
- Managed sub2api account: `grok-build-subscription`, platform `grok`.
- Mixed group: `headroom-openai-grok-composite`.
- OpenAI/Codex remains a separate `openai` OAuth account in the same mixed group.
- Headroom remains protocol-neutral: clients send to `http://127.0.0.1:8787/v1`,
  while sub2api selects the account by model and group policy.

The normal OpenAI-only key remains valid for Claude Code. DSH uses the separate
composite key so its `/v1/models` and Responses calls can see both families.
Do not replace the OpenAI-only key globally just to add Grok.

## Durable sync

`scripts/sync-grok-build-auth.ps1` reads the dynamic top-level entry in the
local Grok auth file, persists only the provider credential fields into the
managed Grok account through the scoped provider-sync API, clears stale
account-error and temporary-unschedulable state, and invalidates scheduler
state without restarting `sub2api-codex`. Direct SQL, admin login, and
restart-based credential synchronization are forbidden.
The sync is fail-soft when the local file is missing: OpenAI traffic stays
available and the watchdog records a redacted status event.

`ensure-sub2api-proxy-stack.ps1` calls this sync on every health tick. The setup
script calls it after Docker is up. No token values are written to logs.

`scripts/sync-dsh-composite-key.ps1` resolves the active key by the composite
group name and updates only the local DSH `HEAD_API_KEY` slot. It never prints
the key. The DSH provider must use:

```text
api: openai-responses
baseURL: http://127.0.0.1:8787/v1
```

`sync-cline-pass-auth.ps1` also reconciles the shared DSH model catalog. Grok
4.6 and 4.5 must remain at `contextWindow: 500000`: the live Grok Responses
endpoint rejects prompts above 500k. Do not advertise the generic 1M window
for these two models.

## Live acceptance proof

Use the composite key and correlate the response with `usage_logs`:

1. `/v1/models` returns the mixed catalog, including the GPT/Codex and Grok
   IDs explicitly enabled by the group.
2. A `gpt-5.6-luna` Responses request returns HTTP 200 and a usage row with
   `account=codex-chatgpt-subscription`, `platform=openai`.
3. A `grok-4.6` Responses request with `reasoning.effort=high` returns HTTP 200
   and a usage row with `account=grok-build-subscription`, `platform=grok`,
   and `reasoning_effort=high`.
4. The two rows use the same Headroom inbound endpoint and the same composite
   group, proving that this is one stack with provider-aware account routing,
   not a second proxy or a fallback disguised as success.

The public model catalog is an allow-list, not a claim that every provider
model accepts every effort. Verify effort per model from `usage_logs` and the
upstream response; keep Grok's subscription model IDs separate from OpenAI
model IDs.

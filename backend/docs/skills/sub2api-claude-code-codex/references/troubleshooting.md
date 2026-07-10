# Troubleshooting Playbook

Known failure signatures and fixes for routing, empty streams, context overflow, 429/503 cooldowns, Luna availability, and usage display issues.

## Contents

- [Troubleshooting](#troubleshooting)

## Troubleshooting

If `/context` still shows `/200k`:

- Ensure `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is present in both User env and `~/.claude/settings.json`.
- Ensure `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is below the official/proven upstream window. For the current GPT-5.6 profile, `400000` is only a conservative Claude Code client target, not the model window; raise toward the official 1,050,000 only after a live long-context probe through the same proxy/account.
- Restart the terminal. Current shells do not automatically receive newly written User env values.

If requests do not hit sub2api:

- Check current-process env, not only User env:
  ```powershell
  $env:ANTHROPIC_BASE_URL
  [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User")
  ```
- Old shells may still point at a previous proxy such as `http://127.0.0.1:8787`.
- Start Claude Code only after setting current shell env or after opening a new terminal.
- On Docker-in-WSL, check Windows routing separately. A stuck `wslrelay.exe` can accept TCP on `127.0.0.1:18081` and never forward the HTTP response. Symptoms: Claude Code thinks for 40-120 seconds, no new `usage_logs` rows appear, `wsl.exe -- curl http://127.0.0.1:18081/health` works, but Windows `curl.exe http://127.0.0.1:18081/health` hangs.
- In that case, set runtime `.env` `BIND_HOST=0.0.0.0`, recreate the `sub2api` service, and set `ANTHROPIC_BASE_URL` to the current WSL eth0 IP:
  ```powershell
  $wslIp = (wsl.exe -- bash -lc "ip -4 addr show eth0 | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1").Trim()
  [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", "http://$wslIp:18081", "User")
  ```

If sub2api returns unknown model:

- Add exact mappings for the requested model, especially `claude-opus-4-8`, `claude-opus-4-8[1m]`, and `gpt-5.5[400k]`.
- Confirm `allow_messages_dispatch=true` on the OpenAI group.

If count-tokens logs show upstream `401`:

- sub2api may fall back to local token estimation. This is usually not fatal if `/v1/messages` requests succeed and usage logs show the expected route such as `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.3-codex-spark`, `gpt-5.6-luna` as Spark fallback, or `gpt-5.4-mini` as final fallback.

If Claude Code shows empty answers, "previous response had no visible output", or sub2api logs show `0/0` usage:

- Query `usage_logs` for `stream=true AND input_tokens=0 AND output_tokens=0 AND duration_ms BETWEEN 500 AND 30000`.
- If the affected rows are `gpt-5.6-sol`, `gpt-5.3-codex-spark`, `gpt-5.6-luna` Spark fallback, `gpt-5.4-mini` final fallback, `gpt-5.5`, or legacy `gpt-5.5[400k]` with weaker reasoning than expected, restart or fork the old Claude Code session with `--model gpt-5.6-sol --effort max`; new max requests should log the strongest supported effort for this route.
- Ensure User env and `~/.claude/settings.json` contain `MAX_THINKING_TOKENS=8000`, but do not treat it as the Codex reasoning control. For Codex, verify `reasoning_effort=xhigh` in sub2api logs.
- Avoid ending a turn with a background shell command that produces no stdout. Claude Code has a known "no visible output" retry loop around empty tool output; emit a visible summary after background tasks.
- A 0/0 row with HTTP 200 can be a Codex ghost stream. Do not solve it by switching Claude Code to `claude-opus-*` if the user needs the Codex route. Fix the proxy path first, then verify the real upstream context limit from logs.
- The local patched `sub2api-codex:local-token-usage` image buffers initial Anthropic SSE events until real text/tool output appears. If upstream completes with no visible text/tool output, the proxy returns a retryable upstream failure instead of a successful empty `message_stop`.
- If logs show `openai_messages.upstream_failover_switching` after an empty stream, that is expected: the guard caught the ghost response and retried instead of letting Claude Code stop empty.
- If logs show `timeout waiting for account concurrency slot` or Claude Code reports `API Error: Concurrency limit exceeded for account`, raise the OpenAI/Codex account `accounts.concurrency` from the default 3/12 to 32 for a multi-window local setup:
  ```powershell
  wsl.exe -- docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -c "update accounts set concurrency=32, updated_at=now() where platform='openai';"
  ```
- Restart the `sub2api` container after changing account concurrency if slot errors continue; the running process may still have cached account config.

If Claude Code reports `API Error: Upstream service temporarily unavailable`:

- First check whether the real upstream error is hidden behind a generic proxy message. Patched local sub2api logs `openai_messages.stream_completed_without_visible_output` and includes fields such as `estimated_input_tokens`, `terminal_error_code`, `terminal_incomplete_reason`, `responses_event_types`, and `terminal_usage_input_tokens`.
- If `terminal_error_code=context_length_exceeded`, the problem is not workflow fan-out or localhost routing. The upstream Codex model rejected the prompt size. In the observed local setup, this starts around `272k+` estimated input tokens despite Claude being configured to display `/400k`.
- Patched local behavior for normal non-compact requests: `context_length_exceeded` is returned to Claude Code as `400 invalid_request_error` without same-account retries, instead of being masked as `API Error: Upstream service temporarily unavailable`.
- Patched local behavior for Claude Code compact prompts: when the full compact overflows the mapped compact model, the proxy should not return the 400 directly; it should log `openai_messages.compact_context_length_fallback`, summarize chunks, merge them, and return a successful compact response. If the user still sees a 400 during `/compact`, verify the live container image was rebuilt/recreated and that `usage_logs.upstream_model` is `gpt-5.3-codex-spark`.
- To stop repeats while diagnosing the current GPT-5.6 profile, set `CLAUDE_CODE_MAX_CONTEXT_TOKENS=400000` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=400000`, then restart Claude Code windows. Do not treat that value as the upstream model maximum.
- Check sub2api access logs for `status_code: 502`.
- If those rows are `/v1/messages`, `stream=false`, and the moderation log shows a large `body_bytes` value around `1000000`, it is Claude Code's non-streaming fallback sending a huge retry body. Set `CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1` in both User env and `~/.claude/settings.json`, then restart Claude Code windows.
- If sub2api logs around the same timestamp show only `status_code: 200`, `stream=true`, and the JSONL transcript records a synthetic API error inside `subagents/workflows/...`, the failing layer is Claude Code's dynamic workflow fan-out, not the proxy HTTP response. Set `workflowSizeGuideline=small` in `%USERPROFILE%\.claude.json`, stop the existing workflow from `/workflows`, and relaunch with a narrower prompt. Large already-generated workflow scripts are not retroactively shrunk.

If Claude Code reports `API Error: 503 Service temporarily unavailable` or `API Error: 429`:

- First confirm proxy health. A healthy `/health` only proves the HTTP service is up; it does not prove any upstream account is schedulable:
  ```powershell
  $url = [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User")
  curl.exe --max-time 5 "$url/health"
  wsl.exe -- docker ps --filter name=sub2api-codex --format "{{.Names}} | {{.Status}} | {{.Ports}}"
  ```
- Check for the proven rate-limit/cooldown pattern. The key signature is `openai_messages.account_select_failed` with `error="no available accounts"` immediately before an access log `status_code=429` or legacy `status_code=503` on `/v1/messages`:
  ```powershell
  $log = "C:\Users\stigm\Documents\Codex\2026-07-07\new-chat\work\sub2api-runtime\data\logs\sub2api.log"
  Select-String -Path $log -Pattern "account_select_failed|status_code.*503|usage limit|rate_limit|no available accounts" -Context 2,2 | Select-Object -Last 80
  ```
- Check Postgres account state and recent errors:
  ```powershell
  wsl.exe -- docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F " | " -Atc "select id, status, schedulable, concurrency, rate_limited_at, rate_limit_reset_at, temp_unschedulable_until, session_window_status, coalesce((extra->'model_rate_limits')::text,''), last_used_at, updated_at from accounts where platform='openai' order by id;"
  wsl.exe -- docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F " | " -Atc "select id, created_at, status_code, upstream_status_code, error_type, left(coalesce(error_message,''),140), left(coalesce(upstream_error_message,''),140), account_id, requested_model from ops_error_logs where created_at > now() - interval '4 hours' order by id desc limit 40;"
  ```
- Interpret the OpenAI/Codex OAuth `403 Access forbidden` pattern this way:
  ```text
  upstream 403 HTML page from chatgpt.com / Codex
  -> patched image logs openai_403_temp_unschedulable
  -> accounts.status remains active, schedulable remains true, temp_unschedulable_until blocks dispatch briefly
  -> after temp_unschedulable_until expires, the same OAuth account can be selected again
  ```
  The 2026-07-09 bug was the old behavior: repeated 403s hit the threshold and wrote `account_disabled_auth_error`, leaving `accounts.status='error'` and `schedulable=false`; all later main-model requests failed as `account_select_failed` / `no available accounts` / 503. Current fork behavior: OpenAI OAuth 403 never uses `SetError`; it uses `SetTempUnschedulable` even when the 403 counter reaches threshold or the counter cache fails. Covered by focused tests `TestRateLimitService_HandleUpstreamError_OpenAI403ThresholdStaysTemporaryForOAuth`, `TestRateLimitService_HandleUpstreamError_OpenAI403TempWriteFailureDoesNotDisableOAuth`, and the preserved non-OAuth disable test.
- If logs still show `account_disabled_auth_error` for OpenAI OAuth 403, first suspect a stale image. Rebuild/recreate `sub2api-codex:local-token-usage`, then verify with a tiny `gpt-5.6-sol` probe:
  ```powershell
  cd C:\Users\stigm\Documents\Codex\2026-07-07\new-chat\work\repo-comparison\sub2api\backend
  wsl.exe -- bash -lc "cd /mnt/c/Users/stigm/Documents/Codex/2026-07-07/new-chat/work/repo-comparison/sub2api/backend && docker build -t sub2api-codex:local-token-usage ."
  wsl.exe -- bash -lc "cd /mnt/c/Users/stigm/Documents/Codex/2026-07-07/new-chat/work/sub2api-runtime && docker compose -p sub2api-codex up -d --force-recreate --no-deps sub2api"
  ```
- Use the manual DB reset only to recover state already poisoned by the old image. Do not keep doing this if the patched image immediately receives fresh upstream 403s:
  ```powershell
  wsl.exe -- docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F " | " -Atc "update accounts set status='active', schedulable=true, error_message=null, temp_unschedulable_until=null, temp_unschedulable_reason=null, rate_limited_at=null, rate_limit_reset_at=null, overload_until=null, updated_at=now() where platform='openai' returning id, status, schedulable;"
  wsl.exe -- docker restart sub2api-codex

  $base = [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User")
  $tok = [Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "User")
  $body = @{ model="gpt-5.6-sol"; max_tokens=32; stream=$false; messages=@(@{ role="user"; content="Reply exactly OK_PROXY_RECOVERED" }) } | ConvertTo-Json -Depth 5 -Compress
  curl.exe --max-time 90 -sS -w "`nHTTP_STATUS=%{http_code}`n" -H "x-api-key: $tok" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d $body "$base/v1/messages"
  ```
  If the probe immediately returns another upstream 403, leave the account in temporary cooldown and treat it as a real OpenAI/Codex auth, edge, or anti-abuse block. Re-import/refresh the OAuth account or wait/change network; do not convert it to permanent account disable for OAuth.
- Interpret a global cooldown pattern this way:
  ```text
  upstream 429 "The usage limit has been reached"
  -> accounts.rate_limited_at and accounts.rate_limit_reset_at are set
  -> single OpenAI/Codex account is temporarily unschedulable
  -> sub2api account selection fails with no available accounts
  -> patched sub2api returns 429 rate_limit_error with the reset timestamp
  ```
- Interpret a model-scoped cooldown pattern this way:
  ```text
  upstream 429 for gpt-5.3-codex-spark or another requested model
  -> accounts.extra.model_rate_limits["gpt-5.3-codex-spark"] is set
  -> direct Spark requests are skipped or fall back when configured
  -> gpt-5.6-sol, gpt-5.6-terra, and Spark-to-Luna-to-mini fallback requests must still select the same OpenAI/Codex account and succeed
  ```
- If a Spark/Codex 5.3 429 accidentally wrote global `rate_limited_at/rate_limit_reset_at`, migrate that reset into `extra.model_rate_limits["gpt-5.3-codex-spark"]`, clear the global fields, restart `sub2api`, then verify `gpt-5.6-sol` with a direct `/v1/messages` probe. This was the 2026-07-08 bug class: a Spark-only cooldown made the main model look unavailable.
- A second proven variant on 2026-07-09: manual `/compact` hit `openai_messages.compact_context_length_fallback`, then Spark returned upstream 429 and logs showed `openai_429_5h_limit_exhausted`, `openai_account_rate_limited`, and `openai_messages.compact_chunk_model_unavailable_switching`. Root cause was `handleOpenAIAccountUpstreamError` dropping the variadic requested/upstream model before `RateLimitService.HandleUpstreamError`, plus a global OAuth runtime block on every 429. Fixed fork behavior: pass the model through, skip global runtime block when a model scope exists, and add `TestOpenAI429FastPath_ModelScopedCooldownDoesNotBlockWholeOAuthAccount`. If this recurs, first confirm the live image was rebuilt from that fix; a stale `sub2api-codex:local-token-usage` tag can still poison all models.
- This is not a context-window failure, a ghost stream, or localhost routing when recent `usage_logs` show normal nonzero rows before/after the burst and `zero_streams=0`.
- Do not "fix" this by raising `accounts.concurrency`; concurrency only helps slot exhaustion. A real upstream usage limit needs waiting until `rate_limit_reset_at`, reducing fan-out/parallel Claude windows, or adding another valid OpenAI/Codex account to the group.
- Current fork behavior: when account selection fails because every configured account that supports the requested model is rate-limited or cooled down, return a clear `429 rate_limit_error` with reset timing instead of generic `503 Service temporarily unavailable`. Issue #1 fixed stale fake quota cooldowns by clearing quota-origin `model_rate_limits` after fresh Codex usage snapshots show headroom.

If `/v1/models` lists `gpt-5.5-mini` or `gpt-5.6-*` but requests fail:

- Trust the request-time upstream response over the model list. `/v1/models` is an advertisement/catalog surface; the ChatGPT/Codex account entitlement is enforced on `/v1/messages`.
- Do not silently alias `gpt-5.5-mini` to `gpt-5.5`. That hides unsupported-model bugs and makes speed/quality tests invalid.
- Current verified behavior on 2026-07-10: `gpt-5.6-sol` and `gpt-5.6-terra` returned 200; `gpt-5.3-codex-spark` is configured as small-fast/Haiku, with normal fallback chain `gpt-5.3-codex-spark -> gpt-5.6-luna -> gpt-5.4-mini`. Direct `gpt-5.6-luna` falls back to `gpt-5.3-codex-spark`, then `gpt-5.4-mini` when Luna is not schedulable.

If Claude Code sub-agent status shows `0 tokens` but sub2api usage logs show nonzero tokens:

- Treat this as a proxy compatibility issue until proven otherwise, not as proof the agents were free or did not run.
- The critical Anthropic SSE field is `message_start.message.usage.input_tokens`. Claude Code's live context/status display reads this early field.
- Broken proxy shape:
  ```json
  {"type":"message_start","message":{"usage":{"input_tokens":0,"output_tokens":0}}}
  {"type":"message_delta","usage":{"input_tokens":119,"output_tokens":7}}
  ```
- Official Anthropic streams put real input usage on `message_start`; final `message_delta` usage is cumulative/final output-side accounting. If the proxy only learns real usage at the final upstream event, Claude Code may keep displaying `0 tokens`.
- sub2api's Responses-to-Anthropic transformer currently emits `message_start` on upstream `response.created`; if that event has no usage, the transformer must either pre-count/estimate input tokens before the stream starts, or buffer/replay the stream so `message_start` can contain final input usage. Pre-counting is the better UX because buffering kills streaming latency.
- Non-streaming `/v1/messages` can still return correct final `usage`, and sub2api Postgres `usage_logs` can still be correct. That means billing/accounting is fine while Claude Code UI is wrong.
- Local verified patch pattern: estimate input tokens from the final OpenAI Responses request body before the upstream call, pass that value into `ResponsesEventToAnthropicState.InputTokens`, and make `responses_to_anthropic.go` emit `state.InputTokens` in `message_start.message.usage.input_tokens` instead of hardcoded zero. Final billing remains based on upstream terminal usage.
- Local verified empty-stream patch pattern: in `handleAnthropicStreamingResponse`, buffer Anthropic SSE until a visible text delta or tool_use/server_tool_use block appears; skip keepalive pings before visible output; if terminal arrives first, return `newOpenAIStreamFailoverError` with "completed without assistant content or tool output".
- Local patched Docker tag used here: `sub2api-codex:local-token-usage`; runtime compose must be started with project name `sub2api-codex` so it reuses the existing Postgres/Redis network and volumes.

If the user wants a larger display than the safe profile:

- Do not invent it for Codex subscription. A larger Claude Code denominator is only a local client hint; the upstream is authoritative.
- In the old 5.5 setup, `/400k` was disproven by upstream `context_length_exceeded` around `272k-278k` estimated input tokens. Do not generalize that old 5.5 evidence to GPT-5.6. GPT-5.6 official docs list a 1,050,000 token window, so use clean `gpt-5.6-sol` plus `gpt-5.3-codex-spark` small-fast/Haiku labels with the 400k Claude Code client target first, then raise only after live long-context probes.

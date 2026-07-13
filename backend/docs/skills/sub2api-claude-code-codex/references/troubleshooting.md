# Troubleshooting Playbook

Known failure signatures and fixes for routing, empty streams, context overflow, 429/503 cooldowns, Luna availability, and usage display issues.

## Contents

- [Troubleshooting](#troubleshooting)

## Troubleshooting

If `/context` still shows `/200k`:

- Ensure `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is present in both User env and `~/.claude/settings.json`.
- Ensure `CLAUDE_CODE_AUTO_COMPACT_WINDOW` is below the official/proven upstream window. For the current GPT-5.6 Claude Code client profile, use `CLAUDE_CODE_MAX_CONTEXT_TOKENS=370000` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=340000`; `/200k` means Claude Code fell back to its custom-model default.
- Restart the terminal. Current shells do not automatically receive newly written User env values.

If requests do not hit sub2api:

- Check current-process env, not only User env:
  ```powershell
  $env:ANTHROPIC_BASE_URL
  [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User")
  ```
- Claude Code should point at Headroom: `http://127.0.0.1:8787`. Old shells may still point directly at sub2api such as `http://127.0.0.1:18081`; that bypasses Headroom optimization.
- Check both Headroom and sub2api health before changing model mapping:
  ```powershell
  curl.exe --max-time 5 http://127.0.0.1:8787/health
  curl.exe --max-time 5 http://127.0.0.1:18081/health
  curl.exe --max-time 5 http://127.0.0.1:8787/stats
  ```
- Start Claude Code only after setting current shell env or after opening a new terminal.
- On Docker-in-WSL, check Windows routing separately. A stuck `wslrelay.exe` can accept TCP on `127.0.0.1:8787` and never forward the HTTP response. Symptoms: Claude Code thinks for 40-120 seconds, no new `usage_logs` rows appear, `wsl.exe -- curl http://127.0.0.1:8787/health` works, but Windows `curl.exe http://127.0.0.1:8787/health` hangs.
- In that case, set `deploy/claude-code-codex-headroom/.env` `HEADROOM_BIND_HOST=0.0.0.0`, recreate the `headroom` service, and set `ANTHROPIC_BASE_URL` to the current WSL eth0 IP on port `8787`:
  ```powershell
  $wslIp = (wsl.exe -- bash -lc "ip -4 addr show eth0 | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1").Trim()
  [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", "http://$wslIp:8787", "User")
  ```
- Use `http://127.0.0.1:18081` only as a temporary direct sub2api diagnostic bypass when Headroom is suspect.

If sub2api returns unknown model:

- Add exact mappings for the requested model, especially `claude-opus-4-8`, `claude-opus-4-8[1m]`, and `gpt-5.5[400k]`.
- Confirm `allow_messages_dispatch=true` on the OpenAI group.

If count-tokens logs show upstream `401`:

- sub2api may fall back to local token estimation. This is usually not fatal if `/v1/messages` requests succeed and usage logs show the expected route such as `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.3-codex-spark`, `gpt-5.6-luna` as Spark fallback, or `gpt-5.4-mini` as final fallback.

If Claude Code shows empty answers, "previous response had no visible output", or sub2api logs show `0/0` usage:

- Query `usage_logs` for `stream=true AND input_tokens=0 AND output_tokens=0 AND duration_ms BETWEEN 500 AND 30000`.
- If the affected rows are `gpt-5.6-sol`, `gpt-5.3-codex-spark`, `gpt-5.6-luna` Spark fallback, `gpt-5.4-mini` final fallback, `gpt-5.5`, or legacy `gpt-5.5[400k]` with weaker reasoning than expected, restart or fork the old Claude Code session with `--model gpt-5.6-sol --effort max`; new max requests should log the strongest supported effort for this route.
- Ensure User env and `~/.claude/settings.json` contain `MAX_THINKING_TOKENS=8000`, but do not treat it as the Codex reasoning control. For GPT-5.6 max requests on the current Codex/OpenAI Responses route, verify `usage_logs.reasoning_effort=max`. If logs show `requested_effort=max` and `upstream_effort=xhigh`, the running image is stale or using the legacy fallback path.
- Avoid ending a turn with a background shell command that produces no stdout. Claude Code has a known "no visible output" retry loop around empty tool output; emit a visible summary after background tasks.
- A 0/0 row with HTTP 200 can be a Codex ghost stream. Do not solve it by switching Claude Code to `claude-opus-*` if the user needs the Codex route. Fix the proxy path first, then verify the real upstream context limit from logs.
- The local patched `sub2api-codex:local-token-usage` image buffers initial Anthropic SSE events until real text/tool output appears. If upstream completes with no visible text/tool output, the proxy returns a retryable upstream failure instead of a successful empty `message_stop`.
- For `API Error: Stream ended without receiving any events`, treat `sub2api` as the Anthropic-compatible server boundary even when OpenAI/Codex is the upstream server. For `/v1/messages`, wait-ping/concurrency may open HTTP 200 before upstream output. The proxy must then either send `event: message_start` or a named Anthropic `event: error` before close. Current patched behavior logs `zero_anthropic_event_stream` when wait-ping opened transport but no Anthropic output started, uses `event: ping\ndata: {"type":"ping"}` for Claude pings, and preserves OpenAI `/responses` behavior as `event: response.failed`.
- Headroom-specific variant: if the Claude JSONL shows a synthetic `<synthetic>` API error with `0` input/output tokens, Headroom logs `proxy_inbound_response ... status=202`, and `STAGE_TIMINGS` has `upstream_connect=null`, the request never reached sub2api. This is the Headroom private `headroom_queued` mid-turn path, not a model or sub2api failure. Rebuild/recreate `headroom-sub2api:0.31.0` from a Dockerfile that applies `deploy/claude-code-codex-headroom/patch-headroom-claude-code-streaming.py`. The patch derives stream keys from `x-claude-code-session-id` plus `x-claude-code-agent-id`, waits for the active stream to drain instead of returning HTTP 202, and keeps active-stream refcounts so a late cleanup cannot clear a newer stream marker.
- Headroom handler-timeout variant: if Claude JSONL shows `<synthetic> Request timed out`, the Headroom log has `event=proxy_inbound_request` and `event=outbound_headers` / `event=beta_header_merge` for the same request id, but no `STAGE_TIMINGS`, no `proxy_inbound_response`, and sub2api has no `usage_logs` row, the request died inside Headroom before upstream. This is not a model limit and not a hanging background shell. The Docker image must include the same patch with the `Claude Code handler watchdog patch` sentinel and env `HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS=540000`; on watchdog fire Headroom must cancel the hung primary handler and retry once with `x-headroom-bypass=true`, `x-headroom-mode=passthrough`, and `x-sub2api-headroom-watchdog-retry=1`. Logs should show `event=claude_code_handler_watchdog_timeout`, then `event=claude_code_handler_watchdog_retry`, and ideally `event=claude_code_handler_watchdog_retry_ok`. A 504 Anthropic SSE `event:error` is only acceptable after the bypass retry also times out.
- Verify the Headroom patch from inside the container: `return JSONResponse(content=queued, status_code=202)` must be absent, sentinels `Claude Code session key patch`, `Claude Code no-202 overlap patch`, `Claude Code handler watchdog patch`, `active-stream refcount patch`, and `overlap wait patch` must be present. `HEADROOM_MID_TURN_STREAM_WAIT_MS` should normally be `600000`; `HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS` should normally be `540000`. If an overlap is real, logs should show `event=mid_turn_overlap_wait` and then `event=mid_turn_overlap_wait_done`, not a `202` response to Claude Code.
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
- To stop repeats while diagnosing context-window behavior, first verify whether the error is a real upstream `context_length_exceeded`, a proxy routing/rate-limit error, or Claude Code's client display fallback. For the current GPT-5.6 Claude Code client profile, use `CLAUDE_CODE_MAX_CONTEXT_TOKENS=370000` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=340000`, then restart Claude Code windows.
- Check sub2api access logs for `status_code: 502`.
- If those rows are `/v1/messages`, `stream=false`, and the moderation log shows a large `body_bytes` value around `1000000`, it is Claude Code's non-streaming fallback sending a huge retry body. Set `CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1` in both User env and `~/.claude/settings.json`, then restart Claude Code windows.
- If sub2api logs around the same timestamp show only `status_code: 200`, `stream=true`, and the JSONL transcript records a synthetic API error inside `subagents/workflows/...`, the failing layer is Claude Code's dynamic workflow fan-out, not the proxy HTTP response. Do not claim `workflowSizeGuideline=small` will prevent it; the local setup already had it and still produced hundreds of spawned descendants. Stop the existing workflow from `/workflows` and relaunch only a narrow prompt, or disable workflows for that session/profile when fan-out must not happen. Large already-generated workflow scripts are not retroactively shrunk.
- Do not add a global Agent-blocking hook as a routine fix. On this machine the accepted guard is advisory: `workflowSizeGuideline=small` plus `%USERPROFILE%\.claude\agents\general-purpose.md`, `Explore.md`, and `workflow-subagent.md` pinned to `gpt-5.6-terra-medium` with `effort: medium` and prompt guidance to stay under 10 sibling agents and avoid deep chains. The `-medium` model alias is intentional and must normalize in sub2api to upstream `gpt-5.6-terra` with `reasoning_effort=medium`; otherwise subagents can inherit parent Sol/max. If Terra-medium returns empty visible output, normal messages fallback should switch to `gpt-5.6-sol-medium`; patched sub2api must preserve fallback effort aliases while routing account selection by the normalized model, or the fallback will become bare Sol/medium. Hard-blocking `PreToolUse` / `SubagentStart` / `SubagentStop` state-file hooks should be installed only after explicit user approval. Do not tell the user a built-in depth cap will prevent hundreds of spawned descendants; observed Claude Code runs contradicted that operationally.
- To verify which model subagents really used, inspect both worker command lines and Postgres:
  ```powershell
  Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*run-claude-pipe-status-worker.ps1*' } | Select-Object ProcessId,CommandLine
  wsl.exe -- docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F " | " -Atc "select requested_model, model_mapping_chain, count(*), sum(input_tokens), sum(output_tokens) from usage_logs where created_at > now() - interval '30 minutes' group by requested_model, model_mapping_chain order by 1,2;"
  ```
- Verified Terra c10 replay on 2026-07-10: 9/10 historical `general-purpose` prompts finished, 1 timed out at 902s, and no Terra API errors were logged. Usage evidence was 238 rows `gpt-5.6-terra -> gpt-5.6-terra`, about 2.26M input tokens and 108.4k output tokens. Treat c10 as technically viable but slow on heavy prompts; do not call c10 "fast" without measuring the tail.

If Claude Code reports `API Error: 503 Service temporarily unavailable` or `API Error: 429`:

- First confirm proxy health. A healthy `/health` only proves the HTTP service is up; it does not prove any upstream account is schedulable:
  ```powershell
  $url = [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User")
  curl.exe --max-time 5 "$url/health"
  wsl.exe -- docker ps --filter name=sub2api-codex --format "{{.Names}} | {{.Status}} | {{.Ports}}"
  ```
- Check for the proven rate-limit/cooldown pattern. The key signature is `openai_messages.account_select_failed` with `error="no available accounts"` immediately before an access log `status_code=429` or legacy `status_code=503` on `/v1/messages`:
  ```powershell
  docker logs --since 30m sub2api-codex 2>&1 | Select-String -Pattern "account_select_failed|status_code.*503|status_code.*429|usage limit|rate_limit|no available accounts" -Context 2,2 | Select-Object -Last 80
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
  cd <sub2api repo root>
  docker compose --env-file deploy\claude-code-codex-headroom\.env -f deploy\claude-code-codex-headroom\docker-compose.yml -p sub2api-codex up -d --build --force-recreate sub2api
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
- OAuth 401 / revoked-token recovery has a separate failure shape:
  ```text
  upstream 401 "Your authentication token has been invalidated"
  -> logs show account_disabled_auth_error
  -> credentials are re-imported with apply-oauth-credentials
  -> account status becomes active, but old images can leave schedulable=false
  -> account selection still fails with no available accounts / 503
  -> Claude Code may spin through retries and end as Request timed out
  ```
  Fixed fork behavior: `ClearAccountError` also calls `SetSchedulable(..., true)`, so `apply-oauth-credentials` and manual clear-error paths put a refreshed OAuth account back into the scheduler. Verify with Postgres before blaming Headroom or context:
  ```powershell
  wsl.exe -- docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F " | " -Atc "select id, name, platform, type, status, schedulable, coalesce(error_message,''), expires_at from accounts where platform='openai' order by id;"
  ```
  Expected recovered state is `active | t` with a non-expired `expires_at`. If the runtime image is stale, set schedulable manually once, rebuild/recreate `sub2api-codex` from the fork, then run a tiny Headroom `/v1/messages` probe and a `claude --print --no-session-persistence` probe.
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
- 2026-07-10 regression fixed in the local fork: the OpenAI/Codex no-account diagnoser now inspects both global `accounts.rate_limit_reset_at` and model-scoped `accounts.extra.model_rate_limits[model].rate_limit_reset_at`. Before this fix, a real `gpt-5.6-sol` model cooldown could be selected out by the scheduler but diagnosed as generic service unavailability, so Claude Code saw `503` instead of `429`. Live verification after rebuilding `sub2api-codex:local-token-usage`: `/v1/messages` for `gpt-5.6-sol` during active cooldown returned `HTTP_STATUS=429` with `rate_limit_error` and reset timestamp; `ops_error_logs` row `3654` recorded `status_code=429`, `error_type=rate_limit_error`.

If `/v1/models` lists `gpt-5.5-mini` or `gpt-5.6-*` but requests fail:

- Trust the request-time upstream response over the model list. `/v1/models` is an advertisement/catalog surface; the ChatGPT/Codex account entitlement is enforced on `/v1/messages`.
- Do not silently alias `gpt-5.5-mini` to `gpt-5.5`. That hides unsupported-model bugs and makes speed/quality tests invalid.
- Current verified behavior on 2026-07-10: `gpt-5.6-sol` and `gpt-5.6-terra` returned 200; `gpt-5.3-codex-spark` is configured as small-fast/Haiku, with normal fallback chain `gpt-5.3-codex-spark -> gpt-5.6-luna -> gpt-5.4-mini`. Direct `gpt-5.6-luna` can return HTTP 200 while actually falling back. The 2026-07-10 11:47 MSK re-probe logged `requested_model=gpt-5.6-luna`, `model=gpt-5.4-mini`, `model_mapping_chain=gpt-5.6-luna->gpt-5.4-mini`, plus `ops_error_logs` recovered upstream 429 "The usage limit has been reached". Treat Luna as unavailable until `usage_logs.model_mapping_chain` ends at `gpt-5.6-luna`.

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
- In the old 5.5 setup, `/400k` was disproven by upstream `context_length_exceeded` around `272k-278k` estimated input tokens. Do not generalize that old 5.5 evidence to GPT-5.6. GPT-5.6 Sol/Terra/Luna are configured locally with `max_input_tokens=1050000`; use clean `gpt-5.6-sol` plus `gpt-5.3-codex-spark` small-fast/Haiku labels, and keep the Claude Code client compact/display target at 370k/340k unless a fresh long-context probe proves a better safe threshold.

Headroom Docker stack:

- Keep the Headroom HTTP proxy, RTK, lean-ctx, TokenSave, ast-grep, difft, and scc inside the Docker image for this profile. Claude Code should use a Docker-backed `headroom` MCP, not stale `%USERPROFILE%\.local\bin\headroom.exe` or `tokensave.exe` paths.
- Keep Headroom `--embedding-server` enabled in this image. The image must build from `HEADROOM_GIT_REPO=https://github.com/stgmt/headroom.git` at pinned `HEADROOM_GIT_REF`, with the local patch scripts retained as idempotent guardrails. If logs show `No module named 'headroom.memory.adapters.watchdog'` or `Falling back to per-worker embedder`, the image is stale, built from the wrong source, or built without `patch-headroom-embedding-server.py`. Rebuild `headroom-sub2api:0.31.0`, recreate the `headroom` service, verify compose labels point at `stgmt/headroom`, then verify logs show `Embedding server: ready.`
- Keep the Claude Code streaming-overlap patch in the Headroom image too. If it is missing, a background agent or fast follow-up main turn can race the previous stream cleanup, Headroom can return private HTTP 202 `headroom_queued`, and Claude Code reports `Stream ended without receiving any events` while still waiting for background agents.
- Preserve all data across recreates on host bind mounts. `/root/.headroom` must be a host bind mount and should contain `ccr_store.db` after memory traffic. `/root/.cache/headroom`, `/root/.cache/huggingface`, `/app/data`, Postgres parent `/var/lib/postgresql`, and Redis `/data` should also be host bind mounts under `${SUB2API_STATE_ROOT:-./data}`. Do not bind the same Postgres host directory directly to `/var/lib/postgresql/data`: `postgres:18-alpine` declares `/var/lib/postgresql` as a volume and that nested layout can make `initdb` loop on a non-empty data dir. If `docker inspect` shows `Type=volume`, the profile is wrong. Do not delete the state root unless intentionally wiping memory and all service state.
- Do this audit proactively whenever editing compose/setup/docs for this stack. Do not wait for the user to point out that Docker named volumes can hide or strand data. A "reusable" fix is not done until the verifier proves host `Type=bind` mounts for every stateful service.
- If a fresh install loses RTK/lean-ctx/difft/scc after adding persistent mounts, the image bootstrap wrapper is missing or stale. Rebuild from a Dockerfile that copies `start-headroom-proxy.sh`, seeds `/opt/headroom-seed`, and uses `ENTRYPOINT ["/usr/local/bin/start-headroom-proxy"]`.

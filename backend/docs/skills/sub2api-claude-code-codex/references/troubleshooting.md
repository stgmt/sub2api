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

- First classify the requested model family. GPT/Codex names should route to the OpenAI/Codex account; `qwen*`, `glm-*`, and `deepseek-v4-pro` should route to the Alibaba Token Plan Anthropic-compatible account. This local profile should not publish raw `fable`, `opus`, `sonnet`, `haiku`, or `claude-*` provider aliases in `/v1/models`.
- Confirm `allow_messages_dispatch=true`, `require_oauth_only=false`, and `models_list_config.enabled=true/explicit=true` on the mixed-provider group.
- Do not fix removed Claude/Fable provider aliases by mapping them to GPT. Claude Code Opus/Fable/Sonnet/Haiku picker slots are env aliases and should point to Qwen high (`qwen3.8-max-preview`) in this profile.
- A stale Windows/Hyper-V Claude host can still emit dated names such as `claude-haiku-4-5-20251001`. Keep hidden group family/exact mappings for these compatibility inputs and route them to `qwen3.8-max-preview`; do not publish them in `/v1/models`. Runtime proof requires `usage_logs.requested_model/upstream_model=qwen3.8-max-preview` on the Alibaba account. If logs show `component=handler.gateway.messages`, `model=claude-haiku-*`, and a millisecond `404 no available accounts`, the running sub2api predates the explicit-alias-before-provider-classification fix.
- If Claude Code says `The 'qwen3.8-max-preview' model is not supported when using Codex with a ChatGPT account`, check `/v1/messages/count_tokens` too, not only `/v1/messages`. The broken route signature is `path="/v1/messages/count_tokens"` plus `component=handler.openai_gateway.count_tokens`, `platform=openai`, or `account_id=1` for a Qwen/GLM/DeepSeek model. Patched sub2api routes the preflight through the mixed-provider classifier and returns a local `{"input_tokens":...}` estimate for Token Plan models, so no upstream Codex input-tokens call is made for Qwen.

If count-tokens logs show upstream `401`:

- sub2api may fall back to local token estimation. This is usually not fatal if `/v1/messages` requests succeed and usage logs show the expected route such as `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.3-codex-spark`, or `gpt-5.6-luna` as Spark fallback.

If Claude Code shows empty answers, "previous response had no visible output", or sub2api logs show `0/0` usage:

- Query `usage_logs` for `stream=true AND input_tokens=0 AND output_tokens=0 AND duration_ms BETWEEN 500 AND 30000`.
- If the affected rows are `gpt-5.6-sol`, `gpt-5.3-codex-spark`, `gpt-5.6-luna` Spark fallback, `gpt-5.5`, or legacy `gpt-5.5[400k]` with weaker reasoning than expected, restart or fork the old Claude Code session with `--model gpt-5.6-sol --effort max`; new max requests should log the strongest supported effort for this route.
- Ensure User env and `~/.claude/settings.json` contain `MAX_THINKING_TOKENS=8000`, but do not treat it as the Codex reasoning control. For GPT-5.6 max requests on the current Codex/OpenAI Responses route, verify `usage_logs.reasoning_effort=max`. If logs show `requested_effort=max` and `upstream_effort=xhigh`, the running image is stale or using the legacy fallback path.
- Avoid ending a turn with a background shell command that produces no stdout. Claude Code has a known "no visible output" retry loop around empty tool output; emit a visible summary after background tasks.
- A 0/0 row with HTTP 200 can be a Codex ghost stream. Do not solve it by switching Claude Code away from the configured GPT/Qwen profile. Fix the proxy path first, then verify the real upstream context limit from logs.
- The local patched `sub2api-codex:local-token-usage` image buffers initial Anthropic SSE events until real text/tool output appears. If upstream completes with no visible text/tool output, the proxy returns a retryable upstream failure instead of a successful empty `message_stop`.
- For `API Error: Stream ended without receiving any events`, treat `sub2api` as the Anthropic-compatible server boundary even when OpenAI/Codex is the upstream server. For `/v1/messages`, wait-ping/concurrency may open HTTP 200 before upstream output. The proxy must then either send `event: message_start` or a named Anthropic `event: error` before close. Current patched behavior logs `zero_anthropic_event_stream` when wait-ping opened transport but no Anthropic output started, uses `event: ping\ndata: {"type":"ping"}` for Claude pings, and preserves OpenAI `/responses` behavior as `event: response.failed`.
- Headroom-specific variant: if the Claude JSONL shows a synthetic `<synthetic>` API error with `0` input/output tokens, Headroom logs `proxy_inbound_response ... status=202`, and `STAGE_TIMINGS` has `upstream_connect=null`, the request never reached sub2api. This is the Headroom private `headroom_queued` mid-turn path, not a model or sub2api failure. Rebuild/recreate `headroom-sub2api:0.31.0` from a Dockerfile that applies `deploy/claude-code-codex-headroom/patch-headroom-claude-code-streaming.py`. The patch derives stream keys from `x-claude-code-session-id` plus `x-claude-code-agent-id`, waits for the active stream to drain instead of returning HTTP 202, and keeps active-stream refcounts so a late cleanup cannot clear a newer stream marker.
- Headroom handler-timeout variant: if Claude JSONL shows `<synthetic> Request timed out`, the Headroom log has `event=proxy_inbound_request` and `event=outbound_headers` / `event=beta_header_merge` for the same request id, but no `STAGE_TIMINGS`, no `proxy_inbound_response`, and sub2api has no `usage_logs` row, the request died inside Headroom before upstream. This is not a model limit and not a hanging background shell. The Docker image must include the same patch with the `Claude Code handler watchdog patch` sentinel and env `HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS=540000`; on watchdog fire Headroom must cancel the hung primary handler and retry once with `x-headroom-bypass=true`, `x-headroom-mode=passthrough`, and `x-sub2api-headroom-watchdog-retry=1`. Logs should show `event=claude_code_handler_watchdog_timeout`, then `event=claude_code_handler_watchdog_retry`, and ideally `event=claude_code_handler_watchdog_retry_ok`. A 504 Anthropic SSE `event:error` is only acceptable after the bypass retry also times out.
- Verify the Headroom patch from inside the container: `return JSONResponse(content=queued, status_code=202)` must be absent, sentinels `Claude Code session key patch`, `Claude Code no-202 overlap patch`, `Claude Code handler watchdog patch`, `active-stream refcount patch`, and `overlap wait patch` must be present. `HEADROOM_MID_TURN_STREAM_WAIT_MS` should normally be `600000`; `HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS` should normally be `540000`. If an overlap is real, logs should show `event=mid_turn_overlap_wait` and then `event=mid_turn_overlap_wait_done`, not a `202` response to Claude Code.

## `400 No tool output found for function call call_*`

- Locate the exact Claude JSONL event first. If a fresh prompt has no preceding client `tool_use`/`tool_result`, the VM did not lose a Bash result.
- Correlate the Headroom request with two sub2api calls. The characteristic failure is an initial Sol HTTP 200, `Memory: Executed memory_search`, then a Headroom-created continuation that receives upstream HTTP 400.
- Mechanism: GPT emitted a private Headroom memory call and a client-owned call in one assistant turn. Old Headroom replayed both but supplied a result only for memory, so the Responses bridge rejected the incomplete call set.
- Required fork behavior: include only result-backed memory `tool_use` blocks in the internal assistant turn, defer client-owned calls, remove all private memory definitions from that continuation, and skip continuation when a memory result has no matching call ID.
- Live verification prompt: request `memory_search` and `Bash pwd` in one parallel turn. Headroom must log `Memory: Deferred 1 client-owned tool call(s) from continuation: ['Bash']`; sub2api must return HTTP 200; Claude Code must report both results without `memory_search` unavailable.
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
- Patched local behavior for Claude Code compact prompts in the current Qwen-high profile: group `messages_dispatch_model_config.compact_mapped_model=qwen3.8-max-preview` rewrites GPT/Codex compact requests before provider classification, so the Alibaba Token Plan Anthropic-compatible account performs compact with `reasoning_effort=high`. If the user still sees a 400 during `/compact`, verify the live container image was rebuilt/recreated and that `usage_logs.upstream_model` is `qwen3.8-max-preview`.
- To stop repeats while diagnosing context-window behavior, first verify whether the error is a real upstream `context_length_exceeded`, a proxy routing/rate-limit error, or Claude Code's client display fallback. For the current GPT-5.6 Claude Code client profile, use `CLAUDE_CODE_MAX_CONTEXT_TOKENS=370000` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=340000`, then restart Claude Code windows.
- Check sub2api access logs for `status_code: 502`.
- If those rows are `/v1/messages`, `stream=false`, and the moderation log shows a large `body_bytes` value around `1000000`, it is Claude Code's non-streaming fallback sending a huge retry body. Set `CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1` in both User env and `~/.claude/settings.json`, then restart Claude Code windows.
- If sub2api logs around the same timestamp show only `status_code: 200`, `stream=true`, and the JSONL transcript records a synthetic API error inside `subagents/workflows/...`, the failing layer is Claude Code's dynamic workflow fan-out, not the proxy HTTP response. Do not claim `workflowSizeGuideline=small` will prevent it; the local setup already had it and still produced hundreds of spawned descendants. Stop the existing workflow from `/workflows` and relaunch only a narrow prompt, or disable workflows for that session/profile when fan-out must not happen. Large already-generated workflow scripts are not retroactively shrunk.
- Do not add a global Agent-blocking hook as a routine fix. On this machine the accepted guard is advisory: `workflowSizeGuideline=small` plus `%USERPROFILE%\.claude\agents\general-purpose.md`, `Explore.md`, `workflow-subagent.md`, `bench-reviewer.md`, and `bench-triage.md` pinned to `qwen3.8-max-preview` with `effort: high` and prompt guidance to stay under 10 sibling agents and avoid deep chains. Keep normal message fallbacks empty unless the user explicitly requests fallback behavior; empty visible output from Qwen is a proxy/upstream bug to investigate, not a reason to hide the failure behind Sol. Hard-blocking `PreToolUse` / `SubagentStart` / `SubagentStop` state-file hooks should be installed only after explicit user approval. Do not tell the user a built-in depth cap will prevent hundreds of spawned descendants; observed Claude Code runs contradicted that operationally.
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
- Distinguish Headroom's local limiter before inspecting sub2api. The exact
  FastAPI body `{"detail":"Rate limited. Retry after N.Ns"}` is generated by
  Headroom before the request reaches sub2api. Claude Code may put it inside a
  WebSearch/tool result and stop that agent without replaying the call. Check
  the effective bucket and run the billing-free burst probe:
  ```powershell
  (Invoke-RestMethod "$url/stats").rate_limiter | ConvertTo-Json -Compress
  node scripts/test-headroom-rate-limit-burst.mjs $url 96
  ```
  The maintained loopback profile requires at least `6000` RPM and `100000000`
  TPM. The probe must finish with `rate_limited=0`; HTTP 401 is expected because
  it deliberately uses a unique invalid key to avoid reaching model billing.
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
  -> first consecutive failure blocks scheduling for 2s
  -> /v1/messages logs openai_messages.oauth_403_autoheal_retry and retries once after 2.25s
  -> a successful retry logs openai_403_autoheal_cleared and removes only the 403 counter/temp state
  -> repeated failures back off to 15s, 1m, then 5m without permanently disabling OAuth
  ```
  Two old failure modes are now covered. The 2026-07-09 behavior permanently disabled OAuth after repeated 403s. The 2026-07-16 behavior kept the account active but applied a fixed ten-minute first-hit cooldown, so one transient HTML 403 made every Claude window fail as `account_select_failed` / `no available accounts` / 503. Current fork behavior never uses `SetError` for OpenAI OAuth 403, applies the adaptive ladder, retries only the first failure once inside the original request, and resets the consecutive counter after any successful OpenAI usage. Cleanup is intentionally narrow: a 403 success must not clear `model_rate_limits`, quota cooldowns, or other temp-unschedulable reasons. Covered by `TestOpenAI403Cooldown`, the `HandleUpstreamError_OpenAI403*` suite, `TestShouldAutohealOpenAIOAuth403`, and the `RecoverOpenAI403AfterSuccess*` suite.
- Use these log markers to distinguish auto-heal from passive expiry:
  ```text
  openai_403_temp_unschedulable cooldown_seconds=2
  openai_messages.oauth_403_autoheal_retry retry_delay=2.25s retry_count=1
  openai_403_autoheal_cleared
  ```
  If the retry receives another 403, the request is allowed to fail and the account remains in the next adaptive cooldown. Do not add unbounded retries: repeated real access denials must still protect the upstream account.
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
- Codex/OpenAI OAuth refresh-token reuse has its own self-heal path:
  ```text
  token refresh fails with OPENAI_OAUTH_TOKEN_REFRESH_FAILED
  -> upstream/body contains refresh_token_reused, invalid_refresh_token, invalid_grant, token_expired, or app_session_terminated
  -> old image marks account status=error and schedulable=false
  -> scheduler hides the account, so Claude Code sees no available accounts / legacy 503
  ```
  Current fork behavior: setup and the repeating self-heal task copy a validated host `%USERPROFILE%\.codex\auth.json` into `${SUB2API_STATE_ROOT}/sub2api/codex-auth.json`; sub2api reads it from `SUB2API_OPENAI_CODEX_AUTH_FILE=/app/data/codex-auth.json`. On refresh failure or OpenAI selection failure, sub2api imports that file only if the refresh token differs and the access-token JWT is not expired, then clears `status=error`, clears temp-unschedulable, sets `schedulable=true`, invalidates stale token cache, and retries account selection once in the original request.
  Proof logs:
  ```text
  token_refresh.openai_codex_auth_file_recovered
  openai_codex_auth_file_recovery_selection_retrying
  ```
  If the host auth file is missing, unchanged, invalid, or expired, patched sub2api returns `401 authentication_error` with `Run codex login on the host`; that is expected and more truthful than `503 Service temporarily unavailable`. Do not perform routine manual SQL reset for this class. Run `codex login` on the host that owns `%USERPROFILE%\.codex\auth.json`; the scheduled self-heal will sync the refreshed file on its next pass, or run `scripts/ensure-sub2api-proxy-stack.ps1` once to sync immediately. Do not print copied auth files or token values.
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
- Reset-credit and external-reset recovery are separate paths. A successful `POST /api/v1/admin/openai/accounts/:id/reset-quota` now calls `ClearModelRateLimits`, which updates Postgres and synchronizes the scheduler snapshot before returning success. A reset performed directly on the ChatGPT/OpenAI site cannot notify sub2api, so quota-origin model cooldowns become eligible for a same-model upstream reprobe one minute after `rate_limited_at`, even if the old weekly `rate_limit_reset_at` is days away. This is not a model fallback: `gpt-5.6-sol` probes `gpt-5.6-sol`. A real continuing upstream 429 rewrites `rate_limited_at` and closes the account for another minute; a successful response persists fresh Codex headroom and removes the old `model_rate_limits` entry.
- Prove this recovery from all three layers: the Claude Code command succeeds on the same requested model, `usage_logs.model_mapping_chain` remains `gpt-5.6-sol->gpt-5.6-sol` with the requested effort, and the account row changes from the old quota-origin entry to `extra.model_rate_limits = {}`. The runtime log must include `openai_codex_cooldown_recovery_cleared_model_rate_limits`. Do not manually delete the row before this proof, and do not add a fallback to mask a stale-lock bug.
- 2026-07-10 regression fixed in the local fork: the OpenAI/Codex no-account diagnoser now inspects both global `accounts.rate_limit_reset_at` and model-scoped `accounts.extra.model_rate_limits[model].rate_limit_reset_at`. Before this fix, a real `gpt-5.6-sol` model cooldown could be selected out by the scheduler but diagnosed as generic service unavailability, so Claude Code saw `503` instead of `429`. Live verification after rebuilding `sub2api-codex:local-token-usage`: `/v1/messages` for `gpt-5.6-sol` during active cooldown returned `HTTP_STATUS=429` with `rate_limit_error` and reset timestamp; `ops_error_logs` row `3654` recorded `status_code=429`, `error_type=rate_limit_error`.
- Alibaba Token Plan terminal exhaustion is a separate `F30` class. Match status 429 plus code `Throttling.AllocationQuota` plus message fragments `token-plan` and `quota has been exhausted`; parse `reset at MM-DD HH:MM:SS UTC`, persist it as the Alibaba account-wide circuit, and use a five-minute reprobe only if the terminal body omits or corrupts the reset. Do not classify a generic/transient `AllocationQuota` response as terminal.
- The group candidate `qwen3.8-max-preview -> gpt-5.6-sol` is consumed only by automatic compact and `external,sdk-cli` routes. The first terminal failure may switch before response bytes; while every matching Qwen account has the persisted quota circuit open, later automatic requests go straight to Sol/high without probing upstream Qwen. A generic scheduler miss is not sufficient. Direct interactive Qwen, generic 429/5xx, auth/context/model errors after account selection, and mid-stream errors do not switch providers. Terminal-quota logs must show `alibaba_token_plan_quota_exhausted`; every actual provider switch must show `claude_code.automatic_cross_provider_fallback`.

If `/v1/models` lists `gpt-5.5-mini`, `gpt-5.6-*`, Qwen/GLM/DeepSeek Token Plan names but requests fail:

- Trust the request-time upstream response over the model list. `/v1/models` is an advertisement/catalog surface; the ChatGPT/Codex account entitlement is enforced on `/v1/messages`.
- Do not silently alias `gpt-5.5-mini` to `gpt-5.5`. That hides unsupported-model bugs and makes speed/quality tests invalid.
- Current verified behavior on 2026-07-22 after the Qwen-high picker correction: direct sub2api and restarted Headroom `/v1/models` returned 23 explicit models, GPT/Codex plus Alibaba Token Plan only. A tiny `qwen3.8-max-preview` request routes to the Alibaba Token Plan account with `reasoning_effort=high`; `glm-5.2` and `deepseek-v4-pro` also route to the Alibaba Token Plan account with no `pricing not found` error.
- Spark is officially 128k and text-only with separate research-preview rate limits. It remains a supported direct model and legacy compact candidate, but the current small-fast/subagent/compact default is Qwen high.

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
- In the old 5.5 setup, `/400k` was disproven by upstream `context_length_exceeded` around `272k-278k` estimated input tokens. Do not generalize that old 5.5 evidence to GPT-5.6. GPT-5.6 Sol/Terra/Luna are configured locally with `max_input_tokens=1050000`; use clean `gpt-5.6-sol` plus Qwen-high small-fast/subagent/compact labels, and keep the Claude Code client compact/display target at 370k/340k unless a fresh long-context probe proves a better safe threshold.

Headroom Docker stack:

- If the Windows verifier reports `[rtk hook] Failed to parse JSON input: expected value at line 1 column 1` while the installed hook itself is healthy, check the verifier transport before reinstalling RTK. Windows PowerShell 5.1 does not reliably preserve UTF-8 JSON when piping a native-command result directly into Git Bash. The installer and verifier must use `Invoke-GitBashUtf8Stdin`: UTF-8 encode the payload, pass it as base64, decode it inside Git Bash, then invoke the exact installed hook command. Run the full verifier without `-SkipRtkProbe`; a green probe must return `updatedInput.command = rtk git status`.
- Keep the Headroom HTTP proxy, RTK, lean-ctx, TokenSave, ast-grep, difft, and scc inside the Docker image for this profile. Claude Code should use a Docker-backed `headroom` MCP, not stale `%USERPROFILE%\.local\bin\headroom.exe` or `tokensave.exe` paths.
- Keep Headroom `--embedding-server` enabled in this image. The image must build from `HEADROOM_GIT_REPO=https://github.com/stgmt/headroom.git` at pinned `HEADROOM_GIT_REF`, with the local patch scripts retained as idempotent guardrails. If logs show `No module named 'headroom.memory.adapters.watchdog'` or `Falling back to per-worker embedder`, the image is stale, built from the wrong source, or built without `patch-headroom-embedding-server.py`. Rebuild `headroom-sub2api:0.31.0`, recreate the `headroom` service, verify compose labels point at `stgmt/headroom`, then verify logs show `Embedding server: ready.`
- Keep the Claude Code streaming-overlap patch in the Headroom image too. If it is missing, a background agent or fast follow-up main turn can race the previous stream cleanup, Headroom can return private HTTP 202 `headroom_queued`, and Claude Code reports `Stream ended without receiving any events` while still waiting for background agents.
- Preserve all data across recreates on host bind mounts. `/root/.headroom` must be a host bind mount and should contain `ccr_store.db` after memory traffic. `/root/.cache/headroom`, `/root/.cache/huggingface`, `/app/data`, Postgres parent `/var/lib/postgresql`, and Redis `/data` should also be host bind mounts under `${SUB2API_STATE_ROOT:-./data}`. Do not bind the same Postgres host directory directly to `/var/lib/postgresql/data`: `postgres:18-alpine` declares `/var/lib/postgresql` as a volume and that nested layout can make `initdb` loop on a non-empty data dir. If `docker inspect` shows `Type=volume`, the profile is wrong. Do not delete the state root unless intentionally wiping memory and all service state.
- Do this audit proactively whenever editing compose/setup/docs for this stack. Do not wait for the user to point out that Docker named volumes can hide or strand data. A "reusable" fix is not done until the verifier proves host `Type=bind` mounts for every stateful service.
- If a fresh install loses RTK/lean-ctx/difft/scc after adding persistent mounts, the image bootstrap wrapper is missing or stale. Rebuild from a Dockerfile that copies `start-headroom-proxy.sh`, seeds `/opt/headroom-seed`, and uses `ENTRYPOINT ["/usr/local/bin/start-headroom-proxy"]`.
## Hyper-V endpoint is stale while Docker is healthy

If a native Linux Claude window reports `Unable to connect to API (ConnectionRefused)` and names an address on the Hyper-V Default Switch, compare four live values before restarting containers: the address in that Claude host's `~/.claude/settings.json`, the current `vEthernet (Default Switch)` IPv4, the current VM IPv4, and the current WSL `eth0` IPv4. Hyper-V Default Switch and WSL addresses can both change after a reboot. A healthy `headroom-sub2api` container does not repair a stale Windows `portproxy` by itself.

If Linux `journalctl` records `systemd-logind: The system will power off now` and Docker receives `SIGTERM`, a logon-only Windows task cannot recover the stack: its trigger already completed successfully. The single owner task must call `ensure-sub2api-proxy-stack.ps1` every minute. Healthy checks must be probe-only; a failed same-host or Hyper-V bridge route must wake WSL through the canonical start script, restore compose and dynamic `portproxy`, and emit `recovery_started` followed by `recovered`. `ConnectionRefused` happens before HTTP, so Headroom/sub2api cannot retry or translate it while WSL is down.

Configure `hyperv-bridge.env` and run the single elevated `Sub2API Codex Proxy Stack Autostart` task. Its proof must include one current `v4tov4` entry, a firewall rule restricted to the current VM address, `UPDATED_BASE_URL=...`, and `HYPERV_HEADROOM_HEALTH_OK` from SSH inside the VM. Install `node`, a `python` command (or update hooks to `python3`), and the expected home-level hook runner in the VM itself when project hooks execute there. Restart an already-running Claude process after these changes.

For a Windows Hyper-V guest, set `HEADROOM_HYPERV_REMOTE_CONFIG_MODE=none`, use the stable Default Switch URL in the guest, and restart Claude. If a `UserPromptSubmit` hook reports `/usr/bin/bash: .../Microsoft/WindowsApps/python: Permission denied`, that is a separate guest-local runtime defect: Git Bash resolved the Microsoft Store app-execution alias instead of a real interpreter. Verify `where.exe python`, `where.exe py`, and the hook command inside that VM; install a real Python runtime or point the hook to its real executable. The hook is explicitly non-blocking and cannot explain a simultaneous proxy-side 404 or a reset that never reached Headroom.

## Giant non-stream request loops after an empty response

Do not classify every `stream:false` request as a bug. Native compact is intentionally non-streaming and must have Claude debug `source=compact`, Headroom's compact marker, and Spark/Luna compact routing in sub2api. The failure pattern is a normal turn replayed by Claude Code's emergency non-streaming fallback: the request lacks the compact marker, retains the main Sol route, and can be substantially larger than the original stream. If upstream repeatedly completes that request without assistant content or tool output, sub2api's bounded same-account retries correctly stop, but Claude Code can resubmit the whole request for many minutes.

Keep `CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK=1` in every host that launches Claude Code, not just Windows. Correlate the Claude transcript timestamp with `ops_error_logs.request_id`, `stream`, and sub2api `body_bytes`; then test a fresh process through the same host namespace. Do not add a model fallback for this symptom unless the user asks for one.

## Native Linux hooks report `node` or `python` not found

Repeated `UserPromptSubmit hook error` lines such as `/bin/sh: node: not found` or `/bin/sh: python: not found` are local Claude-host failures. They can appear beside a gateway error, but they are not emitted by Headroom or sub2api. Check the exact Linux user that launches Claude Code:

```bash
command -v node npm npx python python3
test -f "$HOME/.dev-pomogator/scripts/tsx-runner.js"
test -x "$HOME/.dev-pomogator/node_modules/.bin/tsx"
```

Install a current Node.js LTS runtime in that host, provide `python` through the distro's `python-is-python3` package or an equivalent `/usr/local/bin/python -> /usr/bin/python3` link, and restore the generated dev-pomogator runner plus its `tsx` dependency for that user. Then start a fresh Claude process in the affected project and run a one-turn `claude --print` probe. A resolver stack printed inside a successful hook result is a separate project import-resolution problem; do not report it as `node not found` after the hook exits successfully.

## RTK cannot parse Windows Claude settings

If `rtk init --global --auto-patch` reports `expected value at line 1 column 1` while PowerShell `ConvertFrom-Json` accepts the same file, inspect its first bytes. `EF-BB-BF` is a UTF-8 BOM. Windows PowerShell 5.1 `Set-Content -Encoding UTF8` adds that BOM, while strict Node/Rust JSON parsers may reject it. The stack autostart must write `~/.claude/settings.json` through `Write-Utf8NoBom`; rewrite an already affected file without changing its JSON object, then rerun the RTK installer and verifier.

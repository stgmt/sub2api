# Verification Playbook

Commands and expected evidence for health checks, Claude Code probes, usage_logs, compact routing, and context display verification.

## Contents

- [Verification](#verification)

## Verification

Use the bundled verifier:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-claude-code-sub2api.ps1
```

Manual checks:

```powershell
$env:ANTHROPIC_BASE_URL = [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User")
$env:ANTHROPIC_AUTH_TOKEN = [Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "User")
$env:ANTHROPIC_MODEL = [Environment]::GetEnvironmentVariable("ANTHROPIC_MODEL", "User")
$env:ANTHROPIC_SMALL_FAST_MODEL = [Environment]::GetEnvironmentVariable("ANTHROPIC_SMALL_FAST_MODEL", "User")
$env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_MAX_CONTEXT_TOKENS", "User")
$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "User")
$env:CLAUDE_CODE_MAX_OUTPUT_TOKENS = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_MAX_OUTPUT_TOKENS", "User")
$env:MAX_THINKING_TOKENS = [Environment]::GetEnvironmentVariable("MAX_THINKING_TOKENS", "User")
$effortOverride = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_EFFORT_LEVEL", "User")
if ($effortOverride) { throw "Clear User env CLAUDE_CODE_EFFORT_LEVEL=$effortOverride; it overrides /effort in Claude Code." }

Invoke-RestMethod "http://127.0.0.1:8787/health"
Invoke-RestMethod "http://127.0.0.1:18081/health"
(Invoke-RestMethod "http://127.0.0.1:8787/stats").rate_limiter | ConvertTo-Json -Compress
node scripts/test-headroom-rate-limit-burst.mjs http://127.0.0.1:8787 96
Get-ScheduledTask -TaskName "Sub2API Codex Proxy Stack Autostart" | Select-Object TaskName,State,@{n="RunLevel";e={$_.Principal.RunLevel}},@{n="Action";e={$_.Actions.Arguments}}
Get-ScheduledTask | Where-Object { $_.TaskName -eq "headroom-proxy" -or ($_.Actions.Arguments -match "headroom-proxy|headroom.exe proxy") }
claude mcp list
wsl.exe -- docker exec headroom-sub2api headroom tools doctor
wsl.exe -- docker exec headroom-sub2api headroom savings --json
wsl.exe -- docker exec headroom-sub2api headroom perf --hours 1 --format json
wsl.exe -- docker exec headroom-sub2api sh -lc "test -x /usr/local/bin/start-headroom-proxy && test -d /opt/headroom-seed/headroom && test -d /opt/headroom-seed/cache-headroom && echo SEED_OK"
wsl.exe -- docker logs --tail 120 headroom-sub2api
wsl.exe -- docker inspect headroom-sub2api --format '{{range .Mounts}}{{println .Destination "|" .Type "|" .Name "|" .Source}}{{end}}'
wsl.exe -- docker inspect sub2api-codex sub2api-codex-postgres sub2api-codex-redis --format '{{.Name}} {{range .Mounts}}{{println .Destination "|" .Type "|" .Source}}{{end}}'
wsl.exe -- docker exec headroom-sub2api python -c "import os; p='/root/.headroom/ccr_store.db'; print('CCR_STORE', os.path.exists(p), os.path.getsize(p) if os.path.exists(p) else 0)"
wsl.exe -- docker exec headroom-sub2api sh -lc "test -S /tmp/headroom-embed-8787.sock && echo SOCKET_OK"
wsl.exe -- docker exec headroom-sub2api python -c "import os; os.environ['HEADROOM_EMBEDDING_SERVER_SOCKET']='/tmp/headroom-embed-8787.sock'; from headroom.memory.config import MemoryConfig, EmbedderBackend; from headroom.memory.factory import _create_embedder; e=_create_embedder(MemoryConfig(embedder_backend=EmbedderBackend.ONNX)); print(type(e).__module__, type(e).__name__, e.dimension)"

rtk --version
rtk gain --format json
wsl.exe -- docker exec headroom-sub2api rtk gain --format json
wsl.exe -- docker exec headroom-sub2api headroom perf --format json

claude --model $env:ANTHROPIC_MODEL --effort max --print --no-session-persistence "/context"
claude --model $env:ANTHROPIC_MODEL --effort max --print --output-format json --no-session-persistence "Reply exactly: OK_SUB2API"
```

Expected for the safe profile:

```text
Model: gpt-5.6-sol
Tokens: ... / 370k
JSON modelUsage contextWindow matches the configured Claude Code client target, currently 370000 with auto-compact at 340000; this is the Claude Code client window hint, while upstream context failures must still be verified from proxy logs
JSON modelUsage may still show maxOutputTokens: 32000
Headroom health reports ready and upstream http://sub2api:8080
Headroom `/stats.rate_limiter` reports at least 6000 RPM and 100000000 TPM; the 96-way invalid-key burst reports `rate_limited=0` and never exposes a local 429 to Claude Code
sub2api health reports ok on the direct diagnostic/admin port
Windows autostart is single-owner: `Sub2API Codex Proxy Stack Autostart` exists, `RunLevel=Highest`, action calls `ensure-sub2api-proxy-stack.ps1`, triggers include logon plus `PT1M` repetition, settings include at least three one-minute retries and `IgnoreNew`, `LastTaskResult=0` after a manual `Start-ScheduledTask`, stale `headroom-proxy` is absent, and Startup-folder proxy launchers are absent or renamed with `.disabled`
Controlled self-heal proof passes: stop the WSL distro or remove the owned Headroom `portproxy`, observe `recovery_started` then `recovered` in `logs/self-heal.jsonl`, and require Windows localhost plus Hyper-V VM `/health` to return 200 within two watchdog intervals without manually starting WSL or Docker
Claude MCP list shows headroom connected through Docker; stale host headroom.exe/tokensave.exe entries are absent
Headroom tools doctor shows difft, scc, and ast-grep on PATH; the image also includes rtk, lean-ctx, and tokensave
Headroom image bootstrap check returns `SEED_OK`; the entrypoint seeds empty persistent mounts from `/opt/headroom-seed` before launching the proxy
Headroom, sub2api, Postgres, and Redis state mounts are Docker `bind` mounts to host paths under `${SUB2API_STATE_ROOT:-./data}`, not Docker named volumes; after memory/embedding traffic, `/root/.headroom/ccr_store.db` is non-empty
Headroom `/root/.local/share/rtk` is a Docker `bind` mount to host RTK state, and host/container `rtk gain --format json` totals match
Claude settings contain exactly one `PreToolUse(Bash)` RTK hook, its command includes `MSYS2_ARG_CONV_EXCL='*'`, and the verifier successfully runs it through Git Bash
After a real fresh Claude Code Bash call, RTK `total_commands` increases and debug logs show `Hook PreToolUse:Bash ... success` plus `modified tool input keys`; an unchanged counter is a failed integration even if the model replies successfully
`cat`, `git diff`, `git show`, and `curl` probes produce no rewrite output
Headroom logs show `Embedding server: ready.` and do not show `Falling back to per-worker embedder`, `No module named 'headroom.memory.adapters.watchdog'`, or `ModuleNotFound`
`/tmp/headroom-embed-8787.sock` exists, the memory factory returns `headroom.memory.adapters.watchdog SocketEmbedderClient 384` when `HEADROOM_EMBEDDING_SERVER_SOCKET` is set, and a direct `SocketEmbedderClient.embed(...)` probe returns `EMBED_OK 384`
Headroom savings/perf shows nonzero proxy traffic after Claude Code has used the proxy; `perf.cli_filtering` reports `tool=rtk` with nonzero commands and tokens saved
User env CLAUDE_CODE_EFFORT_LEVEL is absent; /effort can change the session effort
```

Check sub2api logs or Postgres:

```powershell
wsl.exe -- bash -lc 'docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F " | " -Atc "select id, requested_model, upstream_model, reasoning_effort, model_mapping_chain, input_tokens, created_at from usage_logs order by id desc limit 5;"'
```

Expected:

```text
requested_model = gpt-5.6-sol, gpt-5.3-codex-spark, legacy gpt-5.5[400k], or claude-opus/sonnet/haiku aliases for normal work
upstream/response model = gpt-5.6-sol for main work, gpt-5.6-terra for Sonnet, gpt-5.3-codex-spark for small-fast/Haiku when schedulable, or gpt-5.6-luna when Spark fallback takes over
reasoning_effort = max for GPT-5.6 max requests on the current Codex/OpenAI Responses route; a clamp log with upstream_effort=xhigh means the running image or docs are stale
model_mapping_chain includes -> gpt-5.6-sol, -> gpt-5.6-terra, -> gpt-5.3-codex-spark, and -> gpt-5.6-luna for Spark fallback
```

For `general-purpose` subagent model checks:

```powershell
Get-Content "$env:USERPROFILE\.claude\agents\general-purpose.md"
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*run-claude-pipe-status-worker.ps1*' } | Select-Object ProcessId,CommandLine
wsl.exe -- docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F " | " -Atc "select requested_model, model_mapping_chain, count(*), sum(input_tokens), sum(output_tokens) from usage_logs where created_at > now() - interval '30 minutes' group by requested_model, model_mapping_chain order by 1,2;"
```

Expected for the current advisory subagent profile:

```text
general-purpose.md / Explore.md / workflow-subagent.md frontmatter model: gpt-5.6-terra-medium and effort: medium
worker/Claude command line includes -Model "gpt-5.6-terra-medium" or --model gpt-5.6-terra-medium
usage_logs rows show requested_model=gpt-5.6-terra-medium, upstream_model=gpt-5.6-terra, reasoning_effort=medium
fallback proof for empty/unavailable Terra-medium turns: usage_logs should show requested_model=gpt-5.6-terra-medium, model_mapping_chain including gpt-5.6-sol, and reasoning_effort=medium after fallback; direct alias probe `claude --print --model gpt-5.6-sol-mid ...` should record upstream_model=gpt-5.6-sol and reasoning_effort=medium
no global Agent-blocking PreToolUse/SubagentStart/SubagentStop hook is installed unless the user explicitly requested a hard cap
```

For manual `/compact`, do not trust Claude Code's `modelUsage` display. Verify the proxy reroute with:

```powershell
wsl.exe -- docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F " | " -Atc "select id, created_at at time zone 'Europe/Moscow', requested_model, coalesce(upstream_model,''), coalesce(reasoning_effort,''), input_tokens, output_tokens, duration_ms, left(coalesce(model_mapping_chain,''),120) from usage_logs where inbound_endpoint='/v1/messages' order by id desc limit 20;"
```

Expected compact row after the local patch:

```text
requested_model=gpt-5.6-sol, gpt-5.3-codex-spark, gpt-5.6-luna, or a Claude alias
upstream_model=gpt-5.3-codex-spark normally, or gpt-5.6-luna when Spark was rate-limited/unavailable, rejected image inputs, and Luna is schedulable
reasoning_effort is empty for Spark; inherited parent max/xhigh/low is a regression. Luna fallback chunk requests keep their configured low effort
model_mapping_chain=gpt-5.6-sol->gpt-5.3-codex-spark, gpt-5.6-terra->gpt-5.3-codex-spark, or gpt-5.6-luna->gpt-5.3-codex-spark normally, with ->gpt-5.6-luna when the fallback chain takes over
```

For large compact fallback specifically, also check logs:

```powershell
wsl.exe -- bash -lc 'docker logs --since 20m sub2api-codex 2>&1 | grep -E "compact_context_length_fallback|compact_model_unavailable_fallback|compact_chunk_model_unavailable_switching|context_length_exceeded" | tail -n 120'
```

Expected when the full compact could not fit the mapped compact model:

```text
openai_messages.compact_context_length_fallback
```

For a pure context-overflow fallback while Spark is available, the final `usage_logs` row should still be successful with `upstream_model=gpt-5.3-codex-spark`; the aggregate input/output tokens include the chunk summaries and merge pass.
If Spark was unavailable, quota-limited, or rejected image blocks, the final successful compact row should use `gpt-5.6-luna`; logs should include `openai_messages.compact_model_unavailable_fallback`. For image-bearing transcripts the logged upstream message should contain `does not support image inputs`. There is no mini-model fallback.

Headroom proof for the same native request:

```powershell
wsl.exe -- docker exec headroom-sub2api python -c "import json,pathlib; rows=[json.loads(x) for x in pathlib.Path('/root/.headroom/logs/proxy-requests.jsonl').read_text(encoding='utf-8').splitlines()[-300:] if x.strip()]; print(next((r for r in reversed(rows) if 'headroom:claude_code_compact_prompt_preserved' in str(r)), None))"
```

The matching record must contain `headroom:claude_code_compact_prompt_preserved` and must not contain an output-shaper transform. Correlate its UTC timestamp with the fork session JSONL `/compact` command and the final `usage_logs` row. The Claude Code status-line model remains the session model and is not evidence of the compact upstream model.

For source-level compact fallback evals and micro-benchmarks in the local fork:

```powershell
cd .\backend
go test .\internal\service -run 'Test(OpenAICompactModelUnavailableHTTPFallsBackForSparkImageInput|RetryAnthropicCompactFallbackSummaries|BuildAnthropicCompact|AnthropicCompactQualityContract|ForwardAsAnthropic_ClaudeCodeCompact|ForwardAsAnthropic_HeadroomCompactHeader)' -bench BenchmarkAnthropicCompactFallbackGrouping -benchtime=200ms -count=1
go test .\internal\pkg\apicompat -run 'Anthropic|Responses' -count=1
```

Expected: service tests pass, apicompat tests pass, and the benchmark reports low single-digit milliseconds for local grouping/emergency-cap work. This benchmark does not include upstream model latency.

For Anthropic `/v1/messages` SSE compatibility after wait-ping/concurrency:

```powershell
cd .\backend
go test .\internal\handler -run 'Test(SSEPingFormatClaude|GatewayHandleStreamingAwareError|OpenAIEnsureAnthropicErrorResponse|OpenAIHandleAnthropicFailoverExhausted|OpenAIHandleStreamingAwareError)' -count=1
go test .\internal\handler -count=1
```

Expected: wait-ping/comment is followed by a named Anthropic `event: error`, not a bare JSON/data-only frame; failover-exhausted preserves upstream Anthropic error bodies; normal streams keep exactly one `message_start`; OpenAI `/responses` still emits `event: response.failed`. Mutation sanity check: reverting native `/v1/messages` to data-only error or disabling the `streamStarted` SSE branch must fail these tests.

For the Headroom Claude Code streaming-overlap downstream patch:

```powershell
python .\deploy\claude-code-codex-headroom\test_headroom_claude_code_streaming_patch.py
python .\deploy\claude-code-codex-headroom\mutate_headroom_claude_code_streaming_patch_tests.py
```

Expected: the test builds a fake `headroom-ai==0.31.0` install layout, applies `patch-headroom-claude-code-streaming.py`, proves the unsafe `return JSONResponse(content=queued, status_code=202)` branch is gone, proves the patch is idempotent, proves `x-claude-code-session-id` plus `x-claude-code-agent-id` becomes the active stream key, and proves a mutated/unknown Anthropic overlap branch fails closed instead of silently producing a partial patch.
Mutation expected: all bundled mutants are killed. The suite intentionally breaks the Anthropic no-202 patch, Claude agent-id session key, active-stream refcount patch, unknown-shape fail-closed guard, and idempotency guard.

For the current sub2api source path:

```text
Anthropic max_tokens -> OpenAI max_output_tokens
Anthropic output_config.effort=max -> OpenAI reasoning.effort=max for GPT-5.6; gpt-5.3-codex-spark omits reasoning.effort entirely; other legacy models without max support may downgrade max to xhigh
Anthropic thinking.budget_tokens -> parsed but ignored by the Responses converter
```

`/v1/messages` probes should normally go through Headroom at `ANTHROPIC_BASE_URL=http://127.0.0.1:8787`. Direct sub2api probes on `http://127.0.0.1:18081` are useful only to isolate Headroom from sub2api. The route can accept `max_tokens=64000` plus `thinking.budget_tokens=63999`, but Claude Code CLI probes may still report `modelUsage.maxOutputTokens=32000`. Treat that as a Claude Code client/model-metadata cap, not a sub2api cap.

Audit empty/ghost streams:

```powershell
wsl.exe -- bash -lc 'docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F " | " -Atc "select requested_model, reasoning_effort, count(*) filter (where input_tokens=0 and output_tokens=0 and stream=true and duration_ms between 500 and 30000) as zero_streams, count(*) as total from usage_logs where created_at > now() - interval '\''90 minutes'\'' and inbound_endpoint='\''/v1/messages'\'' group by requested_model, reasoning_effort order by zero_streams desc, total desc;"'
```

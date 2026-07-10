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

claude --model $env:ANTHROPIC_MODEL --effort max --print --no-session-persistence "/context"
claude --model $env:ANTHROPIC_MODEL --effort max --print --output-format json --no-session-persistence "Reply exactly: OK_SUB2API"
```

Expected for the safe profile:

```text
Model: gpt-5.6-sol
Tokens: ... / 260k
JSON modelUsage contextWindow: 400000 when using the conservative Claude Code client compact target; this does not prove the upstream model window
JSON modelUsage may still show maxOutputTokens: 32000
```

Check sub2api logs or Postgres:

```powershell
wsl.exe -- bash -lc 'docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F " | " -Atc "select id, requested_model, upstream_model, reasoning_effort, model_mapping_chain, input_tokens, created_at from usage_logs order by id desc limit 5;"'
```

Expected:

```text
requested_model = gpt-5.6-sol, gpt-5.3-codex-spark, legacy gpt-5.5[400k], or claude-opus/sonnet/haiku aliases for normal work
upstream/response model = gpt-5.6-sol for main work, gpt-5.6-terra for Sonnet, gpt-5.3-codex-spark for small-fast/Haiku when schedulable, gpt-5.6-luna when Spark fallback takes over, or gpt-5.4-mini when both Spark and Luna are unavailable
reasoning_effort = xhigh
model_mapping_chain includes -> gpt-5.6-sol, -> gpt-5.6-terra, -> gpt-5.3-codex-spark, -> gpt-5.6-luna for Spark fallback, and -> gpt-5.4-mini for final fallback
```

For manual `/compact`, do not trust Claude Code's `modelUsage` display. Verify the proxy reroute with:

```powershell
wsl.exe -- docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F " | " -Atc "select id, created_at at time zone 'Europe/Moscow', requested_model, coalesce(upstream_model,''), coalesce(reasoning_effort,''), input_tokens, output_tokens, duration_ms, left(coalesce(model_mapping_chain,''),120) from usage_logs where inbound_endpoint='/v1/messages' order by id desc limit 20;"
```

Expected compact row after the local patch:

```text
requested_model=gpt-5.6-sol, gpt-5.3-codex-spark, gpt-5.6-luna, or a Claude alias
upstream_model=gpt-5.3-codex-spark normally, gpt-5.6-luna when Spark was rate-limited/unavailable and Luna is schedulable, or gpt-5.4-mini when both Spark and Luna fallback fail
model_mapping_chain=gpt-5.6-sol->gpt-5.3-codex-spark, gpt-5.6-terra->gpt-5.3-codex-spark, or gpt-5.6-luna->gpt-5.3-codex-spark normally, with ->gpt-5.6-luna->gpt-5.4-mini when the fallback chain takes over
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
If Spark was unavailable or quota-limited, the final successful compact row should use `gpt-5.6-luna` first, then `gpt-5.4-mini` only if Luna is also unavailable; logs should include the compact model fallback event. This is expected; do not change Claude Code global small-fast/subagent env to mini.

For source-level compact fallback evals and micro-benchmarks in the local fork:

```powershell
cd .\backend
go test .\internal\service -run 'Test(RetryAnthropicCompactFallbackSummaries|BuildAnthropicCompact|AnthropicCompactQualityContract|ForwardAsAnthropic_ClaudeCodeCompact)' -bench BenchmarkAnthropicCompactFallbackGrouping -benchtime=200ms -count=1
go test .\internal\pkg\apicompat -run 'Anthropic|Responses' -count=1
```

Expected: service tests pass, apicompat tests pass, and the benchmark reports low single-digit milliseconds for local grouping/emergency-cap work. This benchmark does not include upstream model latency.

For the current sub2api source path:

```text
Anthropic max_tokens -> OpenAI max_output_tokens
Anthropic output_config.effort=max -> OpenAI reasoning.effort=xhigh
Anthropic thinking.budget_tokens -> parsed but ignored by the Responses converter
```

Direct `/v1/messages` probes through sub2api can accept `max_tokens=64000` plus `thinking.budget_tokens=63999`, but Claude Code CLI probes may still report `modelUsage.maxOutputTokens=32000`. Treat that as a Claude Code client/model-metadata cap, not a sub2api cap.

Audit empty/ghost streams:

```powershell
wsl.exe -- bash -lc 'docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F " | " -Atc "select requested_model, reasoning_effort, count(*) filter (where input_tokens=0 and output_tokens=0 and stream=true and duration_ms between 500 and 30000) as zero_streams, count(*) as total from usage_logs where created_at > now() - interval '\''90 minutes'\'' and inbound_endpoint='\''/v1/messages'\'' group by requested_model, reasoning_effort order by zero_streams desc, total desc;"'
```

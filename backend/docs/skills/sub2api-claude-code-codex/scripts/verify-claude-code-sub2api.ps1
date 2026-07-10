param(
  [string]$BaseUrl = [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User"),
  [string]$ApiKey = [Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "User"),
  [string]$Model = [Environment]::GetEnvironmentVariable("ANTHROPIC_MODEL", "User"),
  [string]$SmallFastModel = [Environment]::GetEnvironmentVariable("ANTHROPIC_SMALL_FAST_MODEL", "User"),
  [string]$ExpectedUpstream = "gpt-5.6-sol",
  [switch]$SkipClaudeProbe,
  [switch]$SkipDockerLogs
)

$ErrorActionPreference = "Stop"

if (-not $BaseUrl) { $BaseUrl = "http://127.0.0.1:18081" }
if (-not $Model) { $Model = "gpt-5.6-sol" }
if (-not $SmallFastModel) { $SmallFastModel = "gpt-5.3-codex-spark" }

Write-Host "Base URL: $BaseUrl"
Write-Host "Model: $Model"
Write-Host "Small-fast model: $SmallFastModel"
Write-Host "Has API token: $([bool]$ApiKey)"

try {
  $health = Invoke-WebRequest -UseBasicParsing "$BaseUrl/health" -TimeoutSec 10
  Write-Host "Health: $($health.StatusCode) $($health.Content)"
} catch {
  Write-Warning "Health check failed: $($_.Exception.Message)"
}

if (-not $SkipClaudeProbe) {
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warning "claude command not found; skipping Claude Code probes."
  } else {
    $env:ANTHROPIC_BASE_URL = $BaseUrl
    $env:ANTHROPIC_AUTH_TOKEN = $ApiKey
    $env:ANTHROPIC_MODEL = $Model
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $SmallFastModel
    $env:ANTHROPIC_SMALL_FAST_MODEL = $SmallFastModel
    $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_MAX_CONTEXT_TOKENS", "User")
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "User")
    $env:CLAUDE_CODE_MAX_OUTPUT_TOKENS = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_MAX_OUTPUT_TOKENS", "User")
    $env:MAX_THINKING_TOKENS = [Environment]::GetEnvironmentVariable("MAX_THINKING_TOKENS", "User")
    # Claude Code falls back to 200k for custom/proxy models unless these are explicit.
    if (-not $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS) { $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = "1050000" }
    if (-not $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW) { $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = "1000000" }
    if (-not $env:CLAUDE_CODE_MAX_OUTPUT_TOKENS) { $env:CLAUDE_CODE_MAX_OUTPUT_TOKENS = "64000" }
    if (-not $env:MAX_THINKING_TOKENS) { $env:MAX_THINKING_TOKENS = "8000" }
    Write-Host "Output guard: $env:CLAUDE_CODE_MAX_OUTPUT_TOKENS"
    Write-Host "Thinking guard: $env:MAX_THINKING_TOKENS"

    Write-Host "`n/context:"
    claude --model $Model --effort max --print --no-session-persistence "/context"

    Write-Host "`nJSON probe:"
    $jsonRaw = claude --model $Model --effort max --print --output-format json --no-session-persistence "Reply exactly: OK_SUB2API_VERIFY"
    $json = $jsonRaw | ConvertFrom-Json
    $usage = $json.modelUsage.PSObject.Properties | Select-Object -First 1
    [pscustomobject]@{
      result = $json.result
      usage_model = $usage.Name
      contextWindow = $usage.Value.contextWindow
      maxOutputTokens = $usage.Value.maxOutputTokens
    } | ConvertTo-Json -Compress

    if ($SmallFastModel -ne $Model) {
      Write-Host "`nSmall-fast JSON probe:"
      $smallRaw = claude --model $SmallFastModel --effort low --print --output-format json --no-session-persistence "Reply exactly: OK_SUB2API_SMALL_FAST"
      $smallJson = $smallRaw | ConvertFrom-Json
      [pscustomobject]@{
        result = $smallJson.result
        model = $SmallFastModel
      } | ConvertTo-Json -Compress
    }
  }
}

if (-not $SkipDockerLogs) {
  if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    function Quote-BashSingle([string]$Value) {
      return "'" + $Value.Replace("'", "'\''") + "'"
    }

    Write-Host "`nRecent usage logs:"
    $recentUsageSql = "select id, requested_model, upstream_model, reasoning_effort, model_mapping_chain, input_tokens, created_at from usage_logs order by id desc limit 5;"
    wsl.exe -- bash -lc "docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F ',' -Atc $(Quote-BashSingle $recentUsageSql)"
    Write-Host "`n0/0 ghost-stream audit:"
    $ghostStreamSql = "select requested_model, reasoning_effort, count(*) filter (where input_tokens=0 and output_tokens=0 and stream=true and duration_ms between 500 and 30000) as zero_streams, count(*) as total from usage_logs where created_at > now() - interval '90 minutes' and inbound_endpoint='/v1/messages' group by requested_model, reasoning_effort order by zero_streams desc, total desc;"
    wsl.exe -- bash -lc "docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F ',' -Atc $(Quote-BashSingle $ghostStreamSql)"
  } else {
    Write-Warning "wsl.exe not found; skipping Postgres usage log check."
  }
}

Write-Host "`nExpected main model in usage_logs: $ExpectedUpstream"
Write-Host "Expected small-fast requested_model in usage_logs: $SmallFastModel"

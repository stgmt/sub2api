param(
  [string]$BaseUrl = [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User"),
  [string]$Sub2apiBaseUrl = "http://127.0.0.1:18081",
  [string]$ApiKey = [Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "User"),
  [string]$Model = [Environment]::GetEnvironmentVariable("ANTHROPIC_MODEL", "User"),
  [string]$SmallFastModel = [Environment]::GetEnvironmentVariable("ANTHROPIC_SMALL_FAST_MODEL", "User"),
  [string]$DefaultHaikuModel = [Environment]::GetEnvironmentVariable("ANTHROPIC_DEFAULT_HAIKU_MODEL", "User"),
  [string]$SubagentModel = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_SUBAGENT_MODEL", "User"),
  [string]$ExpectedUpstream = "gpt-5.6-sol",
  [string]$ProjectName = "sub2api-codex",
  [switch]$SkipApiProbe,
  [switch]$SkipClaudeProbe,
  [switch]$SkipDockerLogs
)

$ErrorActionPreference = "Stop"

function Normalize-Url([string]$Url, [string]$Fallback) {
  if ($Url -and $Url.Trim()) { return $Url.Trim().TrimEnd("/") }
  return $Fallback
}

function Show-Health([string]$Label, [string]$Url) {
  try {
    $response = Invoke-WebRequest -UseBasicParsing "$Url/health" -TimeoutSec 10
    Write-Host "$Label health: $($response.StatusCode)"
    try {
      $json = $response.Content | ConvertFrom-Json
      if ($Label -eq "Headroom") {
        $version = $json.version
        if (-not $version) { $version = $json.components.version }
        $upstream = $json.upstream_url
        if (-not $upstream) { $upstream = $json.upstreamUrl }
        if (-not $upstream -and $json.components) { $upstream = $json.components.upstream_url }
        if (-not $upstream -and $json.checks -and $json.checks.upstream) { $upstream = $json.checks.upstream.url }
        Write-Host "Headroom ready: $($json.ready)"
        Write-Host "Headroom version: $version"
        Write-Host "Headroom upstream: $upstream"
      } else {
        Write-Host "$Label body: $($response.Content)"
      }
    } catch {
      Write-Host "$Label body: $($response.Content)"
    }
  } catch {
    Write-Warning "$Label health failed at $Url/health: $($_.Exception.Message)"
  }
}

function Get-ErrorStatus([object]$ErrorRecord) {
  $response = $ErrorRecord.Exception.Response
  if ($response -and $response.StatusCode) {
    try { return [int]$response.StatusCode } catch { return [string]$response.StatusCode }
  }
  return $null
}

$BaseUrl = Normalize-Url $BaseUrl "http://127.0.0.1:8787"
$Sub2apiBaseUrl = Normalize-Url $Sub2apiBaseUrl "http://127.0.0.1:18081"
if (-not $Model) { $Model = "gpt-5.6-sol" }
if (-not $SmallFastModel) { $SmallFastModel = "gpt-5.3-codex-spark" }
if (-not $DefaultHaikuModel) { $DefaultHaikuModel = "gpt-5.6-terra" }
if (-not $SubagentModel) { $SubagentModel = "gpt-5.6-terra" }

Write-Host "Claude/Headroom base URL: $BaseUrl"
Write-Host "sub2api admin/diagnostic URL: $Sub2apiBaseUrl"
Write-Host "Model: $Model"
Write-Host "Small-fast model: $SmallFastModel"
Write-Host "Default Haiku model: $DefaultHaikuModel"
Write-Host "Subagent model: $SubagentModel"
Write-Host "Has API token: $([bool]$ApiKey)"

Show-Health "Headroom" $BaseUrl
Show-Health "sub2api" $Sub2apiBaseUrl

if (-not $SkipApiProbe) {
  if (-not $ApiKey) {
    Write-Warning "ANTHROPIC_AUTH_TOKEN is empty; skipping direct /v1/messages probe."
  } else {
    $headers = @{
      "x-api-key" = $ApiKey
      "anthropic-version" = "2023-06-01"
      "content-type" = "application/json"
    }
    $body = @{
      model = $Model
      max_tokens = 1
      messages = @(@{ role = "user"; content = "Reply exactly OK_SUB2API_VERIFY" })
    } | ConvertTo-Json -Depth 10 -Compress
    try {
      $probe = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$BaseUrl/v1/messages" -Headers $headers -Body $body -TimeoutSec 60
      Write-Host "Headroom /v1/messages probe: $($probe.StatusCode)"
    } catch {
      $status = Get-ErrorStatus $_
      if ($status -eq 429) {
        Write-Warning "Headroom /v1/messages returned 429. Route and API key reached sub2api; fix account quota/cooldown/no-available-accounts next."
      } elseif ($status -eq 401 -or $status -eq 403) {
        Write-Warning "Headroom /v1/messages returned $status. The sub2api API key is missing, wrong, or not authorized for the group."
      } elseif ($status) {
        Write-Warning "Headroom /v1/messages returned HTTP ${status}: $($_.Exception.Message)"
      } else {
        Write-Warning "Headroom /v1/messages probe failed: $($_.Exception.Message)"
      }
    }
  }
}

if (-not $SkipClaudeProbe) {
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warning "claude command not found; skipping Claude Code probes."
  } else {
    $env:ANTHROPIC_BASE_URL = $BaseUrl
    $env:ANTHROPIC_AUTH_TOKEN = $ApiKey
    $env:ANTHROPIC_MODEL = $Model
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $DefaultHaikuModel
    $env:ANTHROPIC_SMALL_FAST_MODEL = $SmallFastModel
    $env:CLAUDE_CODE_SUBAGENT_MODEL = $SubagentModel
    $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_MAX_CONTEXT_TOKENS", "User")
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "User")
    $env:CLAUDE_CODE_MAX_OUTPUT_TOKENS = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_MAX_OUTPUT_TOKENS", "User")
    $env:MAX_THINKING_TOKENS = [Environment]::GetEnvironmentVariable("MAX_THINKING_TOKENS", "User")
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
  if (Get-Command docker -ErrorAction SilentlyContinue) {
    Write-Host "`nCompose services:"
    docker compose -p $ProjectName ps

    Write-Host "`nRecent usage logs:"
    $recentUsageSql = "select id, requested_model, upstream_model, reasoning_effort, model_mapping_chain, input_tokens, created_at from usage_logs order by id desc limit 5;"
    docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F "," -Atc $recentUsageSql

    Write-Host "`n0/0 ghost-stream audit:"
    $ghostStreamSql = "select requested_model, reasoning_effort, count(*) filter (where input_tokens=0 and output_tokens=0 and stream=true and duration_ms between 500 and 30000) as zero_streams, count(*) as total from usage_logs where created_at > now() - interval '90 minutes' and inbound_endpoint='/v1/messages' group by requested_model, reasoning_effort order by zero_streams desc, total desc;"
    docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F "," -Atc $ghostStreamSql
  } elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    function Quote-BashSingle([string]$Value) {
      return "'" + $Value.Replace("'", "'\''") + "'"
    }

    Write-Host "`nCompose services:"
    wsl.exe -- bash -lc "docker compose -p '$ProjectName' ps"
    Write-Host "`nRecent usage logs:"
    $recentUsageSql = "select id, requested_model, upstream_model, reasoning_effort, model_mapping_chain, input_tokens, created_at from usage_logs order by id desc limit 5;"
    wsl.exe -- bash -lc "docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F ',' -Atc $(Quote-BashSingle $recentUsageSql)"
    Write-Host "`n0/0 ghost-stream audit:"
    $ghostStreamSql = "select requested_model, reasoning_effort, count(*) filter (where input_tokens=0 and output_tokens=0 and stream=true and duration_ms between 500 and 30000) as zero_streams, count(*) as total from usage_logs where created_at > now() - interval '90 minutes' and inbound_endpoint='/v1/messages' group by requested_model, reasoning_effort order by zero_streams desc, total desc;"
    wsl.exe -- bash -lc "docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F ',' -Atc $(Quote-BashSingle $ghostStreamSql)"
  } else {
    Write-Warning "docker and wsl.exe not found; skipping Docker/Postgres checks."
  }
}

Write-Host "`nExpected Headroom upstream: http://sub2api:8080"
Write-Host "Expected main model in usage_logs: $ExpectedUpstream"
Write-Host "Expected small-fast requested_model in usage_logs: $SmallFastModel"
Write-Host "Expected default-Haiku/subagent model for delegated agents: $DefaultHaikuModel / $SubagentModel"

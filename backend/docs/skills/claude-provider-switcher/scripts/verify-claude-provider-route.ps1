[CmdletBinding()]
param(
  [string]$RuntimeRoot = "C:\Users\stigm\Documents\Codex\2026-07-07\new-chat\work\sub2api-runtime",
  [string]$WslDistro = "Ubuntu-24.04",
  [string]$StableKeyName = "claude-code-codex-sub2api",
  [string]$HeadroomBaseUrl = ""
)

$ErrorActionPreference = "Stop"
$skillRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$statePath = Join-Path $RuntimeRoot "data\provider-route-state.json"
$postgresContainer = "sub2api-codex-postgres"

function Invoke-Sql([string]$Sql) {
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Sql))
  $command = "printf '%s' '$encoded' | base64 -d | docker exec -i '$postgresContainer' psql -v ON_ERROR_STOP=1 -U sub2api -d sub2api -At"
  $output = @(& wsl.exe -d $WslDistro -- bash -lc $command 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "Postgres query failed: $($output -join [Environment]::NewLine)" }
  return @($output | Where-Object { $_ -and $_.Trim() })
}

function Resolve-HeadroomUrl {
  if ($HeadroomBaseUrl) { return $HeadroomBaseUrl.TrimEnd('/') }
  $settingsPath = Join-Path $HOME ".claude\settings.json"
  if (Test-Path -LiteralPath $settingsPath) {
    $settingsUrl = [string](Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json).env.ANTHROPIC_BASE_URL
    if ($settingsUrl) { return $settingsUrl.TrimEnd('/') }
  }
  $ip = ((@(& wsl.exe -d $WslDistro -- hostname -I) -join ' ').Trim() -split '\s+')[0]
  return "http://${ip}:8787"
}

if (-not (Test-Path -LiteralPath $statePath)) { throw "Provider route state is not initialized: $statePath" }
$state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
$profileFile = if ($state.active_profile -eq "anthropic-only") { "anthropic-only.v1.json" } else { "hybrid-current.v1.json" }
$profile = Get-Content -Raw -LiteralPath (Join-Path $skillRoot "profiles\$profileFile") | ConvertFrom-Json
$keyNameSql = $StableKeyName.Replace("'", "''")
$keyRows = @(Invoke-Sql "SELECT id || chr(9) || key FROM api_keys WHERE name='$keyNameSql' AND status='active' AND deleted_at IS NULL;")
if ($keyRows.Count -ne 1) { throw "Stable key lookup failed" }
$keyParts = $keyRows[0] -split "`t", 2
$keyId = [int64]$keyParts[0]
$key = $keyParts[1]
$baseUrl = Resolve-HeadroomUrl
$started = [DateTimeOffset]::UtcNow
$runId = [guid]::NewGuid().ToString("N")
$commonHeaders = @{ "x-api-key" = $key; Authorization = "Bearer $key"; "anthropic-version" = "2023-06-01" }
$probes = @(
  @{ name = "main"; model = [string]$profile.main_model; system = "You are Claude Code, Anthropic's official CLI for Claude." },
  @{ name = "stale-qwen"; model = "qwen3.8-max-preview"; system = "You are Claude Code, Anthropic's official CLI for Claude." },
  @{ name = "compact"; model = [string]$profile.main_model; system = "Your task is to create a detailed summary of the conversation." },
  @{ name = "sdk-cli"; model = [string]$profile.main_model; system = "You are Claude Code, Anthropic's official CLI for Claude."; user_agent = "claude-cli/2.1.202 (external, sdk-cli)" }
)

$httpProof = @()
foreach ($probe in $probes) {
  $headers = $commonHeaders.Clone()
  $headers["User-Agent"] = if ($probe.user_agent) { "$($probe.user_agent) provider-route-verify/$runId" } else { "claude-route-verify/$runId" }
  $body = @{
    model = $probe.model
    max_tokens = 24
    stream = $false
    system = $probe.system
    metadata = @{ user_id = "user_$('c' * 64)_account__session_$([guid]::NewGuid())" }
    messages = @(@{ role = "user"; content = "Reply exactly ROUTE_VERIFY_$($probe.name)_$runId" })
  } | ConvertTo-Json -Depth 20 -Compress
  $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$baseUrl/v1/messages" -Headers $headers -ContentType "application/json" -Body $body -TimeoutSec 180
  $httpProof += [pscustomobject]@{ probe = $probe.name; status = [int]$response.StatusCode }
}

$startedSql = $started.ToString("o").Replace("'", "''")
$runIdSql = $runId.Replace("'", "''")
$proofSql = @"
SELECT row_to_json(proof)::text
FROM (
  SELECT u.id, u.requested_model, u.model, u.reasoning_effort, u.duration_ms,
         a.name AS account_name, a.platform, a.type, u.group_id
  FROM usage_logs u
  JOIN accounts a ON a.id = u.account_id
  WHERE u.api_key_id = $keyId
    AND u.created_at >= '$startedSql'::timestamptz
    AND u.user_agent LIKE '%$runIdSql%'
  ORDER BY u.id
) proof;
"@
$rows = @()
for ($attempt = 0; $attempt -lt 10 -and $rows.Count -lt $probes.Count; $attempt++) {
  if ($attempt -gt 0) { Start-Sleep -Milliseconds 500 }
  $rows = @(Invoke-Sql $proofSql)
}
$usageProof = @($rows | ForEach-Object { $_ | ConvertFrom-Json })
if ($usageProof.Count -ne $probes.Count) { throw "Expected $($probes.Count) usage rows, got $($usageProof.Count)" }

if ($state.active_profile -eq "anthropic-only") {
  $forbidden = @($usageProof | Where-Object { $_.platform -ne "anthropic" -or $_.type -ne "oauth" -or $_.account_name -ne $profile.expected_account_name })
  if ($forbidden.Count -gt 0) { throw "Anthropic-only verification observed a forbidden provider account" }
  $expectedModels = @($profile.main_model, "claude-sonnet-5", "claude-haiku-4-5-20251001", "claude-sonnet-5")
  for ($i = 0; $i -lt $expectedModels.Count; $i++) {
    if ([string]$usageProof[$i].model -ne [string]$expectedModels[$i]) {
      throw "Probe '$($probes[$i].name)' expected model '$($expectedModels[$i])', got '$($usageProof[$i].model)'"
    }
  }
}

[pscustomobject]@{
  status = "PASS"
  active_profile = $state.active_profile
  generation = $state.generation
  http = $httpProof
  usage = $usageProof
} | ConvertTo-Json -Depth 20

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
$profileFile = switch ($state.active_profile) {
  "anthropic-only" { "anthropic-only.v4.json" }
  "chatgpt-only" { "chatgpt-only.v4.json" }
  "hybrid-current" { "hybrid-current.v1.json" }
  default { throw "Unknown active provider profile: $($state.active_profile)" }
}
$profile = Get-Content -Raw -LiteralPath (Join-Path $skillRoot "profiles\$profileFile") | ConvertFrom-Json
if ([int]$state.profile_version -ne [int]$profile.version) {
  throw "Provider profile state is stale: active version $($state.profile_version), repo version $($profile.version)"
}
if ($state.active_profile -eq "chatgpt-only") {
  $groupNameSql = ([string]$profile.group_name).Replace("'", "''")
  $contractRows = @(Invoke-Sql @"
SELECT id::text
FROM groups
WHERE name = '$groupNameSql'
  AND platform = 'openai'
  AND messages_dispatch_model_config->>'plan_mapped_model' = 'gpt-5.6-sol'
  AND messages_dispatch_model_config->>'plan_reasoning_effort' = 'high'
  AND messages_dispatch_model_config->>'compact_mapped_model' = 'gpt-5.6-terra-medium'
  AND messages_dispatch_model_config->>'compact_reasoning_effort' = 'medium'
  AND messages_dispatch_model_config->>'sdk_cli_mapped_model' = 'gpt-5.6-terra-medium'
  AND messages_dispatch_model_config->>'sdk_cli_reasoning_effort' = 'medium'
  AND COALESCE(messages_dispatch_model_config->'model_fallbacks', '{}'::jsonb) = '{}'::jsonb
  AND COALESCE(messages_dispatch_model_config->'automatic_model_fallbacks', '{}'::jsonb) = '{}'::jsonb;
"@)
  if ($contractRows.Count -ne 1) {
    throw "ChatGPT-only v4 Sol/Terra-medium zero-fallback contract is not active"
  }
}
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
  @{ name = "compact"; model = [string]$profile.main_model; system = "Your task is to create a detailed summary of the conversation."; effort = "max"; adaptive = $true; compact_header = $true },
  @{ name = "sdk-cli"; model = [string]$profile.main_model; system = "x-anthropic-billing-header: cc_entrypoint=sdk-cli; cc_is_subagent=true;`nYou are a Claude Code delegated worker."; user_agent = "claude-cli/2.1.219 (external, sdk-cli)" },
  @{ name = "plan"; model = [string]$profile.main_model; system = "x-anthropic-billing-header: cc_entrypoint=sdk-cli; cc_is_subagent=true;`nYou are a software architect and planning specialist for Claude Code.`n=== CRITICAL: READ-ONLY MODE - NO FILE MODIFICATIONS ===`nThis is a READ-ONLY planning task."; user_agent = "claude-cli/2.1.219 (external, sdk-cli)"; tools = @("Bash", "Glob", "Grep", "Read") }
)

$httpProof = @()
foreach ($probe in $probes) {
  $headers = $commonHeaders.Clone()
  $headers["User-Agent"] = if ($probe.user_agent) { "$($probe.user_agent) provider-route-verify/$runId" } else { "claude-route-verify/$runId" }
  if ($probe.compact_header) { $headers["x-sub2api-claude-compact"] = "1" }
  $body = @{
    model = $probe.model
    max_tokens = 24
    stream = $false
    system = $probe.system
    metadata = @{ user_id = "user_$('c' * 64)_account__session_$([guid]::NewGuid())" }
    messages = @(@{ role = "user"; content = "Reply exactly ROUTE_VERIFY_$($probe.name)_$runId" })
  }
  if ($probe.effort) { $body.output_config = @{ effort = [string]$probe.effort } }
  if ($probe.adaptive) { $body.thinking = @{ type = "adaptive" } }
  if ($probe.tools) { $body.tools = @($probe.tools | ForEach-Object { @{ name = [string]$_; description = "verification tool"; input_schema = @{ type = "object" } } }) }
  $body = $body | ConvertTo-Json -Depth 20 -Compress
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
  $expectedModels = @($profile.main_model, "claude-sonnet-5", "claude-sonnet-5", "claude-sonnet-5", "claude-sonnet-5")
  for ($i = 0; $i -lt $expectedModels.Count; $i++) {
    if ([string]$usageProof[$i].model -ne [string]$expectedModels[$i]) {
      throw "Probe '$($probes[$i].name)' expected model '$($expectedModels[$i])', got '$($usageProof[$i].model)'"
    }
  }
  if ([string]$usageProof[2].reasoning_effort -ne "low") {
    throw "Compact probe expected reasoning effort 'low', got '$($usageProof[2].reasoning_effort)'"
  }
  if ([string]$usageProof[3].reasoning_effort -ne "high") {
    throw "SDK CLI probe expected reasoning effort 'high', got '$($usageProof[3].reasoning_effort)'"
  }
  if ([string]$usageProof[4].reasoning_effort -ne "high") {
    throw "Plan probe expected reasoning effort 'high', got '$($usageProof[4].reasoning_effort)'"
  }
} elseif ($state.active_profile -eq "chatgpt-only") {
  $forbidden = @($usageProof | Where-Object { $_.platform -ne "openai" -or $_.type -ne "oauth" -or $_.account_name -ne $profile.expected_account_name })
  if ($forbidden.Count -gt 0) { throw "ChatGPT-only verification observed a forbidden provider account" }
  # Terra-medium is a client/request alias. The OpenAI bridge normalizes the
  # provider-facing model column to Terra while requested_model preserves the
  # alias for compact and Agent SDK routes.
  $expectedModels = @($profile.main_model, "gpt-5.6-terra", "gpt-5.6-terra", "gpt-5.6-terra", "gpt-5.6-sol")
  for ($i = 0; $i -lt $expectedModels.Count; $i++) {
    if ([string]$usageProof[$i].model -ne [string]$expectedModels[$i]) {
      throw "Probe '$($probes[$i].name)' expected model '$($expectedModels[$i])', got '$($usageProof[$i].model)'"
    }
  }
  if ([string]$usageProof[2].reasoning_effort -ne "medium") {
    throw "Compact probe expected reasoning effort 'medium', got '$($usageProof[2].reasoning_effort)'"
  }
  if ([string]$usageProof[2].requested_model -ne "gpt-5.6-terra-medium") {
    throw "Compact probe expected requested Terra-medium alias, got '$($usageProof[2].requested_model)'"
  }
  if ([string]$usageProof[3].reasoning_effort -ne "medium") {
    throw "SDK CLI probe expected reasoning effort 'medium', got '$($usageProof[3].reasoning_effort)'"
  }
  if ([string]$usageProof[3].requested_model -ne "gpt-5.6-terra-medium") {
    throw "SDK CLI probe expected requested Terra-medium alias, got '$($usageProof[3].requested_model)'"
  }
  if ([string]$usageProof[4].reasoning_effort -ne "high") {
    throw "Plan probe expected reasoning effort 'high', got '$($usageProof[4].reasoning_effort)'"
  }
}

[pscustomobject]@{
  status = "PASS"
  active_profile = $state.active_profile
  generation = $state.generation
  http = $httpProof
  usage = $usageProof
} | ConvertTo-Json -Depth 20

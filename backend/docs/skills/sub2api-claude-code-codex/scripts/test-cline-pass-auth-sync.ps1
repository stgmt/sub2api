param(
  [string]$ScriptPath = (Join-Path $PSScriptRoot "sync-cline-pass-auth.ps1"),
  [string]$EnsurePath = (Join-Path $PSScriptRoot "ensure-sub2api-proxy-stack.ps1"),
  [string]$SetupPath = (Join-Path $PSScriptRoot "setup-sub2api-claude-code.ps1")
)

$ErrorActionPreference = "Stop"

function Assert-Contains {
  param([string]$Text, [string]$Needle, [string]$Message)
  if (-not $Text.Contains($Needle)) { throw $Message }
}

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Cline Pass sync script is missing: $ScriptPath" }
$sync = Get-Content -Raw -LiteralPath $ScriptPath
$ensure = Get-Content -Raw -LiteralPath $EnsurePath
$setup = Get-Content -Raw -LiteralPath $SetupPath

Assert-Contains $sync 'https://api.cline.bot/api/v1' "Cline Pass must use the Cline API endpoint"
Assert-Contains $sync 'auth_source = "cline_pass_cli"' "Cline credentials need an explicit source marker"
Assert-Contains $sync '.cline\data\settings\providers.json' "The default source must be the installed Cline providers file"
Assert-Contains $sync 'workos:' "The sync must normalize the Cline WorkOS token prefix"
Assert-Contains $sync 'header_override_enabled = $true' "Cline-specific headers must be enabled"
Assert-Contains $sync '/auth/refresh' "Expired Cline credentials must refresh without browser login"
Assert-Contains $sync 'Save-JsonAtomic' "Refreshed Cline credentials must be persisted atomically"
Assert-Contains $sync 'ForceRefresh' "The sync must expose a deterministic refresh probe"
Assert-Contains $sync 'cline-pass/qwen3.8-max' "The Cline Qwen model must be catalogued"
Assert-Contains $sync 'cline-pass/deepseek-v4-flash' "The Cline DeepSeek model must be catalogued"
Assert-Contains $sync 'cline-pass/glm-5.3' "GLM-5.3 must remain catalogued"
Assert-Contains $sync 'cline-pass/kimi-k3' "Kimi K3 must remain catalogued"
Assert-Contains $sync 'DshExcludedModelPatterns' "The DSH catalog must keep excluded model families out"
Assert-Contains $sync '"(?i)^nvidia/"' "NVIDIA models must be excluded from the DSH catalog"
Assert-Contains $sync '"(?i)qwen(?:[0-2](?:\.[0-9]+)?|3\.[0-7])(?:[^0-9]|$)"' "Qwen models below 3.8 must be excluded from the DSH catalog"
Assert-Contains $sync '"(?i)glm[- ]?(?:[0-4](?:\.[0-9]+)?|5\.[0-2])(?:[^0-9]|$)"' "GLM models below 5.3 must be excluded from the DSH catalog"
Assert-Contains $sync '"(?i)kimi(?:[- ]k)?[0-2](?:\.[0-9]+)?(?:[^0-9]|$)"' "Kimi models below 3 must be excluded from the DSH catalog"
if ($sync.Contains('"cline-pass/qwen3.7-plus"') -or $sync.Contains('"cline-pass/qwen3.7-max"')) {
  throw "Qwen models below 3.8 must not remain in the Cline catalog"
}
if ($sync.Contains('"cline-pass/glm-5.2"') -or $sync.Contains('"cline-pass/kimi-k2.7-code"') -or $sync.Contains('"cline-pass/kimi-k2.6"')) {
  throw "GLM models below 5.3 and Kimi models below 3 must not remain in the Cline catalog"
}
Assert-Contains $sync 'poolside/laguna-s-2.1:free' "The free Laguna model must be catalogued"
Assert-Contains $sync 'require_oauth_only = $false' "The composite group must accept the Cline API-key account"
if ($sync.Contains('models_list_config')) {
  throw "Provider-local sync must not replace the service-owned composite model catalog"
}
Assert-Contains $sync 'model_mapping = $ClinePassModelMapping' "Cline account must be restricted to its own model catalog"
Assert-Contains $sync 'DshSettingsPath' "The DSH model catalog must be wired"
Assert-Contains $sync 'ProviderSyncToken' "The sync must use the scoped provider-sync credential"
Assert-Contains $sync 'Sync-Sub2apiProviderAccount' "The sync must use the service-owned provider-sync API"
if ($sync -match '(?i)psql|INSERT\s+INTO\s+accounts|UPDATE\s+accounts|Restart-Sub2api|AdminPassword') {
  throw "Cline sync must not use SQL, restarts, or administrator credentials"
}
Assert-Contains $sync 'entryIndices' "DSH flow-style model catalogs must be repaired with valid separators"
Assert-Contains $sync 'DshReasoningCatalog' "DSH effort capabilities must have a durable source of truth"
Assert-Contains $sync 'DshContextWindowCatalog' "DSH provider context limits must have a durable source of truth"
Assert-Contains $sync 'grok-4.6' "DSH Grok effort capability must be preserved"
Assert-Contains $sync 'gpt-5.6-luna' "DSH Luna effort capability must be preserved"
Assert-Contains $sync 'reasoningEfforts' "DSH model entries must declare selectable reasoning efforts"
Assert-Contains $sync 'DSH may rewrite a flow entry into a multi-line mapping' "DSH sync must handle its rewritten multi-line catalog"
Assert-Contains $sync '"grok-4.6" = "low: low, medium: medium, high: high"' "Grok must expose only its supported effort levels"
Assert-Contains $sync '"grok-4.6" = 500000' "DSH must keep Grok 4.6 below its live 500k prompt limit"
Assert-Contains $sync '"grok-4.5" = 500000' "DSH must keep Grok 4.5 below its live 500k prompt limit"
Assert-Contains $sync '"gpt-5.6-luna" = "low: low, medium: medium, high: high, xhigh: xhigh, max: max"' "Luna must expose its supported effort levels"
Assert-Contains $sync '"cline-pass/qwen3.8-max" = "low: low, medium: medium, xhigh: xhigh"' "Qwen must expose its supported effort levels"
Assert-Contains $sync '"cline-pass/kimi-k3" = "low: low, high: high, max: max"' "Kimi must expose its supported effort levels"
Assert-Contains $sync '"cline-pass/glm-5.3" = "high: high, max: max"' "GLM must expose its supported effort levels"
Assert-Contains $sync '"cline-pass/deepseek-v4-pro" = "off: off, high: high, max: max"' "DeepSeek must expose its supported effort levels"
Assert-Contains $sync 'service-owned provider synchronization' "Provider-sync failures must identify the service boundary"
Assert-Contains $ensure 'Sync-ClinePassAuth' "The watchdog must reconcile Cline Pass credentials"
Assert-Contains $ensure 'SUB2API_CLINE_PASS_AUTH_FILE' "The watchdog must allow an explicit Cline auth source"
Assert-Contains $setup 'sync-cline-pass-auth.ps1' "Initial setup must run the Cline Pass sync"
Assert-Contains $setup 'SUB2API_CLINE_PASS_ACCOUNT_NAME' "Setup must persist the Cline account name"

$temp = Join-Path ([IO.Path]::GetTempPath()) ("cline-pass-auth-test-" + [guid]::NewGuid().ToString("N") + ".json")
$fakeAccess = "test-cline-access-token-never-printed"
$fakeRefresh = "test-cline-refresh-token-never-printed"
try {
  $fixture = [ordered]@{
    version = 1
    lastUsedProvider = "cline-pass"
    providers = [ordered]@{
      "cline-pass" = [ordered]@{
        settings = [ordered]@{
          provider = "cline-pass"
          tokenSource = "oauth"
          auth = [ordered]@{
            accessToken = $fakeAccess
            refreshToken = $fakeRefresh
            expiresAt = (Get-Date).ToUniversalTime().AddHours(1).ToString("o")
            accountId = "test-account-id"
          }
          model = "cline-pass/deepseek-v4-flash"
        }
      }
    }
  }
  [IO.File]::WriteAllText($temp, ($fixture | ConvertTo-Json -Compress -Depth 12), [Text.UTF8Encoding]::new($false))
  $probeOutput = @(& $ScriptPath -AuthFile $temp -CheckOnly | ForEach-Object { [string]$_ }) -join ""
  $probe = $probeOutput | ConvertFrom-Json
  if ($probe.status -ne "ready") { throw "Expected a valid Cline fixture, got '$($probe.status)'" }
  if ($probeOutput.Contains($fakeAccess) -or $probeOutput.Contains($fakeRefresh)) {
    throw "Cline Pass sync leaked a fixture credential"
  }
  if ([int]$probe.model_count -ne 10) { throw "Expected 10 Cline catalog models, got $($probe.model_count)" }
  Assert-Contains $probeOutput 'api.cline.bot/api/v1' "Probe must expose only safe endpoint metadata"
} finally {
  Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}

Write-Host "CLINE_PASS_AUTH_SYNC_CONTRACT_OK"

param(
  [string]$ScriptPath = (Join-Path $PSScriptRoot "sync-grok-build-auth.ps1"),
  [string]$DshSyncPath = (Join-Path $PSScriptRoot "sync-dsh-composite-key.ps1"),
  [string]$EnsurePath = (Join-Path $PSScriptRoot "ensure-sub2api-proxy-stack.ps1"),
  [string]$SetupPath = (Join-Path $PSScriptRoot "setup-sub2api-claude-code.ps1")
)

$ErrorActionPreference = "Stop"

function Assert-Contains {
  param([string]$Text, [string]$Needle, [string]$Message)
  if (-not $Text.Contains($Needle)) { throw $Message }
}

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Grok Build sync script is missing: $ScriptPath" }
$sync = Get-Content -Raw -LiteralPath $ScriptPath
$dshSync = Get-Content -Raw -LiteralPath $DshSyncPath
$ensure = Get-Content -Raw -LiteralPath $EnsurePath
$setup = Get-Content -Raw -LiteralPath $SetupPath

Assert-Contains $sync 'https://cli-chat-proxy.grok.com/v1' "Grok Build must use the CLI subscription endpoint"
Assert-Contains $sync 'auth_source = "grok_build_cli"' "Grok Build credentials must carry an explicit source marker"
Assert-Contains $sync 'PSObject.Properties' "The sync must read dynamic Grok auth keys without hard-coding an issuer"
Assert-Contains $sync 'COPY incoming_grok_build_auth(payload) FROM STDIN' "Credentials must enter PostgreSQL through stdin"
Assert-Contains $sync 'Restart-Sub2api' "A changed token must refresh the running scheduler state"
Assert-Contains $sync 'NoRestart' "The sync must provide a non-disruptive dry integration mode"
Assert-Contains $sync 'dynamic issuer/client keys' "The sync must document secret redaction at the parsing boundary"
Assert-Contains $sync "COALESCE(a.credentials->>'refresh_token', '') IS DISTINCT FROM" "The sync must detect refresh-token ownership changes"
Assert-Contains $sync 'jsonb_build_object(' "The sync must preserve sub2api-owned tokens when refresh tokens match"
Assert-Contains $sync "'auth_source', 'grok_build_cli'" "The sync must keep the provider source marker stable"
Assert-Contains $dshSync 'HEAD_API_KEY' "DSH sync must update the configured composite credential slot"
Assert-Contains $dshSync 'headroom-openai-grok-composite' "DSH sync must select the mixed provider group by name"
Assert-Contains $dshSync 'http://127.0.0.1:8787/v1' "DSH sync must keep the Headroom OpenAI Responses endpoint"
Assert-Contains $dshSync 'CheckOnly' "DSH sync must support a read-only verification"
Assert-Contains $ensure 'Sync-GrokBuildAuth' "The repeating watchdog must reconcile Grok Build credentials"
Assert-Contains $ensure 'SUB2API_GROK_BUILD_AUTH_FILE' "The watchdog must allow an explicit Grok auth source"
Assert-Contains $setup 'sync-grok-build-auth.ps1' "Initial setup must run the Grok Build sync after Docker is up"

$temp = Join-Path ([IO.Path]::GetTempPath()) ("grok-build-auth-test-" + [guid]::NewGuid().ToString("N") + ".json")
try {
  $fakeAccess = "test-access-token-never-printed"
  $fakeRefresh = "test-refresh-token-never-printed"
  $fixture = [ordered]@{
    "https://auth.x.ai::test" = [ordered]@{
      key = $fakeAccess
      refresh_token = $fakeRefresh
      expires_at = (Get-Date).ToUniversalTime().AddHours(1).ToString("o")
      oidc_client_id = "test-client"
      email = "test@example.invalid"
    }
  }
  [IO.File]::WriteAllText($temp, ($fixture | ConvertTo-Json -Compress -Depth 8), [Text.UTF8Encoding]::new($false))
  $probeOutput = @(& $ScriptPath -AuthFile $temp -CheckOnly | ForEach-Object { [string]$_ }) -join ""
  $probe = $probeOutput | ConvertFrom-Json
  if ($probe.status -ne "ready") { throw "Expected a valid Grok Build fixture, got '$($probe.status)'" }
  if ($probeOutput.Contains($fakeAccess) -or $probeOutput.Contains($fakeRefresh)) {
    throw "Grok Build sync leaked a fixture credential"
  }
  Assert-Contains $probeOutput 'cli-chat-proxy.grok.com/v1' "Probe must expose only the safe endpoint metadata"
} finally {
  Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}

Write-Host "GROK_BUILD_AUTH_SYNC_CONTRACT_OK"

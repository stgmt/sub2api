param(
  [string]$AuthFile = "",
  [string]$ProviderSyncBaseUrl = "http://127.0.0.1:18081",
  [string]$ProviderSyncToken = "",
  [string]$AccountName = "grok-build-subscription",
  [string]$GroupName = "headroom-openai-grok-composite",
  [string]$CliBaseUrl = "https://cli-chat-proxy.grok.com/v1",
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "provider-account-sync-api.ps1")
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

function New-Result {
  param(
    [string]$Status,
    [string]$Reason = "",
    [bool]$CredentialsChanged = $false,
    [bool]$ServiceRestarted = $false
  )

  [ordered]@{
    status = $Status
    reason = if ($Reason) { $Reason } else { $null }
    credentials_changed = $CredentialsChanged
    service_restarted = $ServiceRestarted
    provider = "grok"
    auth_source = "grok_build_cli"
    base_url = $CliBaseUrl
  }
}

function Resolve-AuthFile {
  if ($AuthFile.Trim()) { return $AuthFile }
  if (-not $env:USERPROFILE) { return "" }
  return (Join-Path $env:USERPROFILE ".grok\auth.json")
}

function Read-GrokBuildEntry {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    return @{ result = New-Result -Status "missing" -Reason "auth file not found"; entry = $null }
  }

  try {
    $document = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  } catch {
    return @{ result = New-Result -Status "invalid" -Reason "auth file is not valid JSON"; entry = $null }
  }

  # Grok Build stores accounts under dynamic issuer/client keys. Never print or
  # expose the dynamic key; only retain the entry that contains an access key.
  $entries = @(
    $document.PSObject.Properties |
      ForEach-Object { $_.Value } |
      Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.key) }
  )
  if ($entries.Count -eq 0) {
    return @{ result = New-Result -Status "invalid" -Reason "no Grok Build access key found"; entry = $null }
  }

  $entry = $entries[0]
  $accessToken = [string]$entry.key
  $refreshToken = [string]$entry.refresh_token
  $expiresAt = [string]$entry.expires_at
  if ([string]::IsNullOrWhiteSpace($accessToken) -or [string]::IsNullOrWhiteSpace($refreshToken)) {
    return @{ result = New-Result -Status "invalid" -Reason "Grok Build access or refresh token is missing"; entry = $null }
  }
  if ([string]::IsNullOrWhiteSpace($expiresAt)) {
    return @{ result = New-Result -Status "invalid" -Reason "Grok Build expiry is missing"; entry = $null }
  }
  $parsedExpiry = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse($expiresAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsedExpiry)) {
    return @{ result = New-Result -Status "invalid" -Reason "Grok Build expiry is invalid"; entry = $null }
  }

  return @{
    result = New-Result -Status "ready"
    entry = $entry
  }
}

function ConvertTo-GrokCredentialsJson {
  param($Entry)

  function Get-OptionalProperty([string]$Name) {
    $property = $Entry.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return "" }
    return [string]$property.Value
  }

  $tokenType = Get-OptionalProperty "token_type"
  $credentials = [ordered]@{
    access_token = [string]$Entry.key
    refresh_token = [string]$Entry.refresh_token
    expires_at = [string]$Entry.expires_at
    token_type = if ($tokenType) { $tokenType } else { "Bearer" }
    base_url = $CliBaseUrl
    auth_source = "grok_build_cli"
  }
  foreach ($pair in @(
    @{ name = "id_token"; value = Get-OptionalProperty "id_token" },
    @{ name = "client_id"; value = Get-OptionalProperty "oidc_client_id" },
    @{ name = "scope"; value = Get-OptionalProperty "scope" },
    @{ name = "email"; value = Get-OptionalProperty "email" }
  )) {
    if (-not [string]::IsNullOrWhiteSpace($pair.value)) {
      $credentials[$pair.name] = $pair.value
    }
  }
  return ($credentials | ConvertTo-Json -Compress -Depth 8)
}

$source = Resolve-AuthFile
$read = Read-GrokBuildEntry -Path $source
if ($read.result.status -ne "ready") {
  ($read.result | ConvertTo-Json -Compress)
  return
}

if ($CheckOnly) {
  ($read.result | ConvertTo-Json -Compress)
  return
}

$credentialsObject = (ConvertTo-GrokCredentialsJson -Entry $read.entry) | ConvertFrom-Json
$credentials = @{}
$credentialsObject.PSObject.Properties | ForEach-Object { $credentials[$_.Name] = $_.Value }
if (-not $ProviderSyncToken) {
  throw "ProviderSyncToken is required for service-owned provider synchronization"
}
$groupBody = [ordered]@{
  name = $GroupName
  platform = "openai"
  subscription_type = "subscription"
  rate_multiplier = 1.0
  require_oauth_only = $false
}
$extra = @{
  provider_sync_source = "grok_build_cli"
  provider_sync_revision = 1
}
$sync = Sync-Sub2apiProviderAccount -BaseUrl $ProviderSyncBaseUrl -ProviderSyncToken $ProviderSyncToken -Source "grok_build_cli" `
  -AccountName $AccountName -Platform "grok" -AccountType "oauth" -Credentials $credentials -Extra $extra `
  -GroupName $GroupName -GroupBody $groupBody -Concurrency 3 -Priority 0 -RateMultiplier 1.0
$changed = [bool]$sync.account_created -or [bool]$sync.group_created -or [bool]$sync.group_changed -or [bool]$sync.credentials_changed

($read.result | ForEach-Object {
  $_.status = if ($changed) { "synced" } else { "unchanged" }
  $_.credentials_changed = [bool]$sync.credentials_changed
  $_.service_restarted = $false
  $_
} | ConvertTo-Json -Compress)

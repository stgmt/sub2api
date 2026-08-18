param(
  [string]$AuthFile = "",
  [string]$Distro = "Ubuntu-24.04",
  [string]$PostgresContainer = "sub2api-codex-postgres",
  [string]$DatabaseUser = "sub2api",
  [string]$DatabaseName = "sub2api",
  [string]$AccountName = "cline-pass-subscription",
  [string]$GroupName = "headroom-openai-grok-composite",
  [string]$ClineBaseUrl = "https://api.cline.bot/api/v1",
  [string]$ClineVersion = "3.0.55",
  [string]$ClineCoreVersion = "0.0.75",
  [string]$DshSettingsPath = "",
  [switch]$CheckOnly,
  [switch]$NoRestart,
  [switch]$ForceRefresh
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

# This is the catalog shipped by the installed ClinePass provider. Keep the
# IDs exact: Cline's display names are not stable API identifiers.
$ClinePassModelIds = @(
  "nvidia/nemotron-3.5-lightning",
  "cline-pass/qwen3.8-max",
  "poolside/laguna-s-2.1:free",
  "cline-pass/kimi-k3",
  "cline-pass/glm-5.2",
  "cline-pass/kimi-k2.7-code",
  "cline-pass/qwen3.7-plus",
  "cline-pass/minimax-m3",
  "cline-pass/qwen3.7-max",
  "cline-pass/deepseek-v4-flash",
  "cline-pass/deepseek-v4-pro",
  "deepseek/deepseek-v4-flash",
  "cline-pass/mimo-v2.5",
  "cline-pass/mimo-v2.5-pro",
  "cline-pass/kimi-k2.6",
  "cline-pass/glm-5.3"
)

$ClinePassModelCatalog = [ordered]@{
  "nvidia/nemotron-3.5-lightning" = @{ name = "Nemotron 3.5 Lightning 30B A3B"; context = 1000000 }
  "cline-pass/qwen3.8-max" = @{ name = "Qwen3.8 Max"; context = 1000000 }
  "poolside/laguna-s-2.1:free" = @{ name = "Laguna S 2.1 (free)"; context = 262144 }
  "cline-pass/kimi-k3" = @{ name = "Kimi K3"; context = 1048576 }
  "cline-pass/glm-5.2" = @{ name = "GLM-5.2"; context = 1048576 }
  "cline-pass/kimi-k2.7-code" = @{ name = "Kimi K2.7 Code"; context = 262144 }
  "cline-pass/qwen3.7-plus" = @{ name = "Qwen3.7 Plus"; context = 1000000 }
  "cline-pass/minimax-m3" = @{ name = "MiniMax-M3"; context = 1048576 }
  "cline-pass/qwen3.7-max" = @{ name = "Qwen3.7 Max"; context = 1000000 }
  "cline-pass/deepseek-v4-flash" = @{ name = "DeepSeek V4 Flash"; context = 1048576 }
  "cline-pass/deepseek-v4-pro" = @{ name = "DeepSeek V4 Pro"; context = 1048576 }
  "deepseek/deepseek-v4-flash" = @{ name = "DeepSeek V4 Flash"; context = 1048576 }
  "cline-pass/mimo-v2.5" = @{ name = "MiMo-V2.5"; context = 1050000 }
  "cline-pass/mimo-v2.5-pro" = @{ name = "MiMo-V2.5-Pro"; context = 1050000 }
  "cline-pass/kimi-k2.6" = @{ name = "Kimi K2.6"; context = 262144 }
  "cline-pass/glm-5.3" = @{ name = "cline-pass/glm-5.3"; context = 128000 }
}

# DSH only renders an effort picker when a model entry declares the levels it
# can send. Keep these declarations beside the catalog sync so a later Cline
# refresh cannot silently remove the picker from the composite route.
$DshReasoningCatalog = [ordered]@{
  "grok-4.6" = "low: low, medium: medium, high: high"
  "grok-4.5" = "low: low, medium: medium, high: high"
  "gpt-5.6-luna" = "low: low, medium: medium, high: high, xhigh: xhigh, max: max"
}

# sub2api treats an OpenAI API-key account with no model_mapping as a
# universal account. Keep Cline Pass isolated from the GPT accounts by making
# the discovered catalog an explicit account-level model whitelist.
$ClinePassModelMapping = [ordered]@{}
foreach ($modelId in $ClinePassModelIds) {
  $ClinePassModelMapping[$modelId] = $modelId
}

function New-Result {
  param(
    [string]$Status,
    [string]$Reason = "",
    [bool]$CredentialsChanged = $false,
    [bool]$ServiceRestarted = $false,
    [int]$ModelCount = $ClinePassModelIds.Count,
    [string]$ExpiryUtc = ""
  )

  [ordered]@{
    status = $Status
    reason = if ($Reason) { $Reason } else { $null }
    credentials_changed = $CredentialsChanged
    service_restarted = $ServiceRestarted
    provider = "cline-pass"
    auth_source = "cline_pass_cli"
    account = $AccountName
    group = $GroupName
    base_url = $ClineBaseUrl
    model_count = $ModelCount
    expires_at_utc = if ($ExpiryUtc) { $ExpiryUtc } else { $null }
  }
}

function Resolve-AuthFile {
  if ($AuthFile.Trim()) { return $AuthFile }
  if (-not $env:USERPROFILE) { return "" }
  return (Join-Path $env:USERPROFILE ".cline\data\settings\providers.json")
}

function Get-PropertyValue {
  param([object]$Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($property) { return $property.Value }
  return $null
}

function ConvertTo-Expiry {
  param([object]$Value)

  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }

  $parsed = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse(
      $text,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal,
      [ref]$parsed)) {
    return $parsed.ToUniversalTime()
  }

  $number = 0L
  if ([Int64]::TryParse($text, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
    if ($number -gt 100000000000) { return [DateTimeOffset]::FromUnixTimeMilliseconds($number).ToUniversalTime() }
    if ($number -gt 1000000000) { return [DateTimeOffset]::FromUnixTimeSeconds($number).ToUniversalTime() }
  }

  return $null
}

function Get-ClinePassHeaders {
  return @{
    "HTTP-Referer" = "https://cline.bot"
    "X-Title" = "Cline"
    "X-IS-MULTIROOT" = "false"
    "X-CLIENT-TYPE" = "cline-cli"
    "X-CLIENT-VERSION" = $ClineVersion
    "X-PLATFORM" = "cli"
    "X-PLATFORM-VERSION" = $ClineVersion
    "X-CORE-VERSION" = $ClineCoreVersion
    "User-Agent" = "Cline/$ClineVersion"
  }
}

function Save-JsonAtomic {
  param(
    [string]$Path,
    [object]$Document
  )

  $directory = Split-Path -Parent $Path
  $temporary = Join-Path $directory (".$([IO.Path]::GetFileName($Path)).cline-pass-sync-$([guid]::NewGuid().ToString('N')).tmp")
  try {
    $json = $Document | ConvertTo-Json -Depth 40
    [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-ClinePassRefresh {
  param(
    [string]$Path,
    [string]$RefreshToken,
    [string]$AccountId
  )

  $uri = "$($ClineBaseUrl.TrimEnd('/'))/auth/refresh"
  $body = @{ refreshToken = $RefreshToken; grantType = "refresh_token" } | ConvertTo-Json -Compress
  try {
    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers (Get-ClinePassHeaders) -ContentType "application/json" -Body $body -TimeoutSec 30
  } catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    return @{ ok = $false; reason = "Cline Pass refresh request failed (HTTP $status)" }
  }

  $data = Get-PropertyValue $response "data"
  if ($null -eq $data) { $data = $response }
  $newAccessToken = [string](Get-PropertyValue $data "accessToken")
  $newRefreshToken = [string](Get-PropertyValue $data "refreshToken")
  $newExpiresAt = [string](Get-PropertyValue $data "expiresAt")
  $userInfo = Get-PropertyValue $data "userInfo"
  $newAccountId = [string](Get-PropertyValue $userInfo "clineUserId")

  if ([string]::IsNullOrWhiteSpace($newAccessToken) -or
      [string]::IsNullOrWhiteSpace($newRefreshToken) -or
      [string]::IsNullOrWhiteSpace($newExpiresAt)) {
    return @{ ok = $false; reason = "Cline Pass refresh returned an incomplete credential response" }
  }

  $newExpiry = ConvertTo-Expiry $newExpiresAt
  if ($null -eq $newExpiry -or $newExpiry -le [DateTimeOffset]::UtcNow) {
    return @{ ok = $false; reason = "Cline Pass refresh returned an invalid expiry" }
  }

  try {
    $document = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $providers = Get-PropertyValue $document "providers"
    $providerProperty = if ($providers) { $providers.PSObject.Properties["cline-pass"] } else { $null }
    if (-not $providerProperty) { return @{ ok = $false; reason = "Cline Pass provider disappeared during refresh" } }
    $provider = $providerProperty.Value
    $settings = Get-PropertyValue $provider "settings"
    $auth = Get-PropertyValue $settings "auth"
    if ($null -eq $auth) { $auth = Get-PropertyValue $provider "auth" }
    if ($null -eq $auth) { return @{ ok = $false; reason = "Cline Pass auth object disappeared during refresh" } }

    # Cline stores this credential with one workos: prefix; the API itself
    # returns the raw WorkOS token. Keep the source file usable by Cline too.
    $storedAccessToken = if ($newAccessToken.StartsWith("workos:", [StringComparison]::OrdinalIgnoreCase)) {
      "workos:" + $newAccessToken.Substring(7)
    } else {
      "workos:" + $newAccessToken
    }
    $auth.accessToken = $storedAccessToken
    $auth.refreshToken = $newRefreshToken
    $auth.expiresAt = $newExpiresAt
    if ($newAccountId) { $auth.accountId = $newAccountId }
    Save-JsonAtomic -Path $Path -Document $document
  } catch {
    return @{ ok = $false; reason = "Cline Pass refresh succeeded but local credential update failed" }
  }

  return @{
    ok = $true
    access_token = if ($newAccessToken.StartsWith("workos:", [StringComparison]::OrdinalIgnoreCase)) { $newAccessToken } else { "workos:" + $newAccessToken }
    refresh_token = $newRefreshToken
    expires_at = $newExpiresAt
    account_id = if ($newAccountId) { $newAccountId } else { $AccountId }
    expiry_utc = $newExpiry.ToString("o")
  }
}

function Read-ClinePassEntry {
  param(
    [string]$Path,
    [switch]$ForceRefresh
  )

  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
    return @{ result = New-Result -Status "missing" -Reason "Cline providers file not found"; entry = $null }
  }

  try {
    $document = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
  } catch {
    return @{ result = New-Result -Status "invalid" -Reason "Cline providers file is not valid JSON"; entry = $null }
  }

  $providers = Get-PropertyValue $document "providers"
  $providerProperty = if ($providers) { $providers.PSObject.Properties["cline-pass"] } else { $null }
  $provider = if ($providerProperty) { $providerProperty.Value } else { $null }
  # Cline 3.x keeps auth under providers.<id>.settings.auth. Accept the
  # older direct shape too so an upgrade does not silently break the sync.
  $settings = Get-PropertyValue $provider "settings"
  $auth = Get-PropertyValue $settings "auth"
  if ($null -eq $auth) { $auth = Get-PropertyValue $provider "auth" }
  $rawAccessToken = [string](Get-PropertyValue $auth "accessToken")
  $refreshToken = [string](Get-PropertyValue $auth "refreshToken")
  $expiresAt = [string](Get-PropertyValue $auth "expiresAt")
  $accountId = [string](Get-PropertyValue $auth "accountId")

  if ([string]::IsNullOrWhiteSpace($rawAccessToken)) {
    return @{ result = New-Result -Status "invalid" -Reason "Cline Pass access token is missing"; entry = $null }
  }
  if ([string]::IsNullOrWhiteSpace($refreshToken)) {
    return @{ result = New-Result -Status "invalid" -Reason "Cline Pass refresh token is missing"; entry = $null }
  }
  $expiry = ConvertTo-Expiry $expiresAt
  if ($null -eq $expiry) {
    return @{ result = New-Result -Status "invalid" -Reason "Cline Pass expiry is missing or invalid"; entry = $null }
  }
  $refreshed = $false
  if ($ForceRefresh -or $expiry -le [DateTimeOffset]::UtcNow.AddMinutes(5)) {
    $refresh = Invoke-ClinePassRefresh -Path $Path -RefreshToken $refreshToken -AccountId $accountId
    if (-not $refresh.ok) {
      return @{ result = New-Result -Status "expired" -Reason $refresh.reason -ExpiryUtc $expiry.ToString("o"); entry = $null }
    }
    $rawAccessToken = [string]$refresh.access_token
    $refreshToken = [string]$refresh.refresh_token
    $expiresAt = [string]$refresh.expires_at
    $accountId = [string]$refresh.account_id
    $expiry = [DateTimeOffset]::Parse($refresh.expiry_utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $refreshed = $true
  }

  # The Cline runtime normalizes the token to exactly one workos: prefix.
  $accessToken = if ($rawAccessToken.StartsWith("workos:", [StringComparison]::OrdinalIgnoreCase)) {
    "workos:" + $rawAccessToken.Substring(7)
  } else {
    "workos:" + $rawAccessToken
  }

  $result = New-Result -Status "ready" -ExpiryUtc $expiry.ToString("o")
  $result.credentials_refreshed = $refreshed
  return @{
    result = $result
    entry = [ordered]@{
      access_token = $accessToken
      refresh_token = $refreshToken
      expires_at = $expiresAt
      account_id = $accountId
      expiry_utc = $expiry.ToString("o")
    }
  }
}

function ConvertTo-ClineCredentialsJson {
  param($Entry)

  $credentials = [ordered]@{
    api_key = [string]$Entry.access_token
    base_url = $ClineBaseUrl.TrimEnd("/")
    auth_source = "cline_pass_cli"
    provider_id = "cline-pass"
    token_type = "Bearer"
    refresh_token = [string]$Entry.refresh_token
    expires_at = [string]$Entry.expires_at
    account_id = [string]$Entry.account_id
    model_mapping = $ClinePassModelMapping
    header_override_enabled = $true
    header_overrides = [ordered]@{
      "http-referer" = "https://cline.bot"
      "x-title" = "Cline"
      "x-is-multi-root" = "false"
      "x-client-type" = "cline-cli"
      "x-client-version" = $ClineVersion
      "x-platform" = "cli"
      "x-platform-version" = $ClineVersion
      "x-core-version" = $ClineCoreVersion
      "user-agent" = "Cline/$ClineVersion"
    }
  }
  return ($credentials | ConvertTo-Json -Compress -Depth 12)
}

function Resolve-DshSettingsFile {
  if ($DshSettingsPath.Trim()) { return $DshSettingsPath }
  if (-not $env:USERPROFILE) { return "" }
  return (Join-Path $env:USERPROFILE ".dsh\settings.yaml")
}

function Sync-DshModelCatalog {
  $path = Resolve-DshSettingsFile
  if (-not $path -or -not (Test-Path -LiteralPath $path)) {
    return [ordered]@{ status = "missing"; path = $path; added = 0; effort_models = @(); model_count = $ClinePassModelCatalog.Count }
  }

  $lines = [System.Collections.Generic.List[string]]::new()
  foreach ($line in Get-Content -LiteralPath $path) { [void]$lines.Add([string]$line) }
  $headIndex = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*apiKeyEnv:\s*HEAD_API_KEY\s*,?\s*$') { $headIndex = $i; break }
  }
  if ($headIndex -lt 0) { return [ordered]@{ status = "skipped"; reason = "HEAD_API_KEY provider not found"; path = $path; added = 0; effort_models = @(); model_count = $ClinePassModelCatalog.Count } }

  $modelsIndex = -1
  for ($i = $headIndex + 1; $i -lt [Math]::Min($lines.Count, $headIndex + 80); $i++) {
    if ($lines[$i] -match '^\s*models:\s*$') { $modelsIndex = $i; break }
  }
  if ($modelsIndex -lt 0) { return [ordered]@{ status = "skipped"; reason = "HEAD_API_KEY model list not found"; path = $path; added = 0; effort_models = @(); model_count = $ClinePassModelCatalog.Count } }

  $openIndex = -1
  for ($i = $modelsIndex + 1; $i -lt [Math]::Min($lines.Count, $modelsIndex + 8); $i++) {
    if ($lines[$i] -match '^\s*\[\s*$') { $openIndex = $i; break }
  }
  if ($openIndex -lt 0) { return [ordered]@{ status = "skipped"; reason = "HEAD_API_KEY model list is not flow-style YAML"; path = $path; added = 0; effort_models = @(); model_count = $ClinePassModelCatalog.Count } }

  $closeIndex = -1
  for ($i = $openIndex + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*\]\s*$') { $closeIndex = $i; break }
  }
  if ($closeIndex -lt 0) { return [ordered]@{ status = "skipped"; reason = "HEAD_API_KEY model list has no closing bracket"; path = $path; added = 0; effort_models = @(); model_count = $ClinePassModelCatalog.Count } }

  $body = ($lines | Select-Object -Skip ($openIndex + 1) -First ($closeIndex - $openIndex - 1)) -join "`n"
  $indent = if ($lines[$closeIndex] -match '^(\s*)') { $Matches[1] + "  " } else { "              " }
  $added = 0
  foreach ($pair in $ClinePassModelCatalog.GetEnumerator()) {
    $escapedId = [regex]::Escape($pair.Key)
    if ($body -match "id:\s*$escapedId(?:[,}]|\s*$)") { continue }
    $entry = "{ id: $($pair.Key), name: $($pair.Value.name), contextWindow: $($pair.Value.context) }"
    [void]$lines.Insert($closeIndex, $indent + $entry)
    $closeIndex++
    $body += "`n$entry"
    $added++
  }

  $changed = $added -gt 0
  $effortModels = [System.Collections.Generic.List[string]]::new()
  foreach ($pair in $DshReasoningCatalog.GetEnumerator()) {
    $escapedId = [regex]::Escape($pair.Key)
    for ($i = $openIndex + 1; $i -lt $closeIndex; $i++) {
      $line = ([string]$lines[$i]).TrimEnd()
      if ($line -notmatch "(?:^|\s|\{)id:\s*$escapedId(?:,|\s*$)") { continue }
      $reasoning = "reasoningEfforts: { $($pair.Value) }"

      # DSH may rewrite a flow entry into a multi-line mapping. Handle both
      # that form and the compact one-line form emitted by this sync script.
      if ($line -match 'reasoningEfforts:\s*\{[^{}]*\}') {
        $updated = [regex]::Replace($line, 'reasoningEfforts:\s*\{[^{}]*\}', $reasoning)
        if ($updated -ne $line) {
          $lines[$i] = $updated
          $changed = $true
        }
        [void]$effortModels.Add($pair.Key)
        break
      }

      if ($line -match '}\s*,?$') {
        $separator = if ($line.EndsWith(',')) { ',' } else { '' }
        $updated = [regex]::Replace($line.TrimEnd(','), '\s*}$', ", $reasoning }") + $separator
        if ($updated -ne $line) {
          $lines[$i] = $updated
          $changed = $true
        }
        [void]$effortModels.Add($pair.Key)
        break
      }

      $entryEnd = $closeIndex
      $entryEffortLine = -1
      for ($j = $i + 1; $j -lt $closeIndex; $j++) {
        $candidate = ([string]$lines[$j]).TrimEnd()
        if ($candidate -match '^\s*reasoningEfforts:\s*\{[^{}]*\}') {
          $entryEffortLine = $j
          break
        }
        if ($candidate -match '^\s*}\s*,?\s*$') {
          $entryEnd = $j
          break
        }
      }

      if ($entryEffortLine -ge 0) {
        $candidate = ([string]$lines[$entryEffortLine]).TrimEnd()
        $updated = [regex]::Replace($candidate, 'reasoningEfforts:\s*\{[^{}]*\}', $reasoning)
        if ($updated -ne $candidate) {
          $lines[$entryEffortLine] = $updated
          $changed = $true
        }
      } else {
        $propertyIndent = if ($line -match '^(\s*)') { $Matches[1] + '  ' } else { '                  ' }
        if ($entryEnd -gt $i) {
          $previous = ([string]$lines[$entryEnd - 1]).TrimEnd()
          if (-not $previous.EndsWith(',')) { $lines[$entryEnd - 1] = $previous + ',' }
        }
        [void]$lines.Insert($entryEnd, $propertyIndent + $reasoning + ',')
        $closeIndex++
        $changed = $true
      }
      [void]$effortModels.Add($pair.Key)
      break
    }
  }

  # Flow-style YAML requires separators between every mapping. Older versions
  # of this helper inserted entries before the closing bracket without adding
  # a comma to the previous last entry, which made DSH reject the catalog.
  $entryIndices = @()
  for ($i = $openIndex + 1; $i -lt $closeIndex; $i++) {
    if ($lines[$i] -match '^\s*\{\s*id:') { $entryIndices += $i }
  }
  if ($entryIndices.Count -gt 0) {
    $lastEntryIndex = $entryIndices[-1]
    foreach ($entryIndex in $entryIndices) {
      $line = ([string]$lines[$entryIndex]).TrimEnd()
      if ($entryIndex -eq $lastEntryIndex) {
        $normalized = $line.TrimEnd(',')
      } else {
        $normalized = $line.TrimEnd(',') + ","
      }
      if ($normalized -ne $line) {
        $lines[$entryIndex] = $normalized
        $changed = $true
      }
    }
  }

  if ($changed) {
    [IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($false))
  }
  return [ordered]@{ status = if ($changed) { "updated" } else { "unchanged" }; path = $path; added = $added; effort_models = @($effortModels); model_count = $ClinePassModelCatalog.Count }
}

function Invoke-PsqlScript {
  param([string]$Sql)

  # Use PowerShell's native stdin pipeline. Windows PowerShell can leave a
  # redirected ProcessStartInfo stdin open across wsl.exe/docker exec, which
  # makes psql wait forever after COPY FROM STDIN even after Close().
  $output = @($Sql | & wsl.exe -d $Distro -- docker exec -i $PostgresContainer psql -U $DatabaseUser -d $DatabaseName -v ON_ERROR_STOP=1 -At 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $safeError = (($output -join [Environment]::NewLine) -replace "(?i)(api_key|access_token|refresh_token|id_token|workos):?\s*[=:]?\s*\S+", '$1=<redacted>').Trim()
    throw "PostgreSQL Cline sync failed: $safeError"
  }
  return (($output -join [Environment]::NewLine).Trim())
}

function Restart-Sub2api {
  $output = & wsl.exe -d $Distro -- docker restart sub2api-codex 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "sub2api restart failed: $(($output -join " ").Trim())"
  }
  for ($attempt = 0; $attempt -lt 45; $attempt++) {
    $health = ((@(& wsl.exe -d $Distro -- docker inspect -f '{{.State.Health.Status}}' sub2api-codex 2>$null)) -join "").Trim()
    if ($health -eq "healthy") { return $true }
    Start-Sleep -Seconds 2
  }
  throw "sub2api did not become healthy after Cline Pass credential sync"
}

$source = Resolve-AuthFile
$read = Read-ClinePassEntry -Path $source -ForceRefresh:$ForceRefresh
if ($read.result.status -ne "ready") {
  ($read.result | ConvertTo-Json -Compress)
  return
}

if ($CheckOnly) {
  ($read.result | ConvertTo-Json -Compress)
  return
}

$credentialsJson = ConvertTo-ClineCredentialsJson -Entry $read.entry
$payload = [ordered]@{
  account_name = $AccountName
  group_name = $GroupName
  credentials = $credentialsJson | ConvertFrom-Json
  model_ids = @($ClinePassModelIds)
}
$payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Compress -Depth 12)))

$sql = @'
BEGIN;
CREATE TEMP TABLE incoming_cline_pass_auth (payload text);
INSERT INTO incoming_cline_pass_auth(payload) VALUES ('
'@
$sql += $payloadBase64 + "');`n"
$sql += @'
CREATE TEMP TABLE cline_sync_result (
  account_id bigint,
  group_id bigint,
  account_changed boolean,
  group_changed boolean,
  membership_added boolean,
  model_count integer
);
DO $$
DECLARE
  p jsonb;
  v_account_id bigint;
  v_group_id bigint;
  v_old_credentials jsonb;
  v_old_status text;
  v_old_schedulable boolean;
  v_old_deleted_at timestamptz;
  v_old_group_config jsonb;
  v_old_require_oauth boolean;
  v_new_credentials jsonb;
  v_new_group_config jsonb;
  v_new_models jsonb;
  v_account_changed boolean;
  v_group_changed boolean;
  v_membership_added boolean;
  v_rows integer;
BEGIN
  SELECT convert_from(decode(payload, 'base64'), 'UTF8')::jsonb
    INTO p
    FROM incoming_cline_pass_auth
    LIMIT 1;
  IF p IS NULL THEN RAISE EXCEPTION 'empty Cline Pass sync payload'; END IF;

  SELECT a.id, a.credentials, a.status, a.schedulable, a.deleted_at
    INTO v_account_id, v_old_credentials, v_old_status, v_old_schedulable, v_old_deleted_at
    FROM accounts a
   WHERE a.name = p->>'account_name'
     AND a.platform = 'openai'
   ORDER BY a.id DESC
   LIMIT 1;

  v_new_credentials := COALESCE(v_old_credentials, '{}'::jsonb) || (p->'credentials');
  IF v_account_id IS NULL THEN
    INSERT INTO accounts (
      name, platform, type, credentials, status, schedulable, priority,
      concurrency, rate_multiplier, created_at, updated_at
    ) VALUES (
      p->>'account_name', 'openai', 'apikey', p->'credentials', 'active', TRUE,
      0, 3, 1.0, NOW(), NOW()
    ) RETURNING id INTO v_account_id;
    v_account_changed := TRUE;
  ELSE
    UPDATE accounts
       SET credentials = v_new_credentials,
           type = 'apikey',
           status = 'active',
           schedulable = TRUE,
           error_message = NULL,
           rate_limited_at = NULL,
           rate_limit_reset_at = NULL,
           overload_until = NULL,
           temp_unschedulable_until = NULL,
           temp_unschedulable_reason = NULL,
           deleted_at = NULL,
           updated_at = NOW()
     WHERE id = v_account_id;
    v_account_changed :=
      v_old_credentials IS DISTINCT FROM v_new_credentials
      OR v_old_status IS DISTINCT FROM 'active'
      OR v_old_schedulable IS DISTINCT FROM TRUE
      OR v_old_deleted_at IS NOT NULL;
  END IF;

  SELECT g.id, g.models_list_config, g.require_oauth_only
    INTO v_group_id, v_old_group_config, v_old_require_oauth
    FROM groups g
   WHERE g.name = p->>'group_name'
     AND g.deleted_at IS NULL
   ORDER BY g.id DESC
   LIMIT 1;
  IF v_group_id IS NULL THEN RAISE EXCEPTION 'Cline Pass target group not found: %', p->>'group_name'; END IF;

  SELECT COALESCE(jsonb_agg(value), '[]'::jsonb)
    INTO v_new_models
    FROM (
      SELECT DISTINCT value
       FROM jsonb_array_elements_text(
          COALESCE(v_old_group_config->'models', '[]'::jsonb) || (p->'model_ids')
        ) AS model_values(value)
       WHERE value <> ''
       ORDER BY value
    ) distinct_models;
  v_new_group_config := COALESCE(v_old_group_config, '{}'::jsonb)
    || jsonb_build_object('models', v_new_models, 'enabled', TRUE, 'explicit', TRUE);
  v_group_changed :=
    v_old_require_oauth IS DISTINCT FROM FALSE
    OR v_old_group_config IS DISTINCT FROM v_new_group_config;

  UPDATE groups
     SET require_oauth_only = FALSE,
         models_list_config = v_new_group_config,
         updated_at = NOW()
   WHERE id = v_group_id;

  INSERT INTO account_groups(account_id, group_id, priority, created_at)
  SELECT v_account_id, v_group_id, 0, NOW()
   WHERE NOT EXISTS (
     SELECT 1 FROM account_groups ag
      WHERE ag.account_id = v_account_id AND ag.group_id = v_group_id
   );
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  v_membership_added := v_rows > 0;

  INSERT INTO cline_sync_result(account_id, group_id, account_changed, group_changed, membership_added, model_count)
  VALUES (v_account_id, v_group_id, v_account_changed, v_group_changed, v_membership_added, jsonb_array_length(v_new_models));
END $$;
SELECT account_id::text || '|' || group_id::text || '|' ||
       account_changed::text || '|' || group_changed::text || '|' ||
       membership_added::text || '|' || model_count::text
  FROM cline_sync_result;
COMMIT;
'@

$psqlOutput = Invoke-PsqlScript -Sql $sql
$row = @($psqlOutput -split "`r?`n" | Where-Object { $_ -match '^\d+\|\d+\|(true|false)\|(true|false)\|(true|false)\|\d+$' } | Select-Object -Last 1)
if ($row.Count -eq 0) { throw "Cline Pass sync returned an unexpected PostgreSQL result" }

$parts = $row[0].Split('|')
$accountChanged = $parts[2] -eq "true"
$groupChanged = $parts[3] -eq "true"
$membershipAdded = $parts[4] -eq "true"
$changed = $accountChanged -or $groupChanged -or $membershipAdded
$dshSync = Sync-DshModelCatalog
$restarted = $false
if ($changed -and -not $NoRestart) { $restarted = Restart-Sub2api }

$result = $read.result
$result.status = if ($changed) { "synced" } else { "unchanged" }
$result.credentials_changed = $accountChanged
$result.group_changed = $groupChanged
$result.membership_added = $membershipAdded
$result.service_restarted = $restarted
$result.model_count = [int]$parts[5]
$result.dsh_model_catalog = $dshSync
($result | ConvertTo-Json -Compress)

param(
  [string]$AuthFile = "",
  [string]$ProviderSyncBaseUrl = "http://127.0.0.1:18081",
  [string]$ProviderSyncToken = "",
  [string]$AccountName = "cline-pass-subscription",
  [string]$GroupName = "headroom-openai-grok-composite",
  [string]$ClineBaseUrl = "https://api.cline.bot/api/v1",
  [string]$ClineVersion = "3.0.55",
  [string]$ClineCoreVersion = "0.0.75",
  [string]$DshSettingsPath = "",
  [switch]$CheckOnly,
  [switch]$ForceRefresh
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "provider-account-sync-api.ps1")
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

# This is the catalog shipped by the installed ClinePass provider. Keep the
# IDs exact: Cline's display names are not stable API identifiers.
$ClinePassModelIds = @(
  "cline-pass/qwen3.8-max",
  "poolside/laguna-s-2.1:free",
  "cline-pass/kimi-k3",
  "cline-pass/minimax-m3",
  "cline-pass/deepseek-v4-flash",
  "cline-pass/deepseek-v4-pro",
  "deepseek/deepseek-v4-flash",
  "cline-pass/mimo-v2.5",
  "cline-pass/mimo-v2.5-pro",
  "cline-pass/glm-5.3"
)

$ClinePassModelCatalog = [ordered]@{
  "cline-pass/qwen3.8-max" = @{ name = "Qwen3.8 Max"; context = 1000000 }
  "poolside/laguna-s-2.1:free" = @{ name = "Laguna S 2.1 (free)"; context = 262144 }
  "cline-pass/kimi-k3" = @{ name = "Kimi K3"; context = 1048576 }
  "cline-pass/minimax-m3" = @{ name = "MiniMax-M3"; context = 1048576 }
  "cline-pass/deepseek-v4-flash" = @{ name = "DeepSeek V4 Flash"; context = 1048576 }
  "cline-pass/deepseek-v4-pro" = @{ name = "DeepSeek V4 Pro"; context = 1048576 }
  "deepseek/deepseek-v4-flash" = @{ name = "DeepSeek V4 Flash"; context = 1048576 }
  "cline-pass/mimo-v2.5" = @{ name = "MiMo-V2.5"; context = 1050000 }
  "cline-pass/mimo-v2.5-pro" = @{ name = "MiMo-V2.5-Pro"; context = 1050000 }
  "cline-pass/glm-5.3" = @{ name = "cline-pass/glm-5.3"; context = 128000 }
}

# NVIDIA/Nemotron, Qwen versions below 3.8, GLM versions below 5.3, and Kimi
# versions below 3 are deliberately excluded from the shared DSH catalog.
# Remove stale entries as well as preventing future Cline Pass syncs from
# reintroducing them.
$DshExcludedModelPatterns = @(
  "(?i)^nvidia/",
  "(?i)nemotron",
  "(?i)qwen(?:[0-2](?:\.[0-9]+)?|3\.[0-7])(?:[^0-9]|$)",
  "(?i)glm[- ]?(?:[0-4](?:\.[0-9]+)?|5\.[0-2])(?:[^0-9]|$)",
  "(?i)kimi(?:[- ]k)?[0-2](?:\.[0-9]+)?(?:[^0-9]|$)"
)

# DSH only renders an effort picker when a model entry declares the levels it
# can send. Keep these declarations beside the catalog sync so a later Cline
# refresh cannot silently remove the picker from the composite route.
$DshReasoningCatalog = [ordered]@{
  "gpt-5.6-sol" = "low: low, medium: medium, high: high, xhigh: xhigh, max: max"
  "gpt-5.6" = "low: low, medium: medium, high: high, xhigh: xhigh, max: max"
  "grok-4.6" = "low: low, medium: medium, high: high"
  "grok-4.5" = "low: low, medium: medium, high: high"
  "gpt-5.6-luna" = "low: low, medium: medium, high: high, xhigh: xhigh, max: max"
  "cline-pass/qwen3.8-max" = "low: low, medium: medium, xhigh: xhigh"
  "cline-pass/kimi-k3" = "low: low, high: high, max: max"
  "cline-pass/minimax-m3" = "off: off, minimal: minimal, low: low, medium: medium, high: high"
  "cline-pass/deepseek-v4-flash" = "off: off, high: high, max: max"
  "cline-pass/deepseek-v4-pro" = "off: off, high: high, max: max"
  "deepseek/deepseek-v4-flash" = "off: off, high: high, max: max"
  "cline-pass/mimo-v2.5" = "off: off, minimal: minimal, low: low, medium: medium, high: high"
  "cline-pass/mimo-v2.5-pro" = "off: off, minimal: minimal, low: low, medium: medium, high: high"
  "cline-pass/glm-5.3" = "high: high, max: max"
}

# Grok Build reports a 500k prompt limit on its live Responses endpoint. Keep
# the DSH picker below that real provider boundary; the generic 1M catalog
# value let conversations grow into requests Grok must reject.
$DshContextWindowCatalog = [ordered]@{
  "grok-4.6" = 500000
  "grok-4.5" = 500000
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
  $removed = 0
  foreach ($pattern in $DshExcludedModelPatterns) {
    for ($i = $closeIndex - 1; $i -gt $openIndex; $i--) {
      $line = [string]$lines[$i]
      if ($line -notmatch 'id:\s*([^,}\s]+)') { continue }
      $modelId = $Matches[1]
      if ($modelId -notmatch $pattern) { continue }

      $start = $i
      while ($start -gt $openIndex) {
        $candidate = ([string]$lines[$start]).Trim()
        if ($candidate -match '^\{\s*$' -or $candidate -match '^\{\s*id:') { break }
        $start--
      }
      $end = $i
      while ($end -lt $closeIndex) {
        $candidate = ([string]$lines[$end]).Trim()
        if ($candidate -match '^\}\s*,?\s*$' -or $candidate -match '^\{.*\}\s*,?\s*$') { break }
        $end++
      }
      if ($end -ge $closeIndex) { $end = $i }

      $count = $end - $start + 1
      $lines.RemoveRange($start, $count)
      $closeIndex -= $count
      $removed++
      $i = [Math]::Min($i, $closeIndex - 1)
    }
  }

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

  $changed = $removed -gt 0
  $changed = $changed -or ($added -gt 0)
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

  $contextModels = [System.Collections.Generic.List[string]]::new()
  foreach ($pair in $DshContextWindowCatalog.GetEnumerator()) {
    $escapedId = [regex]::Escape($pair.Key)
    for ($i = $openIndex + 1; $i -lt $closeIndex; $i++) {
      $line = ([string]$lines[$i]).TrimEnd()
      if ($line -notmatch "(?:^|\s|\{)id:\s*$escapedId(?:,|\s*$)") { continue }

      $entryEnd = $closeIndex
      for ($j = $i; $j -lt $closeIndex; $j++) {
        if (([string]$lines[$j]).TrimEnd() -match '}\s*,?$') { $entryEnd = $j; break }
      }

      $updated = $false
      for ($j = $i; $j -le $entryEnd; $j++) {
        $candidate = ([string]$lines[$j]).TrimEnd()
        if ($candidate -notmatch 'contextWindow:\s*\d+') { continue }
        $replacement = [regex]::Replace($candidate, 'contextWindow:\s*\d+', "contextWindow: $($pair.Value)")
        if ($replacement -ne $candidate) {
          $lines[$j] = $replacement
          $changed = $true
        }
        $updated = $true
        break
      }

      if (-not $updated) {
        if ($entryEnd -eq $i) {
          $suffix = if ($line.EndsWith(',')) { ',' } else { '' }
          $replacement = [regex]::Replace($line.TrimEnd(','), '\s*}$', ", contextWindow: $($pair.Value) }") + $suffix
          $lines[$i] = $replacement
        } else {
          $propertyIndent = if ($line -match '^(\s*)') { $Matches[1] + '  ' } else { '                  ' }
          [void]$lines.Insert($entryEnd, $propertyIndent + "contextWindow: $($pair.Value),")
          $closeIndex++
        }
        $changed = $true
      }

      [void]$contextModels.Add($pair.Key)
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
  return [ordered]@{ status = if ($changed) { "updated" } else { "unchanged" }; path = $path; added = $added; removed = $removed; effort_models = @($effortModels); context_models = @($contextModels); model_count = $ClinePassModelCatalog.Count }
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

$credentialsObject = (ConvertTo-ClineCredentialsJson -Entry $read.entry) | ConvertFrom-Json
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
  openai_responses_mode = "force_chat_completions"
  openai_responses_supported = $false
  provider_sync_source = "cline_pass_cli"
  provider_sync_revision = 1
}
$sync = Sync-Sub2apiProviderAccount -BaseUrl $ProviderSyncBaseUrl -ProviderSyncToken $ProviderSyncToken -Source "cline_pass_cli" `
  -AccountName $AccountName -Platform "openai" -AccountType "apikey" -Credentials $credentials -Extra $extra `
  -GroupName $GroupName -GroupBody $groupBody -Concurrency 3 -Priority 0 -RateMultiplier 1.0
$dshSync = Sync-DshModelCatalog
$accountChanged = [bool]$sync.credentials_changed
$groupChanged = [bool]$sync.group_created -or [bool]$sync.group_changed
$membershipAdded = $true
$changed = $accountChanged -or $groupChanged
$result = $read.result
$result.status = if ($changed) { "synced" } else { "unchanged" }
$result.credentials_changed = [bool]$sync.credentials_changed
$result.group_changed = $groupChanged
$result.membership_added = $membershipAdded
$result.service_restarted = $false
$result.model_count = [int]$ClinePassModelIds.Count
$result.protocol_mode = [string]$sync.protocol_mode
$result.dsh_model_catalog = $dshSync
($result | ConvertTo-Json -Compress)

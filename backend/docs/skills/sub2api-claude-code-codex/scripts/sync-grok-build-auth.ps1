param(
  [string]$AuthFile = "",
  [string]$Distro = "Ubuntu-24.04",
  [string]$PostgresContainer = "sub2api-codex-postgres",
  [string]$DatabaseUser = "sub2api",
  [string]$DatabaseName = "sub2api",
  [string]$AccountName = "grok-build-subscription",
  [string]$CliBaseUrl = "https://cli-chat-proxy.grok.com/v1",
  [switch]$CheckOnly,
  [switch]$NoRestart
)

$ErrorActionPreference = "Stop"
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

  $credentials = [ordered]@{
    access_token = [string]$Entry.key
    refresh_token = [string]$Entry.refresh_token
    expires_at = [string]$Entry.expires_at
    token_type = if ([string]$Entry.token_type) { [string]$Entry.token_type } else { "Bearer" }
    base_url = $CliBaseUrl
    auth_source = "grok_build_cli"
  }
  foreach ($pair in @(
    @{ name = "id_token"; value = [string]$Entry.id_token },
    @{ name = "client_id"; value = [string]$Entry.oidc_client_id },
    @{ name = "scope"; value = [string]$Entry.scope },
    @{ name = "email"; value = [string]$Entry.email }
  )) {
    if (-not [string]::IsNullOrWhiteSpace($pair.value)) {
      $credentials[$pair.name] = $pair.value
    }
  }
  return ($credentials | ConvertTo-Json -Compress -Depth 8)
}

function Invoke-PsqlScript {
  param([string]$Sql)

  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = "wsl.exe"
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $arguments = @(
    "-d", $Distro, "--", "docker", "exec", "-i", $PostgresContainer,
    "psql", "-U", $DatabaseUser, "-d", $DatabaseName,
    "-v", "ON_ERROR_STOP=1", "-At"
  )
  if ($null -ne $psi.PSObject.Properties["ArgumentList"]) {
    foreach ($argument in $arguments) { $psi.ArgumentList.Add([string]$argument) }
  } else {
    # Windows PowerShell 5.1 has no ArgumentList property. Keep the normal
    # WSL argv unquoted; the bundled identifiers do not contain whitespace.
    $psi.Arguments = ($arguments -join ' ')
  }

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $psi
  if (-not $process.Start()) { throw "Could not start WSL PostgreSQL command" }
  $process.StandardInput.Write($Sql)
  $process.StandardInput.Close()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) {
    $safeError = ($stderr -replace "(?i)(access_token|refresh_token|id_token|key)\s*[=:]\s*\S+", '$1=<redacted>').Trim()
    throw "PostgreSQL sync failed: $safeError"
  }
  return $stdout.Trim()
}

function Restart-Sub2api {
  $output = & wsl.exe -d $Distro -- docker restart sub2api-codex 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "sub2api restart failed: $(($output -join ' ').Trim())"
  }
  for ($attempt = 0; $attempt -lt 45; $attempt++) {
    $health = ((@(& wsl.exe -d $Distro -- docker inspect -f '{{.State.Health.Status}}' sub2api-codex 2>$null)) -join "").Trim()
    if ($health -eq "healthy") { return $true }
    Start-Sleep -Seconds 2
  }
  throw "sub2api did not become healthy after Grok Build credential sync"
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

$credentialsJson = ConvertTo-GrokCredentialsJson -Entry $read.entry
$payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($credentialsJson))
$safeAccountName = $AccountName.Replace("'", "''")
$sql = @"
BEGIN;
CREATE TEMP TABLE incoming_grok_build_auth (payload text);
COPY incoming_grok_build_auth(payload) FROM STDIN;
$payloadBase64
\.
WITH incoming AS (
  SELECT convert_from(decode(payload, 'base64'), 'UTF8')::jsonb AS credentials
  FROM incoming_grok_build_auth
), target AS (
  SELECT a.id, a.credentials AS old_credentials, a.status AS old_status,
         a.schedulable AS old_schedulable, a.error_message AS old_error,
         a.temp_unschedulable_until AS old_temp_until,
         CASE
           WHEN COALESCE(a.credentials->>'refresh_token', '') IS DISTINCT FROM COALESCE(i.credentials->>'refresh_token', '')
             OR COALESCE(a.credentials->>'auth_source', '') <> 'grok_build_cli'
           THEN COALESCE(a.credentials, '{}'::jsonb) || i.credentials
           ELSE COALESCE(a.credentials, '{}'::jsonb) || jsonb_build_object(
             'base_url', i.credentials->>'base_url',
             'auth_source', 'grok_build_cli'
           )
         END AS new_credentials
  FROM accounts a CROSS JOIN incoming i
  WHERE a.name = '$safeAccountName' AND a.platform = 'grok' AND a.deleted_at IS NULL
)
UPDATE accounts a
SET credentials = COALESCE(a.credentials, '{}'::jsonb) || target.new_credentials,
    status = 'active',
    schedulable = TRUE,
    error_message = NULL,
    rate_limited_at = NULL,
    rate_limit_reset_at = NULL,
    overload_until = NULL,
    temp_unschedulable_until = NULL,
    temp_unschedulable_reason = NULL,
    updated_at = NOW()
FROM target
WHERE a.id = target.id
RETURNING a.id::text || '|' ||
  CASE WHEN target.old_credentials IS DISTINCT FROM (COALESCE(target.old_credentials, '{}'::jsonb) || target.new_credentials)
             OR target.old_status IS DISTINCT FROM 'active'
             OR target.old_schedulable IS DISTINCT FROM TRUE
             OR target.old_error IS NOT NULL
             OR target.old_temp_until IS NOT NULL
       THEN '1' ELSE '0' END;
COMMIT;
"@

$psqlOutput = Invoke-PsqlScript -Sql $sql
$row = @($psqlOutput -split "`r?`n" | Where-Object { $_ -match '^(\d+)\|([01])$' } | Select-Object -Last 1)
if ($row.Count -eq 0) {
  throw "Grok Build account '$AccountName' was not found or sync returned an unexpected result"
}

$changed = $row[0] -match '^[0-9]+\|1$'
$restarted = $false
if ($changed -and -not $NoRestart) {
  $restarted = Restart-Sub2api
}

($read.result | ForEach-Object {
  $_.status = if ($changed) { "synced" } else { "unchanged" }
  $_.credentials_changed = $changed
  $_.service_restarted = $restarted
  $_
} | ConvertTo-Json -Compress)

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet("status", "anthropic", "chatgpt", "hybrid", "reconcile", "verify")]
  [string]$Command = "status",
  [string]$RuntimeRoot = "C:\Users\stigm\Documents\Codex\2026-07-07\new-chat\work\sub2api-runtime",
  [string]$AdminBaseUrl = "http://127.0.0.1:18081",
  [string]$HeadroomBaseUrl = "http://127.0.0.1:8787",
  [string]$StableKeyName = "claude-code-codex-sub2api",
  [string]$ClaudeCredentialsPath = "$HOME\.claude\.credentials.json",
  [string]$CodexAuthPath = "$HOME\.codex\auth.json",
  [string]$WslDistro = "Ubuntu-24.04",
  [string]$LinuxGuestVmName = "devcontainer-ubuntu-2404",
  [string]$LinuxGuest = "migration@172.20.36.35",
  [string]$LinuxGuestKey = "C:\Migration\devcontainer-vm-key",
  [string]$WindowsGuestName = "win10-ltsc-docker",
  [string]$WindowsGuestCredentialBlob = "C:\Migration\native-windows-port\secrets\win10-ltsc-docker-admin.dpapi",
  [switch]$ForceCredentialRefresh,
  [switch]$SkipFleet
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$profileRoot = Join-Path (Split-Path -Parent $scriptRoot) "profiles"
$profileApplier = Join-Path $scriptRoot "apply-claude-provider-profile.ps1"
$linuxProfileApplier = Join-Path $scriptRoot "apply-claude-provider-profile.sh"
$statePath = Join-Path $RuntimeRoot "data\provider-route-state.json"
$envPath = Join-Path $RuntimeRoot ".env"
$postgresContainer = "sub2api-codex-postgres"

function Test-HttpEndpoint([string]$BaseUrl) {
  try {
    Invoke-WebRequest -UseBasicParsing -Uri "$($BaseUrl.TrimEnd('/'))/health" -TimeoutSec 3 | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Resolve-WslServiceUrl([string]$ConfiguredUrl, [int]$Port) {
  if ($Port -eq 8787) {
    $settingsPath = Join-Path $HOME ".claude\settings.json"
    if (Test-Path -LiteralPath $settingsPath) {
      try {
        $settingsUrl = [string](Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json).env.ANTHROPIC_BASE_URL
        if ($settingsUrl -and (Test-HttpEndpoint $settingsUrl)) { return $settingsUrl.TrimEnd('/') }
      } catch { }
    }
  }
  if (Test-HttpEndpoint $ConfiguredUrl) { return $ConfiguredUrl.TrimEnd('/') }
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $ConfiguredUrl.TrimEnd('/') }
  $addresses = @(& wsl.exe -d $WslDistro -- hostname -I 2>$null)
  if ($LASTEXITCODE -ne 0 -or $addresses.Count -eq 0) { return $ConfiguredUrl.TrimEnd('/') }
  $ip = (($addresses -join ' ').Trim() -split '\s+')[0]
  if (-not $ip) { return $ConfiguredUrl.TrimEnd('/') }
  $candidate = "http://${ip}:$Port"
  if (Test-HttpEndpoint $candidate) { return $candidate }
  return $ConfiguredUrl.TrimEnd('/')
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Read-DotEnv([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw "Runtime env not found: $Path" }
  $result = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { continue }
    $value = $Matches[2].Trim()
    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    $result[$Matches[1]] = $value
  }
  return $result
}

function Read-Profile([string]$Name) {
  $fileName = switch ($Name) {
    "anthropic-only" { "anthropic-only.v4.json" }
    "chatgpt-only" { "chatgpt-only.v4.json" }
    "hybrid-current" { "hybrid-current.v1.json" }
    default { throw "Unknown provider profile: $Name" }
  }
  $path = Join-Path $profileRoot $fileName
  if (-not (Test-Path -LiteralPath $path)) { throw "Profile not found: $path" }
  return [pscustomobject]@{ Path = $path; Data = (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json) }
}

function ConvertTo-SqlLiteral([string]$Value) {
  if ($null -eq $Value) { return "" }
  return $Value.Replace("'", "''")
}

function Invoke-PostgresSql([string]$Sql) {
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Sql))
  if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    $shellCommand = "printf '%s' '$encoded' | base64 -d | docker exec -i '$postgresContainer' psql -v ON_ERROR_STOP=1 -U sub2api -d sub2api -At"
    $output = @(& wsl.exe -d $WslDistro -- bash -lc $shellCommand 2>&1)
  } else {
    $output = @($Sql | & docker exec -i $postgresContainer psql -v ON_ERROR_STOP=1 -U sub2api -d sub2api -At 2>&1)
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Postgres command failed: $($output -join [Environment]::NewLine)"
  }
  return @($output | Where-Object { $_ -and $_.Trim() })
}

function Get-StableKey {
  $name = ConvertTo-SqlLiteral $StableKeyName
  $rows = @(Invoke-PostgresSql "SELECT id || chr(9) || key || chr(9) || COALESCE(group_id::text, '') FROM api_keys WHERE name = '$name' AND deleted_at IS NULL AND status = 'active';")
  if ($rows.Count -ne 1) { throw "Expected one active stable API key named '$StableKeyName', got $($rows.Count)" }
  $parts = $rows[0] -split "`t", 3
  return [pscustomobject]@{ Id = [int64]$parts[0]; Secret = $parts[1]; GroupId = if ($parts[2]) { [int64]$parts[2] } else { $null } }
}

function Get-AdminSession {
  $config = Read-DotEnv $envPath
  if (-not $config.ContainsKey("ADMIN_EMAIL") -or -not $config.ContainsKey("ADMIN_PASSWORD")) {
    throw "ADMIN_EMAIL or ADMIN_PASSWORD is missing in $envPath"
  }
  $body = @{ email = $config.ADMIN_EMAIL; password = $config.ADMIN_PASSWORD } | ConvertTo-Json -Compress
  $login = Invoke-RestMethod -Method Post -Uri "$AdminBaseUrl/api/v1/auth/login" -ContentType "application/json" -Body $body -TimeoutSec 20
  if (-not $login.data.access_token) { throw "Admin login did not return an access token" }
  return @{ Authorization = "Bearer $($login.data.access_token)" }
}

function Invoke-AdminApi([string]$Method, [string]$Path, $Body = $null) {
  $args = @{
    Method = $Method
    Uri = "$AdminBaseUrl$Path"
    Headers = $script:adminHeaders
    TimeoutSec = 30
  }
  if ($null -ne $Body) {
    $args.ContentType = "application/json"
    $args.Body = $Body | ConvertTo-Json -Depth 100 -Compress
  }
  $response = Invoke-RestMethod @args
  if ($null -ne $response.code -and [int]$response.code -ne 0) {
    throw "Admin API $Method $Path failed: $($response.message)"
  }
  return $response.data
}

function Get-Groups {
  $data = Invoke-AdminApi "Get" "/api/v1/admin/groups?page=1&page_size=200"
  return @($data.items)
}

function Get-Accounts {
  $data = Invoke-AdminApi "Get" "/api/v1/admin/accounts?page=1&page_size=200"
  return @($data.items)
}

function Get-GroupByName([string]$Name) {
  return @(Get-Groups | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
}

function Get-AccountByName([string]$Name) {
  return @(Get-Accounts | Where-Object { $_.name -eq $Name }) | Select-Object -First 1
}

function Ensure-ManagedGroup($Profile) {
  $group = Get-GroupByName $Profile.group_name
  $body = $Profile.group
  if ($null -eq $group) {
    Invoke-AdminApi "Post" "/api/v1/admin/groups" $body | Out-Null
  } else {
    if ($body.PSObject.Properties.Name -notcontains "status") { $body | Add-Member -NotePropertyName status -NotePropertyValue "active" }
    Invoke-AdminApi "Put" "/api/v1/admin/groups/$($group.id)" $body | Out-Null
  }
  $group = Get-GroupByName $Profile.group_name
  if ($null -eq $group) { throw "Managed provider group was not created" }

  $groupId = [int64]$group.id
  Invoke-PostgresSql "UPDATE groups SET fallback_group_id = NULL, fallback_group_id_on_invalid_request = NULL WHERE id = $groupId;" | Out-Null
  return $group
}

function Get-Sha256([string]$Value) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace("-", "").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Sync-CodexAuthFile {
  if (-not (Test-Path -LiteralPath $CodexAuthPath)) { throw "Codex auth file not found: $CodexAuthPath" }
  $auth = Get-Content -Raw -LiteralPath $CodexAuthPath | ConvertFrom-Json
  if (-not [string]$auth.tokens.access_token -or -not [string]$auth.tokens.refresh_token) {
    throw "Codex auth file lacks tokens.access_token or tokens.refresh_token"
  }
  $envMap = Read-DotEnv $envPath
  $stateRoot = if ($envMap.ContainsKey("SUB2API_STATE_ROOT") -and $envMap["SUB2API_STATE_ROOT"].Trim()) { $envMap["SUB2API_STATE_ROOT"].Trim() } else { "./data" }
  $sourceHash = (Get-FileHash -LiteralPath $CodexAuthPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($stateRoot.StartsWith("/")) {
    $sourcePortable = $CodexAuthPath -replace '\\', '/'
    $sourceWsl = @(& wsl.exe -d $WslDistro -- wslpath -a -u -- $sourcePortable 2>$null)
    if ($LASTEXITCODE -ne 0 -or $sourceWsl.Count -ne 1 -or -not $sourceWsl[0].Trim()) { throw "Could not translate Codex auth path into WSL" }
    $target = $stateRoot.TrimEnd('/') + "/sub2api/codex-auth.json"
    $targetDir = $stateRoot.TrimEnd('/') + "/sub2api"
    $temporaryTarget = "$target.tmp.$([guid]::NewGuid().ToString('N'))"
    & wsl.exe -d $WslDistro -- mkdir -p $targetDir 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not create WSL Codex auth directory" }
    & wsl.exe -d $WslDistro -- cp $sourceWsl[0].Trim() $temporaryTarget 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not stage Codex auth inside WSL" }
    & wsl.exe -d $WslDistro -- chmod 600 $temporaryTarget 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not protect staged Codex auth inside WSL" }
    & wsl.exe -d $WslDistro -- mv -f $temporaryTarget $target 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not atomically publish Codex auth inside WSL" }
    $targetHashOutput = @(& wsl.exe -d $WslDistro -- sha256sum $target 2>$null)
    $targetHash = if ($LASTEXITCODE -eq 0 -and $targetHashOutput.Count -gt 0) { (($targetHashOutput[0] -split '\s+')[0]).ToLowerInvariant() } else { "" }
    if ($sourceHash -ne $targetHash) { throw "WSL Codex auth hash verification failed" }
    return [pscustomobject]@{ status = "synced"; target = $target; sha256 = $sourceHash }
  }
  $resolvedRoot = if ([IO.Path]::IsPathRooted($stateRoot)) { $stateRoot } else { Join-Path $RuntimeRoot ($stateRoot -replace '^\.[\\/]', '') }
  $targetDir = Join-Path $resolvedRoot "sub2api"
  $target = Join-Path $targetDir "codex-auth.json"
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
  Copy-Item -LiteralPath $CodexAuthPath -Destination $target -Force
  $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($sourceHash -ne $targetHash) { throw "Codex auth hash verification failed" }
  return [pscustomobject]@{ status = "synced"; target = $target; sha256 = $sourceHash }
}

function Get-ClaudeSourceCredentials {
  if (-not (Test-Path -LiteralPath $ClaudeCredentialsPath)) { throw "Claude credentials not found: $ClaudeCredentialsPath" }
  $source = (Get-Content -Raw -LiteralPath $ClaudeCredentialsPath | ConvertFrom-Json).claudeAiOauth
  if (-not $source.accessToken -or -not $source.refreshToken) { throw "Claude OAuth accessToken or refreshToken is missing" }
  $expiresMs = [int64]$source.expiresAt
  $epoch = [DateTimeOffset]::Parse("1970-01-01T00:00:00Z")
  $expires = $epoch.AddMilliseconds($expiresMs)
  return [pscustomobject]@{
    Credentials = @{
      access_token = [string]$source.accessToken
      refresh_token = [string]$source.refreshToken
      expires_at = $expires.ToUniversalTime().ToString("o")
      token_type = "Bearer"
    }
    ExpiresMs = $expiresMs
    ExpiresUnix = [int64][Math]::Floor($expiresMs / 1000)
    Fingerprint = Get-Sha256 ([string]$source.refreshToken)
    SubscriptionType = [string]$source.subscriptionType
    RateLimitTier = [string]$source.rateLimitTier
  }
}

function Ensure-AnthropicAccount($Profile, [int64]$GroupId) {
  $account = Get-AccountByName $Profile.account_name
  $source = $null
  if ($null -eq $account -or $ForceCredentialRefresh) {
    $source = Get-ClaudeSourceCredentials
  } else {
    try {
      $source = Get-ClaudeSourceCredentials
    } catch {
      Write-Verbose "Local Claude source credentials unavailable; preserving sub2api-owned OAuth credentials."
    }
  }
  $notes = "Managed by sub2api-claude-code-codex from the local Claude Code subscription."
  $extra = if ($source) {
    @{
      route_switcher_source_fingerprint = $source.Fingerprint
      route_switcher_source_expires_ms = $source.ExpiresMs
      subscription_type = $source.SubscriptionType
      rate_limit_tier = $source.RateLimitTier
    }
  } else { $null }

  if ($null -eq $account) {
    $body = @{
      name = $Profile.account_name
      notes = $notes
      platform = "anthropic"
      type = "oauth"
      credentials = $source.Credentials
      extra = $extra
      concurrency = 10
      priority = 1
      rate_multiplier = 1.0
      load_factor = 100
      group_ids = @($GroupId)
      expires_at = $source.ExpiresUnix
      auto_pause_on_expired = $false
      confirm_mixed_channel_risk = $true
    }
    Invoke-AdminApi "Post" "/api/v1/admin/accounts" $body | Out-Null
    $account = Get-AccountByName $Profile.account_name
    if ($null -eq $account) { throw "Managed Claude OAuth account was not created" }
  } else {
    $accountDetail = Invoke-AdminApi "Get" "/api/v1/admin/accounts/$($account.id)"
    $shouldRefresh = $false
    if ($source) {
      $existingFingerprint = [string]$accountDetail.extra.route_switcher_source_fingerprint
      $existingExpiresMs = 0
      if ($accountDetail.extra.route_switcher_source_expires_ms) { $existingExpiresMs = [int64]$accountDetail.extra.route_switcher_source_expires_ms }
      $shouldRefresh = $ForceCredentialRefresh -or (-not $existingFingerprint) -or (($existingFingerprint -ne $source.Fingerprint) -and ($source.ExpiresMs -gt $existingExpiresMs))
    }
    if ($source -and $shouldRefresh) {
      Invoke-AdminApi "Post" "/api/v1/admin/accounts/$($account.id)/apply-oauth-credentials" @{
        type = "oauth"
        credentials = $source.Credentials
        extra = $extra
      } | Out-Null
    }
    $updateBody = @{
      name = $Profile.account_name
      notes = $notes
      type = "oauth"
      status = "active"
      schedulable = $true
      concurrency = 10
      priority = 1
      rate_multiplier = 1.0
      load_factor = 100
      group_ids = @($GroupId)
      auto_pause_on_expired = $false
      confirm_mixed_channel_risk = $true
    }
    if ($source) { $updateBody.expires_at = $source.ExpiresUnix }
    Invoke-AdminApi "Put" "/api/v1/admin/accounts/$($account.id)" $updateBody | Out-Null
    Invoke-AdminApi "Post" "/api/v1/admin/accounts/$($account.id)/schedulable" @{ schedulable = $true } | Out-Null
  }

  $account = Get-AccountByName $Profile.account_name
  $accountId = [int64]$account.id
  Invoke-PostgresSql "DELETE FROM account_groups WHERE group_id = $GroupId AND account_id <> $accountId;" | Out-Null
  return $account
}

function Ensure-ChatGPTAccount($Profile, [int64]$GroupId) {
  $authProof = Sync-CodexAuthFile
  $account = Get-AccountByName $Profile.account_name
  if ($null -eq $account) { throw "ChatGPT/Codex account '$($Profile.account_name)' does not exist" }
  if ([string]$account.platform -ne "openai" -or [string]$account.type -ne "oauth") {
    throw "ChatGPT/Codex account '$($Profile.account_name)' must be an OpenAI OAuth account"
  }
  $accountId = [int64]$account.id
  Invoke-PostgresSql "INSERT INTO account_groups (account_id, group_id) VALUES ($accountId, $GroupId) ON CONFLICT (account_id, group_id) DO NOTHING; DELETE FROM account_groups WHERE group_id = $GroupId AND account_id <> $accountId;" | Out-Null
  return [pscustomobject]@{ account = $account; auth = $authProof }
}

function Set-StableKeyGroup([int64]$KeyId, [int64]$GroupId) {
  Invoke-AdminApi "Put" "/api/v1/admin/api-keys/$KeyId" @{ group_id = $GroupId } | Out-Null
}

function Invoke-HeadroomProbe($Profile, $StableKey) {
  $sessionId = [guid]::NewGuid().ToString()
  $probeNonce = [guid]::NewGuid().ToString("N")
  $requestStarted = [DateTimeOffset]::UtcNow
  $body = @{
    model = [string]$Profile.main_model
    max_tokens = 24
    stream = $false
    system = "You are Claude Code, Anthropic's official CLI for Claude."
    metadata = @{ user_id = "user_$('a' * 64)_account__session_$sessionId" }
    messages = @(@{ role = "user"; content = "Reply exactly ROUTE_OK_$probeNonce" })
  } | ConvertTo-Json -Depth 20 -Compress
  $headers = @{
    "x-api-key" = $StableKey.Secret
    "Authorization" = "Bearer $($StableKey.Secret)"
    "anthropic-version" = "2023-06-01"
  }
  $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$HeadroomBaseUrl/v1/messages" -Headers $headers -ContentType "application/json" -Body $body -TimeoutSec 180
  if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) { throw "Headroom probe returned HTTP $($response.StatusCode)" }

  $startedSql = ConvertTo-SqlLiteral $requestStarted.ToString("o")
  $proofRows = @()
  for ($attempt = 0; $attempt -lt 10 -and $proofRows.Count -eq 0; $attempt++) {
    if ($attempt -gt 0) { Start-Sleep -Milliseconds 500 }
    $proofRows = @(Invoke-PostgresSql @"
SELECT row_to_json(proof)::text
FROM (
  SELECT u.id, u.requested_model, u.model, u.upstream_model, u.model_mapping_chain,
         u.reasoning_effort, u.duration_ms, u.created_at, a.id AS account_id,
         a.name AS account_name, a.platform AS account_platform, a.type AS account_type,
         u.group_id
  FROM usage_logs u
  JOIN accounts a ON a.id = u.account_id
  WHERE u.api_key_id = $($StableKey.Id)
    AND u.created_at >= '$startedSql'::timestamptz
  ORDER BY u.id DESC
  LIMIT 1
) proof;
"@)
  }
  if ($proofRows.Count -ne 1) { throw "Headroom probe succeeded but no matching usage_log row appeared" }
  $proof = $proofRows[0] | ConvertFrom-Json
  if ([string]$proof.account_platform -ne [string]$Profile.expected_provider) {
    throw "Wrong provider after switch: expected $($Profile.expected_provider), got $($proof.account_platform)"
  }
  if ([string]$proof.account_type -ne [string]$Profile.expected_account_type) {
    throw "Wrong account type after switch: expected $($Profile.expected_account_type), got $($proof.account_type)"
  }
  if ($Profile.expected_account_name -and [string]$proof.account_name -ne [string]$Profile.expected_account_name) {
    throw "Wrong account after switch: expected $($Profile.expected_account_name), got $($proof.account_name)"
  }
  return $proof
}

function Read-State {
  if (-not (Test-Path -LiteralPath $statePath)) { return $null }
  return Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
}

function Write-State($State) {
  Write-Utf8NoBom $statePath (($State | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
}

function Apply-HostProfile($ProfileRecord, [string]$Generation) {
  $json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $profileApplier -ProfilePath $ProfileRecord.Path -Generation $Generation 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Host profile apply failed: $($json -join [Environment]::NewLine)" }
  return ($json -join [Environment]::NewLine | ConvertFrom-Json)
}

function Test-HostProfile($ProfileRecord, [string]$Generation) {
  $json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $profileApplier -ProfilePath $ProfileRecord.Path -Generation $Generation -CheckOnly 2>&1
  $exitCode = $LASTEXITCODE
  $parsed = $null
  try { $parsed = $json -join [Environment]::NewLine | ConvertFrom-Json } catch { }
  return [pscustomobject]@{ status = if ($exitCode -eq 0) { "synced" } else { "drifted" }; exit_code = $exitCode; detail = $parsed }
}

function Reconcile-LinuxGuest($ProfileRecord, [string]$Generation) {
  $ErrorActionPreference = "Continue"
  $result = [ordered]@{ name = $LinuxGuestVmName; status = "pending-reconcile"; generation = $Generation; checked_at = [DateTimeOffset]::UtcNow.ToString("o"); detail = "offline or unreachable" }
  if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) { $result.detail = "ssh.exe unavailable"; return [pscustomobject]$result }
  if (-not (Test-Path -LiteralPath $LinuxGuestKey)) { $result.detail = "SSH key unavailable"; return [pscustomobject]$result }
  $sshArgs = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new", "-i", $LinuxGuestKey)
  $guestParts = $LinuxGuest -split '@', 2
  $guestUser = if ($guestParts.Count -eq 2) { $guestParts[0] } else { "migration" }
  $targets = [Collections.Generic.List[string]]::new()
  $vmNameLiteral = $LinuxGuestVmName.Replace("'", "''")
  $discoveredIps = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "(Get-VMNetworkAdapter -VMName '$vmNameLiteral' -ErrorAction SilentlyContinue).IPAddresses" 2>$null)
  foreach ($ip in $discoveredIps) {
    $candidateIp = [string]$ip
    if ($candidateIp -match '^\d+\.\d+\.\d+\.\d+$' -and -not $candidateIp.StartsWith('169.254.')) { $targets.Add("${guestUser}@${candidateIp}") }
  }
  if ($LinuxGuest.Trim()) { $targets.Add($LinuxGuest) }
  $activeTarget = $null
  $lastProbe = "Hyper-V guest is not registered or has no reachable SSH address"
  foreach ($target in @($targets | Select-Object -Unique)) {
    $probe = @(& ssh.exe @sshArgs $target "true" 2>&1)
    if ($LASTEXITCODE -eq 0) { $activeTarget = $target; break }
    $lastProbe = ($probe -join " ").Trim()
  }
  if (-not $activeTarget) { $result.detail = $lastProbe; return [pscustomobject]$result }
  $remoteRoot = ".cache/sub2api-claude-route"
  & ssh.exe @sshArgs $activeTarget "mkdir -p $remoteRoot" | Out-Null
  if ($LASTEXITCODE -ne 0) { $result.detail = "failed to create remote staging directory"; return [pscustomobject]$result }
  & scp.exe @sshArgs $ProfileRecord.Path "${activeTarget}:${remoteRoot}/profile.json" | Out-Null
  if ($LASTEXITCODE -ne 0) { $result.detail = "failed to stage profile"; return [pscustomobject]$result }
  & scp.exe @sshArgs $linuxProfileApplier "${activeTarget}:${remoteRoot}/apply-profile.sh" | Out-Null
  if ($LASTEXITCODE -ne 0) { $result.detail = "failed to stage Linux applier"; return [pscustomobject]$result }
  $remote = @(& ssh.exe @sshArgs $activeTarget "chmod 700 $remoteRoot/apply-profile.sh && bash $remoteRoot/apply-profile.sh --profile-path $remoteRoot/profile.json --generation '$Generation'" 2>&1)
  $remoteText = ($remote -join " ").Trim()
  if ($LASTEXITCODE -eq 0) {
    $result.status = "synced"
    try { $result.detail = $remoteText | ConvertFrom-Json } catch { $result.detail = $remoteText }
  } else { $result.detail = $remoteText }
  return [pscustomobject]$result
}

function Reconcile-WindowsGuest($ProfileRecord, [string]$Generation) {
  $result = [ordered]@{ name = $WindowsGuestName; status = "pending-reconcile"; generation = $Generation; checked_at = [DateTimeOffset]::UtcNow.ToString("o"); detail = "offline, unavailable, or host is not elevated" }
  if (-not (Get-Command New-PSSession -ErrorAction SilentlyContinue)) { $result.detail = "PowerShell remoting unavailable"; return [pscustomobject]$result }
  if (-not (Test-Path -LiteralPath $WindowsGuestCredentialBlob)) { $result.detail = "DPAPI credential blob unavailable"; return [pscustomobject]$result }
  $session = $null
  $plain = $null
  $password = $null
  $securePassword = $null
  try {
    Add-Type -AssemblyName System.Security
    $blob = [IO.File]::ReadAllBytes($WindowsGuestCredentialBlob)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($blob, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $password = [Text.Encoding]::UTF8.GetString($plain)
    $securePassword = [Security.SecureString]::new()
    foreach ($character in $password.ToCharArray()) { $securePassword.AppendChar($character) }
    $securePassword.MakeReadOnly()
    $credential = [pscredential]::new("admin", $securePassword)
    $session = New-PSSession -VMName $WindowsGuestName -Credential $credential -ErrorAction Stop
    $remoteRoot = Invoke-Command -Session $session -ScriptBlock {
      $path = Join-Path $env:LOCALAPPDATA "sub2api-claude-route"
      New-Item -ItemType Directory -Path $path -Force | Out-Null
      return $path
    }
    Copy-Item -LiteralPath $ProfileRecord.Path -Destination (Join-Path $remoteRoot "profile.json") -ToSession $session -Force
    Copy-Item -LiteralPath $profileApplier -Destination (Join-Path $remoteRoot "apply-profile.ps1") -ToSession $session -Force
    $remote = Invoke-Command -Session $session -ArgumentList $remoteRoot,$Generation -ScriptBlock {
      param($Root,$Gen)
      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root "apply-profile.ps1") -ProfilePath (Join-Path $Root "profile.json") -Generation $Gen
      if ($LASTEXITCODE -ne 0) { throw "Guest profile applier failed with exit code $LASTEXITCODE" }
    }
    $result.status = "synced"
    $remoteText = ($remote -join " ").Trim()
    try { $result.detail = $remoteText | ConvertFrom-Json } catch { $result.detail = $remoteText }
  } catch {
    $result.detail = $_.Exception.Message
  } finally {
    if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
    if ($securePassword) { $securePassword.Dispose() }
    if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
    $password = $null
  }
  return [pscustomobject]$result
}

function Reconcile-Fleet($ProfileRecord, [string]$Generation) {
  $nodes = [ordered]@{}
  try {
    $hostResult = Apply-HostProfile $ProfileRecord $Generation
    $nodes.windows_host = [pscustomobject]@{ name = [Environment]::MachineName; status = "synced"; generation = $Generation; checked_at = [DateTimeOffset]::UtcNow.ToString("o"); detail = $hostResult }
  } catch {
    $nodes.windows_host = [pscustomobject]@{ name = [Environment]::MachineName; status = "drifted"; generation = $Generation; checked_at = [DateTimeOffset]::UtcNow.ToString("o"); detail = $_.Exception.Message }
  }
  if ($SkipFleet) { return [pscustomobject]$nodes }
  $nodes.ubuntu_hyperv = Reconcile-LinuxGuest $ProfileRecord $Generation
  $nodes.windows_hyperv = Reconcile-WindowsGuest $ProfileRecord $Generation
  return [pscustomobject]$nodes
}

function Get-ProfileForGroup([string]$GroupName) {
  foreach ($name in @("anthropic-only", "chatgpt-only", "hybrid-current")) {
    $record = Read-Profile $name
    if ($record.Data.group_name -eq $GroupName) { return $record }
  }
  return $null
}

function Show-Status {
  $key = Get-StableKey
  $groups = Get-Groups
  $activeGroup = @($groups | Where-Object { [int64]$_.id -eq [int64]$key.GroupId }) | Select-Object -First 1
  $state = Read-State
  $profileRecord = if ($activeGroup) { Get-ProfileForGroup $activeGroup.name } else { $null }
  $generation = if ($state -and $state.generation) { [string]$state.generation } else { "0" }
  $hostStatus = if ($profileRecord) { Test-HostProfile $profileRecord $generation } else { [pscustomobject]@{status="unknown";exit_code=$null;detail=$null} }
  [pscustomobject]@{
    command = "status"
    active_profile = if ($profileRecord) { $profileRecord.Data.name } else { "unknown" }
    active_group_id = $key.GroupId
    active_group_name = if ($activeGroup) { $activeGroup.name } else { $null }
    generation = $generation
    proxy_verified_at = if ($state) { $state.proxy_verified_at } else { $null }
    host = $hostStatus
    nodes = if ($state) { $state.nodes } else { $null }
  } | ConvertTo-Json -Depth 30
}

function Invoke-Switch([string]$ProfileName) {
  $profileRecord = Read-Profile $ProfileName
  $profile = $profileRecord.Data
  $stableKey = Get-StableKey
  $oldGroupId = $stableKey.GroupId
  $oldGroups = Get-Groups
  $oldGroup = @($oldGroups | Where-Object { [int64]$_.id -eq [int64]$oldGroupId }) | Select-Object -First 1

  if ($profile.PSObject.Properties.Name -contains "group") {
    $targetGroup = Ensure-ManagedGroup $profile
  } else {
    $targetGroup = Get-GroupByName $profile.group_name
    if ($null -eq $targetGroup) { throw "Hybrid group '$($profile.group_name)' does not exist" }
  }
  if ($ProfileName -eq "anthropic-only") {
    Ensure-AnthropicAccount $profile ([int64]$targetGroup.id) | Out-Null
  } elseif ($ProfileName -eq "chatgpt-only") {
    Ensure-ChatGPTAccount $profile ([int64]$targetGroup.id) | Out-Null
  }

  $targetGroupId = [int64]$targetGroup.id
  $oldState = Read-State
  $generation = if ($oldState -and $oldState.generation) { [int64]$oldState.generation + 1 } else { 1 }
  $switchedAt = [DateTimeOffset]::UtcNow.ToString("o")
  try {
    Set-StableKeyGroup $stableKey.Id $targetGroupId
    $stableKey.GroupId = $targetGroupId
    $proof = Invoke-HeadroomProbe $profile $stableKey
  } catch {
    $failure = $_.Exception.Message
    if ($null -ne $oldGroupId) {
      try {
        Set-StableKeyGroup $stableKey.Id ([int64]$oldGroupId)
        $stableKey.GroupId = [int64]$oldGroupId
        if ($oldGroup) {
          $oldProfileRecord = Get-ProfileForGroup $oldGroup.name
          if ($oldProfileRecord) {
            $rollbackProof = Invoke-HeadroomProbe $oldProfileRecord.Data $stableKey
            $failure += "; rollback verified on $($rollbackProof.account_name)"
          }
        }
      } catch {
        $failure += "; rollback failed: $($_.Exception.Message)"
      }
    }
    throw "Switch to '$ProfileName' failed and the stable key was restored: $failure"
  }

  $state = [pscustomobject]@{
    active_profile = $ProfileName
    profile_version = $profile.version
    generation = $generation
    stable_key_id = $stableKey.Id
    active_group_id = $targetGroupId
    active_group_name = $targetGroup.name
    previous_group_id = $oldGroupId
    previous_group_name = if ($oldGroup) { $oldGroup.name } else { $null }
    switched_at = $switchedAt
    proxy_verified_at = [DateTimeOffset]::UtcNow.ToString("o")
    proxy_proof = $proof
    nodes = [pscustomobject]@{}
  }
  Write-State $state
  $state.nodes = Reconcile-Fleet $profileRecord ([string]$generation)
  Write-State $state
  $state | ConvertTo-Json -Depth 30
}

function Invoke-Reconcile {
  $stableKey = Get-StableKey
  $group = @(Get-Groups | Where-Object { [int64]$_.id -eq [int64]$stableKey.GroupId }) | Select-Object -First 1
  if ($null -eq $group) { throw "Stable key is not bound to a known group" }
  $profileRecord = Get-ProfileForGroup $group.name
  if ($null -eq $profileRecord) { throw "No versioned profile matches active group '$($group.name)'" }
  $state = Read-State
  $generation = if ($state -and $state.generation) { [string]$state.generation } else { "1" }
  $nodes = Reconcile-Fleet $profileRecord $generation
  if (-not $state) {
    $state = [pscustomobject]@{
      active_profile = $profileRecord.Data.name; profile_version = $profileRecord.Data.version; generation = [int64]$generation
      stable_key_id = $stableKey.Id; active_group_id = $stableKey.GroupId; active_group_name = $group.name
      previous_group_id = $null; previous_group_name = $null; switched_at = $null; proxy_verified_at = $null
      proxy_proof = $null; nodes = $nodes
    }
  } else {
    $state.nodes = $nodes
  }
  Write-State $state
  $state | ConvertTo-Json -Depth 30
}

function Invoke-Verify {
  $verifier = Join-Path $scriptRoot "verify-claude-provider-route.ps1"
  $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifier -RuntimeRoot $RuntimeRoot -WslDistro $WslDistro -StableKeyName $StableKeyName -HeadroomBaseUrl $HeadroomBaseUrl 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "Provider route verification failed: $($output -join [Environment]::NewLine)" }
  $output -join [Environment]::NewLine
}

$AdminBaseUrl = Resolve-WslServiceUrl $AdminBaseUrl 18081
$HeadroomBaseUrl = Resolve-WslServiceUrl $HeadroomBaseUrl 8787
$script:adminHeaders = Get-AdminSession
switch ($Command) {
  "status" { Show-Status }
  "anthropic" { Invoke-Switch "anthropic-only" }
  "chatgpt" { Invoke-Switch "chatgpt-only" }
  "hybrid" { Invoke-Switch "hybrid-current" }
  "reconcile" { Invoke-Reconcile }
  "verify" { Invoke-Verify }
}

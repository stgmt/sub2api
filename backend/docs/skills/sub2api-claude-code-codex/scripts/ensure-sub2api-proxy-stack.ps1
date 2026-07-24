param(
  [string]$RepoRoot = "",
  [string]$ProfileDir = "",
  [string]$ProjectName = "sub2api-codex",
  [string]$Distro = "Ubuntu-24.04",
  [int]$HeadroomPort = 8787,
  [int]$Sub2apiPort = 18081,
  [int]$HealthTimeoutSeconds = 4,
  [int]$RecoveryWaitSeconds = 120,
  [int]$HealthyHeartbeatMinutes = 30,
  [int]$ProviderReconcileMinutes = 15,
  [string]$HyperVVmName = "",
  [string]$HyperVVmSshUser = "",
  [string]$HyperVVmSshKey = "",
  [string]$HyperVSwitchName = "Default Switch",
  [ValidateSet("ssh", "none")]
  [string]$HyperVRemoteConfigMode = "ssh",
  [bool]$RequireHyperVBridge = $false,
  [string]$CodexAuthFile = ""
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$ScriptDir = Split-Path -Parent $PSCommandPath

function Resolve-ProfileDir {
  if ($ProfileDir.Trim()) {
    return (Resolve-Path -LiteralPath $ProfileDir).Path
  }
  if ($RepoRoot.Trim()) {
    $candidate = Join-Path (Resolve-Path -LiteralPath $RepoRoot).Path "deploy\claude-code-codex-headroom"
    if (Test-Path -LiteralPath (Join-Path $candidate "docker-compose.yml")) {
      return $candidate
    }
  }
  throw "Could not resolve the sub2api runtime profile. Pass -ProfileDir or -RepoRoot."
}

function Read-EnvFile {
  param([string]$Path)

  $result = @{}
  if (-not (Test-Path -LiteralPath $Path)) { return $result }
  foreach ($line in Get-Content -LiteralPath $Path) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith("#") -or $trimmed -notmatch "=") { continue }
    $parts = $trimmed.Split("=", 2)
    $result[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'")
  }
  return $result
}

function Write-Utf8NoBom {
  param([string]$Path, [string]$Content)
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Write-SelfHealEvent {
  param(
    [string]$Event,
    [hashtable]$Data = @{}
  )

  $row = [ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString("o")
    event = $Event
  }
  foreach ($key in $Data.Keys) { $row[$key] = $Data[$key] }
  [IO.File]::AppendAllText(
    $LogPath,
    (($row | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
  )
}

function Invoke-ProviderRouteReconcile {
  param([string]$ProfileRoot)

  $routeStatePath = Join-Path $ProfileRoot "data\provider-route-state.json"
  if (-not (Test-Path -LiteralPath $routeStatePath)) {
    return [pscustomobject]@{ status = "disabled"; reason = "provider route state is not initialized" }
  }

  try {
    $routeState = Get-Content -Raw -LiteralPath $routeStatePath | ConvertFrom-Json
    $generation = [string]$routeState.generation
    $settingsPath = Join-Path $HOME ".claude\settings.json"
    $localGeneration = ""
    if (Test-Path -LiteralPath $settingsPath) {
      try { $localGeneration = [string](Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json).env.CLAUDE_PROVIDER_PROFILE_GENERATION } catch { }
    }
    $localDrift = $generation -ne $localGeneration
    $pendingNodes = @($routeState.nodes.PSObject.Properties | Where-Object { [string]$_.Value.status -ne "synced" }).Count
    if (-not $localDrift -and $pendingNodes -eq 0) {
      return [pscustomobject]@{ status = "synced"; generation = $generation; attempted = $false }
    }

    $attemptStatePath = Join-Path $ProfileRoot "logs\provider-route-reconcile-state.json"
    if (-not $localDrift -and (Test-Path -LiteralPath $attemptStatePath)) {
      try {
        $lastAttempt = [DateTimeOffset]::Parse([string](Get-Content -Raw -LiteralPath $attemptStatePath | ConvertFrom-Json).attempted_at)
        if (([DateTimeOffset]::UtcNow - $lastAttempt.ToUniversalTime()).TotalMinutes -lt $ProviderReconcileMinutes) {
          return [pscustomobject]@{ status = "throttled"; generation = $generation; pending_nodes = $pendingNodes; attempted = $false }
        }
      } catch { }
    }

    $candidates = @(
      (Join-Path $HOME ".codex\skills\claude-provider-switcher\scripts\claude-route.ps1")
    )
    if ($RepoRoot.Trim()) {
      $candidates += Join-Path $RepoRoot "backend\docs\skills\claude-provider-switcher\scripts\claude-route.ps1"
    }
    $controller = @($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if ($controller.Count -eq 0) {
      return [pscustomobject]@{ status = "pending-reconcile"; reason = "claude-route controller is not installed"; attempted = $false }
    }

    Write-Utf8NoBom -Path $attemptStatePath -Content (([ordered]@{ attempted_at = [DateTimeOffset]::UtcNow.ToString("o"); generation = $generation } | ConvertTo-Json -Compress) + [Environment]::NewLine)
    $output = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $controller[0] reconcile -RuntimeRoot $ProfileRoot 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ($output -join [Environment]::NewLine) }
    $result = $output -join [Environment]::NewLine | ConvertFrom-Json
    Write-SelfHealEvent -Event "provider_route_reconciled" -Data @{ generation = $generation; active_profile = $result.active_profile }
    return [pscustomobject]@{ status = "reconciled"; generation = $generation; attempted = $true; nodes = $result.nodes }
  } catch {
    Write-SelfHealEvent -Event "provider_route_reconcile_failed" -Data @{ error = $_.Exception.Message }
    return [pscustomobject]@{ status = "pending-reconcile"; attempted = $true; reason = $_.Exception.Message }
  }
}

function Write-HyperVInventorySnapshot {
  $inventoryPath = Join-Path $LogDir "hyperv-inventory.json"
  try {
    Import-Module Hyper-V -ErrorAction Stop
    $vms = foreach ($vm in (Get-VM -ErrorAction Stop)) {
      $adapters = @(Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction SilentlyContinue)
      $services = @(Get-VMIntegrationService -VMName $vm.Name -ErrorAction SilentlyContinue)
      [ordered]@{
        name = $vm.Name
        state = [string]$vm.State
        status = [string]$vm.Status
        generation = $vm.Generation
        automatic_start_action = [string]$vm.AutomaticStartAction
        addresses = @($adapters | ForEach-Object { @($_.IPAddresses) } | Where-Object { $_ })
        adapters = @($adapters | ForEach-Object {
          [ordered]@{
            switch = $_.SwitchName
            mac = $_.MacAddress
            status = [string]$_.Status
          }
        })
        integration_services = @($services | ForEach-Object {
          [ordered]@{
            name = $_.Name
            enabled = [bool]$_.Enabled
            primary_status = [string]$_.PrimaryStatusDescription
          }
        })
      }
    }
    Write-Utf8NoBom -Path $inventoryPath -Content (([ordered]@{
      captured_at = (Get-Date).ToUniversalTime().ToString("o")
      vms = @($vms)
    } | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
  } catch {
    Write-SelfHealEvent -Event "hyperv_inventory_failed" -Data @{ error = $_.Exception.Message }
  }
}

function Sync-HyperVGuestSubagentProfiles {
  param([hashtable]$BridgeEnv)

  if (-not $BridgeEnv.ContainsKey("HEADROOM_HYPERV_STAGE_QWEN_PROFILE") -or
      $BridgeEnv["HEADROOM_HYPERV_STAGE_QWEN_PROFILE"] -notmatch "^(1|true|yes|on)$") {
    return
  }

  $sourceScript = Join-Path $ScriptDir "sync-claude-subagent-profile.ps1"
  if (-not (Test-Path -LiteralPath $sourceScript)) {
    Write-SelfHealEvent -Event "hyperv_subagent_profile_failed" -Data @{ error = "profile sync script is missing"; source = $sourceScript }
    return
  }

  $model = if ($BridgeEnv.ContainsKey("HEADROOM_HYPERV_SUBAGENT_MODEL") -and $BridgeEnv["HEADROOM_HYPERV_SUBAGENT_MODEL"].Trim()) {
    $BridgeEnv["HEADROOM_HYPERV_SUBAGENT_MODEL"].Trim()
  } else {
    "qwen3.8-max-preview"
  }
  $effort = if ($BridgeEnv.ContainsKey("HEADROOM_HYPERV_SUBAGENT_EFFORT") -and $BridgeEnv["HEADROOM_HYPERV_SUBAGENT_EFFORT"].Trim()) {
    $BridgeEnv["HEADROOM_HYPERV_SUBAGENT_EFFORT"].Trim()
  } else {
    "high"
  }
  $targetNames = @()
  if ($BridgeEnv.ContainsKey("HEADROOM_HYPERV_QWEN_VM_NAMES")) {
    $targetNames = @($BridgeEnv["HEADROOM_HYPERV_QWEN_VM_NAMES"].Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  }
  if ($targetNames.Count -eq 0 -and $HyperVVmName.Trim()) {
    $targetNames = @($HyperVVmName.Trim())
  }
  if ($targetNames.Count -eq 0) { return }

  $sourceHash = (Get-FileHash -LiteralPath $sourceScript -Algorithm SHA256).Hash.ToLowerInvariant()
  $profileVersion = "$sourceHash-$model-$effort"
  $launcherPath = Join-Path $LogDir "apply-hyperv-qwen-profile.cmd"
  $launcher = @"
@echo off
setlocal
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\ProgramData\sub2api\sync-claude-subagent-profile.ps1" -Model "$model" -Effort "$effort" > "C:\ProgramData\sub2api\sync-claude-subagent-profile.log" 2>&1
if errorlevel 1 exit /b %errorlevel%
del "%~f0"
"@
  Write-Utf8NoBom -Path $launcherPath -Content ($launcher.Trim() + [Environment]::NewLine)

  foreach ($vmName in $targetNames) {
    $safeName = $vmName -replace '[^A-Za-z0-9._-]', '_'
    $markerPath = Join-Path $LogDir "hyperv-qwen-$safeName-$($profileVersion.Substring(0, 16)).staged"
    if (Test-Path -LiteralPath $markerPath) { continue }
    try {
      $vm = Get-VM -Name $vmName -ErrorAction Stop
      if ([string]$vm.State -ne "Running") {
        throw "VM is not running (state=$($vm.State))"
      }
      $guestService = Get-VMIntegrationService -VMName $vmName -Name "Guest Service Interface" -ErrorAction Stop
      if (-not $guestService.Enabled) {
        Enable-VMIntegrationService -VMName $vmName -Name "Guest Service Interface" -ErrorAction Stop
        Start-Sleep -Milliseconds 500
      }
      Copy-VMFile -VMName $vmName -FileSource Host -SourcePath $sourceScript -DestinationPath "C:\ProgramData\sub2api\sync-claude-subagent-profile.ps1" -CreateFullPath -Force -ErrorAction Stop
      Copy-VMFile -VMName $vmName -FileSource Host -SourcePath $launcherPath -DestinationPath "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\apply-sub2api-qwen-profile.cmd" -CreateFullPath -Force -ErrorAction Stop
      Write-Utf8NoBom -Path $markerPath -Content (([ordered]@{
        vm = $vmName
        model = $model
        effort = $effort
        profile_version = $profileVersion
        staged_at = (Get-Date).ToUniversalTime().ToString("o")
      } | ConvertTo-Json -Compress) + [Environment]::NewLine)
      Write-SelfHealEvent -Event "hyperv_subagent_profile_staged" -Data @{ vm = $vmName; model = $model; effort = $effort }
    } catch {
      Write-SelfHealEvent -Event "hyperv_subagent_profile_failed" -Data @{ vm = $vmName; model = $model; effort = $effort; error = $_.Exception.Message }
    }
  }
}

function Resolve-StateRootPath {
  param([string]$ProfileRoot, [hashtable]$EnvMap)

  $stateRoot = "./data"
  if ($EnvMap.ContainsKey("SUB2API_STATE_ROOT") -and $EnvMap["SUB2API_STATE_ROOT"].Trim()) {
    $stateRoot = $EnvMap["SUB2API_STATE_ROOT"].Trim()
  }
  if ([IO.Path]::IsPathRooted($stateRoot)) {
    return $stateRoot
  }
  return Join-Path $ProfileRoot ($stateRoot -replace '^\.[\\/]', '')
}

function Test-CodexAuthFileShape {
  param([string]$Path)

  try {
    $auth = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $access = [string]$auth.tokens.access_token
    $refresh = [string]$auth.tokens.refresh_token
    return ($access.Trim().Length -gt 0 -and $refresh.Trim().Length -gt 0)
  } catch {
    return $false
  }
}

function Sync-CodexAuthFile {
  param([string]$ProfileRoot, [hashtable]$EnvMap)

  $source = $CodexAuthFile
  if (-not $source.Trim()) {
    if (-not $env:USERPROFILE) { return @{ status = "skipped"; reason = "USERPROFILE is empty" } }
    $source = Join-Path $env:USERPROFILE ".codex\auth.json"
  }
  if (-not (Test-Path -LiteralPath $source)) {
    return @{ status = "missing"; source = $source }
  }
  if (-not (Test-CodexAuthFileShape -Path $source)) {
    Write-SelfHealEvent -Event "codex_auth_sync_skipped" -Data @{ reason = "auth file lacks tokens.access_token or tokens.refresh_token"; source = $source }
    return @{ status = "invalid"; source = $source }
  }

  $stateRoot = Resolve-StateRootPath -ProfileRoot $ProfileRoot -EnvMap $EnvMap
  $targetDir = Join-Path $stateRoot "sub2api"
  $target = Join-Path $targetDir "codex-auth.json"
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

  $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
  $targetHash = ""
  if (Test-Path -LiteralPath $target) {
    $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  if ($sourceHash -eq $targetHash) {
    return @{ status = "unchanged"; target = $target }
  }

  Copy-Item -LiteralPath $source -Destination $target -Force
  Write-SelfHealEvent -Event "codex_auth_synced" -Data @{ target = $target; source_mtime_utc = (Get-Item -LiteralPath $source).LastWriteTimeUtc.ToString("o") }
  return @{ status = "synced"; target = $target }
}

function Invoke-HealthProbe {
  param([string]$Url)

  $started = Get-Date
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$Url/health" -TimeoutSec $HealthTimeoutSeconds
    return [ordered]@{
      url = "$Url/health"
      ok = ($response.StatusCode -eq 200)
      status = [int]$response.StatusCode
      elapsed_ms = [Math]::Round(((Get-Date) - $started).TotalMilliseconds)
    }
  } catch {
    return [ordered]@{
      url = "$Url/health"
      ok = $false
      status = $null
      elapsed_ms = [Math]::Round(((Get-Date) - $started).TotalMilliseconds)
      error = $_.Exception.Message
    }
  }
}

function Get-WslIpv4 {
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & wsl.exe -d $Distro -- hostname -I 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return ((($output -join " ").Trim() -split "\s+") | Where-Object { $_ -match "^\d+\.\d+\.\d+\.\d+$" } | Select-Object -First 1)
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
}

function Get-HyperVSwitchIpv4 {
  if (-not $HyperVVmName.Trim()) { return $null }
  $alias = "vEthernet ($HyperVSwitchName)"
  return (Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "169.254.*" } |
    Select-Object -First 1 -ExpandProperty IPAddress)
}

function Get-RequiredRouteState {
  $sameHostCandidates = @("http://127.0.0.1:$HeadroomPort")
  $wslIp = $null
  $sameHost = Invoke-HealthProbe -Url $sameHostCandidates[0]
  if (-not $sameHost.ok) {
    $wslIp = Get-WslIpv4
    if ($wslIp) {
      $sameHostCandidates += "http://${wslIp}:$HeadroomPort"
      $sameHost = Invoke-HealthProbe -Url $sameHostCandidates[-1]
    }
  }

  $bridge = $null
  if ($HyperVVmName.Trim()) {
    $switchIp = Get-HyperVSwitchIpv4
    if ($switchIp) {
      $bridge = Invoke-HealthProbe -Url "http://${switchIp}:$HeadroomPort"
    } else {
      $bridge = [ordered]@{
        url = "hyperv://$HyperVSwitchName"
        ok = $false
        status = $null
        elapsed_ms = 0
        error = "Hyper-V switch IPv4 was not found"
      }
    }
  }

  $bridgeOk = $true
  if ($RequireHyperVBridge) {
    $bridgeOk = ($null -ne $bridge -and $bridge.ok)
  }

  return [ordered]@{
    ok = ($sameHost.ok -and $bridgeOk)
    same_host = $sameHost
    bridge = $bridge
    bridge_required = $RequireHyperVBridge
    wsl_ip = $wslIp
  }
}

function Save-State {
  param(
    [string]$Status,
    [string]$LastEventAt = ""
  )
  if (-not $LastEventAt -and (Test-Path -LiteralPath $StatePath)) {
    try {
      $previousState = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
      $LastEventAt = [string]$previousState.last_event_at
    } catch {
      $LastEventAt = ""
    }
  }
  Write-Utf8NoBom -Path $StatePath -Content (([ordered]@{
    status = $Status
    checked_at = (Get-Date).ToUniversalTime().ToString("o")
    last_event_at = $LastEventAt
  } | ConvertTo-Json -Compress) + [Environment]::NewLine)
}

$Root = Resolve-ProfileDir
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogPath = Join-Path $LogDir "self-heal.jsonl"
$StatePath = Join-Path $LogDir "self-heal-state.json"
$envMap = Read-EnvFile -Path (Join-Path $Root ".env")
$bridgeEnv = Read-EnvFile -Path (Join-Path $Root "hyperv-bridge.env")

if ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_VM_NAME") -and $bridgeEnv["HEADROOM_HYPERV_VM_NAME"].Trim()) {
  $HyperVVmName = $bridgeEnv["HEADROOM_HYPERV_VM_NAME"]
}
if ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_VM_SSH_USER") -and $bridgeEnv["HEADROOM_HYPERV_VM_SSH_USER"].Trim()) {
  $HyperVVmSshUser = $bridgeEnv["HEADROOM_HYPERV_VM_SSH_USER"]
} elseif ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_SSH_USER") -and $bridgeEnv["HEADROOM_HYPERV_SSH_USER"].Trim()) {
  $HyperVVmSshUser = $bridgeEnv["HEADROOM_HYPERV_SSH_USER"]
}
if ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_VM_SSH_KEY") -and $bridgeEnv["HEADROOM_HYPERV_VM_SSH_KEY"].Trim()) {
  $HyperVVmSshKey = $bridgeEnv["HEADROOM_HYPERV_VM_SSH_KEY"]
} elseif ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_SSH_KEY") -and $bridgeEnv["HEADROOM_HYPERV_SSH_KEY"].Trim()) {
  $HyperVVmSshKey = $bridgeEnv["HEADROOM_HYPERV_SSH_KEY"]
}
if ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_SWITCH_NAME") -and $bridgeEnv["HEADROOM_HYPERV_SWITCH_NAME"].Trim()) {
  $HyperVSwitchName = $bridgeEnv["HEADROOM_HYPERV_SWITCH_NAME"]
}
if ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_REMOTE_CONFIG_MODE") -and $bridgeEnv["HEADROOM_HYPERV_REMOTE_CONFIG_MODE"].Trim()) {
  $HyperVRemoteConfigMode = $bridgeEnv["HEADROOM_HYPERV_REMOTE_CONFIG_MODE"]
}
if (-not $RequireHyperVBridge -and $bridgeEnv.ContainsKey("HEADROOM_HYPERV_REQUIRE_BRIDGE")) {
  $RequireHyperVBridge = $bridgeEnv["HEADROOM_HYPERV_REQUIRE_BRIDGE"] -match "^(1|true|yes|on)$"
}

$hyperVConfigured = $HyperVVmName.Trim().Length -gt 0 -or
  $bridgeEnv.ContainsKey("HEADROOM_HYPERV_QWEN_VM_NAMES") -or
  ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_STAGE_QWEN_PROFILE") -and $bridgeEnv["HEADROOM_HYPERV_STAGE_QWEN_PROFILE"] -match "^(1|true|yes|on)$")
if ($hyperVConfigured) {
  Write-HyperVInventorySnapshot
  Sync-HyperVGuestSubagentProfiles -BridgeEnv $bridgeEnv
}

$startScript = Join-Path $ScriptDir "start-sub2api-proxy-stack.ps1"
if (-not (Test-Path -LiteralPath $startScript)) {
  throw "Start script not found: $startScript"
}

$mutex = [Threading.Mutex]::new($false, "Local\sub2api-codex-proxy-stack-self-heal")
$mutexHeld = $false

try {
  $mutexHeld = $mutex.WaitOne([TimeSpan]::FromSeconds(1))
  if (-not $mutexHeld) {
    Write-SelfHealEvent -Event "check_skipped" -Data @{ reason = "another watchdog instance is active" }
    exit 0
  }

  $codexAuthSync = Sync-CodexAuthFile -ProfileRoot $Root -EnvMap $envMap
  $before = Get-RequiredRouteState
  if ($before.ok) {
    $writeHeartbeat = $true
    $lastEventAt = ""
    if (Test-Path -LiteralPath $StatePath) {
      try {
        $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
        $lastEventAt = [string]$state.last_event_at
        $lastEvent = if ($lastEventAt) { [DateTime]::Parse($lastEventAt).ToUniversalTime() } else { [DateTime]::MinValue }
        $writeHeartbeat = ($state.status -ne "healthy" -or ((Get-Date).ToUniversalTime() - $lastEvent).TotalMinutes -ge $HealthyHeartbeatMinutes)
      } catch {
        $writeHeartbeat = $true
      }
    }
    if ($writeHeartbeat) {
      Write-SelfHealEvent -Event "healthy" -Data @{ routes = $before; codex_auth = $codexAuthSync }
      $lastEventAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    $providerRoute = Invoke-ProviderRouteReconcile -ProfileRoot $Root
    Save-State -Status "healthy" -LastEventAt $lastEventAt
    [pscustomobject]@{ status = "healthy"; recovered = $false; routes = $before; codex_auth = $codexAuthSync; provider_route = $providerRoute } | ConvertTo-Json -Compress -Depth 8
    exit 0
  }

  Save-State -Status "recovering" -LastEventAt (Get-Date).ToUniversalTime().ToString("o")
  Write-SelfHealEvent -Event "recovery_started" -Data @{ routes = $before; codex_auth = $codexAuthSync }

  $startParams = @{
    ProfileDir = $Root
    ProjectName = $ProjectName
    Distro = $Distro
    HeadroomPort = $HeadroomPort
    Sub2apiPort = $Sub2apiPort
    HyperVVmName = $HyperVVmName
    HyperVVmSshUser = $HyperVVmSshUser
    HyperVVmSshKey = $HyperVVmSshKey
    HyperVSwitchName = $HyperVSwitchName
    HyperVRemoteConfigMode = $HyperVRemoteConfigMode
  }
  if ($RepoRoot.Trim()) { $startParams.RepoRoot = $RepoRoot }

  & $startScript @startParams

  $deadline = (Get-Date).AddSeconds($RecoveryWaitSeconds)
  do {
    $after = Get-RequiredRouteState
    if ($after.ok) {
      $providerRoute = Invoke-ProviderRouteReconcile -ProfileRoot $Root
      Save-State -Status "healthy" -LastEventAt (Get-Date).ToUniversalTime().ToString("o")
      Write-SelfHealEvent -Event "recovered" -Data @{ routes_before = $before; routes_after = $after }
      [pscustomobject]@{ status = "healthy"; recovered = $true; routes = $after; provider_route = $providerRoute } | ConvertTo-Json -Compress -Depth 8
      exit 0
    }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)

  throw "Proxy routes did not recover within $RecoveryWaitSeconds seconds"
} catch {
  Save-State -Status "failed" -LastEventAt (Get-Date).ToUniversalTime().ToString("o")
  Write-SelfHealEvent -Event "recovery_failed" -Data @{ error = $_.Exception.Message }
  Write-Error $_
  exit 1
} finally {
  if ($mutexHeld) { $mutex.ReleaseMutex() | Out-Null }
  $mutex.Dispose()
}

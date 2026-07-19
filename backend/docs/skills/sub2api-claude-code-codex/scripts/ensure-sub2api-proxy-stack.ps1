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
  [string]$HyperVVmName = "",
  [string]$HyperVVmSshUser = "",
  [string]$HyperVVmSshKey = "",
  [string]$HyperVSwitchName = "Default Switch"
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

  return [ordered]@{
    ok = ($sameHost.ok -and ($null -eq $bridge -or $bridge.ok))
    same_host = $sameHost
    bridge = $bridge
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
$bridgeEnv = Read-EnvFile -Path (Join-Path $Root "hyperv-bridge.env")

if (-not $HyperVVmName.Trim() -and $bridgeEnv.ContainsKey("HEADROOM_HYPERV_VM_NAME")) {
  $HyperVVmName = $bridgeEnv["HEADROOM_HYPERV_VM_NAME"]
}
if (-not $HyperVVmSshUser.Trim() -and $bridgeEnv.ContainsKey("HEADROOM_HYPERV_SSH_USER")) {
  $HyperVVmSshUser = $bridgeEnv["HEADROOM_HYPERV_SSH_USER"]
}
if (-not $HyperVVmSshKey.Trim() -and $bridgeEnv.ContainsKey("HEADROOM_HYPERV_SSH_KEY")) {
  $HyperVVmSshKey = $bridgeEnv["HEADROOM_HYPERV_SSH_KEY"]
}
if ($HyperVSwitchName -eq "Default Switch" -and $bridgeEnv.ContainsKey("HEADROOM_HYPERV_SWITCH_NAME")) {
  $HyperVSwitchName = $bridgeEnv["HEADROOM_HYPERV_SWITCH_NAME"]
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
      Write-SelfHealEvent -Event "healthy" -Data @{ routes = $before }
      $lastEventAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    Save-State -Status "healthy" -LastEventAt $lastEventAt
    [pscustomobject]@{ status = "healthy"; recovered = $false; routes = $before } | ConvertTo-Json -Compress -Depth 8
    exit 0
  }

  Save-State -Status "recovering" -LastEventAt (Get-Date).ToUniversalTime().ToString("o")
  Write-SelfHealEvent -Event "recovery_started" -Data @{ routes = $before }

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
  }
  if ($RepoRoot.Trim()) { $startParams.RepoRoot = $RepoRoot }

  & $startScript @startParams

  $deadline = (Get-Date).AddSeconds($RecoveryWaitSeconds)
  do {
    $after = Get-RequiredRouteState
    if ($after.ok) {
      Save-State -Status "healthy" -LastEventAt (Get-Date).ToUniversalTime().ToString("o")
      Write-SelfHealEvent -Event "recovered" -Data @{ routes_before = $before; routes_after = $after }
      [pscustomobject]@{ status = "healthy"; recovered = $true; routes = $after } | ConvertTo-Json -Compress -Depth 8
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

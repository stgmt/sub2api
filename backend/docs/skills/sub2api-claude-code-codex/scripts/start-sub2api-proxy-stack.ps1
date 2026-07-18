param(
  [string]$RepoRoot = "",
  [string]$ProfileDir = "",
  [string]$ProjectName = "sub2api-codex",
  [string]$Distro = "Ubuntu-24.04",
  [int]$HeadroomPort = 8787,
  [int]$Sub2apiPort = 18081,
  [int]$DockerWaitSeconds = 180,
  [int]$HealthWaitSeconds = 90,
  [int]$WslRetrySeconds = 120,
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

  $starts = @()
  if ($ScriptDir) { $starts += $ScriptDir }
  $starts += (Get-Location).ProviderPath

  foreach ($start in $starts) {
    $dir = (Resolve-Path -LiteralPath $start).Path
    while ($dir) {
      if (Test-Path -LiteralPath (Join-Path $dir "docker-compose.yml")) {
        return $dir
      }
      $deployProfile = Join-Path $dir "deploy\claude-code-codex-headroom"
      if (Test-Path -LiteralPath (Join-Path $deployProfile "docker-compose.yml")) {
        return $deployProfile
      }
      $parent = Split-Path -Parent $dir
      if (-not $parent -or $parent -eq $dir) { break }
      $dir = $parent
    }
  }

  throw "Could not find deploy\claude-code-codex-headroom\docker-compose.yml. Pass -RepoRoot or -ProfileDir."
}

$Root = Resolve-ProfileDir
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogPath = Join-Path $LogDir "autostart.log"
$MutexName = "Local\sub2api-codex-proxy-stack-autostart"
$Mutex = [System.Threading.Mutex]::new($false, $MutexName)
$MutexHeld = $false

try {
  $MutexHeld = $Mutex.WaitOne([TimeSpan]::FromSeconds(1))
  if (-not $MutexHeld) {
    Add-Content -Path $LogPath -Value ("[{0}] another autostart instance is already running; exiting" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
    exit 0
  }
} catch {
  Add-Content -Path $LogPath -Value ("[{0}] mutex acquisition failed: {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $_.Exception.Message)
}

function Write-StackLog {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
  Add-Content -Path $LogPath -Value $line
}

function Write-Utf8NoBom {
  param(
    [string]$Path,
    [string]$Content
  )
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

$script:LastWslAttachSelfHealAt = [DateTime]::MinValue

function Invoke-LoggedNative {
  param(
    [string]$FilePath,
    [string[]]$Arguments
  )

  try {
    $output = & $FilePath @Arguments 2>&1
    $exit = $LASTEXITCODE
    if ($output) {
      Add-Content -Path $LogPath -Value ($output -join [Environment]::NewLine)
    }
    Write-StackLog "$FilePath $($Arguments -join ' ') exited $exit"
  } catch {
    Write-StackLog "$FilePath $($Arguments -join ' ') failed: $($_.Exception.Message)"
  }
}

function Repair-WslAttachBusy {
  param([int]$Attempt)

  $now = Get-Date
  if (($now - $script:LastWslAttachSelfHealAt).TotalSeconds -lt 20) {
    return
  }
  $script:LastWslAttachSelfHealAt = $now

  Write-StackLog "attempting WSL attach self-heal on attempt $Attempt"
  Invoke-LoggedNative -FilePath "wsl.exe" -Arguments @("--terminate", $Distro)
  Invoke-LoggedNative -FilePath "wsl.exe" -Arguments @("--shutdown")

  $wslRoot = Join-Path $env:LOCALAPPDATA "wsl"
  if (-not (Test-Path -LiteralPath $wslRoot)) {
    Write-StackLog "WSL LocalAppData root not found: $wslRoot"
    return
  }

  $diskImages = Get-ChildItem -LiteralPath $wslRoot -Filter "ext4.vhdx" -Recurse -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending
  if (-not $diskImages) {
    Write-StackLog "no WSL ext4.vhdx images found under $wslRoot"
    return
  }

  foreach ($diskImage in $diskImages) {
    try {
      $image = Get-DiskImage -ImagePath $diskImage.FullName -ErrorAction Stop
      Write-StackLog "WSL disk image candidate: $($diskImage.FullName) attached=$($image.Attached)"
      if ($image.Attached) {
        Dismount-DiskImage -ImagePath $diskImage.FullName -ErrorAction Stop
        Write-StackLog "dismounted stale WSL disk image: $($diskImage.FullName)"
      }
    } catch {
      Write-StackLog "could not inspect/dismount WSL disk image $($diskImage.FullName): $($_.Exception.Message)"
    }
  }
}

function Invoke-WslBash {
  param([string]$Command)
  Write-StackLog "wsl: $Command"
  $deadline = (Get-Date).AddSeconds($WslRetrySeconds)
  $attempt = 0
  do {
    $attempt++
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $output = & wsl.exe -d $Distro -- bash -lc $Command 2>&1
      $exit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }
    $text = ""
    if ($output) {
      # Scheduled tasks can receive WSL service errors as UTF-16 text with
      # embedded NULs. Normalize before matching or the retry classifier misses
      # errors such as Wsl/Service/0x8007274c.
      $text = (($output -join [Environment]::NewLine) -replace "`0", "")
      Add-Content -Path $LogPath -Value $text
    }
    if ($exit -eq 0) {
      return $text
    }
    if ($text -match "ERROR_SHARING_VIOLATION|being used by another process|Failed to attach disk|MountDisk") {
      Write-StackLog "WSL attach busy on attempt $attempt; retrying"
      Repair-WslAttachBusy -Attempt $attempt
      Start-Sleep -Seconds ([Math]::Min(10, 2 * $attempt))
      continue
    }
    if ($text -match "Wsl/Service|0x8007274c|connection attempt failed|connected host has failed to respond|The service cannot be started") {
      Write-StackLog "WSL service transient on attempt $attempt; retrying"
      Start-Sleep -Seconds ([Math]::Min(10, 2 * $attempt))
      continue
    }
    throw "WSL command failed with exit code ${exit}: $Command"
  } while ((Get-Date) -lt $deadline)

  throw "WSL stayed locked for $WslRetrySeconds seconds while running: $Command"
}

function Set-ClaudeBaseUrlFromWsl {
  $ipLine = Invoke-WslBash "hostname -I 2>/dev/null || true"
  $wslIp = ($ipLine -split "\s+" | Where-Object { $_ -match "^\d+\.\d+\.\d+\.\d+$" } | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($wslIp)) {
    Write-StackLog "could not determine WSL IP; leaving ANTHROPIC_BASE_URL unchanged"
    return $null
  }

  $baseUrl = "http://${wslIp}:$HeadroomPort"
  [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $baseUrl, "User")

  $settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
  if (Test-Path -LiteralPath $settingsPath) {
    try {
      $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
      if (-not $settings.PSObject.Properties["env"]) {
        $settings | Add-Member -MemberType NoteProperty -Name env -Value ([pscustomobject]@{})
      }
      if ($settings.env.PSObject.Properties["ANTHROPIC_BASE_URL"]) {
        $settings.env.ANTHROPIC_BASE_URL = $baseUrl
      } else {
        $settings.env | Add-Member -MemberType NoteProperty -Name ANTHROPIC_BASE_URL -Value $baseUrl
      }
      Write-Utf8NoBom -Path $settingsPath -Content (($settings | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    } catch {
      Write-StackLog "could not update Claude settings ANTHROPIC_BASE_URL: $($_.Exception.Message)"
    }
  }

  Write-StackLog "ANTHROPIC_BASE_URL=$baseUrl"
  return $baseUrl
}

function ConvertTo-WslPath {
  param([string]$Path)
  $full = [System.IO.Path]::GetFullPath($Path)
  if ($full -match '^([A-Za-z]):\\(.*)$') {
    $drive = $Matches[1].ToLowerInvariant()
    $rest = $Matches[2] -replace '\\', '/'
    return "/mnt/$drive/$rest"
  }
  return $full -replace '\\', '/'
}

function Get-DotEnvValue {
  param(
    [string]$Path,
    [string]$Name,
    [string]$Fallback
  )

  if (Test-Path -LiteralPath $Path) {
    foreach ($line in Get-Content -LiteralPath $Path) {
      if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
      $key, $value = $line -split '=', 2
      if ($key.Trim() -eq $Name) { return $value.Trim() }
    }
  }
  return $Fallback
}

function Get-HyperVVmIpv4 {
  param(
    [string]$VmName,
    [string]$SwitchIp
  )

  try {
    $adapters = @(Get-VMNetworkAdapter -VMName $VmName -ErrorAction Stop)
  } catch {
    Write-StackLog "could not inspect Hyper-V VM '$VmName': $($_.Exception.Message)"
    return $null
  }

  $ipv4 = @($adapters | ForEach-Object { $_.IPAddresses } |
    Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notmatch '^169\.254\.' })
  if ($ipv4.Count -gt 0) {
    $switchPrefix = ($SwitchIp -split '\.')[0..2] -join '.'
    $samePrefix = @($ipv4 | Where-Object { $_ -like "$switchPrefix.*" })
    if ($samePrefix.Count -gt 0) { return $samePrefix[0] }
    return $ipv4[0]
  }

  foreach ($adapter in $adapters) {
    $mac = ([string]$adapter.MacAddress -replace '(.{2})(?!$)', '$1-').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($mac)) { continue }
    $neighbor = Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.LinkLayerAddress -eq $mac -and $_.IPAddress -notmatch '^169\.254\.' } |
      Select-Object -First 1
    if ($neighbor) { return [string]$neighbor.IPAddress }
  }

  Write-StackLog "could not determine IPv4 address for Hyper-V VM '$VmName'"
  return $null
}

function Get-V4ToV4PortProxyEntries {
  $output = & netsh.exe interface portproxy show v4tov4 2>&1
  foreach ($line in $output) {
    if ([string]$line -match '^\s*(\d+\.\d+\.\d+\.\d+)\s+(\d+)\s+(\d+\.\d+\.\d+\.\d+)\s+(\d+)\s*$') {
      [pscustomobject]@{
        ListenAddress = $Matches[1]
        ListenPort = [int]$Matches[2]
        ConnectAddress = $Matches[3]
        ConnectPort = [int]$Matches[4]
      }
    }
  }
}

function Invoke-CheckedNative {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$Description
  )

  $output = & $FilePath @Arguments 2>&1
  $exit = $LASTEXITCODE
  if ($output) { Add-Content -Path $LogPath -Value ($output -join [Environment]::NewLine) }
  if ($exit -ne 0) { throw "$Description failed with exit code $exit" }
}

function Sync-HyperVHeadroomBridge {
  param([string]$WslIp)

  if ([string]::IsNullOrWhiteSpace($HyperVVmName)) { return $null }

  $switchAlias = "vEthernet ($HyperVSwitchName)"
  $switchIp = Get-NetIPAddress -InterfaceAlias $switchAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch '^169\.254\.' } |
    Select-Object -ExpandProperty IPAddress -First 1
  if ([string]::IsNullOrWhiteSpace($switchIp)) {
    throw "could not determine IPv4 for Hyper-V switch '$HyperVSwitchName'"
  }

  $vmIp = Get-HyperVVmIpv4 -VmName $HyperVVmName -SwitchIp $switchIp
  if ([string]::IsNullOrWhiteSpace($vmIp)) {
    throw "could not determine IPv4 for Hyper-V VM '$HyperVVmName'"
  }

  foreach ($entry in @(Get-V4ToV4PortProxyEntries)) {
    if ($entry.ListenPort -ne $HeadroomPort -or $entry.ConnectPort -ne $HeadroomPort) { continue }
    Invoke-CheckedNative -FilePath "netsh.exe" -Arguments @(
      "interface", "portproxy", "delete", "v4tov4",
      "listenaddress=$($entry.ListenAddress)", "listenport=$HeadroomPort"
    ) -Description "remove stale Headroom portproxy $($entry.ListenAddress):$HeadroomPort"
  }

  Invoke-CheckedNative -FilePath "netsh.exe" -Arguments @(
    "interface", "portproxy", "add", "v4tov4",
    "listenaddress=$switchIp", "listenport=$HeadroomPort",
    "connectaddress=$WslIp", "connectport=$HeadroomPort"
  ) -Description "create Hyper-V to WSL Headroom portproxy"

  $firewallRuleName = "Headroom-HyperV-VM-$HeadroomPort"
  Get-NetFirewallRule -DisplayName $firewallRuleName -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
  New-NetFirewallRule -DisplayName $firewallRuleName -Direction Inbound -Action Allow `
    -Protocol TCP -LocalAddress $switchIp -LocalPort $HeadroomPort -RemoteAddress $vmIp `
    -Profile Any | Out-Null

  $vmBaseUrl = "http://${switchIp}:$HeadroomPort"
  Write-StackLog "Hyper-V Headroom bridge: vm=$HyperVVmName vmIp=$vmIp switchIp=$switchIp wslIp=$WslIp"

  if ([string]::IsNullOrWhiteSpace($HyperVVmSshUser) -or [string]::IsNullOrWhiteSpace($HyperVVmSshKey)) {
    throw "Hyper-V SSH user/key are required when HEADROOM_HYPERV_VM_NAME is configured"
  }
  if (-not (Test-Path -LiteralPath $HyperVVmSshKey)) {
    throw "Hyper-V SSH key not found: $HyperVVmSshKey"
  }

  $remotePython = @'
import json
import os
import pathlib
import sys

base_url = sys.argv[1]
path = pathlib.Path.home() / ".claude" / "settings.json"
data = json.loads(path.read_text(encoding="utf-8"))
data.setdefault("env", {})["ANTHROPIC_BASE_URL"] = base_url
tmp = path.with_name(path.name + ".tmp")
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
os.chmod(tmp, path.stat().st_mode)
os.replace(tmp, path)
print("UPDATED_BASE_URL=" + base_url)
'@
  $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remotePython))
  $remote = "$HyperVVmSshUser@$vmIp"
  $sshCommon = @(
    "-i", $HyperVVmSshKey,
    "-o", "BatchMode=yes",
    "-o", "LogLevel=ERROR",
    "-o", "StrictHostKeyChecking=no",
    "-o", "UserKnownHostsFile=NUL",
    "-o", "ConnectTimeout=8"
  )
  $updateCommand = "printf '%s' '$payload' | base64 -d | python3 - '$vmBaseUrl'"
  Invoke-CheckedNative -FilePath "ssh.exe" -Arguments ($sshCommon + @($remote, $updateCommand)) `
    -Description "update Claude base URL in Hyper-V VM"
  $probeCommand = "curl -fsS --max-time 8 '$vmBaseUrl/health' >/dev/null && echo HYPERV_HEADROOM_HEALTH_OK"
  Invoke-CheckedNative -FilePath "ssh.exe" -Arguments ($sshCommon + @($remote, $probeCommand)) `
    -Description "probe Headroom from Hyper-V VM"
  Write-StackLog "Hyper-V VM Claude ANTHROPIC_BASE_URL=$vmBaseUrl"
  return $vmBaseUrl
}

try {
  Write-StackLog "starting sub2api-codex proxy stack"

  $deadline = (Get-Date).AddSeconds($DockerWaitSeconds)
  do {
    try {
      Invoke-WslBash "docker info >/dev/null 2>&1"
      break
    } catch {
      Write-StackLog "docker pending: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds 5
  } while ((Get-Date) -lt $deadline)

  if ((Get-Date) -ge $deadline) {
    throw "Docker did not become ready within $DockerWaitSeconds seconds"
  }

  $WslRoot = ConvertTo-WslPath $Root
  $envPath = Join-Path $Root ".env"
  $hyperVEnvPath = Join-Path $Root "hyperv-bridge.env"
  $StateRoot = Get-DotEnvValue -Path $envPath -Name "SUB2API_STATE_ROOT" -Fallback "./data"
  $HeadroomAccelerator = Get-DotEnvValue -Path $envPath -Name "HEADROOM_ACCELERATOR" -Fallback "cpu"
  if ([string]::IsNullOrWhiteSpace($HyperVVmName)) {
    $HyperVVmName = Get-DotEnvValue -Path $hyperVEnvPath -Name "HEADROOM_HYPERV_VM_NAME" -Fallback ""
  }
  if ([string]::IsNullOrWhiteSpace($HyperVVmSshUser)) {
    $HyperVVmSshUser = Get-DotEnvValue -Path $hyperVEnvPath -Name "HEADROOM_HYPERV_VM_SSH_USER" -Fallback ""
  }
  if ([string]::IsNullOrWhiteSpace($HyperVVmSshKey)) {
    $HyperVVmSshKey = Get-DotEnvValue -Path $hyperVEnvPath -Name "HEADROOM_HYPERV_VM_SSH_KEY" -Fallback ""
  }
  $HyperVSwitchName = Get-DotEnvValue -Path $hyperVEnvPath -Name "HEADROOM_HYPERV_SWITCH_NAME" -Fallback $HyperVSwitchName
  $ComposeFiles = "-f docker-compose.yml"
  if ($HeadroomAccelerator -eq "cuda") {
    $gpuComposePath = Join-Path $Root "docker-compose.gpu.yml"
    if (-not (Test-Path -LiteralPath $gpuComposePath)) {
      throw "CUDA was selected but the GPU compose overlay is missing: $gpuComposePath"
    }
    $ComposeFiles += " -f docker-compose.gpu.yml"
  }
  $WslStateRoot = if ($StateRoot -match '^/') {
    $StateRoot
  } else {
    $relativeStateRoot = $StateRoot -replace '^\./', ''
    "$WslRoot/$relativeStateRoot"
  }

  Invoke-WslBash "mkdir -p '$WslStateRoot/headroom' '$WslStateRoot/headroom-cache' '$WslStateRoot/headroom-huggingface' '$WslStateRoot/sub2api' '$WslStateRoot/postgres' '$WslStateRoot/redis'"
  Invoke-WslBash "cd '$WslRoot' && docker compose --env-file .env -p '$ProjectName' $ComposeFiles up -d --remove-orphans"
  Invoke-WslBash "cd '$WslRoot' && docker compose --env-file .env -p '$ProjectName' $ComposeFiles ps"

  $baseUrl = Set-ClaudeBaseUrlFromWsl
  $wslIp = if ($baseUrl) { ([Uri]$baseUrl).Host } else { $null }
  if ($wslIp) {
    try {
      Sync-HyperVHeadroomBridge -WslIp $wslIp | Out-Null
    } catch {
      Write-StackLog "Hyper-V Headroom bridge refresh failed: $($_.Exception.Message)"
    }
  }
  $healthUrls = @("http://127.0.0.1:$HeadroomPort")
  if ($baseUrl) {
    $healthUrls += $baseUrl
  }

  $healthDeadline = (Get-Date).AddSeconds($HealthWaitSeconds)
  do {
    foreach ($headroomUrl in ($healthUrls | Select-Object -Unique)) {
      try {
        $sub2apiUrl = $headroomUrl -replace ":$HeadroomPort", ":$Sub2apiPort"
        $headroom = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "$headroomUrl/health"
        $sub2api = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "$sub2apiUrl/health"
        if ($headroom.StatusCode -eq 200 -and $sub2api.StatusCode -eq 200) {
          Write-StackLog "health ok: headroom=$headroomUrl sub2api=$sub2apiUrl"
          exit 0
        }
      } catch {
        Write-StackLog "health pending via ${headroomUrl}: $($_.Exception.Message)"
      }
    }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $healthDeadline)

  throw "Proxy stack did not pass health checks within $HealthWaitSeconds seconds"
} finally {
  if ($MutexHeld) {
    $Mutex.ReleaseMutex() | Out-Null
  }
  $Mutex.Dispose()
}

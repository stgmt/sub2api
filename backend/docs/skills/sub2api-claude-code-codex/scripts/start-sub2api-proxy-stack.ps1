param(
  [string]$RepoRoot = "",
  [string]$ProfileDir = "",
  [string]$ProjectName = "sub2api-codex",
  [string]$Distro = "Ubuntu-24.04",
  [int]$HeadroomPort = 8787,
  [int]$Sub2apiPort = 18081,
  [int]$DockerWaitSeconds = 180,
  [int]$HealthWaitSeconds = 90,
  [int]$WslRetrySeconds = 120
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
      $settings | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
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
  $StateRoot = Get-DotEnvValue -Path $envPath -Name "SUB2API_STATE_ROOT" -Fallback "./data"
  $HeadroomAccelerator = Get-DotEnvValue -Path $envPath -Name "HEADROOM_ACCELERATOR" -Fallback "cpu"
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

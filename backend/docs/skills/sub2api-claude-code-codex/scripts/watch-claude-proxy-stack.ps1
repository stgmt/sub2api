param(
  [string]$BaseUrl,
  [string]$Sub2apiBaseUrl,
  [string]$Distro = "Ubuntu-24.04",
  [string]$LogPath = (Join-Path $HOME ".codex\logs\claude-proxy-watchdog.jsonl"),
  [int]$TimeoutSec = 8,
  [int]$IntervalSec = 30,
  [int]$MaxIterations = 1,
  [switch]$RestartOnFailure,
  [switch]$RequireCuda,
  [switch]$Watch
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

function Get-ClaudeSettingsEnv {
  $settingsPath = Join-Path $HOME ".claude\settings.json"
  if (-not (Test-Path -LiteralPath $settingsPath)) { return @{} }
  try {
    $json = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    if ($json.env) { return $json.env }
  } catch {
    return @{}
  }
  return @{}
}

function Normalize-Url([string]$Url, [string]$Fallback) {
  if ($Url -and $Url.Trim()) { return $Url.Trim().TrimEnd("/") }
  return $Fallback
}

function Convert-ToSub2apiUrl([string]$Url) {
  try {
    $uri = [Uri]$Url
    return "$($uri.Scheme)://$($uri.Host):18081"
  } catch {
    return "http://127.0.0.1:18081"
  }
}

function Invoke-HttpProbe([string]$Label, [string]$Url, [int]$Timeout) {
  $started = Get-Date
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$Url/health" -TimeoutSec $Timeout
    $elapsed = [Math]::Round(((Get-Date) - $started).TotalMilliseconds)
    $body = [string]$response.Content
    return [ordered]@{
      label = $Label
      url = "$Url/health"
      ok = $true
      status = [int]$response.StatusCode
      elapsed_ms = $elapsed
      body = $body.Substring(0, [Math]::Min(800, $body.Length))
    }
  } catch {
    $elapsed = [Math]::Round(((Get-Date) - $started).TotalMilliseconds)
    return [ordered]@{
      label = $Label
      url = "$Url/health"
      ok = $false
      status = $null
      elapsed_ms = $elapsed
      error = $_.Exception.Message
    }
  }
}

function Invoke-Docker {
  param([Parameter(Mandatory = $true)][string[]]$Args)
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
      $output = (& docker @Args 2>&1) -join "`n"
      $exit = $LASTEXITCODE
      if ($exit -eq 0) { return $output }
    }
    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
      $output = (& wsl.exe -d $Distro -- docker @Args 2>&1) -join "`n"
      $exit = $LASTEXITCODE
      if ($exit -eq 0) { return $output }
      throw "WSL Docker command failed with exit code $exit`: $output"
    }
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  throw "No working Docker CLI was found on Windows or in WSL distro $Distro"
}

function Get-ContainerHealth([string]$Container) {
  try {
    $raw = Invoke-Docker -Args @("inspect", "--format", "{{json .State.Health}}", $Container)
    $health = $raw | ConvertFrom-Json
    $last = $null
    if ($health.Log -and $health.Log.Count -gt 0) { $last = $health.Log[-1] }
    return [ordered]@{
      container = $Container
      ok = ($health.Status -eq "healthy")
      status = $health.Status
      failing_streak = $health.FailingStreak
      last_start = $last.Start
      last_end = $last.End
      last_exit_code = $last.ExitCode
    }
  } catch {
    return [ordered]@{
      container = $Container
      ok = $false
      status = "unknown"
      error = $_.Exception.Message
    }
  }
}

function Get-HeadroomGpuRuntime {
  try {
    $deviceRequests = Invoke-Docker -Args @("inspect", "--format", "{{json .HostConfig.DeviceRequests}}", "headroom-sub2api")
    $probe = Invoke-Docker -Args @(
      "exec",
      "headroom-sub2api",
      "python",
      "-c",
      "import torch; from headroom.transforms.kompress_compressor import KompressCompressor; c=KompressCompressor(); b=c.preload(allow_download=False); print('CUDA_OK', torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'none', b)"
    )
    return [ordered]@{
      ok = ($deviceRequests -notin @("[]", "null", "") -and $probe -match "CUDA_OK True .+ pytorch")
      device_requests = $deviceRequests
      probe = $probe
    }
  } catch {
    return [ordered]@{
      ok = $false
      device_requests = $null
      error = $_.Exception.Message
    }
  }
}

function Restart-Container([string]$Container) {
  try {
    $out = Invoke-Docker -Args @("restart", $Container)
    return [ordered]@{ container = $Container; ok = $true; output = $out }
  } catch {
    return [ordered]@{ container = $Container; ok = $false; error = $_.Exception.Message }
  }
}

function Write-WatchdogLog([object]$Row, [string]$Path) {
  $dir = Split-Path -Parent $Path
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Add-Content -LiteralPath $Path -Value (($Row | ConvertTo-Json -Depth 10 -Compress))
}

function Invoke-WatchdogOnce {
  $settingsEnv = Get-ClaudeSettingsEnv
  $effectiveBase = Normalize-Url $BaseUrl (Normalize-Url ([string]$settingsEnv.ANTHROPIC_BASE_URL) (Normalize-Url ([Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User")) "http://127.0.0.1:8787"))
  $effectiveSub2api = Normalize-Url $Sub2apiBaseUrl (Convert-ToSub2apiUrl $effectiveBase)

  $baseProbe = Invoke-HttpProbe "claude_base_headroom" $effectiveBase $TimeoutSec
  $sub2apiProbe = Invoke-HttpProbe "direct_sub2api_same_host" $effectiveSub2api $TimeoutSec
  $localhostHeadroomProbe = Invoke-HttpProbe "localhost_headroom_diagnostic" "http://127.0.0.1:8787" $TimeoutSec
  $localhostSub2apiProbe = Invoke-HttpProbe "localhost_sub2api_diagnostic" "http://127.0.0.1:18081" $TimeoutSec
  $headroomHealth = Get-ContainerHealth "headroom-sub2api"
  $sub2apiHealth = Get-ContainerHealth "sub2api-codex"
  $gpuRuntime = Get-HeadroomGpuRuntime

  $warnings = @()
  $critical = @()

  if (-not $baseProbe.ok) { $critical += "Claude effective Headroom base URL failed: $($baseProbe.url)" }
  if (-not $sub2apiProbe.ok -and -not $localhostSub2apiProbe.ok) { $critical += "sub2api health failed on same-host and localhost routes" }
  if (-not $headroomHealth.ok) { $critical += "headroom-sub2api Docker health is $($headroomHealth.status)" }
  if (-not $sub2apiHealth.ok) { $critical += "sub2api-codex Docker health is $($sub2apiHealth.status)" }
  if ($RequireCuda -and -not $gpuRuntime.ok) { $critical += "Headroom CUDA runtime is unavailable or Kompress is not using the pytorch backend" }
  if ($baseProbe.ok -and -not $localhostHeadroomProbe.ok) {
    $warnings += "Windows localhost:8787 is not usable for Headroom, but Claude effective WSL/IP route is healthy. Do not switch Claude Code back to 127.0.0.1:8787 on this host."
  }

  $actions = @()
  if ($RestartOnFailure -and $critical.Count -gt 0) {
    if (-not $headroomHealth.ok -or -not $baseProbe.ok) { $actions += Restart-Container "headroom-sub2api" }
    if (-not $sub2apiHealth.ok -or (-not $sub2apiProbe.ok -and -not $localhostSub2apiProbe.ok)) { $actions += Restart-Container "sub2api-codex" }
  }

  $row = [ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString("o")
    ok = ($critical.Count -eq 0)
    base_url = $effectiveBase
    sub2api_url = $effectiveSub2api
    probes = @($baseProbe, $sub2apiProbe, $localhostHeadroomProbe, $localhostSub2apiProbe)
    docker = @($headroomHealth, $sub2apiHealth)
    accelerator = $gpuRuntime
    warnings = $warnings
    critical = $critical
    actions = $actions
  }

  Write-WatchdogLog $row $LogPath
  return $row
}

$iterations = if ($Watch) { [Math]::Max(1, $MaxIterations) } else { 1 }
for ($i = 0; $i -lt $iterations; $i++) {
  $row = Invoke-WatchdogOnce
  $row | ConvertTo-Json -Depth 10
  if (-not $Watch -or $i -eq $iterations - 1) { break }
  Start-Sleep -Seconds $IntervalSec
}

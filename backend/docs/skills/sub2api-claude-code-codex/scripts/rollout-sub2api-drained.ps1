[CmdletBinding()]
param(
  [string]$ProfileDir = "",
  [string]$WslDistro = "Ubuntu-24.04",
  [int]$HeadroomPort = 8787,
  [ValidateRange(1, 86400)]
  [int]$DrainTimeoutSeconds = 900,
  [ValidateRange(50, 10000)]
  [int]$PollMilliseconds = 250,
  [ValidateRange(0, 10)]
  [int]$ObserverAllowance = 1,
  [ValidateRange(1, 600)]
  [int]$HealthWaitSeconds = 90
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $ProfileDir) {
  $repoRoot = (Resolve-Path (Join-Path $scriptRoot "..\..\..\..\..")).Path
  $ProfileDir = Join-Path $repoRoot "deploy\claude-code-codex-headroom"
}
$ProfileDir = (Resolve-Path -LiteralPath $ProfileDir).Path
$envPath = Join-Path $ProfileDir ".env"
if (-not (Test-Path -LiteralPath $envPath)) {
  throw "Missing runtime environment: $envPath"
}

function Read-DotEnvValue {
  param([string]$Path, [string]$Name)
  $line = Get-Content -LiteralPath $Path |
    Where-Object { $_ -match "^$([Regex]::Escape($Name))=" } |
    Select-Object -Last 1
  if (-not $line) { return "" }
  return ($line -split "=", 2)[1].Trim()
}

function Invoke-WslBash {
  param([string]$Command)
  & wsl.exe -d $WslDistro -- bash -lc $Command
  if ($LASTEXITCODE -ne 0) {
    throw "WSL command failed with exit code $LASTEXITCODE"
  }
}

$wslProfileDir = (& wsl.exe -d $WslDistro -- wslpath -a ($ProfileDir -replace "\\", "/")).Trim()
if ($LASTEXITCODE -ne 0 -or -not $wslProfileDir) {
  throw "Could not translate profile path into WSL: $ProfileDir"
}

$deadline = (Get-Date).AddSeconds($DrainTimeoutSeconds)
$consecutiveIdle = 0
$samples = 0
while ((Get-Date) -lt $deadline) {
  try {
    $stats = Invoke-RestMethod -Uri "http://127.0.0.1:$HeadroomPort/stats" -TimeoutSec 2
    $active = [int]$stats.proxy_inbound.active
  } catch {
    $active = -1
  }

  $samples++
  if ($active -ge 0 -and $active -le $ObserverAllowance) {
    $consecutiveIdle++
  } else {
    $consecutiveIdle = 0
  }
  if ($consecutiveIdle -ge 2) { break }
  Start-Sleep -Milliseconds $PollMilliseconds
}

if ($consecutiveIdle -lt 2) {
  throw "Drain timeout after ${DrainTimeoutSeconds}s; live container was left untouched"
}

$compose = "cd '$wslProfileDir' && docker compose -p sub2api-codex --env-file .env -f docker-compose.yml -f docker-compose.gpu.yml"
Invoke-WslBash "$compose up -d --no-deps --force-recreate --no-build sub2api"

$healthy = $false
for ($i = 0; $i -lt $HealthWaitSeconds; $i++) {
  $health = (& wsl.exe -d $WslDistro -- docker inspect sub2api-codex --format "{{.State.Health.Status}}" 2>$null).Trim()
  if ($health -eq "healthy") {
    $healthy = $true
    break
  }
  Start-Sleep -Seconds 1
}
if (-not $healthy) {
  throw "sub2api-codex did not become healthy within ${HealthWaitSeconds}s"
}

$expectedRevision = Read-DotEnvValue -Path $envPath -Name "SUB2API_GIT_REF"
$runningRevision = (& wsl.exe -d $WslDistro -- docker inspect sub2api-codex --format '{{index .Config.Labels "org.opencontainers.image.revision"}}').Trim()
if ($LASTEXITCODE -ne 0 -or $runningRevision -ne $expectedRevision) {
  throw "Running revision '$runningRevision' does not match expected '$expectedRevision'"
}

[pscustomobject]@{
  status = "healthy"
  revision = $runningRevision
  samples = $samples
  observerAllowance = $ObserverAllowance
}

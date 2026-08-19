[CmdletBinding()]
param(
  [string]$ProfileDir = "",
  [string]$WslDistro = "Ubuntu-24.04",
  [string]$HeadroomContainer = "headroom-sub2api",
  [string]$Sub2apiContainer = "sub2api-codex",
  [ValidateRange(1, 86400)]
  [int]$DrainTimeoutSeconds = 900,
  [ValidateRange(1, 600)]
  [int]$PausedDrainTimeoutSeconds = 60,
  [ValidateRange(1, 600)]
  [int]$HealthWaitSeconds = 90
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$idleHelperPath = Join-Path $scriptRoot "wait_sub2api_idle.py"
if (-not (Test-Path -LiteralPath $idleHelperPath)) {
  throw "Missing passive drain helper: $idleHelperPath"
}

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
$wslIdleHelperPath = (& wsl.exe -d $WslDistro -- wslpath -a ($idleHelperPath -replace "\\", "/")).Trim()
if ($LASTEXITCODE -ne 0 -or -not $wslIdleHelperPath) {
  throw "Could not translate idle helper path into WSL: $idleHelperPath"
}

$compose = "cd '$wslProfileDir' && docker compose -p sub2api-codex --env-file .env -f docker-compose.yml -f docker-compose.gpu.yml"
$headroomPaused = $false
try {
  # A continuously busy stack may never reach passive zero because new work
  # arrives as old work completes. Timeout here is not a failure: pause ingress
  # and drain the bounded set that was already accepted.
  & wsl.exe -d $WslDistro -- bash -lc "python3 '$wslIdleHelperPath' --container '$Sub2apiContainer' --timeout $DrainTimeoutSeconds --stable-seconds 0.5"
  $passiveDrainExit = $LASTEXITCODE
  if ($passiveDrainExit -ne 0 -and $passiveDrainExit -ne 42) {
    throw "Passive drain failed with exit code $passiveDrainExit"
  }
  Invoke-WslBash "docker pause '$HeadroomContainer' >/dev/null"
  $headroomPaused = $true

  # Close the race between the passive idle observation and docker pause.
  Invoke-WslBash "python3 '$wslIdleHelperPath' --container '$Sub2apiContainer' --timeout $PausedDrainTimeoutSeconds --stable-seconds 0.25"
  Invoke-WslBash "$compose up -d --no-deps --force-recreate --no-build sub2api"

  $healthy = $false
  for ($i = 0; $i -lt $HealthWaitSeconds; $i++) {
    $health = (& wsl.exe -d $WslDistro -- docker inspect $Sub2apiContainer --format "{{.State.Health.Status}}" 2>$null).Trim()
    if ($health -eq "healthy") {
      $healthy = $true
      break
    }
    Start-Sleep -Seconds 1
  }
  if (-not $healthy) {
    throw "$Sub2apiContainer did not become healthy within ${HealthWaitSeconds}s"
  }

  $expectedRevision = Read-DotEnvValue -Path $envPath -Name "SUB2API_GIT_REF"
  $labelsJson = (& wsl.exe -d $WslDistro -- docker inspect $Sub2apiContainer --format "{{json .Config.Labels}}")
  if ($LASTEXITCODE -ne 0 -or -not $labelsJson) {
    throw "Could not inspect labels for $Sub2apiContainer"
  }
  $labels = $labelsJson | ConvertFrom-Json
  $runningRevision = [string]$labels.'org.opencontainers.image.revision'
  if ($LASTEXITCODE -ne 0 -or $runningRevision -ne $expectedRevision) {
    throw "Running revision '$runningRevision' does not match expected '$expectedRevision'"
  }
} finally {
  if ($headroomPaused) {
    & wsl.exe -d $WslDistro -- docker unpause $HeadroomContainer 2>$null | Out-Null
  }
}

[pscustomobject]@{
  status = "healthy"
  revision = $runningRevision
  headroomPaused = $headroomPaused
}

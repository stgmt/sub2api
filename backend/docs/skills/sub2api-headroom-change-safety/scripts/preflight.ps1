param(
  [Parameter(Mandatory = $true)]
  [string]$RepoRoot,
  [string]$RuntimeProfile = "",
  [string]$Distro = "Ubuntu-24.04",
  [switch]$RequireLive
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$start = Join-Path $repo "backend\docs\skills\sub2api-claude-code-codex\scripts\start-sub2api-proxy-stack.ps1"

if (-not (Test-Path -LiteralPath $start)) {
  throw "Not a supported sub2api checkout: $start is missing"
}

function Require-Text {
  param([string]$Text, [string]$Needle)
  if (-not $Text.Contains($Needle)) { throw "Safety invariant missing from source: $Needle" }
}

$sourceText = Get-Content -Raw -LiteralPath $start
foreach ($invariant in @(
  '[switch]$ForceRecreate',
  '[switch]$AllowWslRestart',
  'HEADROOM_REQUIRE_CUDA',
  '--no-recreate',
  'Repair-PausedComposeContainers',
  'docker unpause'
)) {
  Require-Text -Text $sourceText -Needle $invariant
}

$forbidden = @(
  'backend\docs\skills\sub2api-claude-code-codex\scripts\launch-claude-code.ps1',
  'backend\docs\skills\sub2api-claude-code-codex\scripts\launch-claude-code.cmd'
)
foreach ($path in $forbidden) {
  if (Test-Path -LiteralPath (Join-Path $repo $path)) {
    throw "Unexpected manual launcher in proxy skill: $path"
  }
}

$gitHead = (& git -C $repo rev-parse HEAD).Trim()
$dirty = @(& git -C $repo status --porcelain)
$result = [ordered]@{
  source = @{ repo = $repo; sha = $gitHead; dirty_paths = @($dirty) }
  invariants = @{ normal_no_recreate = $true; wsl_restart_opt_in = $true; cuda_fail_closed = $true; paused_container_repair = $true }
  runtime = $null
  live = $null
}

if ($RuntimeProfile.Trim()) {
  $runtime = (Resolve-Path -LiteralPath $RuntimeProfile).Path
  if (-not (Test-Path -LiteralPath (Join-Path $runtime 'docker-compose.yml'))) {
    throw "Runtime profile does not contain docker-compose.yml: $runtime"
  }
  $result.runtime = @{ profile = $runtime; compose_present = $true }
}

if ($RequireLive) {
  $health = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 'http://127.0.0.1:8787/health'
  if ([int]$health.StatusCode -ne 200) { throw "Headroom health failed: HTTP $($health.StatusCode)" }
  $containers = & wsl.exe -d $Distro -- bash -lc "docker inspect -f '{{.Name}}|{{.State.Status}}|paused={{.State.Paused}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' headroom-sub2api sub2api-codex" 2>&1
  if ($LASTEXITCODE -ne 0) { throw "Could not inspect live proxy containers: $($containers -join ' ')" }
  if (($containers -join "`n") -match 'paused=true|\|exited\|') { throw "Live proxy is not safe for change: $($containers -join '; ')" }
  $result.live = @{ health = '200'; containers = @($containers) }
}

$result | ConvertTo-Json -Depth 6

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$RepoRoot,
  [string]$RuntimeProfile = "",
  [string]$Distro = "Ubuntu-24.04",
  [switch]$RequireLive
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path -LiteralPath $RepoRoot).Path
$canonicalProfile = Join-Path $repo "deploy\claude-code-codex-headroom"
if (-not $RuntimeProfile.Trim()) { $RuntimeProfile = $canonicalProfile }
$runtime = (Resolve-Path -LiteralPath $RuntimeProfile).Path
$mainSkillRoot = Join-Path $repo "backend\docs\skills\sub2api-claude-code-codex"
$mainScriptRoot = Join-Path $mainSkillRoot "scripts"
$start = Join-Path $mainScriptRoot "start-sub2api-proxy-stack.ps1"
$module = Join-Path $mainScriptRoot "fleet-contract.psm1"
$manifestPath = Join-Path $canonicalProfile "fleet-manifest.json"
if (-not (Test-Path -LiteralPath $start) -or -not (Test-Path -LiteralPath $module)) {
  throw "Not a supported sub2api checkout: canonical proxy scripts are missing"
}
Import-Module $module -Force
$manifest = Read-FleetManifest -Path $manifestPath

function Require-Text([string]$Text, [string]$Needle) {
  if (-not $Text.Contains($Needle)) { throw "Safety invariant missing from source: $Needle" }
}

$startText = Get-Content -Raw -LiteralPath $start
foreach ($invariant in @('[switch]$ForceRecreate', '[switch]$AllowWslRestart', 'HEADROOM_REQUIRE_CUDA', '--no-recreate', 'Repair-PausedComposeContainers', 'docker unpause')) {
  Require-Text $startText $invariant
}
if ($runtime -ne $canonicalProfile) {
  throw "Runtime profile is not the canonical checkout profile: runtime=$runtime canonical=$canonicalProfile"
}
foreach ($forbidden in @('launch-claude-code.ps1', 'launch-claude-code.cmd')) {
  if (Test-Path -LiteralPath (Join-Path $mainScriptRoot $forbidden)) { throw "Unexpected manual launcher in proxy skill: $forbidden" }
}

$gitHead = (& git -C $repo rev-parse HEAD).Trim()
$dirty = @(& git -C $repo status --porcelain)
$result = [ordered]@{
  status = "safe"
  source = @{ repo = $repo; sha = $gitHead; dirty_paths = @($dirty) }
  runtime = @{ profile = $runtime; canonical = $true }
  fleet = @{ manifest = $manifestPath; required_nodes = @($manifest.nodes | Where-Object required).Count; required_clients = @($manifest.clients | Where-Object required).Count }
  invariants = @{ normal_no_recreate = $true; wsl_restart_opt_in = $true; cuda_fail_closed = $true; paused_container_repair = $true }
  live = $null
}

if ($RequireLive) {
  $routes = [ordered]@{}
  foreach ($client in @($manifest.clients | Where-Object required)) {
    $settingsPath = Resolve-FleetPath -Path ([string]$client.settings_path)
    $url = switch ([string]$client.kind) {
      "claude-code" { Get-ClaudeHeadroomBaseUrl -SettingsPath $settingsPath }
      "dsh" { (Get-DshHeadBaseUrl -SettingsPath $settingsPath) -replace '/v1/?$', '' }
      default { $null }
    }
    if (-not $url) { throw "Required client '$($client.id)' has no configured Headroom endpoint" }
    $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 ($url.TrimEnd('/') + "/health")
    if ([int]$response.StatusCode -ne 200) { throw "Required client '$($client.id)' route failed" }
    $routes[[string]$client.id] = @{ endpoint = $url; health = 200 }
  }
  $primary = @($routes.GetEnumerator() | Select-Object -First 1)[0].Value.endpoint
  $stats = Invoke-RestMethod -UseBasicParsing -TimeoutSec 8 ($primary.TrimEnd('/') + "/stats")
  $rawActive = [int]$stats.proxy_inbound.active
  $active = [Math]::Max(0, $rawActive - 1)
  if ($active -gt 0) { throw "Live proxy has $active active request(s); deployment is not safe" }
  $containers = @(& wsl.exe -d $Distro -- docker inspect -f '{{.Name}}|{{.State.Status}}|paused={{.State.Paused}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{.Image}}' headroom-sub2api sub2api-codex 2>&1)
  if ($LASTEXITCODE -ne 0 -or ($containers -join "`n") -match 'paused=true|\|exited\|') { throw "Live proxy containers are not safe: $($containers -join '; ')" }
  $result.live = @{ routes = [pscustomobject]$routes; active_requests = $active; observer_adjustment = 1; containers = $containers }
}

$result | ConvertTo-Json -Depth 10

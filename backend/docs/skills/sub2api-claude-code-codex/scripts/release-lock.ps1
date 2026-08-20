[CmdletBinding()]
param(
  [ValidateSet("capture", "verify")]
  [string]$Action = "verify",
  [string]$RepoRoot = "",
  [string]$ProfileDir = "",
  [string]$Distro = "Ubuntu-24.04",
  [switch]$RequireLive
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$fleetContract = Join-Path $scriptRoot "fleet-contract.psm1"
Import-Module $fleetContract -Force

if (-not $RepoRoot.Trim()) {
  $RepoRoot = $scriptRoot
  while ($RepoRoot -and -not (Test-Path -LiteralPath (Join-Path $RepoRoot ".git"))) {
    $parent = Split-Path -Parent $RepoRoot
    if (-not $parent -or $parent -eq $RepoRoot) { throw "Could not resolve sub2api checkout" }
    $RepoRoot = $parent
  }
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not $ProfileDir.Trim()) { $ProfileDir = Join-Path $RepoRoot "deploy\claude-code-codex-headroom" }
$ProfileDir = (Resolve-Path -LiteralPath $ProfileDir).Path
$lockPath = Join-Path $ProfileDir "data\release-lock.json"

function Get-SourceState {
  $sha = (& git -C $RepoRoot rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0) { throw "Could not resolve sub2api source revision" }
  $files = [ordered]@{}
  foreach ($name in @("docker-compose.yml", "docker-compose.gpu.yml", "Dockerfile.headroom", "fleet-manifest.json")) {
    $path = Join-Path $ProfileDir $name
    if (-not (Test-Path -LiteralPath $path)) { throw "Release input missing: $path" }
    $files[$name] = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
  }
  return [pscustomobject]@{ sub2api_revision = $sha; files = [pscustomobject]$files }
}

function Get-LiveState {
  $format = "{{.Id}}|{{index .Config.Labels `"org.opencontainers.image.source`"}}|{{index .Config.Labels `"org.opencontainers.image.revision`"}}"
  $rows = [ordered]@{}
  foreach ($container in @("headroom-sub2api", "sub2api-codex")) {
    $output = @(& wsl.exe -d $Distro -- docker inspect --format $format $container 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Could not inspect ${container}: $($output -join ' ')" }
    $parts = ($output -join "").Trim() -split '\|', 3
    $rows[$container] = [pscustomobject]@{ image_id = $parts[0]; source = $parts[1]; revision = $parts[2] }
  }
  return [pscustomobject]$rows
}

$source = Get-SourceState
if ($Action -eq "capture") {
  $live = Get-LiveState
  $lock = [ordered]@{
    schema_version = 1
    captured_at = [DateTimeOffset]::UtcNow.ToString("o")
    source = $source
    live = $live
  }
  Write-AtomicUtf8NoBom -Path $lockPath -Content (($lock | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
  $lock | ConvertTo-Json -Depth 10
  return
}

if (-not (Test-Path -LiteralPath $lockPath)) { throw "Release lock not found: $lockPath" }
$lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json -ErrorAction Stop
$errors = [Collections.Generic.List[string]]::new()
if ([string]$lock.source.sub2api_revision -ne [string]$source.sub2api_revision) {
  $errors.Add("sub2api source revision drift")
}
foreach ($property in $source.files.PSObject.Properties) {
  if ([string]$lock.source.files.($property.Name) -ne [string]$property.Value) { $errors.Add("release input drift: $($property.Name)") }
}
$live = $null
if ($RequireLive) {
  $live = Get-LiveState
  foreach ($property in $live.PSObject.Properties) {
    $expected = $lock.live.($property.Name)
    if ($null -eq $expected -or [string]$expected.image_id -ne [string]$property.Value.image_id) { $errors.Add("live image drift: $($property.Name)") }
  }
}
if ($errors.Count -gt 0) { throw ($errors -join "; ") }
[pscustomobject]@{ status = "verified"; lock_path = $lockPath; source = $source; live = $live } | ConvertTo-Json -Depth 10

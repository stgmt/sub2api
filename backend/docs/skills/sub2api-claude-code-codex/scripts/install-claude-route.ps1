[CmdletBinding()]
param(
  [string]$InstallRoot = "$HOME\.codex\skills\sub2api-claude-code-codex",
  [string]$SafetyInstallRoot = "$HOME\.codex\skills\sub2api-headroom-change-safety",
  [string]$BinDir = "$HOME\.local\bin",
  [string]$LegacySkillRoot = "$HOME\.codex\skills\claude-provider-switcher",
  [string]$RuntimeRoot = "",
  [switch]$SkipPathUpdate,
  [switch]$SkipStatus
)

$ErrorActionPreference = "Stop"
$sourceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$safetySourceRoot = Join-Path (Split-Path -Parent $sourceRoot) "sub2api-headroom-change-safety"
$sourceFull = [IO.Path]::GetFullPath($sourceRoot).TrimEnd('\')
$installFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$safetySourceFull = [IO.Path]::GetFullPath($safetySourceRoot).TrimEnd('\')
$safetyInstallFull = [IO.Path]::GetFullPath($SafetyInstallRoot).TrimEnd('\')
if (-not $RuntimeRoot.Trim()) {
  $candidate = $sourceFull
  while ($candidate -and -not (Test-Path -LiteralPath (Join-Path $candidate "deploy\claude-code-codex-headroom\fleet-manifest.json"))) {
    $parent = Split-Path -Parent $candidate
    if (-not $parent -or $parent -eq $candidate) { $candidate = ""; break }
    $candidate = $parent
  }
  if (-not $candidate) { throw "Could not resolve canonical runtime root; pass -RuntimeRoot" }
  $RuntimeRoot = Join-Path $candidate "deploy\claude-code-codex-headroom"
}
$RuntimeRoot = (Resolve-Path -LiteralPath $RuntimeRoot).Path
$fleetManifestPath = Join-Path $RuntimeRoot "fleet-manifest.json"
if (-not (Test-Path -LiteralPath $fleetManifestPath)) { throw "Fleet manifest not found: $fleetManifestPath" }

function Sync-ManagedSkill {
  param([string]$Source, [string]$Destination)
  if (-not (Test-Path -LiteralPath (Join-Path $Source "SKILL.md"))) { throw "Managed skill source is invalid: $Source" }
  if ($Source -eq $Destination) { return [pscustomobject]@{ status = "source"; path = $Destination; rollback = $null } }
  $parent = Split-Path -Parent $Destination
  New-Item -ItemType Directory -Path $parent -Force | Out-Null
  $staging = Join-Path $parent (".{0}.{1}.installing" -f ([IO.Path]::GetFileName($Destination)), [guid]::NewGuid().ToString("N"))
  $rollback = "$Destination.rollback"
  try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Copy-Item -Path (Join-Path $Source '*') -Destination $staging -Recurse -Force
    if (Test-Path -LiteralPath $rollback) { Remove-Item -LiteralPath $rollback -Recurse -Force }
    if (Test-Path -LiteralPath $Destination) { Move-Item -LiteralPath $Destination -Destination $rollback }
    Move-Item -LiteralPath $staging -Destination $Destination
  } catch {
    if (-not (Test-Path -LiteralPath $Destination) -and (Test-Path -LiteralPath $rollback)) {
      Move-Item -LiteralPath $rollback -Destination $Destination -ErrorAction SilentlyContinue
    }
    throw
  } finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }
  return [pscustomobject]@{ status = "installed"; path = $Destination; rollback = if (Test-Path -LiteralPath $rollback) { $rollback } else { $null } }
}

$mainSkillInstall = Sync-ManagedSkill -Source $sourceFull -Destination $installFull
$safetySkillInstall = Sync-ManagedSkill -Source $safetySourceFull -Destination $safetyInstallFull

foreach ($legacyProfileName in @("anthropic-only.v1.json", "anthropic-only.v2.json", "anthropic-only.v3.json", "chatgpt-only.v1.json", "chatgpt-only.v2.json", "chatgpt-only.v3.json", "chatgpt-only.v4.json", "hybrid-current.v1.json")) {
  $legacyProfile = Join-Path $installFull "profiles\$legacyProfileName"
  if (Test-Path -LiteralPath $legacyProfile) {
    Remove-Item -LiteralPath $legacyProfile -Force
  }
}

$legacyFull = [IO.Path]::GetFullPath($LegacySkillRoot).TrimEnd('\')
if ($legacyFull -ne $installFull -and (Test-Path -LiteralPath $legacyFull)) {
  $legacyManifest = Join-Path $legacyFull "SKILL.md"
  $isManagedLegacy = (Test-Path -LiteralPath $legacyManifest) -and
    (Select-String -LiteralPath $legacyManifest -Pattern '^name:\s*claude-provider-switcher\s*$' -Quiet)
  if ($isManagedLegacy) {
    Remove-Item -LiteralPath $legacyFull -Recurse -Force
  }
}

New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
$wrapperPath = Join-Path $BinDir "claude-route.cmd"
$controllerPath = Join-Path $installFull "scripts\claude-route.ps1"
$wrapper = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$controllerPath" -RuntimeRoot "$RuntimeRoot" -FleetManifestPath "$fleetManifestPath" %*
exit /b %ERRORLEVEL%
"@
[IO.File]::WriteAllText($wrapperPath, $wrapper, [Text.UTF8Encoding]::new($false))

if (-not $SkipPathUpdate) {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @($userPath -split ';' | Where-Object { $_ })
  if ($parts -notcontains $BinDir) {
    [Environment]::SetEnvironmentVariable("Path", (($parts + $BinDir) -join ';'), "User")
  }
}

$result = [ordered]@{
  status = "installed"
  skill_root = $installFull
  safety_skill_root = $safetyInstallFull
  skill_install = $mainSkillInstall
  safety_skill_install = $safetySkillInstall
  command = $wrapperPath
  runtime_root = $RuntimeRoot
  fleet_manifest = $fleetManifestPath
}
if (-not $SkipStatus) {
  $statusOutput = & cmd.exe /d /c "`"$wrapperPath`" status" 2>&1
  if ($LASTEXITCODE -ne 0) { throw "claude-route status failed after install: $($statusOutput -join [Environment]::NewLine)" }
  $result.route_status = ($statusOutput -join [Environment]::NewLine | ConvertFrom-Json)
}
$result | ConvertTo-Json -Depth 30

[CmdletBinding()]
param(
  [string]$InstallRoot = "$HOME\.codex\skills\claude-provider-switcher",
  [string]$BinDir = "$HOME\.local\bin",
  [switch]$SkipStatus
)

$ErrorActionPreference = "Stop"
$sourceRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$sourceFull = [IO.Path]::GetFullPath($sourceRoot).TrimEnd('\')
$installFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')

if ($sourceFull -ne $installFull) {
  New-Item -ItemType Directory -Path $installFull -Force | Out-Null
  Copy-Item -Path (Join-Path $sourceFull '*') -Destination $installFull -Recurse -Force
}

New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
$wrapperPath = Join-Path $BinDir "claude-route.cmd"
$controllerPath = Join-Path $installFull "scripts\claude-route.ps1"
$wrapper = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$controllerPath" %*
exit /b %ERRORLEVEL%
"@
[IO.File]::WriteAllText($wrapperPath, $wrapper, [Text.UTF8Encoding]::new($false))

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$parts = @($userPath -split ';' | Where-Object { $_ })
if ($parts -notcontains $BinDir) {
  [Environment]::SetEnvironmentVariable("Path", (($parts + $BinDir) -join ';'), "User")
}

$result = [ordered]@{
  status = "installed"
  skill_root = $installFull
  command = $wrapperPath
}
if (-not $SkipStatus) {
  $statusOutput = & cmd.exe /d /c "`"$wrapperPath`" status" 2>&1
  if ($LASTEXITCODE -ne 0) { throw "claude-route status failed after install: $($statusOutput -join [Environment]::NewLine)" }
  $result.route_status = ($statusOutput -join [Environment]::NewLine | ConvertFrom-Json)
}
$result | ConvertTo-Json -Depth 30

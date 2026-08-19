param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")).Path
)

$ErrorActionPreference = "Stop"
$preflight = Join-Path $PSScriptRoot "preflight.ps1"
$result = & $preflight -RepoRoot $RepoRoot | ConvertFrom-Json
if (-not $result.invariants.normal_no_recreate -or -not $result.invariants.wsl_restart_opt_in -or -not $result.invariants.cuda_fail_closed -or -not $result.invariants.paused_container_repair) {
  throw "Safety invariant contract failed"
}
Write-Host "CHANGE_SAFETY_CONTRACT_OK"

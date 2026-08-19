param(
  [string]$ScriptPath = (Join-Path $PSScriptRoot "rollout-sub2api-drained.ps1")
)

$ErrorActionPreference = "Stop"
$script = Get-Content -Raw -LiteralPath $ScriptPath

foreach ($required in @(
  'docker pause',
  'docker unpause',
  '$passiveDrainExit -ne 42',
  '{{json .Config.Labels}}',
  "'org.opencontainers.image.revision'"
)) {
  if (-not $script.Contains($required)) {
    throw "Missing drained rollout contract: $required"
  }
}

if ($script.Contains('{{index .Config.Labels')) {
  throw "Do not pass a quoted Go-template index expression through PowerShell and WSL"
}

Write-Output "ROLLOUT_SUB2API_DRAINED_CONTRACT_OK"

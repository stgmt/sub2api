[CmdletBinding()]
param(
  [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"
if (-not $RepoRoot.Trim()) { $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\..")).Path }
$preflight = Join-Path $PSScriptRoot "preflight.ps1"
$mainScriptRoot = Join-Path $RepoRoot "backend\docs\skills\sub2api-claude-code-codex\scripts"
$fleetTest = Join-Path $mainScriptRoot "test-fleet-contract.ps1"
$parseErrors = [Collections.Generic.List[string]]::new()
Get-ChildItem -LiteralPath $mainScriptRoot -Filter "*.ps1" -File | ForEach-Object {
  $tokens = $null
  $errors = $null
  [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
  foreach ($error in @($errors)) { $parseErrors.Add("$($_.Name): $($error.Message)") }
}
Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.ps1" -File | ForEach-Object {
  $tokens = $null
  $errors = $null
  [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
  foreach ($error in @($errors)) { $parseErrors.Add("$($_.Name): $($error.Message)") }
}
if ($parseErrors.Count -gt 0) { throw "PowerShell parse contract failed: $($parseErrors -join '; ')" }
$result = & $preflight -RepoRoot $RepoRoot | ConvertFrom-Json
if (-not $result.runtime.canonical -or -not $result.invariants.normal_no_recreate -or -not $result.invariants.cuda_fail_closed) {
  throw "Change safety invariant contract failed"
}
& $fleetTest | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Fleet contract regression test failed" }
"CHANGE_SAFETY_CONTRACT_OK"

param(
  [string]$LauncherPath = (Join-Path $PSScriptRoot "launch-claude-code.ps1")
)

$ErrorActionPreference = "Stop"
$text = Get-Content -Raw -LiteralPath $LauncherPath
foreach ($needle in @(
  "ensure-sub2api-proxy-stack.ps1",
  "SUB2API_PROFILE_DIR",
  "127.0.0.1:8787/health",
  "ValueFromRemainingArguments",
  "claude.exe, claude"
)) {
  if (-not $text.Contains($needle)) { throw "Launcher contract missing: $needle" }
}
Write-Host "LAUNCHER_CONTRACT_OK"

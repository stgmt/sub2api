param(
  [string]$RepoRoot = "",
  [string]$ProfileDir = "",
  [int]$HealthTimeoutSeconds = 8,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ClaudeArgs = @()
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath
$ensure = Join-Path $scriptDir "ensure-sub2api-proxy-stack.ps1"
if (-not (Test-Path -LiteralPath $ensure)) {
  throw "sub2api launcher is incomplete: missing $ensure"
}

function Find-ProfileDir {
  if ($ProfileDir.Trim()) {
    return (Resolve-Path -LiteralPath $ProfileDir).Path
  }

  $candidates = @()
  if ($env:SUB2API_PROFILE_DIR) { $candidates += $env:SUB2API_PROFILE_DIR }
  if ($RepoRoot.Trim()) { $candidates += (Join-Path $RepoRoot "deploy\claude-code-codex-headroom") }
  $cursor = (Get-Location).Path
  while ($cursor) {
    $candidates += (Join-Path $cursor "deploy\claude-code-codex-headroom")
    $parent = Split-Path -Parent $cursor
    if (-not $parent -or $parent -eq $cursor) { break }
    $cursor = $parent
  }

  foreach ($candidate in ($candidates | Select-Object -Unique)) {
    if (Test-Path -LiteralPath (Join-Path $candidate "docker-compose.yml")) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  throw "Cannot find deploy\claude-code-codex-headroom. Run this from the sub2api checkout or set SUB2API_PROFILE_DIR."
}

$profile = Find-ProfileDir
$repo = if ($RepoRoot.Trim()) { (Resolve-Path -LiteralPath $RepoRoot).Path } else { Split-Path -Parent (Split-Path -Parent $profile) }

Write-Host "[sub2api] repairing and starting Headroom + sub2api..." -ForegroundColor Cyan
& $ensure -RepoRoot $repo -ProfileDir $profile -HealthTimeoutSeconds $HealthTimeoutSeconds -HyperVRemoteConfigMode none
if ($LASTEXITCODE -ne 0) {
  throw "Proxy self-heal failed. Run scripts\verify-claude-code-sub2api.ps1 for diagnostics."
}

$health = Invoke-WebRequest -UseBasicParsing -TimeoutSec $HealthTimeoutSeconds "http://127.0.0.1:8787/health"
if ([int]$health.StatusCode -ne 200) {
  throw "Headroom is not healthy: HTTP $($health.StatusCode)"
}

$claude = Get-Command claude.exe, claude -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $claude) {
  throw "Claude Code was not found in PATH. Install Claude Code, then run this launcher again."
}

Write-Host "[sub2api] Headroom is healthy; launching Claude Code." -ForegroundColor Green
& $claude.Source @ClaudeArgs
exit $LASTEXITCODE

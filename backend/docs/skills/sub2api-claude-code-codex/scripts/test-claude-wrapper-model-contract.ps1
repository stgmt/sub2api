$ErrorActionPreference = "Stop"

$sync = Join-Path $PSScriptRoot "sync-claude-wrapper-models.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sub2api-wrapper-contract-$([guid]::NewGuid())"
$wrapper = Join-Path $tempRoot "claude.cmd"

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  @'
@echo off
set "ANTHROPIC_MODEL=gpt-5.6-sol"
set "ANTHROPIC_SMALL_FAST_MODEL=gpt-5.3-codex-spark"
set "ANTHROPIC_DEFAULT_HAIKU_MODEL=gpt-5.6-terra-medium"
set "CLAUDE_CODE_SUBAGENT_MODEL=gpt-5.6-terra-medium"
"%USERPROFILE%\.local\bin\claude-real.exe" %*
'@ | Set-Content -LiteralPath $wrapper -Encoding ASCII

  $failedAsExpected = $false
  try { & $sync -Path $wrapper -CheckOnly } catch { $failedAsExpected = $true }
  if (-not $failedAsExpected) { throw "CheckOnly accepted a stale wrapper" }

  & $sync -Path $wrapper -SkipBackup
  & $sync -Path $wrapper -CheckOnly

  $text = Get-Content -Raw -LiteralPath $wrapper
  foreach ($key in @(
    "ANTHROPIC_SMALL_FAST_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_FABLE_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL"
  )) {
    if ($text -notmatch ('(?m)^set "' + [regex]::Escape($key) + '=qwen3\.8-max-preview"\r?$')) {
      throw "Qwen model contract missing for $key"
    }
  }
  Write-Host "Claude wrapper model contract tests: PASS"
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

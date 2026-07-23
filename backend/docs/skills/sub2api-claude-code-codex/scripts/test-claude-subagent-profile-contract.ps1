param(
  [string]$ScriptPath = (Join-Path $PSScriptRoot "sync-claude-subagent-profile.ps1")
)

$ErrorActionPreference = "Stop"
$root = Join-Path ([IO.Path]::GetTempPath()) ("sub2api-qwen-profile-" + [guid]::NewGuid().ToString("N"))
$claudeHome = Join-Path $root ".claude"
$wrapper = Join-Path $root ".local\bin\claude.cmd"

try {
  New-Item -ItemType Directory -Force -Path $claudeHome,(Split-Path -Parent $wrapper),(Join-Path $claudeHome "agents") | Out-Null
  @{
    hooks = @{ PreToolUse = @(@{ matcher = "Bash"; hooks = @(@{ type = "command"; command = "keep-me" }) }) }
    env = @{ ANTHROPIC_SMALL_FAST_MODEL = "stale-model" }
  } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $claudeHome "settings.json") -Encoding UTF8
  @"
---
name: general-purpose
description: Keep this custom body.
model: stale-model
effort: low
---

CUSTOM_BODY_SENTINEL
"@ | Set-Content -LiteralPath (Join-Path $claudeHome "agents\general-purpose.md") -Encoding UTF8
  @"
@echo off
set "ANTHROPIC_MODEL=gpt-5.6-sol"
set "CLAUDE_CODE_SUBAGENT_MODEL=stale-model"
"@ | Set-Content -LiteralPath $wrapper -Encoding ASCII

  & $ScriptPath -ClaudeHome $claudeHome -WrapperPath $wrapper -SkipUserEnvironment

  $settings = Get-Content -LiteralPath (Join-Path $claudeHome "settings.json") -Raw | ConvertFrom-Json
  if ($settings.hooks.PreToolUse[0].hooks[0].command -ne "keep-me") { throw "Existing hooks were not preserved" }
  $keys = @(
    "ANTHROPIC_SMALL_FAST_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_FABLE_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "CLAUDE_CODE_SUBAGENT_MODEL"
  )
  foreach ($key in $keys) {
    if ($settings.env.$key -ne "qwen3.8-max-preview") { throw "Wrong settings value for $key" }
  }
  foreach ($name in @("general-purpose", "Explore", "workflow-subagent", "bench-reviewer", "bench-triage")) {
    $text = Get-Content -LiteralPath (Join-Path $claudeHome "agents\$name.md") -Raw
    if ($text -notmatch '(?m)^model: qwen3\.8-max-preview$') { throw "$name model was not pinned" }
    if ($text -notmatch '(?m)^effort: high$') { throw "$name effort was not pinned" }
  }
  $general = Get-Content -LiteralPath (Join-Path $claudeHome "agents\general-purpose.md") -Raw
  if ($general -notmatch 'CUSTOM_BODY_SENTINEL') { throw "Existing agent body was overwritten" }
  $wrapperText = Get-Content -LiteralPath $wrapper -Raw
  if ($wrapperText -notmatch 'ANTHROPIC_MODEL=gpt-5\.6-sol') { throw "Main model wrapper assignment was changed" }
  if ($wrapperText -notmatch 'CLAUDE_CODE_SUBAGENT_MODEL=qwen3\.8-max-preview') { throw "Subagent wrapper assignment was not repaired" }

  & $ScriptPath -ClaudeHome $claudeHome -WrapperPath $wrapper -SkipUserEnvironment -CheckOnly | Out-Null
  Write-Host "CLAUDE_SUBAGENT_PROFILE_CONTRACT_OK"
} finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

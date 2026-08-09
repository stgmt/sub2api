$ErrorActionPreference = "Stop"

$apply = Join-Path $PSScriptRoot "apply-claude-provider-profile.ps1"
$profile = Join-Path (Split-Path -Parent $PSScriptRoot) "profiles\chatgpt-only.v5.json"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "sub2api-fast-wrapper-contract-$([guid]::NewGuid())"
$settings = Join-Path $tempRoot "settings.json"
$agents = Join-Path $tempRoot "agents"
$wrapper = Join-Path $tempRoot "claude.cmd"

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  @'
@echo off
setlocal
set "ANTHROPIC_BASE_URL=http://127.0.0.1:8787"
"%USERPROFILE%\.local\bin\claude.exe" %*
'@ | Set-Content -LiteralPath $wrapper -Encoding ASCII

  & $apply -ProfilePath $profile -SettingsPath $settings -AgentsPath $agents -WrapperPath $wrapper -Generation 99 -EnvironmentTarget None | Out-Null

  $settingsJson = Get-Content -Raw -LiteralPath $settings | ConvertFrom-Json
  if ([string]$settingsJson.env.CLAUDE_CODE_SKIP_FAST_MODE_NETWORK_ERRORS -ne "1") {
    throw "settings.json does not enable the proxy fast-mode network probe workaround"
  }
  if ([string]$settingsJson.env.CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK -ne "1") {
    throw "settings.json does not bypass the unsupported custom-gateway organization probe"
  }
  if ([string]$settingsJson.env.ANTHROPIC_MODEL -ne "claude-opus-5") {
    throw "chatgpt-only profile must expose a Claude-supported Opus identity to the client"
  }
  if ([string]$settingsJson.env.ANTHROPIC_DEFAULT_OPUS_MODEL -ne "claude-opus-5") {
    throw "chatgpt-only Opus picker must use the Claude-supported identity"
  }

  $wrapperText = Get-Content -Raw -LiteralPath $wrapper
  if ($wrapperText -notmatch '(?im)^set\s+"CLAUDE_CODE_SKIP_FAST_MODE_NETWORK_ERRORS=1"\s*$') {
    throw "claude.cmd does not receive CLAUDE_CODE_SKIP_FAST_MODE_NETWORK_ERRORS"
  }
  if ($wrapperText -notmatch '(?im)^set\s+"CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK=1"\s*$') {
    throw "claude.cmd does not receive CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK"
  }
  if ($wrapperText -notmatch '(?im)^set\s+"ANTHROPIC_MODEL=claude-opus-5"\s*$') {
    throw "claude.cmd does not receive the Claude-supported Opus identity"
  }
  if ($wrapperText -match '(?im)^set\s+"CLAUDE_CODE_FORCE_FAST_MODE=') {
    throw "unsupported CLAUDE_CODE_FORCE_FAST_MODE must not be installed"
  }

  Write-Host "Claude fast-mode wrapper contract: PASS"
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

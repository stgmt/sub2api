[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptRoot
$applier = Join-Path $scriptRoot "apply-claude-provider-profile.ps1"
$controller = Join-Path $scriptRoot "claude-route.ps1"
$installer = Join-Path $scriptRoot "install-claude-route.ps1"
$anthropicProfile = Join-Path $skillRoot "profiles\anthropic-only.v2.json"
$hybridProfile = Join-Path $skillRoot "profiles\hybrid-current.v1.json"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("sub2api-provider-route-test-" + [guid]::NewGuid())

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

try {
  $settingsPath = Join-Path $temp ".claude\settings.json"
  $agentsPath = Join-Path $temp ".claude\agents"
  $wrapperPath = Join-Path $temp ".local\bin\claude.cmd"
  New-Item -ItemType Directory -Path $agentsPath -Force | Out-Null
  New-Item -ItemType Directory -Path (Split-Path -Parent $wrapperPath) -Force | Out-Null
  $settings = @{
    permissions = @{ defaultMode = "bypassPermissions" }
    hooks = @{ SessionStart = @(@{ hooks = @(@{ type = "command"; command = "preserve-me" }) }) }
    env = @{ UNRELATED = "keep"; ANTHROPIC_MODEL = "old-model" }
  } | ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($settingsPath, $settings, [Text.UTF8Encoding]::new($false))
  $agentBody = "---`nname: fixture`nmodel: old`neffort: max`n---`n`n# Preserve this body`nAgent instructions stay byte-for-byte.`n"
  $agentPath = Join-Path $agentsPath "fixture.md"
  [IO.File]::WriteAllText($agentPath, $agentBody, [Text.UTF8Encoding]::new($false))
  $wrapper = "@echo off`r`nsetlocal`r`nset `"ANTHROPIC_AUTH_TOKEN=do-not-touch`"`r`nset `"ANTHROPIC_MODEL=old`"`r`nclaude-real.exe %*`r`n"
  [IO.File]::WriteAllText($wrapperPath, $wrapper, [Text.UTF8Encoding]::new($false))

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applier -ProfilePath $anthropicProfile -SettingsPath $settingsPath -AgentsPath $agentsPath -WrapperPath $wrapperPath -Generation 7 -EnvironmentTarget None | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "Anthropic profile apply must succeed"
  $afterAnthropic = Get-Content -Raw $settingsPath | ConvertFrom-Json
  Assert-True ($afterAnthropic.env.UNRELATED -eq "keep") "Unrelated env must survive"
  Assert-True ($afterAnthropic.hooks.SessionStart[0].hooks[0].command -eq "preserve-me") "Hooks must survive"
  Assert-True ($afterAnthropic.env.ANTHROPIC_MODEL -eq "claude-opus-4-8") "Anthropic main model must apply"
  Assert-True ($afterAnthropic.env.CLAUDE_PROVIDER_PROFILE_GENERATION -eq "7") "Generation marker must apply"
  $agentAfter = Get-Content -Raw $agentPath
  Assert-True ($agentAfter -match '(?m)^model: claude-sonnet-5$') "Agent model must switch to Sonnet"
  Assert-True ($agentAfter -match '(?m)^effort: high$') "Agent effort must switch to high"
  Assert-True ($agentAfter.Contains("Agent instructions stay byte-for-byte.")) "Agent body must survive"
  $wrapperAfter = Get-Content -Raw $wrapperPath
  Assert-True ($wrapperAfter.Contains('ANTHROPIC_AUTH_TOKEN=do-not-touch')) "Auth token must survive"
  Assert-True ($wrapperAfter.Contains('ANTHROPIC_MODEL=claude-opus-4-8')) "Wrapper model must switch"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applier -ProfilePath $anthropicProfile -SettingsPath $settingsPath -AgentsPath $agentsPath -WrapperPath $wrapperPath -Generation 7 -EnvironmentTarget None -CheckOnly | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "Check-only must be clean immediately after apply"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applier -ProfilePath $hybridProfile -SettingsPath $settingsPath -AgentsPath $agentsPath -WrapperPath $wrapperPath -Generation 8 -EnvironmentTarget None | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "Hybrid profile apply must succeed"
  $afterHybrid = Get-Content -Raw $settingsPath | ConvertFrom-Json
  Assert-True ($afterHybrid.env.ANTHROPIC_MODEL -eq "gpt-5.6-sol") "Hybrid main model must restore"
  Assert-True ($afterHybrid.env.CLAUDE_CODE_SUBAGENT_MODEL -eq "qwen3.8-max-preview") "Hybrid subagent must restore"
  Assert-True ((Get-Content -Raw $agentPath) -match '(?m)^model: qwen3.8-max-preview$') "Agent frontmatter must restore"

  $anthropic = Get-Content -Raw $anthropicProfile | ConvertFrom-Json
  $hybrid = Get-Content -Raw $hybridProfile | ConvertFrom-Json
  Assert-True ($anthropic.group.platform -eq "openai") "Anthropic-only dispatcher group must remain OpenAI-shaped"
  Assert-True ($anthropic.group.allow_messages_dispatch -eq $true) "Anthropic-only group must dispatch /v1/messages"
Assert-True (@($anthropic.group.messages_dispatch_model_config.model_fallbacks.PSObject.Properties).Count -eq 0) "Anthropic-only fallbacks must be empty"
Assert-True ($anthropic.version -eq 2) "Anthropic-only Sonnet compact profile must be version 2"
Assert-True ($anthropic.group.messages_dispatch_model_config.compact_mapped_model -eq "claude-sonnet-5") "Anthropic-only compact must route directly to Sonnet 5"
Assert-True ($anthropic.client_env.ANTHROPIC_SMALL_FAST_MODEL -eq "claude-sonnet-5") "Anthropic-only small-fast must avoid effort-incompatible Haiku"
Assert-True ($anthropic.group.messages_dispatch_model_config.exact_model_mappings.'gpt-5.3-codex-spark' -eq "claude-sonnet-5") "Stale Spark IDs must route to Sonnet 5 under Anthropic-only"
Assert-True ($anthropic.expected_provider -eq "anthropic") "Anthropic proof contract must name provider"
  Assert-True ($hybrid.expected_provider -eq "openai") "Hybrid proof contract must name provider"

  $controllerText = Get-Content -Raw $controller
  foreach ($needle in @('/api/v1/admin/api-keys/', 'usage_logs', 'Invoke-HeadroomProbe', 'route_switcher_source_fingerprint', 'rollback failed')) {
    Assert-True ($controllerText.Contains($needle)) "Controller contract missing $needle"
  }
  Assert-True ($controllerText.Contains('--profile-path')) "Linux reconcile must use the applier's canonical profile argument"
  Assert-True ($controllerText.Contains('probeNonce')) "Switch and rollback probes must bypass Headroom response-cache reuse"
  Assert-True ($controllerText.Contains('preserving sub2api-owned OAuth credentials')) "Existing Anthropic account must not require stale local Claude credentials"
  Assert-True ($controllerText.Contains('if ($source) { $updateBody.expires_at')) "Existing account expiry must be preserved when no local OAuth source is available"
  Assert-True ((Get-Content -Raw $applier).Contains('SetEnvironmentVariable')) "Windows applier must reconcile user-level env overrides"
  $skillsRoot = Split-Path -Parent $skillRoot
  $setupText = Get-Content -Raw (Join-Path $skillsRoot "sub2api-claude-code-codex\scripts\setup-sub2api-claude-code.ps1")
  $ensureText = Get-Content -Raw (Join-Path $skillsRoot "sub2api-claude-code-codex\scripts\ensure-sub2api-proxy-stack.ps1")
  Assert-True ($setupText.Contains('Join-Path $PSScriptRoot "install-claude-route.ps1"')) "Canonical stack setup must install its bundled provider controller"
  Assert-True (-not $setupText.Contains('claude-provider-switcher\scripts')) "Canonical setup must not depend on the removed standalone skill"
  Assert-True ($ensureText.Contains('.codex\skills\sub2api-claude-code-codex\scripts\claude-route.ps1')) "Watchdog must resolve the controller from the consolidated skill"
  Assert-True ($ensureText.Contains('Invoke-ProviderRouteReconcile')) "The single stack watchdog must own provider generation repair"

  $installFixture = Join-Path $temp "install-fixture"
  $installedSkill = Join-Path $installFixture "sub2api-claude-code-codex"
  $legacySkill = Join-Path $installFixture "claude-provider-switcher"
  $legacyProfile = Join-Path $installedSkill "profiles\anthropic-only.v1.json"
  New-Item -ItemType Directory -Path (Split-Path -Parent $legacyProfile), $legacySkill -Force | Out-Null
  [IO.File]::WriteAllText($legacyProfile, '{}', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $legacySkill 'SKILL.md'), "---`nname: claude-provider-switcher`n---`n", [Text.UTF8Encoding]::new($false))
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -InstallRoot $installedSkill -BinDir (Join-Path $installFixture 'bin') -LegacySkillRoot $legacySkill -SkipPathUpdate -SkipStatus | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "Consolidated installer fixture must succeed"
  Assert-True (Test-Path -LiteralPath (Join-Path $installedSkill 'profiles\anthropic-only.v2.json')) "Installer must copy Anthropic profile v2"
  Assert-True (-not (Test-Path -LiteralPath $legacyProfile)) "Installer must remove stale Anthropic profile v1"
  Assert-True (-not (Test-Path -LiteralPath $legacySkill)) "Installer must remove the managed standalone provider skill"

  [pscustomobject]@{ status = "PASS"; assertions = 37; profiles = @("anthropic-only", "hybrid-current") } | ConvertTo-Json -Compress
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

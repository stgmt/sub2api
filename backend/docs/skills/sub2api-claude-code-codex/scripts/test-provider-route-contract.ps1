[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptRoot
$applier = Join-Path $scriptRoot "apply-claude-provider-profile.ps1"
$controller = Join-Path $scriptRoot "claude-route.ps1"
$installer = Join-Path $scriptRoot "install-claude-route.ps1"
$anthropicProfile = Join-Path $skillRoot "profiles\anthropic-only.v4.json"
$chatgptProfile = Join-Path $skillRoot "profiles\chatgpt-only.v2.json"
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
    env = @{
      UNRELATED = "keep"
      ANTHROPIC_MODEL = "old-model"
      CLAUDE_CODE_MAX_CONTEXT_TOKENS = "370000"
      CLAUDE_CODE_AUTO_COMPACT_WINDOW = "340000"
      CLAUDE_CODE_EFFORT_LEVEL = "max"
    }
  } | ConvertTo-Json -Depth 20
  [IO.File]::WriteAllText($settingsPath, $settings, [Text.UTF8Encoding]::new($false))
  $agentBody = "---`nname: fixture`nmodel: old`neffort: max`n---`n`n# Preserve this body`nAgent instructions stay byte-for-byte.`n"
  $agentPath = Join-Path $agentsPath "fixture.md"
  [IO.File]::WriteAllText($agentPath, $agentBody, [Text.UTF8Encoding]::new($false))
  $wrapper = "@echo off`r`nsetlocal`r`nset `"ANTHROPIC_AUTH_TOKEN=do-not-touch`"`r`nset `"ANTHROPIC_MODEL=old`"`r`nset `"CLAUDE_CODE_MAX_CONTEXT_TOKENS=370000`"`r`nset `"CLAUDE_CODE_AUTO_COMPACT_WINDOW=340000`"`r`nset `"CLAUDE_CODE_EFFORT_LEVEL=max`"`r`nclaude-real.exe %*`r`n"
  [IO.File]::WriteAllText($wrapperPath, $wrapper, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $wrapperPath) "claude.exe"), "fixture", [Text.UTF8Encoding]::new($false))

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applier -ProfilePath $anthropicProfile -SettingsPath $settingsPath -AgentsPath $agentsPath -WrapperPath $wrapperPath -Generation 7 -EnvironmentTarget None | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "Anthropic profile apply must succeed"
  $afterAnthropic = Get-Content -Raw $settingsPath | ConvertFrom-Json
  Assert-True ($afterAnthropic.env.UNRELATED -eq "keep") "Unrelated env must survive"
  Assert-True ($afterAnthropic.hooks.SessionStart[0].hooks[0].command -eq "preserve-me") "Hooks must survive"
  Assert-True ($afterAnthropic.env.ANTHROPIC_MODEL -eq "claude-opus-5[1m]") "Anthropic gateway main model must request 1M context"
  Assert-True ($afterAnthropic.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS -eq "1000000") "Anthropic settings context must replace stale hybrid context"
  Assert-True ($afterAnthropic.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW -eq "1000000") "Anthropic settings compact window must replace stale hybrid window"
  Assert-True ($afterAnthropic.env.CLAUDE_PROVIDER_PROFILE_GENERATION -eq "7") "Generation marker must apply"
  $agentAfter = Get-Content -Raw $agentPath
  Assert-True ($agentAfter -match '(?m)^model: claude-sonnet-5\[1m\]$') "Agent model must switch to Sonnet 1M"
  Assert-True ($agentAfter -match '(?m)^effort: high$') "Agent effort must switch to high"
  Assert-True ($agentAfter.Contains("Agent instructions stay byte-for-byte.")) "Agent body must survive"
  $wrapperAfter = Get-Content -Raw $wrapperPath
  Assert-True ($wrapperAfter.Contains('ANTHROPIC_AUTH_TOKEN=do-not-touch')) "Auth token must survive"
  Assert-True ($wrapperAfter.Contains('ANTHROPIC_MODEL=claude-opus-5[1m]')) "Wrapper model must switch to Opus 1M"
  Assert-True ($wrapperAfter.Contains('CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000')) "Wrapper context must replace stale hybrid context"
  Assert-True ($wrapperAfter.Contains('CLAUDE_CODE_AUTO_COMPACT_WINDOW=1000000')) "Wrapper compact window must replace stale hybrid window"
  Assert-True ($wrapperAfter.Contains('claude.exe %*')) "Wrapper must invoke the current native Claude binary after an update"
  Assert-True (-not $wrapperAfter.Contains('claude-real.exe')) "Wrapper must not pin a stale renamed Claude binary"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applier -ProfilePath $anthropicProfile -SettingsPath $settingsPath -AgentsPath $agentsPath -WrapperPath $wrapperPath -Generation 7 -EnvironmentTarget None -CheckOnly | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "Check-only must be clean immediately after apply"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applier -ProfilePath $hybridProfile -SettingsPath $settingsPath -AgentsPath $agentsPath -WrapperPath $wrapperPath -Generation 8 -EnvironmentTarget None | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "Hybrid profile apply must succeed"
  $afterHybrid = Get-Content -Raw $settingsPath | ConvertFrom-Json
  Assert-True ($afterHybrid.env.ANTHROPIC_MODEL -eq "gpt-5.6-sol") "Hybrid main model must restore"
  Assert-True ($afterHybrid.env.CLAUDE_CODE_SUBAGENT_MODEL -eq "qwen3.8-max-preview") "Hybrid subagent must restore"
  Assert-True ((Get-Content -Raw $agentPath) -match '(?m)^model: qwen3.8-max-preview$') "Agent frontmatter must restore"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applier -ProfilePath $chatgptProfile -SettingsPath $settingsPath -AgentsPath $agentsPath -WrapperPath $wrapperPath -Generation 9 -EnvironmentTarget None | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "ChatGPT-only profile apply must succeed"
  $afterChatGPT = Get-Content -Raw $settingsPath | ConvertFrom-Json
  Assert-True ($afterChatGPT.env.ANTHROPIC_MODEL -eq "gpt-5.6-sol") "ChatGPT-only main must use Sol"
  Assert-True ($afterChatGPT.env.CLAUDE_CODE_SUBAGENT_MODEL -eq "gpt-5.6-luna") "ChatGPT-only subagents must use Luna"
  Assert-True ($afterChatGPT.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS -eq "370000") "ChatGPT-only client context target must be 370k"
  Assert-True ($afterChatGPT.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW -eq "340000") "ChatGPT-only compact threshold must be 340k"
  Assert-True ($afterChatGPT.env.PSObject.Properties.Name -notcontains "CLAUDE_CODE_EFFORT_LEVEL") "ChatGPT-only must clear hard interactive effort"
  $agentAfterChatGPT = Get-Content -Raw $agentPath
  Assert-True ($agentAfterChatGPT -match '(?m)^model: gpt-5.6-luna$') "ChatGPT-only agent frontmatter must use Luna"
  Assert-True ($agentAfterChatGPT -match '(?m)^effort: xhigh$') "ChatGPT-only agent frontmatter must use xhigh"
  Assert-True ((Get-Content -Raw $wrapperPath).Contains('set "CLAUDE_CODE_EFFORT_LEVEL="')) "ChatGPT-only wrapper must clear inherited hard interactive effort"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applier -ProfilePath $chatgptProfile -SettingsPath $settingsPath -AgentsPath $agentsPath -WrapperPath $wrapperPath -Generation 9 -EnvironmentTarget None -CheckOnly | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "ChatGPT-only check-only must be clean immediately after apply"

  $anthropic = Get-Content -Raw $anthropicProfile | ConvertFrom-Json
  $chatgpt = Get-Content -Raw $chatgptProfile | ConvertFrom-Json
  $hybrid = Get-Content -Raw $hybridProfile | ConvertFrom-Json
  Assert-True ($anthropic.group.platform -eq "openai") "Anthropic-only dispatcher group must remain OpenAI-shaped"
  Assert-True ($anthropic.group.allow_messages_dispatch -eq $true) "Anthropic-only group must dispatch /v1/messages"
Assert-True (@($anthropic.group.messages_dispatch_model_config.model_fallbacks.PSObject.Properties).Count -eq 0) "Anthropic-only fallbacks must be empty"
Assert-True ($anthropic.version -eq 4) "Anthropic-only Opus 5 1M profile must be version 4"
Assert-True ($anthropic.main_model -eq "claude-opus-5") "Anthropic-only main must use Opus 5"
Assert-True ($anthropic.client_env.ANTHROPIC_DEFAULT_OPUS_MODEL -eq "claude-opus-5[1m]") "Gateway Opus alias must request the 1M client window"
Assert-True ($anthropic.client_env.CLAUDE_CODE_MAX_CONTEXT_TOKENS -eq "1000000") "Anthropic-only client context must match Opus 5 1M"
Assert-True ($anthropic.client_env.CLAUDE_CODE_AUTO_COMPACT_WINDOW -eq "1000000") "Anthropic-only auto-compact window must use the 1M model window"
Assert-True ($anthropic.group.messages_dispatch_model_config.opus_mapped_model -eq "claude-opus-5") "Opus picker must route to Opus 5"
Assert-True ($anthropic.group.messages_dispatch_model_config.compact_mapped_model -eq "claude-sonnet-5") "Anthropic-only compact must route directly to Sonnet 5"
Assert-True ($anthropic.group.messages_dispatch_model_config.compact_reasoning_effort -eq "low") "Anthropic-only compact must force low effort"
Assert-True ($anthropic.group.messages_dispatch_model_config.exact_model_mappings.'claude-opus-4-8' -eq "claude-opus-5") "Legacy Opus 4.8 requests must upgrade to Opus 5"
Assert-True ($anthropic.client_env.ANTHROPIC_SMALL_FAST_MODEL -eq "claude-sonnet-5[1m]") "Anthropic-only small-fast must use the Sonnet 5 gateway 1M variant"
Assert-True ($anthropic.client_env.CLAUDE_CODE_SUBAGENT_MODEL -eq "claude-sonnet-5[1m]") "Anthropic-only subagents must inherit a 1M-capable Sonnet client model"
Assert-True ($anthropic.group.messages_dispatch_model_config.exact_model_mappings.'gpt-5.3-codex-spark' -eq "claude-sonnet-5") "Stale Spark IDs must route to Sonnet 5 under Anthropic-only"
Assert-True ($anthropic.expected_provider -eq "anthropic") "Anthropic proof contract must name provider"
  Assert-True ($hybrid.expected_provider -eq "openai") "Hybrid proof contract must name provider"
  Assert-True ($chatgpt.main_model -eq "gpt-5.6-sol") "ChatGPT-only main must use Sol"
  Assert-True ($chatgpt.version -eq 2) "ChatGPT-only bounded recovery profile must be version 2"
  Assert-True ($chatgpt.agent_model -eq "gpt-5.6-luna") "ChatGPT-only delegated model must use Luna"
  Assert-True ($chatgpt.agent_effort -eq "xhigh") "ChatGPT-only delegated effort must be xhigh"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.compact_mapped_model -eq "gpt-5.6-luna") "ChatGPT-only compact must use Luna"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.compact_reasoning_effort -eq "high") "ChatGPT-only compact must use high effort"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.sdk_cli_mapped_model -eq "gpt-5.6-luna") "ChatGPT-only SDK CLI must use Luna"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.sdk_cli_reasoning_effort -eq "xhigh") "ChatGPT-only SDK CLI must use xhigh"
  Assert-True (@($chatgpt.group.messages_dispatch_model_config.model_fallbacks.PSObject.Properties).Count -eq 0) "ChatGPT-only generic fallbacks must remain empty"
  Assert-True (@($chatgpt.group.messages_dispatch_model_config.automatic_model_fallbacks.PSObject.Properties).Count -eq 1) "ChatGPT-only must define one bounded automatic fallback"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.automatic_model_fallbacks.'gpt-5.6-luna'[0] -eq "gpt-5.6-sol") "ChatGPT-only automatic Luna recovery must use Sol"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.exact_model_mappings.'qwen3.8-max-preview' -eq "gpt-5.6-luna") "Stale Qwen IDs must fail closed to Luna"
  Assert-True (@($chatgpt.group.models_list_config.models | Where-Object { $_ -match '^(qwen|glm|deepseek|claude)' }).Count -eq 0) "ChatGPT-only catalog must contain GPT/Codex models only"
  Assert-True (@($chatgpt.unset_client_env) -contains "CLAUDE_CODE_EFFORT_LEVEL") "ChatGPT-only must declare hard-effort cleanup"

  $controllerText = Get-Content -Raw $controller
  foreach ($needle in @('/api/v1/admin/api-keys/', 'usage_logs', 'Invoke-HeadroomProbe', 'route_switcher_source_fingerprint', 'rollback failed')) {
    Assert-True ($controllerText.Contains($needle)) "Controller contract missing $needle"
  }
  Assert-True ($controllerText.Contains('--profile-path')) "Linux reconcile must use the applier's canonical profile argument"
  Assert-True ($controllerText.Contains('probeNonce')) "Switch and rollback probes must bypass Headroom response-cache reuse"
  Assert-True ($controllerText.Contains('"chatgpt" { Invoke-Switch "chatgpt-only" }')) "Controller must expose the ChatGPT-only switch"
  Assert-True ($controllerText.Contains('Ensure-ChatGPTAccount')) "Controller must bind the dedicated ChatGPT OAuth account"
  Assert-True ($controllerText.Contains("`$sourcePortable = `$CodexAuthPath -replace '\\', '/'")) "Controller must normalize the Windows Codex auth path before WSL translation"
  Assert-True ($controllerText.Contains('preserving sub2api-owned OAuth credentials')) "Existing Anthropic account must not require stale local Claude credentials"
  Assert-True ($controllerText.Contains('if ($source) { $updateBody.expires_at')) "Existing account expiry must be preserved when no local OAuth source is available"
  Assert-True ($controllerText.Contains('[Security.SecureString]::new()')) "Windows guest reconcile must construct credentials without lazy module loading"
  Assert-True ($controllerText.Contains('Get-VMNetworkAdapter -VMName')) "Linux guest reconcile must discover the current Hyper-V address instead of trusting a stale IP"
  Assert-True (-not $controllerText.Contains('ConvertTo-SecureString $password')) "Windows guest reconcile must not depend on a broken PowerShell.Security module"
  $providerVerifierText = Get-Content -Raw (Join-Path $scriptRoot 'verify-claude-provider-route.ps1')
  Assert-True ($providerVerifierText.Contains("automatic_model_fallbacks'->'gpt-5.6-luna'->>0 = 'gpt-5.6-sol'")) "Provider verifier must prove bounded Luna-to-Sol recovery"
  Assert-True ($providerVerifierText.Contains('Provider profile state is stale')) "Provider verifier must reject stale profile generations"
  Assert-True ((Get-Content -Raw $applier).Contains('SetEnvironmentVariable')) "Windows applier must reconcile user-level env overrides"
  $skillsRoot = Split-Path -Parent $skillRoot
  $setupText = Get-Content -Raw (Join-Path $skillsRoot "sub2api-claude-code-codex\scripts\setup-sub2api-claude-code.ps1")
  $ensureText = Get-Content -Raw (Join-Path $skillsRoot "sub2api-claude-code-codex\scripts\ensure-sub2api-proxy-stack.ps1")
  Assert-True ($setupText.Contains('Join-Path $PSScriptRoot "install-claude-route.ps1"')) "Canonical stack setup must install its bundled provider controller"
  Assert-True (-not $setupText.Contains('claude-provider-switcher\scripts')) "Canonical setup must not depend on the removed standalone skill"
  Assert-True ($ensureText.Contains('.codex\skills\sub2api-claude-code-codex\scripts\claude-route.ps1')) "Watchdog must resolve the controller from the consolidated skill"
  Assert-True ($ensureText.Contains('Invoke-ProviderRouteReconcile')) "The single stack watchdog must own provider generation repair"
  Assert-True ($ensureText.Contains('$stateRoot.StartsWith("/")')) "Watchdog must recognize Linux absolute state roots on Windows"
  Assert-True ($ensureText.Contains("`$sourcePortable = `$source -replace '\\', '/'")) "Watchdog must normalize the Windows Codex auth path before WSL translation"

  $installFixture = Join-Path $temp "install-fixture"
  $installedSkill = Join-Path $installFixture "sub2api-claude-code-codex"
  $legacySkill = Join-Path $installFixture "claude-provider-switcher"
  $legacyProfileV1 = Join-Path $installedSkill "profiles\anthropic-only.v1.json"
  $legacyProfileV2 = Join-Path $installedSkill "profiles\anthropic-only.v2.json"
  $legacyProfileV3 = Join-Path $installedSkill "profiles\anthropic-only.v3.json"
  New-Item -ItemType Directory -Path (Split-Path -Parent $legacyProfileV1), $legacySkill -Force | Out-Null
  [IO.File]::WriteAllText($legacyProfileV1, '{}', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($legacyProfileV2, '{}', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($legacyProfileV3, '{}', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $legacySkill 'SKILL.md'), "---`nname: claude-provider-switcher`n---`n", [Text.UTF8Encoding]::new($false))
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -InstallRoot $installedSkill -BinDir (Join-Path $installFixture 'bin') -LegacySkillRoot $legacySkill -SkipPathUpdate -SkipStatus | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "Consolidated installer fixture must succeed"
  Assert-True (Test-Path -LiteralPath (Join-Path $installedSkill 'profiles\anthropic-only.v4.json')) "Installer must copy Anthropic profile v4"
  Assert-True (Test-Path -LiteralPath (Join-Path $installedSkill 'profiles\chatgpt-only.v2.json')) "Installer must copy ChatGPT-only profile v2"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $installedSkill 'profiles\chatgpt-only.v1.json'))) "Installer must remove legacy ChatGPT-only profile v1"
  Assert-True (-not (Test-Path -LiteralPath $legacyProfileV1)) "Installer must remove stale Anthropic profile v1"
  Assert-True (-not (Test-Path -LiteralPath $legacyProfileV2)) "Installer must remove stale Anthropic profile v2"
  Assert-True (-not (Test-Path -LiteralPath $legacyProfileV3)) "Installer must remove stale Anthropic profile v3"
  Assert-True (-not (Test-Path -LiteralPath $legacySkill)) "Installer must remove the managed standalone provider skill"

  [pscustomobject]@{ status = "PASS"; assertions = 83; profiles = @("anthropic-only", "chatgpt-only", "hybrid-current") } | ConvertTo-Json -Compress
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

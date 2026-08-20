[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptRoot
$applier = Join-Path $scriptRoot "apply-claude-provider-profile.ps1"
$controller = Join-Path $scriptRoot "claude-route.ps1"
$installer = Join-Path $scriptRoot "install-claude-route.ps1"
$anthropicProfile = Join-Path $skillRoot "profiles\anthropic-only.v4.json"
$chatgptProfile = Join-Path $skillRoot "profiles\chatgpt-only.v5.json"
$hybridProfile = Join-Path $skillRoot "profiles\hybrid-current.v2.json"
$qwenProfile = Join-Path $skillRoot "profiles\qwen-only.v1.json"
$alibabaProfile = Join-Path $skillRoot "profiles\alibaba-qwen-deepseek-flash.v1.json"
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
  Assert-True ($afterAnthropic.env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS -eq "10") "Anthropic profile must enforce the concurrent subagent cap"
  Assert-True ($afterAnthropic.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH -eq "1") "Anthropic profile must disable nested subagent spawning"
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
  Assert-True ($afterHybrid.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS -eq "370000") "Hybrid must replace stale 1M context with its GPT safety target"
  Assert-True ($afterHybrid.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW -eq "340000") "Hybrid must restore the GPT compact threshold"
  Assert-True ($afterHybrid.env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS -eq "10") "Hybrid profile must preserve the concurrent subagent cap"
  Assert-True ($afterHybrid.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH -eq "1") "Hybrid profile must preserve the nested subagent cap"
  Assert-True ((Get-Content -Raw $agentPath) -match '(?m)^model: qwen3.8-max-preview$') "Agent frontmatter must restore"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applier -ProfilePath $qwenProfile -SettingsPath $settingsPath -AgentsPath $agentsPath -WrapperPath $wrapperPath -Generation 9 -AuthToken "fleet-test-key" -EnvironmentTarget None | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "Qwen-only profile apply must succeed"
  $afterQwen = Get-Content -Raw $settingsPath | ConvertFrom-Json
  Assert-True ($afterQwen.env.ANTHROPIC_MODEL -eq "qwen3.8-max-preview") "Qwen-only main must use Qwen"
  Assert-True ($afterQwen.env.CLAUDE_CODE_SUBAGENT_MODEL -eq "qwen3.8-max-preview") "Qwen-only subagents must use Qwen"
  Assert-True ($afterQwen.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS -eq "1000000") "Qwen-only must publish the Qwen 1M context"
  Assert-True ($afterQwen.env.ANTHROPIC_AUTH_TOKEN -eq "fleet-test-key") "Fleet API key must be reconciled into settings"
  Assert-True ((Get-Content -Raw $wrapperPath).Contains('ANTHROPIC_AUTH_TOKEN=fleet-test-key')) "Fleet API key must replace a stale wrapper token"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applier -ProfilePath $chatgptProfile -SettingsPath $settingsPath -AgentsPath $agentsPath -WrapperPath $wrapperPath -Generation 10 -AuthToken "fleet-test-key" -BaseUrl "http://172.30.1.2:8787" -EnvironmentTarget None | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "ChatGPT-only profile apply must succeed"
  $afterChatGPT = Get-Content -Raw $settingsPath | ConvertFrom-Json
  Assert-True ($afterChatGPT.env.ANTHROPIC_MODEL -eq "gpt-5.6-sol") "ChatGPT-only main must expose the OpenAI/Codex identity"
  Assert-True ($afterChatGPT.env.ANTHROPIC_DEFAULT_OPUS_MODEL -eq "gpt-5.6-sol") "ChatGPT-only primary picker slot must expose the OpenAI/Codex identity"
   Assert-True ($afterChatGPT.env.CLAUDE_CODE_SKIP_FAST_MODE_NETWORK_ERRORS -eq "1") "ChatGPT-only must bypass the gateway network probe"
   Assert-True ($afterChatGPT.env.CLAUDE_CODE_SKIP_FAST_MODE_ORG_CHECK -eq "1") "ChatGPT-only must bypass the gateway organization probe"
  Assert-True ($afterChatGPT.env.CLAUDE_CODE_SUBAGENT_MODEL -eq "gpt-5.6-luna") "ChatGPT-only subagents must use Luna"
  Assert-True ($afterChatGPT.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS -eq "370000") "ChatGPT-only client context target must be 370k"
  Assert-True ($afterChatGPT.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW -eq "340000") "ChatGPT-only compact threshold must be 340k"
  Assert-True ($afterChatGPT.env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS -eq "10") "ChatGPT-only profile must enforce the concurrent subagent cap"
  Assert-True ($afterChatGPT.env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH -eq "1") "ChatGPT-only profile must disable nested subagent spawning"
  Assert-True ($afterChatGPT.env.ANTHROPIC_BASE_URL -eq "http://172.30.1.2:8787") "Provider apply must reconcile the exact Headroom endpoint"
  Assert-True ($afterChatGPT.env.PSObject.Properties.Name -notcontains "CLAUDE_CODE_EFFORT_LEVEL") "ChatGPT-only must clear hard interactive effort"
  $agentAfterChatGPT = Get-Content -Raw $agentPath
  Assert-True ($agentAfterChatGPT -match '(?m)^model: gpt-5.6-luna$') "ChatGPT-only agent frontmatter must use Luna"
  Assert-True ($agentAfterChatGPT -match '(?m)^effort: max$') "ChatGPT-only agent frontmatter must use max"
  Assert-True ((Get-Content -Raw $wrapperPath).Contains('set "CLAUDE_CODE_EFFORT_LEVEL="')) "ChatGPT-only wrapper must clear inherited hard interactive effort"
  Assert-True ((Get-Content -Raw $wrapperPath).Contains('ANTHROPIC_BASE_URL=http://172.30.1.2:8787')) "Wrapper must use the reconciled Headroom endpoint"
  Assert-True (Test-Path -LiteralPath "$settingsPath.rollback") "Settings updates must retain one atomic rollback file"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applier -ProfilePath $chatgptProfile -SettingsPath $settingsPath -AgentsPath $agentsPath -WrapperPath $wrapperPath -Generation 10 -AuthToken "fleet-test-key" -BaseUrl "http://172.30.1.2:8787" -EnvironmentTarget None -CheckOnly | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "ChatGPT-only check-only must be clean immediately after apply"

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $applier -ProfilePath $alibabaProfile -SettingsPath $settingsPath -AgentsPath $agentsPath -WrapperPath $wrapperPath -Generation 11 -AuthToken "fleet-test-key" -EnvironmentTarget None | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "Alibaba Qwen + DeepSeek Flash profile apply must succeed"
  $afterAlibaba = Get-Content -Raw $settingsPath | ConvertFrom-Json
  Assert-True ($afterAlibaba.env.ANTHROPIC_MODEL -eq "qwen3.8-max-preview") "Alibaba main must use Qwen 3.8 Max"
  Assert-True ($afterAlibaba.env.CLAUDE_CODE_SUBAGENT_MODEL -eq "deepseek-v4-flash-0731") "Alibaba subagents must use the live DeepSeek V4 Flash ID"
  Assert-True ($afterAlibaba.env.ANTHROPIC_SMALL_FAST_MODEL -eq "deepseek-v4-flash-0731") "Alibaba small-fast must use the live DeepSeek V4 Flash ID"
  Assert-True ($afterAlibaba.env.CLAUDE_CODE_MAX_CONTEXT_TOKENS -eq "1000000") "Alibaba profile must publish the 1M context target"
  Assert-True ($afterAlibaba.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW -eq "900000") "Alibaba profile must leave compaction headroom"
  Assert-True ($afterAlibaba.env.PSObject.Properties.Name -notcontains "CLAUDE_CODE_EFFORT_LEVEL") "Alibaba profile must leave interactive effort selectable"
  Assert-True ((Get-Content -Raw $agentPath) -match '(?m)^model: deepseek-v4-flash-0731$') "Alibaba delegated agent frontmatter must use the live Flash ID"

  $anthropic = Get-Content -Raw $anthropicProfile | ConvertFrom-Json
  $chatgpt = Get-Content -Raw $chatgptProfile | ConvertFrom-Json
  $hybrid = Get-Content -Raw $hybridProfile | ConvertFrom-Json
  $qwen = Get-Content -Raw $qwenProfile | ConvertFrom-Json
  $alibaba = Get-Content -Raw $alibabaProfile | ConvertFrom-Json
  Assert-True ($anthropic.group.platform -eq "openai") "Anthropic-only dispatcher group must remain OpenAI-shaped"
  Assert-True ($anthropic.group.allow_messages_dispatch -eq $true) "Anthropic-only group must dispatch /v1/messages"
Assert-True (@($anthropic.group.messages_dispatch_model_config.model_fallbacks.PSObject.Properties).Count -eq 0) "Anthropic-only fallbacks must be empty"
Assert-True ($anthropic.version -eq 4) "Anthropic-only Opus 5 1M profile must be version 4"
Assert-True ($anthropic.main_model -eq "claude-opus-5") "Anthropic-only main must use Opus 5"
Assert-True ($anthropic.client_env.ANTHROPIC_DEFAULT_OPUS_MODEL -eq "claude-opus-5[1m]") "Gateway Opus alias must request the 1M client window"
Assert-True ($anthropic.client_env.CLAUDE_CODE_MAX_CONTEXT_TOKENS -eq "1000000") "Anthropic-only client context must match Opus 5 1M"
Assert-True ($anthropic.client_env.CLAUDE_CODE_AUTO_COMPACT_WINDOW -eq "1000000") "Anthropic-only auto-compact window must use the 1M model window"
Assert-True ($anthropic.client_env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS -eq "10") "Anthropic-only profile must publish the concurrent subagent cap"
Assert-True ($anthropic.client_env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH -eq "1") "Anthropic-only profile must publish the nested subagent cap"
Assert-True ($anthropic.group.messages_dispatch_model_config.opus_mapped_model -eq "claude-opus-5") "Opus picker must route to Opus 5"
Assert-True ($anthropic.group.messages_dispatch_model_config.compact_mapped_model -eq "claude-sonnet-5") "Anthropic-only compact must route directly to Sonnet 5"
Assert-True ($anthropic.group.messages_dispatch_model_config.compact_reasoning_effort -eq "low") "Anthropic-only compact must force low effort"
Assert-True ($anthropic.group.messages_dispatch_model_config.exact_model_mappings.'claude-opus-4-8' -eq "claude-opus-5") "Legacy Opus 4.8 requests must upgrade to Opus 5"
Assert-True ($anthropic.client_env.ANTHROPIC_SMALL_FAST_MODEL -eq "claude-sonnet-5[1m]") "Anthropic-only small-fast must use the Sonnet 5 gateway 1M variant"
Assert-True ($anthropic.client_env.CLAUDE_CODE_SUBAGENT_MODEL -eq "claude-sonnet-5[1m]") "Anthropic-only subagents must inherit a 1M-capable Sonnet client model"
Assert-True ($anthropic.group.messages_dispatch_model_config.exact_model_mappings.'gpt-5.3-codex-spark' -eq "claude-sonnet-5") "Stale Spark IDs must route to Sonnet 5 under Anthropic-only"
Assert-True ($anthropic.expected_provider -eq "anthropic") "Anthropic proof contract must name provider"
  Assert-True ($hybrid.expected_provider -eq "openai") "Hybrid proof contract must name provider"
  Assert-True ($hybrid.version -eq 2) "Hybrid Qwen SDK routing profile must be version 2"
  Assert-True ($hybrid.group.messages_dispatch_model_config.sdk_cli_mapped_model -eq "qwen3.8-max-preview") "Hybrid SDK CLI and built-in Explore children must use Qwen"
  Assert-True ($hybrid.group.messages_dispatch_model_config.sdk_cli_reasoning_effort -eq "high") "Hybrid SDK CLI and built-in Explore children must use high effort"
  Assert-True ($hybrid.group.messages_dispatch_model_config.compact_mapped_model -eq "qwen3.8-max-preview") "Hybrid compact must use Qwen"
  Assert-True ($hybrid.group.messages_dispatch_model_config.compact_reasoning_effort -eq "high") "Hybrid compact must use high effort"
  Assert-True ($hybrid.group.messages_dispatch_model_config.plan_mapped_model -eq "gpt-5.6-sol") "Hybrid Plan agent must use Sol"
  Assert-True ($hybrid.group.messages_dispatch_model_config.plan_reasoning_effort -eq "high") "Hybrid Plan agent must use high effort"
  Assert-True (@($hybrid.group.messages_dispatch_model_config.model_fallbacks.PSObject.Properties).Count -eq 1) "Hybrid must keep exactly one terminal-quota fallback"
  Assert-True ($hybrid.group.messages_dispatch_model_config.model_fallbacks.'qwen3.8-max-preview'[0] -eq "gpt-5.6-sol") "Hybrid Qwen terminal-quota fallback must use Sol"
  Assert-True ($null -eq $hybrid.group.messages_dispatch_model_config.model_fallbacks.'gpt-5.6-luna') "Hybrid must not preserve the stale Luna fallback"
  Assert-True ($chatgpt.main_model -eq "gpt-5.6-sol") "ChatGPT-only main must use Sol"
  Assert-True ($chatgpt.version -eq 5) "ChatGPT-only Luna-max routing profile must be version 5"
  Assert-True ($chatgpt.agent_model -eq "gpt-5.6-luna") "ChatGPT-only delegated model must use Luna"
  Assert-True ($chatgpt.agent_effort -eq "max") "ChatGPT-only delegated effort must be max"
  Assert-True ($chatgpt.client_env.ANTHROPIC_DEFAULT_FABLE_MODEL -eq "gpt-5.6-luna") "ChatGPT-only Fable picker slot must use Luna"
  Assert-True ($chatgpt.client_env.ANTHROPIC_DEFAULT_SONNET_MODEL -eq "gpt-5.6-luna") "ChatGPT-only Sonnet picker slot must use Luna"
  Assert-True ($chatgpt.client_env.CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS -eq "10") "ChatGPT-only profile must publish the concurrent subagent cap"
  Assert-True ($chatgpt.client_env.CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH -eq "1") "ChatGPT-only profile must publish the nested subagent cap"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.compact_mapped_model -eq "gpt-5.6-luna") "ChatGPT-only compact must use Luna"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.compact_reasoning_effort -eq "max") "ChatGPT-only compact must use max effort"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.plan_mapped_model -eq "gpt-5.6-sol") "ChatGPT-only Plan agent must use Sol"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.plan_reasoning_effort -eq "high") "ChatGPT-only Plan agent must use high effort"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.sdk_cli_mapped_model -eq "gpt-5.6-luna") "ChatGPT-only SDK CLI must use Luna"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.sdk_cli_reasoning_effort -eq "max") "ChatGPT-only SDK CLI must use max"
   Assert-True ($chatgpt.group.messages_dispatch_model_config.sonnet_mapped_model -eq "gpt-5.6-luna") "ChatGPT-only Sonnet dispatch must use Luna"
   Assert-True ($chatgpt.group.messages_dispatch_model_config.fast_mapped_model -eq "gpt-5.6-luna") "ChatGPT-only Fast requests must use Luna"
   Assert-True ($chatgpt.group.messages_dispatch_model_config.exact_model_mappings.'claude-opus-5' -eq "gpt-5.6-sol") "Normal Opus identity must stay on Sol"
  Assert-True (@($chatgpt.group.messages_dispatch_model_config.model_fallbacks.PSObject.Properties).Count -eq 0) "ChatGPT-only generic fallbacks must remain empty"
  Assert-True (@($chatgpt.group.messages_dispatch_model_config.automatic_model_fallbacks.PSObject.Properties).Count -eq 0) "ChatGPT-only automatic fallbacks must be empty"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.exact_model_mappings.'qwen3.8-max-preview' -eq "gpt-5.6-luna") "Stale Qwen IDs must route to Luna"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.exact_model_mappings.'gpt-5.6-luna' -eq "gpt-5.6-luna") "Luna IDs must remain Luna"
  Assert-True ($chatgpt.group.messages_dispatch_model_config.exact_model_mappings.'gpt-5.6-terra' -eq "gpt-5.6-luna") "Raw Terra IDs must route to Luna"
  Assert-True (@($chatgpt.group.models_list_config.models | Where-Object { $_ -eq 'gpt-5.6-luna' }).Count -eq 1) "ChatGPT-only catalog must publish Luna"
  Assert-True (@($chatgpt.group.models_list_config.models | Where-Object { $_ -eq 'gpt-5.6-terra-medium' }).Count -eq 0) "ChatGPT-only catalog must hide Terra-medium"
  Assert-True (@($chatgpt.group.models_list_config.models | Where-Object { $_ -eq 'gpt-5.6-terra' }).Count -eq 0) "ChatGPT-only catalog must not publish raw Terra"
  Assert-True (@($chatgpt.group.models_list_config.models | Where-Object { $_ -match '^(qwen|glm|deepseek|claude)' }).Count -eq 0) "ChatGPT-only catalog must contain GPT/Codex models only"
  Assert-True (@($chatgpt.unset_client_env) -contains "CLAUDE_CODE_EFFORT_LEVEL") "ChatGPT-only must declare hard-effort cleanup"
  Assert-True ($qwen.main_model -eq "qwen3.8-max-preview") "Qwen-only main must use Qwen"
  Assert-True ($qwen.agent_model -eq "qwen3.8-max-preview") "Qwen-only agents must use Qwen"
  Assert-True ($qwen.group.messages_dispatch_model_config.plan_mapped_model -eq "qwen3.8-max-preview") "Qwen-only Plan must remain Qwen-only"
  Assert-True ($qwen.group.messages_dispatch_model_config.plan_reasoning_effort -eq "high") "Qwen-only Plan must use high effort"
  Assert-True (@($qwen.unset_client_env) -contains "CLAUDE_CODE_EFFORT_LEVEL") "Qwen-only interactive effort must remain selectable"
  Assert-True (@($qwen.group.messages_dispatch_model_config.model_fallbacks.PSObject.Properties).Count -eq 0) "Qwen-only must not fall back to GPT or Claude"
  Assert-True (@($qwen.group.models_list_config.models).Count -eq 1 -and $qwen.group.models_list_config.models[0] -eq "qwen3.8-max-preview") "Qwen-only picker must publish only Qwen 3.8 Max"
  Assert-True ($alibaba.main_model -eq "qwen3.8-max-preview") "Alibaba main must use Qwen 3.8 Max"
  Assert-True ($alibaba.agent_model -eq "deepseek-v4-flash-0731") "Alibaba delegated model must use the live DeepSeek V4 Flash ID"
  Assert-True ($alibaba.agent_effort -eq "high") "Alibaba delegated model must use high effort"
  Assert-True ($alibaba.group.messages_dispatch_model_config.plan_mapped_model -eq "qwen3.8-max-preview") "Alibaba Plan must use Qwen 3.8 Max"
  Assert-True ($alibaba.group.messages_dispatch_model_config.plan_reasoning_effort -eq "high") "Alibaba Plan must use high effort"
  Assert-True ($alibaba.group.messages_dispatch_model_config.compact_mapped_model -eq "deepseek-v4-flash-0731") "Alibaba compact must use the live DeepSeek V4 Flash ID"
  Assert-True ($alibaba.group.messages_dispatch_model_config.compact_reasoning_effort -eq "high") "Alibaba compact must use high effort"
  Assert-True ($alibaba.group.messages_dispatch_model_config.sdk_cli_mapped_model -eq "deepseek-v4-flash-0731") "Alibaba SDK CLI must use the live DeepSeek V4 Flash ID"
  Assert-True (@($alibaba.group.messages_dispatch_model_config.model_fallbacks.PSObject.Properties).Count -eq 0) "Alibaba generic fallbacks must be empty"
  Assert-True (@($alibaba.group.messages_dispatch_model_config.automatic_model_fallbacks.PSObject.Properties).Count -eq 0) "Alibaba automatic fallbacks must be empty"
  Assert-True ($alibaba.group.messages_dispatch_model_config.alibaba_time_window.enabled) "Alibaba schedule must be enabled in the managed group"
  Assert-True ($alibaba.group.messages_dispatch_model_config.alibaba_time_window.timezone -eq "Europe/Moscow") "Alibaba schedule must use Moscow time"
  Assert-True ($alibaba.group.messages_dispatch_model_config.alibaba_time_window.start -eq "17:00") "Alibaba schedule must start at 17:00"
  Assert-True ($alibaba.group.messages_dispatch_model_config.alibaba_time_window.end -eq "03:00") "Alibaba schedule must end at 03:00"
  Assert-True ($alibaba.group.messages_dispatch_model_config.alibaba_time_window.main_model -eq "qwen3.8-max-preview") "Alibaba in-window main must use Qwen"
  Assert-True ($alibaba.group.messages_dispatch_model_config.alibaba_time_window.subagent_model -eq "deepseek-v4-flash-0731") "Alibaba in-window subagents must use the live Flash ID"
  Assert-True ($alibaba.group.messages_dispatch_model_config.alibaba_time_window.out_of_window_model -eq "deepseek-v4-flash-0731") "Alibaba out-of-window traffic must use the live Flash ID"
  Assert-True ($alibaba.group.messages_dispatch_model_config.exact_model_mappings.'deepseek-v4-pro' -eq "deepseek-v4-flash-0731") "Legacy DeepSeek Pro must redirect to the live Flash ID"
  Assert-True ($alibaba.account_model_mapping.'deepseek-v4-flash' -eq "deepseek-v4-flash-0731" -and $alibaba.account_model_mapping.'deepseek-v4-pro' -eq "deepseek-v4-flash-0731") "Alibaba account aliases must normalize to the live Flash ID"
  Assert-True ((@($alibaba.group.models_list_config.models) -notcontains "deepseek-v4-pro") -and (@($alibaba.group.models_list_config.models) -contains "deepseek-v4-flash-0731")) "Alibaba catalog must publish the live Flash ID and hide Pro"

  $controllerText = Get-Content -Raw $controller
  foreach ($needle in @('/api/v1/admin/api-keys/', 'usage_logs', 'Invoke-HeadroomProbe', 'route_switcher_source_fingerprint', 'rollback failed')) {
    Assert-True ($controllerText.Contains($needle)) "Controller contract missing $needle"
  }
  Assert-True ($controllerText.Contains('--profile-path')) "Linux reconcile must use the applier's canonical profile argument"
  Assert-True ($controllerText.Contains('probeNonce')) "Switch and rollback probes must bypass Headroom response-cache reuse"
  Assert-True ($controllerText.Contains('"chatgpt" { Invoke-Switch "chatgpt-only" }')) "Controller must expose the ChatGPT-only switch"
  Assert-True ($controllerText.Contains('"qwen" { Invoke-Switch "qwen-only" }')) "Controller must expose the Qwen-only switch"
  Assert-True ($controllerText.Contains('"alibaba" { Invoke-Switch "alibaba" }')) "Controller must expose the Alibaba Qwen + DeepSeek Flash switch"
  Assert-True ($controllerText.Contains('"alibaba" { "alibaba-qwen-deepseek-flash.v1.json" }')) "Controller must resolve the Alibaba profile snapshot"
  Assert-True ($controllerText.Contains('"qwen-only" { "qwen-only.v1.json" }')) "Controller must resolve the Qwen-only profile snapshot"
  Assert-True ($controllerText.Contains('Ensure-ChatGPTAccount')) "Controller must bind the dedicated ChatGPT OAuth account"
  Assert-True ($controllerText.Contains('Ensure-QwenAccount')) "Controller must bind the dedicated Alibaba Token Plan account"
  Assert-True ($controllerText.Contains('Ensure-HybridAccounts')) "Controller must bind both providers for the hybrid profile"
  Assert-True (-not $controllerText.Contains('provider-route-node-overrides.json')) "Global switches must not permit hidden per-node profile overrides"
  Assert-True ($controllerText.Contains('ManagedFleetKeyNames')) "Controller must keep legacy fleet keys on the global group"
  Assert-True ($controllerText.Contains('Reconcile-WindowsGuest $ProfileRecord $Generation $stableKey.Secret')) "Windows guest must receive the same profile and stable key"
  Assert-True ($controllerText.Contains('Reconcile-LinuxGuest $ProfileRecord $Generation $stableKey.Secret')) "Linux guest must receive the same profile and stable key"
  Assert-True ($controllerText.Contains("`$sourcePortable = `$CodexAuthPath -replace '\\', '/'")) "Controller must normalize the Windows Codex auth path before WSL translation"
  Assert-True ($controllerText.Contains('preserving sub2api-owned OAuth credentials')) "Existing Anthropic account must not require stale local Claude credentials"
  Assert-True ($controllerText.Contains('if ($source) { $updateBody.expires_at')) "Existing account expiry must be preserved when no local OAuth source is available"
  Assert-True ($controllerText.Contains('[Security.SecureString]::new()')) "Windows guest reconcile must construct credentials without lazy module loading"
  Assert-True ($controllerText.Contains('apply-sub2api-qwen-profile.cmd')) "Windows guest reconcile must remove the legacy Qwen-only startup override"
  Assert-True ($controllerText.Contains('legacy_qwen_override_removed')) "Windows guest reconcile must prove the legacy override is absent"
  Assert-True ((Get-Content -Raw (Join-Path $skillRoot 'scripts\install-claude-route.ps1')).Contains('hybrid-current.v1.json')) "Installer must remove the stale unmanaged hybrid v1 snapshot"
  Assert-True ($controllerText.Contains('[Security.Cryptography.SHA256]::Create()')) "Codex auth hashing must not depend on a lazy PowerShell module"
  Assert-True (-not $controllerText.Contains('Get-FileHash')) "Provider controller must not depend on the unavailable Microsoft.PowerShell.Utility hash cmdlet"
  Assert-True ($controllerText.Contains('Get-VMNetworkAdapter -VMName')) "Linux guest reconcile must discover the current Hyper-V address instead of trusting a stale IP"
  Assert-True (-not $controllerText.Contains('ConvertTo-SecureString $password')) "Windows guest reconcile must not depend on a broken PowerShell.Security module"
  Assert-True ($controllerText.Contains('[IO.File]::ReadAllText($statePath, $strictUtf8)')) "Provider state must be decoded as strict UTF-8 instead of the PowerShell 5.1 ANSI default"
  Assert-True ($controllerText.Contains('$maxProviderStateBytes = 1MB')) "Provider state must have a bounded persistence contract"
  Assert-True ($controllerText.Contains('Provider route state exceeded')) "Oversized provider state must be quarantined instead of exhausting the controller process"
  $providerVerifierText = Get-Content -Raw (Join-Path $scriptRoot 'verify-claude-provider-route.ps1')
  Assert-True ($providerVerifierText.Contains("COALESCE(messages_dispatch_model_config->'automatic_model_fallbacks', '{}'::jsonb) = '{}'::jsonb")) "Provider verifier must prove zero automatic fallback"
  Assert-True ($providerVerifierText.Contains('Provider profile state is stale')) "Provider verifier must reject stale profile generations"
  Assert-True ($providerVerifierText.Contains('cc_entrypoint=sdk-cli; cc_is_subagent=true')) "Provider verifier must mark synthetic delegated children structurally"
  Assert-True ($providerVerifierText.Contains('claude-cli/2.1.219 (external, sdk-cli)')) "Provider verifier must exercise the real generic sdk-cli User-Agent"
  Assert-True (-not $providerVerifierText.Contains('agent-sdk/0.3.201')) "Provider verifier must not depend on the absent Agent SDK User-Agent marker"
  Assert-True ((Get-Content -Raw $applier).Contains('SetEnvironmentVariable')) "Windows applier must reconcile user-level env overrides"
  $skillsRoot = Split-Path -Parent $skillRoot
  $setupText = Get-Content -Raw (Join-Path $skillsRoot "sub2api-claude-code-codex\scripts\setup-sub2api-claude-code.ps1")
  $ensureText = Get-Content -Raw (Join-Path $skillsRoot "sub2api-claude-code-codex\scripts\ensure-sub2api-proxy-stack.ps1")
  Assert-True ($setupText.Contains('Join-Path $PSScriptRoot "install-claude-route.ps1"')) "Canonical stack setup must install its bundled provider controller"
  Assert-True (-not $setupText.Contains('claude-provider-switcher\scripts')) "Canonical setup must not depend on the removed standalone skill"
  Assert-True ($ensureText.Contains('.codex\skills\sub2api-claude-code-codex\scripts\claude-route.ps1')) "Watchdog must resolve the controller from the consolidated skill"
  Assert-True ($ensureText.Contains('Invoke-ProviderRouteReconcile')) "The single stack watchdog must own provider generation repair"
  Assert-True ($ensureText.Contains('$sameGeneration = [string]$attemptState.generation -eq $generation')) "A new global profile generation must bypass the old reconcile throttle"
  Assert-True (-not $ensureText.Contains('Sync-HyperVGuestSubagentProfiles')) "Watchdog must not apply a hidden Qwen-only profile outside claude-route"
  Assert-True (-not $ensureText.Contains('HEADROOM_HYPERV_STAGE_QWEN_PROFILE')) "Legacy Hyper-V Qwen staging must not bypass the active provider profile"
  Assert-True ($ensureText.Contains('$stateRoot.StartsWith("/")')) "Watchdog must recognize Linux absolute state roots on Windows"
  Assert-True ($ensureText.Contains("`$sourcePortable = `$source -replace '\\', '/'")) "Watchdog must normalize the Windows Codex auth path before WSL translation"

  $installFixture = Join-Path $temp "install-fixture"
  $installedSkill = Join-Path $installFixture "sub2api-claude-code-codex"
  $installedSafetySkill = Join-Path $installFixture "sub2api-headroom-change-safety"
  $legacySkill = Join-Path $installFixture "claude-provider-switcher"
  $legacyProfileV1 = Join-Path $installedSkill "profiles\anthropic-only.v1.json"
  $legacyProfileV2 = Join-Path $installedSkill "profiles\anthropic-only.v2.json"
  $legacyProfileV3 = Join-Path $installedSkill "profiles\anthropic-only.v3.json"
  $legacyChatGPTV2 = Join-Path $installedSkill "profiles\chatgpt-only.v2.json"
  New-Item -ItemType Directory -Path (Split-Path -Parent $legacyProfileV1), $legacySkill -Force | Out-Null
  [IO.File]::WriteAllText($legacyProfileV1, '{}', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($legacyProfileV2, '{}', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($legacyProfileV3, '{}', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($legacyChatGPTV2, '{}', [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $legacySkill 'SKILL.md'), "---`nname: claude-provider-switcher`n---`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $installedSkill 'stale-managed-file.txt'), 'stale', [Text.UTF8Encoding]::new($false))
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -InstallRoot $installedSkill -SafetyInstallRoot $installedSafetySkill -BinDir (Join-Path $installFixture 'bin') -LegacySkillRoot $legacySkill -SkipPathUpdate -SkipStatus | Out-Null
  Assert-True ($LASTEXITCODE -eq 0) "Consolidated installer fixture must succeed"
  Assert-True (Test-Path -LiteralPath (Join-Path $installedSkill 'profiles\anthropic-only.v4.json')) "Installer must copy Anthropic profile v4"
  Assert-True (Test-Path -LiteralPath (Join-Path $installedSkill 'profiles\chatgpt-only.v5.json')) "Installer must copy ChatGPT-only profile v5"
  Assert-True (Test-Path -LiteralPath (Join-Path $installedSkill 'profiles\qwen-only.v1.json')) "Installer must copy Qwen-only profile v1"
  Assert-True (Test-Path -LiteralPath (Join-Path $installedSkill 'profiles\alibaba-qwen-deepseek-flash.v1.json')) "Installer must copy the Alibaba profile"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $installedSkill 'profiles\chatgpt-only.v3.json'))) "Installer must remove legacy ChatGPT-only profile v3"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $installedSkill 'profiles\chatgpt-only.v4.json'))) "Installer must remove legacy ChatGPT-only profile v4"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $installedSkill 'profiles\chatgpt-only.v2.json'))) "Installer must remove legacy ChatGPT-only profile v2"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $installedSkill 'profiles\chatgpt-only.v1.json'))) "Installer must remove legacy ChatGPT-only profile v1"
  Assert-True (-not (Test-Path -LiteralPath $legacyProfileV1)) "Installer must remove stale Anthropic profile v1"
  Assert-True (-not (Test-Path -LiteralPath $legacyProfileV2)) "Installer must remove stale Anthropic profile v2"
  Assert-True (-not (Test-Path -LiteralPath $legacyProfileV3)) "Installer must remove stale Anthropic profile v3"
  Assert-True (-not (Test-Path -LiteralPath $legacySkill)) "Installer must remove the managed standalone provider skill"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $installedSkill 'stale-managed-file.txt'))) "Installer must mirror source instead of retaining stale managed files"
  Assert-True (Test-Path -LiteralPath (Join-Path $installedSafetySkill 'SKILL.md')) "Installer must install the change-safety skill from the same checkout"

  [pscustomobject]@{ status = "PASS"; assertions = 199; profiles = @("anthropic-only", "qwen-only", "alibaba", "chatgpt-only", "hybrid-current") } | ConvertTo-Json -Compress
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

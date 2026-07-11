param(
  [string]$RepoRoot = "",
  [string]$ProjectName = "sub2api-codex",
  [int]$HeadroomPort = 8787,
  [int]$Sub2apiPort = 18081,
  [string]$HeadroomBindHost = "127.0.0.1",
  [string]$Sub2apiBindHost = "127.0.0.1",
  [string]$BaseUrl = "",
  [string]$AdminEmail = "admin@sub2api.local",
  [string]$TimeZone = "Europe/Moscow",
  [string]$Model = "gpt-5.6-sol",
  [string]$SmallFastModel = "gpt-5.3-codex-spark",
  [string]$DefaultHaikuModel = "gpt-5.6-terra-high",
  [string]$SubagentModel = "gpt-5.6-terra-high",
  [string]$SubagentEffort = "high",
  [ValidateSet("auto", "low", "medium", "high", "xhigh", "max")]
  [string]$DefaultEffort = "xhigh",
  [int]$MaxContextTokens = 370000,
  [int]$AutoCompactWindow = 340000,
  [int]$MaxOutputTokens = 64000,
  [int]$MaxThinkingTokens = 8000,
  [string]$HeadroomVersion = "0.31.0",
  [string]$HeadroomPythonVersion = "3.12",
  [string]$HeadroomSavingsProfile = "agent-90",
  [string]$HeadroomTargetRatio = "0.10",
  [string]$Sub2apiImage = "sub2api-codex:local-token-usage",
  [string]$ApiKey = "",
  [switch]$ForceRegenerateSecrets,
  [switch]$SkipDockerUp,
  [switch]$SkipClaudeConfig,
  [switch]$SkipGeneralPurposeAgent,
  [switch]$SkipHeadroomMcp
)

$ErrorActionPreference = "Stop"

# Claude Code should use Headroom, not the direct sub2api admin/diagnostic port:
#   Claude Code -> http://127.0.0.1:8787 -> Headroom -> http://sub2api:8080
# sub2api remains published on 18081 for the admin UI and direct diagnostics.

function New-Secret([int]$Bytes = 32) {
  $buffer = New-Object byte[] $Bytes
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    $rng.GetBytes($buffer)
  } finally {
    $rng.Dispose()
  }
  [Convert]::ToBase64String($buffer).TrimEnd("=") -replace "\+", "-" -replace "/", "_"
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function ConvertTo-WslPath([string]$Path) {
  $resolved = Resolve-Path -LiteralPath $Path
  $escaped = $resolved.Path.Replace("\", "\\").Replace("'", "'\''")
  (wsl.exe -- bash -lc "wslpath -a '$escaped'").Trim()
}

function Get-ObjectProperty([object]$Object, [string]$Name) {
  if ($null -eq $Object) { return $null }
  $property = $Object.PSObject.Properties[$Name]
  if ($property) { return $property.Value }
  return $null
}

function Set-ObjectProperty([object]$Object, [string]$Name, [object]$Value) {
  if ($Object.PSObject.Properties[$Name]) {
    $Object.PSObject.Properties[$Name].Value = $Value
  } else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Remove-ObjectProperty([object]$Object, [string]$Name) {
  if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) {
    $Object.PSObject.Properties.Remove($Name)
  }
}

function Find-RepoRoot {
  if ($RepoRoot.Trim()) {
    return (Resolve-Path -LiteralPath $RepoRoot).Path
  }

  $starts = @()
  if ($PSScriptRoot) { $starts += $PSScriptRoot }
  $starts += (Get-Location).ProviderPath

  foreach ($start in $starts) {
    $dir = (Resolve-Path -LiteralPath $start).Path
    while ($dir) {
      $candidate = Join-Path $dir "deploy\claude-code-codex-headroom\docker-compose.yml"
      if (Test-Path -LiteralPath $candidate) { return $dir }
      $parent = Split-Path -Parent $dir
      if (-not $parent -or $parent -eq $dir) { break }
      $dir = $parent
    }
  }

  throw "Could not find deploy\claude-code-codex-headroom\docker-compose.yml. Run from a cloned sub2api repo or pass -RepoRoot."
}

function Read-DotEnv([string]$Path) {
  $map = [ordered]@{}
  if (-not (Test-Path -LiteralPath $Path)) { return $map }
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
    $name, $value = $line -split '=', 2
    $map[$name.Trim()] = $value.Trim()
  }
  return $map
}

function Set-DotEnvValue([System.Collections.IDictionary]$Map, [string]$Name, [string]$Value, [switch]$OnlyIfMissing) {
  if ($OnlyIfMissing -and $Map.Contains($Name) -and $Map[$Name]) { return }
  $Map[$Name] = $Value
}

function Write-DotEnv([System.Collections.IDictionary]$Map, [string]$Path) {
  $order = @(
    "HEADROOM_VERSION",
    "HEADROOM_PYTHON_VERSION",
    "HEADROOM_BIND_HOST",
    "HEADROOM_PORT",
    "HEADROOM_SAVINGS_PROFILE",
    "HEADROOM_TARGET_RATIO",
    "HEADROOM_FORCE_KOMPRESS",
    "HEADROOM_ACCURACY_GUARD",
    "HEADROOM_CODE_AWARE_ENABLED",
    "HEADROOM_CONTEXT_TOOL",
    "HEADROOM_RTK_GAIN_SCOPE",
    "HEADROOM_COMPRESS_USER_MESSAGES",
    "HEADROOM_COMPRESS_SYSTEM_MESSAGES",
    "HEADROOM_PROTECT_ANALYSIS_CONTEXT",
    "HEADROOM_PROTECT_READS",
    "HEADROOM_PROTECT_RECENT",
    "HEADROOM_MIN_TOKENS",
    "HEADROOM_MAX_ITEMS",
    "HEADROOM_DEDUPE",
    "HEADROOM_TOOL_SEARCH",
    "HEADROOM_LOSSLESS_THEN_LOSSY",
    "HEADROOM_OUTPUT_SHAPER",
    "HEADROOM_OUTPUT_HOLDOUT",
    "HEADROOM_REQUEST_TIMEOUT_SECONDS",
    "HEADROOM_ANTHROPIC_PRE_UPSTREAM_CONCURRENCY",
    "HEADROOM_COMPRESSION_MAX_WORKERS",
    "HEADROOM_KOMPRESS_EXECUTION_TIMEOUT_MS",
    "HEADROOM_COMPRESSION_TIMEOUT_SECONDS",
    "HEADROOM_COMPRESSION_DEADLINE_MS",
    "HEADROOM_KOMPRESS_MAX_CONCURRENT",
    "HEADROOM_KOMPRESS_ONNX_INTRA_THREADS",
    "HEADROOM_KOMPRESS_ONNX_INTER_THREADS",
    "HEADROOM_KOMPRESS_BATCH_SIZE",
    "SUB2API_BIND_HOST",
    "SUB2API_PORT",
    "SUB2API_IMAGE",
    "SUB2API_BUILD_CONTEXT",
    "SUB2API_DOCKERFILE",
    "TZ",
    "RUN_MODE",
    "SIMPLE_MODE_CONFIRM",
    "SERVER_MODE",
    "LOG_LEVEL",
    "DATA_DIR",
    "SECURITY_URL_ALLOWLIST_ENABLED",
    "SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP",
    "SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS",
    "ADMIN_EMAIL",
    "ADMIN_PASSWORD",
    "JWT_SECRET",
    "JWT_EXPIRE_HOUR",
    "TOTP_ENCRYPTION_KEY",
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
    "POSTGRES_DB",
    "DATABASE_MAX_OPEN_CONNS",
    "DATABASE_MAX_IDLE_CONNS",
    "DATABASE_CONN_MAX_LIFETIME_MINUTES",
    "DATABASE_CONN_MAX_IDLE_TIME_MINUTES",
    "REDIS_PASSWORD",
    "REDIS_DB",
    "REDIS_POOL_SIZE",
    "REDIS_MIN_IDLE_CONNS",
    "REDIS_ENABLE_TLS"
  )

  $lines = @(
    "# Generated by backend/docs/skills/sub2api-claude-code-codex/scripts/setup-sub2api-claude-code.ps1",
    "# Claude Code endpoint: http://127.0.0.1:8787",
    "# sub2api direct endpoint: http://127.0.0.1:18081 for admin UI and diagnostics",
    ""
  )
  foreach ($key in $order) {
    if ($Map.Contains($key)) { $lines += "$key=$($Map[$key])" }
  }
  foreach ($key in $Map.Keys) {
    if ($order -notcontains $key) { $lines += "$key=$($Map[$key])" }
  }
  Write-Utf8NoBom -Path $Path -Content (($lines -join "`n") + "`n")
}

$resolvedRepoRoot = Find-RepoRoot
$profileDir = Join-Path $resolvedRepoRoot "deploy\claude-code-codex-headroom"
$composePath = Join-Path $profileDir "docker-compose.yml"
$envPath = Join-Path $profileDir ".env"

if (-not (Test-Path -LiteralPath $composePath)) {
  throw "Missing compose profile: $composePath"
}

$ClaudeBaseUrl = if ($BaseUrl.Trim()) { $BaseUrl.Trim().TrimEnd("/") } else { "http://127.0.0.1`:$HeadroomPort" }

$envMap = Read-DotEnv -Path $envPath
if ((Test-Path -LiteralPath $envPath) -and -not $ForceRegenerateSecrets) {
  Copy-Item -LiteralPath $envPath -Destination "$envPath.bak-sub2api-$(Get-Date -Format yyyyMMddHHmmss)"
}

Set-DotEnvValue $envMap "HEADROOM_VERSION" $HeadroomVersion
Set-DotEnvValue $envMap "HEADROOM_PYTHON_VERSION" $HeadroomPythonVersion
Set-DotEnvValue $envMap "HEADROOM_BIND_HOST" $HeadroomBindHost
Set-DotEnvValue $envMap "HEADROOM_PORT" ([string]$HeadroomPort)
Set-DotEnvValue $envMap "HEADROOM_SAVINGS_PROFILE" $HeadroomSavingsProfile
Set-DotEnvValue $envMap "HEADROOM_TARGET_RATIO" $HeadroomTargetRatio
Set-DotEnvValue $envMap "HEADROOM_FORCE_KOMPRESS" "1"
Set-DotEnvValue $envMap "HEADROOM_ACCURACY_GUARD" "strict"
Set-DotEnvValue $envMap "HEADROOM_CODE_AWARE_ENABLED" "1"
Set-DotEnvValue $envMap "HEADROOM_CONTEXT_TOOL" "rtk"
Set-DotEnvValue $envMap "HEADROOM_RTK_GAIN_SCOPE" "global"
Set-DotEnvValue $envMap "HEADROOM_COMPRESS_USER_MESSAGES" "1"
Set-DotEnvValue $envMap "HEADROOM_COMPRESS_SYSTEM_MESSAGES" "1"
Set-DotEnvValue $envMap "HEADROOM_PROTECT_ANALYSIS_CONTEXT" "1"
Set-DotEnvValue $envMap "HEADROOM_PROTECT_READS" "0"
Set-DotEnvValue $envMap "HEADROOM_PROTECT_RECENT" "2"
Set-DotEnvValue $envMap "HEADROOM_MIN_TOKENS" "120"
Set-DotEnvValue $envMap "HEADROOM_MAX_ITEMS" "8"
Set-DotEnvValue $envMap "HEADROOM_DEDUPE" "0"
Set-DotEnvValue $envMap "HEADROOM_TOOL_SEARCH" "0"
Set-DotEnvValue $envMap "HEADROOM_LOSSLESS_THEN_LOSSY" "0"
Set-DotEnvValue $envMap "HEADROOM_OUTPUT_SHAPER" "1"
Set-DotEnvValue $envMap "HEADROOM_OUTPUT_HOLDOUT" "0"
Set-DotEnvValue $envMap "HEADROOM_REQUEST_TIMEOUT_SECONDS" "900"
Set-DotEnvValue $envMap "HEADROOM_ANTHROPIC_PRE_UPSTREAM_CONCURRENCY" "8"
Set-DotEnvValue $envMap "HEADROOM_COMPRESSION_MAX_WORKERS" "2"
Set-DotEnvValue $envMap "HEADROOM_KOMPRESS_EXECUTION_TIMEOUT_MS" "60000"
Set-DotEnvValue $envMap "HEADROOM_COMPRESSION_TIMEOUT_SECONDS" "120"
Set-DotEnvValue $envMap "HEADROOM_COMPRESSION_DEADLINE_MS" "90000"
Set-DotEnvValue $envMap "HEADROOM_KOMPRESS_MAX_CONCURRENT" "2"
Set-DotEnvValue $envMap "HEADROOM_KOMPRESS_ONNX_INTRA_THREADS" "2"
Set-DotEnvValue $envMap "HEADROOM_KOMPRESS_ONNX_INTER_THREADS" "1"
Set-DotEnvValue $envMap "HEADROOM_KOMPRESS_BATCH_SIZE" "16"
Set-DotEnvValue $envMap "SUB2API_BIND_HOST" $Sub2apiBindHost
Set-DotEnvValue $envMap "SUB2API_PORT" ([string]$Sub2apiPort)
Set-DotEnvValue $envMap "SUB2API_IMAGE" $Sub2apiImage
Set-DotEnvValue $envMap "SUB2API_BUILD_CONTEXT" "../.."
Set-DotEnvValue $envMap "SUB2API_DOCKERFILE" "Dockerfile"
Set-DotEnvValue $envMap "TZ" $TimeZone
Set-DotEnvValue $envMap "RUN_MODE" "simple"
Set-DotEnvValue $envMap "SIMPLE_MODE_CONFIRM" "true"
Set-DotEnvValue $envMap "SERVER_MODE" "release"
Set-DotEnvValue $envMap "LOG_LEVEL" "info"
Set-DotEnvValue $envMap "DATA_DIR" "/app/data"
Set-DotEnvValue $envMap "SECURITY_URL_ALLOWLIST_ENABLED" "false"
Set-DotEnvValue $envMap "SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP" "true"
Set-DotEnvValue $envMap "SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS" "true"
Set-DotEnvValue $envMap "ADMIN_EMAIL" $AdminEmail
Set-DotEnvValue $envMap "JWT_EXPIRE_HOUR" "24"
Set-DotEnvValue $envMap "POSTGRES_USER" "sub2api"
Set-DotEnvValue $envMap "POSTGRES_DB" "sub2api"
Set-DotEnvValue $envMap "DATABASE_MAX_OPEN_CONNS" "50"
Set-DotEnvValue $envMap "DATABASE_MAX_IDLE_CONNS" "10"
Set-DotEnvValue $envMap "DATABASE_CONN_MAX_LIFETIME_MINUTES" "30"
Set-DotEnvValue $envMap "DATABASE_CONN_MAX_IDLE_TIME_MINUTES" "5"
Set-DotEnvValue $envMap "REDIS_DB" "0"
Set-DotEnvValue $envMap "REDIS_POOL_SIZE" "256"
Set-DotEnvValue $envMap "REDIS_MIN_IDLE_CONNS" "10"
Set-DotEnvValue $envMap "REDIS_ENABLE_TLS" "false"

Set-DotEnvValue $envMap "ADMIN_PASSWORD" (New-Secret 24) -OnlyIfMissing:(!$ForceRegenerateSecrets)
Set-DotEnvValue $envMap "JWT_SECRET" (New-Secret 48) -OnlyIfMissing:(!$ForceRegenerateSecrets)
Set-DotEnvValue $envMap "TOTP_ENCRYPTION_KEY" (New-Secret 32) -OnlyIfMissing:(!$ForceRegenerateSecrets)
Set-DotEnvValue $envMap "POSTGRES_PASSWORD" (New-Secret 24) -OnlyIfMissing:(!$ForceRegenerateSecrets)
Set-DotEnvValue $envMap "REDIS_PASSWORD" (New-Secret 24) -OnlyIfMissing:(!$ForceRegenerateSecrets)

Write-DotEnv -Map $envMap -Path $envPath

if (-not $SkipDockerUp) {
  if (Get-Command docker -ErrorAction SilentlyContinue) {
    Push-Location $profileDir
    try {
      docker compose --env-file .env -f docker-compose.yml -p $ProjectName up -d --build
    } finally {
      Pop-Location
    }
  } elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    $wslProfileDir = ConvertTo-WslPath $profileDir
    wsl.exe -- bash -lc "cd '$wslProfileDir' && docker compose --env-file .env -f docker-compose.yml -p '$ProjectName' up -d --build"
  } else {
    throw "Neither docker nor wsl.exe was found. Install Docker Desktop or run docker compose manually in $profileDir."
  }
}

if (-not $SkipClaudeConfig) {
  $settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
  New-Item -ItemType Directory -Force -Path (Split-Path $settingsPath) | Out-Null
  if (Test-Path $settingsPath) {
    Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.bak-sub2api-$(Get-Date -Format yyyyMMddHHmmss)"
    $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
  } else {
    $settings = [pscustomobject]@{}
  }
  if (-not (Get-ObjectProperty $settings "env")) {
    Set-ObjectProperty $settings "env" ([pscustomobject]@{})
  }

  $userToken = [Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "User")
  $settingsToken = Get-ObjectProperty $settings.env "ANTHROPIC_AUTH_TOKEN"
  if ($ApiKey.Trim()) {
    Set-ObjectProperty $settings.env "ANTHROPIC_AUTH_TOKEN" $ApiKey.Trim()
    [Environment]::SetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", $ApiKey.Trim(), "User")
  } elseif (-not $settingsToken -and $userToken) {
    Set-ObjectProperty $settings.env "ANTHROPIC_AUTH_TOKEN" $userToken
  } elseif ($settingsToken -and -not $userToken) {
    [Environment]::SetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", [string]$settingsToken, "User")
  }

  Set-ObjectProperty $settings "model" $Model
  Set-ObjectProperty $settings "effortLevel" $DefaultEffort
  Set-ObjectProperty $settings.env "ANTHROPIC_BASE_URL" $ClaudeBaseUrl
  Set-ObjectProperty $settings.env "ANTHROPIC_MODEL" $Model
  Set-ObjectProperty $settings.env "ANTHROPIC_DEFAULT_HAIKU_MODEL" $DefaultHaikuModel
  Set-ObjectProperty $settings.env "ANTHROPIC_SMALL_FAST_MODEL" $SmallFastModel
  Set-ObjectProperty $settings.env "CLAUDE_CODE_SUBAGENT_MODEL" $SubagentModel
  Set-ObjectProperty $settings.env "CLAUDE_CODE_MAX_CONTEXT_TOKENS" ([string]$MaxContextTokens)
  Set-ObjectProperty $settings.env "CLAUDE_CODE_AUTO_COMPACT_WINDOW" ([string]$AutoCompactWindow)
  Set-ObjectProperty $settings.env "CLAUDE_CODE_MAX_OUTPUT_TOKENS" ([string]$MaxOutputTokens)
  Set-ObjectProperty $settings.env "MAX_THINKING_TOKENS" ([string]$MaxThinkingTokens)
  Set-ObjectProperty $settings.env "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "1"
  Set-ObjectProperty $settings.env "CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK" "1"
  Remove-ObjectProperty $settings.env "CLAUDE_CODE_EFFORT_LEVEL"
  $settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $settingsPath -Encoding UTF8

  [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $ClaudeBaseUrl, "User")
  [Environment]::SetEnvironmentVariable("ANTHROPIC_MODEL", $Model, "User")
  [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_HAIKU_MODEL", $DefaultHaikuModel, "User")
  [Environment]::SetEnvironmentVariable("ANTHROPIC_SMALL_FAST_MODEL", $SmallFastModel, "User")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_SUBAGENT_MODEL", $SubagentModel, "User")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_MAX_CONTEXT_TOKENS", [string]$MaxContextTokens, "User")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_AUTO_COMPACT_WINDOW", [string]$AutoCompactWindow, "User")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_MAX_OUTPUT_TOKENS", [string]$MaxOutputTokens, "User")
  [Environment]::SetEnvironmentVariable("MAX_THINKING_TOKENS", [string]$MaxThinkingTokens, "User")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1", "User")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK", "1", "User")
  try {
    [Environment]::SetEnvironmentVariable("CLAUDE_CODE_EFFORT_LEVEL", $null, "User")
  } catch {
    Write-Warning "Could not clear user CLAUDE_CODE_EFFORT_LEVEL: $($_.Exception.Message)"
  }

  $globalConfigPath = Join-Path $env:USERPROFILE ".claude.json"
  if (Test-Path $globalConfigPath) {
    Copy-Item -LiteralPath $globalConfigPath -Destination "$globalConfigPath.bak-sub2api-$(Get-Date -Format yyyyMMddHHmmss)"
    try {
      $globalConfig = Get-Content -Raw -LiteralPath $globalConfigPath | ConvertFrom-Json
      Set-ObjectProperty $globalConfig "workflowSizeGuideline" "small"
      $globalConfig | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $globalConfigPath -Encoding UTF8
    } catch {
      Write-Warning "Could not update $globalConfigPath as JSON: $($_.Exception.Message)"
    }
  }

  if (-not $SkipGeneralPurposeAgent) {
    $agentsDir = Join-Path $env:USERPROFILE ".claude\agents"
    New-Item -ItemType Directory -Force -Path $agentsDir | Out-Null

    function Set-ClaudeAgentOverride {
      param(
        [string]$Name,
        [string]$Description,
        [string]$Body
      )

      $agentPath = Join-Path $agentsDir "$Name.md"
      if (Test-Path -LiteralPath $agentPath) {
        $agentText = Get-Content -LiteralPath $agentPath -Raw
      } else {
        $agentText = @"
---
name: $Name
description: $Description
model: $SubagentModel
effort: $SubagentEffort
---

$Body
"@
      }

      if ($agentText -match "(?ms)^---\s.*?\s---") {
        if ($agentText -match "(?m)^model:\s*.+$") {
          $agentText = $agentText -replace "(?m)^model:\s*.+$", "model: $SubagentModel"
        } else {
          $agentText = $agentText -replace "(?m)^description: .+$", "`$0`nmodel: $SubagentModel"
        }
        if ($agentText -match "(?m)^effort:\s*.+$") {
          $agentText = $agentText -replace "(?m)^effort:\s*.+$", "effort: $SubagentEffort"
        } else {
          $agentText = $agentText -replace "(?m)^model:\s*.+$", "`$0`neffort: $SubagentEffort"
        }
      } else {
        $agentText = "---`nname: $Name`ndescription: $Description`nmodel: $SubagentModel`neffort: $SubagentEffort`n---`n`n$agentText"
      }
      Set-Content -LiteralPath $agentPath -Value $agentText -Encoding UTF8
    }

    Set-ClaudeAgentOverride "general-purpose" `
      "General-purpose agent for complex multi-step work that needs exploration, edits, command execution, or verification. User override pins the model to GPT-5.6 Terra with high effort while Spark is quota-limited." `
      "You are the general-purpose Claude Code subagent.`n`nHandle the delegated task end to end inside your own context. Use tools when needed, keep scope tight, and return only the result the parent needs.`n`nDelegation guardrails:`n- Treat GPT-5.6 Terra high effort as the default model profile for delegated general-purpose work.`n- Do not launch more than 10 sibling subagents for one task.`n- Do not create agent chains deeper than two subagent levels below the lead session.`n- If a task needs more breadth or depth, summarize the remaining slices instead of spawning more agents.`n`nGround investigative answers in concrete file paths, commands, logs, or test results."

    Set-ClaudeAgentOverride "Explore" `
      "Exploration subagent for repository, log, transcript, and design-space investigation. User override pins this built-in workflow agent to GPT-5.6 Terra high effort." `
      "You are the Explore Claude Code subagent.`n`nInvestigate the delegated question in your own context and return only the evidence and conclusion the parent needs. Prefer concrete proof from files, logs, transcripts, commands, and observed runtime state over broad narrative.`n`nUse tools when they materially improve the answer, but keep the scope bounded. When the task is too broad for one pass, summarize the most important findings and name the exact remaining slices instead of recursively expanding the work."

    Set-ClaudeAgentOverride "workflow-subagent" `
      "Claude Code workflow subagent override. Pins generated workflow worker agents to GPT-5.6 Terra high effort on the local proxy profile." `
      "You are the workflow-subagent Claude Code worker.`n`nExecute the delegated workflow slice in your own context and return only the specific result the parent workflow needs. Keep the scope bounded, prefer concrete evidence from files, commands, logs, and tests, and avoid expanding a small slice into a broad investigation."
  }

  if (-not $SkipHeadroomMcp) {
    if ((Get-Command claude -ErrorAction SilentlyContinue) -and (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
      try {
        & claude mcp remove headroom -s user *> $null
      } catch {}
      try {
        & claude mcp remove tokensave -s user *> $null
      } catch {}
      & claude mcp add headroom -s user -- wsl.exe -e docker exec -i headroom-sub2api headroom mcp serve --proxy-url "http://127.0.0.1:8787"
    } else {
      Write-Warning "Could not configure Docker-backed Headroom MCP because claude or wsl.exe was not found."
    }
  }
}

Write-Host "repo root: $resolvedRepoRoot"
Write-Host "compose profile: $profileDir"
Write-Host "compose project: $ProjectName"
Write-Host "Headroom: http://$HeadroomBindHost`:$HeadroomPort -> http://sub2api:8080"
Write-Host "sub2api admin/diagnostics: http://$Sub2apiBindHost`:$Sub2apiPort"
Write-Host "Claude base URL: $ClaudeBaseUrl"
Write-Host "sub2api image: $Sub2apiImage"
Write-Host "Headroom image: headroom-sub2api:$HeadroomVersion"
Write-Host "Headroom savings profile: $HeadroomSavingsProfile (target ratio $HeadroomTargetRatio)"
Write-Host "Headroom embedding server: enabled (--embedding-server with patched watchdog/socket client)"
Write-Host "model: $Model"
Write-Host "default effort: $DefaultEffort (use /effort inside Claude Code to change per session)"
Write-Host "small-fast model: $SmallFastModel"
Write-Host "default Haiku model: $DefaultHaikuModel"
Write-Host "subagent model/effort: $SubagentModel / $SubagentEffort"
Write-Host "max context: $MaxContextTokens"
Write-Host "auto compact: $AutoCompactWindow"
Write-Host "admin email: $AdminEmail"
Write-Host "admin password is in: $envPath"
Write-Host "Next: open http://$Sub2apiBindHost`:$Sub2apiPort, import Codex OAuth, create an API key, and set ANTHROPIC_AUTH_TOKEN if it is not already set."

param(
  [string]$RuntimeDir = "$PWD\sub2api-runtime",
  [int]$Port = 18081,
  [string]$BindHost = "0.0.0.0",
  [string]$BaseUrl = "",
  [string]$AdminEmail = "admin@sub2api.local",
  [string]$TimeZone = "Europe/Moscow",
  [string]$Model = "gpt-5.6-sol",
  [string]$SmallFastModel = "gpt-5.3-codex-spark",
  [int]$MaxContextTokens = 1050000,
  [int]$AutoCompactWindow = 1000000,
  [int]$MaxOutputTokens = 64000,
  [int]$MaxThinkingTokens = 8000,
  [string]$Sub2apiImage = "sub2api-codex:local-token-usage",
  [switch]$ForceRegenerateSecrets,
  [switch]$SkipDockerUp,
  [switch]$SkipClaudeConfig
)

$ErrorActionPreference = "Stop"

# Claude Code needs explicit context hints for custom/proxy models; otherwise
# it falls back to a 200k display/planning window. GPT-5.6 Sol/Terra/Luna are
# configured locally with a 1.05M input window, so auto-compact keeps a 50k
# buffer below that edge.

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
  $escaped = $resolved.Path.Replace("\", "\\")
  (wsl.exe -- bash -lc "wslpath -a '$escaped'").Trim()
}

$hasWsl = [bool](Get-Command wsl.exe -ErrorAction SilentlyContinue)

function Get-WslPrimaryIp {
  if (-not $hasWsl) { return "" }
  try {
    return (wsl.exe -- bash -lc "ip -4 addr show eth0 | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1").Trim()
  } catch {
    return ""
  }
}

function Resolve-ClaudeBaseUrl {
  if ($BaseUrl.Trim()) { return $BaseUrl.Trim().TrimEnd("/") }
  if ($BindHost -eq "0.0.0.0" -or $BindHost -eq "::") {
    $wslIp = Get-WslPrimaryIp
    if ($wslIp) { return "http://$wslIp`:$Port" }
    return "http://127.0.0.1`:$Port"
  }
  return "http://$BindHost`:$Port"
}

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null

$ClaudeBaseUrl = Resolve-ClaudeBaseUrl

$postgresPassword = New-Secret
$redisPassword = New-Secret
$adminPassword = New-Secret
$jwtSecret = New-Secret 48
$totpKey = New-Secret 32

$envContent = @"
BIND_HOST=$BindHost
SERVER_PORT=$Port
SERVER_MODE=release
RUN_MODE=simple
SIMPLE_MODE_CONFIRM=true
TZ=$TimeZone

POSTGRES_USER=sub2api
POSTGRES_PASSWORD=$postgresPassword
POSTGRES_DB=sub2api

REDIS_PASSWORD=$redisPassword
REDIS_DB=0

ADMIN_EMAIL=$AdminEmail
ADMIN_PASSWORD=$adminPassword

JWT_SECRET=$jwtSecret
JWT_EXPIRE_HOUR=24
TOTP_ENCRYPTION_KEY=$totpKey

SECURITY_URL_ALLOWLIST_ENABLED=false
SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP=true
SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS=true

DATABASE_MAX_OPEN_CONNS=50
DATABASE_MAX_IDLE_CONNS=10
DATABASE_CONN_MAX_LIFETIME_MINUTES=30
DATABASE_CONN_MAX_IDLE_TIME_MINUTES=5
REDIS_POOL_SIZE=256
REDIS_MIN_IDLE_CONNS=10
REDIS_ENABLE_TLS=false
"@

$composeContent = @"
services:
  sub2api:
    image: $Sub2apiImage
    container_name: sub2api-codex
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 100000
        hard: 100000
    ports:
      - "`${BIND_HOST:-127.0.0.1}:`${SERVER_PORT:-18081}:8080"
    volumes:
      - ./data:/app/data
    environment:
      - AUTO_SETUP=true
      - SERVER_HOST=0.0.0.0
      - SERVER_PORT=8080
      - SERVER_MODE=`${SERVER_MODE:-release}
      - RUN_MODE=`${RUN_MODE:-simple}
      - SIMPLE_MODE_CONFIRM=`${SIMPLE_MODE_CONFIRM:-true}
      - DATABASE_HOST=postgres
      - DATABASE_PORT=5432
      - DATABASE_USER=`${POSTGRES_USER:-sub2api}
      - DATABASE_PASSWORD=`${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
      - DATABASE_DBNAME=`${POSTGRES_DB:-sub2api}
      - DATABASE_SSLMODE=disable
      - REDIS_HOST=redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=`${REDIS_PASSWORD:-}
      - REDIS_DB=`${REDIS_DB:-0}
      - ADMIN_EMAIL=`${ADMIN_EMAIL:-admin@sub2api.local}
      - ADMIN_PASSWORD=`${ADMIN_PASSWORD:-}
      - JWT_SECRET=`${JWT_SECRET:-}
      - JWT_EXPIRE_HOUR=`${JWT_EXPIRE_HOUR:-24}
      - TOTP_ENCRYPTION_KEY=`${TOTP_ENCRYPTION_KEY:-}
      - TZ=`${TZ:-Europe/Moscow}
      - SECURITY_URL_ALLOWLIST_ENABLED=`${SECURITY_URL_ALLOWLIST_ENABLED:-false}
      - SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP=`${SECURITY_URL_ALLOWLIST_ALLOW_INSECURE_HTTP:-true}
      - SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS=`${SECURITY_URL_ALLOWLIST_ALLOW_PRIVATE_HOSTS:-true}
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - sub2api-codex-network
    healthcheck:
      test: ["CMD", "wget", "-q", "-T", "5", "-O", "/dev/null", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  postgres:
    image: postgres:18-alpine
    container_name: sub2api-codex-postgres
    restart: unless-stopped
    volumes:
      - sub2api-codex-postgres-data:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=`${POSTGRES_USER:-sub2api}
      - POSTGRES_PASSWORD=`${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}
      - POSTGRES_DB=`${POSTGRES_DB:-sub2api}
      - PGDATA=/var/lib/postgresql/data
      - TZ=`${TZ:-Europe/Moscow}
    networks:
      - sub2api-codex-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U `${POSTGRES_USER:-sub2api} -d `${POSTGRES_DB:-sub2api}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

  redis:
    image: redis:8-alpine
    container_name: sub2api-codex-redis
    restart: unless-stopped
    volumes:
      - sub2api-codex-redis-data:/data
    command: >
      sh -c '
        redis-server
        --save 60 1
        --appendonly yes
        --appendfsync everysec
        `${REDIS_PASSWORD:+--requirepass "`$REDIS_PASSWORD"}'
    environment:
      - TZ=`${TZ:-Europe/Moscow}
      - REDISCLI_AUTH=`${REDIS_PASSWORD:-}
    networks:
      - sub2api-codex-network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 5s

networks:
  sub2api-codex-network:
    driver: bridge

volumes:
  sub2api-codex-postgres-data:
  sub2api-codex-redis-data:
"@

$envPath = Join-Path $RuntimeDir ".env"
$composePath = Join-Path $RuntimeDir "docker-compose.yml"

if ((Test-Path $envPath) -and -not $ForceRegenerateSecrets) {
  Write-Host "Existing .env preserved: $envPath"
} else {
  if (Test-Path $envPath) {
    Copy-Item -LiteralPath $envPath -Destination "$envPath.bak-$(Get-Date -Format yyyyMMddHHmmss)"
  }
  Write-Utf8NoBom -Path $envPath -Content $envContent
}

if (Test-Path $composePath) {
  Copy-Item -LiteralPath $composePath -Destination "$composePath.bak-$(Get-Date -Format yyyyMMddHHmmss)"
}
Write-Utf8NoBom -Path $composePath -Content $composeContent

if (-not $SkipDockerUp) {
  if ($hasWsl) {
    $wslRuntime = ConvertTo-WslPath $RuntimeDir
    wsl.exe -- bash -lc "cd '$wslRuntime' && docker compose up -d"
  } else {
    Push-Location $RuntimeDir
    try { docker compose up -d } finally { Pop-Location }
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
  if (-not $settings.env) {
    $settings | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $settings | Add-Member -NotePropertyName model -NotePropertyValue $Model -Force
  $settings | Add-Member -NotePropertyName effortLevel -NotePropertyValue "max" -Force
  $settings.env | Add-Member -NotePropertyName ANTHROPIC_BASE_URL -NotePropertyValue $ClaudeBaseUrl -Force
  $settings.env | Add-Member -NotePropertyName ANTHROPIC_MODEL -NotePropertyValue $Model -Force
  $settings.env | Add-Member -NotePropertyName ANTHROPIC_DEFAULT_HAIKU_MODEL -NotePropertyValue $SmallFastModel -Force
  $settings.env | Add-Member -NotePropertyName ANTHROPIC_SMALL_FAST_MODEL -NotePropertyValue $SmallFastModel -Force
  $settings.env | Add-Member -NotePropertyName CLAUDE_CODE_MAX_CONTEXT_TOKENS -NotePropertyValue ([string]$MaxContextTokens) -Force
  $settings.env | Add-Member -NotePropertyName CLAUDE_CODE_AUTO_COMPACT_WINDOW -NotePropertyValue ([string]$AutoCompactWindow) -Force
  $settings.env | Add-Member -NotePropertyName CLAUDE_CODE_MAX_OUTPUT_TOKENS -NotePropertyValue ([string]$MaxOutputTokens) -Force
  $settings.env | Add-Member -NotePropertyName MAX_THINKING_TOKENS -NotePropertyValue ([string]$MaxThinkingTokens) -Force
  $settings.env | Add-Member -NotePropertyName CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC -NotePropertyValue "1" -Force
  $settings.env | Add-Member -NotePropertyName CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK -NotePropertyValue "1" -Force
  $settings | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $settingsPath -Encoding UTF8

  [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $ClaudeBaseUrl, "User")
  [Environment]::SetEnvironmentVariable("ANTHROPIC_MODEL", $Model, "User")
  [Environment]::SetEnvironmentVariable("ANTHROPIC_DEFAULT_HAIKU_MODEL", $SmallFastModel, "User")
  [Environment]::SetEnvironmentVariable("ANTHROPIC_SMALL_FAST_MODEL", $SmallFastModel, "User")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_MAX_CONTEXT_TOKENS", [string]$MaxContextTokens, "User")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_AUTO_COMPACT_WINDOW", [string]$AutoCompactWindow, "User")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_MAX_OUTPUT_TOKENS", [string]$MaxOutputTokens, "User")
  [Environment]::SetEnvironmentVariable("MAX_THINKING_TOKENS", [string]$MaxThinkingTokens, "User")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1", "User")
  [Environment]::SetEnvironmentVariable("CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK", "1", "User")

  $globalConfigPath = Join-Path $env:USERPROFILE ".claude.json"
  if (Test-Path $globalConfigPath) {
    Copy-Item -LiteralPath $globalConfigPath -Destination "$globalConfigPath.bak-sub2api-$(Get-Date -Format yyyyMMddHHmmss)"
    $globalConfigText = Get-Content -Raw -LiteralPath $globalConfigPath
  } else {
    $globalConfigText = "{`n}"
  }
  if ($globalConfigText -match '"workflowSizeGuideline"\s*:') {
    $globalConfigText = [regex]::Replace(
      $globalConfigText,
      '"workflowSizeGuideline"\s*:\s*"[^"]*"',
      '"workflowSizeGuideline": "small"',
      1
    )
  } else {
    $globalConfigText = [regex]::Replace(
      $globalConfigText,
      '^\s*\{',
      "{`n  `"workflowSizeGuideline`": `"small`",",
      1
    )
  }
  Write-Utf8NoBom -Path $globalConfigPath -Content $globalConfigText
}

Write-Host "sub2api runtime: $RuntimeDir"
Write-Host "docker bind: $BindHost`:$Port -> 8080"
Write-Host "Claude base URL: $ClaudeBaseUrl"
Write-Host "image: $Sub2apiImage"
Write-Host "model: $Model"
Write-Host "small-fast model: $SmallFastModel"
Write-Host "max context: $MaxContextTokens"
Write-Host "auto compact: $AutoCompactWindow"
Write-Host "max output guard: $MaxOutputTokens"
Write-Host "thinking guard: $MaxThinkingTokens"
Write-Host "workflow size guideline: small"
Write-Host "admin email: $AdminEmail"
Write-Host "admin password is in: $(Join-Path $RuntimeDir '.env')"
Write-Host "Next: import Codex OAuth, create/bind OpenAI group, create API key, then set ANTHROPIC_AUTH_TOKEN."

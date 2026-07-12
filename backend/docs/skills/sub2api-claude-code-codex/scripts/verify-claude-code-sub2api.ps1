param(
  [string]$BaseUrl = [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User"),
  [string]$Sub2apiBaseUrl = "http://127.0.0.1:18081",
  [string]$ApiKey = [Environment]::GetEnvironmentVariable("ANTHROPIC_AUTH_TOKEN", "User"),
  [string]$Model = [Environment]::GetEnvironmentVariable("ANTHROPIC_MODEL", "User"),
  [string]$SmallFastModel = [Environment]::GetEnvironmentVariable("ANTHROPIC_SMALL_FAST_MODEL", "User"),
  [string]$DefaultHaikuModel = [Environment]::GetEnvironmentVariable("ANTHROPIC_DEFAULT_HAIKU_MODEL", "User"),
  [string]$SubagentModel = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_SUBAGENT_MODEL", "User"),
  [string]$ExpectedUpstream = "gpt-5.6-sol",
  [string]$ProjectName = "sub2api-codex",
  [switch]$SkipApiProbe,
  [switch]$SkipClaudeProbe,
  [switch]$SkipDockerLogs
)

$ErrorActionPreference = "Stop"

function Normalize-Url([string]$Url, [string]$Fallback) {
  if ($Url -and $Url.Trim()) { return $Url.Trim().TrimEnd("/") }
  return $Fallback
}

function Test-IsWindowsHost {
  return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
}

function Test-Sub2apiAutostartTask {
  if (-not (Test-IsWindowsHost)) {
    Write-Warning "Autostart task check is Windows-only; skipping."
    return
  }

  Write-Host "`nWindows autostart:"
  $taskName = "Sub2API Codex Proxy Stack Autostart"
  $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if (-not $task) {
    throw "Missing scheduled task: $taskName. Run scripts/setup-sub2api-claude-code.ps1 without -SkipAutostart."
  }
  $info = Get-ScheduledTaskInfo -TaskName $taskName
  $arguments = [string]$task.Actions.Arguments
  Write-Host "task: $($task.TaskName) state=$($task.State) runLevel=$($task.Principal.RunLevel) lastResult=$($info.LastTaskResult)"
  Write-Host "action: $($task.Actions.Execute) $arguments"
  if ($task.Principal.RunLevel -ne "Highest") {
    throw "$taskName must use RunLevel=Highest so the WSL VHDX-lock self-heal can call Dismount-DiskImage."
  }
  if ($arguments -notmatch "start-sub2api-proxy-stack\.ps1") {
    throw "$taskName action must call start-sub2api-proxy-stack.ps1, not a stale host executable."
  }
  if ($arguments -notmatch "claude-code-codex-headroom|ProfileDir|RepoRoot") {
    throw "$taskName action does not identify the deploy profile/repo root."
  }

  $staleTask = Get-ScheduledTask -TaskName "headroom-proxy" -ErrorAction SilentlyContinue
  if ($staleTask) {
    throw "Stale scheduled task still exists: headroom-proxy. Remove it to avoid two proxy starters."
  }

  $startupDir = [Environment]::GetFolderPath("Startup")
  if ($startupDir -and (Test-Path -LiteralPath $startupDir)) {
    $staleLaunchers = @(Get-ChildItem -LiteralPath $startupDir -File -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -match "sub2api|headroom" -and
        $_.Extension -in @(".cmd", ".bat", ".ps1", ".lnk") -and
        $_.Name -notmatch "\.disabled$"
      })
    if ($staleLaunchers.Count -gt 0) {
      throw "Stale Startup launcher(s) still active: $($staleLaunchers.FullName -join ', ')"
    }
  }
  Write-Host "single-owner autostart: ok"
}

function Show-Health([string]$Label, [string]$Url) {
  try {
    $response = Invoke-WebRequest -UseBasicParsing "$Url/health" -TimeoutSec 10
    Write-Host "$Label health: $($response.StatusCode)"
    try {
      $json = $response.Content | ConvertFrom-Json
      if ($Label -eq "Headroom") {
        $version = $json.version
        if (-not $version) { $version = $json.components.version }
        $upstream = $json.upstream_url
        if (-not $upstream) { $upstream = $json.upstreamUrl }
        if (-not $upstream -and $json.components) { $upstream = $json.components.upstream_url }
        if (-not $upstream -and $json.checks -and $json.checks.upstream) { $upstream = $json.checks.upstream.url }
        Write-Host "Headroom ready: $($json.ready)"
        Write-Host "Headroom version: $version"
        Write-Host "Headroom upstream: $upstream"
      } else {
        Write-Host "$Label body: $($response.Content)"
      }
    } catch {
      Write-Host "$Label body: $($response.Content)"
    }
  } catch {
    Write-Warning "$Label health failed at $Url/health: $($_.Exception.Message)"
  }
}

function Get-ErrorStatus([object]$ErrorRecord) {
  $response = $ErrorRecord.Exception.Response
  if ($response -and $response.StatusCode) {
    try { return [int]$response.StatusCode } catch { return [string]$response.StatusCode }
  }
  return $null
}

function Test-DockerRuntimeAvailable {
  return [bool]((Get-Command docker -ErrorAction SilentlyContinue) -or (Get-Command wsl.exe -ErrorAction SilentlyContinue))
}

function Invoke-DockerCommand {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Args
  )

  $oldNativeErrorPreference = $null
  $hasNativeErrorPreference = Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Local -ErrorAction SilentlyContinue
  if ($hasNativeErrorPreference) {
    $oldNativeErrorPreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
  }

  try {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
      & docker @Args
    } elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
      & wsl.exe -- docker @Args
    } else {
      throw "docker and wsl.exe not found"
    }
  } finally {
    if ($hasNativeErrorPreference) {
      $PSNativeCommandUseErrorActionPreference = $oldNativeErrorPreference
    }
  }
}

function ConvertTo-PythonBase64Command {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Code
  )

  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Code))
  return "import base64; exec(base64.b64decode('$encoded').decode('utf-8'))"
}

function Get-DockerLogsMerged {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Container,
    [int]$Tail = 180
  )

  if (Get-Command docker -ErrorAction SilentlyContinue) {
    return ((& docker logs --tail $Tail $Container 2>&1) -join "`n")
  }
  if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    return ((& wsl.exe -- sh -lc "docker logs --tail $Tail $Container 2>&1") -join "`n")
  }
  throw "docker and wsl.exe not found"
}

function Assert-DockerBindMount {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Container,
    [Parameter(Mandatory = $true)]
    [string[]]$Destinations
  )

  $mountJson = (Invoke-DockerCommand -Args @("inspect", $Container, "--format", "{{json .Mounts}}") 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect Docker mounts for ${Container}: $mountJson"
  }
  $mounts = $mountJson | ConvertFrom-Json
  foreach ($destination in $Destinations) {
    $matches = @($mounts | Where-Object { $_.Destination -eq $destination })
    if ($matches.Count -gt 0) {
      $mount = $matches[0]
      if ($mount.Type -ne "bind") {
        throw "${Container}:${destination} is mounted as '$($mount.Type)', not host bind. Source: $($mount.Source)"
      }
      Write-Host "bind mount: ${Container}:${destination} <= $($mount.Source)"
      return
    }
  }
  throw "${Container} is missing expected host bind mount destination(s): $($Destinations -join ', ')"
}

function Test-AllStateOnHostBinds {
  if (-not (Test-DockerRuntimeAvailable)) {
    Write-Warning "docker and wsl.exe not found; skipping host-bind state checks."
    return
  }

  Write-Host "`nHost bind state:"
  Assert-DockerBindMount -Container "headroom-sub2api" -Destinations @("/root/.headroom")
  Assert-DockerBindMount -Container "headroom-sub2api" -Destinations @("/root/.cache/headroom")
  Assert-DockerBindMount -Container "headroom-sub2api" -Destinations @("/root/.cache/huggingface")
  Assert-DockerBindMount -Container "sub2api-codex" -Destinations @("/app/data")
  Assert-DockerBindMount -Container "sub2api-codex-postgres" -Destinations @("/var/lib/postgresql/data", "/var/lib/postgresql")
  Assert-DockerBindMount -Container "sub2api-codex-redis" -Destinations @("/data")
}

function Test-HeadroomImageBootstrap {
  if (-not (Test-DockerRuntimeAvailable)) {
    Write-Warning "docker and wsl.exe not found; skipping Headroom image-bootstrap checks."
    return
  }

  Write-Host "`nHeadroom image bootstrap:"
  $bootstrapOutput = (Invoke-DockerCommand -Args @("exec", "headroom-sub2api", "sh", "-lc", "test -x /usr/local/bin/start-headroom-proxy && test -d /opt/headroom-seed/headroom && test -d /opt/headroom-seed/cache-headroom && echo SEED_OK") 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $bootstrapOutput -notmatch "SEED_OK") {
    throw "Headroom image bootstrap is missing. The image must include start-headroom-proxy and /opt/headroom-seed so fresh persistent volumes are seeded safely. Output: $bootstrapOutput"
  }
  Write-Host "seed: $bootstrapOutput"
}

function Test-HeadroomEmbeddingServer {
  if (-not (Test-DockerRuntimeAvailable)) {
    Write-Warning "docker and wsl.exe not found; skipping Headroom embedding-server checks."
    return
  }

  Write-Host "`nHeadroom embedding server:"
  $logs = Get-DockerLogsMerged -Container "headroom-sub2api" -Tail 180
  if ($logs -notmatch "Embedding server: ready\.") {
    throw "Headroom embedding server is not ready. Rebuild the patched headroom image and recreate the service."
  }
  if ($logs -match "Falling back to per-worker embedder|No module named 'headroom\.memory\.adapters\.watchdog'|ModuleNotFound") {
    throw "Headroom embedding server regression detected in logs: fallback or missing watchdog module."
  }
  Write-Host "logs: Embedding server ready; no per-worker fallback detected"

  $socketOutput = (Invoke-DockerCommand -Args @("exec", "headroom-sub2api", "sh", "-lc", "test -S /tmp/headroom-embed-8787.sock && echo SOCKET_OK") 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $socketOutput -notmatch "SOCKET_OK") {
    throw "Headroom embedding socket is missing: /tmp/headroom-embed-8787.sock"
  }
  Write-Host "socket: /tmp/headroom-embed-8787.sock"

  $factoryProbe = "import os; os.environ['HEADROOM_EMBEDDING_SERVER_SOCKET']='/tmp/headroom-embed-8787.sock'; from headroom.memory.config import MemoryConfig, EmbedderBackend; from headroom.memory.factory import _create_embedder; e=_create_embedder(MemoryConfig(embedder_backend=EmbedderBackend.ONNX)); print(type(e).__module__, type(e).__name__, e.dimension)"
  $factoryOutput = (Invoke-DockerCommand -Args @("exec", "headroom-sub2api", "python", "-c", $factoryProbe) 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $factoryOutput -notmatch "headroom\.memory\.adapters\.watchdog\s+SocketEmbedderClient\s+384") {
    throw "Headroom memory factory did not return SocketEmbedderClient 384. Output: $factoryOutput"
  }
  Write-Host "factory: $factoryOutput"

  $embedProbe = "import asyncio; from headroom.memory.adapters.watchdog import SocketEmbedderClient; e=SocketEmbedderClient('/tmp/headroom-embed-8787.sock'); v=asyncio.run(e.embed('sub2api headroom embedding server verification')); print('EMBED_OK', len(v)); asyncio.run(e.close())"
  $embedOutput = (Invoke-DockerCommand -Args @("exec", "headroom-sub2api", "python", "-c", $embedProbe) 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $embedOutput -notmatch "EMBED_OK\s+384") {
    throw "Headroom SocketEmbedderClient direct embed probe failed. Output: $embedOutput"
  }
  Write-Host "embed: $embedOutput"
}

function Test-HeadroomClaudeCodeStreamingPatch {
  if (-not (Test-DockerRuntimeAvailable)) {
    Write-Warning "docker and wsl.exe not found; skipping Headroom Claude Code streaming patch checks."
    return
  }

  Write-Host "`nHeadroom Claude Code streaming patch:"
  $sourceProbe = @'
from pathlib import Path
files = {
  "anthropic": Path("/usr/local/lib/python3.12/site-packages/headroom/proxy/handlers/anthropic.py"),
  "streaming": Path("/usr/local/lib/python3.12/site-packages/headroom/proxy/handlers/streaming.py"),
}
texts = {name: path.read_text() for name, path in files.items()}
required = {
  "anthropic": ["Claude Code session key patch", "Claude Code no-202 overlap patch", "Claude Code handler watchdog patch"],
  "streaming": ["active-stream refcount patch", "overlap wait patch"],
}
missing = [
  f"{name}:{needle}"
  for name, needles in required.items()
  for needle in needles
  if needle not in texts[name]
]
if "return JSONResponse(content=queued, status_code=202)" in texts["anthropic"]:
  missing.append("anthropic:unsafe 202 queue return still present")
if missing:
  raise SystemExit("MISSING " + ", ".join(missing))
print("SOURCE_OK")
'@
  $sourceOutput = (Invoke-DockerCommand -Args @("exec", "headroom-sub2api", "python", "-c", (ConvertTo-PythonBase64Command $sourceProbe)) 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $sourceOutput -notmatch "SOURCE_OK") {
    throw "Headroom Claude Code streaming patch source check failed. Rebuild/recreate headroom-sub2api. Output: $sourceOutput"
  }
  Write-Host "source: $sourceOutput"

  $envOutput = (Invoke-DockerCommand -Args @("exec", "headroom-sub2api", "python", "-c", "import os; print('MID_TURN_WAIT_MS=' + os.environ.get('HEADROOM_MID_TURN_STREAM_WAIT_MS','') + '; HANDLER_WATCHDOG_MS=' + os.environ.get('HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS',''))") 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $envOutput -notmatch "MID_TURN_WAIT_MS=\d+" -or $envOutput -notmatch "HANDLER_WATCHDOG_MS=\d+") {
    throw "Headroom Claude Code timeout env is missing in headroom-sub2api. Output: $envOutput"
  }
  Write-Host "env: $envOutput"

  $regressionProbe = @'
import asyncio
import logging
from types import SimpleNamespace
from headroom.proxy.handlers.streaming import StreamingMixin
from headroom.proxy.handlers import anthropic

logging.disable(logging.CRITICAL)

class Dummy(StreamingMixin):
  pass

async def main():
  d = Dummy()
  key = "verify-overlap"
  d._active_streams.clear()
  d._mid_turn_queues.clear()
  if hasattr(d, "_active_stream_counts"):
    d._active_stream_counts.clear()
  d._mark_mid_turn_stream_active(key)
  async def clear():
    await asyncio.sleep(0.05)
    d._cleanup_mid_turn_stream(key)
  task = asyncio.create_task(clear())
  waited = await d._wait_for_mid_turn_stream(key, "verify-request")
  await task
  assert waited >= 40, waited
  assert key not in d._active_streams
  assert not d._mid_turn_queues
  req = SimpleNamespace(headers={"x-claude-code-session-id": "s", "x-claude-code-agent-id": "a"})
  assert anthropic._headroom_session_header_from_request(req) == "claude-code:s:a"
  print(f"OVERLAP_OK waited_ms={waited:.1f}")

asyncio.run(main())
'@
  $regressionOutput = (Invoke-DockerCommand -Args @("exec", "headroom-sub2api", "python", "-c", (ConvertTo-PythonBase64Command $regressionProbe)) 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $regressionOutput -notmatch "OVERLAP_OK") {
    throw "Headroom Claude Code overlap wait regression failed. Output: $regressionOutput"
  }
  Write-Host "regression: $regressionOutput"

  $watchdogProbe = @'
import asyncio
import logging
import os
from headroom.proxy.handlers import anthropic

logging.disable(logging.CRITICAL)

attempts = {"count": 0}

async def slow_then_retry_ok(self, request, *args, **kwargs):
  attempts["count"] += 1
  if attempts["count"] == 1:
    await asyncio.sleep(3600)
  assert request.headers.get("x-headroom-bypass") == "true", request.headers
  assert request.headers.get("x-headroom-mode") == "passthrough", request.headers
  assert request.headers.get("x-sub2api-headroom-watchdog-retry") == "1", request.headers
  return "WATCHDOG_RETRY_RESPONSE"

class Request:
  headers = {"x-claude-code-session-id": "verify-session", "x-claude-code-agent-id": "verify-agent"}

async def main():
  old_original = anthropic._sub2api_original_handle_anthropic_messages
  old_timeout = os.environ.get("HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS")
  anthropic._sub2api_original_handle_anthropic_messages = slow_then_retry_ok
  os.environ["HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS"] = "1000"
  try:
    response = await anthropic.AnthropicHandlerMixin().handle_anthropic_messages(Request())
    assert response == "WATCHDOG_RETRY_RESPONSE", response
    assert attempts["count"] == 2, attempts
    print(f"WATCHDOG_RETRY_OK attempts={attempts['count']} response={response}")
  finally:
    anthropic._sub2api_original_handle_anthropic_messages = old_original
    if old_timeout is None:
      os.environ.pop("HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS", None)
    else:
      os.environ["HEADROOM_CLAUDE_CODE_HANDLER_WATCHDOG_MS"] = old_timeout

asyncio.run(main())
'@
  $watchdogOutput = (Invoke-DockerCommand -Args @("exec", "headroom-sub2api", "python", "-c", (ConvertTo-PythonBase64Command $watchdogProbe)) 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0 -or $watchdogOutput -notmatch "WATCHDOG_RETRY_OK") {
    throw "Headroom Claude Code handler watchdog regression failed. Output: $watchdogOutput"
  }
  Write-Host "watchdog: $watchdogOutput"
}

function Test-HeadroomPersistentStorage {
  if (-not (Test-DockerRuntimeAvailable)) {
    Write-Warning "docker and wsl.exe not found; skipping Headroom persistent-storage checks."
    return
  }

  Write-Host "`nHeadroom persistent storage:"
  $mountProbe = "import os; paths=['/root/.headroom','/root/.cache/headroom','/root/.cache/huggingface']; print('MOUNTS', ' '.join(p+'='+str(os.path.ismount(p)) for p in paths)); raise SystemExit(0 if all(os.path.ismount(p) for p in paths) else 1)"
  $mountOutput = (Invoke-DockerCommand -Args @("exec", "headroom-sub2api", "python", "-c", $mountProbe) 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw "Headroom persistent mount check failed. Recreate the service from the current compose profile before trusting memory or embedding caches. Output: $mountOutput"
  }
  Write-Host "mounts: $mountOutput"

  $storeProbe = "import os; p='/root/.headroom/ccr_store.db'; print('CCR_STORE', os.path.exists(p), os.path.getsize(p) if os.path.exists(p) else 0)"
  $storeOutput = (Invoke-DockerCommand -Args @("exec", "headroom-sub2api", "python", "-c", $storeProbe) 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect Headroom ccr_store.db. Output: $storeOutput"
  }
  if ($storeOutput -match "CCR_STORE\s+True\s+([1-9][0-9]*)") {
    Write-Host "memory store: $storeOutput"
  } else {
    Write-Warning "Headroom ccr_store.db is not present or is empty yet. This is expected only before memory/embedding traffic has been recorded. Output: $storeOutput"
  }
}

$BaseUrl = Normalize-Url $BaseUrl "http://127.0.0.1:8787"
$Sub2apiBaseUrl = Normalize-Url $Sub2apiBaseUrl "http://127.0.0.1:18081"
if (-not $Model) { $Model = "gpt-5.6-sol" }
if (-not $SmallFastModel) { $SmallFastModel = "gpt-5.3-codex-spark" }
if (-not $DefaultHaikuModel) { $DefaultHaikuModel = "gpt-5.6-terra-medium" }
if (-not $SubagentModel) { $SubagentModel = "gpt-5.6-terra-medium" }

Write-Host "Claude/Headroom base URL: $BaseUrl"
Write-Host "sub2api admin/diagnostic URL: $Sub2apiBaseUrl"
Write-Host "Model: $Model"
Write-Host "Small-fast model: $SmallFastModel"
Write-Host "Default Haiku model: $DefaultHaikuModel"
Write-Host "Subagent model: $SubagentModel"
Write-Host "Has API token: $([bool]$ApiKey)"

Test-Sub2apiAutostartTask
Show-Health "Headroom" $BaseUrl
Show-Health "sub2api" $Sub2apiBaseUrl

if (-not $SkipApiProbe) {
  if (-not $ApiKey) {
    Write-Warning "ANTHROPIC_AUTH_TOKEN is empty; skipping direct /v1/messages probe."
  } else {
    $headers = @{
      "x-api-key" = $ApiKey
      "anthropic-version" = "2023-06-01"
      "content-type" = "application/json"
    }
    $body = @{
      model = $Model
      max_tokens = 1
      messages = @(@{ role = "user"; content = "Reply exactly OK_SUB2API_VERIFY" })
    } | ConvertTo-Json -Depth 10 -Compress
    try {
      $probe = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$BaseUrl/v1/messages" -Headers $headers -Body $body -TimeoutSec 60
      Write-Host "Headroom /v1/messages probe: $($probe.StatusCode)"
    } catch {
      $status = Get-ErrorStatus $_
      if ($status -eq 429) {
        Write-Warning "Headroom /v1/messages returned 429. Route and API key reached sub2api; fix account quota/cooldown/no-available-accounts next."
      } elseif ($status -eq 401 -or $status -eq 403) {
        Write-Warning "Headroom /v1/messages returned $status. The sub2api API key is missing, wrong, or not authorized for the group."
      } elseif ($status) {
        Write-Warning "Headroom /v1/messages returned HTTP ${status}: $($_.Exception.Message)"
      } else {
        Write-Warning "Headroom /v1/messages probe failed: $($_.Exception.Message)"
      }
    }
  }
}

if (-not $SkipClaudeProbe) {
  if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warning "claude command not found; skipping Claude Code probes."
  } else {
    $env:ANTHROPIC_BASE_URL = $BaseUrl
    $env:ANTHROPIC_AUTH_TOKEN = $ApiKey
    $env:ANTHROPIC_MODEL = $Model
    $env:ANTHROPIC_DEFAULT_HAIKU_MODEL = $DefaultHaikuModel
    $env:ANTHROPIC_SMALL_FAST_MODEL = $SmallFastModel
    $env:CLAUDE_CODE_SUBAGENT_MODEL = $SubagentModel
    $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_MAX_CONTEXT_TOKENS", "User")
    $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "User")
    $env:CLAUDE_CODE_MAX_OUTPUT_TOKENS = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_MAX_OUTPUT_TOKENS", "User")
    $env:MAX_THINKING_TOKENS = [Environment]::GetEnvironmentVariable("MAX_THINKING_TOKENS", "User")
    $effortOverride = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_EFFORT_LEVEL", "User")
    if ($effortOverride) {
      throw "User env CLAUDE_CODE_EFFORT_LEVEL=$effortOverride overrides Claude Code /effort. Clear it before verifying this profile."
    }
    if (-not $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS) { $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = "370000" }
    if (-not $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW) { $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = "340000" }
    if (-not $env:CLAUDE_CODE_MAX_OUTPUT_TOKENS) { $env:CLAUDE_CODE_MAX_OUTPUT_TOKENS = "64000" }
    if (-not $env:MAX_THINKING_TOKENS) { $env:MAX_THINKING_TOKENS = "8000" }

    Write-Host "Output guard: $env:CLAUDE_CODE_MAX_OUTPUT_TOKENS"
    Write-Host "Thinking guard: $env:MAX_THINKING_TOKENS"
    Write-Host "Effort override: <unset> (/effort remains usable)"

    Write-Host "`n/context:"
    claude --model $Model --effort max --print --no-session-persistence "/context"

    Write-Host "`nJSON probe:"
    $jsonRaw = claude --model $Model --effort max --print --output-format json --no-session-persistence "Reply exactly: OK_SUB2API_VERIFY"
    $json = $jsonRaw | ConvertFrom-Json
    $usage = $json.modelUsage.PSObject.Properties | Select-Object -First 1
    [pscustomobject]@{
      result = $json.result
      usage_model = $usage.Name
      contextWindow = $usage.Value.contextWindow
      maxOutputTokens = $usage.Value.maxOutputTokens
    } | ConvertTo-Json -Compress

    if ($SmallFastModel -ne $Model) {
      Write-Host "`nSmall-fast JSON probe:"
      $smallRaw = claude --model $SmallFastModel --effort low --print --output-format json --no-session-persistence "Reply exactly: OK_SUB2API_SMALL_FAST"
      $smallJson = $smallRaw | ConvertFrom-Json
      [pscustomobject]@{
        result = $smallJson.result
        model = $SmallFastModel
      } | ConvertTo-Json -Compress
    }
  }
}

if (-not $SkipDockerLogs) {
  if (Get-Command docker -ErrorAction SilentlyContinue) {
    Write-Host "`nCompose services:"
    docker compose -p $ProjectName ps

    Write-Host "`nClaude MCP servers:"
    if (Get-Command claude -ErrorAction SilentlyContinue) {
      claude mcp list
    } else {
      Write-Warning "claude command not found; skipping MCP list."
    }

    Write-Host "`nHeadroom tools doctor:"
    docker exec headroom-sub2api headroom tools doctor

Test-HeadroomImageBootstrap
Test-HeadroomEmbeddingServer
Test-HeadroomClaudeCodeStreamingPatch
Test-HeadroomPersistentStorage
    Test-AllStateOnHostBinds

    Write-Host "`nHeadroom savings:"
    docker exec headroom-sub2api headroom savings --json

    Write-Host "`nHeadroom perf:"
    docker exec headroom-sub2api headroom perf --hours 1 --format json

    Write-Host "`nRecent usage logs:"
    $recentUsageSql = "select id, requested_model, upstream_model, reasoning_effort, model_mapping_chain, input_tokens, created_at from usage_logs order by id desc limit 5;"
    docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F "," -Atc $recentUsageSql

    Write-Host "`n0/0 ghost-stream audit:"
    $ghostStreamSql = "select requested_model, reasoning_effort, count(*) filter (where input_tokens=0 and output_tokens=0 and stream=true and duration_ms between 500 and 30000) as zero_streams, count(*) as total from usage_logs where created_at > now() - interval '90 minutes' and inbound_endpoint='/v1/messages' group by requested_model, reasoning_effort order by zero_streams desc, total desc;"
    docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F "," -Atc $ghostStreamSql
  } elseif (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    function Quote-BashSingle([string]$Value) {
      return "'" + $Value.Replace("'", "'\''") + "'"
    }

    Write-Host "`nCompose services:"
    wsl.exe -- bash -lc "docker compose -p '$ProjectName' ps"
    Write-Host "`nClaude MCP servers:"
    if (Get-Command claude -ErrorAction SilentlyContinue) {
      claude mcp list
    } else {
      Write-Warning "claude command not found; skipping MCP list."
    }
    Write-Host "`nHeadroom tools doctor:"
    wsl.exe -- docker exec headroom-sub2api headroom tools doctor
    Test-HeadroomImageBootstrap
    Test-HeadroomEmbeddingServer
    Test-HeadroomClaudeCodeStreamingPatch
    Test-HeadroomPersistentStorage
    Test-AllStateOnHostBinds
    Write-Host "`nHeadroom savings:"
    wsl.exe -- docker exec headroom-sub2api headroom savings --json
    Write-Host "`nHeadroom perf:"
    wsl.exe -- docker exec headroom-sub2api headroom perf --hours 1 --format json
    Write-Host "`nRecent usage logs:"
    $recentUsageSql = "select id, requested_model, upstream_model, reasoning_effort, model_mapping_chain, input_tokens, created_at from usage_logs order by id desc limit 5;"
    wsl.exe -- bash -lc "docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F ',' -Atc $(Quote-BashSingle $recentUsageSql)"
    Write-Host "`n0/0 ghost-stream audit:"
    $ghostStreamSql = "select requested_model, reasoning_effort, count(*) filter (where input_tokens=0 and output_tokens=0 and stream=true and duration_ms between 500 and 30000) as zero_streams, count(*) as total from usage_logs where created_at > now() - interval '90 minutes' and inbound_endpoint='/v1/messages' group by requested_model, reasoning_effort order by zero_streams desc, total desc;"
    wsl.exe -- bash -lc "docker exec sub2api-codex-postgres psql -U sub2api -d sub2api -F ',' -Atc $(Quote-BashSingle $ghostStreamSql)"
  } else {
    Write-Warning "docker and wsl.exe not found; skipping Docker/Postgres checks."
  }
}

Write-Host "`nExpected Headroom upstream: http://sub2api:8080"
Write-Host "Expected main model in usage_logs: $ExpectedUpstream"
Write-Host "Expected small-fast requested_model in usage_logs: $SmallFastModel"
Write-Host "Expected default-Haiku/subagent model for delegated agents: $DefaultHaikuModel / $SubagentModel"

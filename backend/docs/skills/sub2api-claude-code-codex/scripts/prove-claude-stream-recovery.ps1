param(
  [string]$Distro = "Ubuntu-24.04",
  [string]$Network = "",
  [string]$HeadroomImage = "headroom-sub2api:0.31.0",
  [ValidateRange(1024, 65535)]
  [int]$HeadroomPort = 18787,
  [ValidateRange(30, 600)]
  [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $PSCommandPath
$fixture = Join-Path $scriptDir "synthetic-anthropic-stream-fault.py"
$installer = Join-Path $scriptDir "install-claude-stream-recovery.ps1"
foreach ($path in @($fixture, $installer)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Missing proof dependency: $path" }
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { throw "claude is not on PATH" }
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw "wsl.exe is required" }

$suffix = "{0}-{1}" -f $PID, ([guid]::NewGuid().ToString("N").Substring(0, 8))
$upstreamName = "claude-recovery-upstream-$suffix"
$headroomName = "claude-recovery-headroom-$suffix"
$claudeHome = Join-Path ([IO.Path]::GetTempPath()) "claude-recovery-proof-$suffix"
$rawOutput = Join-Path ([IO.Path]::GetTempPath()) "claude-recovery-proof-$suffix.jsonl"
$savedEnv = @{}
$envNames = @(
  "CLAUDE_CONFIG_DIR",
  "ANTHROPIC_BASE_URL",
  "ANTHROPIC_AUTH_TOKEN",
  "ANTHROPIC_API_KEY",
  "ANTHROPIC_MODEL",
  "ANTHROPIC_SMALL_FAST_MODEL",
  "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
  "CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK",
  "CLAUDE_CODE_EFFORT_LEVEL"
)
foreach ($name in $envNames) { $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }

function Invoke-WslDocker([string[]]$Arguments) {
  $output = @(& wsl.exe -d $Distro -- docker @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "docker $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)" }
  return $output
}

try {
  New-Item -ItemType Directory -Force -Path $claudeHome | Out-Null
  & $installer -ClaudeHome $claudeHome

  if (-not $Network.Trim()) {
    $networkJson = (Invoke-WslDocker @(
      "inspect", "headroom-sub2api", "--format", "{{json .NetworkSettings.Networks}}"
    ) | Out-String).Trim()
    $networkNames = @((ConvertFrom-Json $networkJson).PSObject.Properties.Name)
    if ($networkNames.Count -ne 1) {
      throw "Could not infer one Headroom Docker network; pass -Network explicitly. Found: $($networkNames -join ', ')"
    }
    $Network = $networkNames[0]
  }

  $fixtureWsl = (& wsl.exe -d $Distro -- wslpath -a ($fixture -replace "\\", "/") 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or -not $fixtureWsl) { throw "Could not translate fixture path into WSL" }

  [void](Invoke-WslDocker @(
    "run", "-d", "--rm",
    "--name", $upstreamName,
    "--network", $Network,
    "-v", "${fixtureWsl}:/app/server.py:ro",
    "python:3.12-slim", "python", "-u", "/app/server.py"
  ))
  [void](Invoke-WslDocker @(
    "run", "-d", "--rm",
    "--name", $headroomName,
    "--network", $Network,
    "-p", "127.0.0.1:${HeadroomPort}:8787",
    "-e", "HEADROOM_REQUIRE_CUDA=0",
    "-e", "HEADROOM_DISABLE_KOMPRESS=1",
    "-e", "HEADROOM_CLAUDE_STREAM_RECOVERY=1",
    "-e", "HEADROOM_CLAUDE_STREAM_RECOVERY_TTL_SECONDS=300",
    "-e", "HEADROOM_CLAUDE_STREAM_RECOVERY_MAX_ATTEMPTS=3",
    "-e", "HEADROOM_SKIP_UPSTREAM_CHECK=1",
    $HeadroomImage,
    "--host", "0.0.0.0",
    "--port", "8787",
    "--anthropic-api-url", "http://${upstreamName}:19090/v1/messages",
    "--disable-kompress",
    "--no-cache"
  ))

  $baseUrl = "http://127.0.0.1:$HeadroomPort"
  $deadline = (Get-Date).AddSeconds(90)
  do {
    try {
      $health = Invoke-RestMethod "$baseUrl/health" -TimeoutSec 5
      if ($health.status -in @("healthy", "degraded")) { break }
    } catch {}
    Start-Sleep -Milliseconds 500
  } while ((Get-Date) -lt $deadline)
  if (-not $health) {
    $logs = Invoke-WslDocker @("logs", $headroomName)
    throw "Temporary Headroom did not start: $($logs -join [Environment]::NewLine)"
  }

  $env:CLAUDE_CONFIG_DIR = $claudeHome
  $env:ANTHROPIC_BASE_URL = $baseUrl
  $env:ANTHROPIC_AUTH_TOKEN = "unused"
  Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
  $env:ANTHROPIC_MODEL = "claude-sonnet-4-6"
  $env:ANTHROPIC_SMALL_FAST_MODEL = "claude-sonnet-4-6"
  $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
  $env:CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK = "1"
  Remove-Item Env:CLAUDE_CODE_EFFORT_LEVEL -ErrorAction SilentlyContinue

  $claudeCommand = (Get-Command claude -ErrorAction Stop).Source
  $processInfo = [Diagnostics.ProcessStartInfo]::new()
  $processInfo.FileName = $claudeCommand
  $processInfo.UseShellExecute = $false
  $processInfo.RedirectStandardOutput = $true
  $processInfo.RedirectStandardError = $true
  foreach ($argument in @(
    "--print",
    "--no-session-persistence",
    "--output-format", "stream-json",
    "--verbose",
    "--model", "claude-sonnet-4-6",
    "--effort", "low",
    "Run the deterministic stream recovery proof and return the upstream response."
  )) {
    [void]$processInfo.ArgumentList.Add($argument)
  }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $processInfo
  [void]$process.Start()
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    $process.Kill($true)
    throw "Claude recovery proof exceeded ${TimeoutSeconds}s"
  }
  $claudeExit = $process.ExitCode
  $claudeOutput = @(
    (($stdoutTask.GetAwaiter().GetResult() -split "`r?`n") | Where-Object { $_ })
    (($stderrTask.GetAwaiter().GetResult() -split "`r?`n") | Where-Object { $_ })
  )
  [IO.File]::WriteAllLines($rawOutput, $claudeOutput, [Text.UTF8Encoding]::new($false))

  $upstreamLogs = @(Invoke-WslDocker @("logs", $upstreamName))
  $headroomLogs = @(Invoke-WslDocker @("logs", $headroomName))
  $requestCount = @($upstreamLogs | Where-Object { $_ -match '"event":"synthetic_request"' }).Count
  $checkpointCount = @($headroomLogs | Where-Object { $_ -match "event=claude_stream_checkpoint" }).Count
  $joinedOutput = $claudeOutput -join "`n"
  $sessionIds = @(
    $claudeOutput | ForEach-Object {
      try { ($_ | ConvertFrom-Json).session_id } catch { $null }
    } | Where-Object { $_ } | Select-Object -Unique
  )

  $proof = [ordered]@{
    claude_exit = $claudeExit
    upstream_requests = $requestCount
    console_checkpoint_events = $checkpointCount
    unique_session_ids = $sessionIds.Count
    first_part_seen = $joinedOutput.Contains("FIRST_PART")
    second_pass_seen = $joinedOutput.Contains("SECOND_PASS")
    transcript = $rawOutput
  }
  $proof | ConvertTo-Json -Compress | Write-Output
  if (
    $claudeExit -ne 0 -or
    $requestCount -ne 2 -or
    $sessionIds.Count -ne 1 -or
    -not $proof.first_part_seen -or
    -not $proof.second_pass_seen
  ) {
    throw "Claude stream recovery proof failed: $($proof | ConvertTo-Json -Compress)"
  }
} finally {
  foreach ($name in $envNames) {
    [Environment]::SetEnvironmentVariable($name, $savedEnv[$name], "Process")
  }
  & wsl.exe -d $Distro -- docker rm -f $headroomName $upstreamName *> $null
  $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  $resolvedClaudeHome = [IO.Path]::GetFullPath($claudeHome)
  if ($resolvedClaudeHome.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    Remove-Item -LiteralPath $resolvedClaudeHome -Recurse -Force -ErrorAction SilentlyContinue
  }
}

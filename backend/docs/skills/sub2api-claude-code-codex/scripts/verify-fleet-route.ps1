[CmdletBinding()]
param(
  [string]$RepoRoot = "",
  [string]$ProfileDir = "",
  [string]$FleetManifestPath = "",
  [string]$DshSettingsPath = "$HOME\.dsh\settings.yaml",
  [string]$DshCredentialsPath = "$HOME\.dsh\.credentials.yaml",
  [int]$ProcessTimeoutSeconds = 240,
  [int]$GuestReadyTimeoutSeconds = 120,
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptRoot "fleet-contract.psm1") -Force

if (-not $RepoRoot.Trim()) {
  $candidate = $scriptRoot
  while ($candidate -and -not (Test-Path -LiteralPath (Join-Path $candidate ".git"))) {
    $parent = Split-Path -Parent $candidate
    if (-not $parent -or $parent -eq $candidate) { $candidate = $null; break }
    $candidate = $parent
  }
  if (-not $candidate) { throw "Could not resolve sub2api checkout; pass -RepoRoot" }
  $RepoRoot = $candidate
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not $ProfileDir.Trim()) { $ProfileDir = Join-Path $RepoRoot "deploy\claude-code-codex-headroom" }
$ProfileDir = (Resolve-Path -LiteralPath $ProfileDir).Path
if (-not $FleetManifestPath.Trim()) { $FleetManifestPath = Join-Path $ProfileDir "fleet-manifest.json" }
$manifest = Read-FleetManifest -Path $FleetManifestPath
$runId = [guid]::NewGuid().ToString("N")
$startedAt = [DateTimeOffset]::UtcNow
$results = [Collections.Generic.List[object]]::new()

function Add-ProofResult {
  param(
    [string]$Id,
    [string]$Kind,
    [bool]$Required,
    [string]$Status,
    $Evidence,
    [string]$Error = ""
  )
  $results.Add([pscustomobject]@{
    id = $Id
    kind = $Kind
    required = $Required
    status = $Status
    evidence = $Evidence
    error = if ($Error) { $Error } else { $null }
  })
}

function Invoke-BoundedClaude {
  param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [Parameter(Mandatory = $true)][string]$Marker,
    [int]$TimeoutSeconds = 240
  )
  $escapedExecutable = $Executable.Replace('"', '""')
  $prompt = "Reply exactly $Marker"
  $arguments = "/d /s /c `"`"$escapedExecutable`" --print --no-session-persistence --output-format text `"$prompt`"`""
  $startInfo = [Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = "$env:ComSpec"
  $startInfo.Arguments = $arguments
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $startInfo
  if (-not $process.Start()) { throw "Could not start Claude Code" }
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    try { $process.Kill() } catch { }
    throw "Claude Code timed out after ${TimeoutSeconds}s"
  }
  $stdout = $stdoutTask.GetAwaiter().GetResult()
  $stderr = $stderrTask.GetAwaiter().GetResult()
  return [pscustomobject]@{
    exit_code = $process.ExitCode
    marker_seen = $stdout.Contains($Marker)
    stdout_chars = $stdout.Length
    stderr_chars = $stderr.Length
  }
}

function Resolve-ClaudeExecutable {
  $commands = @(Get-Command claude.cmd, claude.exe, claude -ErrorAction SilentlyContinue)
  if ($commands.Count -eq 0) { throw "Claude Code executable is not installed" }
  return [string]$commands[0].Source
}

function Get-SimpleYamlSecret {
  param([string]$Path, [string]$Name)
  if (-not (Test-Path -LiteralPath $Path)) { throw "Credential file not found: $Path" }
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match ("^\s*" + [regex]::Escape($Name) + ":\s*(?<value>.+?)\s*$")) {
      return $Matches.value.Trim().Trim('"').Trim("'")
    }
  }
  throw "Credential '$Name' is missing from $Path"
}

function Get-DshHeadModel {
  param([string]$Path)
  $lines = @(Get-Content -LiteralPath $Path)
  $head = -1
  $headIndent = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^(?<indent>\s*)head:\s*$') { $head = $i; $headIndent = $Matches.indent.Length; break }
  }
  if ($head -lt 0) { throw "DSH head provider is missing" }
  for ($i = $head + 1; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^(?<indent>\s*)(?<key>[A-Za-z0-9_.-]+):\s*$' -and $Matches.indent.Length -le $headIndent) { break }
    if ($lines[$i] -match '^\s*id:\s*(?<model>[^,}\s]+)') { return $Matches.model.Trim('"').Trim("'") }
  }
  throw "DSH head provider has no model"
}

function Get-ResponsesText {
  param($Response)
  if ($Response.PSObject.Properties.Name -contains "output_text" -and [string]$Response.output_text) {
    return [string]$Response.output_text
  }
  $parts = [Collections.Generic.List[string]]::new()
  foreach ($item in @($Response.output)) {
    foreach ($content in @($item.content)) {
      if ([string]$content.text) { $parts.Add([string]$content.text) }
      elseif ($content.text -and [string]$content.text.value) { $parts.Add([string]$content.text.value) }
    }
  }
  return ($parts -join "`n")
}

function Get-GuestCredential {
  param($Definition)
  $blobPath = Resolve-FleetPath -Path ([string]$Definition.credential_blob)
  if (-not (Test-Path -LiteralPath $blobPath)) { throw "DPAPI credential blob unavailable: $blobPath" }
  Add-Type -AssemblyName System.Security
  $plain = $null
  $password = $null
  try {
    $blob = [IO.File]::ReadAllBytes($blobPath)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($blob, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $password = [Text.Encoding]::UTF8.GetString($plain)
    $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
    $user = if ([string]$Definition.credential_user) { [string]$Definition.credential_user } else { "admin" }
    return [pscredential]::new($user, $secure)
  } finally {
    if ($plain) { [Array]::Clear($plain, 0, $plain.Length) }
    $password = $null
  }
}

try {
  $marker = "FLEET_HOST_$runId"
  $settingsPath = Join-Path $HOME ".claude\settings.json"
  $baseUrl = Get-ClaudeHeadroomBaseUrl -SettingsPath $settingsPath
  if (-not $baseUrl) { throw "Host Claude ANTHROPIC_BASE_URL is missing" }
  $health = Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/health" -TimeoutSec 10
  $claudeProof = Invoke-BoundedClaude -Executable (Resolve-ClaudeExecutable) -Marker $marker -TimeoutSeconds $ProcessTimeoutSeconds
  if ([int]$health.StatusCode -ne 200 -or $claudeProof.exit_code -ne 0 -or -not $claudeProof.marker_seen) {
    throw "Host Claude request did not complete through its configured Headroom route"
  }
  Add-ProofResult -Id "windows-host-claude" -Kind "claude-code" -Required $true -Status "passed" -Evidence ([pscustomobject]@{
    base_url = $baseUrl
    health_status = [int]$health.StatusCode
    marker = $marker
    claude = $claudeProof
  })
} catch {
  Add-ProofResult -Id "windows-host-claude" -Kind "claude-code" -Required $true -Status "failed" -Evidence $null -Error $_.Exception.Message
}

try {
  $marker = "FLEET_DSH_$runId"
  $baseUrl = Get-DshHeadBaseUrl -SettingsPath $DshSettingsPath
  if (-not $baseUrl) { throw "DSH head baseURL is missing" }
  $model = Get-DshHeadModel -Path $DshSettingsPath
  $apiKey = Get-SimpleYamlSecret -Path $DshCredentialsPath -Name "HEAD_API_KEY"
  $body = @{
    model = $model
    input = @(@{ role = "user"; content = @(@{ type = "input_text"; text = "Reply exactly $marker" }) })
    max_output_tokens = 32
    stream = $false
  } | ConvertTo-Json -Depth 10 -Compress
  $response = Invoke-RestMethod -Method Post -Uri "$($baseUrl.TrimEnd('/'))/responses" -Headers @{
    Authorization = "Bearer $apiKey"
    "User-Agent" = "dsh-fleet-verify/$runId"
  } -ContentType "application/json" -Body $body -TimeoutSec $ProcessTimeoutSeconds
  $text = Get-ResponsesText -Response $response
  if (-not $text.Contains($marker)) { throw "DSH-configured Responses request returned no verification marker" }
  Add-ProofResult -Id "windows-host-dsh" -Kind "dsh" -Required $true -Status "passed" -Evidence ([pscustomobject]@{
    base_url = $baseUrl
    model = $model
    marker = $marker
    response_id = [string]$response.id
  })
  $apiKey = $null
} catch {
  Add-ProofResult -Id "windows-host-dsh" -Kind "dsh" -Required $true -Status "failed" -Evidence $null -Error $_.Exception.Message
}

$windowsGuests = @($manifest.nodes | Where-Object { [string]$_.kind -eq "windows-hyperv" })
if ($windowsGuests.Count -gt 0) {
  try { Import-Module Hyper-V -ErrorAction Stop } catch { }
}
foreach ($definition in $windowsGuests) {
  $required = [bool]$definition.required
  $vmName = [string]$definition.vm_name
  $marker = "FLEET_$($definition.id.Replace('-', '_').ToUpperInvariant())_$runId"
  $remoteJob = $null
  try {
    $credential = Get-GuestCredential -Definition $definition
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($GuestReadyTimeoutSeconds)
    $lastError = "guest is not ready"
    $guestReady = $false
    do {
      $probeJob = $null
      try {
        $probeJob = Invoke-Command -VMName $vmName -Credential $credential -AsJob -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
        $null = Wait-Job -Job $probeJob -Timeout 20
        if ($probeJob.State -ne "Completed") {
          $reason = @($probeJob.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason.Message } | Where-Object { $_ }) -join "; "
          throw "PowerShell Direct probe ended in state $($probeJob.State): $reason"
        }
        $null = Receive-Job -Job $probeJob -ErrorAction Stop
        $guestReady = $true
      } catch {
        $lastError = $_.Exception.Message
        if ([DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Seconds 5 }
      } finally {
        if ($probeJob) { Remove-Job -Job $probeJob -Force -ErrorAction SilentlyContinue }
      }
    } while (-not $guestReady -and [DateTimeOffset]::UtcNow -lt $deadline)
    if (-not $guestReady) { throw "PowerShell Direct unavailable: $lastError" }

    $remoteJob = Invoke-Command -VMName $vmName -Credential $credential -AsJob -ArgumentList $marker,$ProcessTimeoutSeconds -ScriptBlock {
      param($ExpectedMarker,$TimeoutSeconds)
      $settingsPath = Join-Path $HOME ".claude\settings.json"
      if (-not (Test-Path -LiteralPath $settingsPath)) { throw "Guest Claude settings are missing" }
      $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
      $baseUrl = ([string]$settings.env.ANTHROPIC_BASE_URL).TrimEnd('/')
      if (-not $baseUrl) { throw "Guest ANTHROPIC_BASE_URL is missing" }
      $health = Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/health" -TimeoutSec 10
      $commands = @(Get-Command claude.cmd, claude.exe, claude -ErrorAction SilentlyContinue)
      if ($commands.Count -eq 0) { throw "Guest Claude Code executable is not installed" }
      $executable = [string]$commands[0].Source
      $prompt = "Reply exactly $ExpectedMarker"
      $psi = [Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = "$env:ComSpec"
      $psi.Arguments = "/d /s /c `"`"$($executable.Replace('"','""'))`" --print --no-session-persistence --output-format text `"$prompt`"`""
      $psi.UseShellExecute = $false
      $psi.CreateNoWindow = $true
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $process = [Diagnostics.Process]::new()
      $process.StartInfo = $psi
      if (-not $process.Start()) { throw "Could not start guest Claude Code" }
      $stdoutTask = $process.StandardOutput.ReadToEndAsync()
      $stderrTask = $process.StandardError.ReadToEndAsync()
      if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill() } catch { }
        throw "Guest Claude Code timed out after ${TimeoutSeconds}s"
      }
      $stdout = $stdoutTask.GetAwaiter().GetResult()
      $stderr = $stderrTask.GetAwaiter().GetResult()
      [pscustomobject]@{
        computer_name = $env:COMPUTERNAME
        base_url = $baseUrl
        health_status = [int]$health.StatusCode
        claude_version = (& $executable --version 2>$null | Select-Object -First 1)
        exit_code = $process.ExitCode
        marker_seen = $stdout.Contains($ExpectedMarker)
        stdout_chars = $stdout.Length
        stderr_chars = $stderr.Length
      }
    } -ErrorAction Stop
    $null = Wait-Job -Job $remoteJob -Timeout ($ProcessTimeoutSeconds + 30)
    if ($remoteJob.State -ne "Completed") {
      $reason = @($remoteJob.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason.Message } | Where-Object { $_ }) -join "; "
      throw "Guest black-box proof ended in state $($remoteJob.State): $reason"
    }
    $remoteRows = @(Receive-Job -Job $remoteJob -ErrorAction Stop)
    $remote = $remoteRows | Select-Object -Last 1
    if ([int]$remote.health_status -ne 200 -or [int]$remote.exit_code -ne 0 -or -not [bool]$remote.marker_seen) {
      throw "Guest request did not complete through its configured Headroom route"
    }
    Add-ProofResult -Id ([string]$definition.id) -Kind "windows-hyperv" -Required $required -Status "passed" -Evidence $remote
  } catch {
    Add-ProofResult -Id ([string]$definition.id) -Kind "windows-hyperv" -Required $required -Status "failed" -Evidence ([pscustomobject]@{ vm_name = $vmName; marker = $marker }) -Error $_.Exception.Message
  } finally {
    if ($remoteJob) { Remove-Job -Job $remoteJob -Force -ErrorAction SilentlyContinue }
  }
}

foreach ($definition in @($manifest.nodes | Where-Object { [string]$_.kind -eq "linux-hyperv" })) {
  Add-ProofResult -Id ([string]$definition.id) -Kind "linux-hyperv" -Required ([bool]$definition.required) -Status "skipped" -Evidence ([pscustomobject]@{ reason = "optional node is not present in the current Hyper-V inventory" })
}

$requiredFailures = @($results | Where-Object { $_.required -and $_.status -ne "passed" })
$report = [ordered]@{
  schema_version = 1
  run_id = $runId
  started_at = $startedAt.ToString("o")
  completed_at = [DateTimeOffset]::UtcNow.ToString("o")
  status = if ($requiredFailures.Count -eq 0) { "passed" } else { "failed" }
  required_failures = @($requiredFailures | ForEach-Object { $_.id })
  results = @($results)
}
$json = ($report | ConvertTo-Json -Depth 20) + [Environment]::NewLine
if ($OutputPath.Trim()) { Write-AtomicUtf8NoBom -Path $OutputPath -Content $json }
$json
if ($requiredFailures.Count -gt 0) { exit 1 }

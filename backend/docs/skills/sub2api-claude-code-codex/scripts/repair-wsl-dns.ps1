param(
  [Parameter(Mandatory = $true)]
  [string]$ProfileDir,
  [string]$Distro = "Ubuntu-24.04",
  [ValidatePattern('^[A-Za-z0-9.-]+$')]
  [string]$ProbeHost = "chatgpt.com",
  [string[]]$Containers = @("sub2api-codex", "headroom-sub2api"),
  [switch]$RepairContainers,
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$dnsPolicyPath = Join-Path $PSScriptRoot "proxy-dns-policy.ps1"
if (-not (Test-Path -LiteralPath $dnsPolicyPath)) { throw "Missing DNS policy helper: $dnsPolicyPath" }
. $dnsPolicyPath

function Read-EnvFile {
  param([string]$Path)

  $result = @{}
  if (-not (Test-Path -LiteralPath $Path)) { return $result }
  foreach ($line in Get-Content -LiteralPath $Path) {
    $trimmed = $line.Trim()
    if (-not $trimmed -or $trimmed.StartsWith("#") -or $trimmed -notmatch "=") { continue }
    $parts = $trimmed.Split("=", 2)
    $result[$parts[0].Trim()] = $parts[1].Trim().Trim('"').Trim("'")
  }
  return $result
}

function Invoke-WslCapture {
  param([string[]]$Arguments)

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& wsl.exe @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  return [ordered]@{
    ok = ($exitCode -eq 0)
    exit_code = $exitCode
    output = (($output -join [Environment]::NewLine) -replace "`0", "").Trim()
  }
}

function Test-WslResolution {
  $probe = Invoke-WslCapture -Arguments @("-d", $Distro, "--", "getent", "ahostsv4", $ProbeHost)
  return [ordered]@{ scope = "wsl"; ok = ($probe.ok -and $probe.output); host = $ProbeHost; error = if ($probe.ok) { $null } else { $probe.output } }
}

function Test-ContainerResolution {
  param([string]$Container)

  $running = Invoke-WslCapture -Arguments @("-d", $Distro, "--", "docker", "inspect", "-f", "{{.State.Running}}", $Container)
  if (-not $running.ok -or $running.output -ne "true") {
    return [ordered]@{ scope = "container"; container = $Container; running = $false; ok = $false; host = $ProbeHost; error = if ($running.output) { $running.output } else { "container is not running" } }
  }
  $probe = Invoke-WslCapture -Arguments @("-d", $Distro, "--", "docker", "exec", $Container, "getent", "ahostsv4", $ProbeHost)
  return [ordered]@{ scope = "container"; container = $Container; running = $true; ok = ($probe.ok -and $probe.output); host = $ProbeHost; error = if ($probe.ok) { $null } else { $probe.output } }
}

function Install-Resolver {
  param([string]$Content, [string[]]$Prefix)

  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Content))
  $command = "printf '%s' '$encoded' | base64 -d > /etc/resolv.conf && chmod 0644 /etc/resolv.conf"
  $result = Invoke-WslCapture -Arguments ($Prefix + @("sh", "-lc", $command))
  if (-not $result.ok) { throw "Could not install resolver configuration: $($result.output)" }
}

$root = (Resolve-Path -LiteralPath $ProfileDir).Path
$envMap = Read-EnvFile -Path (Join-Path $root ".env")
$resolvedDns = Resolve-ProxyDnsSettings -ExistingMap $envMap
$primary = $resolvedDns.primary
$fallback = $resolvedDns.fallback

$hostResolver = @(
  "# Managed by sub2api repair-wsl-dns.ps1 because WSL DNS auto-generation may be disabled."
  "nameserver $primary"
  "nameserver $fallback"
  "options timeout:2 attempts:2 rotate"
  ""
) -join "`n"
$containerResolver = @(
  "# Runtime repair; compose supplies the same external DNS servers on recreate."
  "nameserver 127.0.0.11"
  "nameserver $primary"
  "nameserver $fallback"
  "options timeout:2 attempts:2 rotate ndots:0"
  ""
) -join "`n"

$changed = @()
$wslState = Test-WslResolution
if (-not $wslState.ok -and -not $CheckOnly) {
  Install-Resolver -Content $hostResolver -Prefix @("-d", $Distro, "-u", "root", "--")
  $changed += "wsl:/etc/resolv.conf"
  $wslState = Test-WslResolution
}

$containerStates = @()
if ($RepairContainers) {
  foreach ($container in $Containers) {
    $state = Test-ContainerResolution -Container $container
    if ($state.running -and -not $state.ok -and -not $CheckOnly) {
      Install-Resolver -Content $containerResolver -Prefix @("-d", $Distro, "--", "docker", "exec", "-u", "0", $container)
      $changed += "container:${container}:/etc/resolv.conf"
      $state = Test-ContainerResolution -Container $container
    }
    $containerStates += $state
  }
}

$ok = $wslState.ok -and (@($containerStates | Where-Object { $_.running -and -not $_.ok }).Count -eq 0)
$result = [ordered]@{
  status = if ($ok) { if ($changed.Count -gt 0) { "repaired" } else { "healthy" } } else { "failed" }
  ok = $ok
  probe_host = $ProbeHost
  dns = @($primary, $fallback)
  changed = $changed
  wsl = $wslState
  containers = $containerStates
}
$result | ConvertTo-Json -Compress -Depth 8
if (-not $ok) { exit 1 }

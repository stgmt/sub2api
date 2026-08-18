param(
  [string]$CredentialsPath = "",
  [string]$Distro = "Ubuntu-24.04",
  [string]$PostgresContainer = "sub2api-codex-postgres",
  [string]$DatabaseUser = "sub2api",
  [string]$DatabaseName = "sub2api",
  [string]$GroupName = "headroom-openai-grok-composite",
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

function New-Result {
  param([string]$Status, [string]$Reason = "")
  [ordered]@{
    status = $Status
    reason = if ($Reason) { $Reason } else { $null }
    provider = "headroom-sub2api"
    group = $GroupName
    credential = "HEAD_API_KEY"
    endpoint = "http://127.0.0.1:8787/v1"
  }
}

function Resolve-CredentialsPath {
  if ($CredentialsPath.Trim()) { return $CredentialsPath }
  if (-not $env:USERPROFILE) { return "" }
  return (Join-Path $env:USERPROFILE ".dsh\.credentials.yaml")
}

function Invoke-PsqlQuery {
  param([string]$Sql)

  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = "wsl.exe"
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $arguments = @(
    "-d", $Distro, "--", "docker", "exec", "-i", $PostgresContainer,
    "psql", "-U", $DatabaseUser, "-d", $DatabaseName, "-At"
  )
  if ($null -ne $psi.PSObject.Properties["ArgumentList"]) {
    foreach ($argument in $arguments) { $psi.ArgumentList.Add([string]$argument) }
  } else {
    $psi.Arguments = ($arguments -join ' ')
  }

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $psi
  if (-not $process.Start()) { throw "Could not start WSL PostgreSQL query" }
  $process.StandardInput.Write($Sql)
  $process.StandardInput.Close()
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()
  if ($process.ExitCode -ne 0) { throw "PostgreSQL query failed: $(($stderr -join ' ').Trim())" }
  return $stdout.Trim()
}

$path = Resolve-CredentialsPath
if (-not $path -or -not (Test-Path -LiteralPath $path)) {
  (New-Result -Status "missing" -Reason "DSH credentials file not found" | ConvertTo-Json -Compress)
  return
}

$safeGroupName = $GroupName.Replace("'", "''")
$key = (Invoke-PsqlQuery -Sql @"
SELECT k.key
FROM api_keys k
JOIN groups g ON g.id = k.group_id
WHERE g.name = '$safeGroupName'
  AND g.deleted_at IS NULL
  AND k.status = 'active'
  AND k.deleted_at IS NULL
ORDER BY k.id DESC
LIMIT 1;
"@) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

if ([string]::IsNullOrWhiteSpace($key)) {
  (New-Result -Status "missing" -Reason "active composite API key was not found" | ConvertTo-Json -Compress)
  return
}

$lines = @(Get-Content -LiteralPath $path)
$index = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^\s*HEAD_API_KEY\s*:') { $index = $i; break }
}
if ($index -lt 0) { throw "HEAD_API_KEY entry is missing from DSH credentials file" }

$current = ($lines[$index] -replace '^\s*HEAD_API_KEY\s*:\s*', '').Trim()
if ($CheckOnly -or $current -eq $key) {
  (New-Result -Status "unchanged" | ConvertTo-Json -Compress)
  return
}

$indent = if ($lines[$index] -match '^(\s*)') { $Matches[1] } else { "" }
$lines[$index] = $indent + "HEAD_API_KEY: " + $key
[IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($false))
(New-Result -Status "updated" | ConvertTo-Json -Compress)

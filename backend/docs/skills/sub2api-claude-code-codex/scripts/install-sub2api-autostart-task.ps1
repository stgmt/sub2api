param(
  [string]$TaskName = "Sub2API Codex Proxy Stack Autostart",
  [string]$RepoRoot = "",
  [string]$ProfileDir = "",
  [string]$ProjectName = "sub2api-codex",
  [string]$Distro = "Ubuntu-24.04",
  [int]$HeadroomPort = 8787,
  [int]$Sub2apiPort = 18081,
  [string]$HyperVVmName = "",
  [string]$HyperVVmSshUser = "",
  [string]$HyperVVmSshKey = "",
  [string]$HyperVSwitchName = "Default Switch"
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$Root = Split-Path -Parent $ScriptDir
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogPath = Join-Path $LogDir "install-autostart-task.log"

function Write-InstallLog {
  param([string]$Message)
  Add-Content -Path $LogPath -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message)
}

$startScript = Join-Path $ScriptDir "start-sub2api-proxy-stack.ps1"
if (-not (Test-Path -LiteralPath $startScript)) {
  throw "Start script not found: $startScript"
}

Write-InstallLog "installing scheduled task '$TaskName' for $env:USERNAME"

$staleTask = Get-ScheduledTask -TaskName "headroom-proxy" -ErrorAction SilentlyContinue
if ($staleTask) {
  Unregister-ScheduledTask -TaskName "headroom-proxy" -Confirm:$false
  Write-InstallLog "removed stale scheduled task: headroom-proxy"
}

$startupDir = [Environment]::GetFolderPath("Startup")
if ($startupDir -and (Test-Path -LiteralPath $startupDir)) {
  Get-ChildItem -LiteralPath $startupDir -File -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Name -match "sub2api|headroom" -and
      $_.Extension -in @(".cmd", ".bat", ".ps1", ".lnk") -and
      $_.Name -notmatch "\.disabled$"
    } |
    ForEach-Object {
      $disabledPath = "$($_.FullName).disabled"
      Move-Item -LiteralPath $_.FullName -Destination $disabledPath -Force
      Write-InstallLog "disabled stale Startup launcher: $($_.FullName)"
    }
}

$startArgs = @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  "`"$startScript`"",
  "-ProjectName",
  "`"$ProjectName`"",
  "-Distro",
  "`"$Distro`"",
  "-HeadroomPort",
  ([string]$HeadroomPort),
  "-Sub2apiPort",
  ([string]$Sub2apiPort)
)
if ($RepoRoot.Trim()) {
  $startArgs += @("-RepoRoot", "`"$RepoRoot`"")
}
if ($ProfileDir.Trim()) {
  $startArgs += @("-ProfileDir", "`"$ProfileDir`"")
}
if ($HyperVVmName.Trim()) {
  $startArgs += @("-HyperVVmName", "`"$HyperVVmName`"")
}
if ($HyperVVmSshUser.Trim()) {
  $startArgs += @("-HyperVVmSshUser", "`"$HyperVVmSshUser`"")
}
if ($HyperVVmSshKey.Trim()) {
  $startArgs += @("-HyperVVmSshKey", "`"$HyperVVmSshKey`"")
}
if ($HyperVSwitchName.Trim()) {
  $startArgs += @("-HyperVSwitchName", "`"$HyperVSwitchName`"")
}

$action = New-ScheduledTaskAction `
  -Execute "powershell.exe" `
  -Argument ($startArgs -join " ")

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
  -MultipleInstances IgnoreNew `
  -StartWhenAvailable `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $trigger `
  -Principal $principal `
  -Settings $settings `
  -Description "Starts the single WSL Docker compose stack for Headroom + sub2api Codex proxy and self-heals stale WSL VHDX attach locks." `
  -Force | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-InstallLog "installed: runLevel=$($task.Principal.RunLevel) logonType=$($task.Principal.LogonType) lastResult=$($info.LastTaskResult)"

$task | Select-Object TaskName,State,@{Name="RunLevel";Expression={$_.Principal.RunLevel}},@{Name="LogonType";Expression={$_.Principal.LogonType}},@{Name="Execute";Expression={$_.Actions.Execute}},@{Name="Arguments";Expression={$_.Actions.Arguments}}

param(
  [string]$TaskName = "Sub2API Codex Proxy Stack Autostart",
  [string]$RepoRoot = "",
  [string]$ProfileDir = "",
  [string]$ProjectName = "sub2api-codex",
  [string]$Distro = "Ubuntu-24.04",
  [int]$HeadroomPort = 8787,
  [int]$Sub2apiPort = 18081,
  [int]$WatchdogIntervalMinutes = 1,
  [int]$TaskRestartCount = 3,
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

$ensureScript = Join-Path $ScriptDir "ensure-sub2api-proxy-stack.ps1"
if (-not (Test-Path -LiteralPath $ensureScript)) {
  throw "Self-heal script not found: $ensureScript"
}
$hiddenLauncher = Join-Path $ScriptDir "run-hidden.vbs"
if (-not (Test-Path -LiteralPath $hiddenLauncher)) {
  throw "Zero-window launcher not found: $hiddenLauncher"
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

$ensureArgs = @(
  "-WindowStyle",
  "Hidden",
  "-NoProfile",
  "-NonInteractive",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  "`"$ensureScript`"",
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
  $ensureArgs += @("-RepoRoot", "`"$RepoRoot`"")
}
if ($ProfileDir.Trim()) {
  $ensureArgs += @("-ProfileDir", "`"$ProfileDir`"")
}
if ($HyperVVmName.Trim()) {
  $ensureArgs += @("-HyperVVmName", "`"$HyperVVmName`"")
}
if ($HyperVVmSshUser.Trim()) {
  $ensureArgs += @("-HyperVVmSshUser", "`"$HyperVVmSshUser`"")
}
if ($HyperVVmSshKey.Trim()) {
  $ensureArgs += @("-HyperVVmSshKey", "`"$HyperVVmSshKey`"")
}
if ($HyperVSwitchName.Trim()) {
  $ensureArgs += @("-HyperVSwitchName", "`"$HyperVSwitchName`"")
}

$launcherArgs = @("//B", "//NoLogo", "`"$hiddenLauncher`"", "powershell.exe") + $ensureArgs
$action = New-ScheduledTaskAction `
  -Execute "wscript.exe" `
  -Argument ($launcherArgs -join " ")

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$watchdogTrigger = New-ScheduledTaskTrigger `
  -Once `
  -At (Get-Date).AddMinutes($WatchdogIntervalMinutes) `
  -RepetitionInterval (New-TimeSpan -Minutes $WatchdogIntervalMinutes) `
  -RepetitionDuration (New-TimeSpan -Days 3650)
$triggers = @($logonTrigger, $watchdogTrigger)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
  -MultipleInstances IgnoreNew `
  -StartWhenAvailable `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -RestartCount $TaskRestartCount `
  -RestartInterval (New-TimeSpan -Minutes 1) `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $action `
  -Trigger $triggers `
  -Principal $principal `
  -Settings $settings `
  -Description "Health-checks and self-heals the single WSL Docker compose stack, Hyper-V bridge, and stale WSL VHDX attach locks." `
  -Force | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-InstallLog "installed: runLevel=$($task.Principal.RunLevel) logonType=$($task.Principal.LogonType) triggers=$($task.Triggers.Count) restartCount=$($task.Settings.RestartCount) lastResult=$($info.LastTaskResult)"

$task | Select-Object TaskName,State,@{Name="RunLevel";Expression={$_.Principal.RunLevel}},@{Name="LogonType";Expression={$_.Principal.LogonType}},@{Name="Execute";Expression={$_.Actions.Execute}},@{Name="Arguments";Expression={$_.Actions.Arguments}}

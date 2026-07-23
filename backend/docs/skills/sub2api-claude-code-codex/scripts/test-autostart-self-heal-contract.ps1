param(
  [string]$InstallerPath = (Join-Path $PSScriptRoot "install-sub2api-autostart-task.ps1"),
  [string]$HiddenLauncherPath = (Join-Path $PSScriptRoot "run-hidden.vbs"),
  [string]$EnsurePath = (Join-Path $PSScriptRoot "ensure-sub2api-proxy-stack.ps1"),
  [string]$StartPath = (Join-Path $PSScriptRoot "start-sub2api-proxy-stack.ps1"),
  [string]$VerifierPath = (Join-Path $PSScriptRoot "verify-claude-code-sub2api.ps1")
)

$ErrorActionPreference = "Stop"

function Assert-Contains {
  param([string]$Text, [string]$Needle, [string]$Message)
  if (-not $Text.Contains($Needle)) { throw $Message }
}

$installer = Get-Content -Raw -LiteralPath $InstallerPath
$hiddenLauncher = Get-Content -Raw -LiteralPath $HiddenLauncherPath
$ensure = Get-Content -Raw -LiteralPath $EnsurePath
$start = Get-Content -Raw -LiteralPath $StartPath
$verifier = Get-Content -Raw -LiteralPath $VerifierPath

Assert-Contains $installer 'ensure-sub2api-proxy-stack.ps1' "Scheduled Task must call the health-first ensure script"
Assert-Contains $installer 'New-ScheduledTaskTrigger -AtLogOn' "Scheduled Task must retain logon startup"
Assert-Contains $installer '-RepetitionInterval' "Scheduled Task must have a repeating watchdog trigger"
Assert-Contains $installer '-RestartCount $TaskRestartCount' "Scheduled Task must retry a failed recovery"
Assert-Contains $installer '-MultipleInstances IgnoreNew' "Scheduled Task must remain a single owner"
Assert-Contains $installer 'run-hidden.vbs' "Scheduled Task must use the zero-window launcher"
Assert-Contains $installer '-Execute "wscript.exe"' "Scheduled Task must run through the GUI script host"
Assert-Contains $hiddenLauncher 'shell.Run(command, 0, True)' "Hidden launcher must hide the process and preserve its exit code"

$probeIndex = $ensure.IndexOf('$before = Get-RequiredRouteState')
$recoveryIndex = $ensure.IndexOf('& $startScript @startParams')
if ($probeIndex -lt 0 -or $recoveryIndex -lt 0 -or $probeIndex -ge $recoveryIndex) {
  throw "Self-heal must probe first and invoke the full start script only after failure"
}

Assert-Contains $ensure 'Get-HyperVSwitchIpv4' "Self-heal must verify the Hyper-V bridge route"
Assert-Contains $ensure 'RequireHyperVBridge' "Self-heal must make Hyper-V bridge fail-closed only when explicitly required"
Assert-Contains $ensure '$bridgeOk = $true' "Optional Hyper-V bridge must not fail a healthy same-host route by default"
Assert-Contains $ensure 'bridge_required' "Self-heal route proof must record whether the Hyper-V bridge is required"
Assert-Contains $ensure 'HEADROOM_HYPERV_REQUIRE_BRIDGE' "Self-heal must allow profile env to require the Hyper-V bridge"
Assert-Contains $ensure 'HEADROOM_HYPERV_REMOTE_CONFIG_MODE' "Self-heal must support a Windows guest without SSH"
Assert-Contains $ensure '$bridgeEnv["HEADROOM_HYPERV_VM_NAME"]' "Profile env must override a stale VM name embedded in the scheduled task"
Assert-Contains $ensure 'HEADROOM_HYPERV_VM_SSH_USER' "Self-heal must read the canonical VM SSH user key"
Assert-Contains $ensure 'Sync-CodexAuthFile' "Self-heal must sync fresh host Codex OAuth auth into the sub2api bind mount"
Assert-Contains $ensure 'codex_auth_synced' "Self-heal must emit proof when it refreshes the Codex auth bind file"
Assert-Contains $ensure 'codex-auth.json' "Self-heal must write the canonical sub2api Codex auth file"
Assert-Contains $ensure 'recovery_started' "Self-heal must emit a recovery-start event"
Assert-Contains $ensure 'recovered' "Self-heal must emit recovery proof"
Assert-Contains $ensure 'recovery_failed' "Self-heal must fail closed after an unsuccessful recovery"
Assert-Contains $start 'Sync-SelfHealScheduledTask' "Legacy logon-only tasks must self-upgrade from their existing elevated action"
Assert-Contains $start 'actionUsesHiddenLauncher' "Legacy direct PowerShell tasks must self-upgrade to the zero-window launcher"
Assert-Contains $start 'upgrading legacy or focus-stealing autostart task to repeating zero-window self-heal' "Legacy task migration must be observable"
Assert-Contains $start 'Hyper-V guest config update skipped by mode=none' "Bridge-only Windows mode must remain observable"
Assert-Contains $verifier 'ensure-sub2api-proxy-stack\.ps1' "Verifier must reject the legacy start-script action"
Assert-Contains $verifier 'run-hidden\.vbs' "Verifier must reject focus-stealing scheduled task actions"
Assert-Contains $verifier 'PT1M repeating self-heal trigger' "Verifier must require the repeating trigger"
Assert-Contains $verifier 'MultipleInstances=IgnoreNew' "Verifier must require singleflight task execution"

if ($start.Contains('exit 0')) {
  throw "The nested start script must return instead of terminating its ensure caller"
}

if ($env:OS -eq "Windows_NT") {
  & cscript.exe //B //NoLogo $HiddenLauncherPath powershell.exe -NoProfile -NonInteractive -Command "exit 23"
  if ($LASTEXITCODE -ne 23) {
    throw "Zero-window launcher must preserve the child process exit code; expected 23, got $LASTEXITCODE"
  }
}

Write-Host "AUTOSTART_SELF_HEAL_CONTRACT_OK"

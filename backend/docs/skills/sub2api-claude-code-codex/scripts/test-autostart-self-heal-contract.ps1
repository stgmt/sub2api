param(
  [string]$InstallerPath = (Join-Path $PSScriptRoot "install-sub2api-autostart-task.ps1"),
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
$ensure = Get-Content -Raw -LiteralPath $EnsurePath
$start = Get-Content -Raw -LiteralPath $StartPath
$verifier = Get-Content -Raw -LiteralPath $VerifierPath

Assert-Contains $installer 'ensure-sub2api-proxy-stack.ps1' "Scheduled Task must call the health-first ensure script"
Assert-Contains $installer 'New-ScheduledTaskTrigger -AtLogOn' "Scheduled Task must retain logon startup"
Assert-Contains $installer '-RepetitionInterval' "Scheduled Task must have a repeating watchdog trigger"
Assert-Contains $installer '-RestartCount $TaskRestartCount' "Scheduled Task must retry a failed recovery"
Assert-Contains $installer '-MultipleInstances IgnoreNew' "Scheduled Task must remain a single owner"

$probeIndex = $ensure.IndexOf('$before = Get-RequiredRouteState')
$recoveryIndex = $ensure.IndexOf('& $startScript @startParams')
if ($probeIndex -lt 0 -or $recoveryIndex -lt 0 -or $probeIndex -ge $recoveryIndex) {
  throw "Self-heal must probe first and invoke the full start script only after failure"
}

Assert-Contains $ensure 'Get-HyperVSwitchIpv4' "Self-heal must verify the Hyper-V bridge route"
Assert-Contains $ensure 'recovery_started' "Self-heal must emit a recovery-start event"
Assert-Contains $ensure 'recovered' "Self-heal must emit recovery proof"
Assert-Contains $ensure 'recovery_failed' "Self-heal must fail closed after an unsuccessful recovery"
Assert-Contains $start 'Sync-SelfHealScheduledTask' "Legacy logon-only tasks must self-upgrade from their existing elevated action"
Assert-Contains $start 'upgrading legacy logon-only autostart task to repeating self-heal' "Legacy task migration must be observable"
Assert-Contains $verifier 'ensure-sub2api-proxy-stack\.ps1' "Verifier must reject the legacy start-script action"
Assert-Contains $verifier 'PT1M repeating self-heal trigger' "Verifier must require the repeating trigger"
Assert-Contains $verifier 'MultipleInstances=IgnoreNew' "Verifier must require singleflight task execution"

if ($start.Contains('exit 0')) {
  throw "The nested start script must return instead of terminating its ensure caller"
}

Write-Host "AUTOSTART_SELF_HEAL_CONTRACT_OK"

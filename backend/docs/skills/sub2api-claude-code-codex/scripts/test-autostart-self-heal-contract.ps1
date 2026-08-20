param(
  [string]$InstallerPath = (Join-Path $PSScriptRoot "install-sub2api-autostart-task.ps1"),
  [string]$HiddenLauncherPath = (Join-Path $PSScriptRoot "run-hidden.vbs"),
  [string]$EnsurePath = (Join-Path $PSScriptRoot "ensure-sub2api-proxy-stack.ps1"),
  [string]$StartPath = (Join-Path $PSScriptRoot "start-sub2api-proxy-stack.ps1"),
  [string]$SetupPath = (Join-Path $PSScriptRoot "setup-sub2api-claude-code.ps1"),
  [string]$DnsRepairPath = (Join-Path $PSScriptRoot "repair-wsl-dns.ps1"),
  [string]$DnsPolicyPath = (Join-Path $PSScriptRoot "proxy-dns-policy.ps1"),
  [string]$RecoveryPolicyPath = (Join-Path $PSScriptRoot "proxy-stack-recovery-policy.ps1"),
  [string]$VerifierPath = (Join-Path $PSScriptRoot "verify-claude-code-sub2api.ps1"),
  [string]$FleetManifestPath = (Join-Path $PSScriptRoot "..\..\..\..\..\deploy\claude-code-codex-headroom\fleet-manifest.json")
)

$ErrorActionPreference = "Stop"

function Assert-Contains {
  param([string]$Text, [string]$Needle, [string]$Message)
  if (-not $Text.Contains($Needle)) { throw $Message }
}

function Assert-NotContains {
  param([string]$Text, [string]$Needle, [string]$Message)
  if ($Text.Contains($Needle)) { throw $Message }
}

function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -ne $Expected) { throw "$Message; expected '$Expected', got '$Actual'" }
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

$installer = Get-Content -Raw -LiteralPath $InstallerPath
$hiddenLauncher = Get-Content -Raw -LiteralPath $HiddenLauncherPath
$ensure = Get-Content -Raw -LiteralPath $EnsurePath
$start = Get-Content -Raw -LiteralPath $StartPath
$setup = Get-Content -Raw -LiteralPath $SetupPath
$dnsRepair = Get-Content -Raw -LiteralPath $DnsRepairPath
$dnsPolicy = Get-Content -Raw -LiteralPath $DnsPolicyPath
$recoveryPolicy = Get-Content -Raw -LiteralPath $RecoveryPolicyPath
$verifier = Get-Content -Raw -LiteralPath $VerifierPath
$fleetManifest = Get-Content -Raw -LiteralPath $FleetManifestPath | ConvertFrom-Json
. $RecoveryPolicyPath
. $DnsPolicyPath

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
Assert-Contains $ensure 'FleetManifestPath' "Self-heal must use the versioned fleet manifest"
Assert-Contains $ensure 'Get-FleetReconcileSummary' "Self-heal must evaluate required and optional fleet nodes"
Assert-Contains $ensure 'Assert-ProviderRouteHealthy' "Self-heal must not report healthy while required fleet reconciliation is pending"
Assert-Contains $ensure 'client_routes' "Self-heal must prove each configured client endpoint"
Assert-Contains $ensure 'Get-DshHeadBaseUrl' "Self-heal must probe the endpoint configured in DSH"
Assert-Contains $ensure 'Set-DshHeadBaseUrl' "Self-heal must repair DSH endpoint drift atomically"
Assert-Contains $ensure '"-FleetManifestPath"' "Provider reconciliation must receive the canonical manifest"
Assert-Equal @($fleetManifest.nodes | Where-Object { $_.kind -eq 'windows-hyperv' -and $_.required }).Count 2 "Both Windows Hyper-V guests must be required fleet nodes"
Assert-Equal @($fleetManifest.nodes | Where-Object { $_.kind -eq 'windows-hyperv' -and $_.required -and $_.desired_state -eq 'running' }).Count 2 "Both required Windows guests must declare a running desired state"
Assert-Contains $ensure 'Ensure-RequiredFleetHyperVNodes' "Self-heal must restore required Hyper-V fleet nodes"
Assert-Contains $ensure 'AutomaticStartAction' "Self-heal must make required Hyper-V VM startup durable"
Assert-Contains $ensure 'HEADROOM_HYPERV_VM_SSH_USER' "Self-heal must read the canonical VM SSH user key"
Assert-Contains $ensure 'Write-HyperVInventorySnapshot' "Elevated self-heal must publish an exact Hyper-V VM inventory"
Assert-Contains $ensure 'Invoke-OfflineWindowsGuestRouteRepair' "Elevated self-heal must provide a password-free offline Windows guest repair path"
Assert-Contains $ensure 'Mount-VHD -Path $vhdPath' "Offline guest repair must mount the exact VHDX before editing"
Assert-Contains $ensure 'Dismount-VHD -Path $vhdPath' "Offline guest repair must always dismount the VHDX"
Assert-Contains $ensure 'ghost-offline-route.request.json' "Offline guest repair must use an explicit one-shot request marker"
Assert-Contains $ensure 'offline_guest_route_repaired' "Offline guest repair must emit a durable success event"
Assert-Contains $ensure 'fleet-route-verify.request.json' "Elevated self-heal must support an explicit one-shot fleet verification request"
Assert-Contains $ensure 'verify-fleet-route.ps1' "Fleet verification request must execute the fork-owned black-box verifier"
Assert-Contains $ensure 'Install-OfflineGuestRouteBootstrap' "Offline guest repair must install a credential-free dynamic route bootstrap"
Assert-Contains $ensure 'ensure-headroom-route.ps1' "Offline repair must persist the guest gateway resolver"
Assert-Contains $ensure 'Sub2ApiHeadroomRoute' "Guest route bootstrap must run at each user logon"
Assert-Contains $ensure 'Get-NetRoute -DestinationPrefix "0.0.0.0/0"' "Guest bootstrap must derive the current Default Switch gateway"
Assert-Contains $ensure 'Could not resolve a unique interactive guest profile' "Offline repair must not write a guessed user profile"
Assert-Contains $ensure 'NTUSER.DAT' "Offline repair must resolve the actual guest user hive"
Assert-Contains $ensure 'Host Headroom API key is unavailable for offline guest repair' "Offline repair must fail closed without a valid host-side gateway key"
Assert-Contains $ensure 'auth_source = "host_settings"' "Offline repair telemetry must identify its non-secret key source"
Assert-Contains $ensure 'Invoke-OfflineWindowsGuestSshSetup' "Elevated self-heal must provide a password-free offline SSH setup path"
Assert-Contains $ensure 'ghost-offline-ssh.request.json' "Offline SSH setup must use an explicit one-shot request marker"
Assert-Contains $ensure 'OpenSSH-Server-In-TCP' "Offline SSH setup must open the guest firewall rule for TCP/22"
Assert-Contains $ensure 'offline_guest_ssh_configured' "Offline SSH setup must emit a durable success event"
Assert-Contains $ensure 'authorized_keys' "Offline SSH setup must install a public-key authorization file"
Assert-Contains $ensure 'administrators_authorized_keys' "Offline SSH setup must cover the Windows Administrators authorization path"
Assert-Contains $ensure 'Get-ChildItem -LiteralPath $packageRoot' "Offline SSH setup must expand the OpenSSH package contents before copying"
Assert-Contains $ensure 'Invoke-OfflineWindowsGuestSshAudit' "Offline SSH setup must expose an auditable VHDX verification path"
Assert-NotContains $ensure 'Sync-HyperVGuestSubagentProfiles' "Self-heal must not bypass claude-route with a hidden Qwen-only guest profile"
$reconcileIndex = $ensure.IndexOf('$providerRoute = Invoke-ProviderRouteReconcile -ProfileRoot $Root')
$healthyIndex = $ensure.IndexOf('Write-SelfHealEvent -Event "healthy"')
Assert-True ($reconcileIndex -ge 0 -and $healthyIndex -gt $reconcileIndex) "Self-heal must publish healthy only after provider fleet reconciliation"
Assert-NotContains $ensure 'HEADROOM_HYPERV_STAGE_QWEN_PROFILE' "Legacy Qwen-only Hyper-V staging must stay retired"
Assert-Contains $ensure 'Sync-CodexAuthFile' "Self-heal must sync fresh host Codex OAuth auth into the sub2api bind mount"
Assert-Contains $ensure 'codex_auth_synced' "Self-heal must emit proof when it refreshes the Codex auth bind file"
Assert-Contains $ensure 'codex-auth.json' "Self-heal must write the canonical sub2api Codex auth file"
Assert-Contains $ensure '$stateRoot.StartsWith("/")' "Self-heal must distinguish a Linux absolute state root from a Windows path"
Assert-Contains $ensure "`$sourcePortable = `$source -replace '\\', '/'" "Self-heal must normalize the Windows Codex auth source before WSL translation"
Assert-Contains $ensure '$temporaryTarget = "$target.tmp.$([guid]::NewGuid().ToString(''N''))"' "Self-heal must stage Codex auth atomically inside WSL"
Assert-Contains $ensure 'mv -f $temporaryTarget $target' "Self-heal must atomically publish staged Codex auth inside WSL"
Assert-Contains $ensure 'WSL Codex auth hash verification failed' "Self-heal must verify the copied OAuth file by hash"
Assert-Contains $ensure 'Invoke-ProviderRouteReconcile' "The single stack watchdog must also reconcile the active provider profile"
Assert-Contains $ensure 'provider-route-state.json' "Provider reconciliation must be generation-driven"
Assert-Contains $ensure 'ProviderReconcileMinutes' "Offline guest reconciliation must be throttled"
Assert-Contains $ensure 'provider_route_reconcile_failed' "Provider reconcile failures must be observable without declaring the proxy dead"
Assert-Contains $ensure 'recovery_started' "Self-heal must emit a recovery-start event"
Assert-Contains $ensure 'recovered' "Self-heal must emit recovery proof"
Assert-Contains $ensure 'recovery_failed' "Self-heal must fail closed after an unsuccessful recovery"
Assert-Contains $ensure '$rawActive = [int]$proxyInbound.active' "Self-heal must preserve the raw Headroom activity gauge"
Assert-Contains $ensure 'active = [Math]::Max(0, $rawActive - 1)' "Self-heal must subtract its own /stats observer request before deciding whether traffic is idle"
Assert-Contains $ensure 'observer_adjustment = 1' "Self-heal must expose the observer adjustment in its proof payload"
Assert-Contains $recoveryPolicy 'if (-not $Lifecycle.known)' "Unknown Docker lifecycle must never authorize a recreate"
Assert-Contains $ensure "docker ps -a --format" "Lifecycle observation must distinguish Docker transport failure from missing containers"
Assert-NotContains $ensure "`n    ForceRecreate = `$true" "Missing/stopped containers must be started without forcing recreation of healthy peers"
Assert-Contains $ensure '$startParams.ForceRecreate = $true' "Only a proven-idle running stack may opt into force recreation"
Assert-Contains $ensure 'bridge_recovery_started' "A bridge-only outage must take the non-recreating repair path"
Assert-Contains $ensure 'compose_policy = "--no-recreate"' "Bridge repair must prove the safe compose policy"
Assert-Contains $ensure 'Test-Sub2apiDnsRoute' "Self-heal must probe the provider DNS route, not only local HTTP health"
Assert-Contains $ensure 'dns_repaired' "Self-heal must make successful DNS repair observable"
Assert-Contains $ensure 'dns_repair_failed' "Self-heal must make failed DNS repair observable"
Assert-Contains $dnsRepair 'Resolve-ProxyDnsSettings' "DNS repair must use the shared profile-aware resolver policy"
Assert-Contains $dnsPolicy 'SUB2API_PRIMARY_DNS' "DNS policy must use the profile primary resolver"
Assert-Contains $dnsPolicy 'SUB2API_FALLBACK_DNS' "DNS policy must use the profile fallback resolver"
Assert-Contains $dnsRepair 'wsl:/etc/resolv.conf' "DNS repair must restore the missing WSL resolver file"
Assert-Contains $dnsRepair 'nameserver 127.0.0.11' "Container repair must retain Docker service discovery"
Assert-Contains $dnsRepair 'container:${container}:/etc/resolv.conf' "Container repair must report every in-place repair"
Assert-Contains $setup '[string]$Sub2apiPrimaryDns = "auto"' "Setup must not overwrite routed DNS with a hard-coded public resolver"
Assert-Contains $setup 'Resolve-ProxyDnsSettings' "Setup must resolve DNS through the shared preservation policy"
Assert-Contains $setup 'Set-DotEnvValue $envMap "SUB2API_PRIMARY_DNS" $resolvedDns.primary' "Setup must persist the resolved primary DNS"
Assert-Contains $dnsPolicy 'Get-NetRoute' "DNS policy must discover the active Windows route for a new profile"
Assert-Contains $dnsPolicy 'existing_profile' "DNS policy must preserve a previously verified profile resolver"

$existingDns = [ordered]@{ SUB2API_PRIMARY_DNS = "192.168.1.1"; SUB2API_FALLBACK_DNS = "9.9.9.9" }
$dnsDecision = Resolve-ProxyDnsSettings -ExistingMap $existingDns
Assert-Equal $dnsDecision.primary "192.168.1.1" "Automatic setup must preserve the existing primary resolver"
Assert-Equal $dnsDecision.fallback "9.9.9.9" "Automatic setup must preserve the existing fallback resolver"
Assert-Equal $dnsDecision.primary_source "existing_profile" "Preserved primary DNS needs an explicit source"
$dnsDecision = Resolve-ProxyDnsSettings -RequestedPrimary "10.10.10.10" -RequestedFallback "8.8.4.4" -ExistingMap $existingDns
Assert-Equal $dnsDecision.primary "10.10.10.10" "An explicit primary resolver must override the existing profile"
Assert-Equal $dnsDecision.fallback "8.8.4.4" "An explicit fallback resolver must override the existing profile"
$invalidDnsRejected = $false
try { Resolve-ProxyDnsSettings -RequestedPrimary "127.0.0.1" -ExistingMap @{} | Out-Null } catch { $invalidDnsRejected = $true }
Assert-Equal $invalidDnsRejected $true "Loopback DNS must be rejected before writing the compose profile"

$zeroActive = [pscustomobject]@{ ok = $true; active_known = $true; active = 0 }
$busy = [pscustomobject]@{ ok = $true; active_known = $true; active = 3 }
$unknownActive = [pscustomobject]@{ ok = $false; active_known = $false; active = $null }
$unknownLifecycle = [pscustomobject]@{ known = $false; missing_or_stopped = $false; both_running = $false }
$missingLifecycle = [pscustomobject]@{ known = $true; missing_or_stopped = $true; both_running = $false }
$runningLifecycle = [pscustomobject]@{ known = $true; missing_or_stopped = $false; both_running = $true }

$decision = Get-ProxyStackRecoveryDecision -ActiveState $zeroActive -Lifecycle $unknownLifecycle
Assert-Equal $decision.action "defer" "Unknown Docker state must defer even when Headroom reports zero active requests"
Assert-Equal $decision.reason "lifecycle_state_unproven" "Unknown Docker state needs an explicit reason"
$decision = Get-ProxyStackRecoveryDecision -ActiveState $unknownActive -Lifecycle $missingLifecycle
Assert-Equal $decision.action "start-missing" "A proven missing container must use non-recreating startup"
Assert-Equal $decision.force_recreate $false "Missing-container recovery must not recreate healthy peers"
$decision = Get-ProxyStackRecoveryDecision -ActiveState $zeroActive -Lifecycle $runningLifecycle
Assert-Equal $decision.action "recreate-idle" "A proven-idle fully running stack may be recreated"
Assert-Equal $decision.force_recreate $true "Idle running-stack recovery must opt in explicitly"
$decision = Get-ProxyStackRecoveryDecision -ActiveState $busy -Lifecycle $runningLifecycle
Assert-Equal $decision.reason "active_proxy_requests" "Active traffic must defer recovery"
Assert-Contains $start 'Sync-SelfHealScheduledTask' "Legacy logon-only tasks must self-upgrade from their existing elevated action"
Assert-Contains $start 'actionUsesHiddenLauncher' "Legacy direct PowerShell tasks must self-upgrade to the zero-window launcher"
Assert-Contains $start 'upgrading legacy or focus-stealing autostart task to repeating zero-window self-heal' "Legacy task migration must be observable"
Assert-Contains $start 'Hyper-V guest config update skipped by mode=none' "Bridge-only Windows mode must remain observable"
Assert-Contains $start 'Repair-PausedComposeContainers' "Autostart must repair paused Docker containers before compose start"
Assert-Contains $start 'docker unpause' "Autostart must unpause paused Docker containers instead of retrying compose blindly"
Assert-Contains $start '[switch]$AllowWslRestart' "Destructive WSL restart must require an explicit operator switch"
Assert-Contains $start 'destructive restart is not explicitly allowed' "Scheduled recovery must explain why WSL restart was refused"
Assert-Contains $start 'HEADROOM_REQUIRE_CUDA' "GPU-required profiles must be explicit in the starter"
Assert-Contains $start 'refusing CPU fallback' "GPU-required profiles must fail closed instead of starting CPU Headroom"
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

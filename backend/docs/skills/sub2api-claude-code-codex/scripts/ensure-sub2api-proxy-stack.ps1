param(
  [string]$RepoRoot = "",
  [string]$ProfileDir = "",
  [string]$ProjectName = "sub2api-codex",
  [string]$Distro = "Ubuntu-24.04",
  [int]$HeadroomPort = 8787,
  [int]$Sub2apiPort = 18081,
  [int]$HealthTimeoutSeconds = 4,
  [int]$RecoveryWaitSeconds = 120,
  [int]$HealthyHeartbeatMinutes = 30,
  [int]$ProviderReconcileMinutes = 15,
  [string]$HyperVVmName = "",
  [string]$HyperVVmSshUser = "",
  [string]$HyperVVmSshKey = "",
  [string]$HyperVSwitchName = "Default Switch",
  [ValidateSet("ssh", "none")]
  [string]$HyperVRemoteConfigMode = "ssh",
  [bool]$RequireHyperVBridge = $false,
  [string]$CodexAuthFile = "",
  [ValidatePattern('^[A-Za-z0-9.-]+$')]
  [string]$DnsProbeHost = "chatgpt.com"
)

$ErrorActionPreference = "Stop"
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$ScriptDir = Split-Path -Parent $PSCommandPath
$recoveryPolicyScript = Join-Path $ScriptDir "proxy-stack-recovery-policy.ps1"
if (-not (Test-Path -LiteralPath $recoveryPolicyScript)) {
  throw "Recovery policy script not found: $recoveryPolicyScript"
}
. $recoveryPolicyScript

function Resolve-ProfileDir {
  if ($ProfileDir.Trim()) {
    return (Resolve-Path -LiteralPath $ProfileDir).Path
  }
  if ($RepoRoot.Trim()) {
    $candidate = Join-Path (Resolve-Path -LiteralPath $RepoRoot).Path "deploy\claude-code-codex-headroom"
    if (Test-Path -LiteralPath (Join-Path $candidate "docker-compose.yml")) {
      return $candidate
    }
  }
  throw "Could not resolve the sub2api runtime profile. Pass -ProfileDir or -RepoRoot."
}

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

function Write-Utf8NoBom {
  param([string]$Path, [string]$Content)
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Write-SelfHealEvent {
  param(
    [string]$Event,
    [hashtable]$Data = @{}
  )

  $row = [ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString("o")
    event = $Event
  }
  foreach ($key in $Data.Keys) { $row[$key] = $Data[$key] }
  [IO.File]::AppendAllText(
    $LogPath,
    (($row | ConvertTo-Json -Compress -Depth 8) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
  )
}

function Invoke-ProviderRouteReconcile {
  param([string]$ProfileRoot)

  $routeStatePath = Join-Path $ProfileRoot "data\provider-route-state.json"
  if (-not (Test-Path -LiteralPath $routeStatePath)) {
    return [pscustomobject]@{ status = "disabled"; reason = "provider route state is not initialized" }
  }

  try {
    $routeState = Get-Content -Raw -LiteralPath $routeStatePath | ConvertFrom-Json
    $generation = [string]$routeState.generation
    $bridgeEnv = Read-EnvFile -Path (Join-Path $ProfileRoot "hyperv-bridge.env")
    $configuredWindowsGuestName = if ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_WINDOWS_GUEST_NAME")) {
      [string]$bridgeEnv["HEADROOM_HYPERV_WINDOWS_GUEST_NAME"]
    } else { "" }
    $configuredWindowsGuestCredentialBlob = if ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_WINDOWS_GUEST_CREDENTIAL_BLOB")) {
      [string]$bridgeEnv["HEADROOM_HYPERV_WINDOWS_GUEST_CREDENTIAL_BLOB"]
    } else { "" }
    $settingsPath = Join-Path $HOME ".claude\settings.json"
    $localGeneration = ""
    if (Test-Path -LiteralPath $settingsPath) {
      try { $localGeneration = [string](Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json).env.CLAUDE_PROVIDER_PROFILE_GENERATION } catch { }
    }
    $localDrift = $generation -ne $localGeneration
    $pendingNodes = @($routeState.nodes.PSObject.Properties | Where-Object { [string]$_.Value.status -ne "synced" }).Count
    $windowsNode = @($routeState.nodes.PSObject.Properties | Where-Object { $_.Name -eq "windows_hyperv" } | Select-Object -First 1)
    $windowsGuestDrift = $false
    if ($configuredWindowsGuestName.Trim() -and $configuredWindowsGuestCredentialBlob.Trim()) {
      $windowsGuestDrift = $windowsNode.Count -eq 0 -or [string]$windowsNode[0].Value.name -ne $configuredWindowsGuestName.Trim()
    }
    if (-not $localDrift -and $pendingNodes -eq 0 -and -not $windowsGuestDrift) {
      return [pscustomobject]@{ status = "synced"; generation = $generation; attempted = $false }
    }

    $attemptStatePath = Join-Path $ProfileRoot "logs\provider-route-reconcile-state.json"
    if (-not $localDrift -and (Test-Path -LiteralPath $attemptStatePath)) {
      try {
        $attemptState = Get-Content -Raw -LiteralPath $attemptStatePath | ConvertFrom-Json
        $lastAttempt = [DateTimeOffset]::Parse([string]$attemptState.attempted_at)
        $sameGeneration = [string]$attemptState.generation -eq $generation
        if (-not $windowsGuestDrift -and $sameGeneration -and ([DateTimeOffset]::UtcNow - $lastAttempt.ToUniversalTime()).TotalMinutes -lt $ProviderReconcileMinutes) {
          return [pscustomobject]@{ status = "throttled"; generation = $generation; pending_nodes = $pendingNodes; attempted = $false }
        }
      } catch { }
    }

    $candidates = @(
      (Join-Path $HOME ".codex\skills\sub2api-claude-code-codex\scripts\claude-route.ps1")
    )
    if ($RepoRoot.Trim()) {
      $candidates += Join-Path $RepoRoot "backend\docs\skills\sub2api-claude-code-codex\scripts\claude-route.ps1"
    }
    $controller = @($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if ($controller.Count -eq 0) {
      return [pscustomobject]@{ status = "pending-reconcile"; reason = "claude-route controller is not installed"; attempted = $false }
    }

    Write-Utf8NoBom -Path $attemptStatePath -Content (([ordered]@{ attempted_at = [DateTimeOffset]::UtcNow.ToString("o"); generation = $generation } | ConvertTo-Json -Compress) + [Environment]::NewLine)
    $controllerArgs = @("reconcile", "-RuntimeRoot", $ProfileRoot)
    if ($configuredWindowsGuestName.Trim() -and $configuredWindowsGuestCredentialBlob.Trim()) {
      $controllerArgs += @(
        "-WindowsGuestName", $configuredWindowsGuestName.Trim(),
        "-WindowsGuestCredentialBlob", $configuredWindowsGuestCredentialBlob.Trim()
      )
    }
    $output = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $controller[0] @controllerArgs 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ($output -join [Environment]::NewLine) }
    $result = $output -join [Environment]::NewLine | ConvertFrom-Json
    Write-SelfHealEvent -Event "provider_route_reconciled" -Data @{ generation = $generation; active_profile = $result.active_profile }
    return [pscustomobject]@{ status = "reconciled"; generation = $generation; attempted = $true; nodes = $result.nodes }
  } catch {
    Write-SelfHealEvent -Event "provider_route_reconcile_failed" -Data @{ error = $_.Exception.Message }
    return [pscustomobject]@{ status = "pending-reconcile"; attempted = $true; reason = $_.Exception.Message }
  }
}

function Write-HyperVInventorySnapshot {
  $inventoryPath = Join-Path $LogDir "hyperv-inventory.json"
  try {
    Import-Module Hyper-V -ErrorAction Stop
    $vms = foreach ($vm in (Get-VM -ErrorAction Stop)) {
      $adapters = @(Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction SilentlyContinue)
      $services = @(Get-VMIntegrationService -VMName $vm.Name -ErrorAction SilentlyContinue)
      $disks = @(Get-VMHardDiskDrive -VMName $vm.Name -ErrorAction SilentlyContinue)
      [ordered]@{
        name = $vm.Name
        state = [string]$vm.State
        status = [string]$vm.Status
        generation = $vm.Generation
        automatic_start_action = [string]$vm.AutomaticStartAction
        addresses = @($adapters | ForEach-Object { @($_.IPAddresses) } | Where-Object { $_ })
        hard_disks = @($disks | ForEach-Object {
          [ordered]@{
            controller_type = $_.ControllerType
            controller_number = $_.ControllerNumber
            controller_location = $_.ControllerLocation
            path = $_.Path
          }
        })
        adapters = @($adapters | ForEach-Object {
          [ordered]@{
            switch = $_.SwitchName
            mac = $_.MacAddress
            status = [string]$_.Status
          }
        })
        integration_services = @($services | ForEach-Object {
          [ordered]@{
            name = $_.Name
            enabled = [bool]$_.Enabled
            primary_status = [string]$_.PrimaryStatusDescription
          }
        })
      }
    }
    Write-Utf8NoBom -Path $inventoryPath -Content (([ordered]@{
      captured_at = (Get-Date).ToUniversalTime().ToString("o")
      vms = @($vms)
    } | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
  } catch {
    Write-SelfHealEvent -Event "hyperv_inventory_failed" -Data @{ error = $_.Exception.Message }
  }
}

function Invoke-OfflineWindowsGuestRouteRepair {
  param([string]$RequestPath)

  $request = Get-Content -Raw -LiteralPath $RequestPath | ConvertFrom-Json
  $vmName = [string]$request.vm_name
  $vhdPath = [string]$request.vhd_path
  $guestUser = if ([string]$request.guest_user) { [string]$request.guest_user } else { "admin" }
  $baseUrl = if ([string]$request.base_url) { [string]$request.base_url } else { "http://172.22.128.1:8787" }
  if (-not $vmName -or -not (Test-Path -LiteralPath $vhdPath)) { throw "Offline guest repair request is invalid" }

  Import-Module Hyper-V -ErrorAction Stop
  $vm = Get-VM -Name $vmName -ErrorAction Stop
  $wasRunning = $vm.State -eq "Running"
  if ($wasRunning) {
    Stop-VM -Name $vmName -Force -ErrorAction Stop
    $deadline = (Get-Date).AddMinutes(2)
    do { Start-Sleep -Seconds 2; $vm = Get-VM -Name $vmName } while ($vm.State -ne "Off" -and (Get-Date) -lt $deadline)
    if ($vm.State -ne "Off") { throw "VM did not stop for offline guest repair: $($vm.State)" }
  }

  $mounted = $false
  $driveRoot = $null
  $disk = $null
  $partition = $null
  $addedAccessPath = $false
  $mount = $null
  try {
    $mount = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
    $mounted = $true
    $disk = Get-Disk -Number $mount.DiskNumber -ErrorAction Stop
    $partition = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -notin @("Reserved", "Recovery") } | Sort-Object Size -Descending | Select-Object -First 1)
    if ($partition.Count -eq 0) { throw "No usable guest partition found on disk $($disk.Number)" }
    $driveRoot = @($partition[0].AccessPaths | Where-Object { $_ -match '^[A-Z]:\\$' } | Select-Object -First 1)
    if (-not $driveRoot) {
      $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object Name)
      $letter = @([char[]]("DEFGHIJKLMNOPQRSTUVWXYZ") | ForEach-Object { [string]$_ } | Where-Object { $_ -notin $used } | Select-Object -First 1)
      if (-not $letter) { throw "No free drive letter for guest VHDX" }
      $driveRoot = "$letter`:\"
      Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition[0].PartitionNumber -AccessPath $driveRoot -ErrorAction Stop
      $addedAccessPath = $true
    }
    $claudeDir = Join-Path $driveRoot "Users\$guestUser\.claude"
    New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
    $settingsPath = Join-Path $claudeDir "settings.json"
    $settings = if (Test-Path -LiteralPath $settingsPath) { try { Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json } catch { [pscustomobject]@{} } } else { [pscustomobject]@{} }
    if (-not $settings.PSObject.Properties["env"]) { $settings | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) }
    foreach ($pair in @(@("ANTHROPIC_BASE_URL", $baseUrl), @("ANTHROPIC_AUTH_TOKEN", "unused"))) {
      if (-not $settings.env.PSObject.Properties[$pair[0]]) { $settings.env | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] } else { $settings.env.($pair[0]) = $pair[1] }
    }
    $settings | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $settingsPath -Encoding utf8
    $proofPath = Join-Path $driveRoot "Users\$guestUser\headroom-route-offline-proof.txt"
    Set-Content -LiteralPath $proofPath -Value ("HEADROOM_OFFLINE_ROUTE_APPLIED`nbase_url=$baseUrl`napplied_at=$((Get-Date).ToUniversalTime().ToString('o'))") -Encoding utf8
    if ($addedAccessPath) { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition[0].PartitionNumber -AccessPath $driveRoot -ErrorAction SilentlyContinue }
    Dismount-VHD -Path $vhdPath -ErrorAction Stop
    $mounted = $false
    if ($wasRunning) { Start-VM -Name $vmName -ErrorAction Stop | Out-Null }
    Move-Item -LiteralPath $RequestPath -Destination ($RequestPath -replace '\.request\.json$','.done.json') -Force
    Write-SelfHealEvent -Event "offline_guest_route_repaired" -Data @{ vm = $vmName; base_url = $baseUrl; settings = "Users\$guestUser\.claude\settings.json" }
    return [pscustomobject]@{ status = "repaired"; vm = $vmName; base_url = $baseUrl; restarted = $wasRunning }
  } catch {
    if ($addedAccessPath -and $disk -and $partition -and $driveRoot) { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition[0].PartitionNumber -AccessPath $driveRoot -ErrorAction SilentlyContinue }
    if ($mounted) { Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue }
    if ($wasRunning -and (Get-VM -Name $vmName).State -eq "Off") { Start-VM -Name $vmName -ErrorAction SilentlyContinue | Out-Null }
    throw
  }
}

function Invoke-OfflineWindowsGuestSshSetup {
  param([string]$RequestPath)

  $request = Get-Content -Raw -LiteralPath $RequestPath | ConvertFrom-Json
  $vmName = [string]$request.vm_name
  $vhdPath = [string]$request.vhd_path
  $guestUser = if ([string]$request.guest_user) { [string]$request.guest_user } else { "admin" }
  $packageRoot = [string]$request.package_root
  $publicKeyPath = [string]$request.public_key_path
  $hostKeyRoot = [string]$request.host_key_root
  if (-not $vmName -or -not (Test-Path -LiteralPath $vhdPath) -or -not (Test-Path -LiteralPath (Join-Path $packageRoot "sshd.exe")) -or -not (Test-Path -LiteralPath $publicKeyPath) -or -not (Test-Path -LiteralPath (Join-Path $hostKeyRoot "ssh_host_ed25519_key"))) {
    throw "Offline SSH request is invalid or missing OpenSSH/key material"
  }

  Import-Module Hyper-V -ErrorAction Stop
  $vm = Get-VM -Name $vmName -ErrorAction Stop
  $wasRunning = $vm.State -eq "Running"
  if ($wasRunning) {
    Stop-VM -Name $vmName -Force -ErrorAction Stop
    $deadline = (Get-Date).AddMinutes(2)
    do { Start-Sleep -Seconds 2; $vm = Get-VM -Name $vmName } while ($vm.State -ne "Off" -and (Get-Date) -lt $deadline)
    if ($vm.State -ne "Off") { throw "VM did not stop for offline SSH setup: $($vm.State)" }
  }

  $mounted = $false
  $disk = $null
  $partition = $null
  $driveRoot = $null
  $addedAccessPath = $false
  $hiveLoaded = $false
  try {
    $mount = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
    $mounted = $true
    $disk = Get-Disk -Number $mount.DiskNumber -ErrorAction Stop
    $partition = @(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -notin @("Reserved", "Recovery") } | Sort-Object Size -Descending | Select-Object -First 1)
    if ($partition.Count -eq 0) { throw "No usable guest partition found for offline SSH setup" }
    $driveRoot = $partition[0].AccessPaths | Where-Object { $_ -match '^[A-Z]:\\$' } | Select-Object -First 1 -ExpandProperty ToString
    if (-not $driveRoot -or -not (Test-Path -LiteralPath $driveRoot)) {
      $used = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object Name)
      $letter = @([char[]]("DEFGHIJKLMNOPQRSTUVWXYZ") | ForEach-Object { [string]$_ } | Where-Object { $_ -notin $used -and -not (Test-Path -LiteralPath "$_`:\") } | Select-Object -First 1)
      if (-not $letter) { throw "No free drive letter for offline SSH setup" }
      $driveRoot = "$letter`:\"
      Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition[0].PartitionNumber -AccessPath $driveRoot -ErrorAction Stop
      $addedAccessPath = $true
    }

    $openSshDir = Join-Path $driveRoot "Windows\System32\OpenSSH"
    New-Item -ItemType Directory -Force -Path $openSshDir | Out-Null
    Get-ChildItem -LiteralPath $packageRoot -Force | ForEach-Object {
      $packageTarget = Join-Path $openSshDir $_.Name
      if (-not (Test-Path -LiteralPath $packageTarget)) {
        Copy-Item -LiteralPath $_.FullName -Destination $packageTarget -Recurse -Force
      }
    }
    $programSshDir = Join-Path $driveRoot "ProgramData\ssh"
    New-Item -ItemType Directory -Force -Path $programSshDir | Out-Null
    foreach ($hostKeyName in @("ssh_host_ed25519_key", "ssh_host_ed25519_key.pub", "ssh_host_rsa_key", "ssh_host_rsa_key.pub")) {
      $hostKeyTarget = Join-Path $programSshDir $hostKeyName
      if (-not (Test-Path -LiteralPath $hostKeyTarget)) {
        Copy-Item -LiteralPath (Join-Path $hostKeyRoot $hostKeyName) -Destination $hostKeyTarget -Force
      }
    }
    $moduliTarget = Join-Path $programSshDir "moduli"
    if (-not (Test-Path -LiteralPath $moduliTarget)) { Copy-Item -LiteralPath (Join-Path $packageRoot "moduli") -Destination $moduliTarget -Force }

    $authorizedDir = Join-Path $driveRoot "Users\$guestUser\.ssh"
    New-Item -ItemType Directory -Force -Path $authorizedDir | Out-Null
    $authorizedPath = Join-Path $authorizedDir "authorized_keys"
    if (-not (Test-Path -LiteralPath $authorizedPath)) { Copy-Item -LiteralPath $publicKeyPath -Destination $authorizedPath -Force }
    $administratorsAuthorizedPath = Join-Path $programSshDir "administrators_authorized_keys"
    if (-not (Test-Path -LiteralPath $administratorsAuthorizedPath)) { Copy-Item -LiteralPath $publicKeyPath -Destination $administratorsAuthorizedPath -Force }
    $config = @(
      "Port 22",
      "ListenAddress 0.0.0.0",
      "PubkeyAuthentication yes",
      "PasswordAuthentication no",
      "AuthorizedKeysFile .ssh/authorized_keys",
      "HostKey __PROGRAMDATA__/ssh/ssh_host_ed25519_key",
      "HostKey __PROGRAMDATA__/ssh/ssh_host_rsa_key",
      "Subsystem sftp sftp-server.exe"
    ) -join [Environment]::NewLine
    $sshdConfigPath = Join-Path $programSshDir "sshd_config"
    if (-not (Test-Path -LiteralPath $sshdConfigPath)) {
      Set-Content -LiteralPath $sshdConfigPath -Value ($config + [Environment]::NewLine) -Encoding ascii
    }
    $bootstrapScriptPath = Join-Path $programSshDir "bootstrap-sshd.ps1"
    if (-not (Test-Path -LiteralPath $bootstrapScriptPath)) {
      $bootstrapScript = @(
        '$ErrorActionPreference = "SilentlyContinue"',
        'New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (SSH)" -Enabled True -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null',
        'Set-NetFirewallRule -DisplayName "OpenSSH Server (SSH)" -Enabled True -Action Allow -Profile Any -ErrorAction SilentlyContinue',
        'Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue',
        'Start-Service -Name sshd -ErrorAction SilentlyContinue'
      ) -join [Environment]::NewLine
      Set-Content -LiteralPath $bootstrapScriptPath -Value ($bootstrapScript + [Environment]::NewLine) -Encoding ascii
    }
    $softwareHivePath = Join-Path $driveRoot "Windows\System32\config\SOFTWARE"
    & reg.exe load HKLM\OfflineGhostSoftware $softwareHivePath | Out-Null
    if ($LASTEXITCODE -eq 0) {
      $runKey = 'HKLM\OfflineGhostSoftware\Microsoft\Windows\CurrentVersion\Run'
      & reg.exe add $runKey /v OpenSSHBootstrap /t REG_SZ /d 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\ProgramData\ssh\bootstrap-sshd.ps1' /f | Out-Null
      & reg.exe unload HKLM\OfflineGhostSoftware | Out-Null
    }
    & icacls.exe $programSshDir /inheritance:r /grant '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' /T /C | Out-Null
    & icacls.exe $authorizedDir /inheritance:r /grant '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' /T /C | Out-Null

    & reg.exe load HKLM\OfflineGhostSystem (Join-Path $driveRoot "Windows\System32\config\SYSTEM") | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not load guest SYSTEM hive for offline SSH setup" }
    $hiveLoaded = $true
    foreach ($controlSet in @("ControlSet001", "ControlSet002", "ControlSet003", "ControlSet004")) {
      $serviceKey = "HKLM\OfflineGhostSystem\$controlSet\Services\sshd"
      & reg.exe add $serviceKey /v ImagePath /t REG_EXPAND_SZ /d '"C:\Windows\System32\OpenSSH\sshd.exe" -E C:\ProgramData\ssh\sshd.log' /f | Out-Null
      & reg.exe add $serviceKey /v DisplayName /t REG_SZ /d 'OpenSSH SSH Server' /f | Out-Null
      & reg.exe add $serviceKey /v Description /t REG_SZ /d 'SSH protocol based service' /f | Out-Null
      & reg.exe add $serviceKey /v ObjectName /t REG_SZ /d LocalSystem /f | Out-Null
      & reg.exe add $serviceKey /v ErrorControl /t REG_DWORD /d 1 /f | Out-Null
      & reg.exe add $serviceKey /v RequiredPrivileges /t REG_MULTI_SZ /d 'SeAssignPrimaryTokenPrivilege\0SeTcbPrivilege\0SeBackupPrivilege\0SeRestorePrivilege\0SeImpersonatePrivilege\0' /f | Out-Null
      & reg.exe add $serviceKey /v Start /t REG_DWORD /d 2 /f | Out-Null
      & reg.exe add $serviceKey /v Type /t REG_DWORD /d 16 /f | Out-Null
      $bootstrapKey = "HKLM\OfflineGhostSystem\$controlSet\Services\OpenSSHFirewallBootstrap"
      & reg.exe add $bootstrapKey /v ImagePath /t REG_EXPAND_SZ /d 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\ProgramData\ssh\bootstrap-sshd.ps1' /f | Out-Null
      & reg.exe add $bootstrapKey /v DisplayName /t REG_SZ /d 'OpenSSH Firewall Bootstrap' /f | Out-Null
      & reg.exe add $bootstrapKey /v ObjectName /t REG_SZ /d LocalSystem /f | Out-Null
      & reg.exe add $bootstrapKey /v ErrorControl /t REG_DWORD /d 1 /f | Out-Null
      & reg.exe add $bootstrapKey /v Start /t REG_DWORD /d 2 /f | Out-Null
      & reg.exe add $bootstrapKey /v Type /t REG_DWORD /d 16 /f | Out-Null
      $firewallKey = "HKLM\OfflineGhostSystem\$controlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"
      & reg.exe add $firewallKey /v '{8B7B9B1A-5C4D-4DF4-9B7B-0F0E3C4A6B22}' /t REG_SZ /d 'v2.30|Action=Allow|Active=TRUE|Dir=In|Protocol=6|Profile=Domain|Profile=Private|Profile=Public|LPort=22|App=%SystemRoot%\System32\OpenSSH\sshd.exe|Name=OpenSSH-Server-In-TCP|' /f | Out-Null
      & reg.exe add $firewallKey /v 'sshd-tcpm' /t REG_SZ /d 'v2.30|Action=Allow|Active=TRUE|Dir=In|Protocol=6|LPort=22|App=%SystemRoot%\system32\OpenSSH\sshd.exe|Name=OpenSSH Server (sshd) tcp|Desc=Inbound TCP rule for OpenSSH SSH Server (sshd) over port 22.|' /f | Out-Null
    }
    $binaryInstalled = Test-Path -LiteralPath (Join-Path $openSshDir "sshd.exe")
    $sshdLogPath = Join-Path $programSshDir "sshd.log"
    $sshdLogTail = if (Test-Path -LiteralPath $sshdLogPath) { (Get-Content -LiteralPath $sshdLogPath -Tail 20 -ErrorAction SilentlyContinue) -join " | " } else { $null }
    $systemEventLogPath = Join-Path $driveRoot "Windows\System32\winevt\Logs\System.evtx"
    $serviceEventTail = if (Test-Path -LiteralPath $systemEventLogPath) { @(& wevtutil.exe qe $systemEventLogPath /lf:true /f:text /c:80 2>$null | Select-String -Pattern 'sshd|OpenSSH|Service Control Manager|error' | Select-Object -Last 12) -join " | " } else { $null }
    & reg.exe unload HKLM\OfflineGhostSystem | Out-Null
    $hiveLoaded = $false
    if ($addedAccessPath) { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition[0].PartitionNumber -AccessPath $driveRoot -ErrorAction SilentlyContinue }
    Dismount-VHD -Path $vhdPath -ErrorAction Stop
    $mounted = $false
    if ($wasRunning) { Start-VM -Name $vmName -ErrorAction Stop | Out-Null }
    if (-not $binaryInstalled) { throw "OpenSSH package copy did not produce sshd.exe in the guest system directory" }
    Move-Item -LiteralPath $RequestPath -Destination ($RequestPath -replace '\.request\.json$','.done.json') -Force
    Write-SelfHealEvent -Event "offline_guest_ssh_configured" -Data @{ vm = $vmName; user = $guestUser; port = 22; public_key = "installed"; sshd_exe = $true; guest_drive = $driveRoot; sshd_log_tail = $sshdLogTail; service_event_tail = $serviceEventTail }
    return [pscustomobject]@{ status = "configured"; vm = $vmName; port = 22; restarted = $wasRunning }
  } catch {
    if ($hiveLoaded) { & reg.exe unload HKLM\OfflineGhostSystem | Out-Null }
    if ($addedAccessPath -and $disk -and $partition -and $driveRoot) { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition[0].PartitionNumber -AccessPath $driveRoot -ErrorAction SilentlyContinue }
    if ($mounted) { Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue }
    if ($wasRunning -and (Get-VM -Name $vmName).State -eq "Off") { Start-VM -Name $vmName -ErrorAction SilentlyContinue | Out-Null }
    throw
  }
}

function Invoke-PowerShellDirectWindowsGuestSshRepair {
  param([string]$RequestPath)

  $request = Get-Content -Raw -LiteralPath $RequestPath | ConvertFrom-Json
  $vmName = [string]$request.vm_name
  $guestUser = if ([string]$request.guest_user) { [string]$request.guest_user } else { "admin" }
  $password = [string]$request.password
  if (-not $vmName -or -not $password) { throw "PowerShell Direct SSH request is missing vm_name or password" }

  $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
  $credential = [pscredential]::new($guestUser, $securePassword)
  $result = Invoke-Command -VMName $vmName -Credential $credential -ScriptBlock {
    $ErrorActionPreference = "Stop"
    $rule = Get-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if (-not $rule) {
      New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH-Server-In-TCP" -Description "Allow SSH server inbound TCP 22" -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -Profile Any | Out-Null
    } else {
      Set-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" -Enabled True -Action Allow -Profile Any | Out-Null
    }
    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd
    $service = Get-Service -Name sshd
    [pscustomobject]@{ user = [Environment]::UserName; computer = $env:COMPUTERNAME; service = $service.Status.ToString(); firewall = $true }
  }
  $donePath = $RequestPath -replace '\.request\.json$','.done.json'
  $safeRequest = [ordered]@{ vm_name = $vmName; guest_user = $guestUser; action = "start-sshd" }
  $safeRequest | ConvertTo-Json | Set-Content -LiteralPath $donePath -Encoding utf8
  Remove-Item -LiteralPath $RequestPath -Force
  Write-SelfHealEvent -Event "powershell_direct_guest_ssh_repaired" -Data @{ vm = $vmName; user = $guestUser; service = $result.service; firewall = $true }
  return $result
}

function Invoke-OfflineWindowsGuestSshAudit {
  param([string]$RequestPath)

  $request = Get-Content -Raw -LiteralPath $RequestPath | ConvertFrom-Json
  $vmName = [string]$request.vm_name
  $vhdPath = [string]$request.vhd_path
  if (-not $vmName -or -not (Test-Path -LiteralPath $vhdPath)) { throw "Offline SSH audit request is invalid" }
  $wasRunning = ((Get-VM -Name $vmName -ErrorAction Stop).State -eq "Running")
  $mounted = $false
  $hiveLoaded = $false
  $disk = $null
  $driveRoot = $null
  try {
    if ($wasRunning) { Stop-VM -Name $vmName -Force -ErrorAction Stop | Out-Null }
    $disk = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
    $mounted = $true
    $partition = Get-Disk -Number $disk.DiskNumber | Get-Partition | Where-Object { $_.Type -notin @("Reserved", "Recovery") -and $_.Size -gt 20GB } | Sort-Object Size -Descending | Select-Object -First 1
    if (-not $partition) { throw "Could not find guest Windows partition" }
    $driveRoot = (Get-Volume -Partition $partition).DriveLetter + ":\"
    $systemHive = Join-Path $driveRoot "Windows\System32\config\SYSTEM"
    $registryError = $null
    & reg.exe load HKLM\OfflineGhostAuditSystem $systemHive | Out-Null
    if ($LASTEXITCODE -eq 0) {
      $hiveLoaded = $true
      $select = (& reg.exe query HKLM\OfflineGhostAuditSystem\Select /v Current 2>$null) -join " "
      $serviceValues = foreach ($controlSet in @("ControlSet001", "ControlSet002", "ControlSet003", "ControlSet004")) {
        $key = "HKLM\OfflineGhostAuditSystem\$controlSet\Services\sshd"
        if (Test-Path "Registry::$key") { [pscustomobject]@{ control_set = $controlSet; values = ((& reg.exe query $key 2>$null) -join " | ") } }
      }
    } else {
      $registryError = "SYSTEM hive could not be loaded"
      $select = ""
      $serviceValues = @()
    }
    $result = [ordered]@{
      vm = $vmName
      selected_control_set = $select.Trim()
      registry_error = $registryError
      sshd_exe = Test-Path (Join-Path $driveRoot "Windows\System32\OpenSSH\sshd.exe")
      sshd_config = Test-Path (Join-Path $driveRoot "ProgramData\ssh\sshd_config")
      administrators_authorized_keys = Test-Path (Join-Path $driveRoot "ProgramData\ssh\administrators_authorized_keys")
      host_ed25519 = Test-Path (Join-Path $driveRoot "ProgramData\ssh\ssh_host_ed25519_key")
      service_registry = $serviceValues
      system_log = Test-Path (Join-Path $driveRoot "Windows\System32\winevt\Logs\System.evtx")
    }
    $donePath = $RequestPath -replace '\.request\.json$','.done.json'
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $donePath -Encoding utf8
    Remove-Item -LiteralPath $RequestPath -Force
    Write-SelfHealEvent -Event "offline_guest_ssh_audited" -Data $result
    return [pscustomobject]$result
  } finally {
    if ($hiveLoaded) { & reg.exe unload HKLM\OfflineGhostAuditSystem | Out-Null }
    if ($driveRoot -and $disk) { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath $driveRoot -ErrorAction SilentlyContinue }
    if ($mounted) { Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue }
    if ($wasRunning) { Start-VM -Name $vmName -ErrorAction SilentlyContinue | Out-Null }
  }
}

function Resolve-StateRootPath {
  param([string]$ProfileRoot, [hashtable]$EnvMap)

  $stateRoot = "./data"
  if ($EnvMap.ContainsKey("SUB2API_STATE_ROOT") -and $EnvMap["SUB2API_STATE_ROOT"].Trim()) {
    $stateRoot = $EnvMap["SUB2API_STATE_ROOT"].Trim()
  }
  if ($stateRoot.StartsWith("/") -or [IO.Path]::IsPathRooted($stateRoot)) {
    return $stateRoot
  }
  return Join-Path $ProfileRoot ($stateRoot -replace '^\.[\\/]', '')
}

function Test-CodexAuthFileShape {
  param([string]$Path)

  try {
    $auth = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $access = [string]$auth.tokens.access_token
    $refresh = [string]$auth.tokens.refresh_token
    return ($access.Trim().Length -gt 0 -and $refresh.Trim().Length -gt 0)
  } catch {
    return $false
  }
}

function Sync-CodexAuthFile {
  param([string]$ProfileRoot, [hashtable]$EnvMap)

  $source = $CodexAuthFile
  if (-not $source.Trim()) {
    if (-not $env:USERPROFILE) { return @{ status = "skipped"; reason = "USERPROFILE is empty" } }
    $source = Join-Path $env:USERPROFILE ".codex\auth.json"
  }
  if (-not (Test-Path -LiteralPath $source)) {
    return @{ status = "missing"; source = $source }
  }
  if (-not (Test-CodexAuthFileShape -Path $source)) {
    Write-SelfHealEvent -Event "codex_auth_sync_skipped" -Data @{ reason = "auth file lacks tokens.access_token or tokens.refresh_token"; source = $source }
    return @{ status = "invalid"; source = $source }
  }

  $stateRoot = Resolve-StateRootPath -ProfileRoot $ProfileRoot -EnvMap $EnvMap
  $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($stateRoot.StartsWith("/")) {
    $sourcePortable = $source -replace '\\', '/'
    # WSL may emit a harmless localhost-proxy warning alongside wslpath's
    # result. Keep only the absolute POSIX path instead of treating warning
    # text as a second path and failing the whole watchdog tick.
    $sourceWslRaw = @(& wsl.exe -d $Distro -- wslpath -a -u -- $sourcePortable 2>$null)
    $sourceWslExit = $LASTEXITCODE
    $sourceWsl = @($sourceWslRaw | Where-Object { ([string]$_).Trim() -match '^/' } | Select-Object -First 1)
    if ($sourceWslExit -ne 0 -or $sourceWsl.Count -ne 1 -or -not $sourceWsl[0].Trim()) {
      throw "Could not translate Codex auth path into WSL: $source"
    }
    $target = $stateRoot.TrimEnd('/') + "/sub2api/codex-auth.json"
    $targetHash = ""
    $hashOutput = @(& wsl.exe -d $Distro -- sha256sum $target 2>$null)
    if ($LASTEXITCODE -eq 0 -and $hashOutput.Count -gt 0) { $targetHash = (($hashOutput[0] -split '\s+')[0]).ToLowerInvariant() }
    if ($sourceHash -eq $targetHash) {
      return @{ status = "unchanged"; target = $target }
    }
    $targetDir = $stateRoot.TrimEnd('/') + "/sub2api"
    $temporaryTarget = "$target.tmp.$([guid]::NewGuid().ToString('N'))"
    & wsl.exe -d $Distro -- mkdir -p $targetDir 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not create WSL Codex auth directory: $targetDir" }
    & wsl.exe -d $Distro -- cp $sourceWsl[0].Trim() $temporaryTarget 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not stage Codex auth inside WSL" }
    & wsl.exe -d $Distro -- chmod 600 $temporaryTarget 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not protect staged Codex auth inside WSL" }
    & wsl.exe -d $Distro -- mv -f $temporaryTarget $target 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not atomically publish Codex auth inside WSL" }
    $copiedHashOutput = @(& wsl.exe -d $Distro -- sha256sum $target 2>$null)
    $copiedHash = if ($LASTEXITCODE -eq 0 -and $copiedHashOutput.Count -gt 0) { (($copiedHashOutput[0] -split '\s+')[0]).ToLowerInvariant() } else { "" }
    if ($sourceHash -ne $copiedHash) {
      throw "WSL Codex auth hash verification failed: $target"
    }
    Write-SelfHealEvent -Event "codex_auth_synced" -Data @{ target = $target; source_mtime_utc = (Get-Item -LiteralPath $source).LastWriteTimeUtc.ToString("o") }
    return @{ status = "synced"; target = $target }
  }

  $targetDir = Join-Path $stateRoot "sub2api"
  $target = Join-Path $targetDir "codex-auth.json"
  New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

  $targetHash = ""
  if (Test-Path -LiteralPath $target) {
    $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  if ($sourceHash -eq $targetHash) {
    return @{ status = "unchanged"; target = $target }
  }

  Copy-Item -LiteralPath $source -Destination $target -Force
  Write-SelfHealEvent -Event "codex_auth_synced" -Data @{ target = $target; source_mtime_utc = (Get-Item -LiteralPath $source).LastWriteTimeUtc.ToString("o") }
  return @{ status = "synced"; target = $target }
}

function Sync-GrokBuildAuth {
  $syncScript = Join-Path $ScriptDir "sync-grok-build-auth.ps1"
  if (-not (Test-Path -LiteralPath $syncScript)) {
    return [ordered]@{ status = "disabled"; reason = "Grok Build sync script is missing" }
  }

  $syncParams = @{
    Distro = $Distro
    PostgresContainer = "sub2api-codex-postgres"
    DatabaseUser = if ($envMap.ContainsKey("POSTGRES_USER") -and $envMap["POSTGRES_USER"].Trim()) { $envMap["POSTGRES_USER"] } else { "sub2api" }
    DatabaseName = if ($envMap.ContainsKey("POSTGRES_DB") -and $envMap["POSTGRES_DB"].Trim()) { $envMap["POSTGRES_DB"] } else { "sub2api" }
    AccountName = if ($envMap.ContainsKey("SUB2API_GROK_ACCOUNT_NAME") -and $envMap["SUB2API_GROK_ACCOUNT_NAME"].Trim()) { $envMap["SUB2API_GROK_ACCOUNT_NAME"] } else { "grok-build-subscription" }
    CliBaseUrl = if ($envMap.ContainsKey("SUB2API_GROK_CLI_BASE_URL") -and $envMap["SUB2API_GROK_CLI_BASE_URL"].Trim()) { $envMap["SUB2API_GROK_CLI_BASE_URL"] } else { "https://cli-chat-proxy.grok.com/v1" }
  }
  if ($envMap.ContainsKey("SUB2API_GROK_BUILD_AUTH_FILE") -and $envMap["SUB2API_GROK_BUILD_AUTH_FILE"].Trim()) {
    $syncParams.AuthFile = $envMap["SUB2API_GROK_BUILD_AUTH_FILE"]
  }

  try {
    $raw = @(& $syncScript @syncParams 2>&1)
    $jsonLine = @($raw | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1)
    if ($jsonLine.Count -eq 0) {
      throw "Grok Build sync returned no status payload"
    }
    $result = $jsonLine[0] | ConvertFrom-Json
    $resultMap = @{}
    foreach ($property in $result.PSObject.Properties) { $resultMap[$property.Name] = $property.Value }
    Write-SelfHealEvent -Event "grok_build_auth_sync" -Data $resultMap
    return $result
  } catch {
    $failure = [ordered]@{ status = "error"; reason = $_.Exception.Message; provider = "grok"; auth_source = "grok_build_cli" }
    Write-SelfHealEvent -Event "grok_build_auth_sync_failed" -Data $failure
    return [pscustomobject]$failure
  }
}

function Sync-ClinePassAuth {
  $syncScript = Join-Path $ScriptDir "sync-cline-pass-auth.ps1"
  if (-not (Test-Path -LiteralPath $syncScript)) {
    return [ordered]@{ status = "disabled"; reason = "Cline Pass sync script is missing"; provider = "cline-pass"; auth_source = "cline_pass_cli" }
  }

  $syncParams = @{
    Distro = $Distro
    PostgresContainer = "sub2api-codex-postgres"
    DatabaseUser = if ($envMap.ContainsKey("POSTGRES_USER") -and $envMap["POSTGRES_USER"].Trim()) { $envMap["POSTGRES_USER"] } else { "sub2api" }
    DatabaseName = if ($envMap.ContainsKey("POSTGRES_DB") -and $envMap["POSTGRES_DB"].Trim()) { $envMap["POSTGRES_DB"] } else { "sub2api" }
    AccountName = if ($envMap.ContainsKey("SUB2API_CLINE_PASS_ACCOUNT_NAME") -and $envMap["SUB2API_CLINE_PASS_ACCOUNT_NAME"].Trim()) { $envMap["SUB2API_CLINE_PASS_ACCOUNT_NAME"] } else { "cline-pass-subscription" }
    GroupName = if ($envMap.ContainsKey("SUB2API_CLINE_PASS_GROUP_NAME") -and $envMap["SUB2API_CLINE_PASS_GROUP_NAME"].Trim()) { $envMap["SUB2API_CLINE_PASS_GROUP_NAME"] } else { "headroom-openai-grok-composite" }
    ClineBaseUrl = if ($envMap.ContainsKey("SUB2API_CLINE_PASS_BASE_URL") -and $envMap["SUB2API_CLINE_PASS_BASE_URL"].Trim()) { $envMap["SUB2API_CLINE_PASS_BASE_URL"] } else { "https://api.cline.bot/api/v1" }
  }
  if ($envMap.ContainsKey("SUB2API_CLINE_PASS_AUTH_FILE") -and $envMap["SUB2API_CLINE_PASS_AUTH_FILE"].Trim()) {
    $syncParams.AuthFile = $envMap["SUB2API_CLINE_PASS_AUTH_FILE"]
  }

  try {
    $raw = @(& $syncScript @syncParams 2>&1)
    $jsonLine = @($raw | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1)
    if ($jsonLine.Count -eq 0) { throw "Cline Pass sync returned no status payload" }
    $result = $jsonLine[0] | ConvertFrom-Json
    $resultMap = @{}
    foreach ($property in $result.PSObject.Properties) { $resultMap[$property.Name] = $property.Value }
    Write-SelfHealEvent -Event "cline_pass_auth_sync" -Data $resultMap
    return $result
  } catch {
    $failure = [ordered]@{ status = "error"; reason = $_.Exception.Message; provider = "cline-pass"; auth_source = "cline_pass_cli" }
    Write-SelfHealEvent -Event "cline_pass_auth_sync_failed" -Data $failure
    return [pscustomobject]$failure
  }
}

function Invoke-HealthProbe {
  param([string]$Url)

  $started = Get-Date
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri "$Url/health" -TimeoutSec $HealthTimeoutSeconds
    return [ordered]@{
      url = "$Url/health"
      ok = ($response.StatusCode -eq 200)
      status = [int]$response.StatusCode
      elapsed_ms = [Math]::Round(((Get-Date) - $started).TotalMilliseconds)
    }
  } catch {
    return [ordered]@{
      url = "$Url/health"
      ok = $false
      status = $null
      elapsed_ms = [Math]::Round(((Get-Date) - $started).TotalMilliseconds)
      error = $_.Exception.Message
    }
  }
}

function Invoke-HeadroomStatsProbe {
  param([string]$Url)

  try {
    $payload = Invoke-RestMethod -UseBasicParsing -Uri "$Url/stats" -TimeoutSec $HealthTimeoutSeconds
    $proxyInbound = $payload.proxy_inbound
    if ($null -eq $proxyInbound -or $null -eq $proxyInbound.active) {
      return [ordered]@{
        url = "$Url/stats"
        ok = $false
        active_known = $false
        active = $null
        error = "proxy_inbound.active is missing"
      }
    }
    # The request that reads /stats has already entered Headroom's inbound
    # middleware, so proxy_inbound.active includes this observer itself.
    $rawActive = [int]$proxyInbound.active
    return [ordered]@{
      url = "$Url/stats"
      ok = $true
      active_known = $true
      active = [Math]::Max(0, $rawActive - 1)
      raw_active = $rawActive
      observer_adjustment = 1
    }
  } catch {
    return [ordered]@{
      url = "$Url/stats"
      ok = $false
      active_known = $false
      active = $null
      error = $_.Exception.Message
    }
  }
}

function Get-ActiveHeadroomState {
  $candidates = @("http://127.0.0.1:$HeadroomPort")
  $wslIp = Get-WslIpv4
  if ($wslIp) { $candidates += "http://${wslIp}:$HeadroomPort" }

  foreach ($candidate in $candidates) {
    $probe = Invoke-HeadroomStatsProbe -Url $candidate
    if ($probe.ok) { return $probe }
  }

  return [ordered]@{
    url = $null
    ok = $false
    active_known = $false
    active = $null
    error = "Headroom /stats was unavailable on all local candidates"
  }
}

function Get-StackLifecycleState {
  $names = @("headroom-sub2api", "sub2api-codex")
  $records = @{}
  $known = $false
  $errorText = $null
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $lines = @(& wsl.exe -d $Distro -- bash -lc "docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}'" 2>&1)
    $exitCode = $LASTEXITCODE
    $known = ($exitCode -eq 0)
    if (-not $known) { $errorText = (($lines -join [Environment]::NewLine) -replace "`0", "").Trim() }
    foreach ($line in $lines) {
      $parts = (($line -as [string]) -split '\|', 3)
      if ($known -and $parts.Count -ge 3 -and $names -contains $parts[0]) {
        $health = if ($parts[2] -match '\((healthy|unhealthy|starting)\)') { $Matches[1] } else { "none" }
        $records[$parts[0]] = [ordered]@{ status = $parts[1]; health = $health; summary = $parts[2] }
      }
    }
  } catch {
    $known = $false
    $errorText = $_.Exception.Message
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  $headroom = if ($records.ContainsKey('headroom-sub2api')) { $records['headroom-sub2api'] } else { $null }
  $sub2api = if ($records.ContainsKey('sub2api-codex')) { $records['sub2api-codex'] } else { $null }
  return [ordered]@{
    known = $known
    error = $errorText
    headroom = $headroom
    sub2api = $sub2api
    both_running = ($known -and $null -ne $headroom -and $headroom.status -eq 'running' -and $null -ne $sub2api -and $sub2api.status -eq 'running')
    missing_or_stopped = ($known -and ($null -eq $headroom -or $headroom.status -ne 'running' -or $null -eq $sub2api -or $sub2api.status -ne 'running'))
  }
}

function Get-HeadroomImageState {
  try {
    $configured = ((@(& wsl.exe -d $Distro -- bash -lc "docker inspect -f '{{.Config.Image}}' headroom-sub2api" 2>$null)) -join "").Trim()
    $runningId = ((@(& wsl.exe -d $Distro -- bash -lc "docker inspect -f '{{.Image}}' headroom-sub2api" 2>$null)) -join "").Trim()
    if (-not $configured -or -not $runningId) {
      return [ordered]@{ ok = $false; drift = $false; target_available = $false; error = "Headroom container image metadata is unavailable" }
    }
    $targetId = ((@(& wsl.exe -d $Distro -- docker image inspect -f '{{.Id}}' $configured 2>$null)) -join "").Trim()
    return [ordered]@{
      ok = ($targetId.Length -gt 0)
      configured_image = $configured
      running_id = $runningId
      target_id = $targetId
      target_available = ($targetId.Length -gt 0)
      drift = ($targetId.Length -gt 0 -and $runningId.Length -gt 0 -and $targetId -ne $runningId)
    }
  } catch {
    return [ordered]@{ ok = $false; drift = $false; target_available = $false; error = $_.Exception.Message }
  }
}

function Invoke-HeadroomIdleRollout {
  param([System.Collections.IDictionary]$ImageState)

  $rootPortable = $Root -replace '\\', '/'
  $rootWslRaw = @(& wsl.exe -d $Distro -- wslpath -a -u -- $rootPortable 2>$null)
  $rootWslExit = $LASTEXITCODE
  $rootWsl = @($rootWslRaw | Where-Object { ([string]$_).Trim() -match '^/' } | Select-Object -First 1)
  if ($rootWslExit -ne 0 -or $rootWsl.Count -ne 1 -or -not $rootWsl[0].Trim()) {
    throw "Could not translate Headroom profile path into WSL: $Root"
  }

  $compose = "cd '$($rootWsl[0].Trim())' && docker compose --env-file .env -p '$ProjectName' -f docker-compose.yml"
  $requiresCuda = ($null -ne $envMap -and $envMap.ContainsKey('HEADROOM_REQUIRE_CUDA') -and $envMap['HEADROOM_REQUIRE_CUDA'].Trim() -eq '1')
  if ($requiresCuda) { $compose += " -f docker-compose.gpu.yml" }
  $compose += " up -d --no-deps --force-recreate headroom"
  $output = @(& wsl.exe -d $Distro -- bash -lc $compose 2>&1)
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) { throw "Headroom idle image rollout failed: $($output -join ' ')" }
  Write-SelfHealEvent -Event "headroom_image_rolled" -Data @{ image = $ImageState; service = "headroom"; compose_policy = "--no-deps --force-recreate" }
  return [ordered]@{ status = "rolled"; service = "headroom"; output = (($output -join " ").Trim()) }
}

function Get-WslIpv4 {
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & wsl.exe -d $Distro -- hostname -I 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return ((($output -join " ").Trim() -split "\s+") | Where-Object { $_ -match "^\d+\.\d+\.\d+\.\d+$" } | Select-Object -First 1)
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
}

function Test-Sub2apiDnsRoute {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& wsl.exe -d $Distro -- docker exec sub2api-codex getent ahostsv4 $DnsProbeHost 2>&1)
    $exitCode = $LASTEXITCODE
    $text = (($output -join [Environment]::NewLine) -replace "`0", "").Trim()
    return [ordered]@{
      host = $DnsProbeHost
      ok = ($exitCode -eq 0 -and $text.Length -gt 0)
      elapsed_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds)
      error = if ($exitCode -eq 0) { $null } else { $text }
    }
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
    $watch.Stop()
  }
}

function Get-HyperVSwitchIpv4 {
  if (-not $HyperVVmName.Trim()) { return $null }
  $alias = "vEthernet ($HyperVSwitchName)"
  return (Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "169.254.*" } |
    Select-Object -First 1 -ExpandProperty IPAddress)
}

function Test-HeadroomGpuRoute {
  $required = $true
  if ($null -ne $envMap -and $envMap.ContainsKey('HEADROOM_REQUIRE_CUDA')) {
    $required = $envMap['HEADROOM_REQUIRE_CUDA'].Trim() -eq '1'
  }
  if (-not $required) {
    return [ordered]@{ required = $false; ok = $true; device_requests = 'not-required' }
  }

  try {
    $probe = @(& wsl.exe -d $Distro -- bash -lc "docker inspect headroom-sub2api --format '{{json .HostConfig.DeviceRequests}}'" 2>$null)
    $raw = (($probe -join ' ') -replace '\s+', '').Trim()
    $ok = -not [string]::IsNullOrWhiteSpace($raw) -and $raw -ne 'null' -and $raw -ne '[]'
    return [ordered]@{ required = $true; ok = $ok; device_requests = if ($ok) { 'present' } else { $raw } }
  } catch {
    return [ordered]@{ required = $true; ok = $false; device_requests = 'probe-failed'; error = $_.Exception.Message }
  }
}

function Get-RequiredRouteState {
  $sameHostCandidates = @("http://127.0.0.1:$HeadroomPort")
  $wslIp = $null
  $sameHost = Invoke-HealthProbe -Url $sameHostCandidates[0]
  if (-not $sameHost.ok) {
    $wslIp = Get-WslIpv4
    if ($wslIp) {
      $sameHostCandidates += "http://${wslIp}:$HeadroomPort"
      $sameHost = Invoke-HealthProbe -Url $sameHostCandidates[-1]
    }
  }

  $bridge = $null
  if ($HyperVVmName.Trim()) {
    $switchIp = Get-HyperVSwitchIpv4
    if ($switchIp) {
      $bridge = Invoke-HealthProbe -Url "http://${switchIp}:$HeadroomPort"
    } else {
      $bridge = [ordered]@{
        url = "hyperv://$HyperVSwitchName"
        ok = $false
        status = $null
        elapsed_ms = 0
        error = "Hyper-V switch IPv4 was not found"
      }
    }
  }

  $bridgeOk = $true
  if ($RequireHyperVBridge) {
    $bridgeOk = ($null -ne $bridge -and $bridge.ok)
  }
  $gpu = Test-HeadroomGpuRoute
  $dns = Test-Sub2apiDnsRoute

  return [ordered]@{
    ok = ($sameHost.ok -and $bridgeOk -and $gpu.ok -and $dns.ok)
    same_host = $sameHost
    bridge = $bridge
    bridge_required = $RequireHyperVBridge
    wsl_ip = $wslIp
    gpu = $gpu
    dns = $dns
  }
}

function Save-State {
  param(
    [string]$Status,
    [string]$LastEventAt = ""
  )
  if (-not $LastEventAt -and (Test-Path -LiteralPath $StatePath)) {
    try {
      $previousState = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
      $LastEventAt = [string]$previousState.last_event_at
    } catch {
      $LastEventAt = ""
    }
  }
  Write-Utf8NoBom -Path $StatePath -Content (([ordered]@{
    status = $Status
    checked_at = (Get-Date).ToUniversalTime().ToString("o")
    last_event_at = $LastEventAt
  } | ConvertTo-Json -Compress) + [Environment]::NewLine)
}

$Root = Resolve-ProfileDir
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogPath = Join-Path $LogDir "self-heal.jsonl"
$StatePath = Join-Path $LogDir "self-heal-state.json"
$envMap = Read-EnvFile -Path (Join-Path $Root ".env")
$bridgeEnv = Read-EnvFile -Path (Join-Path $Root "hyperv-bridge.env")

if ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_VM_NAME") -and $bridgeEnv["HEADROOM_HYPERV_VM_NAME"].Trim()) {
  $HyperVVmName = $bridgeEnv["HEADROOM_HYPERV_VM_NAME"]
}
if ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_VM_SSH_USER") -and $bridgeEnv["HEADROOM_HYPERV_VM_SSH_USER"].Trim()) {
  $HyperVVmSshUser = $bridgeEnv["HEADROOM_HYPERV_VM_SSH_USER"]
} elseif ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_SSH_USER") -and $bridgeEnv["HEADROOM_HYPERV_SSH_USER"].Trim()) {
  $HyperVVmSshUser = $bridgeEnv["HEADROOM_HYPERV_SSH_USER"]
}
if ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_VM_SSH_KEY") -and $bridgeEnv["HEADROOM_HYPERV_VM_SSH_KEY"].Trim()) {
  $HyperVVmSshKey = $bridgeEnv["HEADROOM_HYPERV_VM_SSH_KEY"]
} elseif ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_SSH_KEY") -and $bridgeEnv["HEADROOM_HYPERV_SSH_KEY"].Trim()) {
  $HyperVVmSshKey = $bridgeEnv["HEADROOM_HYPERV_SSH_KEY"]
}
if ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_SWITCH_NAME") -and $bridgeEnv["HEADROOM_HYPERV_SWITCH_NAME"].Trim()) {
  $HyperVSwitchName = $bridgeEnv["HEADROOM_HYPERV_SWITCH_NAME"]
}
if ($bridgeEnv.ContainsKey("HEADROOM_HYPERV_REMOTE_CONFIG_MODE") -and $bridgeEnv["HEADROOM_HYPERV_REMOTE_CONFIG_MODE"].Trim()) {
  $HyperVRemoteConfigMode = $bridgeEnv["HEADROOM_HYPERV_REMOTE_CONFIG_MODE"]
}
if (-not $RequireHyperVBridge -and $bridgeEnv.ContainsKey("HEADROOM_HYPERV_REQUIRE_BRIDGE")) {
  $RequireHyperVBridge = $bridgeEnv["HEADROOM_HYPERV_REQUIRE_BRIDGE"] -match "^(1|true|yes|on)$"
}

$hyperVConfigured = $HyperVVmName.Trim().Length -gt 0
if ($hyperVConfigured) {
  Write-HyperVInventorySnapshot
}

$startScript = Join-Path $ScriptDir "start-sub2api-proxy-stack.ps1"
if (-not (Test-Path -LiteralPath $startScript)) {
  throw "Start script not found: $startScript"
}
$dnsRepairScript = Join-Path $ScriptDir "repair-wsl-dns.ps1"
if (-not (Test-Path -LiteralPath $dnsRepairScript)) {
  throw "DNS repair script not found: $dnsRepairScript"
}

$mutex = [Threading.Mutex]::new($false, "Local\sub2api-codex-proxy-stack-self-heal")
$mutexHeld = $false

try {
  $mutexHeld = $mutex.WaitOne([TimeSpan]::FromSeconds(1))
  if (-not $mutexHeld) {
    Write-SelfHealEvent -Event "check_skipped" -Data @{ reason = "another watchdog instance is active" }
    exit 0
  }

  $offlineGuestRepairRequest = Join-Path $LogDir "ghost-offline-route.request.json"
  if (Test-Path -LiteralPath $offlineGuestRepairRequest) {
    $repair = Invoke-OfflineWindowsGuestRouteRepair -RequestPath $offlineGuestRepairRequest
    $repair | ConvertTo-Json -Compress -Depth 6
    exit 0
  }
  $offlineGuestSshRequest = Join-Path $LogDir "ghost-offline-ssh.request.json"
  if (Test-Path -LiteralPath $offlineGuestSshRequest) {
    $sshSetup = Invoke-OfflineWindowsGuestSshSetup -RequestPath $offlineGuestSshRequest
    $sshSetup | ConvertTo-Json -Compress -Depth 6
    exit 0
  }
  $directGuestSshRequest = Join-Path $LogDir "ghost-powershell-direct-ssh.request.json"
  if (Test-Path -LiteralPath $directGuestSshRequest) {
    $directRepair = Invoke-PowerShellDirectWindowsGuestSshRepair -RequestPath $directGuestSshRequest
    $directRepair | ConvertTo-Json -Compress -Depth 6
    exit 0
  }
  $offlineGuestSshAuditRequest = Join-Path $LogDir "ghost-offline-ssh-audit.request.json"
  if (Test-Path -LiteralPath $offlineGuestSshAuditRequest) {
    $sshAudit = Invoke-OfflineWindowsGuestSshAudit -RequestPath $offlineGuestSshAuditRequest
    $sshAudit | ConvertTo-Json -Compress -Depth 8
    exit 0
  }

  $codexAuthSync = Sync-CodexAuthFile -ProfileRoot $Root -EnvMap $envMap
  $grokAuthSync = Sync-GrokBuildAuth
  $clinePassAuthSync = Sync-ClinePassAuth
  $before = Get-RequiredRouteState
  $dnsRepair = $null
  if (-not $before.dns.ok) {
    $dnsOutput = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $dnsRepairScript -ProfileDir $Root -Distro $Distro -ProbeHost $DnsProbeHost -RepairContainers 2>&1)
    $dnsExitCode = $LASTEXITCODE
    $dnsText = (($dnsOutput -join [Environment]::NewLine) -replace "`0", "").Trim()
    if ($dnsExitCode -eq 0) {
      $dnsRepair = $dnsText | ConvertFrom-Json
      Write-SelfHealEvent -Event "dns_repaired" -Data @{ result = $dnsRepair }
      $before = Get-RequiredRouteState
    } else {
      $dnsRepair = [ordered]@{ status = "failed"; error = $dnsText }
      Write-SelfHealEvent -Event "dns_repair_failed" -Data @{ result = $dnsRepair }
    }
  }
  if ($before.ok) {
    $imageState = Get-HeadroomImageState
    $imageRollout = $null
    if ($imageState.drift) {
      $activeState = Get-ActiveHeadroomState
      if ($activeState.ok -and $activeState.active_known -and $activeState.active -eq 0) {
        $imageRollout = Invoke-HeadroomIdleRollout -ImageState $imageState
        $afterRollout = Get-RequiredRouteState
        if (-not $afterRollout.ok) {
          throw "Headroom image rollout did not restore required routes"
        }
        $before = $afterRollout
      } else {
        $imageRollout = [ordered]@{ status = "deferred"; reason = if ($activeState.ok) { "active_proxy_requests" } else { "active_state_unproven" }; active = $activeState }
        Write-SelfHealEvent -Event "headroom_image_rollout_deferred" -Data @{ image = $imageState; rollout = $imageRollout }
      }
    }
    $writeHeartbeat = $true
    $lastEventAt = ""
    if (Test-Path -LiteralPath $StatePath) {
      try {
        $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
        $lastEventAt = [string]$state.last_event_at
        $lastEvent = if ($lastEventAt) { [DateTime]::Parse($lastEventAt).ToUniversalTime() } else { [DateTime]::MinValue }
        $writeHeartbeat = ($state.status -ne "healthy" -or ((Get-Date).ToUniversalTime() - $lastEvent).TotalMinutes -ge $HealthyHeartbeatMinutes)
      } catch {
        $writeHeartbeat = $true
      }
    }
      if ($writeHeartbeat) {
        Write-SelfHealEvent -Event "healthy" -Data @{ routes = $before; codex_auth = $codexAuthSync; grok_auth = $grokAuthSync; cline_pass_auth = $clinePassAuthSync }
      $lastEventAt = (Get-Date).ToUniversalTime().ToString("o")
    }
    $providerRoute = Invoke-ProviderRouteReconcile -ProfileRoot $Root
    Save-State -Status "healthy" -LastEventAt $lastEventAt
    [pscustomobject]@{ status = "healthy"; recovered = $false; routes = $before; dns_repair = $dnsRepair; codex_auth = $codexAuthSync; grok_auth = $grokAuthSync; cline_pass_auth = $clinePassAuthSync; provider_route = $providerRoute; headroom_image = $imageState; headroom_image_rollout = $imageRollout } | ConvertTo-Json -Compress -Depth 10
    exit 0
  }

  $bridgeOnlyFailure = ($before.same_host.ok -and $before.dns.ok -and $before.gpu.ok -and $before.bridge_required -and $null -ne $before.bridge -and -not $before.bridge.ok)
  if ($bridgeOnlyFailure) {
    Write-SelfHealEvent -Event "bridge_recovery_started" -Data @{ routes = $before }
    $bridgeParams = @{
      ProfileDir = $Root
      ProjectName = $ProjectName
      Distro = $Distro
      HeadroomPort = $HeadroomPort
      Sub2apiPort = $Sub2apiPort
      HyperVVmName = $HyperVVmName
      HyperVVmSshUser = $HyperVVmSshUser
      HyperVVmSshKey = $HyperVVmSshKey
      HyperVSwitchName = $HyperVSwitchName
      HyperVRemoteConfigMode = $HyperVRemoteConfigMode
    }
    if ($RepoRoot.Trim()) { $bridgeParams.RepoRoot = $RepoRoot }
    & $startScript @bridgeParams
    $afterBridge = Get-RequiredRouteState
    if ($afterBridge.ok) {
      $providerRoute = Invoke-ProviderRouteReconcile -ProfileRoot $Root
      Save-State -Status "healthy" -LastEventAt (Get-Date).ToUniversalTime().ToString("o")
      Write-SelfHealEvent -Event "bridge_recovered" -Data @{ routes_before = $before; routes_after = $afterBridge; compose_policy = "--no-recreate" }
      [pscustomobject]@{ status = "healthy"; recovered = $true; recovery = "bridge-only"; routes = $afterBridge; grok_auth = $grokAuthSync; cline_pass_auth = $clinePassAuthSync; provider_route = $providerRoute } | ConvertTo-Json -Compress -Depth 10
      exit 0
    }
    Write-SelfHealEvent -Event "bridge_recovery_failed" -Data @{ routes_before = $before; routes_after = $afterBridge }
    $before = $afterBridge
  }

  Save-State -Status "recovering" -LastEventAt (Get-Date).ToUniversalTime().ToString("o")
    Write-SelfHealEvent -Event "recovery_started" -Data @{ routes = $before; codex_auth = $codexAuthSync; grok_auth = $grokAuthSync; cline_pass_auth = $clinePassAuthSync }

  # A failed health probe is not proof that a compose recreate is safe. The
  # compose project contains both proxies, so recreating it can terminate a
  # live Claude SSE/tool turn even when Docker restart counters stay at zero.
  # Recreate only when active traffic is proven absent, or Docker proves that
  # one of the required containers is actually stopped/missing.
  $activeState = Get-ActiveHeadroomState
  $lifecycle = Get-StackLifecycleState
  $recoveryDecision = Get-ProxyStackRecoveryDecision -ActiveState $activeState -Lifecycle $lifecycle
  if ($recoveryDecision.action -eq "defer") {
    $reason = $recoveryDecision.reason
    Save-State -Status "deferred" -LastEventAt (Get-Date).ToUniversalTime().ToString("o")
    Write-SelfHealEvent -Event "recovery_deferred" -Data @{ reason = $reason; decision = $recoveryDecision; active = $activeState; lifecycle = $lifecycle; routes = $before }
    [pscustomobject]@{ status = "deferred"; recovered = $false; reason = $reason; decision = $recoveryDecision; active = $activeState; lifecycle = $lifecycle; routes = $before } | ConvertTo-Json -Compress -Depth 10
    exit 0
  }

  $startParams = @{
    ProfileDir = $Root
    ProjectName = $ProjectName
    Distro = $Distro
    HeadroomPort = $HeadroomPort
    Sub2apiPort = $Sub2apiPort
    HyperVVmName = $HyperVVmName
    HyperVVmSshUser = $HyperVVmSshUser
    HyperVVmSshKey = $HyperVVmSshKey
    HyperVSwitchName = $HyperVSwitchName
    HyperVRemoteConfigMode = $HyperVRemoteConfigMode
  }
  if ($recoveryDecision.force_recreate) {
    $startParams.ForceRecreate = $true
  }
  if ($RepoRoot.Trim()) { $startParams.RepoRoot = $RepoRoot }

  & $startScript @startParams

  $deadline = (Get-Date).AddSeconds($RecoveryWaitSeconds)
  do {
    $after = Get-RequiredRouteState
    if ($after.ok) {
      $providerRoute = Invoke-ProviderRouteReconcile -ProfileRoot $Root
      Save-State -Status "healthy" -LastEventAt (Get-Date).ToUniversalTime().ToString("o")
      Write-SelfHealEvent -Event "recovered" -Data @{ routes_before = $before; routes_after = $after }
        [pscustomobject]@{ status = "healthy"; recovered = $true; routes = $after; grok_auth = $grokAuthSync; cline_pass_auth = $clinePassAuthSync; provider_route = $providerRoute } | ConvertTo-Json -Compress -Depth 8
      exit 0
    }
    Start-Sleep -Seconds 3
  } while ((Get-Date) -lt $deadline)

  throw "Proxy routes did not recover within $RecoveryWaitSeconds seconds"
} catch {
  Save-State -Status "failed" -LastEventAt (Get-Date).ToUniversalTime().ToString("o")
  Write-SelfHealEvent -Event "recovery_failed" -Data @{ error = $_.Exception.Message }
  Write-Error $_
  exit 1
} finally {
  if ($mutexHeld) { $mutex.ReleaseMutex() | Out-Null }
  $mutex.Dispose()
}

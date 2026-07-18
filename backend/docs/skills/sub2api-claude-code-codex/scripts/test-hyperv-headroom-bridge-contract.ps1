param(
  [string]$ScriptPath = (Join-Path $PSScriptRoot "start-sub2api-proxy-stack.ps1")
)

$ErrorActionPreference = "Stop"
$content = Get-Content -LiteralPath $ScriptPath -Raw
$checks = [ordered]@{
  "optional sidecar config" = 'hyperv-bridge.env'
  "current Hyper-V switch discovery" = 'Get-NetIPAddress -InterfaceAlias $switchAlias'
  "current VM address discovery" = 'Get-VMNetworkAdapter -VMName $VmName'
  "stale portproxy removal" = '"portproxy", "delete", "v4tov4"'
  "current WSL portproxy target" = '"connectaddress=$WslIp"'
  "VM-scoped firewall" = '-RemoteAddress $vmIp'
  "atomic remote settings update" = 'os.replace(tmp, path)'
  "remote endpoint update" = 'ANTHROPIC_BASE_URL'
  "probe from the VM namespace" = 'HYPERV_HEADROOM_HEALTH_OK'
  "Windows settings stay BOM-free" = 'Write-Utf8NoBom -Path $settingsPath'
  "configured bridge fails closed" = 'Hyper-V SSH user/key are required when HEADROOM_HYPERV_VM_NAME is configured'
}

$failed = @()
foreach ($entry in $checks.GetEnumerator()) {
  if (-not $content.Contains($entry.Value)) {
    $failed += $entry.Key
    Write-Output "FAIL $($entry.Key)"
  } else {
    Write-Output "PASS $($entry.Key)"
  }
}

if ($failed.Count -gt 0) {
  throw "Hyper-V bridge contract failed: $($failed -join ', ')"
}

Write-Output "HYPERV_BRIDGE_CONTRACT_OK checks=$($checks.Count)"

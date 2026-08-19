param(
    [Parameter(Mandatory)]
    [string]$VmName,
    [string]$VmRoot = 'C:\VMs',
    [string]$SwitchAlias = 'vEthernet (Default Switch)'
)

$ErrorActionPreference = 'Stop'

$vmcx = Get-ChildItem -LiteralPath (Join-Path $VmRoot $VmName) -Recurse -Filter '*.vmcx' -ErrorAction SilentlyContinue |
    Select-Object -First 1
$moduleResult = try {
    Import-Module Hyper-V -Force -ErrorAction Stop
    @{ status = 'ok'; detail = 'Hyper-V module imported' }
} catch {
    @{ status = 'failed'; detail = $_.Exception.Message }
}

$neighbors = Get-NetNeighbor -InterfaceAlias $SwitchAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.State -notin 'Permanent', 'Unreachable' } |
    Select-Object IPAddress, LinkLayerAddress, State

[pscustomobject]@{
    vm_name = $VmName
    vmcx_path = $vmcx.FullName
    vmcx_guid = if ($vmcx) { [IO.Path]::GetFileNameWithoutExtension($vmcx.Name) } else { $null }
    hyperv_module = $moduleResult
    default_switch_neighbors = @($neighbors)
} | ConvertTo-Json -Depth 5

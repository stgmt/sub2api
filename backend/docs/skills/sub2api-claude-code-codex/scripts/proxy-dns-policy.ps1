function ConvertTo-ProxyDnsAddress {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  $parsed = $null
  if (-not [Net.IPAddress]::TryParse($Value.Trim(), [ref]$parsed) -or
      $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
      [Net.IPAddress]::IsLoopback($parsed) -or
      $parsed.Equals([Net.IPAddress]::Any)) {
    throw "$Name must be a non-loopback IPv4 address, got '$Value'"
  }
  return $parsed.IPAddressToString
}

function Get-ProxyDnsMapValue {
  param(
    [System.Collections.IDictionary]$Map,
    [string]$Name
  )

  if ($null -ne $Map -and $Map.Contains($Name) -and [string]$Map[$Name]) {
    return ([string]$Map[$Name]).Trim()
  }
  return ""
}

function Get-HostPrimaryDnsAddress {
  $candidates = New-Object System.Collections.Generic.List[string]

  if ($env:OS -eq "Windows_NT" -and
      (Get-Command Get-NetRoute -ErrorAction SilentlyContinue) -and
      (Get-Command Get-DnsClientServerAddress -ErrorAction SilentlyContinue)) {
    try {
      $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop |
        Sort-Object RouteMetric, InterfaceMetric)
      foreach ($route in $routes) {
        $servers = @(Get-DnsClientServerAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop)
        foreach ($server in $servers) {
          foreach ($address in @($server.ServerAddresses)) {
            if ($address) { $candidates.Add([string]$address) }
          }
        }
      }
    } catch {
      # Public fallback below remains available when Windows network cmdlets fail.
    }
  }

  if ($candidates.Count -eq 0 -and (Test-Path -LiteralPath "/etc/resolv.conf")) {
    foreach ($line in Get-Content -LiteralPath "/etc/resolv.conf" -ErrorAction SilentlyContinue) {
      if ($line -match '^\s*nameserver\s+(\S+)') { $candidates.Add($Matches[1]) }
    }
  }

  foreach ($candidate in $candidates) {
    try {
      return ConvertTo-ProxyDnsAddress -Value $candidate -Name "host DNS resolver"
    } catch {
      continue
    }
  }
  return ""
}

function Resolve-ProxyDnsSettings {
  param(
    [string]$RequestedPrimary = "auto",
    [string]$RequestedFallback = "auto",
    [System.Collections.IDictionary]$ExistingMap = @{}
  )

  $existingPrimary = Get-ProxyDnsMapValue -Map $ExistingMap -Name "SUB2API_PRIMARY_DNS"
  $existingFallback = Get-ProxyDnsMapValue -Map $ExistingMap -Name "SUB2API_FALLBACK_DNS"

  if ($RequestedPrimary.Trim() -and $RequestedPrimary.Trim() -ne "auto") {
    $primary = ConvertTo-ProxyDnsAddress -Value $RequestedPrimary -Name "Sub2apiPrimaryDns"
    $primarySource = "explicit"
  } elseif ($existingPrimary) {
    $primary = ConvertTo-ProxyDnsAddress -Value $existingPrimary -Name "SUB2API_PRIMARY_DNS"
    $primarySource = "existing_profile"
  } else {
    $detectedPrimary = Get-HostPrimaryDnsAddress
    $primary = if ($detectedPrimary) { $detectedPrimary } else { "1.1.1.1" }
    $primarySource = if ($detectedPrimary) { "host_route" } else { "public_default" }
  }

  if ($RequestedFallback.Trim() -and $RequestedFallback.Trim() -ne "auto") {
    $fallback = ConvertTo-ProxyDnsAddress -Value $RequestedFallback -Name "Sub2apiFallbackDns"
    $fallbackSource = "explicit"
  } elseif ($existingFallback) {
    $fallback = ConvertTo-ProxyDnsAddress -Value $existingFallback -Name "SUB2API_FALLBACK_DNS"
    $fallbackSource = "existing_profile"
  } else {
    $fallback = if ($primary -ne "1.1.1.1") { "1.1.1.1" } else { "8.8.8.8" }
    $fallbackSource = "public_default"
  }

  return [pscustomobject]@{
    primary = $primary
    fallback = $fallback
    primary_source = $primarySource
    fallback_source = $fallbackSource
  }
}

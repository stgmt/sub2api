function Get-ProxyStackRecoveryDecision {
  param(
    [Parameter(Mandatory = $true)]$ActiveState,
    [Parameter(Mandatory = $true)]$Lifecycle
  )

  if (-not $Lifecycle.known) {
    return [ordered]@{ action = "defer"; reason = "lifecycle_state_unproven"; force_recreate = $false }
  }
  if ($Lifecycle.missing_or_stopped) {
    return [ordered]@{ action = "start-missing"; reason = "required_container_missing_or_stopped"; force_recreate = $false }
  }
  if ($ActiveState.ok -and $ActiveState.active_known -and $ActiveState.active -eq 0 -and $Lifecycle.both_running) {
    return [ordered]@{ action = "recreate-idle"; reason = "proven_idle_running_stack"; force_recreate = $true }
  }
  if ($ActiveState.ok -and $ActiveState.active_known -and $ActiveState.active -gt 0) {
    return [ordered]@{ action = "defer"; reason = "active_proxy_requests"; force_recreate = $false }
  }
  return [ordered]@{ action = "defer"; reason = "active_state_unproven"; force_recreate = $false }
}

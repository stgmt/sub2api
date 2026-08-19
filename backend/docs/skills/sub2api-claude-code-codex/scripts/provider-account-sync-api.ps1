Set-StrictMode -Version Latest

function Sync-Sub2apiProviderAccount {
  param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$ProviderSyncToken,
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$AccountName,
    [Parameter(Mandatory = $true)][string]$Platform,
    [Parameter(Mandatory = $true)][string]$AccountType,
    [Parameter(Mandatory = $true)][hashtable]$Credentials,
    [Parameter(Mandatory = $true)][hashtable]$Extra,
    [Parameter(Mandatory = $true)][string]$GroupName,
    [Parameter(Mandatory = $true)][hashtable]$GroupBody,
    [int]$Concurrency = 3,
    [int]$Priority = 0,
    [double]$RateMultiplier = 1.0
  )
  if ([string]::IsNullOrWhiteSpace($ProviderSyncToken)) {
    throw "ProviderSyncToken is required for service-owned provider synchronization"
  }
  $body = [ordered]@{
    source = $Source
    account_name = $AccountName
    platform = $Platform
    account_type = $AccountType
    credentials = $Credentials
    extra = $Extra
    group_name = $GroupName
    group_platform = [string]$GroupBody.platform
    subscription_type = [string]$GroupBody.subscription_type
    require_oauth_only = [bool]$GroupBody.require_oauth_only
    concurrency = $Concurrency
    priority = $Priority
    rate_multiplier = $RateMultiplier
  }
  if ($GroupBody.Contains("models_list_config")) {
    $body.models_list_config = $GroupBody.models_list_config
  }
  $response = Invoke-RestMethod -Method Post `
    -Uri "$($BaseUrl.TrimEnd('/'))/api/v1/provider-sync/accounts" `
    -Headers @{ "X-Provider-Sync-Key" = $ProviderSyncToken } `
    -ContentType "application/json" `
    -Body ($body | ConvertTo-Json -Compress -Depth 20) `
    -TimeoutSec 30
  if ($null -eq $response.data -or [int64]$response.data.account_id -le 0) {
    throw "provider sync API returned an invalid response"
  }
  return $response.data
}

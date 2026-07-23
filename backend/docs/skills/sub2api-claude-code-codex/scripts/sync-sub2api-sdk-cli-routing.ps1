[CmdletBinding()]
param(
  [string]$GroupName = "codex-gpt56-claude-code",
  [string]$Model = "qwen3.8-max-preview",
  [ValidateSet("low", "medium", "high", "xhigh", "max")]
  [string]$Effort = "high",
  [string]$PostgresContainer = "sub2api-codex-postgres",
  [string]$RedisContainer = "sub2api-codex-redis",
  [string]$WslDistro = "Ubuntu-24.04",
  [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

function ConvertTo-SqlLiteral([string]$Value) {
  return $Value.Replace("'", "''")
}

function Clear-APIKeyAuthCache {
  $lua = "local keys=redis.call('keys',ARGV[1]); if #keys > 0 then return redis.call('del',unpack(keys)) end; return 0"
  if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    $output = @(& wsl.exe -d $WslDistro -- docker exec $RedisContainer redis-cli --raw EVAL $lua 0 "apikey:auth:*" 2>&1)
  } else {
    $output = @(& docker exec $RedisContainer redis-cli --raw EVAL $lua 0 "apikey:auth:*" 2>&1)
  }
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to invalidate API-key auth cache: $($output -join [Environment]::NewLine)"
  }
  Write-Host "Invalidated cached API-key snapshots: $($output[-1])"
}

function Invoke-PostgresSql([string]$Sql) {
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Sql))
  if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    $command = "printf '%s' '$encoded' | base64 -d | docker exec -i '$PostgresContainer' psql -v ON_ERROR_STOP=1 -U sub2api -d sub2api -At"
    $output = @(& wsl.exe -d $WslDistro -- bash -lc $command 2>&1)
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to configure sdk-cli routing through WSL: $($output -join [Environment]::NewLine)"
    }
    return $output
  }

  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Neither wsl.exe nor docker is available"
  }

  $tempFile = [IO.Path]::GetTempFileName()
  $containerFile = "/tmp/sub2api-sdk-cli-routing-$PID.sql"
  try {
    [IO.File]::WriteAllText($tempFile, $Sql, [Text.UTF8Encoding]::new($false))
    & docker cp $tempFile "${PostgresContainer}:$containerFile" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker cp failed" }
    $output = @(& docker exec $PostgresContainer psql -v ON_ERROR_STOP=1 -U sub2api -d sub2api -At -f $containerFile 2>&1)
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to configure sdk-cli routing: $($output -join [Environment]::NewLine)"
    }
    return $output
  } finally {
    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    & docker exec $PostgresContainer rm -f $containerFile 2>$null | Out-Null
  }
}

$groupSql = ConvertTo-SqlLiteral $GroupName
$modelSql = ConvertTo-SqlLiteral $Model
$effortSql = ConvertTo-SqlLiteral $Effort.ToLowerInvariant()

if (-not $CheckOnly) {
  $updateSql = @"
DO `$`$
DECLARE
  affected integer;
BEGIN
  UPDATE groups
  SET messages_dispatch_model_config =
    jsonb_set(
      jsonb_set(
        COALESCE(messages_dispatch_model_config, '{}'::jsonb),
        '{sdk_cli_mapped_model}',
        to_jsonb('$modelSql'::text),
        true
      ),
      '{sdk_cli_reasoning_effort}',
      to_jsonb('$effortSql'::text),
      true
    ),
    updated_at = now()
  WHERE name = '$groupSql' AND platform = 'openai';
  GET DIAGNOSTICS affected = ROW_COUNT;
  IF affected <> 1 THEN
    RAISE EXCEPTION 'Expected one OpenAI group named %, updated %', '$groupSql', affected;
  END IF;
END
`$`$;
"@
  Invoke-PostgresSql $updateSql | Out-Null
  Clear-APIKeyAuthCache
}

$checkSql = @"
SELECT id || '|' || name || '|' ||
       COALESCE(messages_dispatch_model_config->>'sdk_cli_mapped_model', '') || '|' ||
       COALESCE(messages_dispatch_model_config->>'sdk_cli_reasoning_effort', '')
FROM groups
WHERE name = '$groupSql'
  AND platform = 'openai'
  AND messages_dispatch_model_config->>'sdk_cli_mapped_model' = '$modelSql'
  AND messages_dispatch_model_config->>'sdk_cli_reasoning_effort' = '$effortSql';
"@
$proof = @(Invoke-PostgresSql $checkSql | Where-Object { $_ -and $_.Trim() })
if ($proof.Count -ne 1) {
  throw "sdk-cli routing contract is not active for group '$GroupName'"
}
Write-Host "SUB2API_SDK_CLI_ROUTING_OK $($proof[0])"

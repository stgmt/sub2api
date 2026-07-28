[CmdletBinding()]
param(
  [string]$TerraWorktree = (Join-Path (Get-Location) "work\dev-pomogator-issue153-terra-v3"),
  [string]$QwenWorktree = (Join-Path (Get-Location) "work\dev-pomogator-issue153-qwen-v3"),
  [string]$OutputRoot = (Join-Path (Get-Location) "outputs\issue153-model-bench"),
  [string]$TerraModel = "gpt-5.6-terra-high",
  [ValidateSet('low','medium','high','xhigh','max')]
  [string]$TerraEffort = "high",
  [string]$QwenModel = "qwen3.8-max-preview",
  [ValidateSet('low','medium','high','xhigh','max')]
  [string]$QwenEffort = "medium",
  [int]$TimeoutMinutes = 90,
  [switch]$RoutePreflightOnly
)

$ErrorActionPreference = "Stop"
$claude = "$HOME\.local\bin\claude.exe"
$headroom = "http://127.0.0.1:8787"
$postgres = "sub2api-codex-postgres"
$wslDistro = "Ubuntu-24.04"
$runId = [DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$runRoot = Join-Path $OutputRoot $runId
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

function Invoke-DbSql([string]$Sql) {
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Sql))
  $command = "printf '%s' '$encoded' | base64 -d | docker exec -i '$postgres' psql -v ON_ERROR_STOP=1 -U sub2api -d sub2api -At"
  $output = @(& wsl.exe -d $wslDistro -- bash -lc $command 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "Postgres command failed: $($output -join [Environment]::NewLine)" }
  return $output
}

function New-BenchmarkGroup([string]$Name, [int64]$SourceGroupId, [string]$MappedModel, [string]$Effort) {
  $description = "Ephemeral isolated benchmark group cloned from $SourceGroupId; SDK CLI pinned to $MappedModel/$Effort."
  $sql = @"
INSERT INTO groups
SELECT (jsonb_populate_record(
  NULL::groups,
  to_jsonb(g) || jsonb_build_object(
    'id', nextval('groups_id_seq'),
    'name', '$Name',
    'description', '$description',
    'status', 'active',
    'created_at', now(),
    'updated_at', now(),
    'deleted_at', NULL,
    'supported_model_scopes', COALESCE(NULLIF(g.supported_model_scopes, 'null'::jsonb), '["claude","gemini_text","gemini_image"]'::jsonb),
    'messages_dispatch_model_config',
      g.messages_dispatch_model_config || jsonb_build_object(
        'sdk_cli_mapped_model', '$MappedModel',
        'sdk_cli_reasoning_effort', '$Effort',
        'plan_mapped_model', '$MappedModel',
        'plan_reasoning_effort', '$Effort',
        'compact_mapped_model', '$MappedModel',
        'compact_reasoning_effort', '$Effort',
        'opus_mapped_model', '$MappedModel',
        'sonnet_mapped_model', '$MappedModel',
        'haiku_mapped_model', '$MappedModel',
        'model_fallbacks', '{}'::jsonb
      )
  )
)).*
FROM groups g
WHERE g.id = $SourceGroupId
RETURNING id;
"@
  $id = [int64](@(Invoke-DbSql $sql)[0])
  return [pscustomobject]@{ Id = $id; Name = $Name; SourceGroupId = $SourceGroupId; Model = $MappedModel; Effort = $Effort }
}

function Disable-BenchmarkGroup($Group) {
  if ($null -eq $Group) { return }
  Invoke-DbSql "UPDATE groups SET status='inactive',updated_at=now() WHERE id=$($Group.Id);" | Out-Null
}

function New-BenchmarkKey([string]$Name, [int64]$GroupId) {
  $token = "sk-bench-$([Guid]::NewGuid().ToString('N'))"
  $sql = "INSERT INTO api_keys(user_id,key,name,group_id,status,expires_at) VALUES (1,'$token','$Name',$GroupId,'active',now()+interval '2 hours') RETURNING id;"
  $id = [int64](@(Invoke-DbSql $sql)[0])
  return [pscustomobject]@{ Id = $id; Token = $token; Name = $Name; GroupId = $GroupId }
}

function Disable-BenchmarkKey($Key) {
  if ($null -eq $Key) { return }
  Invoke-DbSql "UPDATE api_keys SET status='inactive',expires_at=now(),updated_at=now() WHERE id=$($Key.Id);" | Out-Null
}

function New-ClaudeProcess([string]$Label, [string]$Worktree, [string]$Model, [string]$Effort, [string]$Token, [string]$Prompt) {
  $settingsPath = Join-Path $runRoot "$Label-settings.json"
  $settings = [ordered]@{
    env = [ordered]@{
      ANTHROPIC_BASE_URL = $headroom
      ANTHROPIC_AUTH_TOKEN = $Token
      ANTHROPIC_MODEL = $Model
      ANTHROPIC_SMALL_FAST_MODEL = $Model
      ANTHROPIC_DEFAULT_HAIKU_MODEL = $Model
      ANTHROPIC_DEFAULT_SONNET_MODEL = $Model
      ANTHROPIC_DEFAULT_OPUS_MODEL = $Model
      CLAUDE_CODE_SUBAGENT_MODEL = $Model
      CLAUDE_CODE_EFFORT_LEVEL = $Effort
      CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS = '10'
      CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH = '1'
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
      CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK = '1'
    }
  }
  [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))

  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $claude
  $psi.WorkingDirectory = $Worktree
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  foreach ($arg in @('--settings',$settingsPath,'--model',$Model,'--effort',$Effort,'--print','--output-format','json','--dangerously-skip-permissions',$Prompt)) {
    $psi.ArgumentList.Add($arg)
  }
  $psi.Environment['ANTHROPIC_BASE_URL'] = $headroom
  $psi.Environment['ANTHROPIC_AUTH_TOKEN'] = $Token
  $psi.Environment['ANTHROPIC_MODEL'] = $Model
  $psi.Environment['ANTHROPIC_SMALL_FAST_MODEL'] = $Model
  $psi.Environment['ANTHROPIC_DEFAULT_HAIKU_MODEL'] = $Model
  $psi.Environment['ANTHROPIC_DEFAULT_SONNET_MODEL'] = $Model
  $psi.Environment['ANTHROPIC_DEFAULT_OPUS_MODEL'] = $Model
  $psi.Environment['CLAUDE_CODE_SUBAGENT_MODEL'] = $Model
  $psi.Environment['CLAUDE_CODE_EFFORT_LEVEL'] = $Effort
  $psi.Environment['CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS'] = '10'
  $psi.Environment['CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH'] = '1'
  $psi.Environment['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'] = '1'
  $psi.Environment['CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK'] = '1'

  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $psi
  if (-not $process.Start()) { throw "Failed to start $Label" }
  return [pscustomobject]@{
    Label = $Label
    Worktree = $Worktree
    Model = $Model
    Effort = $Effort
    SettingsPath = $settingsPath
    Process = $process
    StdoutTask = $process.StandardOutput.ReadToEndAsync()
    StderrTask = $process.StandardError.ReadToEndAsync()
    StartedAt = [DateTimeOffset]::UtcNow
    CompletedAt = $null
  }
}

function Finish-ClaudeProcess($Run) {
  $stdout = $Run.StdoutTask.GetAwaiter().GetResult()
  $stderr = $Run.StderrTask.GetAwaiter().GetResult()
  $claudeResult = $null
  try { $claudeResult = $stdout | ConvertFrom-Json } catch {}
  $stdoutPath = Join-Path $runRoot "$($Run.Label)-stdout.json"
  $stderrPath = Join-Path $runRoot "$($Run.Label)-stderr.log"
  [IO.File]::WriteAllText($stdoutPath, $stdout, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($stderrPath, $stderr, [Text.UTF8Encoding]::new($false))
  $statusPath = Join-Path $runRoot "$($Run.Label)-git-status.txt"
  $diffPath = Join-Path $runRoot "$($Run.Label)-diff.patch"
  $status = @(& git -C $Run.Worktree status --short 2>&1) -join [Environment]::NewLine
  $diff = @(& git -C $Run.Worktree diff --binary 2>&1) -join [Environment]::NewLine
  [IO.File]::WriteAllText($statusPath, $status, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($diffPath, $diff, [Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{
    label = $Run.Label
    model = $Run.Model
    effort = $Run.Effort
    exit_code = $Run.Process.ExitCode
    duration_seconds = [math]::Round((($Run.CompletedAt ?? [DateTimeOffset]::UtcNow) - $Run.StartedAt).TotalSeconds, 1)
    claude_duration_seconds = if ($claudeResult -and $claudeResult.duration_ms) { [math]::Round([double]$claudeResult.duration_ms / 1000, 3) } else { $null }
    api_duration_seconds = if ($claudeResult -and $claudeResult.duration_api_ms) { [math]::Round([double]$claudeResult.duration_api_ms / 1000, 3) } else { $null }
    turns = if ($claudeResult) { $claudeResult.num_turns } else { $null }
    session_id = if ($claudeResult) { $claudeResult.session_id } else { $null }
    model_usage = if ($claudeResult) { $claudeResult.modelUsage } else { $null }
    stdout = $stdoutPath
    stderr = $stderrPath
    git_status = $statusPath
    diff = $diffPath
  }
}

$terraKey = $null
$qwenKey = $null
$terraGroup = $null
$qwenGroup = $null
$runs = @()
try {
  if (-not (Test-Path -LiteralPath $claude)) { throw "Claude Code binary not found: $claude" }
  foreach ($path in @($TerraWorktree,$QwenWorktree)) {
    if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { throw "Benchmark worktree not found: $path" }
    if (@(& git -C $path status --porcelain).Count -ne 0) { throw "Benchmark worktree is not clean: $path" }
  }
  $terraHead = @(& git -C $TerraWorktree rev-parse HEAD)[0]
  $qwenHead = @(& git -C $QwenWorktree rev-parse HEAD)[0]
  if ($terraHead -ne $qwenHead) { throw "Benchmark worktrees do not share one baseline: $terraHead != $qwenHead" }
  $groups = @(Invoke-DbSql "SELECT id || chr(9) || name FROM groups WHERE id IN (8,11) ORDER BY id;")
  if ($groups -notcontains "8`tcodex-gpt56-claude-code" -or $groups -notcontains "11`tchatgpt-subscription-only") {
    throw "Expected benchmark groups 8 and 11 are not available"
  }

  if ($RoutePreflightOnly) {
    $nonce = "ISSUE153_ROUTE_PREFLIGHT_$runId"
    $prompt = "Delegate exactly two read-only tasks: (1) built-in Explore reads package.json and returns its package name; (2) built-in Plan reads package.json scripts and proposes one relevant verification command without editing. Then reply with both results and nonce $nonce. Do not inspect the file yourself."
  } else {
    $issue = gh issue view 153 --repo stgmt/dev-pomogator --json title,body,url | ConvertFrom-Json
    $prompt = @"
You are one arm of a controlled model benchmark. Implement GitHub issue #153 end-to-end in this isolated checkout.

Issue: $($issue.title)
URL: $($issue.url)

$($issue.body)

Benchmark rules:
- Do the implementation now; do not stop at a plan or ask the user questions.
- Start from this checkout only. Do not inspect sibling worktrees, prior benchmark artifacts, prior Claude sessions, or earlier implementations of issue #153.
- Inspect the actual repository contracts before editing. Follow its AGENTS.md/CLAUDE.md/spec workflow.
- Implement the smallest complete production solution, including machine-checkable artifact/state integration and focused regression/BDD coverage required by the issue.
- Run the strongest relevant tests that fit the time budget and repair failures caused by your changes.
- Do not report a partial result as complete. Use the full 90-minute budget when necessary and stop early only when every issue requirement is implemented and verified, or when a concrete external blocker is proven by command output.
- Do not commit, push, create PRs/issues, or modify files outside this worktree.
- Do not weaken or bypass existing gates to obtain green tests.
- End with a concise report: implementation status, exact files changed, tests and outcomes, unresolved requirements, and residual risks.
"@
  }
  [IO.File]::WriteAllText((Join-Path $runRoot 'prompt.txt'), $prompt, [Text.UTF8Encoding]::new($false))

  $terraGroup = New-BenchmarkGroup "bench-issue153-terra-$runId" 11 $TerraModel $TerraEffort
  $qwenGroup = New-BenchmarkGroup "bench-issue153-qwen-$runId" 8 $QwenModel $QwenEffort
  $terraKey = New-BenchmarkKey "bench-issue153-terra-$runId" $terraGroup.Id
  $qwenKey = New-BenchmarkKey "bench-issue153-qwen-$runId" $qwenGroup.Id
  [IO.File]::WriteAllText((Join-Path $runRoot 'key-ids.json'), ([pscustomobject]@{
    terra_key=$terraKey.Id
    qwen_key=$qwenKey.Id
    terra_group=$terraGroup.Id
    qwen_group=$qwenGroup.Id
  } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

  $runs = @(
    (New-ClaudeProcess 'terra-high' $TerraWorktree $TerraModel $TerraEffort $terraKey.Token $prompt),
    (New-ClaudeProcess 'qwen-medium' $QwenWorktree $QwenModel $QwenEffort $qwenKey.Token $prompt)
  )
  Write-Output "BENCH_START run=$runId terra_pid=$($runs[0].Process.Id) qwen_pid=$($runs[1].Process.Id)"

  $deadline = [DateTimeOffset]::UtcNow.AddMinutes($TimeoutMinutes)
  while (@($runs | Where-Object { -not $_.Process.HasExited }).Count -gt 0 -and [DateTimeOffset]::UtcNow -lt $deadline) {
    Start-Sleep -Seconds 30
    foreach ($run in $runs | Where-Object { $_.Process.HasExited -and $null -eq $_.CompletedAt }) {
      $run.CompletedAt = [DateTimeOffset]::UtcNow
    }
    $state = $runs | ForEach-Object {
      "$($_.Label):$($(if ($_.Process.HasExited) { 'done' } else { 'running' })):cpu=$([math]::Round($_.Process.TotalProcessorTime.TotalSeconds,1))s"
    }
    Write-Output "BENCH_PROGRESS elapsed=$([math]::Round(([DateTimeOffset]::UtcNow-$runs[0].StartedAt).TotalMinutes,1))m $($state -join ' ')"
  }
  foreach ($run in $runs | Where-Object { -not $_.Process.HasExited }) {
    $run.Process.Kill($true)
    $run.CompletedAt = [DateTimeOffset]::UtcNow
    Write-Output "BENCH_TIMEOUT label=$($run.Label)"
  }
  foreach ($run in $runs) { $run.Process.WaitForExit() }
  foreach ($run in $runs | Where-Object { $null -eq $_.CompletedAt }) { $run.CompletedAt = [DateTimeOffset]::UtcNow }
  $results = @($runs | ForEach-Object { Finish-ClaudeProcess $_ })
  $usage = @(Invoke-DbSql "SELECT api_key_id || chr(9) || requested_model || chr(9) || model || chr(9) || coalesce(reasoning_effort,'') || chr(9) || count(*) || chr(9) || sum(input_tokens) || chr(9) || sum(output_tokens) FROM usage_logs WHERE api_key_id IN ($($terraKey.Id),$($qwenKey.Id)) GROUP BY api_key_id,requested_model,model,reasoning_effort ORDER BY api_key_id,model,reasoning_effort;")
  [IO.File]::WriteAllLines((Join-Path $runRoot 'usage-by-key.tsv'), $usage, [Text.UTF8Encoding]::new($false))
  if (@($usage | Where-Object { $_ -like "$($terraKey.Id)`t*" }).Count -eq 0) { throw "Terra benchmark key recorded no usage" }
  if (@($usage | Where-Object { $_ -like "$($qwenKey.Id)`t*" }).Count -eq 0) { throw "Qwen benchmark key recorded no usage" }
  foreach ($row in $usage) {
    $cells = $row -split "`t"
    $keyId, $requestedModel, $actualModel, $actualEffort = $cells[0..3]
    if ($keyId -eq [string]$terraKey.Id -and ($requestedModel -ne $TerraModel -or $actualModel -ne $TerraModel -or $actualEffort -ne $TerraEffort)) {
      throw "Terra route contamination: $row"
    }
    if ($keyId -eq [string]$qwenKey.Id -and ($requestedModel -ne $QwenModel -or $actualModel -ne $QwenModel -or $actualEffort -ne $QwenEffort)) {
      throw "Qwen route contamination: $row"
    }
  }
  [IO.File]::WriteAllText((Join-Path $runRoot 'run-results.json'), ($results | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
  [pscustomobject]@{run_id=$runId;run_root=$runRoot;terra_key_id=$terraKey.Id;qwen_key_id=$qwenKey.Id;results=$results} | ConvertTo-Json -Depth 6 -Compress
} finally {
  foreach ($run in $runs) {
    if ($run.Process -and -not $run.Process.HasExited) {
      try { $run.Process.Kill($true) } catch {}
    }
  }
  Disable-BenchmarkKey $terraKey
  Disable-BenchmarkKey $qwenKey
  Disable-BenchmarkGroup $terraGroup
  Disable-BenchmarkGroup $qwenGroup
  foreach ($run in $runs) {
    if ($run.SettingsPath -and (Test-Path -LiteralPath $run.SettingsPath)) {
      Remove-Item -LiteralPath $run.SettingsPath -Force
    }
  }
}

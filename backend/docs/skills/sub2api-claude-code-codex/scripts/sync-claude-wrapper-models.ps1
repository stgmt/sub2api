[CmdletBinding()]
param(
  [string]$Path = (Join-Path $env:USERPROFILE ".local\bin\claude.cmd"),
  [string]$Model = "gpt-5.6-sol",
  [string]$SmallFastModel = "qwen3.8-max-preview",
  [string]$DefaultOpusModel = "qwen3.8-max-preview",
  [string]$DefaultFableModel = "qwen3.8-max-preview",
  [string]$DefaultSonnetModel = "qwen3.8-max-preview",
  [string]$DefaultHaikuModel = "qwen3.8-max-preview",
  [string]$SubagentModel = "qwen3.8-max-preview",
  [switch]$CheckOnly,
  [switch]$SkipBackup
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Path)) {
  Write-Host "Claude command wrapper absent; settings/User env remain authoritative: $Path"
  return
}

$expected = [ordered]@{
  ANTHROPIC_MODEL = $Model
  ANTHROPIC_SMALL_FAST_MODEL = $SmallFastModel
  ANTHROPIC_DEFAULT_OPUS_MODEL = $DefaultOpusModel
  ANTHROPIC_DEFAULT_FABLE_MODEL = $DefaultFableModel
  ANTHROPIC_DEFAULT_SONNET_MODEL = $DefaultSonnetModel
  ANTHROPIC_DEFAULT_HAIKU_MODEL = $DefaultHaikuModel
  CLAUDE_CODE_SUBAGENT_MODEL = $SubagentModel
}

$text = Get-Content -Raw -LiteralPath $Path
$lines = [System.Collections.Generic.List[string]]::new()
foreach ($line in ($text -split "\r?\n")) { $lines.Add($line) }

$mismatches = [System.Collections.Generic.List[string]]::new()
$missing = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $expected.GetEnumerator()) {
  $pattern = '^\s*set\s+"' + [regex]::Escape($entry.Key) + '=([^"]*)"\s*$'
  $index = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $pattern) {
      $index = $i
      if ($Matches[1] -ne [string]$entry.Value) {
        $mismatches.Add("$($entry.Key): $($Matches[1]) -> $($entry.Value)")
        if (-not $CheckOnly) { $lines[$i] = "set `"$($entry.Key)=$($entry.Value)`"" }
      }
      break
    }
  }
  if ($index -lt 0) { $missing.Add($entry.Key) }
}

if ($CheckOnly) {
  if ($missing.Count -gt 0 -or $mismatches.Count -gt 0) {
    $details = @($mismatches) + @($missing | ForEach-Object { "${_}: missing" })
    throw "Claude command wrapper overrides the configured model profile: $($details -join '; ')"
  }
  Write-Host "Claude command wrapper model contract: OK ($Path)"
  return
}

if ($missing.Count -gt 0) {
  $insertAt = $lines.Count
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '(?i)claude-real\.exe') { $insertAt = $i; break }
  }
  foreach ($key in $missing) {
    $lines.Insert($insertAt, "set `"$key=$($expected[$key])`"")
    $insertAt++
  }
}

if ($missing.Count -eq 0 -and $mismatches.Count -eq 0) {
  Write-Host "Claude command wrapper model contract already current: $Path"
  return
}

if (-not $SkipBackup) {
  Copy-Item -LiteralPath $Path -Destination "$Path.bak-sub2api-$(Get-Date -Format yyyyMMddHHmmss)"
}
$utf8 = [System.Text.UTF8Encoding]::new($false)
$updated = (($lines -join "`r`n").TrimEnd("`r", "`n") + "`r`n")
[System.IO.File]::WriteAllText($Path, $updated, $utf8)
Write-Host "Claude command wrapper model contract synchronized: $Path"

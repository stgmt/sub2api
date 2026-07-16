param(
  [string]$Version = "v0.42.4",
  [string]$InstallDir = (Join-Path $env:USERPROFILE ".local\bin"),
  [string]$WslDistro = "Ubuntu-24.04",
  [string[]]$ExcludeCommands = @("cat", "git diff", "git show", "curl"),
  [switch]$SkipWsl,
  [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  $parent = Split-Path -Parent $Path
  if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8)
}

function Invoke-GitBashUtf8Stdin([string]$GitBash, [string]$Command, [string]$InputText) {
  $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($InputText))
  $probeCommand = "printf '%s' '$encoded' | base64 -d | $Command"
  $output = @(& $GitBash -lc $probeCommand 2>&1)
  [pscustomobject]@{
    ExitCode = $LASTEXITCODE
    Output = $output
  }
}

function Set-ObjectProperty([object]$Object, [string]$Name, [object]$Value) {
  if ($Object.PSObject.Properties[$Name]) {
    $Object.PSObject.Properties[$Name].Value = $Value
  } else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Get-RtkVersion([string]$Path) {
  $output = (& $Path --version 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $output -notmatch '^rtk\s+\d+\.\d+\.\d+') {
    throw "Invalid RTK binary at ${Path}: $output"
  }
  return $output
}

function Ensure-UserPath([string]$Path) {
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $parts = @($userPath -split ";" | Where-Object { $_ -and $_.Trim() })
  $normalized = $Path.TrimEnd("\")
  if (-not ($parts | Where-Object { $_.TrimEnd("\") -ieq $normalized })) {
    $parts += $Path
    [Environment]::SetEnvironmentVariable("Path", ($parts -join ";"), "User")
  }
  if (-not (($env:Path -split ";") | Where-Object { $_.TrimEnd("\") -ieq $normalized })) {
    $env:Path = "$Path;$env:Path"
  }
}

function Merge-RtkHookExclusions([string]$ConfigPath, [string[]]$Commands) {
  $text = if (Test-Path -LiteralPath $ConfigPath) {
    Get-Content -Raw -LiteralPath $ConfigPath
  } else {
    ""
  }

  $section = [regex]::Match($text, '(?ms)(?<header>^\[hooks\]\s*\r?\n)(?<body>.*?)(?=^\[|\z)')
  $existing = @()
  if ($section.Success) {
    $lineMatch = [regex]::Match($section.Groups['body'].Value, '(?m)^\s*exclude_commands\s*=\s*\[(?<values>[^\]]*)\]\s*$')
    if ($lineMatch.Success) {
      foreach ($match in [regex]::Matches($lineMatch.Groups['values'].Value, '"(?<value>(?:\\.|[^"])*)"')) {
        $existing += $match.Groups['value'].Value.Replace('\"', '"').Replace('\\', '\')
      }
    }
  }

  $merged = @()
  foreach ($command in @($existing) + @($Commands)) {
    if ($command -and $merged -notcontains $command) { $merged += $command }
  }
  $quoted = @($merged | ForEach-Object { '"' + $_.Replace('\', '\\').Replace('"', '\"') + '"' })
  $newLine = "exclude_commands = [$($quoted -join ', ')]"

  if ($section.Success) {
    $body = $section.Groups['body'].Value
    $lineMatch = [regex]::Match($body, '(?m)^\s*exclude_commands\s*=\s*\[[^\]]*\]\s*$')
    if ($lineMatch.Success) {
      $body = $body.Remove($lineMatch.Index, $lineMatch.Length).Insert($lineMatch.Index, $newLine)
    } else {
      $body = "$newLine`r`n$body"
    }
    $replacement = $section.Groups['header'].Value + $body
    $text = $text.Remove($section.Index, $section.Length).Insert($section.Index, $replacement)
  } else {
    if ($text -and -not $text.EndsWith("`n")) { $text += "`r`n" }
    $text += "`r`n[hooks]`r`n$newLine`r`n"
  }

  Write-Utf8NoBom -Path $ConfigPath -Content $text
}

function Install-WindowsRtk {
  if (-not [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
    throw "install-claude-rtk.ps1 currently expects a Windows host. Run rtk init --global --auto-patch directly on Linux/macOS."
  }
  if ($Version -notmatch '^v?\d+\.\d+\.\d+$') { throw "Invalid RTK version: $Version" }

  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $target = Join-Path $InstallDir "rtk.exe"
  $expected = "rtk $($Version.TrimStart('v'))"
  $current = if (Test-Path -LiteralPath $target) {
    try { Get-RtkVersion $target } catch { "" }
  } else { "" }

  if ($Force -or $current -ne $expected) {
    $tempDir = Join-Path $env:TEMP ("sub2api-rtk-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    try {
      $archive = Join-Path $tempDir "rtk.zip"
      $url = "https://github.com/rtk-ai/rtk/releases/download/$Version/rtk-x86_64-pc-windows-msvc.zip"
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
      Expand-Archive -LiteralPath $archive -DestinationPath $tempDir -Force
      $source = Get-ChildItem -LiteralPath $tempDir -Recurse -Filter "rtk.exe" | Select-Object -First 1 -ExpandProperty FullName
      if (-not $source) { throw "RTK archive did not contain rtk.exe: $url" }
      $downloaded = Get-RtkVersion $source
      if ($downloaded -ne $expected) { throw "Expected $expected, downloaded $downloaded" }
      Copy-Item -LiteralPath $source -Destination $target -Force
    } finally {
      Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  Ensure-UserPath $InstallDir
  $installed = Get-RtkVersion $target
  if ($installed -ne $expected) { throw "RTK install verification failed: $installed" }

  & $target init --global --auto-patch | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "rtk init failed with exit code $LASTEXITCODE" }
  Merge-RtkHookExclusions -ConfigPath (Join-Path $env:APPDATA "rtk\config.toml") -Commands $ExcludeCommands
  return $target
}

function Install-WslRtk {
  if ($SkipWsl) { return $null }
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $null }
  if ($WslDistro -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid WSL distro name: $WslDistro" }

  $distros = (((& wsl.exe -l -q) -join "`n") -replace ([char]0).ToString(), "") -split "`n" | ForEach-Object { $_.Trim() }
  if ($distros -notcontains $WslDistro) {
    Write-Warning "WSL distro $WslDistro is not installed; native Windows RTK remains available, but automatic hook rewriting is not guaranteed."
    return $null
  }

  $template = @'
set -euo pipefail
version='__VERSION__'
expected='rtk __PLAIN_VERSION__'
target="$HOME/.local/bin/rtk"
mkdir -p "$HOME/.local/bin"
current=''
if [ -x "$target" ]; then current="$($target --version 2>/dev/null || true)"; fi
if [ "$current" != "$expected" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  url="https://github.com/rtk-ai/rtk/releases/download/${version}/rtk-x86_64-unknown-linux-musl.tar.gz"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmp/rtk.tar.gz"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp/rtk.tar.gz" "$url"
  else
    echo 'curl or wget is required to install RTK in WSL' >&2
    exit 1
  fi
  tar -xzf "$tmp/rtk.tar.gz" -C "$tmp"
  source="$(find "$tmp" -type f -name rtk | head -1)"
  [ -n "$source" ]
  install -m 0755 "$source" "$target"
fi
for rc in "$HOME/.profile" "$HOME/.bashrc"; do
  touch "$rc"
  grep -Fq '# sub2api-rtk-path' "$rc" || printf '\n# sub2api-rtk-path\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
done
export PATH="$HOME/.local/bin:$PATH"
"$target" --version
mkdir -p "$HOME/.claude"
mkdir -p "$HOME/.cache/rtk"
"$target" init --global --auto-patch </dev/null >"$HOME/.cache/rtk/init.log" 2>&1
'@
  $script = $template.Replace('__VERSION__', $Version).Replace('__PLAIN_VERSION__', $Version.TrimStart('v'))
  $script = $script.Replace("`r`n", "`n")
  $tempScript = Join-Path $env:TEMP ("sub2api-install-rtk-" + [guid]::NewGuid().ToString("N") + ".sh")
  Write-Utf8NoBom -Path $tempScript -Content $script
  try {
    if ($tempScript -notmatch '^(?<drive>[A-Za-z]):\\(?<rest>.*)$') { throw "Cannot map temporary script into WSL: $tempScript" }
    $wslTempScript = "/mnt/$($Matches['drive'].ToLowerInvariant())/$($Matches['rest'].Replace('\', '/'))"
    $wslInstallOutput = @(& wsl.exe -d $WslDistro -- bash $wslTempScript)
    if ($LASTEXITCODE -ne 0) { throw "WSL RTK install failed with exit code $LASTEXITCODE" }
    if ($wslInstallOutput.Count -gt 0) { Write-Host ($wslInstallOutput -join "`n") }
  } finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
  }

  $homeRaw = ((& wsl.exe -d $WslDistro -- bash -lc 'printf "__WSL_HOME__=%s\n" "$HOME"') -join "`n")
  $homeMatch = [regex]::Match($homeRaw, '(?m)^__WSL_HOME__=(?<home>/[^\r\n]+)$')
  $wslHome = if ($homeMatch.Success) { $homeMatch.Groups['home'].Value } else { "" }
  if (-not $wslHome.StartsWith('/')) { throw "Could not resolve WSL home for $WslDistro" }
  $uncHome = "\\wsl.localhost\$WslDistro" + $wslHome.Replace('/', '\')
  Merge-RtkHookExclusions -ConfigPath (Join-Path $uncHome ".config\rtk\config.toml") -Commands $ExcludeCommands
  return $wslHome
}

function Set-ClaudeRtkHook([string]$WindowsRtk, [string]$WslHome) {
  $settingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"
  if (-not (Test-Path -LiteralPath $settingsPath)) { throw "Claude settings not found after rtk init: $settingsPath" }
  Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.bak-rtk-$(Get-Date -Format yyyyMMddHHmmss)"
  $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
  if (-not $settings.PSObject.Properties['hooks']) { Set-ObjectProperty $settings 'hooks' ([pscustomobject]@{}) }

  $command = if ($WslHome) {
    "MSYS2_ARG_CONV_EXCL='*' wsl.exe -d $WslDistro -- env -i HOME=$WslHome PATH=$WslHome/.local/bin:/usr/bin:/bin $WslHome/.local/bin/rtk hook claude"
  } else {
    'rtk hook claude'
  }
  $entries = @()
  if ($settings.hooks.PSObject.Properties['PreToolUse']) { $entries = @($settings.hooks.PreToolUse) }
  $retained = @($entries | Where-Object {
    $commands = @($_.hooks | ForEach-Object { [string]$_.command })
    -not ($_.matcher -eq 'Bash' -and ($commands -match 'rtk(?:\.exe)?\s+hook\s+claude|rtk-rewrite'))
  })
  $retained += [pscustomobject]@{
    matcher = 'Bash'
    hooks = @([pscustomobject]@{ type = 'command'; command = $command })
  }
  Set-ObjectProperty $settings.hooks 'PreToolUse' $retained
  Write-Utf8NoBom -Path $settingsPath -Content ($settings | ConvertTo-Json -Depth 100)

  $payload = '{"session_id":"sub2api-rtk-probe","cwd":"C:\\","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}'
  if ($WslHome) {
    $gitBash = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'
    if (-not (Test-Path -LiteralPath $gitBash)) { throw "Git Bash is required for the Claude Code RTK bridge: $gitBash" }
    $probe = Invoke-GitBashUtf8Stdin -GitBash $gitBash -Command $command -InputText $payload
    $hookOutput = @($probe.Output)
    $hookExitCode = $probe.ExitCode
  } else {
    $hookOutput = $payload | & $WindowsRtk hook claude
    $hookExitCode = $LASTEXITCODE
  }
  if ($hookExitCode -ne 0) { throw "RTK hook probe failed with exit code ${hookExitCode}: $($hookOutput | Out-String)" }
  $hookJson = ($hookOutput | Out-String).Trim() | ConvertFrom-Json
  if ($hookJson.hookSpecificOutput.updatedInput.command -ne 'rtk git status') {
    throw "RTK hook did not rewrite git status: $($hookOutput | Out-String)"
  }

  $rtkMd = Join-Path $env:USERPROFILE ".claude\RTK.md"
  $claudeMd = Join-Path $env:USERPROFILE ".claude\CLAUDE.md"
  if (-not (Test-Path -LiteralPath $rtkMd)) { throw "rtk init did not create $rtkMd" }
  if (-not (Test-Path -LiteralPath $claudeMd) -or (Get-Content -Raw -LiteralPath $claudeMd) -notmatch '(?m)^@RTK\.md\s*$') {
    throw "rtk init did not add @RTK.md to $claudeMd"
  }

  $managed = @'
<!-- sub2api:rtk-profile -->
## sub2api accuracy profile

The Claude Code Bash hook is active. Exact source, diff, and raw API commands are excluded from automatic rewriting: __EXCLUDE_COMMANDS__. Use `RTK_DISABLED=1 <command>` for any one-off raw command. Use `rtk gain --format json` and `rtk hook-audit` for evidence.
<!-- /sub2api:rtk-profile -->
'@
  $managed = $managed.Replace('__EXCLUDE_COMMANDS__', ($ExcludeCommands -join ', '))
  $rtkText = Get-Content -Raw -LiteralPath $rtkMd
  if ($rtkText -match '(?ms)<!-- sub2api:rtk-profile -->.*?<!-- /sub2api:rtk-profile -->') {
    $rtkText = [regex]::Replace($rtkText, '(?ms)<!-- sub2api:rtk-profile -->.*?<!-- /sub2api:rtk-profile -->', $managed.Trim())
  } else {
    $rtkText = $rtkText.TrimEnd() + "`r`n`r`n" + $managed.Trim() + "`r`n"
  }
  Write-Utf8NoBom -Path $rtkMd -Content $rtkText
  return $command
}

$windowsRtk = Install-WindowsRtk
$wslHome = Install-WslRtk
$hookCommand = Set-ClaudeRtkHook -WindowsRtk $windowsRtk -WslHome $wslHome

Write-Host "RTK Windows: $(Get-RtkVersion $windowsRtk) at $windowsRtk"
if ($wslHome) { Write-Host "RTK WSL: $WslDistro $wslHome/.local/bin/rtk" }
Write-Host "Claude PreToolUse: $hookCommand"
Write-Host "RTK exclusions: $($ExcludeCommands -join ', ')"
Write-Host "RTK auto-rewrite: verified (git status -> rtk git status)"

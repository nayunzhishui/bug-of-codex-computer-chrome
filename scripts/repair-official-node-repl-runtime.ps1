[CmdletBinding()]
param(
  [ValidateRange(3, 60)][int]$DelaySeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$codexHome = Join-Path $env:USERPROFILE '.codex'
$configPath = Join-Path $codexHome 'config.toml'
$reportPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'codex-official-runtime-repair-result.txt'
$startedAt = Get-Date
$report = [Collections.Generic.List[string]]::new()

function Add-Report {
  param([Parameter(Mandatory)][string]$Message)
  $line = "$(Get-Date -Format o) $Message"
  $report.Add($line)
  [IO.File]::WriteAllLines($reportPath, $report, [Text.UTF8Encoding]::new($false))
}

function Stop-ProcessTree {
  param(
    [Parameter(Mandatory)][int]$RootPid,
    [Parameter(Mandatory)][object[]]$Snapshot
  )

  $children = @($Snapshot | Where-Object { $_.ParentProcessId -eq $RootPid })
  foreach ($child in $children) {
    Stop-ProcessTree -RootPid ([int]$child.ProcessId) -Snapshot $Snapshot
  }
  Stop-Process -Id $RootPid -Force -ErrorAction SilentlyContinue
}

Start-Sleep -Seconds $DelaySeconds

try {
  Add-Report 'mode=official-runtime-repair'

  if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "missing config: $configPath"
  }
  $backupPath = "$configPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Copy-Item -LiteralPath $configPath -Destination $backupPath
  Add-Report "backup=$backupPath"

  $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
  $config = [regex]::Replace($config, '(?m)^\s*notify\s*=.*\r?\n?', '')
  $config = [regex]::Replace($config, '(?m)^\s*deferred_executor\s*=\s*true\s*\r?\n?', '')
  if ($config -match '(?ms)^\[windows\]\s*(.*?)(?=^\[|\z)') {
    $windowsBlock = $Matches[0]
    $updatedBlock = if ($windowsBlock -match '(?m)^\s*sandbox\s*=') {
      [regex]::Replace($windowsBlock, '(?m)^\s*sandbox\s*=.*$', 'sandbox = "unelevated"', 1)
    } else {
      $windowsBlock.TrimEnd() + [Environment]::NewLine + 'sandbox = "unelevated"' + [Environment]::NewLine
    }
    if ($updatedBlock -match '(?m)^\s*sandbox_private_desktop\s*=') {
      $updatedBlock = [regex]::Replace($updatedBlock, '(?m)^\s*sandbox_private_desktop\s*=.*$', 'sandbox_private_desktop = true', 1)
    } else {
      $updatedBlock = $updatedBlock.TrimEnd() + [Environment]::NewLine + 'sandbox_private_desktop = true' + [Environment]::NewLine
    }
    $config = $config.Replace($windowsBlock, $updatedBlock)
  } else {
    $config = $config.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine +
      '[windows]' + [Environment]::NewLine +
      'sandbox = "unelevated"' + [Environment]::NewLine +
      'sandbox_private_desktop = true' + [Environment]::NewLine
  }
  [IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))
  [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $null, 'User')
  Add-Report 'cleared user CODEX_CLI_PATH and unsupported fixed-runtime overrides'

  $localCodex = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\codex.exe'
  if (Test-Path -LiteralPath $localCodex -PathType Leaf) {
    & $localCodex mcp remove node_repl 2>$null | Out-Null
  }

  $snapshot = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $desktopRoots = @($snapshot | Where-Object {
    ($_.Name -eq 'ChatGPT.exe' -and $_.ExecutablePath -like 'C:\Program Files\WindowsApps\OpenAI.Codex_*\app\ChatGPT.exe') -or
    ($_.Name -eq 'codex.exe' -and $_.ExecutablePath -like "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe")
  })
  foreach ($process in $desktopRoots) {
    Stop-ProcessTree -RootPid ([int]$process.ProcessId) -Snapshot $snapshot
  }

  $cuaBase = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node')).TrimEnd('\')
  $remainingHelpers = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -in @('node_repl.exe', 'codex-computer-use.exe') -and
    -not [string]::IsNullOrWhiteSpace($_.ExecutablePath) -and
    [IO.Path]::GetFullPath($_.ExecutablePath).StartsWith($cuaBase + '\', [StringComparison]::OrdinalIgnoreCase)
  })
  foreach ($helper in $remainingHelpers) {
    Stop-Process -Id $helper.ProcessId -Force -ErrorAction SilentlyContinue
  }

  $activeExecRoot = Join-Path $codexHome 'node_repl\active_execs'
  if (Test-Path -LiteralPath $activeExecRoot -PathType Container) {
    Get-ChildItem -LiteralPath $activeExecRoot -File -Filter '*.json' |
      Remove-Item -Force
  }
  Add-Report 'stopped stale Codex, node_repl, and Computer Use helper processes'

  Start-Process explorer.exe -ArgumentList 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
  $deadline = (Get-Date).AddSeconds(90)
  do {
    Start-Sleep -Seconds 2
    $appServer = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -eq 'codex.exe' -and
        (
          $_.ExecutablePath -eq $localCodex -or
          $_.ExecutablePath -like 'C:\Program Files\WindowsApps\OpenAI.Codex_*\app\resources\codex.exe'
        ) -and
        $_.CommandLine -match '\bapp-server\b' -and
        $_.CreationDate -ge $startedAt
      } |
      Sort-Object CreationDate -Descending |
      Select-Object -First 1
  } while ($null -eq $appServer -and (Get-Date) -lt $deadline)
  if ($null -eq $appServer) {
    throw 'Codex did not publish a fresh app-server within 90 seconds'
  }

  Add-Report "SUCCESS fresh app-server pid=$($appServer.ProcessId)"
  Add-Report 'Create new @Chrome and @Computer tasks for real plugin validation.'
} catch {
  Add-Report "FAILED $($_.Exception.Message)"
  try {
    Start-Process explorer.exe -ArgumentList 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'
  } catch {}
  exit 1
}

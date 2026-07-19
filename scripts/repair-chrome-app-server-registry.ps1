[CmdletBinding()]
param(
  [switch]$InspectOnly,
  [ValidateRange(30, 600)][int]$TimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$registryPath = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\chrome-native-hosts-v2.json'
$backupRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\backups\chrome-app-server-registry'
$resultPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'codex-chrome-app-server-repair-result.txt'
$requiredFields = @(
  'appServerProtocolVersion', 'appVersion', 'channel', 'cliVersion', 'entryId',
  'extensionBuildChannels', 'extensionIds', 'installId', 'nativeHostNames',
  'nativeHostProtocolVersion', 'nativeHostVersion', 'paths', 'presence',
  'proxyHost', 'proxyPort', 'schemaVersion', 'updatedAt'
)
$script:report = [Collections.Generic.List[string]]::new()

function Write-Report {
  param([Parameter(Mandatory)][string]$Message)
  $line = "$(Get-Date -Format o) $Message"
  $script:report.Add($line)
  Write-Host $line
}

function Save-Report {
  $script:report | Set-Content -LiteralPath $resultPath -Encoding UTF8
  Write-Host "Report: $resultPath"
}

function Get-DesktopMainProcesses {
  @(
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -eq 'ChatGPT.exe' -and $_.CommandLine -notmatch '--type=' }
  )
}

function Get-DesktopRuntimeProcesses {
  $localBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
  @(
    Get-Process codex, codex-code-mode-host -ErrorAction SilentlyContinue |
      Where-Object { $_.Path -like "$localBin*" }
  )
}

function Get-CompatibleEntry {
  if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    return $null
  }

  $document = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $entriesProperty = $document.PSObject.Properties['entries']
  if ($null -eq $entriesProperty) {
    return $null
  }

  foreach ($entry in @($entriesProperty.Value)) {
    $missing = @($requiredFields | Where-Object { $null -eq $entry.PSObject.Properties[$_] })
    if ($missing.Count -gt 0) {
      continue
    }
    $pidProperty = $entry.presence.PSObject.Properties['pid']
    if ($null -eq $pidProperty) {
      continue
    }
    $entryPid = [int]$pidProperty.Value
    $liveProcess = Get-Process -Id $entryPid -ErrorAction SilentlyContinue
    if (
      $null -ne $liveProcess -and
      [int]$entry.appServerProtocolVersion -eq 2 -and
      [int]$entry.nativeHostProtocolVersion -eq 2
    ) {
      return [pscustomobject]@{
        Entry = $entry
        Pid = $entryPid
      }
    }
  }
  return $null
}

try {
  Write-Report "mode=$(if ($InspectOnly) { 'inspect' } else { 'repair' })"

  $compatibleBefore = Get-CompatibleEntry
  if ($null -ne $compatibleBefore) {
    Write-Report "SUCCESS registry already has a compatible live entry pid=$($compatibleBefore.Pid)"
    Save-Report
    exit 0
  }

  if ($InspectOnly) {
    Write-Report 'FAILED no compatible live app-server entry exists; no files were changed'
    Save-Report
    exit 2
  }

  $desktopMain = Get-DesktopMainProcesses
  $runtimeProcesses = Get-DesktopRuntimeProcesses
  if ($desktopMain.Count -gt 0 -or $runtimeProcesses.Count -gt 0) {
    $desktopPids = @($desktopMain | ForEach-Object { $_.ProcessId }) -join ','
    $runtimePids = @($runtimeProcesses | ForEach-Object { $_.Id }) -join ','
    Write-Report "FAILED Codex is still running desktopPids=$desktopPids runtimePids=$runtimePids"
    Write-Report 'Use the system-tray Codex icon and choose Exit, then run this file again.'
    Save-Report
    exit 3
  }

  New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
  if (Test-Path -LiteralPath $registryPath) {
    $backupPath = Join-Path $backupRoot "chrome-native-hosts-v2.$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
    Move-Item -LiteralPath $registryPath -Destination $backupPath
    Write-Report "backed up stale registry to $backupPath"
  } else {
    Write-Report 'registry was already missing; continuing with regeneration'
  }

  Write-Report 'starting Codex Desktop'
  Start-Process explorer.exe -ArgumentList 'shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App'

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    Start-Sleep -Seconds 2
    try {
      $compatibleAfter = Get-CompatibleEntry
    } catch {
      $compatibleAfter = $null
    }
    if ($null -ne $compatibleAfter) {
      $item = Get-Item -LiteralPath $registryPath
      Write-Report "SUCCESS compatible live app-server entry pid=$($compatibleAfter.Pid) modified=$($item.LastWriteTime.ToString('o'))"
      Save-Report
      exit 0
    }
  } while ((Get-Date) -lt $deadline)

  Write-Report "FAILED Codex did not publish a compatible live app-server entry within $TimeoutSeconds seconds"
  Save-Report
  exit 4
} catch {
  Write-Report "FAILED $($_.Exception.Message)"
  Save-Report
  exit 1
}

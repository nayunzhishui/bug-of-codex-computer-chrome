param(
  [string]$OutFile = "$env:USERPROFILE\Desktop\codex-runtime-check.txt",
  [switch]$OpenReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue

function Add-ReportLine {
  param([string]$Text = '')
  Add-Content -LiteralPath $OutFile -Value $Text -Encoding UTF8
}

function Get-Sha256 {
  param([Parameter(Mandatory)][string]$Path)
  $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
      (($sha256.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '').ToUpperInvariant()
    } finally {
      $sha256.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Add-FileEvidence {
  param(
    [Parameter(Mandatory)][string]$Label,
    [Parameter(Mandatory)][string]$Path
  )
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Add-ReportLine "${Label}: MISSING | $Path"
    return
  }
  $item = Get-Item -LiteralPath $Path
  $hash = Get-Sha256 -Path $Path
  Add-ReportLine "${Label}: length=$($item.Length) sha256=$hash | $Path"
}

Add-ReportLine '=== Codex runtime diagnosis ==='
Add-ReportLine "Generated: $(Get-Date -Format o)"
Add-ReportLine

$localBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
$localCodex = Join-Path $localBin 'codex.exe'
$localNodeRepl = Join-Path $localBin 'node_repl.exe'

Add-ReportLine '=== CLI versions ==='
if (Test-Path -LiteralPath $localCodex) {
  Add-ReportLine "Desktop local: $(& $localCodex --version)"
} else {
  Add-ReportLine 'Desktop local: MISSING'
}
try {
  Add-ReportLine "PATH codex: $(& codex --version)"
} catch {
  Add-ReportLine "PATH codex: unavailable ($($_.Exception.Message))"
}
Add-ReportLine

Add-ReportLine '=== Current MSIX CUA manifest ==='
$package = Get-AppxPackage -Name OpenAI.Codex |
  Sort-Object Version -Descending |
  Select-Object -First 1
if ($null -eq $package) {
  Add-ReportLine 'OpenAI.Codex package: MISSING'
} else {
  Add-ReportLine "Package version: $($package.Version)"
  Add-ReportLine "Install location: $($package.InstallLocation)"
  $bundledCua = Join-Path $package.InstallLocation 'app\resources\cua_node'
  $manifestPath = Join-Path $bundledCua 'manifest.json'
  if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Add-ReportLine "Runtime archive: $($manifest.runtime_archive_version)"
    Add-ReportLine "node_repl archive: $($manifest.node_repl_archive_path)"
    Add-FileEvidence -Label 'MSIX node_repl' -Path (Join-Path $bundledCua $manifest.node_repl_path)
  } else {
    Add-ReportLine "CUA manifest: MISSING | $manifestPath"
  }
}
Add-FileEvidence -Label 'Local node_repl' -Path $localNodeRepl
Add-FileEvidence -Label 'Local codex' -Path $localCodex
Add-ReportLine

Add-ReportLine '=== Desktop core alignment ==='
if ($null -eq $package) {
  Add-ReportLine 'SKIPPED: current MSIX package is unavailable.'
} else {
  $resources = Join-Path $package.InstallLocation 'app\resources'
  foreach ($name in @('codex.exe', 'codex-code-mode-host.exe', 'codex-command-runner.exe', 'codex-windows-sandbox-setup.exe')) {
    $source = Join-Path $resources $name
    $target = Join-Path $localBin $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
      Add-ReportLine "${name} source: MISSING | $source"
      continue
    }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
      Add-ReportLine "${name} local: MISSING | $target"
      continue
    }
    $sourceHash = Get-Sha256 -Path $source
    $targetHash = Get-Sha256 -Path $target
    $status = if ($sourceHash -eq $targetHash) { 'MATCH' } else { 'MISMATCH' }
    Add-ReportLine "${name}: $status | MSIX=$sourceHash | local=$targetHash"
  }
}
Add-ReportLine

Add-ReportLine '=== Bundled plugin versions ==='
if ($null -ne $package) {
  $bundledMarketplaceSource = Join-Path $package.InstallLocation 'app\resources\plugins\openai-bundled'
  $bundledMarketplaceTarget = Join-Path $env:USERPROFILE '.codex\.tmp\bundled-marketplaces\openai-bundled'
  foreach ($pluginName in @('chrome', 'computer-use')) {
    $sourceManifest = Join-Path $bundledMarketplaceSource "plugins\$pluginName\.codex-plugin\plugin.json"
    $targetManifest = Join-Path $bundledMarketplaceTarget "plugins\$pluginName\.codex-plugin\plugin.json"
    foreach ($candidate in @(
      @{ Label = 'MSIX'; Path = $sourceManifest },
      @{ Label = 'active marketplace'; Path = $targetManifest }
    )) {
      if (Test-Path -LiteralPath $candidate.Path) {
        $pluginManifest = Get-Content -LiteralPath $candidate.Path -Raw -Encoding UTF8 | ConvertFrom-Json
        Add-ReportLine "$pluginName $($candidate.Label): version=$($pluginManifest.version) | $($candidate.Path)"
      } else {
        Add-ReportLine "$pluginName $($candidate.Label): MISSING | $($candidate.Path)"
      }
    }
    $cacheRoot = Join-Path $env:USERPROFILE ".codex\plugins\cache\openai-bundled\$pluginName"
    $cacheVersions = @(Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      ForEach-Object { $_.Name })
    Add-ReportLine "$pluginName installed cache: $($cacheVersions -join ', ')"
  }
}
Add-ReportLine

Add-ReportLine '=== Legacy external node_repl MCP ==='
if (Test-Path -LiteralPath $localCodex) {
  $legacyMcpOutput = @(& $localCodex mcp get node_repl 2>&1)
  if ($LASTEXITCODE -eq 0) {
    Add-ReportLine 'WARNING: external node_repl is configured. It may expose js without the trusted browser/approval bridge.'
    $legacyMcpOutput | ForEach-Object { Add-ReportLine $_ }
  } else {
    Add-ReportLine 'Absent (expected when the official bundled plugin supplies the trusted tool).'
  }
}
Add-ReportLine

Add-ReportLine '=== Chrome native host and browser state ==='
$configPath = Join-Path $env:USERPROFILE '.codex\config.toml'
if (Test-Path -LiteralPath $configPath) {
  $configItem = Get-Item -LiteralPath $configPath
  Add-ReportLine "config.toml: created=$($configItem.CreationTime.ToString('o')) modified=$($configItem.LastWriteTime.ToString('o'))"
  $configMatches = Select-String -LiteralPath $configPath -Pattern '^notify|^\[mcp_servers\.node_repl\]|NODE_REPL_NODE_MODULE_DIRS' -ErrorAction SilentlyContinue
  foreach ($match in $configMatches) {
    Add-ReportLine "config.toml:$($match.LineNumber): $($match.Line)"
  }
} else {
  Add-ReportLine "config.toml: MISSING | $configPath"
}

$nativeManifestPath = Join-Path $env:LOCALAPPDATA 'OpenAI\extension\com.openai.codexextension.json'
if (Test-Path -LiteralPath $nativeManifestPath) {
  $nativeManifest = Get-Content -LiteralPath $nativeManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Add-ReportLine "Native manifest: $nativeManifestPath"
  Add-ReportLine "Native host path: $($nativeManifest.path)"
} else {
  Add-ReportLine "Native manifest: MISSING | $nativeManifestPath"
}
foreach ($registryPath in @(
  'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension',
  'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.openai.codexextension'
)) {
  if (Test-Path -LiteralPath $registryPath) {
    Add-ReportLine "Registry $registryPath = $((Get-Item -LiteralPath $registryPath).GetValue(''))"
  } else {
    Add-ReportLine "Registry MISSING: $registryPath"
  }
}
$chromeProcesses = @(Get-Process chrome -ErrorAction SilentlyContinue)
Add-ReportLine "Google Chrome running: $($chromeProcesses.Count -gt 0)"
$nativeProcesses = @(Get-CimInstance Win32_Process | Where-Object {
  $_.Name -eq 'extension-host.exe' -and $_.ExecutablePath -like '*openai-bundled*chrome*extension-host.exe'
})
foreach ($nativeProcess in $nativeProcesses) {
  Add-ReportLine "Native host pid=$($nativeProcess.ProcessId) parent=$($nativeProcess.ParentProcessId) started=$($nativeProcess.CreationDate) path=$($nativeProcess.ExecutablePath)"
}
Add-ReportLine

Add-ReportLine '=== Recent session evidence ==='
$patterns = @(
  'bundled_executable_relocation_failed',
  'node-repl-missing',
  'missingHelperPath',
  'browser_use_setup_failed',
  'mcp__node_repl__js',
  'mcp: node_repl/js started',
  'Browser is not available: extension',
  'TypeError: tools.mcp__node_repl__js is not a function',
  'Computer Use requires app approval but elicitations are unavailable',
  'Computer Use app approval UI is unavailable outside trusted node_repl',
  'Browser security unavailable outside node repl',
  'stream disconnected before completion',
  '无法连接 Chrome 控制组件',
  '浏览器安全层拦截'
)
$sessionRoot = Join-Path $env:USERPROFILE '.codex\sessions'
if (Test-Path -LiteralPath $sessionRoot) {
  $recentSessions = Get-ChildItem -LiteralPath $sessionRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 20
  $patternRegex = ($patterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
  foreach ($session in $recentSessions) {
    $hits = Select-String -LiteralPath $session.FullName -Pattern $patternRegex -ErrorAction SilentlyContinue |
      Select-Object -First 30
    foreach ($hit in $hits) {
      $text = $hit.Line
      if ($text.Length -gt 1000) {
        $text = $text.Substring(0, 1000) + '...'
      }
      Add-ReportLine "$($session.FullName):$($hit.LineNumber): $text"
    }
  }
} else {
  Add-ReportLine "Session root: MISSING | $sessionRoot"
}

Write-Output "Report written: $OutFile"
if ($OpenReport) {
  notepad.exe $OutFile
}

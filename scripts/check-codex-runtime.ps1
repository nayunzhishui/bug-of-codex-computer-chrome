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
  $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
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

Add-ReportLine '=== node_repl MCP ==='
if (Test-Path -LiteralPath $localCodex) {
  try {
    (& $localCodex mcp get node_repl 2>&1) | ForEach-Object { Add-ReportLine $_ }
  } catch {
    Add-ReportLine "node_repl MCP unavailable: $($_.Exception.Message)"
  }
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
  'Computer Use requires app approval but elicitations are unavailable',
  'Computer Use app approval UI is unavailable outside trusted node_repl',
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

param(
  [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256 {
  param([Parameter(Mandatory)][string]$Path)
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Copy-PlainFile {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Target
  )

  $targetDirectory = Split-Path -Parent $Target
  New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
  $stageDirectory = Join-Path $targetDirectory ('.codex-stage-' + [Guid]::NewGuid().ToString('N'))
  $stagedFile = Join-Path $stageDirectory (Split-Path -Leaf $Target)
  New-Item -ItemType Directory -Path $stageDirectory | Out-Null

  $input = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $output = [IO.File]::Open($stagedFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
      $input.CopyTo($output)
      $output.Flush($true)
    } finally {
      $output.Dispose()
    }
  } finally {
    $input.Dispose()
  }

  if ((Get-Sha256 $Source) -ne (Get-Sha256 $stagedFile)) {
    throw "SHA-256 mismatch while staging $Target"
  }

  $backup = "$Target.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  try {
    if (Test-Path -LiteralPath $Target) {
      Move-Item -LiteralPath $Target -Destination $backup
    }
    Move-Item -LiteralPath $stagedFile -Destination $Target
  } catch {
    if ((Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $Target)) {
      Move-Item -LiteralPath $backup -Destination $Target
    }
    throw
  } finally {
    if (
      (Test-Path -LiteralPath $stageDirectory) -and
      (Get-ChildItem -LiteralPath $stageDirectory -Force | Measure-Object).Count -eq 0
    ) {
      Remove-Item -LiteralPath $stageDirectory -Force
    }
  }
  Write-Output "updated $Target"
  Write-Output "backup $backup"
}

$package = Get-AppxPackage -Name OpenAI.Codex |
  Sort-Object Version -Descending |
  Select-Object -First 1
if ($null -eq $package) {
  throw 'OpenAI.Codex MSIX package was not found'
}

$resources = Join-Path $package.InstallLocation 'app\resources'
$bundledCua = Join-Path $resources 'cua_node'
$manifestPath = Join-Path $bundledCua 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
  throw "Missing CUA manifest: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$runtimeTag = Split-Path -Leaf (Split-Path -Parent $manifest.node_repl_archive_path)
$runtimeRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\runtimes\cua_node\$runtimeTag"
$runtimeNodeRepl = Join-Path $runtimeRoot $manifest.node_repl_path
$runtimeNodeModules = Join-Path $runtimeRoot $manifest.node_modules
$localBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
$localCodex = Join-Path $localBin 'codex.exe'
$localNodeRepl = Join-Path $localBin 'node_repl.exe'
$npmVendorBin = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin'

[pscustomobject]@{
  Apply = [bool]$Apply
  PackageVersion = $package.Version.ToString()
  RuntimeVersion = $manifest.runtime_archive_version
  RuntimeSource = $bundledCua
  RuntimeTarget = $runtimeRoot
  DesktopBin = $localBin
  NpmVendorBin = $npmVendorBin
} | Format-List

if (-not $Apply) {
  Write-Output 'DRY RUN only. Fully exit Codex/ChatGPT, then rerun with -Apply.'
  return
}

$running = @()
$running += Get-Process ChatGPT -ErrorAction SilentlyContinue
$running += Get-Process codex, codex-code-mode-host -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -like "$localBin*" }
if (($running | Measure-Object).Count -gt 0) {
  throw 'Codex/ChatGPT is still running. Fully exit it before applying this repair.'
}

New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
& robocopy.exe $bundledCua $runtimeRoot /E /COPY:DT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
if ($LASTEXITCODE -ge 8) {
  throw "CUA runtime copy failed, robocopy exit=$LASTEXITCODE"
}

$nodeVersion = & (Join-Path $runtimeRoot $manifest.node_path) --version
if ($nodeVersion -ne "v$($manifest.node_version)") {
  throw "CUA Node version mismatch: $nodeVersion"
}
& $runtimeNodeRepl --help | Out-Null

foreach ($name in @('codex.exe', 'codex-code-mode-host.exe', 'codex-command-runner.exe', 'codex-windows-sandbox-setup.exe')) {
  $source = Join-Path $npmVendorBin $name
  if (-not (Test-Path -LiteralPath $source)) {
    $source = Join-Path $resources $name
  }
  if (-not (Test-Path -LiteralPath $source)) {
    Write-Warning "missing helper source: $name"
    continue
  }
  $target = Join-Path $localBin $name
  if ((Test-Path -LiteralPath $target) -and (Get-Sha256 $source) -eq (Get-Sha256 $target)) {
    Write-Output "already current $target"
    continue
  }
  Copy-PlainFile -Source $source -Target $target
}

if (
  -not (Test-Path -LiteralPath $localNodeRepl) -or
  (Get-Sha256 $runtimeNodeRepl) -ne (Get-Sha256 $localNodeRepl)
) {
  Copy-PlainFile -Source $runtimeNodeRepl -Target $localNodeRepl
}

& $localCodex mcp remove node_repl 2>$null | Out-Null
& $localCodex mcp add node_repl `
  --env CODEX_CLI_PATH=$localCodex `
  --env CODEX_HOME="$env:USERPROFILE\.codex" `
  --env NODE_REPL_NODE_MODULE_DIRS=$runtimeNodeModules `
  -- $localNodeRepl | Out-Null

Write-Output (& $localCodex --version)
Write-Output (& $localCodex mcp get node_repl)
Write-Output 'Repair applied. Reopen Codex and validate in a new task.'

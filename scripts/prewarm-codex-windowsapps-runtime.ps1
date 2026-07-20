[CmdletBinding()]
param(
  [switch]$InspectOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256Lower {
  param([Parameter(Mandatory)][string]$Path)
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BundleId {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string[]]$RelativePaths
  )

  $builder = [System.Text.StringBuilder]::new()
  foreach ($relativePath in $RelativePaths) {
    $diskPath = Join-Path $Root ($relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $diskPath -PathType Leaf)) {
      throw "Missing bundled file: $diskPath"
    }
    [void]$builder.Append($relativePath)
    [void]$builder.Append([char]0)
    [void]$builder.Append((Get-Sha256Lower -Path $diskPath))
    [void]$builder.Append([char]0)
  }

  $sha = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes($builder.ToString())
    $digest = $sha.ComputeHash($bytes)
  } finally {
    $sha.Dispose()
  }
  -join ($digest | ForEach-Object { $_.ToString('x2') }) | ForEach-Object { $_.Substring(0, 16) }
}

function Assert-MatchingFile {
  param(
    [Parameter(Mandatory)][string]$Expected,
    [Parameter(Mandatory)][string]$Actual
  )
  if (-not (Test-Path -LiteralPath $Actual -PathType Leaf)) {
    throw "Missing local source file: $Actual"
  }
  if ((Get-Sha256Lower -Path $Expected) -ne (Get-Sha256Lower -Path $Actual)) {
    throw "Local source does not match the installed Codex package: $Actual"
  }
}

function Move-InvalidTargetAside {
  param(
    [Parameter(Mandatory)][string]$Target,
    [Parameter(Mandatory)][string]$AllowedRoot
  )
  if (-not (Test-Path -LiteralPath $Target)) {
    return
  }
  $resolvedRoot = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\') + '\'
  $resolvedTarget = [IO.Path]::GetFullPath($Target)
  if (-not $resolvedTarget.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to move a path outside the expected runtime root: $resolvedTarget"
  }
  $backup = "$resolvedTarget.invalid.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Move-Item -LiteralPath $resolvedTarget -Destination $backup
  Write-Output "Moved invalid target aside: $backup"
}

$package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $package) {
  throw 'OpenAI.Codex MSIX package is not installed.'
}

$resources = Join-Path $package.InstallLocation 'app\resources'
$cuaPackageRoot = Join-Path $resources 'cua_node'
$manifestPath = Join-Path $cuaPackageRoot 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
  throw "Bundled CUA manifest is missing: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$runtimeTag = ($manifest.node_repl_archive_path -split '/')[0]
$localRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
$binRoot = Join-Path $localRoot 'bin'
$runtimeRoot = Join-Path $localRoot 'runtimes\cua_node'
$runtimeSource = Join-Path $runtimeRoot $runtimeTag

$codexFiles = @(
  'codex.exe',
  'codex-code-mode-host.exe',
  'codex-windows-sandbox-setup.exe',
  'codex-command-runner.exe'
)
$runtimeIdentityFiles = @(
  'manifest.json',
  'bin/node.exe',
  'bin/node_repl.exe'
)

$codexId = Get-BundleId -Root $resources -RelativePaths $codexFiles
$runtimeId = Get-BundleId -Root $cuaPackageRoot -RelativePaths $runtimeIdentityFiles
$codexTarget = Join-Path $binRoot $codexId
$runtimeTarget = Join-Path $runtimeRoot $runtimeId

foreach ($file in $codexFiles) {
  Assert-MatchingFile -Expected (Join-Path $resources $file) -Actual (Join-Path $binRoot $file)
}
foreach ($file in $runtimeIdentityFiles) {
  $relativeDiskPath = $file.Replace('/', [IO.Path]::DirectorySeparatorChar)
  Assert-MatchingFile -Expected (Join-Path $cuaPackageRoot $relativeDiskPath) -Actual (Join-Path $runtimeSource $relativeDiskPath)
}

$codexReady = (Test-Path -LiteralPath $codexTarget -PathType Container)
if ($codexReady) {
  foreach ($file in $codexFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $codexTarget $file) -PathType Leaf) -or
        (Get-Sha256Lower -Path (Join-Path $resources $file)) -ne (Get-Sha256Lower -Path (Join-Path $codexTarget $file))) {
      $codexReady = $false
      break
    }
  }
}

if ($InspectOnly -and -not $codexReady) {
  throw "Codex hash runtime is not ready: $codexTarget"
}

if (-not $codexReady) {
  Move-InvalidTargetAside -Target $codexTarget -AllowedRoot $binRoot
  $staging = Join-Path $binRoot ".staging-$codexId-manual-$PID"
  New-Item -ItemType Directory -Path $staging -Force | Out-Null
  try {
    foreach ($file in $codexFiles) {
      Copy-Item -LiteralPath (Join-Path $binRoot $file) -Destination (Join-Path $staging $file)
    }
    Move-Item -LiteralPath $staging -Destination $codexTarget
  } catch {
    if (Test-Path -LiteralPath $staging) {
      Remove-Item -LiteralPath $staging -Recurse -Force
    }
    throw
  }
}

$runtimeReady = (Test-Path -LiteralPath $runtimeTarget -PathType Container)
if ($runtimeReady) {
  foreach ($file in $runtimeIdentityFiles) {
    $relativeDiskPath = $file.Replace('/', [IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeTarget $relativeDiskPath) -PathType Leaf) -or
        (Get-Sha256Lower -Path (Join-Path $cuaPackageRoot $relativeDiskPath)) -ne (Get-Sha256Lower -Path (Join-Path $runtimeTarget $relativeDiskPath))) {
      $runtimeReady = $false
      break
    }
  }
}

if ($InspectOnly -and -not $runtimeReady) {
  throw "CUA hash runtime is not ready: $runtimeTarget"
}

if (-not $runtimeReady) {
  Move-InvalidTargetAside -Target $runtimeTarget -AllowedRoot $runtimeRoot
  $staging = Join-Path $runtimeRoot ".staging-$runtimeId-manual-$PID"
  New-Item -ItemType Directory -Path $staging -Force | Out-Null
  try {
    & robocopy.exe $runtimeSource $staging /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) {
      throw "Failed to copy the decrypted CUA runtime, robocopy exit=$LASTEXITCODE"
    }
    Move-Item -LiteralPath $staging -Destination $runtimeTarget
  } catch {
    if (Test-Path -LiteralPath $staging) {
      Remove-Item -LiteralPath $staging -Recurse -Force
    }
    throw
  }
}

$helper = Join-Path $runtimeTarget 'bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe'
$transport = Join-Path $runtimeTarget 'bin\node_modules\@oai\sky\dist\project\cua\sky_js\src\targets\windows\internal\helper_transport.js'
if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
  throw "Computer Use helper is missing after prewarm: $helper"
}
if (-not (Test-Path -LiteralPath $transport -PathType Leaf)) {
  throw "Computer Use transport module is missing after prewarm: $transport"
}

$marketplaceRepairScript = Join-Path $PSScriptRoot 'repair-codex-bundled-marketplace-efs.ps1'
if (-not (Test-Path -LiteralPath $marketplaceRepairScript -PathType Leaf)) {
  throw "Bundled marketplace EFS repair script is missing: $marketplaceRepairScript"
}
if ($InspectOnly) {
  & $marketplaceRepairScript -InspectOnly
} else {
  & $marketplaceRepairScript
}

[pscustomobject]@{
  Status = if ($InspectOnly) { 'INSPECT_OK' } else { 'READY' }
  PackageVersion = $package.Version.ToString()
  CodexBundleId = $codexId
  CodexTarget = $codexTarget
  CuaRuntimeId = $runtimeId
  CuaRuntimeTarget = $runtimeTarget
  ComputerUseHelper = $helper
  ComputerUseTransport = $transport
  MarketplaceRepairScript = $marketplaceRepairScript
} | Format-List

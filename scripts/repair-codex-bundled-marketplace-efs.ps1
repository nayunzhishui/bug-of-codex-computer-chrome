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

function Test-SameFile {
  param(
    [Parameter(Mandatory)][string]$Expected,
    [Parameter(Mandatory)][string]$Actual
  )
  (Test-Path -LiteralPath $Actual -PathType Leaf) -and
    ((Get-Item -LiteralPath $Expected).Length -eq (Get-Item -LiteralPath $Actual).Length) -and
    ((Get-Sha256Lower -Path $Expected) -eq (Get-Sha256Lower -Path $Actual))
}

function Get-MatchingDirectory {
  param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$ExpectedRoot,
    [Parameter(Mandatory)][string[]]$RelativeFiles
  )
  foreach ($directory in Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue) {
    $matches = $true
    foreach ($relativeFile in $RelativeFiles) {
      if (-not (Test-SameFile -Expected (Join-Path $ExpectedRoot $relativeFile) -Actual (Join-Path $directory.FullName $relativeFile))) {
        $matches = $false
        break
      }
    }
    if ($matches) {
      return $directory.FullName
    }
  }
  $null
}

function Test-MarketplaceMirror {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Mirror
  )
  if (-not (Test-Path -LiteralPath $Mirror -PathType Container)) {
    return $false
  }
  $sourceFiles = Get-ChildItem -LiteralPath $Source -Recurse -File
  foreach ($sourceFile in $sourceFiles) {
    $relative = $sourceFile.FullName.Substring($Source.Length).TrimStart('\')
    if (-not (Test-SameFile -Expected $sourceFile.FullName -Actual (Join-Path $Mirror $relative))) {
      return $false
    }
  }
  return $true
}

if (-not ('CodexEfsCopy' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class CodexEfsCopy {
    private const uint COPY_FILE_ALLOW_DECRYPTED_DESTINATION = 0x00000008;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CopyFileExW")]
    private static extern bool CopyFileEx(
        string source,
        string destination,
        IntPtr progressRoutine,
        IntPtr data,
        ref int cancel,
        uint flags
    );

    public static void CopyFile(string source, string destination) {
        var cancel = 0;
        if (!CopyFileEx(source, destination, IntPtr.Zero, IntPtr.Zero, ref cancel,
                COPY_FILE_ALLOW_DECRYPTED_DESTINATION)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@
}

if (-not ('CodexEnvironmentBroadcast' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexEnvironmentBroadcast {
    private static readonly IntPtr HWND_BROADCAST = new IntPtr(0xffff);
    private const uint WM_SETTINGCHANGE = 0x001A;
    private const uint SMTO_ABORTIFHUNG = 0x0002;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint message,
        UIntPtr wParam,
        string lParam,
        uint flags,
        uint timeout,
        out UIntPtr result
    );

    public static void NotifyEnvironmentChanged() {
        UIntPtr result;
        SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, UIntPtr.Zero,
            "Environment", SMTO_ABORTIFHUNG, 5000, out result);
    }
}
'@
}

function Copy-EfsSafeDirectory {
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination
  )
  [IO.Directory]::CreateDirectory($Destination) | Out-Null
  foreach ($directory in Get-ChildItem -LiteralPath $Source -Recurse -Directory -Force) {
    $relative = $directory.FullName.Substring($Source.Length).TrimStart('\')
    [IO.Directory]::CreateDirectory((Join-Path $Destination $relative)) | Out-Null
  }
  foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File -Force) {
    $relative = $file.FullName.Substring($Source.Length).TrimStart('\')
    $target = Join-Path $Destination $relative
    [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
    [CodexEfsCopy]::CopyFile($file.FullName, $target)
  }
}

$package = Get-AppxPackage -Name OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $package) {
  throw 'OpenAI.Codex MSIX package is not installed.'
}

$packageVersion = $package.Version.ToString()
$resources = Join-Path $package.InstallLocation 'app\resources'
$sourceMarketplace = Join-Path $resources 'plugins\openai-bundled'
$sourceCua = Join-Path $resources 'cua_node'
$localRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex'
$codexRoot = Join-Path $localRoot 'bin'
$cuaRoot = Join-Path $localRoot 'runtimes\cua_node'
$codexFiles = @(
  'codex.exe',
  'codex-code-mode-host.exe',
  'codex-windows-sandbox-setup.exe',
  'codex-command-runner.exe'
)
$cuaIdentityFiles = @(
  'manifest.json',
  'bin\node.exe',
  'bin\node_repl.exe'
)

if (-not (Test-Path -LiteralPath $sourceMarketplace -PathType Container)) {
  throw "Bundled marketplace source is missing: $sourceMarketplace"
}

$codexRuntime = Get-MatchingDirectory -Root $codexRoot -ExpectedRoot $resources -RelativeFiles $codexFiles
$cuaRuntime = Get-MatchingDirectory -Root $cuaRoot -ExpectedRoot $sourceCua -RelativeFiles $cuaIdentityFiles
if ($null -eq $codexRuntime) {
  throw 'No hash-matching decrypted Codex runtime was found. Run prewarm-codex-windowsapps-runtime.ps1 first.'
}
if ($null -eq $cuaRuntime) {
  throw 'No hash-matching decrypted CUA runtime was found. Run prewarm-codex-windowsapps-runtime.ps1 first.'
}

$mirrorParent = Join-Path $localRoot 'decrypted-bundled-resources'
$mirrorResources = Join-Path $mirrorParent $packageVersion
$mirrorMarketplace = Join-Path $mirrorResources 'plugins\openai-bundled'
$mirrorCua = Join-Path $mirrorResources 'cua_node'
$mirrorReady = Test-MarketplaceMirror -Source $sourceMarketplace -Mirror $mirrorMarketplace
if ($mirrorReady) {
  foreach ($file in $codexFiles) {
    if (-not (Test-SameFile -Expected (Join-Path $codexRuntime $file) -Actual (Join-Path $mirrorResources $file))) {
      $mirrorReady = $false
      break
    }
  }
}
if ($mirrorReady) {
  try {
    $mirrorReady = ((Get-Item -LiteralPath $mirrorCua -Force).LinkType -eq 'Junction') -and
      ((Get-Item -LiteralPath $mirrorCua -Force).Target -contains $cuaRuntime)
  } catch {
    $mirrorReady = $false
  }
}

if ($InspectOnly -and -not $mirrorReady) {
  throw "Decrypted bundled marketplace mirror is not ready: $mirrorResources"
}

if (-not $InspectOnly -and -not $mirrorReady) {
  [IO.Directory]::CreateDirectory($mirrorParent) | Out-Null
  $staging = Join-Path $mirrorParent ".staging-$packageVersion-$PID"
  if (Test-Path -LiteralPath $staging) {
    Remove-Item -LiteralPath $staging -Recurse -Force
  }
  [IO.Directory]::CreateDirectory($staging) | Out-Null
  try {
    Copy-EfsSafeDirectory -Source $sourceMarketplace -Destination (Join-Path $staging 'plugins\openai-bundled')
    foreach ($file in $codexFiles) {
      Copy-Item -LiteralPath (Join-Path $codexRuntime $file) -Destination (Join-Path $staging $file)
    }
    New-Item -ItemType Junction -Path (Join-Path $staging 'cua_node') -Target $cuaRuntime | Out-Null

    if (-not (Test-MarketplaceMirror -Source $sourceMarketplace -Mirror (Join-Path $staging 'plugins\openai-bundled'))) {
      throw 'Decrypted marketplace mirror failed hash validation.'
    }
    if (Test-Path -LiteralPath $mirrorResources) {
      $backup = "$mirrorResources.invalid.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
      Move-Item -LiteralPath $mirrorResources -Destination $backup
    }
    Move-Item -LiteralPath $staging -Destination $mirrorResources
  } catch {
    if (Test-Path -LiteralPath $staging) {
      Remove-Item -LiteralPath $staging -Recurse -Force
    }
    throw
  }
  $mirrorReady = $true
}

$environmentName = 'CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH'
$configuredEnvironment = [Environment]::GetEnvironmentVariable($environmentName, 'User')
if ($InspectOnly) {
  if ($configuredEnvironment -ne $mirrorResources) {
    throw "User environment override is not configured for the current Codex package: $configuredEnvironment"
  }
} else {
  [Environment]::SetEnvironmentVariable($environmentName, $mirrorResources, 'User')
  [CodexEnvironmentBroadcast]::NotifyEnvironmentChanged()
  $configuredEnvironment = $mirrorResources
}

$stagingRoot = Join-Path $env:USERPROFILE '.codex\.tmp\bundled-marketplaces'
$removedStagingCount = 0
if (-not $InspectOnly -and (Test-Path -LiteralPath $stagingRoot -PathType Container)) {
  $rootPrefix = [IO.Path]::GetFullPath($stagingRoot).TrimEnd('\') + '\'
  foreach ($directory in Get-ChildItem -LiteralPath $stagingRoot -Directory -Filter 'openai-bundled.staging-*' -ErrorAction SilentlyContinue) {
    $fullPath = [IO.Path]::GetFullPath($directory.FullName)
    if ($fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        $directory.Name -match '^openai-bundled\.staging-[0-9a-fA-F-]{36}$' -and
        $directory.LastWriteTime -lt (Get-Date).AddMinutes(-2)) {
      Remove-Item -LiteralPath $fullPath -Recurse -Force
      $removedStagingCount++
    }
  }
}

[pscustomobject]@{
  Status = if ($InspectOnly) { 'INSPECT_OK' } else { 'REPAIRED' }
  PackageVersion = $packageVersion
  SourceMarketplace = $sourceMarketplace
  MirrorResources = $mirrorResources
  MirrorMarketplace = $mirrorMarketplace
  CodexRuntime = $codexRuntime
  CuaRuntime = $cuaRuntime
  EnvironmentName = $environmentName
  EnvironmentValue = $configuredEnvironment
  RemovedStagingDirectories = $removedStagingCount
  RestartRequired = -not $InspectOnly
} | Format-List

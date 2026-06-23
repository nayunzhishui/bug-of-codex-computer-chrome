# copy-plain-file-template.ps1
# 用途：在路径确认后复制单个文件，并校验 SHA-256。
# 注意：Source 和 Destination 必须来自最新 Codex 日志，不要猜路径。

param(
  [Parameter(Mandatory=$true)]
  [string]$Source,

  [Parameter(Mandatory=$true)]
  [string]$Destination
)

if (!(Test-Path $Source)) {
  throw "源文件不存在：$Source"
}

$destDir = Split-Path $Destination
New-Item -ItemType Directory -Force -Path $destDir | Out-Null

$inputStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
try {
  $outputStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try {
    $inputStream.CopyTo($outputStream)
  } finally {
    $outputStream.Close()
  }
} finally {
  $inputStream.Close()
}

$srcHash = Get-FileHash $Source -Algorithm SHA256
$dstHash = Get-FileHash $Destination -Algorithm SHA256

Write-Host "Source      : $Source"
Write-Host "Destination : $Destination"
Write-Host "Source SHA  : $($srcHash.Hash)"
Write-Host "Dest SHA    : $($dstHash.Hash)"

if ($srcHash.Hash -ne $dstHash.Hash) {
  throw "SHA-256 校验失败"
}

Write-Host "OK"

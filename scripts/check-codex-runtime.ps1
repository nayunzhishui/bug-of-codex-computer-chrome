# check-codex-runtime.ps1
$out = "$env:USERPROFILE\Desktop\codex-runtime-check.txt"
Remove-Item $out -Force -ErrorAction SilentlyContinue

$roots = @(
  "$env:LOCALAPPDATA\OpenAI\Codex",
  "$env:USERPROFILE\.codex",
  "$env:USERPROFILE\.cache\codex-runtimes"
)

$patterns = @(
  "bundled_executable_relocation_failed",
  "node-repl-missing",
  "missingHelperPath",
  "browser_use_setup_failed",
  "mcp__node_repl__js",
  "codex-windows-sandbox-setup.exe",
  "codex-command-runner.exe",
  "CODEX_CLI_PATH",
  "nodeRepl.config",
  "CodexFingerprint",
  "RgFingerprint",
  "CuaFingerprint",
  "RuntimePaths"
)

foreach ($root in $roots) {
  if (Test-Path $root) {
    Get-ChildItem $root -Recurse -Force -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Length -lt 20MB } |
      ForEach-Object {
        foreach ($p in $patterns) {
          $hits = Select-String -Path $_.FullName -Pattern $p -SimpleMatch -ErrorAction SilentlyContinue
          if ($hits) {
            Add-Content $out "`n--- FILE: $($_.FullName) | PATTERN: $p ---"
            $hits | Select-Object -First 30 | ForEach-Object {
              Add-Content $out $_.Line
            }
          }
        }
      }
  }
}

notepad $out

# Dev run: publish everything self-contained into windows/dev-run/ and start.
# No system changes. Needs: .NET 9 SDK, windows/native DLLs (run
# build-llama-windows.ps1 once), model files in %LocalAppData%\DigUp\Models.
# For sound/video tests only: set DIGUP_FFMPEG to a folder with ffmpeg.exe +
# ffprobe.exe (your own install; the ship bundles its own).
# PowerShell 5.1 safe. Run from the repo root: powershell -File windows\scripts\dev-run-windows.ps1 [app|cli]
#   app  start DigUpApp.exe (default)
#   cli  print the digup.exe path and stop
#
# All three publish straight into $Dev. Shared files are identical builds of
# the same runtimes. (DigUpApp vs digup names differ on purpose: Windows
# disks are case-insensitive, one folder, no silent overwrites.)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Dev = Join-Path $RepoRoot "windows\dev-run"
$Mode = if ($args.Count -gt 0) { $args[0] } else { "app" }

# Never publish over a running app: quit DigUp first (tray menu → Quit).
$running = Get-Process DigUpApp, digup, digup-embed -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -like "$Dev*" }
if ($running) {
  $names = ($running | ForEach-Object { "$($_.ProcessName) ($($_.Id))" }) -join ", "
  throw "DigUp is running ($names) from $Dev. Quit it first (tray menu → Quit DigUp), then run this again."
}

function Publish-One($Project, $Name) {
  # Out-Null matters: dotnet prints warnings to stdout, which would land in
  # the return value. Failures still throw below.
  dotnet publish $Project -c Release -r win-x64 --self-contained -o $Dev --nologo -v quiet | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "$Name publish failed (see output above)" }
}

Publish-One (Join-Path $RepoRoot "windows\src\digup\digup.csproj") "cli"
Publish-One (Join-Path $RepoRoot "windows\src\DigUp.Embed\DigUp.Embed.csproj") "embed"
Publish-One (Join-Path $RepoRoot "windows\src\DigUp.App\DigUp.App.csproj") "app"

$arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq "Arm64") { "arm64" } else { "x64" }
if (!(Test-Path (Join-Path $RepoRoot "windows\native\$arch\llama.dll"))) { throw "no native DLLs: run windows\scripts\build-llama-windows.ps1 first" }
Copy-Item (Join-Path $RepoRoot "windows\native\$arch\*.dll") $Dev -Force

# Loud smoke checks: empty output or missing files fail here, never silently.
foreach ($need in @("digup.exe", "digup.dll", "digup-embed.exe", "digup-embed.dll", "DigUpApp.exe", "DigUpApp.dll", "llama.dll", "mtmd.dll")) {
  if (!(Test-Path (Join-Path $Dev $need))) { throw "missing $need in $Dev" }
}
$help = (& (Join-Path $Dev "digup.exe") --help 2>&1 | Out-String)
if ($help -notmatch "search your files by meaning") { throw "digup.exe --help gave no help text (something overwrote it?)" }
Write-Host "dev folder OK: $Dev"
if ($Mode -eq "cli") { Write-Host (Join-Path $Dev "digup.exe"); exit 0 }
& (Join-Path $Dev "DigUpApp.exe")

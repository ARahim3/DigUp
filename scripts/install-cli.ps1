# Windows: puts the `digup` CLI on PATH and installs the `digup` skill for Claude Code and Google Antigravity.
# The CLI is the installed app's helper (digup.exe beside its DLLs, llama.cpp's backends and ffmpeg), so install DigUp
# first; its helper folder is added to the user's PATH (no admin rights). A digup.exe built from source can be named
# with -Helper <folder> instead, once its DLLs are beside it (scripts/package-windows.sh lays them out).
#   powershell -ExecutionPolicy Bypass -File scripts\install-cli.ps1 [-Helper <folder>]
param(
    [string]$Helper = (Join-Path $env:LOCALAPPDATA "DigUp\helper")
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

$exe = Join-Path $Helper "digup.exe"
if (-not (Test-Path $exe)) {
    Write-Error "no digup.exe in $Helper. Install DigUp for Windows first, or pass -Helper <folder with digup.exe>."
}
$Helper = (Resolve-Path $Helper).Path

# The user's PATH as stored (not this session's, which has the system PATH in front of it).
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$entries = @($userPath -split ";" | Where-Object { $_ -ne "" })
if ($entries | Where-Object { $_.TrimEnd("\") -ieq $Helper.TrimEnd("\") }) {
    Write-Host "Already on PATH: $Helper"
} else {
    [Environment]::SetEnvironmentVariable("Path", (($entries + $Helper) -join ";"), "User")
    Write-Host "Added to the user PATH: $Helper (open a new terminal to run ``digup``)"
}

$skill = Join-Path $repo ".agents\skills\digup\SKILL.md"
if (Test-Path $skill) {
    foreach ($dest in @(
            (Join-Path $repo ".claude\skills\digup"),
            (Join-Path $HOME ".claude\skills\digup"),
            (Join-Path $HOME ".gemini\config\skills\digup"))) {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -Force $skill (Join-Path $dest "SKILL.md")
        Write-Host "Installed skill: $(Join-Path $dest 'SKILL.md')"
    }
}

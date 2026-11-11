# One-Command Launcher for DigUp Desktop App (Pre-loaded with DigUp-Safe-Test)
# Usage: .\start-digup.ps1

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
$SafeTestRoot = Join-Path $RepoRoot "DigUp-Safe-Test"
$DocsDir = Join-Path $SafeTestRoot "docs"
$CodeDir = Join-Path $SafeTestRoot "code-sample"
$SandboxDir = Join-Path $SafeTestRoot ".digup-sandbox"
$IndexDir = Join-Path $SandboxDir "index"
$SettingsFile = Join-Path $SandboxDir "settings.json"

New-Item -ItemType Directory -Force -Path $IndexDir | Out-Null

# Pre-configure sandbox settings so the main search + AI window opens immediately
# with your DigUp-Safe-Test folders already indexed and ready to search/chat.
if (-not (Test-Path $SettingsFile)) {
    $InitialSettings = @{
        folders        = @($DocsDir, $CodeDir)
        skipped        = @()
        skipTypes      = @()
        codeFolders    = @($DocsDir, $CodeDir)
        codeSkipped    = @()
        codeEditor     = "default"
        setUp          = $true
        openAtLogin    = $false
        updateChecks   = $false
        processorOnly  = $true
        slmModel       = "qwen2.5-3b"
        loraAdapter    = ""
        activeCagSlot  = "default"
    } | ConvertTo-Json -Depth 4
    Set-Content -Path $SettingsFile -Value $InitialSettings -Encoding UTF8
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Starting DigUp Desktop App (Safe-Test Sandbox)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Indexed Folders :" -ForegroundColor Green
Write-Host "   - $DocsDir"
Write-Host "   - $CodeDir"
Write-Host " Fine-Tune Data  : $IndexDir\fine_tune_data\" -ForegroundColor Yellow
Write-Host " CAG Cache Slots : $IndexDir\cag_cache\" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan

Push-Location (Join-Path $RepoRoot "shell\src-tauri")
try {
    cargo run -- --settings "$SettingsFile" --index "$IndexDir"
} finally {
    Pop-Location
}

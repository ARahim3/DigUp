# DigUp Dual-Mode Launcher (Quick Start Mode vs. Developer/Contributor Mode)
#
# MODE 1 -- Quick Start (Least Friction, Multi-Folder + SLM):
#   .\start-digup.ps1                                              # Launch sandbox demo immediately
#   .\start-digup.ps1 -WithSLM                                     # Auto-start local SLM (Qwen2.5) + DigUp
#   .\start-digup.ps1 -UserFolders -WithSLM                        # Index Desktop, Documents, Downloads, Projects + SLM
#   .\start-digup.ps1 -Folders "C:\MyDocs","D:\Notes" -WithSLM     # Point to any list of folders & start immediately
#
# MODE 2 -- Developer / Contributor Mode (Build, Test, Benchmark & Push Limits):
#   .\start-digup.ps1 -Mode Dev                                    # Run unit/GraphRAG tests, show git status, run debug build
#   .\start-digup.ps1 -Mode Dev -TestOnly                          # Run the Rust test & evaluation suite without opening UI

param(
    [ValidateSet("Quick", "Dev")]
    [string]$Mode = "Quick",
    [string[]]$Folders = @(),
    [switch]$UserFolders,
    [switch]$WithSLM,
    [switch]$TurboSLM,
    [switch]$TestOnly,
    [switch]$ResetFolders
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
$SafeTestRoot = Join-Path $RepoRoot "DigUp-Safe-Test"
$DocsDir = Join-Path $SafeTestRoot "docs"
$CodeDir = Join-Path $SafeTestRoot "code-sample"
$SandboxDir = Join-Path $SafeTestRoot ".digup-sandbox"
$IndexDir = Join-Path $SandboxDir "index"
$SettingsFile = Join-Path $SandboxDir "settings.json"

New-Item -ItemType Directory -Force -Path $IndexDir | Out-Null

# Resolve target folders to index
$TargetFolders = @()
if ($UserFolders) {
    $Candidates = @(
        (Join-Path $HOME "Desktop"),
        (Join-Path $HOME "Documents"),
        (Join-Path $HOME "Downloads"),
        (Join-Path $HOME "Desktop\Projects")
    )
    foreach ($c in $Candidates) {
        if (Test-Path $c) { $TargetFolders += $c }
    }
}
if ($Folders.Count -gt 0) {
    foreach ($f in $Folders) {
        if (Test-Path $f) {
            $Resolved = (Resolve-Path $f).Path
            if ($TargetFolders -notcontains $Resolved) {
                $TargetFolders += $Resolved
            }
        } else {
            Write-Warning "Folder not found, skipping: $f"
        }
    }
}

# Create or update settings.json when folders are passed or first initialized
if ((-not (Test-Path $SettingsFile)) -or $ResetFolders -or ($TargetFolders.Count -gt 0)) {
    if ($TargetFolders.Count -eq 0) {
        $TargetFolders = @($DocsDir, $CodeDir)
    }
    $InitialSettings = @{
        folders        = $TargetFolders
        skipped        = @(
            "C:\Windows",
            "C:\Program Files",
            "C:\Program Files (x86)",
            "C:\ProgramData",
            (Join-Path $HOME "AppData")
        )
        skipTypes      = @()
        codeFolders    = $TargetFolders
        codeSkipped    = @()
        codeEditor     = "default"
        setUp          = $true
        openAtLogin    = $false
        updateChecks   = $false
        processorOnly  = $true
        slmModel       = $(if ($TurboSLM) { "qwen2.5-1.5b" } else { "qwen2.5-3b" })
        loraAdapter    = ""
        activeCagSlot  = "default"
    } | ConvertTo-Json -Depth 4
    Set-Content -Path $SettingsFile -Value $InitialSettings -Encoding UTF8
}

$CurrentSettings = Get-Content -Path $SettingsFile -Raw | ConvertFrom-Json

# Auto-start Local SLM Server in background if requested
if ($WithSLM -or $TurboSLM) {
    $PortOpen = $false
    try {
        $Tcp = New-Object System.Net.Sockets.TcpClient
        $Connect = $Tcp.BeginConnect("127.0.0.1", 8080, $null, $null)
        $Wait = $Connect.AsyncWaitHandle.WaitOne(300, $false)
        if ($Wait -and $Tcp.Connected) { $PortOpen = $true }
        $Tcp.Close()
    } catch {}

    if ($PortOpen) {
        Write-Host "[SLM] Local SLM server already active on http://127.0.0.1:8080" -ForegroundColor Green
    } else {
        $SlmArgs = if ($TurboSLM) { "-Turbo" } else { "" }
        Write-Host "[SLM] Launching Local SLM Server in background window..." -ForegroundColor Cyan
        Start-Process powershell -ArgumentList "-NoExit", "-ExecutionPolicy", "Bypass", "-File", "`"$RepoRoot\start-slm.ps1`"", $SlmArgs
    }
}

if ($Mode -eq "Dev") {
    Write-Host "============================================================" -ForegroundColor Magenta
    Write-Host " DigUp -- DEVELOPER AND CONTRIBUTOR MODE" -ForegroundColor Magenta
    Write-Host "============================================================" -ForegroundColor Magenta
    $Branch = (git branch --show-current 2>$null)
    Write-Host " Active Branch   : $Branch" -ForegroundColor Yellow

    if (-not $TestOnly) {
        $Running = Get-Process -Name "digup-shell" -ErrorAction SilentlyContinue
        if ($Running) {
            Write-Host " Stopping existing digup-shell.exe process before recompiling..." -ForegroundColor Yellow
            Stop-Process -Name "digup-shell" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 600
        }
    }

    Write-Host " Running Rust Unit + GraphRAG + Safety Test Suite..." -ForegroundColor Cyan

    Push-Location (Join-Path $RepoRoot "shell\src-tauri")
    try {
        cargo test
        if ($LASTEXITCODE -ne 0) {
            throw "Unit tests failed in Developer Mode."
        }
        if ($TestOnly) {
            Write-Host "All Developer Mode checks passed!" -ForegroundColor Green
            return
        }
        Write-Host "Starting DigUp with live cargo compilation..." -ForegroundColor Cyan
        cargo run -- --settings "$SettingsFile" --index "$IndexDir"
    } finally {
        Pop-Location
    }
} else {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " DigUp -- QUICK START MODE (Zero-Friction)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " Indexed Folders :" -ForegroundColor Green
    foreach ($f in $CurrentSettings.folders) {
        Write-Host "   - $f"
    }
    Write-Host " System Guard    : Windows, Program Files, AppData auto-excluded" -ForegroundColor DarkGray
    Write-Host " Fine-Tune Data  : $IndexDir\fine_tune_data\" -ForegroundColor Yellow
    Write-Host " CAG Cache Slots : $IndexDir\cag_cache\" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan

    $Running = Get-Process -Name "digup-shell" -ErrorAction SilentlyContinue
    if ($Running) {
        Write-Host " Stopping previous digup-shell.exe instance..." -ForegroundColor Yellow
        Stop-Process -Name "digup-shell" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 600
    }

    $PrebuiltExe = Join-Path $RepoRoot "shell\src-tauri\target\debug\digup-shell.exe"
    if (Test-Path $PrebuiltExe) {
        & $PrebuiltExe --settings "$SettingsFile" --index "$IndexDir"
    } else {
        Push-Location (Join-Path $RepoRoot "shell\src-tauri")
        try {
            cargo run -- --settings "$SettingsFile" --index "$IndexDir"
        } finally {
            Pop-Location
        }
    }
}

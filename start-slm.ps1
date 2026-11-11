# One-Command Local SLM Downloader & Server for DigUp (Qwen2.5-3B-Instruct / Qwen2.5-1.5B-Instruct)
# Usage:
#   .\start-slm.ps1             # Downloads & runs Qwen2.5-3B-Instruct (Q4_K_M, ~1.93 GB) on 6 CPU threads
#   .\start-slm.ps1 -Turbo      # Downloads & runs Qwen2.5-1.5B-Instruct (Q4_K_M, ~986 MB) for faster CPU speed

param(
    [switch]$Turbo
)

$ErrorActionPreference = "Stop"
$RepoRoot = $PSScriptRoot
$SlmDir = Join-Path $RepoRoot "DigUp-Safe-Test\.digup-sandbox\slm"
$BinDir = Join-Path $SlmDir "bin"
$ModelDir = Join-Path $SlmDir "models"

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null

# 1. Select GGUF Model (8-Core, 12GB RAM Optimized)
if ($Turbo) {
    $ModelFile = "qwen2.5-1.5b-instruct-q4_k_m.gguf"
    $ModelUrl = "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
} else {
    $ModelFile = "qwen2.5-3b-instruct-q4_k_m.gguf"
    $ModelUrl = "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf"
}
$ModelPath = Join-Path $ModelDir $ModelFile

# 2. Ensure pre-built llama-server.exe is present (no CMake/compiler needed)
$LlamaServerExe = Get-ChildItem -Path $BinDir -Filter "llama-server.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $LlamaServerExe) {
    Write-Host "[1/2] Downloading official pre-built llama.cpp CPU server for Windows x64..." -ForegroundColor Cyan
    $ReleaseApi = "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
    $Release = Invoke-RestMethod -Uri $ReleaseApi -Headers @{ "User-Agent" = "DigUp-SLM-Setup" }
    $Asset = $Release.assets | Where-Object { $_.name -match "bin-win-cpu-x64\.zip$" -or $_.name -match "bin-win-avx2-x64\.zip$" } | Select-Object -First 1
    if (-not $Asset) {
        throw "Could not find Windows x64 CPU zip in latest llama.cpp release."
    }
    $ZipPath = Join-Path $BinDir $Asset.name
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ZipPath
    Expand-Archive -Path $ZipPath -DestinationPath $BinDir -Force
    Remove-Item $ZipPath -Force
    $LlamaServerExe = Get-ChildItem -Path $BinDir -Filter "llama-server.exe" -Recurse | Select-Object -First 1
}

# 3. Download GGUF Model Weights if not already downloaded
if (-not (Test-Path $ModelPath)) {
    Write-Host "[2/2] Downloading $ModelFile from Hugging Face..." -ForegroundColor Cyan
    Write-Host "      Source: $ModelUrl" -ForegroundColor Gray
    & curl.exe -L --fail --progress-bar -o "$ModelPath" "$ModelUrl"
    if ($LASTEXITCODE -ne 0) {
        Remove-Item $ModelPath -ErrorAction SilentlyContinue
        throw "Download of $ModelFile failed."
    }
}

Write-Host "============================================================" -ForegroundColor Green
Write-Host " DigUp Local SLM Server Active (127.0.0.1:8080)" -ForegroundColor Green
Write-Host " Model   : $ModelFile" -ForegroundColor Yellow
Write-Host " Threads : 6 CPU Threads | KV Cache: Q8_0 | Context: 8192" -ForegroundColor Yellow
Write-Host " Status  : Ready for DigUp Ask AI (GraphRAG + CAG)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Green

& $LlamaServerExe.FullName `
    -m "$ModelPath" `
    --host 127.0.0.1 `
    --port 8080 `
    -t 6 `
    -c 8192 `
    -ctk q8_0 `
    -ctv q8_0

# Builds llama.cpp (MIT), the embedding runtime: tag b11461 plus
# scripts/llama.cpp-no-logits.patch, as llama.dll + mtmd.dll (+ ggml*.dll)
# in windows/native/x64 (all out of git). Tested 2026-10-11: CUDA sm_120,
# vectors match the Mac reference (9/9 cosine >= 0.999).
# Only the libraries: no tools, no server, nothing downloaded at build time.
# Makes no system changes: cmake comes from PATH, or from a venv in Vendor/
# (needs Python + uv). Writes only under Vendor/ and windows/native/.
# Does nothing when that exact build is already there.
# PowerShell 5.1 safe. Run from anywhere: powershell -File windows/scripts/build-llama-windows.ps1
#
# Knobs (env): CUDA_ARCH (default 120 = RTX 50xx; use "all" for a release
# build that runs on every NVIDIA card, slower to compile), WITH_VULKAN=1
# (needs a Vulkan SDK; off by default since it needs a system install).

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Tag = "b11461"   # first tags with EmbeddingGemma 2 (text + vision + audio) are b11452+
$Patch = Join-Path $RepoRoot "scripts\llama.cpp-no-logits.patch"
$Source = Join-Path $RepoRoot "Vendor\llama.cpp"
$BuildRoot = Join-Path $RepoRoot "Vendor\llama-build-win"
$Out = Join-Path $RepoRoot "windows\native"
$StampFile = Join-Path $Out "BUILD"
$CudaArch = if ($env:CUDA_ARCH) { $env:CUDA_ARCH } else { "120" }
$WantVulkan = ($env:WITH_VULKAN -eq "1") -and ($env:VULKAN_SDK -and (Test-Path $env:VULKAN_SDK))
$Stamp = "$Tag $((Get-FileHash -Algorithm SHA256 -LiteralPath $Patch).Hash.Substring(0, 12)) cuda=$CudaArch vulkan=$WantVulkan"

function Has-Build($Arch) {
  (Test-Path (Join-Path $Out "$Arch\llama.dll")) -and (Test-Path (Join-Path $Out "$Arch\mtmd.dll"))
}

if ((Test-Path $StampFile) -and ((Get-Content -LiteralPath $StampFile -TotalCount 1) -eq $Stamp) `
    -and (Has-Build "x64")) {
  exit 0
}

if (!(Test-Path $Source)) {
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch $Tag https://github.com/ggml-org/llama.cpp $Source
} else {
  $at = ""
  try { $at = (git -C $Source describe --tags --exact-match 2>$null) } catch { $at = "" }
  if ($at -ne $Tag) {
    git -C $Source fetch --quiet --depth 1 origin tag $Tag
    git -C $Source checkout --quiet --force $Tag   # --force also drops the old patch
  }
}
# Without the patch, every input token costs 1 MiB of logits that an embedding
# model never produces (262k vocabulary). Skipped when it no longer fits.
try {
  git -C $Source apply --check $Patch 2>$null
  if ($?) { git -C $Source apply $Patch }
} catch { }

$Cmake = (Get-Command cmake -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
if (!$Cmake) {
  $Venv = Join-Path $RepoRoot "Vendor\cmake-venv"
  if (!(Test-Path (Join-Path $Venv "Scripts\cmake.exe"))) {
    if (Get-Command uv -ErrorAction SilentlyContinue) {
      uv venv --quiet $Venv --python 3.12
      uv pip install --quiet --python (Join-Path $Venv "Scripts\python.exe") cmake ninja
    } else {
      python -m venv $Venv
      & (Join-Path $Venv "Scripts\python.exe") -m pip install --quiet cmake ninja
    }
  }
  $Cmake = Join-Path $Venv "Scripts\cmake.exe"
}

# ARM64 needs an ARM64 machine (no cross-CUDA here): x64 now, arm64 where it runs.
$Cores = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$VulkanFlag = $WantVulkan ? "ON" : "OFF"
$Arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq "Arm64") { @{ Dir = "arm64"; Flag = "ARM64" } } else { @{ Dir = "x64"; Flag = "x64" } }
$Build = Join-Path $BuildRoot $Arch.Dir
$CudaFlags = if ($CudaArch -eq "all" -or $Arch.Dir -eq "arm64") { @() } else { @("-DCMAKE_CUDA_ARCHITECTURES=$CudaArch") }
& $Cmake -S $Source -B $Build -G "Visual Studio 17 2022" -A $Arch.Flag `
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON `
  -DGGML_CUDA=ON @CudaFlags -DGGML_VULKAN=$VulkanFlag -DLLAMA_BUILD_MTMD=ON `
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_SERVER=OFF `
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_OPENSSL=OFF
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
& $Cmake --build $Build --config Release -j $Cores --target llama mtmd
if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }
$Dest = Join-Path $Out $Arch.Dir
New-Item -ItemType Directory -Force -Path $Dest > $null
Get-ChildItem -LiteralPath (Join-Path $Build "bin\Release") -Filter *.dll |
  Copy-Item -Destination $Dest -Force
Set-Content -LiteralPath $StampFile -Value $Stamp -NoNewline
Write-Host "Built llama.cpp $Tag (patched) into $Dest"

# GT3 Revisited HD packs: sets up the PyTorch (CUDA) upscaler that hd-pack.ps1 -Torch uses, in
# place of realesrgan-ncnn-vulkan (whose 2022 Vulkan build loses the GPU on this PC).
#
#   pwsh -ExecutionPolicy Bypass -File $HOME\source\gt3r-xbox\torch-setup.ps1
#
# Makes tools\torch-venv (a Python environment of its own: PyTorch with CUDA 12.8 for RTX 50
# cards, spandrel, Pillow, numpy; a few GB) and downloads the Real-ESRGAN x4plus model into
# tools\. Needs Python 3.10-3.13 (winget install Python.Python.3.13). Safe to run again.
[CmdletBinding()]
param()
# Windows PowerShell 5 (powershell.exe, or .\script.ps1 from it): this needs PowerShell 7 (pwsh).
if ($PSVersionTable.PSVersion.Major -lt 7) {
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) { throw "PowerShell 7 is needed: winget install Microsoft.PowerShell, then a new terminal" }
    $pass = foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { "-$k" } } else { "-$k"; "$v" }
    }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @pass
    exit $LASTEXITCODE
}
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$tools = Join-Path $root "tools"
$venv = Join-Path $tools "torch-venv"
$py = Join-Path $venv "Scripts\python.exe"
$model = Join-Path $tools "RealESRGAN_x4plus.pth"

if (-not (Test-Path $py)) {
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if (-not $launcher) {
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        $launcher = Get-Command py -ErrorAction SilentlyContinue
    }
    if (-not $launcher) { throw "No Python: winget install Python.Python.3.13, then run this again" }
    Write-Host "== Making the Python environment ($venv)"
    $made = $false
    foreach ($v in "3.13", "3.12", "3.11", "3.10") {
        & py "-$v" -m venv $venv 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $py)) { $made = $true; break }
    }
    if (-not $made) { throw "Could not make a Python environment: Python 3.10 to 3.13 is needed (winget install Python.Python.3.13)" }
}
Write-Host "== PyTorch with CUDA 12.8 (a few GB the first time)"
& $py -m pip install --upgrade pip | Out-Null
& $py -m pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
if ($LASTEXITCODE) { throw "pip could not install PyTorch" }
& $py -m pip install spandrel pillow numpy
if ($LASTEXITCODE) { throw "pip could not install spandrel / Pillow / numpy" }
if (-not (Test-Path $model)) {
    Write-Host "== The Real-ESRGAN x4plus model"
    Invoke-WebRequest "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth" -OutFile $model
}
# The movies' model (hd-pack.ps1 -Movies -Torch): small and fast, made for video.
$movieModel = Join-Path $tools "realesr-animevideov3.pth"
if (-not (Test-Path $movieModel)) {
    Write-Host "== The Real-ESRGAN animevideov3 model (movies)"
    Invoke-WebRequest "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth" -OutFile $movieModel
}
Write-Host "== Checking CUDA"
& $py -c "import torch; print('PyTorch', torch.__version__, '| CUDA', torch.cuda.is_available(), '|', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'no GPU'); assert torch.cuda.is_available(); torch.zeros(1, device='cuda')"
if ($LASTEXITCODE) { throw "PyTorch cannot use the GPU (see above)" }
Write-Host "== Ready: hd-pack.ps1 ... -Torch"

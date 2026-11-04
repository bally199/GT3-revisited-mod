# ANGLE (OpenGL ES on Direct3D 11) built for UWP, for the Xbox package (docs/dev/XBOX.md):
# vcpkg's angle port, which has a UWP (CoreWindow) configuration, at the vcpkg commit the
# Windows package uses (packaging/angle.ps1). Puts every DLL it needs (libEGL.dll,
# libGLESv2.dll and zlib's) and LICENSE-ANGLE.txt in .\angle-uwp, the folder to pass as
# -DGT3R_ANGLE_DIR; cmake/Uwp.cmake packages all of them. Takes 20-30 minutes.
#   pwsh packaging/uwp/angle-uwp.ps1
$ErrorActionPreference = "Stop"
$vc = Join-Path ($env:RUNNER_TEMP ?? $env:TEMP) vcpkg-uwp
if (-not (Test-Path $vc)) {
    git clone --quiet https://github.com/microsoft/vcpkg $vc
    git -C $vc checkout --quiet 9a5dfef5d1a0438a7d24856a85bd60f309d355e9
    if ($LASTEXITCODE) { exit 1 }
    & "$vc\bootstrap-vcpkg.bat" -disableMetrics
}
& "$vc\vcpkg.exe" install angle:x64-uwp --disable-metrics
if ($LASTEXITCODE) { exit 1 }
$inst = "$vc\installed\x64-uwp"
New-Item -Force -ItemType Directory angle-uwp | Out-Null
Copy-Item -Force "$inst\bin\*.dll" angle-uwp
Copy-Item -Force "$inst\share\angle\copyright" angle-uwp\LICENSE-ANGLE.txt
Get-ChildItem angle-uwp | ForEach-Object { Write-Host $_.Name }

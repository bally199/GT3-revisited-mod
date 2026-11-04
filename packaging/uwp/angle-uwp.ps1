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
# vcpkg's angle port with one more patch (angle-no-coremessaging.patch): ANGLE's UWP build
# imports CreateDispatcherQueueController from CoreMessaging.dll, a desktop-only function the
# CoreWindow path never calls; where it is missing, Windows refuses to load libGLESv2.dll.
$overlay = Join-Path ($env:RUNNER_TEMP ?? $env:TEMP) vcpkg-uwp-ports
Remove-Item -Recurse -Force $overlay -ErrorAction SilentlyContinue
New-Item -Force -ItemType Directory $overlay | Out-Null
Copy-Item -Recurse "$vc\ports\angle" "$overlay\angle"
Copy-Item (Join-Path $PSScriptRoot angle-no-coremessaging.patch) "$overlay\angle\"
$portfile = "$overlay\angle\portfile.cmake"
# (-replace, not a match on the line end: the clone may have CRLF line ends.)
(Get-Content -Raw $portfile) -replace '001-fix-builder-error\.patch', "001-fix-builder-error.patch`n        angle-no-coremessaging.patch" |
    Set-Content -NoNewline $portfile
if (-not (Select-String -Quiet -SimpleMatch angle-no-coremessaging.patch $portfile)) { throw "could not add the patch to $portfile" }
& "$vc\vcpkg.exe" install angle:x64-uwp --disable-metrics "--overlay-ports=$overlay"
if ($LASTEXITCODE) { exit 1 }
$inst = "$vc\installed\x64-uwp"
New-Item -Force -ItemType Directory angle-uwp | Out-Null
Copy-Item -Force "$inst\bin\*.dll" angle-uwp
Copy-Item -Force "$inst\share\angle\copyright" angle-uwp\LICENSE-ANGLE.txt
Get-ChildItem angle-uwp | ForEach-Object { Write-Host $_.Name }
# The patch worked: libGLESv2.dll no longer names CoreMessaging.dll among its imports.
if (Select-String -Quiet -SimpleMatch CoreMessaging.dll angle-uwp\libGLESv2.dll) { throw "libGLESv2.dll still imports CoreMessaging.dll" }

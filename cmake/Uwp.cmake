# UWP package for Xbox Dev Mode (docs/dev/XBOX.md): included by CMakeLists.txt when
# CMAKE_SYSTEM_NAME is WindowsStore. Needs the Visual Studio generator, which writes the
# package (.msix) with the manifest, the images, SDL3.dll and ANGLE's DLLs in it.
#
#   cmake -S . -B build-uwp -G "Visual Studio 17 2022" -A x64 -DCMAKE_SYSTEM_NAME=WindowsStore
#         -DCMAKE_SYSTEM_VERSION=10.0 -DGT3R_ANGLE_DIR=<vcpkg>/installed/x64-uwp/bin
#
# The game cannot draw 3D without ANGLE (OpenGL ES on Direct3D 11): SDL_GPU has no
# backend there (no Vulkan, and SDL's Direct3D 12 needs DXIL shaders and a window handle).

if(NOT CMAKE_GENERATOR MATCHES "Visual Studio")
  message(FATAL_ERROR "UWP builds need a Visual Studio generator (-G \"Visual Studio 17 2022\"): it makes the package")
endif()
if(NOT GT3R_ANGLE_DIR)
  message(FATAL_ERROR "UWP builds need ANGLE for 3D: -DGT3R_ANGLE_DIR=<folder with the UWP libEGL.dll and "
                      "libGLESv2.dll> (vcpkg install angle:x64-uwp; docs/dev/XBOX.md)")
endif()
foreach(f libEGL.dll libGLESv2.dll)
  if(NOT EXISTS ${GT3R_ANGLE_DIR}/${f})
    message(FATAL_ERROR "GT3R_ANGLE_DIR: ${GT3R_ANGLE_DIR}/${f} is missing")
  endif()
endforeach()

# The publisher the package is signed as: the certificate's subject (docs/dev/XBOX.md, "Signing").
set(GT3R_UWP_PUBLISHER "CN=GT3Revisited-Dev" CACHE STRING "UWP: Publisher in the manifest; the signing certificate's subject")
# Package versions have four parts; the fourth is the build (CI counts runs there).
set(GT3R_UWP_BUILD 0 CACHE STRING "UWP: fourth part of the package version")
set(GT3R_UWP_VERSION "${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}.${PROJECT_VERSION_PATCH}.${GT3R_UWP_BUILD}")

set(_uwp_dir ${CMAKE_SOURCE_DIR}/packaging/uwp)
set(_uwp_manifest ${CMAKE_BINARY_DIR}/generated/Package.appxmanifest)
configure_file(${_uwp_dir}/Package.appxmanifest.in ${_uwp_manifest} @ONLY)

file(GLOB _uwp_assets ${_uwp_dir}/Assets/*.png)
set_source_files_properties(${_uwp_assets} PROPERTIES VS_DEPLOYMENT_CONTENT 1 VS_DEPLOYMENT_LOCATION "Assets")

# ANGLE and what it links against (vcpkg's UWP build may put zlib1.dll beside it): every DLL in
# the folder, at the package root where SDL loads libEGL.dll from.
file(GLOB _uwp_angle_dlls ${GT3R_ANGLE_DIR}/*.dll)
set_source_files_properties(${_uwp_angle_dlls} PROPERTIES VS_DEPLOYMENT_CONTENT 1)
set(_uwp_licenses ${CMAKE_SOURCE_DIR}/LICENSE ${CMAKE_SOURCE_DIR}/third_party/fonts/barlow/OFL.txt)
if(EXISTS ${GT3R_ANGLE_DIR}/LICENSE-ANGLE.txt)
  list(APPEND _uwp_licenses ${GT3R_ANGLE_DIR}/LICENSE-ANGLE.txt)
endif()
set_source_files_properties(${_uwp_licenses} PROPERTIES VS_DEPLOYMENT_CONTENT 1 VS_DEPLOYMENT_LOCATION "licenses")

# SDL3.dll, built here: every executable and DLL goes to bin/<config> (CMakeLists.txt sets
# CMAKE_RUNTIME_OUTPUT_DIRECTORY before SDL is fetched), so its path per configuration is known
# and only the one of the configuration being packaged goes in.
set(_uwp_sdl_dlls)
foreach(cfg Debug Release RelWithDebInfo MinSizeRel)
  set(dll ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/${cfg}/SDL3.dll)
  set_source_files_properties(${dll} PROPERTIES GENERATED TRUE VS_DEPLOYMENT_CONTENT $<CONFIG:${cfg}>)
  list(APPEND _uwp_sdl_dlls ${dll})
endforeach()

target_sources(gt3r PRIVATE ${_uwp_manifest} ${_uwp_assets} ${_uwp_angle_dlls} ${_uwp_licenses} ${_uwp_sdl_dlls})
source_group("Package" FILES ${_uwp_manifest})
source_group("Package\\Assets" FILES ${_uwp_assets})
source_group("Package\\Libraries" FILES ${_uwp_angle_dlls} ${_uwp_sdl_dlls})

set_target_properties(gt3r PROPERTIES
  # Otherwise Visual Studio writes the SDK's version over the manifest's MinVersion.
  VS_WINDOWS_TARGET_PLATFORM_MIN_VERSION 10.0.17763.0
  VS_GLOBAL_AppxPackage true
  VS_GLOBAL_AppxBundle Never
  # Building gt3r also writes the package: build-uwp/AppPackages/gt3r_<version>_x64_<config>_Test/
  # (the .msix, the .cer and Dependencies/x64 with the VCLibs framework package).
  VS_GLOBAL_GenerateAppxPackageOnBuild true
  VS_GLOBAL_AppxPackageDir ${CMAKE_BINARY_DIR}/AppPackages/
  # A package to sideload (Device Portal), not one for the Store.
  VS_GLOBAL_UapAppxPackageBuildMode SideloadOnly
  VS_GLOBAL_GenerateAppInstallerFile False
  VS_GLOBAL_AppxPackageSigningEnabled true
  VS_GLOBAL_AppxPackageSigningTimestampDigestAlgorithm SHA256)
# The certificate: packaging/uwp/make-cert.ps1 makes one (gt3r-dev.pfx, never committed).
set(GT3R_UWP_CERT "" CACHE FILEPATH "UWP: .pfx the package is signed with (packaging/uwp/make-cert.ps1)")
set(GT3R_UWP_CERT_PASSWORD "" CACHE STRING "UWP: password of GT3R_UWP_CERT")
if(GT3R_UWP_CERT)
  set_target_properties(gt3r PROPERTIES VS_GLOBAL_PackageCertificateKeyFile ${GT3R_UWP_CERT})
  if(GT3R_UWP_CERT_PASSWORD)
    set_target_properties(gt3r PROPERTIES VS_GLOBAL_PackageCertificatePassword ${GT3R_UWP_CERT_PASSWORD})
  endif()
endif()

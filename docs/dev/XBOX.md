# Xbox (UWP Dev Mode)

GT3 Revisited as a UWP app for Xbox Series X|S in Developer Mode: the same game, fullscreen on
the TV, with Xbox pads. **Status: runs on an Xbox Series S** (menus, movies, races, sound, pads,
the disc from a USB drive); the notes below are what it took.

## How it works

| Piece | What it does |
|---|---|
| [SDL3-uwp](https://github.com/XboxEmulationHub/SDL3-uwp) `release-uwp-3.4.14` | SDL 3 dropped its WinRT backend; this community fork keeps it on SDL 3.4: CoreWindow, OpenGL ES through ANGLE, Windows.Gaming.Input pads (impulse triggers), WASAPI audio, a file picker, the B button handled as back instead of suspending the app. Fetched by `cmake/Dependencies.cmake` when `CMAKE_SYSTEM_NAME` is `WindowsStore`, built as `SDL3.dll`. |
| `cmake/patches/sdl-uwp.patch` | Fixes to the fork's CMake build, which leaves out pieces its own Visual Studio project has: DLL loading (`LoadPackagedLibrary`, without which ANGLE never loads) and the file picker. Opens files with the `...FromAppW` functions, which honour `broadFileSystemAccess`, so a disc image on a USB drive opens by its path (plain `CreateFile2` only reaches the app's own folders). Asks for the whole screen (`UseCoreWindow`) instead of the TV-safe area, so ANGLE's swap chain matches the size SDL reports. Also fixes in the fork's code that the console showed: WASAPI devices activated on the UI thread (they never finished otherwise), a self-deadlock in the C++ thread backend (thread ids), keyboard key-up/down swapped (which left pad buttons held after the first press), the Back key sent as a press and a release, and the pad's virtual keys ignored as keys. |
| ANGLE, `angle:x64-uwp` from vcpkg | OpenGL ES 3.0 on Direct3D 11. Series X\|S give UWP apps D3D11 feature level 11_0 (Xbox One only gave 10_0, too little for ES 3.0). `packaging/uwp/angle-uwp.ps1` builds it through an overlay port with `angle-no-coremessaging.patch`: ANGLE's composition swap-chain code imports `CoreMessaging.dll`, which the Xbox does not have, so the DLL failed to load at all. |
| The OpenGL ES renderer (`src/render/gpu_gles.cpp`) | The only 3D renderer in a UWP app: SDL_GPU has no backend there (no Vulkan; SDL's D3D12 needs DXIL shaders and a window handle). `GT3R_UWP` makes it the first choice. |
| `cmake/Uwp.cmake`, `packaging/uwp/` | The package: manifest, tile images (`packaging/make_uwp_assets.py`), `SDL3.dll` and ANGLE's DLLs, signing. |

Controls: GT3's own buttons: Cross is A, Circle is B, Triangle is Y (which leaves Settings and
other menus), Square is X. Our own screens' hints show the Xbox names (A, B, X, Y, LB, RB, Menu,
View). Player 1 takes any pad when the one named in `config.ini` is not connected (the pad's
name changes with the console's language).

Game changes under `GT3R_UWP`: always fullscreen; OpenGL ES (ANGLE) first; online codes typed
on the game's own pad keyboard (as in VR); no update download (there is no Xbox package to
fetch); no console, process or `gethostname` code; the system Back key that comes with each B press
is dropped; the log also goes to `gt3r.log` in the user data folder.

## Build

### Option A: GitHub Actions (no Windows PC needed)

Fork the repository, push this branch, then **Actions → xbox-uwp → Run workflow**. The first
run builds ANGLE (20-30 min, then cached). Download the `gt3r-xbox-uwp` artifact: it holds
`gt3r_<version>_x64_Release_Test/` with the `.msix`, its `.cer`, and
`Dependencies/x64/Microsoft.VCLibs.x64.14.00.appx`.

### Option B: Visual Studio on Windows

Needs Visual Studio 2022 with the **Universal Windows Platform development** workload and
**C++ (v143) Universal Windows Platform tools**, CMake 3.21+ and Git.

In PowerShell, from the repository:

```
./packaging/uwp/angle-uwp.ps1                        # -> .\angle-uwp (20-30 min, once)
./packaging/uwp/make-cert.ps1 -Out gt3r-dev.pfx      # once; never commit the .pfx
# Quotes around each -D: PowerShell splits an unquoted -DCMAKE_SYSTEM_VERSION=10.0 at the dot.
cmake -S . -B build-uwp -G "Visual Studio 17 2022" -A x64 "-DCMAKE_SYSTEM_NAME=WindowsStore" `
      "-DCMAKE_SYSTEM_VERSION=10.0" "-DGT3R_ANGLE_DIR=$PWD/angle-uwp" `
      "-DGT3R_UWP_CERT=$PWD/gt3r-dev.pfx" "-DGT3R_UWP_CERT_PASSWORD=gt3r"
cmake --build build-uwp --config Release --target gt3r
```

The package lands in `build-uwp\AppPackages\`. With Visual Studio you can also open
`build-uwp\GT3Revisited.sln`, pick **Remote Machine** with the console's IP and press F5 to
deploy and debug on the Xbox directly.

## Install on the Xbox

1. **Developer Mode**: install *Xbox Dev Mode* from the Store on the console and activate it
   with a Microsoft Partner Center developer account (a one-off fee), then restart into Dev
   Home.
2. **Device Portal**: in Dev Home, *Remote Access Settings* → enable Device Portal and set a
   user and password. Open `https://<console IP>:11443` on a PC or phone.
3. **Install**: *Home → Add*, choose the `.msix`, then on the next page add the dependency
   `Microsoft.VCLibs.x64.14.00.appx` from `Dependencies\x64\`. Start.
4. **Make it a Game**: in Dev Home, highlight GT3 Revisited → *View details* → *App type:
   Game*. As an App it gets a fraction of the GPU and memory.

## The disc image

Dev Mode apps reach a USB drive only when it is **NTFS** and its permissions let in **ALL
APPLICATION PACKAGES** (the group every UWP app runs as); exFAT, which has no permissions, and a
plain NTFS drive are both refused. On a Windows PC:

1. Format the drive NTFS (Explorer → right-click → Format), or keep an NTFS drive as it is.
2. In an administrator terminal: `icacls E:\ /grant "*S-1-15-2-1:(OI)(CI)RX" /T` (E: being the drive;
   S-1-15-2-1 is ALL APPLICATION PACKAGES, RX read access), or Properties → Security → Edit → Add
   "ALL APPLICATION PACKAGES" with Read & execute, applied to the files and folders below.
3. Copy your `.iso` (about 3.9 GB) to it.

Plug it into the console; if the Xbox asks how to use the drive, choose media, **not** game
storage (that reformats it). At the first start the game asks for the disc; the picker shows the
drive (usually E:). The path is remembered like on other platforms.

Fallback: Device Portal → *File explorer* → *LocalAppData* → GT3 Revisited's `LocalState`,
upload the `.iso` there, and pick it from there (the app always reaches its own folder).

## Where things are

- **User data** (config, saves, mods, replays, screenshots, `gt3r.log`): the app's
  `LocalState\GT3Revisited\GT3Revisited\`, reachable in Device Portal's *File explorer*. Copy
  mods into `mods\` there.
- **Log**: `gt3r.log` in that folder, started afresh at each launch. The first thing to look at
  when something fails.

## Xbox-specific rendering

- **GL debug context on by default** (`[video] gpu_debug = 1`): GL errors are logged and the
  context validates calls. It went in with the fix for flashing in races; `gpu_debug = 0` turns
  it off (a little faster, untested for regressions).
- **Uniforms one buffer per slot** instead of ranges of one buffer (`glBindBufferRange` at
  offsets drew other draws' uniforms on ANGLE/D3D11 11_0).
- **Car pages and prize presentations in one pass**, supersampled 2x (when the render scale is
  under 200%) instead of GT3's 4-6 jittered passes: with the passes' scratch target every other
  frame came out wrong on the console (white, or an earlier picture over the whole screen) while
  every step read back was right. `GT3R_SHOWROOM=8` (below) brings the passes back for tests.
- **No framebuffer discards** (`glInvalidateFramebuffer`): ANGLE makes them real D3D11 discards.
- **A `glFinish` after each 3D frame** (each submitted command buffer that drew): without it the
  2D renderer now and then showed a frame whose 3D work had not reached it, in replays most
  (a car's texture sheet, black or white over the whole screen). A flush was not enough; a
  finish after every pass also cleared it, a few fps slower. `GT3R_GLES_PROBE` (below) keeps
  the other variants for tests: 2 finish after every pass and blit, 4 flush there, 8 finish at
  submits (any platform), 16 flush there.

## Testing switches

`args.txt` in the data folder (one argument per line, read at start) takes `--env NAME=value`
pairs, the way Android does: `GT3R_CAPTURE3D=<first>,<count>,<path>` (3D frames as PNGs),
`GT3R_CAPTURE2D=<first>,<count>,<path>` (each 2D step of the car pages),
`GT3R_SHOWROOM=<bits>` (car page passes: 1 one pass, 2 no floor mirror, 4 no compositing,
8 the 4 passes on Xbox), `GT3R_GLES_PROBE=<bits>` (1 clears off exact 0/1, 2 a `glFinish`
after every pass). Upload it with Device Portal's file explorer.

## Known gaps and first things to check

- **ANGLE for UWP**: built and working at vcpkg's chromium/7258 with the patch above. If
  `angle-uwp.ps1` fails on a newer vcpkg, pin the older commit in the script.
- **`APPX0702` / missing `.winmd`** at the packaging step: SDL's UWP `main` normally wants one
  C++/CX (`/ZW`) file in the app. The game is C++20, which SDL's header accepts without it; if
  MSBuild still asks for metadata, that is the error to send back.
- **First run on the console**: check `gt3r.log` for the `OpenGL ES:` line. It should say
  `OpenGL ES 3.0 (ANGLE ...)`. A `No OpenGL ES renderer` line means the context failed; the
  game then runs 2D-only (menus, no races).
- **Export a save / music folder pickers**: the fork's picker only opens single files, so
  "Export to PS2" and choosing a music folder may do nothing. Saves still work in `saves\`.
- **Screen size**: the game's UI has no TV safe-area inset. If menu edges are cut off on your
  TV, turn the TV's overscan off ("Just scan" / "Screen fit") rather than shrinking the game.
  The menus can fill a 16:9 screen with Settings → Display → *Menu shape* (stretched, or 4:3
  between blurred sides).
- **The picker's C++ file** (`SDL_winrt_pickers.cpp`) is C++/WinRT and is built with
  `/std:c++17` by the patch; if SDL fails to compile there, that flag is the place to look.
- **Online**: the manifest asks for internet and LAN client/server. Session codes through the
  relay should work; *Host by address* on the Xbox needs the console's firewall to let UDP
  47630 in, which Dev Mode may not allow.
- **Performance**: a Series S runs races at 60 fps at 100% with 4x MSAA; 300% is beyond it.
  `[video] dynamic_resolution = on` lowers the scale when frames run late.

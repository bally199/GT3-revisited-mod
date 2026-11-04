// UWP (Xbox) compatibility, force-included into every file of a WindowsStore build
// (CMakeLists.txt, GT3R_UWP; docs/dev/XBOX.md).
//
// The C runtime declares getenv only for desktop and games builds, not store apps, so the
// game's developer variables (GT3R_*) read SDL's environment there instead. Desktop builds keep
// std::getenv: SDL_getenv reads a copy taken at start, which misses variables the tests set later.
#pragma once

#include <cstdlib>

#include <SDL3/SDL_stdinc.h>

#if !defined(_CRT_USE_WINAPI_FAMILY_DESKTOP_APP) && !defined(_CRT_USE_WINAPI_FAMILY_GAMES)
namespace std {
inline const char* getenv(const char* name) noexcept { return SDL_getenv(name); }
} // namespace std
#endif

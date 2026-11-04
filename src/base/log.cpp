#include "base/log.h"

#include <SDL3/SDL_log.h>

#include <cstdio>

#if GT3R_UWP
#include <SDL3/SDL_filesystem.h>
#include <SDL3/SDL_stdinc.h>

#include <mutex>
#include <string>
#endif

namespace gt3r {

static LogLevel g_level = LogLevel::Info;

void log_set_level(LogLevel level) { g_level = level; }

void log_message(LogLevel level, const char* fmt, ...) {
    if (level < g_level) return;
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    // SDL_Log routes to logcat on Android and stderr/console elsewhere.
    SDL_LogPriority prio = SDL_LOG_PRIORITY_INFO;
    switch (level) {
    case LogLevel::Debug: prio = SDL_LOG_PRIORITY_DEBUG; break;
    case LogLevel::Info: prio = SDL_LOG_PRIORITY_INFO; break;
    case LogLevel::Warn: prio = SDL_LOG_PRIORITY_WARN; break;
    case LogLevel::Error: prio = SDL_LOG_PRIORITY_ERROR; break;
    }
    SDL_LogMessage(SDL_LOG_CATEGORY_APPLICATION, prio, "%s", buf);
#if GT3R_UWP
    // Xbox: no console, and SDL's log goes to the debugger only, so the log is also written to
    // gt3r.log in the user data folder (LocalState; Device Portal's File explorer shows it),
    // started afresh at each launch.
    static std::mutex mutex;
    static std::FILE* file = nullptr;
    static bool tried = false;
    std::lock_guard<std::mutex> lock(mutex);
    if (!tried) {
        tried = true;
        if (char* dir = SDL_GetPrefPath("GT3Revisited", "GT3Revisited")) {
            file = std::fopen((std::string(dir) + "gt3r.log").c_str(), "w");
            SDL_free(dir);
        }
    }
    if (file) {
        static const char* const kLevels[] = {"DEBUG", "INFO", "WARN", "ERROR"};
        std::fprintf(file, "%s: %s\n", kLevels[int(level)], buf);
        std::fflush(file);
    }
#endif
}

} // namespace gt3r

#include "base/log.h"

#include <SDL3/SDL_log.h>

#include <cstdio>

#if GT3R_UWP
#include <SDL3/SDL_filesystem.h>
#include <SDL3/SDL_stdinc.h>

#include <mutex>
#include <string>
#endif

#if GT3R_UWP
namespace {

// Xbox: no console, and SDL's log goes to the debugger only, so every log line, SDL's own
// included (video, render: why a GL context failed), is also written to gt3r.log in the user
// data folder (LocalState; Device Portal's File explorer shows it), started afresh at each launch.
SDL_LogOutputFunction g_default_output = nullptr;
void* g_default_userdata = nullptr;

void SDLCALL uwp_log_output(void* userdata, int category, SDL_LogPriority priority, const char* message) {
    (void)userdata;
    if (g_default_output) g_default_output(g_default_userdata, category, priority, message);
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
    if (!file) return;
    static const char* const kPriorities[] = {"", "TRACE", "VERBOSE", "DEBUG", "INFO", "WARN", "ERROR", "CRITICAL"};
    const char* p = priority > 0 && priority < int(SDL_arraysize(kPriorities)) ? kPriorities[priority] : "?";
    if (category == SDL_LOG_CATEGORY_APPLICATION) std::fprintf(file, "%s: %s\n", p, message);
    else std::fprintf(file, "%s: [SDL %d] %s\n", p, category, message);
    std::fflush(file);
}

struct UwpLogSetup {
    UwpLogSetup() {
        SDL_GetLogOutputFunction(&g_default_output, &g_default_userdata);
        SDL_SetLogOutputFunction(uwp_log_output, nullptr);
        // SDL's own reports on video, rendering, audio, input and the system (EGL, ANGLE, the window).
        SDL_SetLogPriority(SDL_LOG_CATEGORY_VIDEO, SDL_LOG_PRIORITY_DEBUG);
        SDL_SetLogPriority(SDL_LOG_CATEGORY_RENDER, SDL_LOG_PRIORITY_DEBUG);
        SDL_SetLogPriority(SDL_LOG_CATEGORY_SYSTEM, SDL_LOG_PRIORITY_DEBUG);
        SDL_SetLogPriority(SDL_LOG_CATEGORY_AUDIO, SDL_LOG_PRIORITY_DEBUG);
        SDL_SetLogPriority(SDL_LOG_CATEGORY_INPUT, SDL_LOG_PRIORITY_DEBUG);
        SDL_SetLogPriority(SDL_LOG_CATEGORY_ERROR, SDL_LOG_PRIORITY_DEBUG);
    }
};

} // namespace
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
#if GT3R_UWP
    static UwpLogSetup setup; // the first log line installs the gt3r.log output
    (void)setup;
#endif
    SDL_LogMessage(SDL_LOG_CATEGORY_APPLICATION, prio, "%s", buf);
}

} // namespace gt3r

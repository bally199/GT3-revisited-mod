#include "platform/render_scale.h"

#include <SDL3/SDL_platform_defines.h>

#include <algorithm>
#include <charconv>
#include <cmath>
#include <string>

namespace gt3r::platform {

std::optional<float> parse_render_scale(std::string_view value) {
    while (!value.empty() && value.front() == ' ') value.remove_prefix(1);
    while (!value.empty() && value.back() == ' ') value.remove_suffix(1);
    if (value.empty() || value == "auto") return std::nullopt;
    std::string s(value);
    char* end = nullptr;
    float v = std::strtof(s.c_str(), &end);
    if (end == s.c_str() || !std::isfinite(v)) return std::nullopt;
    return std::clamp(v, 0.5f, kMaxRenderScale);
}

float supersample_limit(float pixel_w, float pixel_h) {
    if (!(pixel_w > 0) || !(pixel_h > 0)) return 1.0f;
    return std::clamp(float(kMaxTargetSide) / std::max(pixel_w, pixel_h), 1.0f, kMaxRenderScale);
}

float auto_render_scale(int pixel_w, int pixel_h, bool mobile) {
#if GT3R_UWP
    // Xbox (the app's screen is 1080p): 150%, which a Series S holds at 60 fps in races.
    (void)pixel_w, (void)pixel_h, (void)mobile;
    return 1.5f;
#endif
    if (!mobile || pixel_w <= 0 || pixel_h <= 0) return 1.0f;
    // Height of the letterboxed 16:9 game area.
    float lines = std::min(float(pixel_h), float(pixel_w) * 9.0f / 16.0f);
    return std::clamp(float(kAutoTargetLines) / lines, 0.5f, 1.0f);
}

float dynamic_ceiling(int pixel_w, int pixel_h) {
    if (pixel_w <= 0 || pixel_h <= 0) return 1.0f;
    float lines = std::min(float(pixel_h), float(pixel_w) * 9.0f / 16.0f);
    return std::clamp(float(kDynamicMaxLines) / lines, 0.5f, 1.0f);
}

int default_msaa(bool mobile) { return mobile ? 2 : 4; }

bool is_mobile() {
#if defined(SDL_PLATFORM_ANDROID) || defined(SDL_PLATFORM_IOS)
    return true;
#else
    return false;
#endif
}

} // namespace gt3r::platform

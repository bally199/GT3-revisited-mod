#pragma once

#include <optional>
#include <string_view>

namespace gt3r::platform {

// [video] render_scale: "auto" (default) or 0.5..4.0. Auto keeps desktop at
// native resolution; on phones and tablets it caps the 3D resolution at about
// kAutoTargetLines lines of the 16:9 game area (the PS2 drew 448). Above 1 the 3D
// views render larger than the screen and are scaled down (supersampling), within
// supersample_limit.
constexpr int kAutoTargetLines = 900;
constexpr float kMaxRenderScale = 4.0f;

// Parses a config value; nullopt means "auto" (or an unparsable value).
std::optional<float> parse_render_scale(std::string_view value);

// The most a view of w x h pixels supersamples to: kMaxTargetSide pixels a side (400% up to
// 4096 pixels across, e.g. 3840x2160; 320% of 5120x2880), at least 1. kMaxTargetSide is the
// largest 2D texture SDL_GPU assumes (SDL_gpu.c MAX_2D_DIMENSION), the render-target limit of
// D3D12, Metal on Apple GPUs and most Vulkan drivers. GPU memory sets no cap here: 400% of
// 3840x2160 with 4x MSAA takes about 5 GB of targets (not cycled, View3D::draw); a view whose
// targets cannot be created steps down.
constexpr int kMaxTargetSide = 16384;
float supersample_limit(float pixel_w, float pixel_h);

// Scale for "auto" given the window size in physical pixels (the Xbox: 1.5).
float auto_render_scale(int pixel_w, int pixel_h, bool mobile);

// With dynamic resolution and "auto", the most the 3D resolution goes up to: the screen's full
// resolution, up to kDynamicMaxLines lines of the 16:9 game area. It starts at auto_render_scale
// and climbs while the GPU keeps up, so a phone that can draw its full resolution does.
constexpr int kDynamicMaxLines = 1440;
float dynamic_ceiling(int pixel_w, int pixel_h);

// [video] msaa when the config has none: 4 on desktop, 2 on phones and tablets. On a phone
// GPU 4x costs about 19% of the frame and 2x about 3% (Moto G Power 2024, Trial Mountain), so
// dynamic resolution keeps a sharper picture at 2x while the edges stay nearly as smooth. GPUs
// without 2x (Mali) get 4x instead (GpuContext::set_msaa), not none.
int default_msaa(bool mobile);

// True on Android and iOS builds.
bool is_mobile();

} // namespace gt3r::platform

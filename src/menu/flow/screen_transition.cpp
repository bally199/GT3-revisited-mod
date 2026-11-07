#include "menu/flow/screen_transition.h"

#include <algorithm>
#include <cmath>

namespace gt3r::menu::flow {

namespace {

constexpr int kIndicatorWait = 180;     // 3 s
constexpr int kIndicatorPeriod = 32;    // frames per blink phase
constexpr int kDelayFrames = 10;        // DelayFadeout
constexpr float kDelayGrey = 12.8f / 255.0f; // DelayFadeout wash colour 0.1 (GS 12.8)
constexpr int kLineStep = 16;           // Lineout sweep per frame (px from each edge)
constexpr float kRowSpeed = 640.0f / 24.0f; // Combout sweep per frame
constexpr float kRowStartMin = -320.0f;

// GS alpha: 0x80 = 1.0.
constexpr float gs_alpha(int a) { return a / 128.0f; }

} // namespace

LoadingPicture& race_loading_picture() {
    static LoadingPicture slot;
    return slot;
}

int LoadingPicture::frames_for(u64 elapsed_ns) {
    const u64 n = elapsed_ns * 60 / 1000000000ull;
    return int(std::clamp<u64>(n, 1, 600));
}

void ScreenTransition::start(TransitionType type) {
    type_ = type;
    active_ = true;
    frame_ = 0;
    wait_ = kIndicatorWait;
    blink_ = 0;
    delay_ = type == TransitionType::DelayFadeout ? kDelayFrames : 0;
    lines_ = 0;
    // Random start positions in [-320, 0): each row pair starts sweeping at a
    // different time. (The original uses its own generator, seeded with 100.)
    rng_ = 100;
    for (float& r : rows_) {
        rng_ = rng_ * 1103515245u + 12345u;
        r = kRowStartMin + (float((rng_ >> 8) & 0xFFFF) / 65536.0f) * -kRowStartMin;
    }
}

SDL_FColor ScreenTransition::delay_fadeout_cover(int frames) {
    const int n = frames - kDelayFrames;
    return {kDelayGrey, kDelayGrey, kDelayGrey, n > 0 ? 1.0f - std::pow(0.5f, float(n)) : 0.0f};
}

int ScreenTransition::settle_frames(TransitionType type) {
    switch (type) {
    case TransitionType::Combout: return 36;      // the latest row (-320) reaches 640 after 36 frames
    case TransitionType::Lineout: return 21;      // 320 px from each edge at 16 px per frame
    case TransitionType::DelayFadeout: return 10 + 8;
    case TransitionType::Fadeout: return 48;      // 0.906^48 ~ 1% of the picture left
    }
    return 30;
}

void ScreenTransition::draw_frame(SDL_Renderer* r, const SDL_FRect& dst) {
    if (!active_) return;
    ++frame_;
    const float sx = dst.w / 640.0f, sy = dst.h / 448.0f;
    auto rect = [&](float x0, float y0, float x1, float y1) {
        SDL_FRect f{dst.x + x0 * sx, dst.y + y0 * sy, (x1 - x0) * sx, (y1 - y0) * sy};
        SDL_RenderFillRect(r, &f);
    };
    if (delay_ > 0) {
        // DelayFadeout draws nothing at all (not even the indicator) at first.
        --delay_;
        return;
    }
    switch (type_) {
    case TransitionType::Fadeout:
        // A near-black wash at alpha 0x0C (GS scale) every frame. The GS blends in integers,
        // (wash - picture) x 12 >> 7, which keeps stepping anything brighter than the wash down
        // to it: once settled the picture is gone, the wash colour all over. A GPU's rounded
        // blend stalls within about 5 levels of it instead, leaving a faint picture: after the
        // settle frames, the wash opaque.
        SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
        SDL_SetRenderDrawColorFloat(r, 12 / 255.0f, 12 / 255.0f, 12 / 255.0f,
                                    frame_ >= settle_frames(TransitionType::Fadeout) ? 1.0f : gs_alpha(0x0C));
        rect(0, 0, 640, 448);
        break;
    case TransitionType::DelayFadeout:
        // Colour (0.1, 0.1, 0.1) at alpha 0.5 every frame.
        SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
        SDL_SetRenderDrawColorFloat(r, kDelayGrey, kDelayGrey, kDelayGrey, 0.5f);
        rect(0, 0, 640, 448);
        break;
    case TransitionType::Lineout:
        // Opaque black 1-px columns sweeping in from both edges: even columns
        // from the left, odd columns from the right.
        SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_NONE);
        SDL_SetRenderDrawColor(r, 0, 0, 0, 255);
        for (int x = 0; x < lines_; x += 2) {
            rect(float(x), 0, float(x + 1), 448);
            rect(float(639 - x), 0, float(640 - x), 448);
        }
        lines_ += kLineStep;
        break;
    case TransitionType::Combout:
        // 2-px rows, each a dark bar growing from the left edge, alpha 0x60.
        SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
        SDL_SetRenderDrawColorFloat(r, 32 / 255.0f, 32 / 255.0f, 32 / 255.0f, gs_alpha(0x60));
        for (int i = 0; i < 256; ++i) {
            if (rows_[size_t(i)] >= 1.0f) rect(0, float(2 * i), float(int(rows_[size_t(i)])), float(2 * i + 2));
            rows_[size_t(i)] += kRowSpeed;
        }
        break;
    }
    // Loading indicator: after 3 s a 16x16 square at (20, 20) blinking
    // between light grey and black every 32 frames.
    if (wait_ > 0) {
        --wait_;
        return;
    }
    ++blink_;
    bool on = ((blink_ / kIndicatorPeriod) & 1) == 0;
    SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_NONE);
    if (on) SDL_SetRenderDrawColorFloat(r, 0.9f, 0.9f, 0.9f, 1.0f);
    else SDL_SetRenderDrawColor(r, 0, 0, 0, 255);
    rect(20, 20, 36, 36);
}

} // namespace gt3r::menu::flow

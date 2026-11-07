#include "menu/menu_text.h"

#include "text/game_font.h"

#include <algorithm>

namespace gt3r::menu {

TextDrawer make_game_font_drawer(text::GameFonts& fonts) {
    return [&fonts](SDL_Renderer* r, const TextDrawRequest& req) {
        if (!fonts.loaded()) {
            draw_text_debug_font(r, req);
            return;
        }
        const TextStyle& ts = *req.style;
        if (ts.text.empty()) return;
        text::TextStyle st;
        text::GameFont* f = fonts.resolve(ts.font, st);
        if (!f) return;
        // Menu units -> target pixels; the font spec's own scale is in scale_x/scale_y.
        st.scale = req.scale_y;
        st.scale_x *= req.scale_x / req.scale_y;
        auto c8 = [](float v) { return u8(std::clamp(v, 0.0f, 1.0f) * 255.0f + 0.5f); };
        st.color = {c8(req.color.r), c8(req.color.g), c8(req.color.b), c8(req.color.a)};
        // 3x3 anchor: column = left/center/right, row = top/middle/bottom.
        int anchor = ts.align & 0x0F;
        if (anchor > 8) anchor = 4;
        int col = anchor % 3, row = anchor / 3;
        const SDL_FRect& b = req.box;
        float x = col == 0 ? b.x : col == 1 ? b.x + b.w / 2 : b.x + b.w;
        float y = row == 0 ? b.y : row == 1 ? b.y + b.h / 2 : b.y + b.h;
        st.align = col == 0 ? text::HAlign::Left : col == 1 ? text::HAlign::Center : text::HAlign::Right;
        st.valign = row == 0 ? text::VAlign::Top : row == 1 ? text::VAlign::Middle : text::VAlign::Bottom;
        f->draw_game(x, y, std::string_view(ts.text), st);
    };
}

MenuRenderer::TextHd make_game_font_hd(text::GameFonts& fonts) {
    return [&fonts](const TextStyle& ts) {
        if (!fonts.loaded() || ts.text.empty()) return false;
        text::TextStyle st;
        text::GameFont* f = fonts.resolve(ts.font, st);
        return f && f->hd(st.variant);
    };
}

void use_game_fonts(MenuRenderer& r, text::GameFonts& fonts) {
    r.set_text_drawer(make_game_font_drawer(fonts), make_game_font_hd(fonts));
}

} // namespace gt3r::menu

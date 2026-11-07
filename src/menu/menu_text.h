#pragma once

// Menu text drawn with the game's own fonts (src/text/game_font.h).

#include "menu/menu_renderer.h"

namespace gt3r::text {
class GameFonts;
}

namespace gt3r::menu {

// Returns a TextDrawer that draws pmb text with `fonts` (which must be loaded
// for the same SDL_Renderer and outlive the drawer). Falls back to the debug
// font when the fonts are not loaded.
TextDrawer make_game_font_drawer(text::GameFonts& fonts);
// Whether that drawer draws a style from HD glyph atlases (MenuRenderer::set_text_drawer).
MenuRenderer::TextHd make_game_font_hd(text::GameFonts& fonts);
// Both, into `r`.
void use_game_fonts(MenuRenderer& r, text::GameFonts& fonts);

} // namespace gt3r::menu

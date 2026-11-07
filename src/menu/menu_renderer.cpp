#include "menu/menu_renderer.h"

#include "menu/menu_canvas.h"
#include "menu/menu_text.h"
#include "base/log.h"

#include <algorithm>
#include <atomic>
#include <thread>
#include "text/game_font.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace gt3r::menu {

namespace {

SDL_FColor fcolor(const Rgba& c) { return {c.r / 255.0f, c.g / 255.0f, c.b / 255.0f, c.a / 255.0f}; }

// Text colors use the GS convention where 0x80 means fully opaque.
SDL_FColor text_fcolor(const Rgba& c) {
    return {c.r / 255.0f, c.g / 255.0f, c.b / 255.0f, std::min(1.0f, c.a / 128.0f)};
}

// The debug font only has ASCII. Game text encoding: {0x80+N, c} is char c
// of ISO-8859-N, 0xA1..0xFE start EUC-JP pairs (full width, two '?'); 0x7F is
// the game fonts' long dash.
std::string ascii_only(std::string_view s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        unsigned char c = s[i];
        if (c >= 0x20 && c < 0x7F) {
            out += char(c);
        } else if (c == 0x7F) {
            out += '-';
        } else if (c >= 0xA1 && c <= 0xFE) {
            out += "??";
            ++i;
        } else if (c >= 0x80 && c < 0xA0) {
            out += '?';
            ++i;
        } else if (c != '\r') {
            out += '?';
        }
    }
    return out;
}

} // namespace

void draw_text_debug_font(SDL_Renderer* r, const TextDrawRequest& req) {
    const TextStyle& st = *req.style;
    if (st.text.empty()) return;
    FontSpec fs = FontSpec::parse(st.font);
    float gx = fs.size / 8.0f * fs.sx * req.scale_x;
    float gy = fs.size / 8.0f * fs.sy * req.scale_y;
    if (gx <= 0 || gy <= 0) return;
    std::vector<std::string> lines;
    {
        std::string_view s = st.text;
        size_t start = 0;
        for (;;) {
            size_t nl = s.find('\n', start);
            lines.push_back(ascii_only(s.substr(start, nl == std::string_view::npos ? nl : nl - start)));
            if (nl == std::string_view::npos) break;
            start = nl + 1;
        }
    }
    int anchor = st.align & 0x0F;
    if (anchor > 8) anchor = 4;
    int col = anchor % 3, row = anchor / 3;
    float line_h = 8 * gy * 1.25f;
    float block_h = line_h * (lines.size() - 1) + 8 * gy;
    const SDL_FRect& b = req.box;
    float top = row == 0 ? b.y : row == 1 ? b.y + (b.h - block_h) / 2 : b.y + b.h - block_h;

    float osx, osy;
    SDL_GetRenderScale(r, &osx, &osy);
    SDL_SetRenderScale(r, gx * osx, gy * osy);
    SDL_SetRenderDrawColorFloat(r, req.color.r, req.color.g, req.color.b, req.color.a);
    for (size_t i = 0; i < lines.size(); ++i) {
        float w = lines[i].size() * 8 * gx;
        float left = col == 0 ? b.x : col == 1 ? b.x + (b.w - w) / 2 : b.x + b.w - w;
        float y = top + i * line_h;
        SDL_RenderDebugText(r, left / gx, y / gy, lines[i].c_str());
    }
    SDL_SetRenderScale(r, osx, osy);
}

MenuRenderer::~MenuRenderer() {
    release();
    clear_cache();
}

namespace {
MenuRenderer::ImagePack& image_pack_slot() {
    static MenuRenderer::ImagePack pack;
    return pack;
}
} // namespace

void MenuRenderer::set_image_pack(ImagePack pack) { image_pack_slot() = std::move(pack); }
const MenuRenderer::ImagePack& MenuRenderer::image_pack() { return image_pack_slot(); }

void MenuRenderer::release() {
    for (SDL_Texture* t : textures_)
        if (t) {
            hd_.erase(t);
            SDL_DestroyTexture(t);
        }
    textures_.clear();
}

void MenuRenderer::clear_cache() {
    for (auto& [scene, list] : cache_)
        for (SDL_Texture* t : list)
            if (t) {
                hd_.erase(t);
                SDL_DestroyTexture(t);
            }
    cache_.clear();
}

std::vector<SDL_Texture*> MenuRenderer::upload(const MenuScene* scene) {
    std::vector<SDL_Texture*> out;
    // The replacements first, several at a time (each is a PNG to read and decode: a page's
    // worth one after another held the menus up for seconds).
    const ImagePack& pack = image_pack();
    const std::vector<MenuImage>& images = scene->images();
    std::vector<std::optional<MenuImage>> found(images.size());
    const u64 t0 = SDL_GetTicksNS();
    if (pack && !images.empty()) {
        std::atomic<size_t> next{0};
        auto work = [&] {
            for (size_t i; (i = next++) < images.size();) {
                if (images[i].rgba.empty()) continue;
                try {
                    found[i] = pack(images[i]);
                } catch (...) {
                }
            }
        };
        const unsigned n = std::clamp(std::thread::hardware_concurrency(), 1u, 8u);
        std::vector<std::thread> helpers;
        for (unsigned k = 1; k < n && k < images.size(); ++k) helpers.emplace_back(work);
        work();
        for (std::thread& h : helpers) h.join();
    }
    const u64 t1 = SDL_GetTicksNS();
    size_t hd_count = 0, hd_bytes = 0;
    for (size_t index = 0; index < images.size(); ++index) {
        const MenuImage& img = images[index];
        SDL_Texture* t = nullptr;
        if (!img.rgba.empty()) {
            const MenuImage* use = &img;
            std::optional<MenuImage>& hd = found[index];
            if (hd && hd->width && hd->height && hd->rgba.size() >= size_t(hd->width) * hd->height) use = &*hd;
            else hd.reset();
            t = SDL_CreateTexture(r_, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, int(use->width),
                                  int(use->height));
            if (!t && hd) { // (too large for the renderer: the original)
                hd.reset();
                use = &img;
                t = SDL_CreateTexture(r_, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, int(img.width),
                                      int(img.height));
            }
            if (t) {
                SDL_UpdateTexture(t, nullptr, use->rgba.data(), int(use->width * 4));
                SDL_SetTextureBlendMode(t, SDL_BLENDMODE_BLEND);
                SDL_SetTextureScaleMode(t, SDL_SCALEMODE_LINEAR);
                if (hd) hd_.insert(t), ++hd_count, hd_bytes += hd->rgba.size() * 4;
            }
        }
        out.push_back(t);
    }
    // (How long a page's art takes to be ready: the replacements' reading and decoding, then the
    // textures made from them.)
    if (hd_count)
        LOG_INFO("menu art: %zu images, %zu HD (%.0f MB): replacements %.0f ms, textures %.0f ms", images.size(),
                 hd_count, double(hd_bytes) / 1048576.0, double(t1 - t0) / 1e6, double(SDL_GetTicksNS() - t1) / 1e6);
    return out;
}

void MenuRenderer::set_scene(const MenuScene* scene) {
    release();
    scene_ = scene;
    if (scene) textures_ = upload(scene);
}

const std::vector<SDL_Texture*>& MenuRenderer::textures_for(const MenuScene* scene) {
    if (!scene || scene == scene_) return textures_;
    auto it = cache_.find(scene);
    if (it == cache_.end()) it = cache_.emplace(scene, upload(scene)).first;
    return it->second;
}

void MenuRenderer::draw_elements(const std::vector<ElementDraw>& list, const RenderOptions& ro,
                                 const SDL_FRect& dst) {
    SDL_Rect old_clip;
    bool had_clip = SDL_RenderClipEnabled(r_);
    SDL_GetRenderClipRect(r_, &old_clip);
    SDL_Rect clip{int(dst.x), int(dst.y), int(dst.w + 0.5f), int(dst.h + 0.5f)};
    SDL_SetRenderClipRect(r_, &clip);
    SDL_SetRenderDrawBlendMode(r_, SDL_BLENDMODE_BLEND);
    // Sharp parts (set_canvas): runs of them go into the picture between the art, as models do.
    const bool can_sharp = canvas_ && canvas_->on();
    const SDL_FRect pic = can_sharp ? canvas_->picture_rect() : SDL_FRect{};
    const SDL_Rect pic_clip{0, 0, int(pic.w), int(pic.h)};
    bool in_sharp = false, art_since = true; // (art drawn into the page / layer since the last run)
    for (const ElementDraw& d : list) {
        if (d.alpha <= 0.0f) continue;
        const Sharp k = can_sharp ? sharp(d, ro) : Sharp::No;
        const bool s = k == Sharp::Yes || (k == Sharp::Either && in_sharp);
        if (s && !in_sharp) {
            canvas_->model_begin(r_, art_since);
            in_sharp = true;
        } else if (!s && in_sharp) {
            canvas_->model_end(r_);
            SDL_SetRenderClipRect(r_, &clip);
            in_sharp = false;
            art_since = false;
        }
        const SDL_FRect& to = s ? pic : dst;
        const SDL_Rect& base = s ? pic_clip : clip;
        if (d.has_clip) {
            const float sx = to.w / kMenuWidth, sy = to.h / kMenuHeight;
            SDL_Rect c{int(to.x + d.clip.x * sx), int(to.y + (kMenuHeight - d.clip.y - d.clip.h) * sy),
                       int(d.clip.w * sx + 0.5f), int(d.clip.h * sy + 0.5f)};
            SDL_Rect both;
            if (!SDL_GetRectIntersection(&c, &base, &both)) continue;
            SDL_SetRenderClipRect(r_, &both);
        }
        if (!s) art_since = true;
        if (d.kind != ElementDraw::Kind::Element) draw_effect(d, to, s);
        else if (d.element) {
            drawing_ = d.scene ? d.scene : scene_;
            draw_element(*d.element, textures_for(d.scene), d, ro, to);
            drawing_ = nullptr;
        }
        if (d.has_clip) SDL_SetRenderClipRect(r_, &base);
    }
    if (in_sharp) canvas_->model_end(r_);
    SDL_SetRenderClipRect(r_, had_clip ? &old_clip : nullptr);
}

MenuRenderer::Sharp MenuRenderer::sharp(const ElementDraw& d, const RenderOptions& ro) {
    if (d.kind == ElementDraw::Kind::Arc) return Sharp::Yes;
    if (d.kind != ElementDraw::Kind::Element || !d.element) return Sharp::Either; // (flat colour: as sharp either way)
    const Element& e = *d.element;
    // (Not those whose widget callbacks run: they can draw models of their own into the canvas.)
    if (d.overlay || (d.widget && e.widget_class && !e.widget_class->empty())) return Sharp::No;
    if (e.image && !d.hide_parts && ro.images) {
        const std::vector<SDL_Texture*>& textures = textures_for(d.scene);
        if (e.image->image < textures.size() && hd_.count(textures[e.image->image])) return Sharp::Yes;
    }
    if (e.text && ro.text && text_hd_ && text_hd_(*e.text)) return Sharp::Yes;
    // The disc's pixels look the same scaled up before or after: with the run around them.
    return Sharp::Either;
}

void MenuRenderer::draw(int page, const SceneOptions& so, const RenderOptions& ro, const SDL_FRect& dst) {
    if (!scene_) return;
    SDL_Rect old_clip;
    bool had_clip = SDL_RenderClipEnabled(r_);
    SDL_GetRenderClipRect(r_, &old_clip);
    SDL_Rect clip{int(dst.x), int(dst.y), int(dst.w + 0.5f), int(dst.h + 0.5f)};
    SDL_SetRenderClipRect(r_, &clip);
    SDL_SetRenderDrawBlendMode(r_, SDL_BLENDMODE_BLEND);
    drawing_ = scene_;
    for (const DrawItem& it : scene_->draw_list(page, so)) draw_element(*it.element, it.widget, ro, dst);
    drawing_ = nullptr;
    SDL_SetRenderClipRect(r_, had_clip ? &old_clip : nullptr);
}

void MenuRenderer::draw_element(const Element& e, bool widget, const RenderOptions& ro, const SDL_FRect& dst) {
    ElementDraw t;
    t.widget = widget;
    draw_element(e, textures_, t, ro, dst);
}

void MenuRenderer::draw_element(const Element& e, const std::vector<SDL_Texture*>& textures, const ElementDraw& t,
                                const RenderOptions& ro, const SDL_FRect& dst) {
    const bool widget = t.widget;
    const float sx = dst.w / kMenuWidth, sy = dst.h / kMenuHeight;
    // Menu space has y up; (x, y) is the bottom-left corner. The transform
    // scales about the box centre and then offsets it.
    const float bx = t.has_box ? t.box.x : e.x, by = t.has_box ? t.box.y : e.y;
    const float bw = t.has_box ? t.box.w : e.w, bh = t.has_box ? t.box.h : e.h;
    const float cx = bx + bw * 0.5f + t.dx, cy = by + bh * 0.5f + t.dy;
    const float hw = bw * 0.5f * t.scale, hh = bh * 0.5f * t.scale;
    const float left = dst.x + (cx - hw) * sx, right = dst.x + (cx + hw) * sx;
    const float top = dst.y + (kMenuHeight - cy - hh) * sy, bottom = dst.y + (kMenuHeight - cy + hh) * sy;
    const SDL_FPoint corner[4] = {{left, top}, {right, top}, {right, bottom}, {left, bottom}};
    auto modulate = [&](SDL_FColor c) {
        c.r *= t.brightness * t.tint.r;
        c.g *= t.brightness * t.tint.g;
        c.b *= t.brightness * t.tint.b;
        c.a *= t.alpha;
        return c;
    };

    if (widget && widget_ && e.widget_class && !e.widget_class->empty())
        widget_(r_, e, SDL_FRect{left, top, right - left, bottom - top}, t.alpha);

    SDL_Texture* tex = nullptr;
    if (e.image && ro.images && e.image->image < textures.size()) tex = textures[e.image->image];
    if ((e.colors || tex || t.has_colors) && !t.hide_parts) {
        SDL_Vertex v[4];
        for (int i = 0; i < 4; ++i) {
            v[i].position = corner[i];
            // The layout lists colours from the bottom-left (y up): corner i takes colour 3 - i.
            const int ci = 3 - i;
            v[i].color = modulate(t.has_colors ? t.colors[ci]
                                  : e.colors   ? fcolor((*e.colors)[size_t(ci)])
                                               : SDL_FColor{1, 1, 1, 1});
            v[i].color.a *= t.corner_alpha[i];
            v[i].tex_coord = e.image ? SDL_FPoint{e.image->uv[i * 2], e.image->uv[i * 2 + 1]} : SDL_FPoint{0, 0};
        }
        static const int idx[6] = {0, 1, 2, 0, 2, 3};
        SDL_BlendMode old_mode = SDL_BLENDMODE_BLEND;
        if (t.additive && tex) {
            SDL_GetTextureBlendMode(tex, &old_mode);
            SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_ADD);
        }
        SDL_RenderGeometry(r_, tex, v, 4, idx, 6);
        if (t.additive && tex) SDL_SetTextureBlendMode(tex, old_mode);
    }
    if (widget_overlay_ && ((widget && e.widget_class && !e.widget_class->empty()) || t.overlay))
        widget_overlay_(r_, e, SDL_FRect{left, top, right - left, bottom - top}, t.alpha);
    if (e.text && ro.text && text_) {
        TextDrawRequest req;
        TextStyle cut;
        req.style = &*e.text;
        if (t.text) {
            cut = *e.text;
            cut.text = *t.text;
            req.style = &cut;
        }
        if (t.text_bytes >= 0 && size_t(t.text_bytes) < req.style->text.size()) {
            if (req.style != &cut) cut = *e.text;
            cut.text.resize(size_t(t.text_bytes));
            req.style = &cut;
        }
        // A marquee runs along the middle of its box whatever row its anchor names: the dealers'
        // maker tickers (title_jpn2 ..., align 0x17: bottom centre) sit centred in their bars
        // on the PS2.
        if (t.text_clip) {
            if (req.style != &cut) cut = *req.style;
            const int a = cut.align & 0x0F;
            if (a <= 8) cut.align = u16((cut.align & ~0x0F) | (3 + a % 3));
            req.style = &cut;
        }
        SDL_Rect old_clip{};
        bool clipped = false;
        if (t.text_clip) {
            bool had = SDL_RenderClipEnabled(r_);
            SDL_GetRenderClipRect(r_, &old_clip);
            SDL_Rect c{int(left), int(top), int(right - left + 0.5f), int(bottom - top + 0.5f)};
            SDL_Rect both = c;
            if (had) SDL_GetRectIntersection(&c, &old_clip, &both);
            SDL_SetRenderClipRect(r_, &both);
            clipped = true;
            if (!had) old_clip = {0, 0, 0, 0};
        }
        req.box = {left + t.text_dx * sx, top, right - left, bottom - top};
        req.scale_x = sx * t.scale;
        req.scale_y = sy * t.scale;
        SDL_FColor tc = text_fcolor(e.text->color);
        if (t.has_text_color) tc = {t.text_color.r, t.text_color.g, t.text_color.b, tc.a};
        req.color = modulate(tc);
        text_(r_, req);
        if (clipped) SDL_SetRenderClipRect(r_, old_clip.w ? &old_clip : nullptr);
    }
    if (ro.outlines || (widget && ro.widget_labels)) {
        SDL_FRect box{left, top, right - left, bottom - top};
        if (widget)
            SDL_SetRenderDrawColor(r_, 255, 0, 255, 200);
        else
            SDL_SetRenderDrawColor(r_, 0, 255, 128, 140);
        SDL_RenderRect(r_, &box);
        if (widget && ro.widget_labels) {
            std::string label = e.widget_class && !e.widget_class->empty() ? *e.widget_class : e.name;
            SDL_RenderDebugText(r_, left + 2, top + 2, label.c_str());
        }
    }
}

void MenuRenderer::draw_effect(const ElementDraw& t, const SDL_FRect& dst, bool fine) {
    if (!t.has_box && !t.element) return;
    const float sx = dst.w / kMenuWidth, sy = dst.h / kMenuHeight;
    const float bx = t.has_box ? t.box.x : t.element->x, by = t.has_box ? t.box.y : t.element->y;
    const float bw = t.has_box ? t.box.w : t.element->w, bh = t.has_box ? t.box.h : t.element->h;
    const float cx = bx + bw * 0.5f + t.dx, cy = by + bh * 0.5f + t.dy;
    const float hw = bw * 0.5f * t.scale, hh = bh * 0.5f * t.scale;
    const float left = dst.x + (cx - hw) * sx, right = dst.x + (cx + hw) * sx;
    const float top = dst.y + (kMenuHeight - cy - hh) * sy, bottom = dst.y + (kMenuHeight - cy + hh) * sy;
    SDL_Vertex v[6];
    int n = 4;
    static const int quad[6] = {0, 1, 2, 0, 2, 3};
    static const int strip[12] = {0, 1, 4, 0, 4, 5, 1, 2, 3, 1, 3, 4};
    const int* idx = quad;
    int ni = 6;
    auto set = [](SDL_Vertex& vx, float x, float y, SDL_FColor c) {
        vx.position = {x, y};
        vx.color = c;
        vx.tex_coord = {0, 0};
    };
    if (t.kind == ElementDraw::Kind::Arc) {
        const float pcx = (left + right) * 0.5f, pcy = (top + bottom) * 0.5f;
        const float rx = (right - left) * 0.5f, ry = (bottom - top) * 0.5f, k = 1.0f - t.arc_thickness;
        SDL_FColor col{t.fill.r, t.fill.g, t.fill.b, t.fill.a * t.alpha};
        SDL_SetRenderDrawBlendMode(r_, SDL_BLENDMODE_BLEND);
        if (!fine) {
            // 32 vertex pairs from angle level to level2 (outer, inner).
            SDL_Vertex av[64];
            int ai[31 * 6];
            for (int i = 0; i < 32; ++i) {
                float a = (t.level + (t.level2 - t.level) * float(i) / 31.0f) * 3.14159265f / 180.0f;
                float ox = std::cos(a) * rx, oy = -std::sin(a) * ry;
                set(av[2 * i], pcx + ox, pcy + oy, col);
                set(av[2 * i + 1], pcx + ox * k, pcy + oy * k, col);
            }
            for (int i = 0; i < 31; ++i) {
                int* q = ai + i * 6;
                q[0] = 2 * i, q[1] = 2 * i + 1, q[2] = 2 * i + 2, q[3] = 2 * i + 1, q[4] = 2 * i + 3, q[5] = 2 * i + 2;
            }
            SDL_RenderGeometry(r_, nullptr, av, 64, ai, 31 * 6);
            return;
        }
        // At the screen's resolution (set_canvas): segments of about 4 pixels, and a one-pixel
        // fringe fading out past the outer and inner edges (the edges smooth, as the 640 x 448
        // picture scaled up was). Rings: outer fringe, outer, inner, inner fringe.
        const float sweep = std::abs(t.level2 - t.level) * 3.14159265f / 180.0f;
        const int n = std::clamp(int(sweep * std::max(rx, ry) / 4.0f), 8, 512) + 1;
        const float fx = rx > 1 ? 1.0f / rx : 0, fy = ry > 1 ? 1.0f / ry : 0; // a pixel, per radius
        const float kin = std::max(0.0f, k);
        SDL_FColor clear = col;
        clear.a = 0;
        std::vector<SDL_Vertex> av(size_t(n) * 4);
        std::vector<int> ai;
        ai.reserve(size_t(n - 1) * 18);
        for (int i = 0; i < n; ++i) {
            float a = (t.level + (t.level2 - t.level) * float(i) / float(n - 1)) * 3.14159265f / 180.0f;
            float c = std::cos(a), sn = -std::sin(a);
            SDL_Vertex* v4 = &av[size_t(i) * 4];
            set(v4[0], pcx + c * rx * (1 + fx), pcy + sn * ry * (1 + fy), clear);
            set(v4[1], pcx + c * rx, pcy + sn * ry, col);
            set(v4[2], pcx + c * rx * kin, pcy + sn * ry * kin, col);
            set(v4[3], pcx + c * rx * std::max(0.0f, kin - fx), pcy + sn * ry * std::max(0.0f, kin - fy), clear);
        }
        for (int i = 0; i + 1 < n; ++i)
            for (int b = 0; b < 3; ++b) {
                const int p0 = i * 4 + b, p1 = p0 + 1, q0 = p0 + 4, q1 = p1 + 4;
                for (int x : {p0, p1, q0, p1, q1, q0}) ai.push_back(x);
            }
        SDL_RenderGeometry(r_, nullptr, av.data(), int(av.size()), ai.data(), int(ai.size()));
        return;
    }
    SDL_BlendMode mode = SDL_BLENDMODE_ADD;
    if (t.kind == ElementDraw::Kind::Glow) {
        // Left edge, centre column, right edge; the centre is brighter.
        SDL_FColor e{1, 1, 1, std::clamp(t.level2 * t.alpha, 0.0f, 1.0f)};
        SDL_FColor c{1, 1, 1, std::clamp(t.level * t.alpha, 0.0f, 1.0f)};
        float mid = (left + right) * 0.5f;
        set(v[0], left, top, e);
        set(v[1], mid, top, c);
        set(v[2], right, top, e);
        set(v[3], right, bottom, e);
        set(v[4], mid, bottom, c);
        set(v[5], left, bottom, e);
        n = 6;
        idx = strip;
        ni = 12;
    } else {
        SDL_FColor c;
        if (t.kind == ElementDraw::Kind::AddQuad) {
            float g = std::clamp(t.level, 0.0f, 1.0f);
            c = {g, g, g, t.alpha};
        } else {
            c = t.fill;
            c.a *= t.alpha;
            mode = SDL_BLENDMODE_BLEND;
        }
        set(v[0], left, top, c);
        set(v[1], right, top, c);
        set(v[2], right, bottom, c);
        set(v[3], left, bottom, c);
    }
    SDL_BlendMode old;
    SDL_GetRenderDrawBlendMode(r_, &old);
    // Geometry without a texture uses the renderer's draw blend mode.
    SDL_SetRenderDrawBlendMode(r_, mode);
    SDL_RenderGeometry(r_, nullptr, v, n, idx, ni);
    SDL_SetRenderDrawBlendMode(r_, old);
}

std::vector<u32> render_page_rgba(const MenuScene& scene, int page, const SceneOptions& so, const RenderOptions& ro,
                                  int width, int height, const Vfs* fonts_vfs) {
    std::vector<u32> out;
    SDL_Surface* surf = SDL_CreateSurface(width, height, SDL_PIXELFORMAT_RGBA32);
    if (!surf) return out;
    SDL_Renderer* r = SDL_CreateSoftwareRenderer(surf);
    if (!r) {
        SDL_DestroySurface(surf);
        return out;
    }
    {
        text::GameFonts fonts;
        MenuRenderer mr(r);
        if (fonts_vfs && fonts.load(*fonts_vfs, r)) use_game_fonts(mr, fonts);
        mr.set_scene(&scene);
        SDL_SetRenderDrawColor(r, 0, 0, 0, 255);
        SDL_RenderClear(r);
        mr.draw(page, so, ro, SDL_FRect{0, 0, float(width), float(height)});
        SDL_FlushRenderer(r);
    }
    out.resize(size_t(width) * height);
    for (int y = 0; y < height; ++y)
        std::memcpy(&out[size_t(y) * width], static_cast<const u8*>(surf->pixels) + size_t(y) * surf->pitch,
                    size_t(width) * 4);
    SDL_DestroyRenderer(r);
    SDL_DestroySurface(surf);
    return out;
}

void apply_text_inset(std::vector<ElementDraw>& list) {
    for (ElementDraw& d : list) {
        if (!d.element || !d.element->text || d.kind != ElementDraw::Kind::Element) continue;
        int anchor = d.element->text->align & 0x0F;
        if (anchor > 8) continue; // centred
        int col = anchor % 3;
        if (col == 0) d.text_dx += kTextInset;
        else if (col == 2) d.text_dx -= kTextInset;
    }
}

} // namespace gt3r::menu

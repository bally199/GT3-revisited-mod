#include "video/deinterlace.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>

namespace gt3r::video {

namespace {

void shape(Frame& f, const Frame& in) {
    f.width = in.width, f.height = in.height;
    f.pts = in.pts, f.type = in.type, f.index = in.index;
    f.y.resize(size_t(in.width) * size_t(in.height));
    f.u.resize(size_t(in.chroma_width()) * size_t(in.chroma_height()));
    f.v.resize(f.u.size());
}

// A missing line: the spatial guess (the mean of `above` and `below`), held within `diff` of the
// temporal guess `t` (yadif's rule).
inline u8 adapt(int above, int below, int t, int diff) {
    const int spatial = (above + below + 1) >> 1;
    return u8(std::clamp(spatial, t - diff, t + diff));
}

// A field's chroma (`cf` rows of `cw`) interpolated to the picture's `ch` rows: picture chroma
// row j takes the field's (fractional) row j / 2 - `offset`.
void chroma(const u8* field, int cw, int cf, u8* out, int ch, float offset) {
    for (int j = 0; j < ch; ++j) {
        const float s = std::clamp(float(j) * 0.5f - offset, 0.0f, float(cf - 1));
        const int m = std::min(int(s), cf - 1), n = std::min(m + 1, cf - 1);
        const int f = int((s - float(m)) * 256.0f + 0.5f);
        const u8* a = field + size_t(m) * size_t(cw);
        const u8* b = field + size_t(n) * size_t(cw);
        u8* o = out + size_t(j) * size_t(cw);
        if (f == 0) std::memcpy(o, a, size_t(cw));
        else
            for (int x = 0; x < cw; ++x) o[x] = u8((int(a[x]) * (256 - f) + int(b[x]) * f + 128) >> 8);
    }
}

} // namespace

void FieldDeinterlacer::process(const Frame& in, Frame& first, Frame& second) {
    shape(first, in);
    shape(second, in);
    const int w = in.width, h = in.height;
    if (h < 4 || (h & 1) || in.y.size() < size_t(w) * size_t(h)) { // not two whole fields: as it is
        first.y = second.y = in.y, first.u = second.u = in.u, first.v = second.v = in.v;
        return;
    }
    const int fh = h / 2; // field lines
    const bool prev = have_prev_ && prev_w_ == w && prev_h_ == h;
    const u8* Y = in.y.data();
    const u8* P = prev ? prev_y_.data() : nullptr;
    auto A = [&](const u8* p, int k) { return p + size_t(std::clamp(k, 0, fh - 1)) * size_t(w); };
    auto B = [&](const u8* p, int k) { return p + size_t(fh + std::clamp(k, 0, fh - 1)) * size_t(w); };

    for (int k = 0; k < fh; ++k) {
        // The first field's picture: its line k on picture line 2k; picture line 2k + 1 between
        // its lines k and k + 1, in time between the last frame's second field and this one's.
        std::memcpy(first.y.data() + size_t(2 * k) * size_t(w), A(Y, k), size_t(w));
        u8* o = first.y.data() + size_t(2 * k + 1) * size_t(w);
        {
            const u8 *c = A(Y, k), *e = A(Y, k + 1), *bn = B(Y, k);
            if (!P) {
                for (int x = 0; x < w; ++x) o[x] = u8((int(c[x]) + int(e[x]) + 1) >> 1);
            } else {
                const u8 *bp = B(P, k), *pc = A(P, k), *pe = A(P, k + 1);
                for (int x = 0; x < w; ++x) {
                    const int t = (int(bp[x]) + int(bn[x]) + 1) >> 1;
                    const int d0 = std::abs(int(bp[x]) - int(bn[x])) >> 1;
                    const int d1 = (std::abs(int(pc[x]) - int(c[x])) + std::abs(int(pe[x]) - int(e[x]))) >> 1;
                    o[x] = adapt(c[x], e[x], t, std::max(d0, d1));
                }
            }
        }
        // The second field's picture: its line k on picture line 2k + 1; picture line 2k between
        // its lines k - 1 and k, from this frame's first field (1 field earlier).
        std::memcpy(second.y.data() + size_t(2 * k + 1) * size_t(w), B(Y, k), size_t(w));
        o = second.y.data() + size_t(2 * k) * size_t(w);
        {
            const u8 *c = B(Y, k - 1), *e = B(Y, k), *a = A(Y, k);
            if (!P) {
                for (int x = 0; x < w; ++x) o[x] = u8((int(c[x]) + int(e[x]) + 1) >> 1);
            } else {
                const u8 *pa = A(P, k), *pc = B(P, k - 1), *pe = B(P, k);
                for (int x = 0; x < w; ++x) {
                    const int d0 = std::abs(int(a[x]) - int(pa[x])) >> 1;
                    const int d1 = (std::abs(int(pc[x]) - int(c[x])) + std::abs(int(pe[x]) - int(e[x]))) >> 1;
                    o[x] = adapt(c[x], e[x], a[x], std::max(d0, d1));
                }
            }
        }
    }

    // Chroma: picture chroma row j sits at picture line 2j + 1/2; the first field's chroma row m
    // at 4m + 1, the second's at 4m + 2.
    const int cw = in.chroma_width(), ch = in.chroma_height(), cf = ch / 2;
    if (cf >= 1 && in.u.size() >= size_t(cw) * size_t(ch) && in.v.size() >= size_t(cw) * size_t(ch)) {
        const size_t half = size_t(cf) * size_t(cw);
        chroma(in.u.data(), cw, cf, first.u.data(), ch, 0.125f);
        chroma(in.v.data(), cw, cf, first.v.data(), ch, 0.125f);
        chroma(in.u.data() + half, cw, cf, second.u.data(), ch, 0.375f);
        chroma(in.v.data() + half, cw, cf, second.v.data(), ch, 0.375f);
    } else {
        first.u = second.u = in.u, first.v = second.v = in.v;
    }

    prev_y_.assign(in.y.begin(), in.y.begin() + std::ptrdiff_t(size_t(w) * size_t(h)));
    prev_w_ = w, prev_h_ = h, have_prev_ = true;
}

} // namespace gt3r::video

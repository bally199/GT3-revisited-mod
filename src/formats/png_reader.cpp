#include "formats/png_reader.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>

#include <zlib.h>

namespace gt3r {

namespace {
u32 be32(ByteSpan d, size_t o) { return u32(d[o]) << 24 | u32(d[o + 1]) << 16 | u32(d[o + 2]) << 8 | d[o + 3]; }

} // namespace

PngImage decode_png(ByteSpan d, u32 max_dim) {
    static const u8 kSig[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    if (d.size() < 33 || std::memcmp(d.data(), kSig, 8) != 0) throw FormatError("PNG: bad signature");
    u32 w = 0, h = 0;
    int depth = 0, ctype = 0, interlace = 0;
    std::vector<ByteSpan> idat; // (the chunks where they are: no copy of the picture's data)
    Bytes palette;
    size_t idat_bytes = 0;
    std::vector<u8> trns;
    for (size_t o = 8; o + 12 <= d.size();) {
        u32 len = be32(d, o);
        if (o + 12 + len > d.size()) throw FormatError("PNG: truncated chunk");
        const char* type = reinterpret_cast<const char*>(d.data() + o + 4);
        ByteSpan body = d.subspan(o + 8, len);
        if (!std::memcmp(type, "IHDR", 4) && len >= 13) {
            w = be32(body, 0), h = be32(body, 4);
            depth = body[8], ctype = body[9], interlace = body[12];
        } else if (!std::memcmp(type, "PLTE", 4)) {
            palette.assign(body.begin(), body.end());
        } else if (!std::memcmp(type, "tRNS", 4)) {
            trns.assign(body.begin(), body.end());
        } else if (!std::memcmp(type, "IDAT", 4)) {
            idat.push_back(body);
            idat_bytes += body.size();
        } else if (!std::memcmp(type, "IEND", 4)) {
            break;
        }
        o += 12 + len;
    }
    if (!w || !h || w > max_dim || h > max_dim) throw FormatError("PNG: bad size");
    if (interlace) throw FormatError("PNG: interlaced images are not supported");
    int channels = ctype == 0 ? 1 : ctype == 2 ? 3 : ctype == 3 ? 1 : ctype == 4 ? 2 : ctype == 6 ? 4 : 0;
    if (!channels) throw FormatError("PNG: unknown colour type");
    if (depth != 8 && !(ctype == 3 && (depth == 1 || depth == 2 || depth == 4)))
        throw FormatError("PNG: only 8-bit images (and 1/2/4-bit palettes) are supported");
    if (idat_bytes < 2) throw FormatError("PNG: no image data");
    const size_t stride = (size_t(w) * channels * depth + 7) / 8, bpp = std::max<size_t>(1, size_t(channels) * depth / 8);
    // The whole picture inflated at once into a buffer with one spare row of zeros in front (the
    // first row's "row above"), unfiltered in place a row at a time with a loop per filter (the
    // texture packs' pictures are large: a 2560 x 1792 one is 18 MB of this), then copied out.
    const size_t row = stride + 1, total = row * h;
    Bytes buf(row + total);
    {
        z_stream zs{};
        if (inflateInit(&zs) != Z_OK) throw FormatError("PNG: inflateInit failed");
        zs.next_out = buf.data() + row;
        size_t room = total;
        int rc = Z_OK;
        for (size_t k = 0; k < idat.size() && rc == Z_OK; ++k) { // the IDAT chunks, in place
            zs.next_in = const_cast<Bytef*>(idat[k].data());
            size_t left = idat[k].size();
            while (left && rc == Z_OK) {
                const uInt in = uInt(std::min<size_t>(left, 1u << 30)), out = uInt(std::min<size_t>(room, 1u << 30));
                zs.avail_in = in, zs.avail_out = out;
                rc = inflate(&zs, Z_NO_FLUSH);
                left -= in - zs.avail_in;
                room -= out - zs.avail_out;
                if (rc == Z_OK && zs.avail_in == in && zs.avail_out == out) rc = Z_BUF_ERROR; // (no progress)
                if (rc == Z_OK && !room && (left || k + 1 < idat.size())) {
                    // Full with input left: only the stream's end may follow.
                    u8 extra;
                    zs.next_out = &extra, zs.avail_out = 1;
                    zs.avail_in = uInt(std::min<size_t>(left, 1u << 30));
                    const uInt in2 = zs.avail_in;
                    rc = inflate(&zs, Z_NO_FLUSH);
                    left -= in2 - zs.avail_in;
                    if (rc == Z_OK && zs.avail_out == 0) rc = Z_DATA_ERROR; // more pixels than the size says
                }
            }
        }
        inflateEnd(&zs);
        if ((rc != Z_STREAM_END && rc != Z_OK) || room != 0) throw FormatError("PNG: bad image data");
    }
    PngImage img;
    img.width = w, img.height = h;
    img.rgba.resize(size_t(w) * h);
    for (u32 y = 0; y < h; ++y) {
        u8* cur = buf.data() + row * (y + 1) + 1;
        const u8* prev = cur - row; // (row -1: the zeros; else the row above, already unfiltered)
        switch (cur[-1]) {
        case 0: break;
        case 1:
            for (size_t x = bpp; x < stride; ++x) cur[x] = u8(cur[x] + cur[x - bpp]);
            break;
        case 2:
            for (size_t x = 0; x < stride; ++x) cur[x] = u8(cur[x] + prev[x]);
            break;
        case 3:
            for (size_t x = 0; x < bpp && x < stride; ++x) cur[x] = u8(cur[x] + (prev[x] >> 1));
            for (size_t x = bpp; x < stride; ++x) cur[x] = u8(cur[x] + ((cur[x - bpp] + prev[x]) >> 1));
            break;
        case 4:
            for (size_t x = 0; x < bpp && x < stride; ++x) cur[x] = u8(cur[x] + prev[x]);
            for (size_t x = bpp; x < stride; ++x) {
                const int a = cur[x - bpp], b = prev[x], c = prev[x - bpp];
                const int pa = std::abs(b - c), pb = std::abs(a - c), pc = std::abs(a + b - 2 * c);
                cur[x] = u8(cur[x] + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c));
            }
            break;
        default: throw FormatError("PNG: bad filter");
        }
        u32* out = img.rgba.data() + size_t(y) * w;
        if (ctype == 6) {
            std::memcpy(out, cur, size_t(w) * 4); // R G B A bytes are the pixel (little-endian)
        } else if (ctype == 2) {
            for (u32 x = 0; x < w; ++x) out[x] = u32(cur[x * 3]) | u32(cur[x * 3 + 1]) << 8 | u32(cur[x * 3 + 2]) << 16 | 0xFF000000u;
        } else if (ctype == 0) {
            for (u32 x = 0; x < w; ++x) out[x] = u32(cur[x]) * 0x010101u | 0xFF000000u;
        } else if (ctype == 4) {
            for (u32 x = 0; x < w; ++x) out[x] = u32(cur[x * 2]) * 0x010101u | u32(cur[x * 2 + 1]) << 24;
        } else {
            const int bits = depth, per = 8 / bits;
            for (u32 x = 0; x < w; ++x) {
                const u8 byte = cur[x / per];
                const int idx = (byte >> ((per - 1 - int(x % per)) * bits)) & ((1 << bits) - 1);
                if (size_t(idx) * 3 + 2 >= palette.size()) throw FormatError("PNG: palette index out of range");
                const u8 al = size_t(idx) < trns.size() ? trns[size_t(idx)] : 255;
                out[x] = u32(palette[idx * 3]) | u32(palette[idx * 3 + 1]) << 8 | u32(palette[idx * 3 + 2]) << 16 | u32(al) << 24;
            }
        }
    }
    return img;
}

std::optional<std::pair<u32, u32>> png_size(ByteSpan d) {
    static const u8 kPng[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    if (d.size() < 24 || std::memcmp(d.data(), kPng, 8) != 0 || std::memcmp(d.data() + 12, "IHDR", 4) != 0) return std::nullopt;
    auto be = [&](size_t o) { return u32(d[o]) << 24 | u32(d[o + 1]) << 16 | u32(d[o + 2]) << 8 | d[o + 3]; };
    return std::make_pair(be(16), be(20));
}

} // namespace gt3r

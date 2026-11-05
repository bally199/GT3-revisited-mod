#pragma once
// Field-split movie frames (field_layout.h: two W x H/2 fields stacked, the first on top, the
// second 1/60 s later, 1/50 on PAL, below) to two progressive W x H pictures, one at each
// field's time, instead of each field stretched to the full height ("bob", which halves the
// vertical detail of everything, moving or not).
//
// Each picture keeps its own field's lines and fills the other field's lines motion-adaptively,
// after yadif's rule: the temporal guess for a missing line is the other field's line next to it
// in time (the mean of the fields before and after where both exist), allowed to differ from the
// spatial guess (the mean of the lines above and below) only by as much as that part of the
// picture changed between frames. Still parts get the other field's line unchanged (full
// detail, no line twitter); moving parts get the spatial guess (no combing).
//
//   first field's picture:  its lines; the gaps from the second fields of this frame and the last
//   second field's picture: its lines; the gaps from the first field of this frame (the next
//                           frame is not decoded yet when this one is shown)
//
// Chroma (4:2:0, its fields stacked the same way) is each field's own, interpolated to the full
// height.
#include "video/mpeg2_decoder.h"

#include <vector>

namespace gt3r::video {

class FieldDeinterlacer {
public:
    // Forgets the last frame (a new movie, or a jump).
    void reset() { have_prev_ = false; }
    // `in`: a field-split frame (even height of at least 4). `first` / `second` get the
    // progressive pictures (same size, buffers reused). The frame is remembered for the next.
    void process(const Frame& in, Frame& first, Frame& second);

private:
    std::vector<u8> prev_y_; // the last frame's luma (stacked fields)
    int prev_w_ = 0, prev_h_ = 0;
    bool have_prev_ = false;
};

} // namespace gt3r::video

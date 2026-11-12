#pragma once

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace rail {

// The native two-column grid, in unscaled document coordinates. Shared by drawing
// and drag hit testing so scrolling and the sidebar's control scale do not drift.
struct PinnedTabLayout {
    double width;
    double top;
    static constexpr double rowHeight = 42, tileHeight = 36, gap = 6, inset = 12;

    struct Rect { double x, y, width, height; };

    double tileWidth() const { return std::floor((width - 2 * inset - gap) / 2); }
    Rect tile(size_t index) const {
        return {inset + (index % 2) * (tileWidth() + gap), top + (index / 2) * rowHeight, tileWidth(), tileHeight};
    }
    // Gaps run left to right, then top to bottom. Either half of a tile chooses
    // before/after it; the empty half of an odd final row appends.
    size_t insertionIndex(size_t count, double x, double y) const {
        if (!count || y < top) return 0;
        if (y >= top + ((count + 1) / 2) * rowHeight) return count;
        const auto row = static_cast<size_t>(std::floor((y - top + gap / 2) / rowHeight));
        const double leftMiddle = inset + tileWidth() / 2;
        const size_t column = x < leftMiddle ? 0 : x < leftMiddle + tileWidth() + gap ? 1 : 2;
        return std::min(count, row * 2 + column);
    }
    Rect insertionMarker(size_t count, size_t index) const {
        // At a row wrap, show the next row's leading edge. At the end, show the
        // trailing edge of the last tile, including an odd final row.
        const bool append = count && index >= count;
        const auto target = tile(append ? count - 1 : std::min(index, count));
        return {target.x + (append ? target.width + gap / 2 : -gap / 2) - 1.5, target.y, 3, tileHeight};
    }
};

} // namespace rail

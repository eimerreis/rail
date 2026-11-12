#pragma once

namespace rail {

// Transient, per-browser-generation gate. Chromium's native hidden-page media
// deferral handles playback; this only prevents accidental initial presentation.
class PagePresentation {
public:
    bool update(bool selected, bool browserReady, bool closing) {
        // A visited page can remain behind an unload-confirmation sheet. A
        // close/quit racing initial creation must not grant first presentation.
        const bool visible = selected && browserReady && (!closing || presented_);
        if (visible && !closing) presented_ = true;
        return visible;
    }
    bool initiallyHidden() const { return !presented_; }

private:
    bool presented_ = false;
};

} // namespace rail

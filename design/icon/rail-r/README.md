# Rail R icon

The approved logo is `../rail-r-variants/rail-r-02-rounded.png`: an upright, rounded geometric R in warm cream on a near-black tile. That PNG is the reference. It is a generated image with a gray presentation surround, so it is not packaged directly.

`scripts/make-rail-icon.swift` redraws the R as vector paths fitted to the reference (stem, bowl, counter, leg, fillets and the small rounded notch where the leg meets the bowl). Colours are sampled from it: cream `#FEEFD7`, tile `#050505`. The tile uses continuous (superellipse) corners.

The script writes:

- `resources/AppIcon.icns` — all ten macOS sizes (16–512 pt at 1× and 2×). Each size is drawn directly from the paths on the standard grid: an 824 px body in a 1024 px canvas with a soft shadow and transparent surround.
- `resources/RailMark.pdf` — the tile and R as a 64 × 64 pt vector page with no margin or shadow, for the Spaces rail.
- `AppIcon-1024.png` — the full-size icon.
- `AppIcon-sizes.png` — 16, 32 and 128 px at actual size, 16 and 32 enlarged, and the 1024 px icon at half size.
- `overlay-check.png` — the reconstruction compared with the reference. Red marks cream that the reference doesn't have; blue marks reference cream that is missing. The script prints the differing area.

Regenerate:

```sh
swift scripts/make-rail-icon.swift
```

Run it by path with `swift`. A binary compiled with `swiftc` resolves the repository from its compile-time source path, so it fails when started from another directory.

`scripts/package-ink-icon.swift` packages the earlier ink artwork and is superseded.

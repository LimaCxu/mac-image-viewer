# Mac Image Viewer

[中文](README.md) | **English**

A native macOS image viewer built to replace the stock Preview app for the *browsing* job:
paging, rotation, zoom, full screen, drag & drop, slideshow, and an EXIF inspector — all keyboard-accessible.

A single-file AppKit implementation, **240 KB**, with **zero third-party dependencies**.
Decoding is delegated entirely to the system ImageIO, so JPEG / PNG / HEIC / WebP / AVIF / TIFF / GIF / RAW / PDF
work out of the box, with EXIF orientation applied automatically.

```
Paging  ← → ↑ ↓ Space     Rotate  R / ⌥R        Zoom  ⌘+ ⌘- / pinch
100%    ⌘0                Fit     ⌘9            Full screen  F
Slideshow  S              Info    ⌘I            Settings  ⌘,
```

## Build and run

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/LimaCxu/mac-image-viewer.git
cd mac-image-viewer
./build.sh
open ImageViewer.app
```

Copy it into `/Applications` to use it as a regular app (it can also be set as the default handler for images):

```bash
cp -R ImageViewer.app /Applications/
```

Opening a specific file or a whole folder straight from the shell:

```bash
open -a "$PWD/ImageViewer.app" photo.jpg
open -a "$PWD/ImageViewer.app" ~/Pictures
```

## Features

| Action | Shortcut |
|---|---|
| Previous / next | `←` `→` `↑` `↓` `Space` |
| Jump 10 | `Page Up` / `Page Down` |
| First / last | `Home` / `End` (or `⌥⌘↑` `⌥⌘↓`) |
| Zoom in / out | `⌘+` `⌘-`, trackpad pinch, `⌘` + scroll |
| Actual size (100%) | `⌘0` or double-click |
| Fit to window | `⌘9`, toggle with double-click |
| Rotate right / left 90° | `R` / `⌥R` (or `⌘R` / `⌥⌘R`) |
| Full screen | `F` or `⌃⌘F`, exit with `Esc` |
| Slideshow | `S` or the toolbar ▶ (becomes ⏸ while playing; the first click advances immediately) |
| Info panel | `⌘I` or the toolbar ⓘ |
| Settings | `⌘,` or the toolbar ⚙ |
| Open file / folder | `⌘O` / `⇧⌘O` |

Drag & drop: drop images or folders onto the window. Folders are scanned **recursively** (up to 5000 images, sorted by path).

**Settings** (stored in `UserDefaults`, persisted across launches)

| Item | Values |
|---|---|
| Slideshow interval | 1 / 2 / 3 / 5 / 8 / 10 / 15 / 30 s (changing it while playing takes effect **immediately**) |
| Initial zoom | Fit to window / Actual size (100%) |
| Background | Light (follows the system) / Dark |

**Info panel** (refreshes automatically as you page; rows without a value are hidden)

- **File**: name, location, size, modification/creation date, UTI type
- **Image**: pixel dimensions (adjusted for EXIF orientation), megapixels, colour model, colour profile, bit depth, DPI, EXIF orientation, current zoom
- **Capture**: camera make/model, lens, aperture, shutter, ISO, focal length, 35 mm equivalent, exposure bias, flash, capture time, software
- **Location**: latitude/longitude (with N/S, E/W) and altitude

## Self-test

The built-in self-test drives the real UI logic and **reads the rendered output back into a bitmap for pixel-level
verification** — it does not merely check that the process stayed alive.

```bash
# Generate the fixtures first (all images are synthesised locally; the repo ships no third-party assets)
swiftc -O -o /tmp/make_test_images Tools/make_test_images.swift
/tmp/make_test_images test-images

# Run the 41 checks
./ImageViewer.app/Contents/MacOS/ImageViewer test-images --selftest
```

Coverage includes: folder scanning, two-phase decoding, fit ratio, actual-size = 100%, zoom factors, canvas
dimensions swapping after rotation, **rotation direction (clockwise)**, **the image not being drawn upside down**,
paging, slideshow auto-advance and its button state, settings persistence, the dark background actually reaching
the pixels, info-panel content and refresh on paging, and EXIF aperture/shutter/ISO/focal-length parsing.
On success it prints `SELFTEST: PASS` and exits 0.

> This suite has caught two genuine bugs, both visible in the commit history:
> 1. Inside a `flipped NSView`, `CGContext.draw` renders a `CGImage` **upside down**. It was pinned down with a
>    coordinate-convention-independent control experiment (`Tools/probe_orientation.swift`).
> 2. When EXIF is written by libraries such as PIL, rational values (FNumber/ExposureTime/FocalLength) end up with
>    a non-conformant type and **ImageIO silently drops all three tags**, which produced a false failure.
>    `Tools/probe_exif.swift` dumps the tags, values and Swift types ImageIO actually exposes.

## Design notes

- **Two-phase decoding**: a 1600 px preview appears immediately (even for huge files), the full-resolution image
  replaces it in the background; neighbouring images are preloaded into an `NSCache`.
- **System decoder**: `CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceCreateThumbnailWithTransform` —
  EXIF orientation, colour management and RAW/HEIC are all handled by the system instead of hand-written decoders.
- **Zoom is delegated to `NSScrollView`**: `allowsMagnification` provides pinch and scroll positioning, and a custom
  `CenteringClipView` centres images smaller than the window.
- **Rotation is non-destructive**: only a quarter-turn counter is kept and applied as a drawing transform; the file is
  never modified.
- **Definition of 100%**: one image pixel = one screen pixel (computed from the screen scale factor), recalculated when
  the window first appears or moves to another display.
- **Slideshow** uses a one-shot timer that is re-armed on every page change, registered in the `.common` run loop mode
  so it cannot be starved while you scroll or use the trackpad.
- **Build robustness**: `build.sh` compiles into a staging directory first, so a failed build never destroys a working
  `.app`, and its compiler cache directory is derived from the project path so moving the checkout does not hit stale
  caches.

## About REA

The development workflow of this project used **[REA](https://github.com/morluto/rea)** (`rea-agents` 6.5.0, through its
MCP interface), but **no binary was decompiled**. Concretely, REA did two things here:

| Stage | What REA did | What it produced |
|---|---|---|
| Reconnaissance before coding | Inventory of Mach-O dependencies of the system Preview app (`/System/Applications/Preview.app`) | 87 dependent frameworks / 105 load commands / arm64e, of which the actual decoding layer is only `ImageIO + UniformTypeIdentifiers + CoreGraphics + ColorSync`. This is why this tool links only those four. |
| Verification after every build | Artefact identity pinning | sha256, ad-hoc signing state and cdhash, confirming the shipped binary is the verified one |

Size comparison (both measured by REA on the same machine):

| | Dependent frameworks | Load commands | Architectures |
|---|---|---|---|
| System Preview | 87 | 105 | arm64e + arm64 |
| This tool | 24 | 42 | arm64 |

**Statement**: every line of code in this repository is an original implementation that only calls publicly documented
AppKit / ImageIO / CoreGraphics / UniformTypeIdentifiers APIs. It contains no code, resources or decompiled output from
Preview or any other proprietary software. The REA results above are cited solely as the basis for architecture
decisions and artefact verification.

## Repository layout

```
Sources/main.swift             The whole implementation (single file, ~1400 lines)
Resources/Info.plist           Bundle configuration
Tools/make_test_images.swift   Generates the self-test fixtures (including a conformant EXIF sample)
Tools/probe_bitmap.swift       Probe for the y-axis orientation of NSBitmapImageRep
Tools/probe_orientation.swift  Control experiment for CGImage drawing orientation
Tools/probe_exif.swift         Dumps the EXIF tags/types ImageIO actually exposes
build.sh                       Compile + package + ad-hoc sign
```

## Known limitations

- arm64 only (for a universal binary, add `x86_64` to `-target` in `build.sh` and merge with `lipo`).
- GIFs show the first frame only; no animation playback.
- No thumbnail strip, no delete/rename, no multi-page PDF browsing.
- Not notarised; distributing to other machines requires your own signing.

## License

[MIT](LICENSE)

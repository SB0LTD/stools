<p align="center">
  <img src="logo.png" alt="stools" width="160" />
</p>

<h1 align="center">stools</h1>

<p align="center">
  <strong>The SB0 tools suite.</strong><br/>
  <sub>A native, zero-dependency collection of small command-line tools — built in Sig.</sub>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/sig-0.4%2B-6f42c1?style=flat-square" alt="Sig 0.4+" />
  <img src="https://img.shields.io/badge/version-0.0.1-blue?style=flat-square" alt="Version 0.0.1" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License: MIT" />
  <img src="https://img.shields.io/badge/platform-windows%20%7C%20macos%20%7C%20linux-lightgrey?style=flat-square" alt="Platform" />
</p>

---

## Overview

`stools` is a suite of small, fast command-line tools from SB0. It is scaffolded
with [zpm](https://github.com/SB0LTD/zpm) and implemented entirely in **Sig** —
no allocator, no heap in the hot path, and it builds fully offline.

## Install / Build

Requires [Sig](https://github.com/SB0LTD/sig) 0.4 or newer.

```sh
sig build          # build the suite
sig build test     # run the tests
sig build run      # build and run
```

The compiled binaries land in `sig-out/bin/` (`.exe` on Windows): the `stools`
dispatcher, the `img2elementor` and `url2elementor` tools, and `stools-ui` —
the launcher GUI.

### Platforms

stools cross-compiles to every SB0 target from a single host:

| Platform | Notes |
| --- | --- |
| Windows (x86_64, aarch64) | full `slicker` support (Win32 GDI + SendInput) |
| Linux (x86_64, aarch64) | full `slicker` support (Xlib + XTest) |
| macOS (x86_64, aarch64) | full `slicker` support (CoreGraphics + CGEvent) |
| SB0 native (aarch64) | bootable SB0K image; `slicker` capture lands when the Nexus compositor exposes capture/enumerate/inject ops |

```sh
sig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast   # any hosted target
bash scripts/build-sb0.sh sig-out/bin/stools-aarch64-sb0.sb0k # SB0K native image
```

CI builds and tests on every push, cross-compiles all targets, and boots the
SB0K image under QEMU. Releases (on `v*` tags) publish signed archives for all
platforms.

## Usage

```sh
stools <command> [args]
```

| Command             | Description                                              |
| ------------------- | -------------------------------------------------------- |
| `help`              | Show usage                                               |
| `version`           | Print the suite version                                  |
| `slicker [flags]`   | Visual UI-automation engine — find and click UI elements |
| `hash <text>`       | Print the FNV-1a 64-bit hash of the given text           |
| `now`               | Print a monotonic timestamp (nanoseconds)                |

### Examples

```sh
stools version
stools hash "hello"
stools now
```

## slicker

`slicker` scans every open window, finds a target UI element, and — when you opt
in — clicks it. It captures each window's true framebuffer via **Windows
Graphics Capture** (so it sees GPU-composited apps like VS Code / Kiro / Chrome,
even when they're behind other windows), then locates the target either by
**color region** or by **image template**.

### Finding by color region (most robust for solid-color buttons)

A distinctively-colored button (e.g. a purple "Allow" approval button) is best
found by its fill color + size: only the button forms a large connected region
of that color, so scattered UI accents of the same hue are ignored.

```sh
# Detect only (safe): report where the purple button is, never click.
stools slicker --multi --sig 113,56,204 --tol 24 --min-area 3000 --min-fill 550 --title gotliv

# Find AND keep clicking it as it reappears (continuous auto-approve):
stools slicker --multi --sig 113,56,204 --tol 24 --min-area 3000 --min-fill 550 --title gotliv --click --watch
```

- `--sig R,G,B` the button's fill color (sample it from a screenshot)
- `--tol N` per-channel color tolerance
- `--min-area N` minimum connected-pixel area — filters out small same-color noise
- `--multi` treat each distinct region separately (click every match)
- `--title SUBSTR` restrict to windows whose title contains `SUBSTR`
- `--click` actually click (opt-in; detect-only without it)
- `--watch` scan continuously; `--interval-ms N` sets the cadence (default 500)

### Finding by image template (shape matching)

Give slicker a cropped PNG of the element; it matches by edge/shape (robust to
color and brightness shifts):

```sh
stools slicker --template button.png --score 850 --title gotliv --click --watch
```

### Safety

slicker never clicks unless you pass `--click` **and** an explicit target
(`--sig` or `--template`). There is no built-in rule targeting any
application's prompts — what it automates is entirely operator-chosen.

## stools-ui

`stools-ui` is a translucent, dark-glass control panel for the whole suite. It
renders every command as a form — toggles, steppers, color pickers, text
fields, and segmented choices — and launches the selected tool for you, showing
its output inline. Long-running commands (like `slicker --watch`) spawn in the
background with a **Stop** control; one-shot commands run and capture their
output.

```sh
stools-ui
```

The launcher is **data-driven**: every command and flag comes from a single
schema (`src/tool_schema.sig`). Adding a new tool is one entry in that
registry — the UI renders it and the argv assembler serializes it with no other
changes. It reuses the same safety gate as the CLI (slicker won't click without
an explicit target). Visually it matches the SB0 house style: a borderless,
layered see-through window over the zpm OpenGL + `materials` render stack, with
the suite logo in the titlebar and command rail.

The app icon (window, taskbar, and Explorer) comes from a single `src/stools.ico`
(generated from `logo.png` by `scripts/make-ico.ps1`, with sizes up to 256 for
Windows 11). It is embedded natively: the window/rail logo via `@embedFile`, and
the exe icon via `src/stools.rc` compiled and linked by `sig build` (the build
step's `.win32_resource` option) — no post-build tools.

## Tools

The suite ships as focused binaries alongside the `stools` dispatcher:

| Binary | Purpose |
| --- | --- |
| `stools` | Suite dispatcher + `slicker`, a config-driven visual UI-automation engine (scans all windows, detects a color signature, opt-in clicks + verifies). |
| `stools-ui` | Translucent launcher GUI — renders the data-driven command registry into a form and launches any tool via subprocess, streaming its output. |
| `img2elementor` | Reconstruct an Elementor template from a **PNG screenshot** (geometry + placeholders). |
| `url2elementor` | Reconstruct an Elementor template from a **live URL's rendered DOM** — real text, colors, images, and layout. |

There are two reconstruction tools because a flat screenshot and a live page
are fundamentally different inputs. `img2elementor` works from a raster and can
only recover *shape* (it emits placeholder text and empty image boxes).
`url2elementor` drives a real browser and reads the rendered document, so it
recovers the *actual content*. Use `url2elementor` for a live site;
`img2elementor` when all you have is an image.

### url2elementor

```sh
url2elementor <https://site> [output.json] [--port N] [--keep-open]
```

Reconstructs an Elementor template from a live page by reading its **rendered
DOM** — the reliable way to recover what a flat screenshot loses. It:

1. launches a headless browser (Chrome/Edge/Chromium/Brave) with the remote
   debugging port open,
2. attaches to the page target over a **pure-Sig WebSocket**,
3. navigates to the URL and waits for load (plus a short settle for
   client-rendered pages),
4. evaluates an in-page extractor that walks the visual box tree and builds the
   Elementor element array from **computed styles, geometry, real text, and
   image URLs**, and
5. writes a valid Elementor template JSON — importable via **Templates →
   Import**.

The result carries the page's real words, colors, font sizes, alignment,
buttons, and section layout (bands become containers; side-by-side elements
become flex rows). Inline `<svg>` icons are captured as data URIs; `<img>` and
CSS `background-image` sources are captured as image widgets (side-load them
into the media library on import to render them locally).

Honest limits: exact pixel spacing and custom webfonts are not reproduced (the
page falls back to the theme font), and heavily canvas- or shadow-DOM-driven
sites expose less to the extractor. Geometry, color, text, and structure are the
reliable output.

- `--port N` remote debugging port for the headless browser (default 9222)
- `--keep-open` leave the browser running after extraction (debugging)

The whole transport — WebSocket (RFC 6455), the Chrome DevTools Protocol client,
and the DOM→Elementor mapping — is pure Sig and lives in
[zpm](https://github.com/SB0LTD/zpm) (`net/websocket`, `platform/cdp`,
`elementor/dom_import`). It speaks only to `std.Io.net`, so it is cross-platform
by construction (no OS-specific code, no libc).

### img2elementor

```sh
img2elementor <input.png> [output.json] [--debug]   # from a local screenshot
```

PNG-only. (For a live URL, use `url2elementor` — a flat raster cannot recover
real text or images.) The pipeline decodes the PNG, detects the page
background, segments the layout into rows and columns, estimates per-region
typography (size, weight, color, alignment), and writes a valid Elementor
template JSON — importable via **Templates → Import**. It reconstructs the page
*structure*: a horizontal nav row, side-by-side hero columns, headings,
buttons, and image blocks, with measured colors and font sizes.

What it can and can't recover: geometry, colors, font sizes, alignment, and the
row/column layout are reconstructed faithfully. Exact glyph text and photo
*content* cannot be recovered from a flat raster, so text is emitted as
size-keyed placeholders (`"Multi-line heading text"`, `"Body text"`) and images
as empty boxes sized to the region — the operator fills those in.

`--debug` prints the detected regions (kind, bounds, line count, font height,
density) to stderr — useful for tuning.

Entirely pure-Sig: PNG decode, image analysis, and JSON emission all live in
[zpm](https://github.com/SB0LTD/zpm).

## Project layout

```
stools/
├─ build.sig            # pure-Sig bounded build graph
├─ build.sig.zon        # package manifest (name, version, deps)
├─ src/
│  ├─ main.sig          # entry point + command dispatch + slicker CLI
│  ├─ slicker.sig       # visual UI-automation engine (scan/detect/click/watch)
│  ├─ img2elementor.sig # PNG screenshot → Elementor template
│  ├─ url2elementor.sig # live URL → Elementor template (via headless browser DOM)
│  ├─ tool_schema.sig   # data-driven registry of commands + flags (drives the UI)
│  ├─ launch.sig        # schema → argv → subprocess launch (generic)
│  ├─ launcher.sig      # stools-ui: translucent launcher GUI
│  ├─ stools.ico        # app icon (window/taskbar/exe), sizes 16..256
│  ├─ stools.rc         # win32 resource: embeds stools.ico as the exe icon
│  └─ platform/         # SB0 bare-metal entry, UART, linker script
├─ CHANGELOG.md
├─ LICENSE
└─ logo.png
```

Detection and capture live in [zpm](https://github.com/SB0LTD/zpm):
`ui_detect` (color-region + template/chamfer matching, Layer 0) and `screencap`
(window enumerate/capture/click per OS — Windows Graphics Capture, CoreGraphics,
Xlib, and the SB0 Nexus client).

The `url2elementor` web-automation stack is also pure-Sig zpm, built on
`std.Io.net` so it is cross-platform with no OS-specific code:

- `net/websocket` — an RFC 6455 WebSocket client (handshake, framing, masking,
  fragmentation, ping/pong, close).
- `platform/cdp` — a Chrome DevTools Protocol client: launches a headless
  browser, discovers its page target over HTTP, and drives it (navigate +
  `Runtime.evaluate`) over the WebSocket.
- `elementor/dom_import` — the in-page extractor JavaScript plus the Elementor
  document envelope assembler.

The Elementor template builder (`elementor/document`) is shared by both tools.

## Contributing

New tools slot into the `Command` enum and its dispatch in `src/main.sig`. Keep
each tool allocation-free and add a test alongside it. Run `sig build test`
before opening a PR.

## License

MIT © SB0. See [LICENSE](LICENSE).

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

The compiled binary lands at `sig-out/bin/stools` (`.exe` on Windows).

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

## Tools

The suite ships as focused binaries alongside the `stools` dispatcher:

| Binary | Purpose |
| --- | --- |
| `stools` | Suite dispatcher + `slicker`, a config-driven visual UI-automation engine (scans all windows, detects a color signature, opt-in clicks + verifies). |
| `img2elementor` | Reconstruct an editable Elementor template from a screenshot. |

### img2elementor

```sh
img2elementor <input.png> [output.json]
```

Decodes the PNG, detects the page background, segments the layout, estimates
per-region typography (size, weight, color, alignment), and writes a valid
Elementor template JSON of containers, headings, text, buttons, and image
blocks — importable via **Templates → Import**. Colors, sizes, and layout are
reconstructed faithfully; exact glyph text can't be recovered from a flat
raster, so text bodies are size-keyed placeholders to fill in. Entirely
pure-Sig (PNG decode, image analysis, and JSON emission all live in
[zpm](https://github.com/SB0LTD/zpm)).

## Project layout

```
stools/
├─ build.sig            # pure-Sig bounded build graph
├─ build.sig.zon        # package manifest (name, version, deps)
├─ src/
│  ├─ main.sig          # entry point + command dispatch + slicker CLI
│  ├─ slicker.sig       # visual UI-automation engine (scan/detect/click/watch)
│  ├─ img2elementor.sig # screenshot → Elementor template
│  └─ platform/         # SB0 bare-metal entry, UART, linker script
├─ CHANGELOG.md
├─ LICENSE
└─ logo.png
```

Detection and capture live in [zpm](https://github.com/SB0LTD/zpm):
`ui_detect` (color-region + template/chamfer matching, Layer 0) and `screencap`
(window enumerate/capture/click per OS — Windows Graphics Capture, CoreGraphics,
Xlib, and the SB0 Nexus client).

## Contributing

New tools slot into the `Command` enum and its dispatch in `src/main.sig`. Keep
each tool allocation-free and add a test alongside it. Run `sig build test`
before opening a PR.

## License

MIT © SB0. See [LICENSE](LICENSE).

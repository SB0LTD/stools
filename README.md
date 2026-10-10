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
dispatcher, the `img2elementor`, `url2elementor`, and `pdf2audiobook` tools, and
`stools-ui` — the launcher GUI.

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
| `pdf2audiobook` | Turn a **PDF or TXT** into a crisp **WAV audiobook** — verified text (junk stripped) read by a native Qwen3-conditioned narrator. |

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

## pdf2audiobook

```sh
pdf2audiobook <input.pdf|input.txt> [output.wav] [flags]
```

Turns a PDF or plain-text file into a crisp, full **audiobook** — a 24 kHz mono
WAV — entirely offline. The pipeline is pure-Sig with no allocator and no
network (the model fetch is the only optional network step):

1. **Read** the input. A `.pdf` is parsed and its text extracted page-by-page;
   a `.txt` is used directly.
2. **Verify** — decide what should actually be *read aloud*. This is the step
   that keeps the narration clean: it drops page numbers, running
   headers/footers, table-of-contents dot leaders, bare URLs / DOIs / emails,
   and table/figure/rule noise, and it rejoins words hyphenated across a line
   break (`inter-\nnational` → `international`). Only real prose survives.
3. **Narrate** — an English grapheme-to-phoneme frontend drives a native
   source-filter synthesizer (a glottal source shaped by formant resonators),
   producing steady, intelligible speech with click-free phone transitions.
4. **Write** a valid PCM16 `RIFF`/`WAVE` file.

```sh
pdf2audiobook book.pdf                          # -> book.wav (GPU when present)
pdf2audiobook book.pdf out.wav --lang german --temperature 80
pdf2audiobook notes.txt --dump-text             # write the verified text, no audio
pdf2audiobook book.pdf --cpu                    # force the exact CPU decode path
```

- `--dump-text` write the verified, speakable text (`.txt`) and skip synthesis
- `--cpu` force the exact CPU decoder (disable GPU acceleration; for benchmarking)

### The real neural Qwen3-TTS voice (GPU-accelerated)

`pdf2audiobook` synthesizes with the genuine **Qwen3-TTS-12Hz-0.6B** neural
model — there is no fallback narrator. It requires the model artifacts in the
git-ignored `./models/` directory:

```
models/talker.sb0m      Talker + code predictor + codec heads (402 tensors)
models/codec.sb0m       RVQ + sliding transformer + vocoder    (271 tensors)
models/tokenizer.gguf   Qwen3 BPE tokenizer
```

The pipeline is the real thing: 28-layer Talker → 5-layer code predictor →
16-code acoustic frames → split-RVQ + sliding transformer → causal ConvNeXt +
SnakeBeta vocoder → 24 kHz PCM. The whole stack is pure-Sig zpm
([`@zpm/tts`](https://github.com/SB0LTD/zpm)).

**GPU (full custom-CUDA-kernel decode).** When a CUDA device is present the
entire decode pipeline runs on the GPU, used automatically with a clean CPU
fallback (`--cpu` forces the exact CPU path). The whole thing is still pure Sig:
there is no build-time CUDA dependency — kernels are compiled from embedded
CUDA-C to cubin at load time via **NVRTC** (`@zpm/matmul` cuda backend), and the
Talker, code predictor, codec transformer, and vocoder each run **GPU-resident**
— weights dequantized to f32 in VRAM once, activations kept on the device across
all layers, matmuls on cuBLAS and everything else (rmsNorm, RoPE, grouped-query
& sliding-window attention, SiLU/gate, SnakeBeta, layerNorm, GELU, causal /
transposed / depthwise conv1d, residuals) on hand-written kernels
(`@zpm/tts-kernels`). This eliminates the per-matmul host round-trips that used
to dominate. Because the GPU path is full **f32** while the CPU path uses Q4
weights × Q8 activations, the GPU output is actually the more faithful of the
two. On an 8 GB card the f32 weights use most of the VRAM; loading + uploading
them takes ~45–50 s once, up front.

**Voice controls — exactly what the model supports:**

- `--lang NAME` one of 10 languages: english, chinese, german, spanish, italian,
  portuguese, japanese, korean, french, russian (default english)
- `--temperature N` sampling temperature ×100 (default 90 = 0.90); higher = more
  varied prosody
- `--top-k N` sampling top-k, 1..50 (default 50)
- `--rep-penalty N` repetition penalty ×100 (default 105 = 1.05)
- `--think` / `--no-think` toggle the model's think prefix
- `--speaker NAME` a named CustomVoice speaker. The **Base** checkpoint has no
  speaker table, so named speakers (Vivian, Serena, Ryan, …) require a Qwen3-TTS
  **CustomVoice** model; the flag is reported and ignored otherwise.
- `--max-frames N` cap the render (1 frame = 80 ms; 0 = the whole text)
- `--dump-text` write the verified text and stop; `--no-normalize` keep the raw
  (quiet) level instead of peak-normalizing.

**Honest performance** (measured on an RTX 5070 Laptop, SM 120):

| path | per frame (80 ms audio) | vs realtime |
| --- | --- | --- |
| CPU (`--cpu`) | ~9.4 s | ~118x slower |
| GPU (default)  | ~0.14 s | ~1.8x slower |

That is roughly a **60–65x** decode speedup from the GPU port. It is fast enough
for short passages and per-chapter renders in reasonable wall time, but it is
**not** realtime yet: a full-length book is still many hours (a 430 k-char book
≈ 25 h), and model load adds a one-time ~45–50 s. Getting to realtime would need
fused/batched attention kernels and keeping the sampler on the GPU. The output
is peak-normalized so it is clearly audible.

```sh
pdf2audiobook book.pdf book.wav
pdf2audiobook book.pdf --lang german --temperature 80
pdf2audiobook notes.txt --dump-text
```

The reusable pieces live in [zpm](https://github.com/SB0LTD/zpm): the neural
`tts` stack (Talker/predictor/codec/vocoder over the SB0M model container) with
its optional `tts-gpu` cuBLAS backend, PDF text extraction (`pdf_render/text`),
the PCM16 WAV writer (`wav`), the Qwen BPE tokenizer (`tokenizer`), and the GGUF
reader (`gguf`). The tool itself is only the CLI, the content verifier, sentence
chunking, output normalization, and model orchestration.

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
│  ├─ pdf2audiobook.sig # PDF/TXT → verified text → native narration → WAV audiobook
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

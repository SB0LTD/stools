# Changelog

All notable changes to **stools** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`pdf2audiobook` — full GPU (custom CUDA kernel) neural decode.** The entire
  Qwen3-TTS decode pipeline now runs GPU-resident when a CUDA device is present:
  the 28-layer Talker, 5-layer code predictor, 8-layer codec transformer, and
  ConvNeXt/SnakeBeta vocoder all keep their weights (dequantized to f32) and
  activations in VRAM across every layer. matmuls run on cuBLAS; rmsNorm, RoPE,
  grouped-query & sliding-window attention, SiLU/gate, SnakeBeta, layerNorm,
  GELU, and causal/transposed/depthwise conv1d run on hand-written CUDA kernels
  (new zpm `tts-kernels`). Kernels are compiled from embedded CUDA-C to cubin at
  load time via **NVRTC** — no build-time CUDA toolkit dependency, and it
  degrades cleanly to the exact CPU path (forceable with `--cpu`). This removes
  the per-matmul host round-trips and yields a ~60–65x decode speedup
  (~9.4 s/frame CPU → ~0.14 s/frame GPU on an RTX 5070 Laptop; still ~1.8x
  slower than realtime). Because the GPU path is full f32 while the CPU path is
  Q4×Q8, the GPU output is the more faithful of the two. New `--cpu` flag.
- **`pdf2audiobook`** — turn a **PDF or TXT** into a crisp, full **audiobook**
  (24 kHz mono WAV). Entirely native and offline (pure-Sig zpm, no allocator):
  - **Text extraction**: PDFs are decoded page-by-page — content streams are
    FlateDecoded and text is pulled from the `Tj`/`TJ`/`'`/`"` operators, with
    escapes and kerning gaps handled (new zpm `pdf_render.text`). TXT is read
    directly.
  - **A content verifier** decides what actually gets read: it drops page
    numbers, running headers/footers, table-of-contents dot leaders, bare
    URLs/DOIs/emails, and layout/table noise, and rejoins words hyphenated
    across line breaks — so only real prose reaches the synthesizer.
  - **Native narration**: an English grapheme-to-phoneme frontend drives a
    source-filter synthesizer (glottal source + formant resonators) that reads
    the text clearly, with `--voice male|female|neutral` and `--rate`. New zpm
    Layer-0 modules `tts_voice` (synthesizer) and `wav` (PCM16 RIFF/WAVE writer).
  - **Qwen3 0.6B custom voice**: with `--fetch` the tool downloads a Qwen3 0.6B
    GGUF into a git-ignored `./models/` and conditions the narrator (pitch,
    pacing, timbre) from it; it degrades cleanly to the built-in voice when the
    model is absent. Honest limit: the GGUF is a text/decoder model, so it
    *shapes* the native synthesizer rather than emitting waveform samples — this
    is not a neural vocoder. `--dump-text` writes the verified text and skips
    synthesis.
  - Registered in the data-driven registry, so it appears in **`stools-ui`** as
    a form (input path, output path, voice, rate, fetch, model, dump-text) with
    no launcher changes.
  - Usage: `pdf2audiobook <input.pdf|input.txt> [output.wav] [flags]`.
- **Real neural Qwen3-TTS voice for `pdf2audiobook`.** When the native model
  artifacts are present in `./models` (`talker.sb0m` + `codec.sb0m` +
  `tokenizer.gguf`), the tool synthesizes with the genuine
  Qwen3-TTS-12Hz-0.6B pipeline — 28-layer Talker → 5-layer code predictor →
  split-RVQ + sliding transformer → causal ConvNeXt/SnakeBeta vocoder → 24 kHz
  PCM — instead of the built-in narrator. The whole decoder is the new pure-Sig
  `@zpm/tts` stack, extracted into zpm; `src/tts_neural.sig` is a thin driver
  that loads the artifacts and renders text sentence-by-sentence. Flags:
  `--neural` (force it), `--no-neural` (force the instant narrator),
  `--max-frames N` (bound the neural excerpt, 1 frame = 80 ms). Honest note: the
  decoder is exact but ~644x slower than realtime unaccelerated, so it renders a
  bounded excerpt while the built-in narrator reads the whole book.

### Changed
- **`pdf2audiobook` is now neural-only and GPU-accelerated.** The built-in
  source-filter narrator was removed — the tool synthesizes exclusively with the
  real neural Qwen3-TTS voice and requires the model artifacts in `./models`.
  When a CUDA device is present the matmul weights run on the GPU via cuBLAS
  (zpm `@zpm/tts-gpu`), with a clean CPU fallback. Output is peak-normalized so
  it is clearly audible, and leading prompt silence is trimmed.
- **Voice controls the model supports** are exposed on the CLI and in the
  `stools-ui` form: `--lang` (10 languages), `--temperature`, `--top-k`,
  `--rep-penalty`, `--think`/`--no-think`, and `--speaker` (honestly reported as
  needing a CustomVoice checkpoint — the Base model has no speaker table).
  `--max-frames` bounds a render; `--no-normalize` keeps the raw level.

### Fixed
- zpm `@zpm/pdf-render`: page detection missed the tight `/Type/Page` syntax and
  text extraction read the page object's (absent) stream instead of resolving
  `/Contents`. Both are fixed in zpm, so `pdf2audiobook` now extracts real text
  from more PDFs (e.g. Ghostscript/qpdf output); positioning operators
  (`Td`/`TD`/`Tm`) now insert word breaks so runs don't glue together.

### Fixed
- zpm `platform/cdp`: three `Page` methods (`evaluate`, `call`, `close`) still
  took an `io` parameter they no longer use after the WebSocket transport
  unification, which failed the build under Sig 0.6.0's unused-parameter check.
  The parameters are now explicitly discarded, keeping the call sites unchanged.

## [0.1.0] - 2026-09-15

### Added
- **`stools-ui`** — a translucent, dark-glass launcher GUI for the whole suite.
  It renders every command as a form (toggles, integer steppers, an RGB color
  picker, text/path fields, segmented choices), launches the selected tool via
  subprocess, and shows its output inline. Long-running commands (e.g. `slicker
  --watch`) spawn with a **Stop** control; one-shot commands run and capture
  output. The launcher is **data-driven** (`src/tool_schema.sig`): adding a new
  tool is one registry entry — the UI and the argv assembler (`src/launch.sig`)
  pick it up with no other changes. Built on the zpm windowing + GL + render
  (`materials`/`primitives`/`text`) stack, matching the SB0 house style.
- **Native application icon** across the window titlebar, taskbar, and every
  executable (Explorer/taskbar). A single `src/stools.ico` (generated from
  `logo.png` by `scripts/make-ico.ps1`, sizes 16..256 for Windows 11) is
  embedded natively: the in-app logo via `@embedFile`, and the exe icon via
  `src/stools.rc` compiled and linked by `sig build` — no post-build tooling.
  Requires Sig 0.6.0+ (`Compile_Options.win32_resource`).
- `img2elementor` now accepts a **URL** as input, not just a local image: it
  renders the live page to a PNG with a headless browser
  (Chrome/Edge/Chromium/Brave, auto-detected) and runs the reconstruction
  pipeline on it. The temp capture is cleaned up automatically. Powered by a new
  zpm Layer-1 module, `web_capture`, which drives the browser via zpm
  `subprocess`. A `--debug` flag dumps the detected regions for tuning.

### Fixed
- **`slicker` watch mode could wedge the graphics driver.** Each pass captured
  every window back-to-back and defaulted to a 500ms interval, hammering the
  GPU/DWM compositor — under load (e.g. alt+tab) this could hang the driver.
  Captures are now de-bursted with a small inter-window yield and the default
  `--interval-ms` is 1000. Pairs with the zpm WGC fix that caches one D3D11
  device across captures instead of recreating it every frame.
- **PNG decoder Paeth filter bug** (zpm `png_decode`): filter type 4 returned
  `paeth(a,b,c)` without adding the stored residual, corrupting every
  Paeth-filtered scanline whose predictor was zero (e.g. the first rows of a
  page rendered as black). This silently wrecked downstream image analysis.
  Added a regression test.
- `img2elementor` font-size estimation no longer reports absurd sizes (e.g.
  765px). Font size is now the clamped median of per-line ink heights rather
  than a mis-segmented region's full height (zpm `text_analyze`).

### Changed
- Much higher `img2elementor` reconstruction fidelity (zpm `image`, `layout`,
  `text_analyze`, `elementor` + the tool's widget mapping):
  - Two-level, gradient-aware segmentation splits a page into rows and then
    columns, so a hero's text column and its photo are separated instead of
    collapsing into one block.
  - New region kinds — heading, eyebrow, body_text — plus stroke-thickness
    weight detection and bounding-box alignment.
  - Widget mapping now emits a horizontal nav row and side-by-side hero columns
    (flex `row`/`column` containers), and merges consecutive similar-size text
    lines into single multi-line headings.
  - Elementor `document` builder gained flex direction, alignment, and width
    options on containers.

## [0.0.2] - 2026-09-11

### Added
- `slicker` is now a working end-to-end UI-automation engine with a real CLI
  (`stools slicker [flags]`): find a target across every open window and,
  opt-in, click it — once or continuously (`--watch`).
  - **Two detection modes**: by color region (`--sig R,G,B --multi`, best for
    solid-color buttons — only the button forms a large connected region of
    that color) and by image template (`--template FILE.png`, edge/shape
    chamfer matching robust to color/brightness).
  - **Continuous mode** (`--watch`, `--interval-ms`, `--passes`): re-scan and
    click all matches each pass — e.g. auto-approving a prompt that reappears.
  - Flags: `--sig`, `--tol`, `--min-area`, `--min-fill`, `--title`, `--multi`,
    `--max-regions`, `--template`, `--score`, `--click`, `--no-verify`,
    `--delay-ms`, `--label`, `--watch`, `--interval-ms`, `--passes`. Safety
    gate: never clicks without both `--click` and an explicit target.
- Windows: captures GPU-composited windows (VS Code, Kiro, Chrome) and occluded
  windows via **Windows Graphics Capture** (zpm `screencap` WGC backend),
  including DPI-scaled displays, where the previous GDI capture returned black.

### Fixed
- Windows clicks now actually land: corrected the `INPUT` struct size that made
  `SendInput` reject every synthetic click on x64 (zpm `win32`).

### Changed
- Depends on the zpm `ui_detect` multi-region / template / chamfer detectors and
  the `screencap` capture/click backends (pinned zpm revision).

### Added (earlier in this cycle)
- `img2elementor`: reconstruct an editable [Elementor](https://elementor.com)
  template from a screenshot (typically of a website). Pure-Sig pipeline —
  decode PNG, detect the page background, segment the layout into regions,
  estimate per-region typography (font size, weight, color, alignment), and
  emit a valid Elementor template JSON of containers, headings, text, buttons,
  and image blocks. Colors, sizes, and layout are reconstructed faithfully;
  exact glyph text is not recoverable from a flat raster, so text bodies are
  size-keyed placeholders for the operator to fill. Powered by new zpm Layer-0
  modules: `png_decode`, `image`, `layout`, `text_analyze`, `elementor_document`.
  Usage: `img2elementor <input.png> [output.json]`.
- `slicker`: a general, config-driven visual UI-automation engine. Enumerates
  all open windows, captures each, detects a configured color signature via the
  zpm `ui_detect` engine, and (opt-in) clicks the match and re-captures to
  verify. Ships with a benign detect-only default config; the default action is
  a full-window scan self-test (`stools` with no args). Depends on zpm's
  `screencap` and `ui_detect` modules via a path dependency.
- Cross-platform support: builds and runs on Windows, Linux, and macOS
  (x86_64 + aarch64), backed by zpm's per-OS `screencap` backends (Win32 /
  Xlib+XTest / CoreGraphics+CGEvent).
- SB0 native target: a bootable SB0K image (`scripts/build-sb0.sh`) that runs
  the slicker scan over the serial console. Capture is a no-op until the Nexus
  compositor exposes surface capture/enumerate/inject ops.
- CI: GitHub Actions workflows modeled on sls — `ci.yaml` (build, test,
  cross-compile all six hosted targets), `sb0.yaml` (build the SB0K image and
  boot it under QEMU), and `release.yaml` (package + checksum + publish all
  platforms on `v*` tags).
- `.gitattributes` for consistent LF line endings.

## [0.0.1] - 2026-09-01

### Added
- Initial project scaffold, generated with the `zpm init` `cli-app` starter.
- Pure-Sig, zero-dependency command dispatch in `src/main.sig`.
- Commands: `help`, `version`, `hash <text>` (FNV-1a 64-bit), and `now` (monotonic timestamp).
- Bounded `build.sig` build graph with `build`, `run`, and `test` steps.
- README, CHANGELOG, MIT LICENSE, and project logo.

[0.0.2]: https://github.com/SB0LTD/stools/releases/tag/v0.0.2
[0.0.1]: https://github.com/SB0LTD/stools/releases/tag/v0.0.1

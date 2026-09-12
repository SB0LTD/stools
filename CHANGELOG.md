# Changelog

All notable changes to **stools** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

# Changelog

All notable changes to **stools** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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

[0.0.1]: https://github.com/SB0LTD/stools/releases/tag/v0.0.1

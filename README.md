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

| Command          | Description                                    |
| ---------------- | ---------------------------------------------- |
| `help`           | Show usage                                     |
| `version`        | Print the suite version                        |
| `hash <text>`    | Print the FNV-1a 64-bit hash of the given text |
| `now`            | Print a monotonic timestamp (nanoseconds)      |

### Examples

```sh
stools version
stools hash "hello"
stools now
```

## Project layout

```
stools/
├─ build.sig        # pure-Sig bounded build graph
├─ build.sig.zon    # package manifest (name, version, deps)
├─ src/
│  └─ main.sig      # entry point + command dispatch
├─ CHANGELOG.md
├─ LICENSE
└─ logo.png
```

## Contributing

New tools slot into the `Command` enum and its dispatch in `src/main.sig`. Keep
each tool allocation-free and add a test alongside it. Run `sig build test`
before opening a PR.

## License

MIT © SB0. See [LICENSE](LICENSE).

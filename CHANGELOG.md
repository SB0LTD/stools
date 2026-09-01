# Changelog

All notable changes to **stools** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.1] - 2026-09-01

### Added
- Initial project scaffold, generated with the `zpm init` `cli-app` starter.
- Pure-Sig, zero-dependency command dispatch in `src/main.sig`.
- Commands: `help`, `version`, `hash <text>` (FNV-1a 64-bit), and `now` (monotonic timestamp).
- Bounded `build.sig` build graph with `build`, `run`, and `test` steps.
- README, CHANGELOG, MIT LICENSE, and project logo.

[0.0.1]: https://github.com/SB0LTD/stools/releases/tag/v0.0.1

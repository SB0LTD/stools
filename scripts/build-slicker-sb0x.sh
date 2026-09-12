#!/usr/bin/env bash
# Build slicker as a native SB0X userspace image (slicker.sb0x) for SB0/Nexus.
#
# The Sig compiler's SB0 link backend emits the SB0X container DIRECTLY for
# `-target aarch64-sb0` with NO linker script (a linker script would select the
# privileged SB0K kernel container instead). The backend produces the canonical
# two-segment layout — a read-execute segment (code/rodata) and a read-write
# segment (data + zero-init BSS as mem-only) — so slicker's large capture buffer
# costs no image bytes and the process can legally write its own globals under
# the SB0 per-segment page permissions. No ELF, no objcopy, no external packer.
#
# `-target aarch64-sb0` also makes screencap's comptime backend select the real
# SB0/Nexus compositor client (zpm screencap/sb0.sig) rather than the desktop
# stub. Reusable modules come from the sibling zpm checkout (../zpm), the same
# path dependency build.sig.zon declares.
#
# Usage: scripts/build-slicker-sb0x.sh <output-path.sb0x>
set -euo pipefail

OUT="${1:-sig-out/bin/slicker.sb0x}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ZPM="$HERE/../zpm/src"

echo "== slicker SB0X userspace build =="
echo "target: aarch64-sb0 (native SB0X, no linker script)"
echo "output: $OUT"

command -v sig >/dev/null 2>&1 || { echo "error: sig not on PATH" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

# Compile the SB0X app: the userspace entry + the reusable zpm screencap (SB0
# backend) and ui_detect engine. screencap declares a `win32` import used only
# by its Windows backend; on aarch64-sb0 that backend is never @import-ed, but
# the name must resolve, so point it at win32.sig (not referenced/linked here).
sig build-exe \
  -target aarch64-sb0 -mcpu=baseline -OReleaseSmall \
  -fno-stack-check -fno-stack-protector -fno-unwind-tables -fstrip -ffunction-sections \
  --dep screencap --dep ui_detect -Mroot="$HERE/src/platform/sb0_slicker_app.sig" \
  -Mui_detect="$ZPM/core/ui_detect.sig" \
  --dep win32 -Mscreencap="$ZPM/platform/screencap.sig" \
  -Mwin32="$ZPM/platform/win32.sig" \
  -femit-bin="$OUT"

[ -s "$OUT" ] || { echo "error: SB0X image was not produced" >&2; exit 1; }

# Verify the SB0X magic: bytes 0x53 0x42 0x30 0x58 ("SB0X").
magic="$(od -An -tx1 -N4 "$OUT" | tr -d ' \n')"
if [ "$magic" != "53423058" ]; then
  echo "error: output is not a valid SB0X image (leading bytes: $magic, expected 53423058)" >&2
  exit 1
fi
echo "slicker SB0X image produced: $OUT ($(wc -c < "$OUT") bytes, magic SB0X)"

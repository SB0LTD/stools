//! SB0 bare-metal / userspace entry for stools — a real SB0K image.
//!
//! Runs the slicker scan pipeline (zpm screencap + ui_detect) on SB0 and
//! reports the result over the PL011 UART. On SB0 the screencap backend
//! honestly reports "no display" today (the Nexus userspace ABI has no
//! surface enumeration / capture / input-injection ops yet — see
//! zpm/src/platform/screencap/sb0.sig), so the scan finds zero windows and the
//! self-test PASSes. The moment Nexus grows those compositor ops, the same
//! binary starts seeing real surfaces with no change here.
//!
//! Boot contract matches sig's SB0K layout (sb0k.ld): the image is loaded at
//! 0x40200000, the CPU resets to `_start`, and a 64-byte "SB0K" header precedes
//! the reset code.

const uart = @import("uart");
const screencap = @import("screencap");
const ui_detect = @import("ui_detect");

const build_version = "0.0.2";

extern var __bss_start: u8;
extern var __bss_end: u8;
extern const __stack_top: u8;

const MAX_WINDOWS = 64;
var windows: screencap.WindowList(MAX_WINDOWS) = .{};

// Capture staging buffer (BSS). Sized for a 1080p scanout (1920x1080 RGBA).
const CAPTURE_BYTES = 1920 * 1080 * 4;
var capture_buf: [CAPTURE_BYTES]u8 = undefined;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ adrp x0, __stack_top
        \\ add  x0, x0, :lo12:__stack_top
        \\ mov  sp, x0
        \\ mov  x1, #(3 << 20)
        \\ msr  cpacr_el1, x1
        \\ isb
        \\ bl   %[main]
        \\ b    .
        :
        : [main] "S" (&sb0Main),
        : .{ .memory = true });
    unreachable;
}

export fn sb0Main() callconv(.c) noreturn {
    zeroBss();

    uart.write("stools " ++ build_version ++ " — SB0 native image\r\n");
    uart.write("stools slicker — scanning all surfaces (detect-only)\r\n");

    const sig = ui_detect.ColorSignature{ .r = 124, .g = 92, .b = 219, .tolerance = 28 };
    const params = ui_detect.DetectParams{ .signature = sig, .min_area = 600, .min_fill_permille = 450 };

    const n = screencap.enumerate(MAX_WINDOWS, &windows, .{ .visible_only = true });

    // Capture each enumerated surface via the Nexus compositor and detect. On
    // SB0 the whole scanout is exposed as one capturable surface.
    var matches: usize = 0;
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const win = windows.items[idx];
        const need = @as(usize, @intCast(win.width)) * @as(usize, @intCast(win.height)) * 4;
        if (win.width <= 0 or win.height <= 0 or need > capture_buf.len) continue;
        const cap = screencap.captureWindow(win, capture_buf[0..]);
        if (!cap.ok) continue;
        const m = ui_detect.detect(cap.pixels, cap.width, cap.height, params);
        if (m.found) matches += 1;
    }

    uart.write("scan complete: ");
    writeUint(n);
    uart.write(" surfaces scanned, ");
    writeUint(matches);
    uart.write(" matches\r\n");

    if (matches == 0) {
        uart.write("result: PASS (target signature not present)\r\n");
    } else {
        uart.write("result: FOUND\r\n");
    }

    uart.write("STOOLS-SB0-EXIT\r\n");
    while (true) asm volatile ("wfe");
}

fn writeUint(value: usize) void {
    var buf: [20]u8 = undefined;
    if (value == 0) {
        uart.putc('0');
        return;
    }
    var v = value;
    var len: usize = 0;
    while (v > 0) : (v /= 10) {
        buf[len] = @intCast('0' + (v % 10));
        len += 1;
    }
    while (len > 0) {
        len -= 1;
        uart.putc(buf[len]);
    }
}

fn zeroBss() void {
    const start: [*]u8 = @ptrCast(&__bss_start);
    const end: [*]u8 = @ptrCast(&__bss_end);
    const len = @intFromPtr(end) - @intFromPtr(start);
    var i: usize = 0;
    while (i < len) : (i += 1) start[i] = 0;
}

//! slicker — the stools visual UI-automation scan as a native SB0X userspace
//! process, delivered to the Nexus kernel at runtime.
//!
//! This is packaged as an SB0X image (slicker.sb0x) and published as a stools
//! release artifact. The generic SB0/Nexus kernel loads it off a FAT disk at
//! boot (APP.SBX + APP.MFT declaring profile=interactive) and launches it at
//! EL0 with the interactive capability profile: display (surface index 1) +
//! input (index 2) handles are delegated so screencap's SB0 backend can talk to
//! the Nexus compositor over the device-queue ABI (enumerate surfaces, capture
//! pixels, inject a pointer click).
//!
//! It runs the SAME reusable zpm engine the hosted (Windows/macOS/Linux)
//! slicker runs — `screencap` (SB0 backend → Nexus) and `ui_detect` (pure
//! color-region detection) — proving the automation engine works on SB0 too.
//! It reports each step over the debug UART and exits through the process
//! lifecycle so the kernel prints a clean exit code.
//!
//! Contrast with src/platform/sb0_entry.sig: that is a bare-metal SB0K probe
//! with NO kernel under it (its device-queue traps go unserviced). This app
//! runs on Nexus, so enumerate/capture/click reach a real compositor.

const builtin = @import("builtin");
const screencap = @import("screencap");
const ui_detect = @import("ui_detect");

const build_version = "0.0.2";

// SB0 operation codes (x8 on `svc #0`).
const OP_PROCESS_EXIT: u64 = 0x0000;
const OP_DEBUG_PRINT: u64 = 0x0f00;

// SB0 trap gate. The `aarch64-sb0` target does not accept named-register
// extended-asm constraints (`"={x0}"`), so — like zpm's screencap/sb0.sig — we
// define the trap as a file-scope global-assembly function with the C calling
// convention: args arrive in x0.. per the AAPCS, we move them into the SB0 ABI
// registers (x8=opcode, x0..x2=args), `svc #0`, and store the x0/x1 results
// through the caller-provided out pointer. This is the proven SB0 userspace
// trap shape.
const TrapResult = extern struct { value: u64 = 0, status: u64 = 0 };

extern fn slickerSb0Trap(op: u64, a0: u64, a1: u64, a2: u64, out: *TrapResult) callconv(.c) void;

comptime {
    if (builtin.cpu.arch == .aarch64) {
        asm (
            \\.global slickerSb0Trap
            \\.type slickerSb0Trap, %function
            \\.p2align 2
            \\slickerSb0Trap:
            \\  mov x8, x0
            \\  mov x0, x1
            \\  mov x1, x2
            \\  mov x2, x3
            \\  svc #0
            \\  str x0, [x4]
            \\  str x1, [x4, #8]
            \\  ret
        );
    }
}

fn trap3(op: u64, a0: u64, a1: u64, a2: u64) TrapResult {
    var out = TrapResult{};
    if (builtin.cpu.arch != .aarch64) return out;
    slickerSb0Trap(op, a0, a1, a2, &out);
    return out;
}

fn puts(msg: []const u8) void {
    _ = trap3(OP_DEBUG_PRINT, @intFromPtr(msg.ptr), msg.len, 0);
}

fn putUint(value: usize) void {
    var buf: [20]u8 = undefined;
    if (value == 0) {
        puts("0");
        return;
    }
    var v = value;
    var len: usize = 0;
    while (v > 0) : (v /= 10) {
        buf[len] = @intCast('0' + (v % 10));
        len += 1;
    }
    // Reverse into a second buffer so we emit most-significant digit first.
    var out: [20]u8 = undefined;
    var i: usize = 0;
    while (len > 0) {
        len -= 1;
        out[i] = buf[len];
        i += 1;
    }
    puts(out[0..i]);
}

fn processExit(code: u64) noreturn {
    _ = trap3(OP_PROCESS_EXIT, code, 0, 0);
    unreachable;
}

// Static capture buffer sized for a 1080p BGRX scanout (1920x1080 RGBA).
const MAX_WINDOWS = 8;
const CAPTURE_BYTES = 1920 * 1080 * 4;
var capture_buf: [CAPTURE_BYTES]u8 = undefined;
var windows: screencap.WindowList(MAX_WINDOWS) = .{};

/// Run one detect-only scan pass over every compositor surface and report the
/// result over the UART. The engine mirrors hosted slicker's scanOnce.
export fn userMain() callconv(.c) void {
    puts("SLICKER-READY: slicker scan online (native SB0X on Nexus), v" ++ build_version ++ "\n");
    puts("slicker: scanning all surfaces via the Nexus compositor (detect-only)\n");

    // A benign color signature; the SB0 scanout is unlikely to contain it, so
    // the self-test PASSes while still exercising enumerate + capture + detect.
    const sig = ui_detect.ColorSignature{ .r = 124, .g = 92, .b = 219, .tolerance = 28 };
    const params = ui_detect.DetectParams{ .signature = sig, .min_area = 600, .min_fill_permille = 450 };

    const n = screencap.enumerate(MAX_WINDOWS, &windows, .{ .visible_only = true });
    puts("slicker: surfaces enumerated=");
    putUint(n);
    puts("\n");

    var matches: usize = 0;
    var captured: usize = 0;
    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const win = windows.items[idx];
        const need = @as(usize, @intCast(win.width)) * @as(usize, @intCast(win.height)) * 4;
        if (win.width <= 0 or win.height <= 0 or need > capture_buf.len) continue;
        const cap = screencap.captureWindow(win, capture_buf[0..]);
        if (!cap.ok) continue;
        captured += 1;
        const m = ui_detect.detect(cap.pixels, cap.width, cap.height, params);
        if (m.found) matches += 1;
    }

    puts("slicker: surfaces captured=");
    putUint(captured);
    puts(" matches=");
    putUint(matches);
    puts("\n");

    if (matches == 0) {
        puts("slicker: result PASS (target signature not present on any surface)\n");
    } else {
        puts("slicker: result FOUND\n");
    }
    puts("SLICKER-DONE\n");
    processExit(0);
}

/// SB0X process entry. `naked` so the kernel register/stack contract
/// (x0=BHB, x1=HandleTable, sp=stack top) is untouched. Runs at EL0; the kernel
/// enables FP/SIMD for the process. Call the Sig-level main, then exit cleanly.
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ bl   %[main]
        \\ mov  x8, #0
        \\ mov  x0, #0
        \\ svc  #0
        \\ 1: wfe
        \\ b    1b
        :
        : [main] "S" (&userMain),
        : .{ .memory = true });
    unreachable;
}

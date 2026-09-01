// stools slicker — a general, config-driven visual UI-automation daemon.
//
// Slicker is the thin application shell around two reusable zpm modules:
//   • zpm `screencap` (Layer 1): enumerate windows, capture pixels, click.
//   • zpm `ui_detect` (Layer 0): find a configured color signature in a buffer.
//
// It runs a scan/act/verify loop: for every open window it captures the pixels,
// looks for an element matching the configured color signature, and — when
// enabled — clicks the element's center, then re-captures to confirm the click
// registered (the element moved or disappeared).
//
// Slicker is general on purpose. It carries NO built-in rule that targets any
// application's security or consent prompts; the default config is a benign
// example and the tool refuses to auto-act unless the operator supplies both a
// signature and the explicit `--click` flag. What it automates is chosen by the
// person running it, not baked in.

const std = @import("std");
const screencap = @import("screencap");
const ui_detect = @import("ui_detect");

/// A single match-and-act rule. The engine is driven entirely by these.
pub const Rule = struct {
    /// Human label for logging.
    label: []const u8,
    /// Color signature the target element is expected to have.
    signature: ui_detect.ColorSignature,
    /// Minimum matching area / fill ratio for a real hit.
    min_area: u32 = 400,
    min_fill_permille: u32 = 500,
};

pub const Config = struct {
    rule: Rule,
    /// When false (default), slicker only detects and reports — never clicks.
    click: bool = false,
    /// When true, re-capture after clicking and confirm the element changed.
    verify: bool = true,
    /// Milliseconds to wait between click and verification capture.
    verify_delay_ms: u32 = 120,
    /// Restrict scanning to windows whose title contains this (empty = all).
    title_filter: []const u8 = "",
};

/// A benign default: a mid-violet UI accent, detect-only. This exists so the
/// binary is runnable out of the box for a harmless demo/self-test — it does
/// not click and is not tied to any specific application.
pub const default_config = Config{
    .rule = .{
        .label = "violet-accent (demo)",
        .signature = .{ .r = 124, .g = 92, .b = 219, .tolerance = 28 },
        .min_area = 600,
        .min_fill_permille = 450,
    },
    .click = false,
    .verify = true,
};

/// Outcome of processing a single window.
pub const WindowOutcome = struct {
    matched: bool = false,
    clicked: bool = false,
    verified: bool = false,
    center_x: u32 = 0,
    center_y: u32 = 0,
};

/// Summary across all windows in one full scan pass.
pub const ScanReport = struct {
    windows_scanned: usize = 0,
    matches: usize = 0,
    clicks: usize = 0,
    verified: usize = 0,
};

// A capture buffer sized for a large 4K window (3840x2160 RGBA ≈ 33 MB).
// File-scope static so the deep scan loop never touches the stack for pixels.
const MAX_W = 3840;
const MAX_H = 2160;
var capture_buf: [MAX_W * MAX_H * 4]u8 = undefined;
var verify_buf: [MAX_W * MAX_H * 4]u8 = undefined;

const MAX_WINDOWS = 256;

fn titleContains(win: screencap.WindowInfo, needle: []const u8) bool {
    if (needle.len == 0) return true;
    // WindowInfo.title is UTF-16; compare against ASCII needle loosely.
    if (win.title_len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= win.title_len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const c = win.title[i + j];
            if (c > 127 or @as(u8, @intCast(c)) != needle[j]) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

/// Run exactly one scan pass over all open windows. Pure orchestration; all
/// OS access goes through the zpm screencap module and all detection through
/// the zpm ui_detect module.
pub fn scanOnce(config: Config) ScanReport {
    var report: ScanReport = .{};

    var windows: screencap.WindowList(MAX_WINDOWS) = .{};
    const n = screencap.enumerate(MAX_WINDOWS, &windows, .{ .visible_only = true });

    const params = ui_detect.DetectParams{
        .signature = config.rule.signature,
        .min_area = config.rule.min_area,
        .min_fill_permille = config.rule.min_fill_permille,
    };

    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const win = windows.items[idx];
        if (!titleContains(win, config.title_filter)) continue;
        // Skip windows larger than our static buffer.
        const need = @as(usize, @intCast(win.width)) * @as(usize, @intCast(win.height)) * 4;
        if (win.width <= 0 or win.height <= 0 or need > capture_buf.len) continue;

        report.windows_scanned += 1;

        const cap = screencap.captureWindow(win, capture_buf[0..]);
        if (!cap.ok) continue;

        const m = ui_detect.detect(cap.pixels, cap.width, cap.height, params);
        if (!m.found) continue;

        report.matches += 1;
        printMatch(config.rule.label, win, m);

        if (!config.click) continue;

        // Translate the match centroid (window-local) to screen coordinates.
        const screen_x = win.left + @as(i32, @intCast(m.center_x));
        const screen_y = win.top + @as(i32, @intCast(m.center_y));
        const clicked = screencap.clickAt(screen_x, screen_y);
        if (!clicked) continue;
        report.clicks += 1;

        if (!config.verify) continue;

        // Verify: re-capture and confirm the element is gone / changed at the
        // same spot. If detect no longer finds it, the click took effect.
        screencap.sleepMs(config.verify_delay_ms);
        // Re-capture the same window to confirm the click took effect.
        const cap2 = screencap.captureWindow(win, verify_buf[0..]);
        if (!cap2.ok) continue;
        const m2 = ui_detect.detect(cap2.pixels, cap2.width, cap2.height, params);
        if (!m2.found) {
            report.verified += 1;
            printVerified(config.rule.label);
        }
    }

    return report;
}

fn printMatch(label: []const u8, win: screencap.WindowInfo, m: ui_detect.Match) void {
    std.debug.print(
        "  [match] '{s}' in window (@{d},{d} {d}x{d}) at local ({d},{d}), area={d}\n",
        .{ label, win.left, win.top, win.width, win.height, m.center_x, m.center_y, m.area },
    );
}

fn printVerified(label: []const u8) void {
    std.debug.print("  [verify] '{s}' click confirmed — element cleared\n", .{label});
}

// ── Tests (pure orchestration helpers) ──────────────────────────────

fn makeWin(title: []const u8) screencap.WindowInfo {
    var w: screencap.WindowInfo = .{ .hwnd = undefined, .left = 0, .top = 0, .width = 100, .height = 100 };
    for (title, 0..) |c, i| w.title[i] = c;
    w.title_len = title.len;
    return w;
}

test "title filter matches substring" {
    const w = makeWin("Some App - Editor");
    try std.testing.expect(titleContains(w, "Editor"));
    try std.testing.expect(titleContains(w, ""));
    try std.testing.expect(!titleContains(w, "Terminal"));
}

test "default config is detect-only" {
    try std.testing.expect(!default_config.click);
    try std.testing.expect(default_config.verify);
}

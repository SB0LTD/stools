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

/// How slicker decides what a "match" is within a captured window.
pub const Mode = enum {
    /// Merge all pixels matching the color signature into one region (the
    /// original behavior). One target per window.
    color,
    /// Separate the matching pixels into distinct connected regions and act on
    /// each independently. Use when the same signature appears more than once.
    color_multi,
    /// Slide a small grayscale template over the window and match by normalized
    /// cross-correlation. Robust to brightness/contrast shifts.
    template,
};

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
    /// Detection strategy. Defaults to the original single-region color scan.
    mode: Mode = .color,
    /// When false (default), slicker only detects and reports — never clicks.
    click: bool = false,
    /// When true, re-capture after clicking and confirm the element changed.
    verify: bool = true,
    /// Milliseconds to wait between click and verification capture.
    verify_delay_ms: u32 = 120,
    /// Restrict scanning to windows whose title contains this (empty = all).
    title_filter: []const u8 = "",
    /// Edge template used when `mode == .template`. Chamfer shape matching —
    /// robust to fill color/brightness, discriminative on the button's outline
    /// + glyph edges (unlike NCC, which saturates on flat-fill buttons).
    edge_template: ?ui_detect.EdgeTemplate = null,
    /// Sobel edge threshold for the window edge map (matches how the template
    /// edges were extracted).
    edge_threshold: u32 = 200,
    /// Minimum shape-match confidence (per-mille, 0..1000) for a hit.
    template_min_permille: i32 = 700,
    /// In color_multi mode, cap on regions acted on per window.
    max_regions: usize = 16,
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

// Multi-region scratch: ui_detect.detectAll needs 2 u32 per pixel (visited map
// + DFS stack). File-scope static so the scan loop never heap-allocates.
var detect_scratch: [2 * MAX_W * MAX_H]u32 = undefined;
// Output regions for one window in color_multi mode.
const MAX_REGIONS = 64;
var region_out: [MAX_REGIONS]ui_detect.Match = undefined;

// Chamfer-match scratch: ui_detect.matchEdgeTemplateAll needs an edge map + a
// distance-transform buffer, one u16 per pixel each. Sized for the max window.
var chamfer_scratch: [2 * MAX_W * MAX_H]u16 = undefined;
// Output locations for one window in template mode (all matching buttons).
const MAX_TEMPLATE_HITS = 64;
var template_out: [MAX_TEMPLATE_HITS]ui_detect.TemplateMatch = undefined;

const MAX_WINDOWS = 256;

// Small yield between per-window captures within a single pass. Spreads the
// GPU/DWM capture work out so a pass is not one tight burst — keeps slicker
// unobtrusive and avoids piling capture sessions onto heavy compositor events.
const INTER_WINDOW_YIELD_MS: u32 = 15;

fn titleContains(win: screencap.WindowInfo, needle: []const u8) bool {
    if (needle.len == 0) return true;
    const title = win.title[0..win.title_len]; // UTF-8
    if (title.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= title.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (title[i + j] != needle[j]) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

/// Run exactly one scan pass over all open windows. Pure orchestration; all
/// OS access goes through the zpm screencap module and all detection through
/// the zpm ui_detect module. Dispatches per `config.mode`.
pub fn scanOnce(config: Config) ScanReport {
    var report: ScanReport = .{};

    var windows: screencap.WindowList(MAX_WINDOWS) = .{};
    const n = screencap.enumerate(MAX_WINDOWS, &windows, .{ .visible_only = true });

    var idx: usize = 0;
    while (idx < n) : (idx += 1) {
        const win = windows.items[idx];
        if (!titleContains(win, config.title_filter)) continue;
        // Skip windows larger than our static buffer.
        const need = @as(usize, @intCast(win.width)) * @as(usize, @intCast(win.height)) * 4;
        if (win.width <= 0 or win.height <= 0 or need > capture_buf.len) continue;

        // De-burst: yield briefly before each capture so a pass spreads its
        // GPU/DWM work out instead of firing N back-to-back capture sessions.
        // This keeps slicker unobtrusive and avoids colliding a tight burst
        // with heavy compositor events (e.g. alt+tab). Skip the yield before
        // the very first captured window.
        if (report.windows_scanned > 0) screencap.sleepMs(INTER_WINDOW_YIELD_MS);

        report.windows_scanned += 1;

        const cap = screencap.captureWindow(win, capture_buf[0..]);
        if (!cap.ok) continue;

        switch (config.mode) {
            .color => scanColor(config, win, cap, &report),
            .color_multi => scanColorMulti(config, win, cap, &report),
            .template => scanTemplate(config, win, cap, &report),
        }
    }

    return report;
}

/// Run scan passes continuously: scan every window, click all matches, wait
/// `interval_ms`, repeat. Runs `max_passes` times, or forever when it is 0
/// (stop with Ctrl-C / by killing the process). Returns the accumulated totals
/// across every pass. This is the "watch and keep clicking" mode.
pub fn scanLoop(config: Config, max_passes: usize, interval_ms: u32) ScanReport {
    var total: ScanReport = .{};
    var pass: usize = 0;
    while (max_passes == 0 or pass < max_passes) : (pass += 1) {
        printPassHeader(pass + 1);
        const r = scanOnce(config);
        total.windows_scanned += r.windows_scanned;
        total.matches += r.matches;
        total.clicks += r.clicks;
        total.verified += r.verified;
        printPassSummary(pass + 1, r);
        // Sleep between passes (skip the wait after the final bounded pass).
        if (max_passes == 0 or pass + 1 < max_passes) screencap.sleepMs(interval_ms);
    }
    return total;
}

fn detectParams(config: Config) ui_detect.DetectParams {
    return .{
        .signature = config.rule.signature,
        .min_area = config.rule.min_area,
        .min_fill_permille = config.rule.min_fill_permille,
    };
}

/// Single-region color scan (the original behavior): find one blob, optionally
/// click its centroid, optionally verify it cleared.
fn scanColor(config: Config, win: screencap.WindowInfo, cap: screencap.Capture, report: *ScanReport) void {
    const params = detectParams(config);
    const m = ui_detect.detect(cap.pixels, cap.width, cap.height, params);
    if (!m.found) return;

    report.matches += 1;
    printMatch(config.rule.label, win, m);

    if (!config.click) return;
    if (!clickCentroid(win, cap, m.center_x, m.center_y)) return;
    report.clicks += 1;

    if (!config.verify) return;
    screencap.sleepMs(config.verify_delay_ms);
    const cap2 = screencap.captureWindow(win, verify_buf[0..]);
    if (!cap2.ok) return;
    const m2 = ui_detect.detect(cap2.pixels, cap2.width, cap2.height, params);
    if (!m2.found) {
        report.verified += 1;
        printVerified(config.rule.label);
    }
}

/// Multi-region color scan: separate the signature into distinct regions and
/// act on each (up to config.max_regions). Verification re-scans and confirms
/// the total qualifying-region count dropped.
fn scanColorMulti(config: Config, win: screencap.WindowInfo, cap: screencap.Capture, report: *ScanReport) void {
    const params = detectParams(config);
    const need = ui_detect.scratchLen(cap.width, cap.height);
    if (need > detect_scratch.len) return; // window too large for scratch

    const found = ui_detect.detectAll(cap.pixels, cap.width, cap.height, params, detect_scratch[0..], region_out[0..]);
    if (found == 0) return;

    const limit = @min(found, @min(config.max_regions, region_out.len));
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const m = region_out[i];
        report.matches += 1;
        printMatch(config.rule.label, win, m);

        if (!config.click) continue;
        if (!clickCentroid(win, cap, m.center_x, m.center_y)) continue;
        report.clicks += 1;
    }

    if (!config.click or !config.verify) return;
    // Verify: after clicking every region, re-scan; fewer qualifying regions
    // means the clicks took effect. Count the reduction as verified hits.
    screencap.sleepMs(config.verify_delay_ms);
    const cap2 = screencap.captureWindow(win, verify_buf[0..]);
    if (!cap2.ok) return;
    const after = ui_detect.detectAll(cap2.pixels, cap2.width, cap2.height, params, detect_scratch[0..], region_out[0..]);
    if (after < found) {
        const cleared = found - after;
        report.verified += cleared;
        printVerifiedCount(config.rule.label, cleared);
    }
}

/// Template scan: edge-based CHAMFER shape matching. Finds every window
/// location whose shape matches the template's outline+glyph edges — robust to
/// fill color/brightness and discriminative where NCC saturates (flat-fill
/// buttons). Acts on all matches, optionally clicks each, then verifies fewer
/// remain.
fn scanTemplate(config: Config, win: screencap.WindowInfo, cap: screencap.Capture, report: *ScanReport) void {
    const tpl = config.edge_template orelse return;
    const need = ui_detect.chamferScratchLen(cap.width, cap.height);
    if (need > chamfer_scratch.len) return; // window too large for scratch

    const found = ui_detect.matchEdgeTemplateAll(
        cap.pixels,
        cap.width,
        cap.height,
        tpl,
        config.edge_threshold,
        config.template_min_permille,
        chamfer_scratch[0..],
        template_out[0..],
    );
    if (found == 0) return;

    const limit = @min(found, @min(config.max_regions, template_out.len));
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const tm = template_out[i];
        report.matches += 1;
        printTemplateMatch(config.rule.label, win, tm);

        if (!config.click) continue;
        if (!clickCentroid(win, cap, tm.center_x, tm.center_y)) continue;
        report.clicks += 1;
    }

    if (!config.click or !config.verify) return;
    // Verify: after clicking, re-scan; fewer matches means the clicks landed.
    screencap.sleepMs(config.verify_delay_ms);
    const cap2 = screencap.captureWindow(win, verify_buf[0..]);
    if (!cap2.ok) return;
    const after = ui_detect.matchEdgeTemplateAll(
        cap2.pixels,
        cap2.width,
        cap2.height,
        tpl,
        config.edge_threshold,
        config.template_min_permille,
        chamfer_scratch[0..],
        template_out[0..],
    );
    if (after < found) {
        const cleared = found - after;
        report.verified += cleared;
        printVerifiedCount(config.rule.label, cleared);
    }
}

/// Translate a window-local centroid to screen coordinates and click it.
/// Translate a capture-local centroid to absolute screen coordinates and click.
/// Detection runs on the captured pixels, which on DPI-scaled displays are
/// PHYSICAL pixels (cap.width/height) larger than the window's logical rect
/// (win.width/height). Scale the centroid from capture space back to logical
/// window space before offsetting by the window's logical origin.
fn clickCentroid(win: screencap.WindowInfo, cap: screencap.Capture, cx: u32, cy: u32) bool {
    const logical_x: i64 = if (cap.width > 0)
        @divTrunc(@as(i64, cx) * @as(i64, win.width), @as(i64, @intCast(cap.width)))
    else
        @intCast(cx);
    const logical_y: i64 = if (cap.height > 0)
        @divTrunc(@as(i64, cy) * @as(i64, win.height), @as(i64, @intCast(cap.height)))
    else
        @intCast(cy);
    const screen_x = win.left + @as(i32, @intCast(logical_x));
    const screen_y = win.top + @as(i32, @intCast(logical_y));
    return screencap.clickAt(screen_x, screen_y);
}

fn printMatch(label: []const u8, win: screencap.WindowInfo, m: ui_detect.Match) void {
    std.debug.print(
        "  [match] '{s}' in window (@{d},{d} {d}x{d}) at local ({d},{d}), area={d}\n",
        .{ label, win.left, win.top, win.width, win.height, m.center_x, m.center_y, m.area },
    );
}

fn printTemplateMatch(label: []const u8, win: screencap.WindowInfo, tm: ui_detect.TemplateMatch) void {
    std.debug.print(
        "  [match] '{s}' (template) in window (@{d},{d} {d}x{d}) at local ({d},{d}), score={d}\u{2030}\n",
        .{ label, win.left, win.top, win.width, win.height, tm.x, tm.y, tm.score_permille },
    );
}

fn printVerified(label: []const u8) void {
    std.debug.print("  [verify] '{s}' click confirmed — element cleared\n", .{label});
}

fn printVerifiedCount(label: []const u8, cleared: usize) void {
    std.debug.print("  [verify] '{s}' clicks confirmed — {d} region(s) cleared\n", .{ label, cleared });
}

fn printPassHeader(pass: usize) void {
    std.debug.print("── pass {d} ──\n", .{pass});
}

fn printPassSummary(pass: usize, r: ScanReport) void {
    std.debug.print(
        "pass {d}: {d} windows, {d} matches, {d} clicks, {d} verified\n",
        .{ pass, r.windows_scanned, r.matches, r.clicks, r.verified },
    );
}

// ── Tests (pure orchestration helpers) ──────────────────────────────

fn makeWin(title: []const u8) screencap.WindowInfo {
    var w: screencap.WindowInfo = .{ .handle = 0, .left = 0, .top = 0, .width = 100, .height = 100 };
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

test "default mode is single-region color" {
    try std.testing.expectEqual(Mode.color, default_config.mode);
    try std.testing.expect(default_config.template == null);
}

test "detectParams mirrors the rule thresholds" {
    const cfg = Config{ .rule = .{
        .label = "x",
        .signature = .{ .r = 1, .g = 2, .b = 3, .tolerance = 4 },
        .min_area = 123,
        .min_fill_permille = 456,
    } };
    const p = detectParams(cfg);
    try std.testing.expectEqual(@as(u32, 123), p.min_area);
    try std.testing.expectEqual(@as(u32, 456), p.min_fill_permille);
    try std.testing.expectEqual(@as(u8, 4), p.signature.tolerance);
}

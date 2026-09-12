// stools — the SB0 tools suite.
//
// A native command-line entry point that dispatches to the individual tools in
// the suite. The first tool is `slicker`, a config-driven visual UI-automation
// engine (see src/slicker.sig).

const std = @import("std");
const slicker = @import("slicker.sig");
const ui_detect = @import("ui_detect");
const png_decode = @import("png_decode");

// ── Template loading buffers (no heap). Sized for a modest template image:
// a button screenshot is small (a few hundred px per side). 512x512 is a
// generous cap. png_decode needs a scratch (IDAT), a raw (filtered scanlines),
// and an RGBA out buffer; we then reduce RGBA -> one grayscale byte per pixel.
const TPL_MAX_W = 512;
const TPL_MAX_H = 512;
const TPL_MAX_PX = TPL_MAX_W * TPL_MAX_H;
var tpl_file_buf: [4 * 1024 * 1024]u8 = undefined; // raw PNG file bytes
var tpl_scratch: [TPL_MAX_PX * 4]u8 = undefined; // concatenated IDAT
var tpl_raw: [TPL_MAX_PX * 5]u8 = undefined; // inflated filtered scanlines
var tpl_rgba: [TPL_MAX_PX * 4]u8 = undefined; // decoded RGBA8
// Edge points extracted from the template for chamfer shape matching. A button
// outline + glyph edges are a small fraction of the pixels; cap generously.
var tpl_edge_points: [TPL_MAX_PX]ui_detect.EdgePoint = undefined;
const TEMPLATE_EDGE_THRESHOLD: u32 = 200;

pub const version = "0.0.2";

/// Every top-level command understood by the suite.
pub const Command = enum {
    help,
    version,
    slicker,
    // ── Misc small tools ──
    hash,
    now,
    unknown,

    pub fn parse(value: []const u8) Command {
        if (std.mem.eql(u8, value, "help")) return .help;
        if (std.mem.eql(u8, value, "-h")) return .help;
        if (std.mem.eql(u8, value, "--help")) return .help;
        if (std.mem.eql(u8, value, "version")) return .version;
        if (std.mem.eql(u8, value, "-V")) return .version;
        if (std.mem.eql(u8, value, "--version")) return .version;
        if (std.mem.eql(u8, value, "slicker")) return .slicker;
        if (std.mem.eql(u8, value, "hash")) return .hash;
        if (std.mem.eql(u8, value, "now")) return .now;
        return .unknown;
    }
};

/// FNV-1a 64-bit — small, allocation-free hash used by the `hash` tool.
pub fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn printUsage() void {
    std.debug.print(
        \\stools — the SB0 tools suite (v{s})
        \\
        \\Usage: stools <command> [args]
        \\
        \\Commands:
        \\  help              Show this help
        \\  version           Print the suite version
        \\  slicker [flags]   Visual UI-automation engine (scans all windows)
        \\  hash <text>       Print the FNV-1a hash of the given text
        \\  now               Print a monotonic timestamp (nanoseconds)
        \\
        \\slicker flags (default: one detect-only single-region color scan):
        \\  --template FILE.png Match this button/icon image across all windows
        \\  --score N           Min template match score, per-mille (default 700)
        \\  --sig R,G,B         Target color signature (0..255 each)
        \\  --tol N             Per-channel color tolerance (default 28)
        \\  --min-area N        Minimum matching pixels for a hit (default 600)
        \\  --min-fill N        Minimum fill per-mille of the bbox (default 450)
        \\  --title SUBSTR      Only scan windows whose title contains SUBSTR
        \\  --multi             Detect every distinct region, not just one
        \\  --max-regions N     Cap regions acted on per window (default 16)
        \\  --click             Actually click matches (opt-in; off by default)
        \\  --no-verify         Skip the post-click re-capture confirmation
        \\  --delay-ms N        Wait between click and verify (default 120)
        \\  --label TEXT        Human label used in match logs
        \\  --watch             Scan continuously, clicking all matches each pass
        \\  --interval-ms N     Delay between watch passes (default 500)
        \\  --passes N          Run N passes then stop (implies --watch)
        \\
        \\Examples:
        \\  stools slicker --template ok-button.png            (one detect scan)
        \\  stools slicker --template ok-button.png --click     (find & click once)
        \\  stools slicker --template ok.png --click --watch    (keep clicking it)
        \\  stools slicker --sig 40,120,215 --click --watch     (click by color, loop)
        \\
        \\slicker refuses to click unless you pass --click AND a target (--sig or
        \\--template). It has no built-in rule targeting any application's
        \\security or consent prompts.
        \\
    , .{version});
}

/// Run one scan across all windows using `config` and report the outcome.
fn runSlickerScan(config: slicker.Config) void {
    const mode_name: []const u8 = switch (config.mode) {
        .color => "single-region color",
        .color_multi => "multi-region color",
        .template => "template",
    };
    std.debug.print(
        "stools slicker — scanning all windows ({s}, {s})\n",
        .{ mode_name, if (config.click) "click enabled" else "detect-only" },
    );
    const report = slicker.scanOnce(config);
    std.debug.print(
        "scan complete: {d} windows scanned, {d} matches, {d} clicks, {d} verified\n",
        .{ report.windows_scanned, report.matches, report.clicks, report.verified },
    );
    if (report.matches == 0) {
        std.debug.print("result: PASS (target signature not present in any window)\n", .{});
    } else {
        std.debug.print("result: FOUND ({d} match(es) reported above)\n", .{report.matches});
    }
}

/// Continuous watch mode: scan and click all matches every `interval_ms`, over
/// and over. Runs `passes` times, or until stopped (Ctrl-C) when passes is 0.
fn runSlickerWatch(run: SlickerRun) void {
    const mode_name: []const u8 = switch (run.config.mode) {
        .color => "single-region color",
        .color_multi => "multi-region color",
        .template => "template",
    };
    if (run.passes == 0) {
        std.debug.print(
            "stools slicker — watching all windows ({s}, {s}) every {d}ms; Ctrl-C to stop\n",
            .{ mode_name, if (run.config.click) "click enabled" else "detect-only", run.interval_ms },
        );
    } else {
        std.debug.print(
            "stools slicker — watching all windows ({s}, {s}) for {d} passes every {d}ms\n",
            .{ mode_name, if (run.config.click) "click enabled" else "detect-only", run.passes, run.interval_ms },
        );
    }
    const total = slicker.scanLoop(run.config, run.passes, run.interval_ms);
    std.debug.print(
        "watch complete: {d} total matches, {d} total clicks, {d} total verified across passes\n",
        .{ total.matches, total.clicks, total.verified },
    );
}

// ── slicker flag parsing ───────────────────────────────────────────

const ParseError = error{
    MissingValue,
    BadNumber,
    BadColor,
    UnknownFlag,
    ClickWithoutTarget,
    TemplateLoadFailed,
    TemplateTooLarge,
};

/// A parsed slicker invocation: the detection config plus run-control (whether
/// to loop, how often, and how many passes).
const SlickerRun = struct {
    config: slicker.Config,
    watch: bool = false,
    interval_ms: u32 = 500,
    /// 0 = run until stopped (only meaningful with watch).
    passes: usize = 1,
};

/// Build a SlickerRun from the argument iterator (positioned just after the
/// `slicker` subcommand). Starts from the benign default and overlays flags.
/// `io` is needed to load a `--template` PNG from disk.
fn parseSlickerArgs(io: std.Io, args: *std.process.Args.Iterator, label_store: []u8, title_store: []u8) ParseError!SlickerRun {
    var config = slicker.default_config;
    var run = SlickerRun{ .config = undefined };
    var have_sig = false;
    var have_template = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--click")) {
            config.click = true;
        } else if (std.mem.eql(u8, arg, "--no-verify")) {
            config.verify = false;
        } else if (std.mem.eql(u8, arg, "--watch")) {
            run.watch = true;
            if (run.passes == 1) run.passes = 0; // default watch = run forever
        } else if (std.mem.eql(u8, arg, "--interval-ms")) {
            const v = args.next() orelse return error.MissingValue;
            run.interval_ms = try parseU32(v);
        } else if (std.mem.eql(u8, arg, "--passes")) {
            const v = args.next() orelse return error.MissingValue;
            run.passes = try parseU32(v);
            run.watch = true;
        } else if (std.mem.eql(u8, arg, "--multi")) {
            config.mode = .color_multi;
        } else if (std.mem.eql(u8, arg, "--template")) {
            const path = args.next() orelse return error.MissingValue;
            config.edge_template = try loadTemplate(io, path);
            config.edge_threshold = TEMPLATE_EDGE_THRESHOLD;
            config.mode = .template;
            have_template = true;
        } else if (std.mem.eql(u8, arg, "--score")) {
            const v = args.next() orelse return error.MissingValue;
            config.template_min_permille = @intCast(try parseU32(v));
        } else if (std.mem.eql(u8, arg, "--sig")) {
            const v = args.next() orelse return error.MissingValue;
            config.rule.signature = try parseColor(v, config.rule.signature.tolerance);
            have_sig = true;
        } else if (std.mem.eql(u8, arg, "--tol")) {
            const v = args.next() orelse return error.MissingValue;
            config.rule.signature.tolerance = try parseU8(v);
        } else if (std.mem.eql(u8, arg, "--min-area")) {
            const v = args.next() orelse return error.MissingValue;
            config.rule.min_area = try parseU32(v);
        } else if (std.mem.eql(u8, arg, "--min-fill")) {
            const v = args.next() orelse return error.MissingValue;
            config.rule.min_fill_permille = try parseU32(v);
        } else if (std.mem.eql(u8, arg, "--max-regions")) {
            const v = args.next() orelse return error.MissingValue;
            config.max_regions = try parseU32(v);
        } else if (std.mem.eql(u8, arg, "--delay-ms")) {
            const v = args.next() orelse return error.MissingValue;
            config.verify_delay_ms = try parseU32(v);
        } else if (std.mem.eql(u8, arg, "--title")) {
            const v = args.next() orelse return error.MissingValue;
            config.title_filter = copyInto(title_store, v);
        } else if (std.mem.eql(u8, arg, "--label")) {
            const v = args.next() orelse return error.MissingValue;
            config.rule.label = copyInto(label_store, v);
        } else {
            return error.UnknownFlag;
        }
    }

    // Safety gate: clicking requires an explicit operator-chosen target —
    // either a color signature or a template image. Nothing is baked in.
    if (config.click and !have_sig and !have_template) return error.ClickWithoutTarget;

    run.config = config;
    return run;
}

/// Load a PNG from `path`, decode to RGBA8, and reduce it to a grayscale
/// an `EdgeTemplate` (the template's Sobel edge points) for chamfer shape
/// matching. All buffers are file-scope statics — no heap. Returns
/// TemplateTooLarge if the image exceeds the caps, or TemplateLoadFailed if the
/// image has too little edge structure to match on.
fn loadTemplate(io: std.Io, path: []const u8) ParseError!ui_detect.EdgeTemplate {
    const cwd: std.Io.Dir = .cwd();
    const file = cwd.openFile(io, path, .{}) catch return error.TemplateLoadFailed;
    defer file.close(io);
    const stat = file.stat(io) catch return error.TemplateLoadFailed;
    if (stat.size == 0 or stat.size > tpl_file_buf.len) return error.TemplateLoadFailed;

    var reader = file.reader(io, &.{});
    var got: u64 = 0;
    while (got < stat.size) {
        const want: usize = @intCast(@min(stat.size - got, tpl_file_buf.len - got));
        const n = reader.interface.readSliceShort(tpl_file_buf[@intCast(got)..][0..want]) catch return error.TemplateLoadFailed;
        if (n == 0) break;
        got += n;
    }
    const file_data = tpl_file_buf[0..@intCast(got)];

    const info = png_decode.readInfo(file_data) catch return error.TemplateLoadFailed;
    if (@as(usize, info.width) * @as(usize, info.height) > TPL_MAX_PX) return error.TemplateTooLarge;

    const decoded = png_decode.decode(file_data, &tpl_scratch, &tpl_raw, &tpl_rgba) catch return error.TemplateLoadFailed;

    // Extract the template's edge points (button outline + glyph strokes).
    const np = ui_detect.prepareTemplate(decoded.pixels, decoded.width, decoded.height, TEMPLATE_EDGE_THRESHOLD, tpl_edge_points[0..]);
    if (np == 0) return error.TemplateLoadFailed; // no usable shape

    return .{ .w = decoded.width, .h = decoded.height, .points = tpl_edge_points[0..np] };
}

fn copyInto(store: []u8, v: []const u8) []const u8 {
    const n = @min(v.len, store.len);
    @memcpy(store[0..n], v[0..n]);
    return store[0..n];
}

fn parseU32(s: []const u8) ParseError!u32 {
    if (s.len == 0) return error.BadNumber;
    var acc: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return error.BadNumber;
        acc = acc * 10 + (c - '0');
        if (acc > 0xffff_ffff) return error.BadNumber;
    }
    return @intCast(acc);
}

fn parseU8(s: []const u8) ParseError!u8 {
    const v = try parseU32(s);
    if (v > 255) return error.BadNumber;
    return @intCast(v);
}

/// Parse "R,G,B" (each 0..255) into a ColorSignature, preserving `tolerance`.
fn parseColor(s: []const u8, tolerance: u8) ParseError!ui_detect.ColorSignature {
    var it = std.mem.splitScalar(u8, s, ',');
    const r = try parseU8(it.next() orelse return error.BadColor);
    const g = try parseU8(it.next() orelse return error.BadColor);
    const b = try parseU8(it.next() orelse return error.BadColor);
    if (it.next() != null) return error.BadColor; // too many components
    return .{ .r = r, .g = g, .b = b, .tolerance = tolerance };
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator()) catch
        std.process.fatal("cannot read command line", .{});
    defer args.deinit();

    _ = args.next(); // skip the executable path

    // No subcommand -> run the benign detect-only self-test scan.
    const cmd_str = args.next() orelse {
        runSlickerScan(slicker.default_config);
        return;
    };

    switch (Command.parse(cmd_str)) {
        .help => printUsage(),
        .version => std.debug.print("{s}\n", .{version}),
        .slicker => {
            var label_store: [128]u8 = undefined;
            var title_store: [256]u8 = undefined;
            const run = parseSlickerArgs(init.io, &args, &label_store, &title_store) catch |err| {
                slickerArgError(err);
            };
            if (run.watch) {
                runSlickerWatch(run);
            } else {
                runSlickerScan(run.config);
            }
        },
        .hash => {
            const text = args.next() orelse std.process.fatal("usage: stools hash <text>", .{});
            std.debug.print("{x}\n", .{fnv1a(text)});
        },
        .now => {
            // Monotonic clock via the PAL's Io. `.awake` is the CLOCK_MONOTONIC
            // equivalent: never goes backwards, unaffected by wall-clock jumps.
            const ts = std.Io.Timestamp.now(init.io, .awake);
            std.debug.print("{d}\n", .{ts.toNanoseconds()});
        },
        .unknown => {
            std.debug.print("unknown command: '{s}'\n\n", .{cmd_str});
            printUsage();
            std.process.exit(2);
        },
    }
}

fn slickerArgError(err: ParseError) noreturn {
    const msg = switch (err) {
        error.MissingValue => "a flag is missing its value",
        error.BadNumber => "expected a number",
        error.BadColor => "expected a color as R,G,B (each 0..255)",
        error.UnknownFlag => "unknown slicker flag",
        error.ClickWithoutTarget => "--click requires an explicit target: --sig R,G,B or --template FILE.png",
        error.TemplateLoadFailed => "could not read/decode the --template PNG",
        error.TemplateTooLarge => "the --template image is larger than 512x512",
    };
    std.process.fatal("slicker: {s} (see `stools help`)", .{msg});
}

test "commands parse exactly" {
    try std.testing.expectEqual(Command.help, Command.parse("help"));
    try std.testing.expectEqual(Command.slicker, Command.parse("slicker"));
    try std.testing.expectEqual(Command.hash, Command.parse("hash"));
    try std.testing.expectEqual(Command.unknown, Command.parse("HASH"));
}

test "fnv1a is stable and non-trivial" {
    try std.testing.expectEqual(fnv1a(""), 0xcbf29ce484222325);
    try std.testing.expect(fnv1a("stools") != fnv1a("stool"));
}

test "parseU32 accepts digits and rejects junk" {
    try std.testing.expectEqual(@as(u32, 0), try parseU32("0"));
    try std.testing.expectEqual(@as(u32, 4294967295), try parseU32("4294967295"));
    try std.testing.expectError(error.BadNumber, parseU32(""));
    try std.testing.expectError(error.BadNumber, parseU32("12a"));
    try std.testing.expectError(error.BadNumber, parseU32("4294967296")); // overflow
}

test "parseU8 bounds to a byte" {
    try std.testing.expectEqual(@as(u8, 255), try parseU8("255"));
    try std.testing.expectError(error.BadNumber, parseU8("256"));
}

test "parseColor reads R,G,B and keeps tolerance" {
    const c = try parseColor("124,92,219", 30);
    try std.testing.expectEqual(@as(u8, 124), c.r);
    try std.testing.expectEqual(@as(u8, 92), c.g);
    try std.testing.expectEqual(@as(u8, 219), c.b);
    try std.testing.expectEqual(@as(u8, 30), c.tolerance);
    try std.testing.expectError(error.BadColor, parseColor("1,2", 0));
    try std.testing.expectError(error.BadColor, parseColor("1,2,3,4", 0));
    try std.testing.expectError(error.BadNumber, parseColor("1,2,300", 0));
}

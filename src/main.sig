// stools — the SB0 tools suite.
//
// A native command-line entry point that dispatches to the individual tools in
// the suite. The first tool is `slicker`, a config-driven visual UI-automation
// engine (see src/slicker.sig).

const std = @import("std");
const slicker = @import("slicker.sig");

pub const version = "0.0.1";

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
        \\  slicker           Visual UI-automation engine (scans all windows)
        \\  hash <text>       Print the FNV-1a hash of the given text
        \\  now               Print a monotonic timestamp (nanoseconds)
        \\
        \\slicker (default action: a single detect-only scan of every window):
        \\  Detects a configured color signature across all open windows and
        \\  reports matches. Clicking is opt-in via config and never targets
        \\  application security or consent prompts.
        \\
    , .{version});
}

/// Run one detect-only scan across all windows using the benign default config.
/// This is the self-test: it enumerates every window, captures it, and reports
/// whether the target signature was found. No clicking.
pub fn runScanSelfTest() void {
    std.debug.print("stools slicker — scanning all windows (detect-only)\n", .{});
    const report = slicker.scanOnce(slicker.default_config);
    std.debug.print(
        "scan complete: {d} windows scanned, {d} matches\n",
        .{ report.windows_scanned, report.matches },
    );
    if (report.matches == 0) {
        std.debug.print("result: PASS (target signature not present in any window)\n", .{});
    } else {
        std.debug.print("result: FOUND ({d} match(es) reported above)\n", .{report.matches});
    }
}

pub fn main() void {
    // The dependency-free entry runs the slicker self-test: a safe, detect-only
    // full-window scan. Interactive subcommand routing arrives with the suite's
    // PAL argv support.
    runScanSelfTest();
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

// stools — the SB0 tools suite.
//
// A native, dependency-free command-line entry point that dispatches to the
// individual tools in the suite. Pure Sig, no allocator, no heap: commands are
// matched by value and each tool is an allocation-free pure function.

const std = @import("std");

pub const version = "0.0.1";

/// Every top-level command understood by the suite.
pub const Command = enum {
    help,
    version,
    // ── Suite tools (skeletons — flesh out as the suite grows) ──
    hash,
    now,
    unknown,

    /// Parse a command from its textual argument.
    pub fn parse(value: []const u8) Command {
        if (std.mem.eql(u8, value, "help")) return .help;
        if (std.mem.eql(u8, value, "-h")) return .help;
        if (std.mem.eql(u8, value, "--help")) return .help;
        if (std.mem.eql(u8, value, "version")) return .version;
        if (std.mem.eql(u8, value, "-V")) return .version;
        if (std.mem.eql(u8, value, "--version")) return .version;
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
        \\  hash <text>       Print the FNV-1a hash of the given text
        \\  now               Print a monotonic timestamp (nanoseconds)
        \\
    , .{version});
}

/// Dispatch a parsed command. Kept separate from `main` so it is unit-testable
/// without a live process environment.
pub fn dispatch(cmd: Command) void {
    switch (cmd) {
        .help, .unknown => printUsage(),
        .version => std.debug.print("stools v{s}\n", .{version}),
        .hash => std.debug.print("{x}\n", .{fnv1a("stools")}),
        .now => std.debug.print("{d}\n", .{std.time.nanoTimestamp()}),
    }
}

pub fn main() void {
    // Args wiring is provided per-platform by the suite's PAL as tools land;
    // the dependency-free scaffold shows usage so the binary is runnable now.
    printUsage();
}

test "commands parse exactly" {
    try std.testing.expectEqual(Command.help, Command.parse("help"));
    try std.testing.expectEqual(Command.version, Command.parse("--version"));
    try std.testing.expectEqual(Command.hash, Command.parse("hash"));
    try std.testing.expectEqual(Command.now, Command.parse("now"));
    try std.testing.expectEqual(Command.unknown, Command.parse("HASH"));
}

test "fnv1a is stable and non-trivial" {
    try std.testing.expectEqual(fnv1a(""), 0xcbf29ce484222325);
    try std.testing.expect(fnv1a("stools") != fnv1a("stool"));
}

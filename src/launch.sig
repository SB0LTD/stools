// launch — turn a schema Command's live flag state into an argv, then run the
// right built binary via zpm subprocess. Fully generic over the schema: it
// never references a specific tool by name, so new tools in the registry are
// launchable with no changes here.
//
// argv layout:
//   stools binary:       <bin>/stools[.exe] [subcommand] [flags...]
//   img2elementor binary:<bin>/img2elementor[.exe] [positional/flags...]
//
// All storage is fixed-size (no heap): argv tokens are slices into a caller-
// owned scratch arena of bytes, and the argv pointer array is bounded.

const std = @import("std");
const builtin = @import("builtin");
const subprocess = @import("subprocess");
const schema = @import("tool_schema.sig");

pub const MAX_ARGV = 48;
/// Scratch bytes to serialize numeric/color tokens into. Text/path/positional
/// values are referenced in place from the flag buffers, so this only needs to
/// hold formatted numbers and "R,G,B" strings.
pub const SCRATCH = 4096;

/// Outcome the UI shows. For one-shot runs we capture output; for spawned
/// long-running processes we hold the handle so the UI can Stop it.
pub const LaunchKind = enum { one_shot, spawned, blocked };

pub const LaunchError = enum {
    none,
    /// slicker --click needs an explicit target (color sig or template).
    click_without_target,
    /// Could not resolve the binary path.
    bad_binary,
    /// The subprocess policy was rejected (should not happen — we pass none).
    spawn_failed,
    /// Too many argv tokens.
    too_many_args,
    /// A required positional was left empty.
    missing_positional,
};

/// A fully assembled launch: the argv (slices valid as long as `arena` and the
/// source Command live), plus the executable path.
pub const Plan = struct {
    argv: [MAX_ARGV][]const u8 = undefined,
    argc: usize = 0,
    exe_buf: [512]u8 = @splat(0),
    exe_len: usize = 0,
    kind: LaunchKind = .one_shot,
    err: LaunchError = .none,

    pub fn exePath(self: *const Plan) []const u8 {
        return self.exe_buf[0..self.exe_len];
    }
    pub fn argvSlice(self: *const Plan) []const []const u8 {
        return self.argv[0..self.argc];
    }
};

const exe_suffix = if (builtin.os.tag == .windows) ".exe" else "";

/// Resolve the sibling binary path from the launcher's own directory. The
/// launcher, stools, and img2elementor are all installed into the same bin/
/// dir, so we take the launcher's exe dir and append the target binary name.
/// `self_exe` is the launcher's own path (argv[0] / self path); `name` is the
/// bare binary name (e.g. "stools").
fn resolveBinary(pl: *Plan, self_dir: []const u8, name: []const u8) void {
    var pos: usize = 0;
    const cap = pl.exe_buf.len;
    const put = struct {
        fn f(buf: []u8, p: *usize, s: []const u8) void {
            const room = buf.len - p.*;
            const k = @min(room, s.len);
            @memcpy(buf[p.*..][0..k], s[0..k]);
            p.* += k;
        }
    }.f;
    put(pl.exe_buf[0..], &pos, self_dir);
    if (self_dir.len > 0 and self_dir[self_dir.len - 1] != sep) {
        if (pos < cap) {
            pl.exe_buf[pos] = sep;
            pos += 1;
        }
    }
    put(pl.exe_buf[0..], &pos, name);
    put(pl.exe_buf[0..], &pos, exe_suffix);
    pl.exe_len = pos;
}

const sep: u8 = if (builtin.os.tag == .windows) '\\' else '/';

/// Format a u64 into `scratch` at `off`, return the written slice + new offset.
fn fmtInt(scratch: []u8, off: *usize, v: u64) []const u8 {
    const start = off.*;
    var tmp: [20]u8 = undefined;
    var tlen: usize = 0;
    var x = v;
    if (x == 0) {
        tmp[tlen] = '0';
        tlen += 1;
    } else {
        while (x > 0) : (x /= 10) {
            tmp[tlen] = @intCast('0' + (x % 10));
            tlen += 1;
        }
    }
    // reverse into scratch
    var i = tlen;
    while (i > 0) : (i -= 1) {
        if (off.* < scratch.len) {
            scratch[off.*] = tmp[i - 1];
            off.* += 1;
        }
    }
    return scratch[start..off.*];
}

/// Format "R,G,B" into scratch, return the slice.
fn fmtColor(scratch: []u8, off: *usize, r: u8, g: u8, b: u8) []const u8 {
    const start = off.*;
    _ = fmtInt(scratch, off, r);
    if (off.* < scratch.len) {
        scratch[off.*] = ',';
        off.* += 1;
    }
    _ = fmtInt(scratch, off, g);
    if (off.* < scratch.len) {
        scratch[off.*] = ',';
        off.* += 1;
    }
    _ = fmtInt(scratch, off, b);
    return scratch[start..off.*];
}

fn push(pl: *Plan, tok: []const u8) bool {
    if (pl.argc >= MAX_ARGV) {
        pl.err = .too_many_args;
        return false;
    }
    pl.argv[pl.argc] = tok;
    pl.argc += 1;
    return true;
}

/// Whether a color/template target is present & enabled (for the slicker
/// click-safety gate). Generic check: any enabled `--sig` color or non-empty
/// `--template` path.
fn hasClickTarget(cmd: *const schema.Command) bool {
    for (cmd.flagsConst()) |f| {
        if (f.kind == .color and f.val_on) return true;
        if (f.kind == .path and std.mem.eql(u8, f.token, "--template") and f.val_text_len > 0) return true;
    }
    return false;
}

fn clickRequested(cmd: *const schema.Command) bool {
    for (cmd.flagsConst()) |f| {
        if (std.mem.eql(u8, f.token, "--click") and f.val_on) return true;
    }
    return false;
}

/// Build a launch Plan from a command's current flag state. `self_dir` is the
/// directory containing the launcher executable (where sibling binaries live).
/// `scratch` holds formatted numeric/color tokens for the plan's lifetime.
pub fn plan(cmd: *const schema.Command, self_dir: []const u8, scratch: []u8) Plan {
    var p = Plan{};
    var off: usize = 0;

    // Safety gate mirrors slicker's own: clicking needs an explicit target.
    if (clickRequested(cmd) and !hasClickTarget(cmd)) {
        p.err = .click_without_target;
        return p;
    }

    // argv[0] = the binary.
    const bin_name: []const u8 = switch (cmd.binary) {
        .stools => "stools",
        .img2elementor => "img2elementor",
    };
    resolveBinary(&p, self_dir, bin_name);
    if (p.exe_len == 0) {
        p.err = .bad_binary;
        return p;
    }
    if (!push(&p, p.exePath())) return p;

    // Optional subcommand token.
    if (cmd.subcommand.len > 0) {
        if (!push(&p, cmd.subcommand)) return p;
    }

    // Flags, in declaration order.
    for (cmd.flagsConst()) |*f| {
        switch (f.kind) {
            .toggle => {
                if (f.val_on and f.token.len > 0) {
                    if (!push(&p, f.token)) return p;
                }
            },
            .int => {
                if (!f.val_on) continue;
                if (f.token.len > 0 and !push(&p, f.token)) return p;
                if (!push(&p, fmtInt(scratch, &off, f.val_int))) return p;
            },
            .color => {
                if (!f.val_on) continue;
                if (f.token.len > 0 and !push(&p, f.token)) return p;
                if (!push(&p, fmtColor(scratch, &off, f.val_r, f.val_g, f.val_b))) return p;
            },
            .text, .path => {
                if (f.val_text_len == 0) continue; // optional; omit when empty
                if (f.token.len > 0 and !push(&p, f.token)) return p;
                if (!push(&p, f.textSlice())) return p;
            },
            .choice => {
                if (f.choices.len == 0) continue;
                const idx = @min(f.val_choice, f.choices.len - 1);
                const tok = f.choices[idx].token;
                if (tok.len > 0 and !push(&p, tok)) return p;
            },
            .positional => {
                if (f.val_text_len == 0) {
                    p.err = .missing_positional;
                    return p;
                }
                if (!push(&p, f.textSlice())) return p;
            },
        }
    }

    p.kind = if (schema.runsForever(cmd)) .spawned else .one_shot;
    return p;
}

/// Execute a one-shot plan and capture its output. Blocks until completion.
pub fn runOneShot(io: std.Io, p: *const Plan) subprocess.SubprocessResult {
    const cfg = subprocess.SubprocessConfig{ .argv = p.argvSlice() };
    return subprocess.run(io, &cfg);
}

/// Spawn a long-running plan without waiting. Returns the handle to Stop later.
pub fn spawnLong(io: std.Io, p: *const Plan) ?subprocess.ProcessHandle {
    const cfg = subprocess.SubprocessConfig{ .argv = p.argvSlice() };
    return subprocess.spawn(io, &cfg);
}

// ── Tests ──────────────────────────────────────────────────────────

test "plan assembles slicker argv with subcommand and enabled flags" {
    var reg = schema.buildRegistry();
    const slicker = &reg[0];
    // Enable a couple of flags with values.
    for (slicker.flagsSlice()) |*f| {
        if (std.mem.eql(u8, f.token, "--sig")) {
            f.val_on = true;
            f.val_r = 113;
            f.val_g = 56;
            f.val_b = 204;
        }
        if (std.mem.eql(u8, f.token, "--tol")) {
            f.val_on = true;
            f.val_int = 24;
        }
    }
    var scratch: [SCRATCH]u8 = undefined;
    const p = plan(slicker, "C:\\bin", &scratch);
    try std.testing.expectEqual(LaunchError.none, p.err);
    // argv[0] ends with stools(.exe); argv[1] == "slicker".
    try std.testing.expect(std.mem.endsWith(u8, p.argv[0], "stools" ++ exe_suffix));
    try std.testing.expectEqualStrings("slicker", p.argv[1]);
    // --sig 113,56,204 present somewhere.
    var found_sig = false;
    var i: usize = 0;
    while (i + 1 < p.argc) : (i += 1) {
        if (std.mem.eql(u8, p.argv[i], "--sig")) {
            try std.testing.expectEqualStrings("113,56,204", p.argv[i + 1]);
            found_sig = true;
        }
    }
    try std.testing.expect(found_sig);
}

test "click without target is blocked" {
    var reg = schema.buildRegistry();
    const slicker = &reg[0];
    // Turn OFF the default color sig, then request click.
    for (slicker.flagsSlice()) |*f| {
        if (std.mem.eql(u8, f.token, "--sig")) f.val_on = false;
        if (std.mem.eql(u8, f.token, "--click")) f.val_on = true;
    }
    var scratch: [SCRATCH]u8 = undefined;
    const p = plan(slicker, "C:\\bin", &scratch);
    try std.testing.expectEqual(LaunchError.click_without_target, p.err);
}

test "hash positional is required and emitted verbatim" {
    var reg = schema.buildRegistry();
    const hash = &reg[2];
    var scratch: [SCRATCH]u8 = undefined;
    // Empty -> missing_positional.
    var p = plan(hash, "/usr/bin", &scratch);
    try std.testing.expectEqual(LaunchError.missing_positional, p.err);
    // Set text -> emitted after the subcommand.
    hash.flags[0].setText("hello");
    p = plan(hash, "/usr/bin", &scratch);
    try std.testing.expectEqual(LaunchError.none, p.err);
    try std.testing.expectEqualStrings("hash", p.argv[1]);
    try std.testing.expectEqualStrings("hello", p.argv[2]);
}

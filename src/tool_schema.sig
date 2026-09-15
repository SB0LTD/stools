// tool_schema — a data-driven description of every stools command and its
// flags, plus the mutable form state the launcher UI edits and turns into an
// argv for a subprocess launch.
//
// This module is the single source of truth for what the launcher can run.
// Adding a NEW tool (current or future) is purely additive: append a Command
// to `registry` with its Flag list. The UI renders any Command generically and
// the argv assembler (see launch.sig) serializes any Command generically —
// neither needs per-tool code. Nothing here is application-specific beyond the
// data itself.
//
// Design constraints (match the rest of stools): allocation-free. All flag
// value storage is inline fixed-size buffers; the registry is a comptime-built
// array of Commands whose Flags carry runtime-mutable `value` state.

const std = @import("std");

/// The kind of a flag decides how the UI renders it and how the argv assembler
/// serializes it. Generic across all tools.
pub const FlagKind = enum {
    /// On/off. Emits `token` when on, nothing when off. No value.
    toggle,
    /// Unsigned integer with min/max/step. Emits `token value`.
    int,
    /// Free text. Emits `token value` when non-empty.
    text,
    /// Filesystem path (rendered with a path affordance). Emits `token value`.
    path,
    /// Three 0..255 channels. Emits `token R,G,B`.
    color,
    /// One-of choice from `choices`. Each choice may map to its own token
    /// (e.g. slicker mode: default=nothing, multi=`--multi`). Emits the
    /// selected choice's token (which may be empty for "no flag").
    choice,
    /// A required positional argument (no token, value emitted verbatim in
    /// order). Used by `hash <text>` and `img2elementor <input>`.
    positional,
};

/// One selectable option for a `choice` flag. `token` is emitted as-is when
/// selected (empty string means "emit nothing" — a real default state).
pub const Choice = struct {
    label: []const u8,
    token: []const u8,
};

/// Inline storage caps. Generous but bounded — no heap anywhere.
pub const MAX_TEXT = 256;
pub const MAX_CHOICES = 6;

/// A single flag/argument. The static fields (name..choices) describe it; the
/// `val_*` fields are the live, user-editable value the UI mutates.
pub const Flag = struct {
    /// The CLI token, e.g. "--sig". Empty for positionals.
    token: []const u8 = "",
    /// Human label shown in the form.
    label: []const u8,
    /// One-line help shown under the control.
    help: []const u8 = "",
    kind: FlagKind,

    // ── int constraints ──
    int_min: u64 = 0,
    int_max: u64 = 1_000_000,
    int_step: u64 = 1,

    // ── choice options ──
    choices: []const Choice = &.{},

    // ── live value state (mutated by the UI) ──
    /// toggle: on/off. Also the "enabled" bit for optional int/text/path/color
    /// flags — when false, the flag is omitted from argv entirely.
    val_on: bool = false,
    /// int value.
    val_int: u64 = 0,
    /// color channels (0..255).
    val_r: u8 = 0,
    val_g: u8 = 0,
    val_b: u8 = 0,
    /// selected choice index (for `choice`).
    val_choice: usize = 0,
    /// text/path buffer + length.
    val_text: [MAX_TEXT]u8 = @splat(0),
    val_text_len: usize = 0,

    pub fn textSlice(self: *const Flag) []const u8 {
        return self.val_text[0..self.val_text_len];
    }

    pub fn setText(self: *Flag, s: []const u8) void {
        const n = @min(s.len, MAX_TEXT);
        @memcpy(self.val_text[0..n], s[0..n]);
        self.val_text_len = n;
    }

    /// Append one character to a text/path flag (used by keyboard input).
    pub fn pushChar(self: *Flag, c: u8) void {
        if (self.val_text_len < MAX_TEXT) {
            self.val_text[self.val_text_len] = c;
            self.val_text_len += 1;
        }
    }

    /// Remove the last character (backspace).
    pub fn popChar(self: *Flag) void {
        if (self.val_text_len > 0) self.val_text_len -= 1;
    }
};

/// How the command's binary is invoked: which executable, and whether a
/// subcommand token precedes the flags (stools uses `stools slicker ...`;
/// img2elementor is its own binary with no subcommand).
pub const Binary = enum {
    /// The `stools` dispatcher binary. `subcommand` names the subcommand.
    stools,
    /// The standalone `img2elementor` binary. No subcommand.
    img2elementor,
};

pub const MAX_FLAGS = 24;

/// A launchable command: a binary + optional subcommand + a set of flags.
pub const Command = struct {
    /// Short name shown in the command list, e.g. "slicker".
    name: []const u8,
    /// One-line description shown in the header.
    summary: []const u8,
    /// Accent color index into the palette (see ui theme) for visual identity.
    accent: Accent,
    binary: Binary,
    /// Subcommand token for the stools binary (e.g. "slicker"). Empty when the
    /// binary takes no subcommand (img2elementor) or none is needed.
    subcommand: []const u8 = "",
    /// Whether this command runs indefinitely (needs spawn + a Stop control)
    /// vs. one-shot (blocking run with captured output). Data-driven so the UI
    /// knows to show Stop. slicker --watch is handled specially: see runsForever.
    long_running_when: LongRunning = .never,
    /// The flags/arguments, in display + argv order.
    flags: [MAX_FLAGS]Flag = undefined,
    flag_count: usize = 0,

    pub fn flagsSlice(self: *Command) []Flag {
        return self.flags[0..self.flag_count];
    }
    pub fn flagsConst(self: *const Command) []const Flag {
        return self.flags[0..self.flag_count];
    }
};

/// Visual accent identity per command.
pub const Accent = enum { violet, cyan, mint, amber };

/// Whether a command is long-running.
pub const LongRunning = enum {
    /// Always one-shot.
    never,
    /// Always long-running.
    always,
    /// Long-running only when a specific toggle flag (by token) is on. Used by
    /// slicker: it loops forever only with --watch (and no bounded --passes).
    when_watch,
};

// ── Builders (comptime helpers to keep the registry readable) ──────────────

fn toggle(token: []const u8, label: []const u8, help: []const u8, on: bool) Flag {
    return .{ .token = token, .label = label, .help = help, .kind = .toggle, .val_on = on };
}

fn intFlag(token: []const u8, label: []const u8, help: []const u8, min: u64, max: u64, step: u64, default: u64, on: bool) Flag {
    return .{
        .token = token,
        .label = label,
        .help = help,
        .kind = .int,
        .int_min = min,
        .int_max = max,
        .int_step = step,
        .val_int = default,
        .val_on = on,
    };
}

fn colorFlag(token: []const u8, label: []const u8, help: []const u8, r: u8, g: u8, b: u8, on: bool) Flag {
    return .{ .token = token, .label = label, .help = help, .kind = .color, .val_r = r, .val_g = g, .val_b = b, .val_on = on };
}

fn textFlag(token: []const u8, label: []const u8, help: []const u8, kind: FlagKind) Flag {
    return .{ .token = token, .label = label, .help = help, .kind = kind };
}

fn positional(label: []const u8, help: []const u8) Flag {
    return .{ .token = "", .label = label, .help = help, .kind = .positional, .val_on = true };
}

fn mkCommand(
    name: []const u8,
    summary: []const u8,
    accent: Accent,
    binary: Binary,
    subcommand: []const u8,
    lr: LongRunning,
    comptime flags: []const Flag,
) Command {
    var c = Command{
        .name = name,
        .summary = summary,
        .accent = accent,
        .binary = binary,
        .subcommand = subcommand,
        .long_running_when = lr,
    };
    for (flags, 0..) |f, i| c.flags[i] = f;
    c.flag_count = flags.len;
    return c;
}

// ── The registry: every launchable tool. Append here to add a tool. ────────

pub const MAX_COMMANDS = 16;

/// Build the live registry. Returns a fresh, independently-editable copy so the
/// UI can mutate flag values without touching comptime data. Extend by adding
/// a mkCommand(...) entry — the UI and argv assembler pick it up automatically.
pub fn buildRegistry() [MAX_COMMANDS]Command {
    var reg: [MAX_COMMANDS]Command = undefined;
    var n: usize = 0;

    // ── slicker: visual UI-automation engine ──
    reg[n] = mkCommand(
        "slicker",
        "Visual UI-automation — find and click UI elements across all windows",
        .violet,
        .stools,
        "slicker",
        .when_watch,
        &.{
            // Detection target (choice of strategy).
            mkChoice(
                "Strategy",
                "How to locate the target element",
                &.{
                    .{ .label = "Single color region", .token = "" },
                    .{ .label = "Multi color regions", .token = "--multi" },
                },
            ),
            colorFlag("--sig", "Color signature (R,G,B)", "Fill color of the target, 0..255 each", 113, 56, 204, true),
            intFlag("--tol", "Color tolerance", "Per-channel color tolerance", 0, 255, 1, 24, false),
            intFlag("--min-area", "Min area (px)", "Minimum connected pixels for a real hit", 0, 100000, 100, 3000, false),
            intFlag("--min-fill", "Min fill (per-mille)", "Minimum fill of the bounding box, per-mille", 0, 1000, 10, 550, false),
            intFlag("--max-regions", "Max regions", "Cap on regions acted on per window", 1, 64, 1, 16, false),
            textFlag("--template", "Template PNG", "Match this button/icon image instead of a color", .path),
            intFlag("--score", "Template score", "Min template match score, per-mille", 0, 1000, 10, 700, false),
            textFlag("--title", "Window title filter", "Only scan windows whose title contains this", .text),
            textFlag("--label", "Match label", "Human label used in match logs", .text),
            // Action + safety.
            toggle("--click", "Click matches", "Actually click (opt-in). Requires a target: color sig or template.", false),
            toggle("--no-verify", "Skip verify", "Skip the post-click re-capture confirmation", false),
            intFlag("--delay-ms", "Verify delay (ms)", "Wait between click and verify capture", 0, 5000, 10, 120, false),
            // Continuous mode.
            toggle("--watch", "Watch (loop)", "Scan continuously, re-acting each pass until stopped", false),
            intFlag("--interval-ms", "Watch interval (ms)", "Delay between watch passes", 50, 60000, 50, 1000, false),
            intFlag("--passes", "Bounded passes", "Run N passes then stop (implies watch)", 1, 100000, 1, 4, false),
        },
    );
    n += 1;

    // ── img2elementor: screenshot/URL -> Elementor template ──
    reg[n] = mkCommand(
        "img2elementor",
        "Reconstruct an editable Elementor template from a screenshot or URL",
        .cyan,
        .img2elementor,
        "",
        .never,
        &.{
            positional("Input (PNG path or URL)", "A local .png or an http(s):// URL to capture"),
            textFlag("", "Output JSON path", "Where to write the template (optional)", .path),
            toggle("--debug", "Debug regions", "Print detected regions to stderr", false),
        },
    );
    n += 1;

    // ── hash: FNV-1a of text ──
    reg[n] = mkCommand(
        "hash",
        "Print the FNV-1a 64-bit hash of the given text",
        .mint,
        .stools,
        "hash",
        .never,
        &.{
            positional("Text", "The text to hash"),
        },
    );
    n += 1;

    // ── now: monotonic timestamp ──
    reg[n] = mkCommand(
        "now",
        "Print a monotonic timestamp (nanoseconds)",
        .amber,
        .stools,
        "now",
        .never,
        &.{},
    );
    n += 1;

    // ── version ──
    reg[n] = mkCommand(
        "version",
        "Print the stools suite version",
        .amber,
        .stools,
        "version",
        .never,
        &.{},
    );
    n += 1;

    // Zero out the remaining slots' flag counts so slicing is safe.
    var k = n;
    while (k < MAX_COMMANDS) : (k += 1) {
        reg[k] = Command{ .name = "", .summary = "", .accent = .violet, .binary = .stools };
        reg[k].flag_count = 0;
    }
    return reg;
}

/// Number of populated commands in a registry built by buildRegistry().
pub fn commandCount() usize {
    return 5;
}

fn mkChoice(label: []const u8, help: []const u8, comptime choices: []const Choice) Flag {
    var f = Flag{ .token = "", .label = label, .help = help, .kind = .choice, .val_on = true };
    // choices is comptime data with static lifetime — safe to reference.
    f.choices = choices;
    return f;
}

/// Does this command, in its current flag state, run indefinitely? The UI uses
/// this to decide between a blocking run (with captured output) and a spawn
/// (with a Stop control).
pub fn runsForever(cmd: *const Command) bool {
    switch (cmd.long_running_when) {
        .never => return false,
        .always => return true,
        .when_watch => {
            // slicker loops forever with --watch UNLESS --passes is enabled
            // (bounded). Find those two flags by token.
            var watch_on = false;
            var passes_on = false;
            for (cmd.flagsConst()) |f| {
                if (std.mem.eql(u8, f.token, "--watch")) watch_on = f.val_on;
                if (std.mem.eql(u8, f.token, "--passes")) passes_on = f.val_on;
            }
            return watch_on and !passes_on;
        },
    }
}

// ── Tests ──────────────────────────────────────────────────────────

test "registry builds with the expected command count" {
    const reg = buildRegistry();
    try std.testing.expectEqual(@as(usize, 5), commandCount());
    try std.testing.expectEqualStrings("slicker", reg[0].name);
    try std.testing.expectEqualStrings("img2elementor", reg[1].name);
}

test "slicker exposes its full flag surface" {
    var reg = buildRegistry();
    const slicker = &reg[0];
    // Spot-check a few flags exist by token.
    var have_sig = false;
    var have_watch = false;
    var have_click = false;
    for (slicker.flagsConst()) |f| {
        if (std.mem.eql(u8, f.token, "--sig")) have_sig = true;
        if (std.mem.eql(u8, f.token, "--watch")) have_watch = true;
        if (std.mem.eql(u8, f.token, "--click")) have_click = true;
    }
    try std.testing.expect(have_sig and have_watch and have_click);
}

test "runsForever reflects watch/passes state" {
    var reg = buildRegistry();
    const slicker = &reg[0];
    // Default: not forever.
    try std.testing.expect(!runsForever(slicker));
    // Turn on watch -> forever.
    for (slicker.flagsSlice()) |*f| {
        if (std.mem.eql(u8, f.token, "--watch")) f.val_on = true;
    }
    try std.testing.expect(runsForever(slicker));
    // Also enable bounded passes -> no longer forever.
    for (slicker.flagsSlice()) |*f| {
        if (std.mem.eql(u8, f.token, "--passes")) f.val_on = true;
    }
    try std.testing.expect(!runsForever(slicker));
}

test "text flag push/pop/set" {
    var f = textFlag("--title", "Title", "", .text);
    f.setText("hello");
    try std.testing.expectEqualStrings("hello", f.textSlice());
    f.pushChar('!');
    try std.testing.expectEqualStrings("hello!", f.textSlice());
    f.popChar();
    try std.testing.expectEqualStrings("hello", f.textSlice());
}

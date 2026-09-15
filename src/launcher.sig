// stools launcher — a translucent, dark-glass control panel for the SB0 tools
// suite. It renders the data-driven command registry (tool_schema.sig) into a
// form and launches the selected tool via subprocess (launch.sig). Everything
// is generic over the schema, so future tools appear automatically.
//
// Visual language matches the SB0 house style: a borderless, layered
// (see-through) window, a dark near-black canvas, low-alpha glass panels, and
// the violet/cyan/mint/amber brand accents from the zpm materials Theme.
//
// Layer 3 (application shell). All heavy lifting — windowing, GL, text, the
// materials system, subprocess — lives in zpm and is merely composed here.

const std = @import("std");
const w32 = @import("win32");
const gl = @import("gl");
const windowmod = @import("window");
const prim = @import("primitives");
const colormod = @import("color");
const mats = @import("materials");
const textmod = @import("text");
const iconmod = @import("icon");
const subprocess = @import("subprocess");
const schema = @import("tool_schema.sig");
const launch = @import("launch.sig");

// The suite icon, embedded so the window/taskbar icon and the in-GUI logo need
// no external file at runtime. The same stools.ico also becomes the exe icon
// natively at build time via src/stools.rc (see build.sig .win32_resource) —
// one source of truth, built from logo.png by scripts/make-ico.ps1.
const stools_ico = @embedFile("stools.ico");

const Color = colormod.Color;
const Box = mats.Box;

// ── Window / layout constants ──────────────────────────────────────
const WIN_W: i32 = 1120;
const WIN_H: i32 = 720;
const OPACITY: u8 = 236; // whole-window alpha (see-through, but readable)

const TITLE_H: f32 = 44;
const BTN_W: f32 = 46; // title bar min/close buttons
const RAIL_W: f32 = 288; // left command list
const PAD: f32 = 20;
const ROW_H: f32 = 66; // flag row height
const FIELD_H: f32 = 30;

// ── UI state (file-scope; the WndProc is a C callback and can't capture) ────
const UiState = struct {
    width: i32 = WIN_W,
    height: i32 = WIN_H,

    // Mouse (GL space: origin bottom-left, y-up).
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    // A click that hasn't been consumed by the frame yet.
    click_pending: bool = false,
    click_x: f32 = 0,
    click_y: f32 = 0,

    title_hover: TitleHover = .none,

    // Command selection.
    selected: usize = 0,

    // Scroll offset for the form (in pixels).
    form_scroll: f32 = 0,

    // Focused text/path/positional flag index within the selected command
    // (-1 = none). Keyboard input routes here.
    focus_flag: isize = -1,

    // Launch result / running process.
    have_result: bool = false,
    result: subprocess.SubprocessResult = undefined,
    launch_err: launch.LaunchError = .none,
    running: bool = false,
    handle: ?subprocess.ProcessHandle = null,

    // Status line.
    status: [160]u8 = @splat(0),
    status_len: usize = 0,

    fn setStatus(self: *UiState, s: []const u8) void {
        const n = @min(s.len, self.status.len);
        @memcpy(self.status[0..n], s[0..n]);
        self.status_len = n;
    }
    fn statusSlice(self: *const UiState) []const u8 {
        return self.status[0..self.status_len];
    }
};

const TitleHover = enum { none, close, minimize };

var g_ui: UiState = .{};
var g_registry: [schema.MAX_COMMANDS]schema.Command = undefined;
var g_hwnd: w32.HWND = undefined;
var g_self_dir: [512]u8 = @splat(0);
var g_self_dir_len: usize = 0;
var g_io: std.Io = undefined;

// ── Color helpers: materials uses [4]f32, primitives/text use Color struct ──
fn c4(v: mats.Color) Color {
    return .{ .r = v[0], .g = v[1], .b = v[2], .a = v[3] };
}
fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
    return .{ .r = r, .g = g, .b = b, .a = a };
}

fn accentColor(a: schema.Accent) mats.Color {
    return switch (a) {
        .violet => mats.Theme.violet,
        .cyan => mats.Theme.cyan,
        .mint => mats.Theme.mint,
        .amber => mats.Theme.amber,
    };
}

// ── Font + icon (initialized after GL context) ──────────────────────
var g_font: textmod.FontAtlas = undefined;
var g_font_big: textmod.FontAtlas = undefined;
var g_logo: iconmod.IconTexture = .{};

// ── WndProc ─────────────────────────────────────────────────────────
fn loword(lp: w32.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lp)) & 0xFFFF))));
}
fn hiword(lp: w32.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate((@as(usize, @bitCast(lp)) >> 16) & 0xFFFF))));
}

fn wndProc(hwnd: w32.HWND, msg: u32, wparam: w32.WPARAM, lparam: w32.LPARAM) callconv(.c) w32.LRESULT {
    switch (msg) {
        w32.WM_NCHITTEST => {
            // Client-space cursor.
            var pt = w32.POINT{ .x = loword(lparam), .y = hiword(lparam) };
            _ = w32.ScreenToClient(hwnd, &pt);
            const fw: f32 = @floatFromInt(g_ui.width);
            const y_top: f32 = @floatFromInt(pt.y);
            const x: f32 = @floatFromInt(pt.x);
            // Top strip is the drag caption, except over the min/close buttons.
            if (y_top < TITLE_H) {
                if (x >= fw - BTN_W * 2) return w32.HTCLIENT; // buttons
                return w32.HTCAPTION; // draggable
            }
            return w32.HTCLIENT;
        },
        w32.WM_MOUSEMOVE => {
            const mx: f32 = @floatFromInt(loword(lparam));
            const my_top: f32 = @floatFromInt(hiword(lparam));
            g_ui.mouse_x = mx;
            g_ui.mouse_y = @as(f32, @floatFromInt(g_ui.height)) - my_top; // to GL space
            // Title button hover (top-of-window, screen top = high y).
            const fw: f32 = @floatFromInt(g_ui.width);
            if (my_top < TITLE_H) {
                if (mx >= fw - BTN_W) {
                    g_ui.title_hover = .close;
                } else if (mx >= fw - BTN_W * 2) {
                    g_ui.title_hover = .minimize;
                } else g_ui.title_hover = .none;
            } else g_ui.title_hover = .none;
        },
        w32.WM_LBUTTONDOWN => {
            // Title buttons act on down for snappiness.
            switch (g_ui.title_hover) {
                .close => {
                    w32.PostQuitMessage(0);
                    return 0;
                },
                .minimize => {
                    _ = w32.ShowWindow(hwnd, w32.SW_MINIMIZE);
                    return 0;
                },
                .none => {},
            }
            // Queue a client click for the frame to hit-test.
            g_ui.click_pending = true;
            g_ui.click_x = @floatFromInt(loword(lparam));
            g_ui.click_y = @as(f32, @floatFromInt(g_ui.height)) - @as(f32, @floatFromInt(hiword(lparam)));
        },
        w32.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(@as(u16, @truncate((wparam >> 16) & 0xFFFF)));
            g_ui.form_scroll -= @as(f32, @floatFromInt(delta)) / 120.0 * 48.0;
            if (g_ui.form_scroll < 0) g_ui.form_scroll = 0;
        },
        w32.WM_CHAR => {
            const ch: u8 = @truncate(wparam);
            handleChar(ch);
        },
        w32.WM_KEYDOWN => {
            // 0x08 backspace handled via WM_CHAR on Windows; also handle Esc.
            if (wparam == 0x1B) g_ui.focus_flag = -1; // Esc unfocuses
        },
        w32.WM_CLOSE, w32.WM_DESTROY => {
            w32.PostQuitMessage(0);
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}

fn handleChar(ch: u8) void {
    if (g_ui.focus_flag < 0) return;
    const cmd = &g_registry[g_ui.selected];
    const fi: usize = @intCast(g_ui.focus_flag);
    if (fi >= cmd.flag_count) return;
    const f = &cmd.flags[fi];
    if (f.kind != .text and f.kind != .path and f.kind != .positional) return;
    if (ch == 0x08) {
        f.popChar();
    } else if (ch >= 0x20 and ch < 0x7F) {
        f.pushChar(ch);
    }
}

// ── Hit-test helpers ────────────────────────────────────────────────
fn inBox(x: f32, y: f32, bx: f32, by: f32, bw: f32, bh: f32) bool {
    return x >= bx and x <= bx + bw and y >= by and y <= by + bh;
}

// ── Frame ───────────────────────────────────────────────────────────
fn frame() void {
    const w: f32 = @floatFromInt(g_ui.width);
    const h: f32 = @floatFromInt(g_ui.height);

    // Dark canvas — combined with the layered-window alpha this reads as glass.
    gl.glClearColor(mats.Theme.backdrop[0], mats.Theme.backdrop[1], mats.Theme.backdrop[2], 1.0);
    gl.glClear(gl.COLOR_BUFFER_BIT);
    gl.setupOrtho2D(g_ui.width, g_ui.height);
    gl.enableBlending();

    // Ambient gradient + a soft brand glow behind the rail for depth.
    prim.gradientRect(0, 0, w, h, rgba(0.02, 0.02, 0.05, 1.0), rgba(0.05, 0.05, 0.11, 1.0));
    const acc = accentColor(g_registry[g_ui.selected].accent);
    prim.glow(RAIL_W, h * 0.5, 420, c4(acc), 0.5);

    drawTitleBar(w, h);
    drawRail(w, h);
    drawForm(w, h);

    // Consume any pending click after all hit-testing this frame.
    g_ui.click_pending = false;
}

fn drawTitleBar(w: f32, h: f32) void {
    const y = h - TITLE_H;
    // Glass strip.
    mats.rect(.{ .x = 0, .y = y, .w = w, .h = TITLE_H }, mats.withAlpha(mats.Theme.surface_high, 0.55));
    mats.divider(0, y, w, mats.Theme.violet);

    // Wordmark, preceded by the suite mark.
    const mark = TITLE_H - 16;
    g_logo.drawAt(PAD + mark * 0.5, y + TITLE_H * 0.5, mark, 1.0);
    const word_x = PAD + mark + 12;
    _ = g_font_big.drawString("stools", word_x, y + 13, 1.0, c4(mats.Theme.text));
    const vx = word_x + g_font_big.measureString("stools", 1.0) + 8;
    _ = g_font.drawString("control", vx, y + 16, 1.0, c4(mats.Theme.violet_hot));

    // Min / close buttons (right).
    const min_x = w - BTN_W * 2;
    const close_x = w - BTN_W;
    if (g_ui.title_hover == .minimize)
        mats.rect(.{ .x = min_x, .y = y, .w = BTN_W, .h = TITLE_H }, mats.withAlpha(mats.Theme.highlight, 0.5));
    if (g_ui.title_hover == .close)
        mats.rect(.{ .x = close_x, .y = y, .w = BTN_W, .h = TITLE_H }, mats.withAlpha(mats.Theme.danger, 0.65));
    // glyphs
    const gy = y + TITLE_H * 0.5;
    prim.line(min_x + BTN_W * 0.5 - 6, gy, min_x + BTN_W * 0.5 + 6, gy, 1.5, c4(mats.Theme.text));
    prim.line(close_x + BTN_W * 0.5 - 6, gy - 6, close_x + BTN_W * 0.5 + 6, gy + 6, 1.5, c4(mats.Theme.text));
    prim.line(close_x + BTN_W * 0.5 - 6, gy + 6, close_x + BTN_W * 0.5 + 6, gy - 6, 1.5, c4(mats.Theme.text));
}

fn drawRail(w: f32, h: f32) void {
    _ = w;
    const top = h - TITLE_H;
    // Rail panel.
    mats.panel(.{ .x = PAD * 0.5, .y = PAD * 0.5, .w = RAIL_W - PAD * 0.5, .h = top - PAD }, 16, mats.Theme.surface, mats.Theme.violet, 3);

    // Brand emblem: a soft accent halo behind the suite logo, centered near the
    // top of the rail. Reinforces identity beyond the small titlebar mark.
    const emblem = 64.0;
    const ex = RAIL_W * 0.5;
    const ey = top - 30 - emblem * 0.5;
    prim.glow(ex, ey, emblem * 1.15, c4(mats.Theme.violet), 0.6);
    g_logo.drawAt(ex, ey, emblem, 1.0);

    _ = g_font.drawString("TOOLS", PAD * 1.4, top - 84, 0.85, c4(mats.Theme.text_muted));

    const n = schema.commandCount();
    var i: usize = 0;
    var iy = top - 110;
    const item_h: f32 = 58;
    while (i < n) : (i += 1) {
        iy -= item_h;
        const cmd = &g_registry[i];
        const bx = PAD;
        const bw = RAIL_W - PAD * 1.5;
        const selected = i == g_ui.selected;
        const hovered = inBox(g_ui.mouse_x, g_ui.mouse_y, bx, iy, bw, item_h - 8);
        const acc = accentColor(cmd.accent);

        const st: mats.Interaction = if (selected) .selected else if (hovered) .hover else .idle;
        if (selected or hovered) {
            mats.buttonSurface(.{ .x = bx, .y = iy, .w = bw, .h = item_h - 8 }, 12, mats.scaleRgb(acc, if (selected) 0.5 else 0.3), st);
        } else {
            mats.roundedRect(.{ .x = bx, .y = iy, .w = bw, .h = item_h - 8 }, 12, mats.withAlpha(mats.Theme.surface_raised, 0.6));
        }
        // Accent dot.
        prim.circle(bx + 18, iy + (item_h - 8) * 0.5, 5, c4(acc));
        _ = g_font.drawString(cmd.name, bx + 34, iy + (item_h - 8) * 0.5 - 6, 0.95, c4(mats.Theme.text));

        // Click selects.
        if (g_ui.click_pending and inBox(g_ui.click_x, g_ui.click_y, bx, iy, bw, item_h - 8)) {
            if (g_ui.selected != i) {
                g_ui.selected = i;
                g_ui.focus_flag = -1;
                g_ui.form_scroll = 0;
                g_ui.have_result = false;
                g_ui.launch_err = .none;
            }
        }
    }
}

fn drawForm(w: f32, h: f32) void {
    const top = h - TITLE_H;
    const fx = RAIL_W + PAD * 0.5;
    const fw = w - fx - PAD;
    const cmd = &g_registry[g_ui.selected];
    const acc = accentColor(cmd.accent);

    // Header.
    _ = g_font_big.drawString(cmd.name, fx + 4, top - 34, 1.0, c4(mats.Theme.text));
    _ = g_font.drawString(cmd.summary, fx + 4, top - 58, 0.82, c4(mats.Theme.text_muted));
    mats.divider(fx + 4, top - 68, fw - 8, acc);

    // Console / launch bar occupy the bottom; form scrolls in the middle.
    const bar_h: f32 = 54;
    const console_h: f32 = 150;
    const form_top = top - 80;
    const form_bottom = PAD + console_h + bar_h + 12;
    const view_h = form_top - form_bottom;

    // Clip the scrolling form region.
    prim.scissorBegin(fx, form_bottom, fw, view_h);
    var y = form_top + g_ui.form_scroll;
    var fi: usize = 0;
    while (fi < cmd.flag_count) : (fi += 1) {
        y -= ROW_H;
        drawFlagRow(cmd, fi, fx + 4, y, fw - 8, acc);
    }
    prim.scissorEnd();

    // Launch bar.
    drawLaunchBar(cmd, fx, PAD + console_h + 6, fw, bar_h, acc);

    // Console.
    drawConsole(fx, PAD, fw, console_h);
}

fn drawFlagRow(cmd: *schema.Command, fi: usize, x: f32, y: f32, wdt: f32, acc: mats.Color) void {
    const f = &cmd.flags[fi];
    // Label + help.
    _ = g_font.drawString(f.label, x, y + ROW_H - 22, 0.85, c4(mats.Theme.text));
    if (f.help.len > 0)
        _ = g_font.drawString(f.help, x, y + ROW_H - 40, 0.7, c4(mats.Theme.text_muted));

    const ctrl_x = x + wdt - 320;
    const ctrl_w: f32 = 316;
    const cy = y + ROW_H - 44;

    switch (f.kind) {
        .toggle => drawToggle(f, ctrl_x + ctrl_w - 62, cy, acc),
        .int => drawStepper(f, ctrl_x, cy, ctrl_w, acc, false),
        .color => drawColor(f, ctrl_x, cy, ctrl_w, acc),
        .text, .path, .positional => drawTextField(cmd, fi, ctrl_x, cy, ctrl_w, acc),
        .choice => drawChoice(f, ctrl_x, cy, ctrl_w, acc),
    }
}

/// A small "enabled" checkbox for optional valued flags, drawn to the left of
/// the control. Returns nothing; toggles f.val_on on click.
fn drawEnable(f: *schema.Flag, x: f32, cy: f32) void {
    const s: f32 = 16;
    const by = cy + (FIELD_H - s) * 0.5;
    mats.roundedRect(.{ .x = x, .y = by, .w = s, .h = s }, 4, mats.withAlpha(mats.Theme.surface_high, 0.9));
    if (f.val_on) {
        mats.roundedRect(.{ .x = x + 3, .y = by + 3, .w = s - 6, .h = s - 6 }, 3, mats.Theme.mint);
    }
    mats.roundedOutline(.{ .x = x, .y = by, .w = s, .h = s }, 4, mats.withAlpha(mats.Theme.stroke, 1.0), 1.0);
    if (g_ui.click_pending and inBox(g_ui.click_x, g_ui.click_y, x, by, s, s)) {
        f.val_on = !f.val_on;
    }
}

fn drawToggle(f: *schema.Flag, x: f32, cy: f32, acc: mats.Color) void {
    const tw: f32 = 52;
    const thh: f32 = 24;
    const by = cy + (FIELD_H - thh) * 0.5;
    const on = f.val_on;
    const track = if (on) mats.scaleRgb(acc, 0.9) else mats.Theme.surface_high;
    mats.roundedRect(.{ .x = x, .y = by, .w = tw, .h = thh }, thh * 0.5, track);
    const knob_x = if (on) x + tw - thh + 2 else x + 2;
    prim.circle(knob_x + (thh - 4) * 0.5, by + thh * 0.5, (thh - 6) * 0.5, c4(mats.Theme.text));
    if (g_ui.click_pending and inBox(g_ui.click_x, g_ui.click_y, x, by, tw, thh)) {
        f.val_on = !f.val_on;
    }
}

fn drawStepper(f: *schema.Flag, x: f32, cy: f32, wdt: f32, acc: mats.Color, _: bool) void {
    // enable checkbox
    drawEnable(f, x, cy);
    const fieldx = x + 26;
    const btn: f32 = 30;
    const dim = !f.val_on;
    const base_col = if (dim) mats.withAlpha(mats.Theme.surface, 0.6) else mats.withAlpha(mats.Theme.surface_raised, 0.95);
    // minus
    mats.roundedRect(.{ .x = fieldx, .y = cy, .w = btn, .h = FIELD_H }, 8, base_col);
    prim.line(fieldx + 9, cy + FIELD_H * 0.5, fieldx + btn - 9, cy + FIELD_H * 0.5, 1.5, c4(mats.Theme.text));
    // value box
    const vx = fieldx + btn + 4;
    const vw = wdt - 26 - btn * 2 - 8;
    mats.roundedRect(.{ .x = vx, .y = cy, .w = vw, .h = FIELD_H }, 8, base_col);
    var buf: [24]u8 = undefined;
    const s = fmtU64(&buf, f.val_int);
    const tw = g_font.measureString(s, 0.9);
    _ = g_font.drawString(s, vx + (vw - tw) * 0.5, cy + 8, 0.9, c4(if (dim) mats.Theme.text_muted else mats.Theme.text));
    // plus
    const px = vx + vw + 4;
    mats.roundedRect(.{ .x = px, .y = cy, .w = btn, .h = FIELD_H }, 8, base_col);
    prim.line(px + 9, cy + FIELD_H * 0.5, px + btn - 9, cy + FIELD_H * 0.5, 1.5, c4(mats.Theme.text));
    prim.line(px + btn * 0.5, cy + 9, px + btn * 0.5, cy + FIELD_H - 9, 1.5, c4(mats.Theme.text));
    _ = acc;

    if (!g_ui.click_pending) return;
    if (inBox(g_ui.click_x, g_ui.click_y, fieldx, cy, btn, FIELD_H)) {
        f.val_on = true;
        if (f.val_int >= f.int_min + f.int_step) f.val_int -= f.int_step else f.val_int = f.int_min;
    } else if (inBox(g_ui.click_x, g_ui.click_y, px, cy, btn, FIELD_H)) {
        f.val_on = true;
        if (f.val_int + f.int_step <= f.int_max) f.val_int += f.int_step else f.val_int = f.int_max;
    }
}

fn drawColor(f: *schema.Flag, x: f32, cy: f32, wdt: f32, acc: mats.Color) void {
    _ = acc;
    drawEnable(f, x, cy);
    const fieldx = x + 26;
    const dim = !f.val_on;
    // swatch
    const sw: f32 = 34;
    const swatch = mats.Color{
        @as(f32, @floatFromInt(f.val_r)) / 255.0,
        @as(f32, @floatFromInt(f.val_g)) / 255.0,
        @as(f32, @floatFromInt(f.val_b)) / 255.0,
        if (dim) 0.5 else 1.0,
    };
    mats.roundedRect(.{ .x = fieldx, .y = cy, .w = sw, .h = FIELD_H }, 8, swatch);
    mats.roundedOutline(.{ .x = fieldx, .y = cy, .w = sw, .h = FIELD_H }, 8, mats.withAlpha(mats.Theme.stroke, 1.0), 1.0);

    // Three channel steppers R G B, compact.
    const chan_w = (wdt - 26 - sw - 12) / 3.0;
    channel(f, 0, fieldx + sw + 8, cy, chan_w - 4, dim);
    channel(f, 1, fieldx + sw + 8 + chan_w, cy, chan_w - 4, dim);
    channel(f, 2, fieldx + sw + 8 + chan_w * 2, cy, chan_w - 4, dim);
}

fn channel(f: *schema.Flag, idx: u8, x: f32, cy: f32, wdt: f32, dim: bool) void {
    const base_col = if (dim) mats.withAlpha(mats.Theme.surface, 0.6) else mats.withAlpha(mats.Theme.surface_raised, 0.95);
    mats.roundedRect(.{ .x = x, .y = cy, .w = wdt, .h = FIELD_H }, 8, base_col);
    const label: []const u8 = switch (idx) {
        0 => "R",
        1 => "G",
        else => "B",
    };
    const tint: Color = switch (idx) {
        0 => rgba(1.0, 0.45, 0.5, 1.0),
        1 => rgba(0.4, 0.95, 0.6, 1.0),
        else => rgba(0.45, 0.7, 1.0, 1.0),
    };
    _ = g_font.drawString(label, x + 8, cy + 8, 0.78, tint);
    var buf: [8]u8 = undefined;
    const v: u64 = switch (idx) {
        0 => f.val_r,
        1 => f.val_g,
        else => f.val_b,
    };
    const s = fmtU64(&buf, v);
    _ = g_font.drawString(s, x + 26, cy + 8, 0.82, c4(if (dim) mats.Theme.text_muted else mats.Theme.text));
    // Click left half decrements, right half increments (wrap 0..255).
    if (!g_ui.click_pending) return;
    if (!inBox(g_ui.click_x, g_ui.click_y, x, cy, wdt, FIELD_H)) return;
    f.val_on = true;
    const inc = g_ui.click_x > x + wdt * 0.5;
    setChannel(f, idx, inc);
}

fn setChannel(f: *schema.Flag, idx: u8, inc: bool) void {
    const step: i32 = 8;
    var v: i32 = switch (idx) {
        0 => f.val_r,
        1 => f.val_g,
        else => f.val_b,
    };
    v += if (inc) step else -step;
    if (v < 0) v = 0;
    if (v > 255) v = 255;
    const u: u8 = @intCast(v);
    switch (idx) {
        0 => f.val_r = u,
        1 => f.val_g = u,
        else => f.val_b = u,
    }
}

fn drawChoice(f: *schema.Flag, x: f32, cy: f32, wdt: f32, acc: mats.Color) void {
    // A segmented control: one pill per choice.
    if (f.choices.len == 0) return;
    const gap: f32 = 6;
    const seg_w = (wdt - gap * @as(f32, @floatFromInt(f.choices.len - 1))) / @as(f32, @floatFromInt(f.choices.len));
    var i: usize = 0;
    var sx = x;
    while (i < f.choices.len) : (i += 1) {
        const sel = i == f.val_choice;
        const st: mats.Interaction = if (sel) .selected else .idle;
        if (sel) {
            mats.buttonSurface(.{ .x = sx, .y = cy, .w = seg_w, .h = FIELD_H }, 8, mats.scaleRgb(acc, 0.55), st);
        } else {
            mats.roundedRect(.{ .x = sx, .y = cy, .w = seg_w, .h = FIELD_H }, 8, mats.withAlpha(mats.Theme.surface_raised, 0.9));
        }
        const lbl = f.choices[i].label;
        const tw = g_font.measureString(lbl, 0.75);
        _ = g_font.drawString(lbl, sx + (seg_w - tw) * 0.5, cy + 9, 0.75, c4(mats.Theme.text));
        if (g_ui.click_pending and inBox(g_ui.click_x, g_ui.click_y, sx, cy, seg_w, FIELD_H)) {
            f.val_choice = i;
        }
        sx += seg_w + gap;
    }
}

fn drawTextField(cmd: *schema.Command, fi: usize, x: f32, cy: f32, wdt: f32, acc: mats.Color) void {
    const f = &cmd.flags[fi];
    const focused = g_ui.focus_flag == @as(isize, @intCast(fi));
    const box_col = mats.withAlpha(mats.Theme.surface_high, 0.95);
    mats.roundedRect(.{ .x = x, .y = cy, .w = wdt, .h = FIELD_H }, 8, box_col);
    mats.roundedOutline(.{ .x = x, .y = cy, .w = wdt, .h = FIELD_H }, 8, mats.withAlpha(if (focused) acc else mats.Theme.stroke, 1.0), if (focused) 1.6 else 1.0);

    const s = f.textSlice();
    if (s.len > 0) {
        _ = g_font.drawString(s, x + 10, cy + 8, 0.85, c4(mats.Theme.text));
    } else if (!focused) {
        const ph: []const u8 = if (f.kind == .path) "path…" else "type…";
        _ = g_font.drawString(ph, x + 10, cy + 8, 0.85, c4(mats.Theme.text_muted));
    }
    // Caret.
    if (focused) {
        const tw = g_font.measureString(s, 0.85);
        prim.line(x + 10 + tw + 1, cy + 6, x + 10 + tw + 1, cy + FIELD_H - 6, 1.5, c4(acc));
    }
    if (g_ui.click_pending and inBox(g_ui.click_x, g_ui.click_y, x, cy, wdt, FIELD_H)) {
        g_ui.focus_flag = @intCast(fi);
    }
}

fn drawLaunchBar(cmd: *schema.Command, x: f32, y: f32, wdt: f32, hh: f32, acc: mats.Color) void {
    _ = wdt;
    const bw: f32 = 190;
    const bx = x + 4;
    const forever = schema.runsForever(cmd);
    const running = g_ui.running;

    // Primary action button.
    const label = if (running) "Stop" else if (forever) "Launch (watch)" else "Run";
    const col = if (running) mats.Theme.danger else mats.scaleRgb(acc, 0.9);
    const hovered = inBox(g_ui.mouse_x, g_ui.mouse_y, bx, y, bw, hh);
    const st: mats.Interaction = if (hovered) .hover else .idle;
    mats.buttonSurface(.{ .x = bx, .y = y, .w = bw, .h = hh }, 12, col, st);
    const tw = g_font_big.measureString(label, 0.9);
    _ = g_font_big.drawString(label, bx + (bw - tw) * 0.5, y + hh * 0.5 - 8, 0.9, c4(mats.Theme.text));

    // Status text to the right.
    if (g_ui.launch_err != .none) {
        _ = g_font.drawString(errText(g_ui.launch_err), bx + bw + 16, y + hh * 0.5 - 6, 0.8, c4(mats.Theme.danger));
    } else if (g_ui.status_len > 0) {
        _ = g_font.drawString(g_ui.statusSlice(), bx + bw + 16, y + hh * 0.5 - 6, 0.8, c4(mats.Theme.text_muted));
    }

    if (g_ui.click_pending and inBox(g_ui.click_x, g_ui.click_y, bx, y, bw, hh)) {
        if (running) stopRunning() else launchSelected();
    }
}

fn drawConsole(x: f32, y: f32, wdt: f32, hh: f32) void {
    mats.panel(.{ .x = x, .y = y, .w = wdt, .h = hh }, 12, mats.Theme.canvas, mats.Theme.cyan, 2);
    _ = g_font.drawString("OUTPUT", x + 14, y + hh - 22, 0.72, c4(mats.Theme.text_muted));
    prim.scissorBegin(x + 8, y + 8, wdt - 16, hh - 34);
    var ly = y + hh - 40;
    if (g_ui.running) {
        _ = g_font.drawString("running… (Stop to end)", x + 14, ly, 0.82, c4(mats.Theme.mint));
    } else if (g_ui.have_result) {
        var buf: [64]u8 = undefined;
        const code = g_ui.result.exit_code;
        const head = codeLine(&buf, code);
        _ = g_font.drawString(head, x + 14, ly, 0.82, c4(if (code == 0) mats.Theme.mint else mats.Theme.amber));
        ly -= 20;
        ly = drawLines(g_ui.result.stdoutSlice(), x + 14, ly, 0.78, c4(mats.Theme.text));
        _ = drawLines(g_ui.result.stderrSlice(), x + 14, ly, 0.78, c4(mats.Theme.danger));
    } else {
        _ = g_font.drawString("no run yet", x + 14, ly, 0.8, c4(mats.Theme.text_muted));
    }
    prim.scissorEnd();
}

fn drawLines(text: []const u8, x: f32, y0: f32, scale: f32, color: Color) f32 {
    var y = y0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            _ = g_font.drawString(text[start..i], x, y, scale, color);
            y -= 18;
            start = i + 1;
            if (y < 0) return y;
        }
    }
    if (start < text.len) {
        _ = g_font.drawString(text[start..], x, y, scale, color);
        y -= 18;
    }
    return y;
}

// ── Actions ─────────────────────────────────────────────────────────
var g_scratch: [launch.SCRATCH]u8 = undefined;

fn launchSelected() void {
    const cmd = &g_registry[g_ui.selected];
    g_ui.launch_err = .none;
    g_ui.have_result = false;
    const p = launch.plan(cmd, g_self_dir[0..g_self_dir_len], &g_scratch);
    if (p.err != .none) {
        g_ui.launch_err = p.err;
        return;
    }
    if (p.kind == .spawned) {
        g_ui.handle = launch.spawnLong(g_io, &p);
        if (g_ui.handle == null) {
            g_ui.launch_err = .spawn_failed;
            return;
        }
        g_ui.running = true;
        g_ui.setStatus("process running");
    } else {
        g_ui.setStatus("running…");
        g_ui.result = launch.runOneShot(g_io, &p);
        g_ui.have_result = true;
        g_ui.setStatus("done");
    }
}

fn stopRunning() void {
    if (g_ui.handle) |*hnd| {
        _ = subprocess.kill(g_io, hnd);
        g_ui.handle = null;
    }
    g_ui.running = false;
    g_ui.setStatus("stopped");
}

// ── small formatters ────────────────────────────────────────────────
fn fmtU64(buf: []u8, v: u64) []const u8 {
    var tmp: [20]u8 = undefined;
    var tlen: usize = 0;
    var x = v;
    if (x == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    while (x > 0) : (x /= 10) {
        tmp[tlen] = @intCast('0' + (x % 10));
        tlen += 1;
    }
    var i: usize = 0;
    while (i < tlen) : (i += 1) buf[i] = tmp[tlen - 1 - i];
    return buf[0..tlen];
}

fn codeLine(buf: []u8, code: i32) []const u8 {
    const prefix = "exit code ";
    @memcpy(buf[0..prefix.len], prefix);
    var pos = prefix.len;
    var v: u64 = undefined;
    if (code < 0) {
        buf[pos] = '-';
        pos += 1;
        v = @intCast(-code);
    } else v = @intCast(code);
    const s = fmtU64(buf[pos..], v);
    return buf[0 .. pos + s.len];
}

fn errText(e: launch.LaunchError) []const u8 {
    return switch (e) {
        .none => "",
        .click_without_target => "click needs a target: enable color sig or template",
        .bad_binary => "could not find the tool binary",
        .spawn_failed => "failed to start the process",
        .too_many_args => "too many arguments",
        .missing_positional => "a required field is empty",
    };
}

// ── Self-dir resolution ─────────────────────────────────────────────
/// Fill g_self_dir with the directory of the launcher executable so sibling
/// binaries (stools, img2elementor) resolve next to it. Uses the process's
/// own exe path; falls back to "." if unavailable.
fn resolveSelfDir(io: std.Io) void {
    const n = std.process.executableDirPath(io, g_self_dir[0..]) catch {
        g_self_dir[0] = '.';
        g_self_dir_len = 1;
        return;
    };
    g_self_dir_len = n;
}

// ── Entry ───────────────────────────────────────────────────────────
pub fn main(init: std.process.Init) !void {
    g_io = init.io;
    g_registry = schema.buildRegistry();
    resolveSelfDir(init.io);

    var window = windowmod.Window.initWithConfig(
        w32.L("stools control"),
        WIN_W,
        WIN_H,
        &wndProc,
        OPACITY,
        stools_ico, // window + taskbar icon
    ) catch return error.WindowInitFailed;
    defer window.deinit();
    g_hwnd = window.hwnd;

    g_font = textmod.FontAtlas.init(w32.L("Segoe UI"), 15);
    g_font_big = textmod.FontAtlas.init(w32.L("Segoe UI Semibold"), 20);
    // In-GUI logo texture. 128px source frame keeps it crisp when drawn large.
    g_logo = iconmod.IconTexture.initFromIco(stools_ico.ptr, stools_ico.len, 128);
    defer g_logo.deinit();

    while (window.running) {
        window.pollEvents();
        if (!window.running) break;

        // If a spawned process exited on its own, reflect that.
        if (g_ui.running) {
            if (g_ui.handle) |*hnd| {
                if (hnd.child.id == null) {
                    g_ui.running = false;
                    g_ui.handle = null;
                }
            }
        }

        g_ui.width = window.width;
        g_ui.height = window.height;
        frame();
        window.swap();
        w32.Sleep(16);
    }
}

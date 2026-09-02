// stools img2elementor — reconstruct an Elementor template from a screenshot.
//
// Pipeline (all pure-Sig, powered by zpm's image + elementor modules):
//   1. read a PNG file
//   2. decode to RGBA8            (zpm png_decode)
//   3. detect the page background (zpm image)
//   4. segment into regions       (zpm layout)
//   5. estimate typography per region (zpm text_analyze)
//   6. map regions -> Elementor widgets and emit a template JSON (zpm elementor)
//   7. write the .json next to the input (or to the given output path)
//
// Honesty note: this reconstructs editable structure (containers, headings,
// text, buttons, image blocks) with estimated colors/sizes/alignment. Exact
// glyph text is not recoverable from a flat raster, so heading/text bodies are
// emitted as placeholders keyed to their measured size/weight — the operator
// fills the words. Geometry, color, and layout are the reliable output.
//
// Usage: img2elementor <input.png> [output.json]

const std = @import("std");
const png_decode = @import("png_decode");
const image = @import("image");
const layout = @import("layout");
const text_analyze = @import("text_analyze");
const elementor = @import("elementor_document");

// ── Static working buffers (no heap). Sized for up to ~4K-wide screenshots. ──
const MAX_PIXELS: usize = 3840 * 2400;
var file_buf: [16 * 1024 * 1024]u8 = undefined; // raw PNG file
var scratch_buf: [MAX_PIXELS]u8 = undefined; // concatenated IDAT
var raw_buf: [MAX_PIXELS * 5]u8 = undefined; // inflated filtered scanlines
var rgba_buf: [MAX_PIXELS * 4]u8 = undefined; // decoded RGBA8
var json_buf: [4 * 1024 * 1024]u8 = undefined; // emitted Elementor JSON
var row_scratch: [2400]u32 = undefined;
var col_scratch: [3840]u32 = undefined;
var regions: [512]layout.Region = undefined;

pub fn main(init: std.process.Init) !void {
    // Args are the one place a platform (Windows WTF-16 command line) can force
    // an allocation. Use the process arena — one-shot at startup, freed on exit,
    // never touched again. All image + JSON work below is fixed-buffer, no heap.
    var args = std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator()) catch
        std.process.fatal("cannot read command line", .{});
    defer args.deinit();

    _ = args.next(); // executable
    var in_storage: [4096]u8 = undefined;
    var out_storage: [4096]u8 = undefined;
    const input_path = copyArg(args.next(), &in_storage) orelse usage(init.io);
    const output_path = copyArg(args.next(), &out_storage); // optional

    // ── Read the PNG ──
    const cwd: std.Io.Dir = .cwd();
    const input = cwd.openFile(init.io, input_path, .{}) catch |err|
        std.process.fatal("cannot open '{s}': {t}", .{ input_path, err });
    defer input.close(init.io);
    const stat = input.stat(init.io) catch |err|
        std.process.fatal("cannot stat '{s}': {t}", .{ input_path, err });
    if (stat.size == 0) std.process.fatal("input is empty", .{});
    if (stat.size > file_buf.len) std.process.fatal("input is {d} bytes; max {d}", .{ stat.size, file_buf.len });

    var reader = input.reader(init.io, &.{});
    var got: u64 = 0;
    while (got < stat.size) {
        const want: usize = @intCast(@min(stat.size - got, file_buf.len - got));
        const n = reader.interface.readSliceShort(file_buf[@intCast(got)..][0..want]) catch |err|
            std.process.fatal("read error: {t}", .{err});
        if (n == 0) break;
        got += n;
    }
    const file_data = file_buf[0..@intCast(got)];

    // ── Decode ──
    const info = png_decode.readInfo(file_data) catch |err|
        std.process.fatal("not a valid PNG: {t}", .{err});
    if (@as(usize, info.width) * @as(usize, info.height) > MAX_PIXELS)
        std.process.fatal("image {d}x{d} exceeds max pixels", .{ info.width, info.height });

    const decoded = png_decode.decode(file_data, &scratch_buf, &raw_buf, &rgba_buf) catch |err|
        std.process.fatal("PNG decode failed: {t}", .{err});

    const img = image.Image.init(decoded.pixels, decoded.width, decoded.height);
    const bg = img.backgroundColor();

    // ── Segment ──
    const n_regions = layout.segment(img, bg, .{}, row_scratch[0..decoded.height], col_scratch[0..decoded.width], &regions);

    // ── Build the Elementor document ──
    var doc = elementor.Doc.init(&json_buf, "Reconstructed page");
    var bg_hex: [8]u8 = undefined;
    const page_bg = hex(bg, &bg_hex);
    doc.beginContainer(.{ .bg_color = page_bg });

    var i: usize = 0;
    while (i < n_regions) : (i += 1) {
        emitRegion(&doc, img, bg, regions[i]);
    }

    doc.endContainer();
    const json = doc.finish();
    if (doc.didOverflow()) std.process.fatal("output exceeded JSON buffer", .{});

    // ── Write output ──
    var default_out: [4096]u8 = undefined;
    const out_path = output_path orelse deriveOutputPath(input_path, &default_out);
    const out_file = cwd.createFile(init.io, out_path, .{}) catch |err|
        std.process.fatal("cannot create '{s}': {t}", .{ out_path, err });
    defer out_file.close(init.io);
    out_file.writeStreamingAll(init.io, json) catch |err|
        std.process.fatal("write error: {t}", .{err});

    report(init.io, decoded.width, decoded.height, n_regions, out_path, json.len);
}

/// Map one region to Elementor widget(s).
fn emitRegion(doc: *elementor.Doc, img: image.Image, bg: image.Rgba, region: layout.Region) void {
    var ink_hex: [8]u8 = undefined;
    var fill_hex: [8]u8 = undefined;
    const ink = hex(region.ink_color, &ink_hex);

    switch (region.kind) {
        .button => {
            // The button fill is its region color; the label color is the ink.
            var text_hex: [8]u8 = undefined;
            const label_color = hex(pickReadable(region.fill_color), &text_hex);
            const fill = hex(region.fill_color, &fill_hex);
            doc.button("Button", .{ .text_color = label_color, .bg_color = fill, .alignment = .left });
        },
        .text_line => {
            const stats = text_analyze.estimateText(img, region.rect, bg, 48, row_scratch[0..region.rect.h]);
            const al = mapAlign(stats.alignment);
            if (stats.font_px >= 30 or stats.bold) {
                // A prominent line -> heading. Level scales with size.
                const level = headingLevel(stats.font_px);
                const weight: []const u8 = if (stats.bold) "700" else "";
                doc.heading(placeholderFor(stats.font_px), .{
                    .level = level,
                    .color = ink,
                    .font_px = stats.font_px,
                    .weight = weight,
                    .alignment = al,
                });
            } else {
                doc.text(placeholderFor(stats.font_px), .{
                    .color = ink,
                    .font_px = stats.font_px,
                    .alignment = al,
                });
            }
        },
        .bar => {
            // A nav/divider bar -> a thin container tinted with its fill color.
            var bar_hex: [8]u8 = undefined;
            const fill = hex(region.fill_color, &bar_hex);
            doc.beginContainer(.{ .bg_color = fill });
            doc.endContainer();
        },
        .image_block, .unknown => {
            doc.imageBox(region.rect.w, region.rect.h);
        },
    }
}

// ── Helpers ──

fn copyArg(arg: ?[:0]const u8, storage: []u8) ?[]const u8 {
    const v = arg orelse return null;
    if (v.len == 0 or v.len > storage.len) return null;
    @memcpy(storage[0..v.len], v);
    return storage[0..v.len];
}

/// Format an Rgba as "#rrggbb" into `buf` (must be >= 7 bytes).
fn hex(c: image.Rgba, buf: []u8) []const u8 {
    const digits = "0123456789abcdef";
    buf[0] = '#';
    buf[1] = digits[c.r >> 4];
    buf[2] = digits[c.r & 0xf];
    buf[3] = digits[c.g >> 4];
    buf[4] = digits[c.g & 0xf];
    buf[5] = digits[c.b >> 4];
    buf[6] = digits[c.b & 0xf];
    return buf[0..7];
}

/// Choose black or white text for readability against a fill color.
fn pickReadable(fill: image.Rgba) image.Rgba {
    return if (fill.luma() < 140) .{ .r = 255, .g = 255, .b = 255 } else .{ .r = 17, .g = 17, .b = 17 };
}

fn mapAlign(a: text_analyze.Align) elementor.Align {
    return switch (a) {
        .left => .left,
        .center => .center,
        .right => .right,
    };
}

fn headingLevel(font_px: u32) elementor.HeaderSize {
    if (font_px >= 56) return .h1;
    if (font_px >= 40) return .h2;
    if (font_px >= 30) return .h3;
    if (font_px >= 24) return .h4;
    return .h5;
}

/// A size-keyed placeholder for the (unrecoverable) exact text.
fn placeholderFor(font_px: u32) []const u8 {
    if (font_px >= 56) return "Heading text";
    if (font_px >= 30) return "Subheading text";
    return "Body text";
}

fn deriveOutputPath(input_path: []const u8, buf: []u8) []const u8 {
    // Replace a trailing .png/.PNG with .json; else append .json.
    var base_len = input_path.len;
    if (input_path.len >= 4) {
        const ext = input_path[input_path.len - 4 ..];
        if (eqIgnoreCase(ext, ".png")) base_len = input_path.len - 4;
    }
    const suffix = ".json";
    if (base_len + suffix.len > buf.len) return "out.json";
    @memcpy(buf[0..base_len], input_path[0..base_len]);
    @memcpy(buf[base_len..][0..suffix.len], suffix);
    return buf[0 .. base_len + suffix.len];
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (lower(x) != lower(y)) return false;
    }
    return true;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn report(io: std.Io, width: u32, height: u32, n: usize, out_path: []const u8, json_len: usize) void {
    _ = io;
    std.debug.print(
        "img2elementor: {d}x{d}, {d} region(s) -> {s} ({d} bytes)\n",
        .{ width, height, n, out_path, json_len },
    );
}

fn usage(io: std.Io) noreturn {
    _ = io;
    std.debug.print("usage: img2elementor <input.png> [output.json]\n", .{});
    std.process.exit(2);
}

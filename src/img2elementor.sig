// stools img2elementor — reconstruct an Elementor template from a screenshot
// or a live URL.
//
// Pipeline (all pure-Sig, powered by zpm's image + elementor modules):
//   0. if the input is a URL, render it to a PNG   (zpm web_capture -> headless browser)
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
// Usage:
//   img2elementor <input.png> [output.json]      reconstruct from a local image
//   img2elementor <https://site> [output.json]   capture the URL, then reconstruct

const std = @import("std");
const png_decode = @import("png_decode");
const image = @import("image");
const layout = @import("layout");
const text_analyze = @import("text_analyze");
const elementor = @import("elementor_document");
const web_capture = @import("web_capture");

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
    const input_arg = copyArg(args.next(), &in_storage) orelse usage(init.io);
    // The second positional is the output path unless it's the --debug flag.
    var debug_dump = false;
    var out2_storage: [4096]u8 = undefined;
    var output_path = copyArg(args.next(), &out_storage); // optional
    if (output_path) |o| {
        if (eqIgnoreCase(o, "--debug")) {
            debug_dump = true;
            output_path = copyArg(args.next(), &out2_storage);
        }
    }
    if (copyArg(args.next(), &out2_storage)) |extra| {
        if (eqIgnoreCase(extra, "--debug")) debug_dump = true;
    }

    const cwd: std.Io.Dir = .cwd();

    // ── Resolve the input to a local PNG path. A URL is rendered to a temp PNG
    //    by a headless browser; a local path is used as-is. ──
    var captured_storage: [4096]u8 = undefined;
    const from_url = isUrl(input_arg);
    const input_path = if (from_url)
        captureUrl(init.io, input_arg, &captured_storage)
    else
        input_arg;
    // Remove the temp capture on the way out (only when we created it). The
    // capture path is absolute, so delete it via the absolute API.
    defer if (from_url) std.Io.Dir.deleteFileAbsolute(init.io, input_path) catch {};

    // ── Read the PNG ──
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
    const bg_model = image.backgroundModel(img);

    // ── Segment ──
    const n_regions = layout.segment(img, bg, .{}, row_scratch[0..decoded.height], col_scratch[0..decoded.width], &regions);

    // Optional region dump for tuning (pass --debug as the last argument).
    if (debug_dump) {
        var di: usize = 0;
        while (di < n_regions) : (di += 1) {
            const r = regions[di];
            std.debug.print(
                "  region[{d}] kind={s} x={d} y={d} w={d} h={d} lines={d} th={d} dens={d}\n",
                .{ di, @tagName(r.kind), r.rect.x, r.rect.y, r.rect.w, r.rect.h, r.line_count, r.text_height, r.ink_density_permille },
            );
        }
    }

    // ── Build the Elementor document ──
    var doc = elementor.Doc.init(&json_buf, "Reconstructed page");
    var bg_hex: [8]u8 = undefined;
    // Page background: the blended center of the model (represents a gradient
    // page more faithfully than a single corner).
    const page_bg = hex(bg_model.at(decoded.width / 2, decoded.height / 2), &bg_hex);
    doc.beginContainer(.{ .bg_color = page_bg });
    emitRows(&doc, img, bg_model, regions[0..n_regions], decoded.width);
    doc.endContainer();
    const json = doc.finish();
    if (doc.didOverflow()) std.process.fatal("output exceeded JSON buffer", .{});

    // ── Write output ──
    var default_out: [4096]u8 = undefined;
    const out_path = output_path orelse deriveOutputPath(input_arg, &default_out);
    const out_file = cwd.createFile(init.io, out_path, .{}) catch |err|
        std.process.fatal("cannot create '{s}': {t}", .{ out_path, err });
    defer out_file.close(init.io);
    out_file.writeStreamingAll(init.io, json) catch |err|
        std.process.fatal("write error: {t}", .{err});

    report(init.io, decoded.width, decoded.height, n_regions, out_path, json.len);
}

/// Group regions into horizontal rows (by vertical overlap) and emit each row.
/// A row with multiple horizontally-separated regions becomes a flex `row`
/// container so side-by-side content (nav items; hero text beside a photo) is
/// reconstructed side-by-side instead of collapsing into one vertical stack.
fn emitRows(doc: *elementor.Doc, img: image.Image, bg: image.BgModel, regions_in: []const layout.Region, page_w: u32) void {
    // Work on a local index order sorted by y (regions arrive roughly in reading
    // order already, but sort to be safe). Bounded copy; no heap.
    var order: [512]u16 = undefined;
    const n = @min(regions_in.len, order.len);
    for (0..n) |k| order[k] = @intCast(k);
    // Insertion sort by rect.y.
    var a: usize = 1;
    while (a < n) : (a += 1) {
        const key = order[a];
        const ky = regions_in[key].rect.y;
        var b: usize = a;
        while (b > 0 and regions_in[order[b - 1]].rect.y > ky) : (b -= 1) order[b] = order[b - 1];
        order[b] = key;
    }

    var i: usize = 0;
    while (i < n) {
        // Start a row with region `i`; absorb following regions that overlap it
        // vertically (their y-center falls within the row's y-span).
        const first = regions_in[order[i]];
        var row_top = first.rect.y;
        var row_bot = first.rect.bottom();
        var j = i + 1;
        while (j < n) : (j += 1) {
            const r = regions_in[order[j]];
            const cy = r.rect.centerY();
            if (cy >= row_top and cy <= row_bot) {
                if (r.rect.y < row_top) row_top = r.rect.y;
                if (r.rect.bottom() > row_bot) row_bot = r.rect.bottom();
            } else break;
        }
        const row = order[i..j];

        if (row.len == 1) {
            emitRegion(doc, img, bg, regions_in[row[0]]);
        } else {
            // Sort the row left->right by x.
            var rbuf: [64]u16 = undefined;
            const m = @min(row.len, rbuf.len);
            for (0..m) |k| rbuf[k] = row[k];
            var p: usize = 1;
            while (p < m) : (p += 1) {
                const key = rbuf[p];
                const kx = regions_in[key].rect.x;
                var q: usize = p;
                while (q > 0 and regions_in[rbuf[q - 1]].rect.x > kx) : (q -= 1) rbuf[q] = rbuf[q - 1];
                rbuf[q] = key;
            }
            emitRow(doc, img, bg, regions_in, rbuf[0..m], page_w);
        }
        i = j;
    }
}

/// Emit a row of regions (already sorted left->right). If the row pairs a large
/// image with a cluster of text (a classic hero), split it into a stacked text
/// column beside the image so the headline lines stack vertically next to the
/// photo — instead of every line sitting horizontally.
fn emitRow(doc: *elementor.Doc, img: image.Image, bg: image.BgModel, regions_in: []const layout.Region, row: []const u16, page_w: u32) void {
    // Find a dominant large image in the row.
    var big_img: ?usize = null; // index into `row`
    var big_area: u32 = 0;
    for (row, 0..) |ri, idx| {
        const r = regions_in[ri];
        if (r.kind == .image_block and r.rect.w >= page_w / 5 and r.rect.h >= 200) {
            const ar = r.rect.area();
            if (ar > big_area) {
                big_area = ar;
                big_img = idx;
            }
        }
    }

    doc.beginContainer(.{ .direction = .row, .align_items = "center" });

    if (big_img) |bi| {
        const img_region = regions_in[row[bi]];
        const img_on_right = img_region.rect.centerX() >= page_w / 2;
        if (img_on_right) {
            emitTextColumn(doc, img, bg, regions_in, row, bi);
            emitRegion(doc, img, bg, img_region);
        } else {
            emitRegion(doc, img, bg, img_region);
            emitTextColumn(doc, img, bg, regions_in, row, bi);
        }
    } else {
        for (row) |ri| emitRegion(doc, img, bg, regions_in[ri]);
    }

    doc.endContainer();
}

/// Emit all regions in `row` except the one at `skip_idx`, stacked vertically
/// inside a column container. Consecutive text regions whose estimated font
/// size is similar are coalesced into a single multi-line heading, so a
/// headline that segmented into several lines reads as one heading rather than
/// a stack of one-liners.
fn emitTextColumn(doc: *elementor.Doc, img: image.Image, bg: image.BgModel, regions_in: []const layout.Region, row: []const u16, skip_idx: usize) void {
    doc.beginContainer(.{ .direction = .column });

    var idx: usize = 0;
    while (idx < row.len) {
        if (idx == skip_idx) {
            idx += 1;
            continue;
        }
        const region = regions_in[row[idx]];
        // Only text-like kinds are candidates for merging.
        if (region.kind == .heading or region.kind == .text_line) {
            const stats = text_analyze.estimateTextBg(img, region.rect, bg, 72, row_scratch[0..region.rect.h]);
            // Extend the run over following text regions of similar size.
            var last = idx;
            var total_lines: u32 = stats.line_count;
            var j = idx + 1;
            while (j < row.len and j != skip_idx) : (j += 1) {
                const r2 = regions_in[row[j]];
                if (r2.kind != .heading and r2.kind != .text_line) break;
                const s2 = text_analyze.estimateTextBg(img, r2.rect, bg, 72, row_scratch[0..r2.rect.h]);
                if (!fontsSimilar(stats.font_px, s2.font_px)) break;
                last = j;
                total_lines += s2.line_count;
            }
            var ink_hex: [8]u8 = undefined;
            const ink = hex(region.ink_color, &ink_hex);
            if (stats.font_px >= 30 or stats.bold) {
                const weight: []const u8 = if (stats.bold) "700" else "";
                doc.heading(headingPlaceholder(total_lines, stats.font_px), .{
                    .level = headingLevel(stats.font_px),
                    .color = ink,
                    .font_px = stats.font_px,
                    .weight = weight,
                    .alignment = mapAlign(stats.alignment),
                });
            } else {
                doc.text(placeholderFor(stats.font_px), .{
                    .color = ink,
                    .font_px = stats.font_px,
                    .alignment = mapAlign(stats.alignment),
                });
            }
            idx = last + 1;
        } else {
            emitRegion(doc, img, bg, region);
            idx += 1;
        }
    }

    doc.endContainer();
}

/// Two font sizes are "similar" if within ~20% of the larger — good enough to
/// treat consecutive lines as one heading block.
fn fontsSimilar(a: u32, b: u32) bool {
    if (a == 0 or b == 0) return false;
    const hi = @max(a, b);
    const lo = @min(a, b);
    return (hi - lo) * 5 <= hi; // <=20% difference
}

fn headingPlaceholder(lines: u32, font_px: u32) []const u8 {
    if (lines >= 2) return "Multi-line heading text";
    return placeholderFor(font_px);
}

/// Map one region to Elementor widget(s). Uses the gradient-aware background
/// model so text stats and colors are measured against the local background.
fn emitRegion(doc: *elementor.Doc, img: image.Image, bg: image.BgModel, region: layout.Region) void {
    var ink_hex: [8]u8 = undefined;
    var fill_hex: [8]u8 = undefined;
    const ink = hex(region.ink_color, &ink_hex);

    switch (region.kind) {
        .button => {
            // The button fill is its region color; the label color is the ink.
            var text_hex: [8]u8 = undefined;
            const label_color = hex(pickReadable(region.fill_color), &text_hex);
            const fill = hex(region.fill_color, &fill_hex);
            doc.button("Button", .{ .text_color = label_color, .bg_color = fill, .alignment = .center });
        },
        .heading => {
            const stats = text_analyze.estimateTextBg(img, region.rect, bg, 72, row_scratch[0..region.rect.h]);
            const weight: []const u8 = if (stats.bold) "700" else "";
            doc.heading(placeholderFor(stats.font_px), .{
                .level = headingLevel(stats.font_px),
                .color = ink,
                .font_px = stats.font_px,
                .weight = weight,
                .alignment = mapAlign(stats.alignment),
            });
        },
        .eyebrow => {
            // A small label above a heading -> a short uppercase heading (h6).
            const stats = text_analyze.estimateTextBg(img, region.rect, bg, 72, row_scratch[0..region.rect.h]);
            doc.heading("LABEL", .{
                .level = .h6,
                .color = ink,
                .font_px = stats.font_px,
                .weight = "600",
                .alignment = mapAlign(stats.alignment),
            });
        },
        .body_text => {
            const stats = text_analyze.estimateTextBg(img, region.rect, bg, 72, row_scratch[0..region.rect.h]);
            doc.text(bodyPlaceholder(stats.line_count), .{
                .color = ink,
                .font_px = stats.font_px,
                .alignment = mapAlign(stats.alignment),
            });
        },
        .text_line => {
            const stats = text_analyze.estimateTextBg(img, region.rect, bg, 72, row_scratch[0..region.rect.h]);
            if (stats.font_px >= 30 or stats.bold) {
                const weight: []const u8 = if (stats.bold) "700" else "";
                doc.heading(placeholderFor(stats.font_px), .{
                    .level = headingLevel(stats.font_px),
                    .color = ink,
                    .font_px = stats.font_px,
                    .weight = weight,
                    .alignment = mapAlign(stats.alignment),
                });
            } else {
                doc.text(placeholderFor(stats.font_px), .{
                    .color = ink,
                    .font_px = stats.font_px,
                    .alignment = mapAlign(stats.alignment),
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

fn bodyPlaceholder(line_count: u32) []const u8 {
    return if (line_count >= 3) "Body paragraph text spanning several lines." else "Body text";
}

// ── Helpers ──

/// True if the argument looks like an http(s) URL.
fn isUrl(s: []const u8) bool {
    return startsWithIgnoreCase(s, "http://") or startsWithIgnoreCase(s, "https://");
}

/// Heuristic: a path is Windows-style if it starts with a drive letter
/// (e.g. "C:") or already contains a backslash.
fn isWindowsPath(p: []const u8) bool {
    if (p.len >= 2 and p[1] == ':') return true;
    for (p) |c| {
        if (c == '\\') return true;
    }
    return false;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (s[0..prefix.len], prefix) |a, b| {
        if (lower(a) != lower(b)) return false;
    }
    return true;
}

/// Render a URL to a temp PNG via a headless browser and return the PNG path.
/// The path lives in `storage`. Fatal on capture failure — there is nothing
/// downstream can do without pixels.
///
/// The browser requires an ABSOLUTE screenshot path (a relative one is denied
/// or silently ignored), so resolve the temp file against the current
/// directory before handing it to web_capture.
fn captureUrl(io: std.Io, url: []const u8, storage: []u8) []const u8 {
    const name = "img2elementor-capture.png";
    var cwd_buf: [3072]u8 = undefined;
    const dir_len = std.process.currentPath(io, &cwd_buf) catch
        std.process.fatal("cannot resolve working directory for capture", .{});
    const dir = cwd_buf[0..dir_len];

    // Join "<cwd>/<name>" into storage.
    const sep_len: usize = 1;
    if (dir.len + sep_len + name.len > storage.len) std.process.fatal("capture path too long", .{});
    @memcpy(storage[0..dir.len], dir);
    storage[dir.len] = if (isWindowsPath(dir)) '\\' else '/';
    @memcpy(storage[dir.len + sep_len ..][0..name.len], name);
    const out = storage[0 .. dir.len + sep_len + name.len];

    std.debug.print("img2elementor: capturing {s} ...\n", .{url});
    const shot = web_capture.capture(io, .{
        .url = url,
        .output_path = out,
        .width = 1440,
        .height = 2400,
    });
    if (!shot.ok) {
        switch (shot.err) {
            .no_browser_found => std.process.fatal(
                "no headless browser found (install Chrome/Edge/Chromium) to capture a URL",
                .{},
            ),
            .browser_error => std.process.fatal(
                "browser '{s}' failed to capture the page (exit {d})",
                .{ shot.browser_used, shot.exit_code },
            ),
            .spawn_failed => std.process.fatal("could not launch browser '{s}'", .{shot.browser_used}),
            else => std.process.fatal("URL capture failed", .{}),
        }
    }
    std.debug.print("img2elementor: captured via {s} -> {s}\n", .{ shot.browser_used, out });
    return out;
}

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

fn deriveOutputPath(input: []const u8, buf: []u8) []const u8 {
    const suffix = ".json";
    // For a URL, name the file after the host (e.g. https://ela.sb0.tech/ ->
    // ela.sb0.tech.json), so a URL run leaves a readable artifact.
    if (isUrl(input)) {
        const host = urlHost(input);
        var n: usize = 0;
        for (host) |c| {
            if (n >= buf.len - suffix.len) break;
            buf[n] = if (isSafeNameChar(c)) c else '_';
            n += 1;
        }
        if (n == 0 or n + suffix.len > buf.len) return "out.json";
        @memcpy(buf[n..][0..suffix.len], suffix);
        return buf[0 .. n + suffix.len];
    }

    // Replace a trailing .png/.PNG with .json; else append .json.
    var base_len = input.len;
    if (input.len >= 4) {
        const ext = input[input.len - 4 ..];
        if (eqIgnoreCase(ext, ".png")) base_len = input.len - 4;
    }
    if (base_len + suffix.len > buf.len) return "out.json";
    @memcpy(buf[0..base_len], input[0..base_len]);
    @memcpy(buf[base_len..][0..suffix.len], suffix);
    return buf[0 .. base_len + suffix.len];
}

/// Extract the host portion of an http(s) URL (between "://" and the next "/").
fn urlHost(url: []const u8) []const u8 {
    var start: usize = 0;
    if (startsWithIgnoreCase(url, "https://")) start = 8 else if (startsWithIgnoreCase(url, "http://")) start = 7;
    var end = start;
    while (end < url.len and url[end] != '/') : (end += 1) {}
    return url[start..end];
}

fn isSafeNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '.' or c == '-' or c == '_';
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
    std.debug.print(
        \\usage: img2elementor <input> [output.json]
        \\  <input> is a local .png path or an http(s):// URL.
        \\  A URL is rendered to a PNG by a headless browser (Chrome/Edge/Chromium),
        \\  then reconstructed into an Elementor template.
        \\
    , .{});
    std.process.exit(2);
}

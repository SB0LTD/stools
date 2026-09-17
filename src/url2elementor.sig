// stools url2elementor — reconstruct an Elementor template from a *live URL*.
//
// URL-only. Unlike img2elementor (which reads a flat PNG and can only recover
// geometry + placeholders), this drives a real headless browser over the
// DevTools Protocol and reads the *rendered* DOM — so the output carries the
// page's real text, images, colors, fonts, and layout. That is what makes the
// reconstruction look like the source rather than a wireframe.
//
// Pipeline (all pure-Sig, powered by the zpm websocket + cdp + elementor stack):
//   1. launch a headless browser with the remote debugging port  (zpm cdp)
//   2. attach to its page target over a pure-Sig WebSocket        (zpm websocket)
//   3. navigate to the URL and wait for load                      (zpm cdp)
//   4. evaluate the in-page extractor, which builds the Elementor
//      content array from computed styles + geometry + text + images
//                                                                 (zpm dom_import)
//   5. wrap it in the Elementor document envelope and write .json (zpm dom_import)
//
// Usage:
//   url2elementor <https://site> [output.json] [--port N] [--keep-open]

const std = @import("std");
const cdp = @import("cdp");
const dom_import = @import("elementor_dom_import");

// ── Static working buffers (no heap). ──
// Clone mode captures the whole rendered document + inlined CSS, which is much
// larger than the widget-decomposition JSON, so these are sized generously.
// recv bounds the largest CDP message we can read back.
var recv_buf: [64 * 1024 * 1024]u8 = undefined; // websocket receive / captured page
var ws_scratch: [8 * 1024]u8 = undefined; // websocket handshake
var http_buf: [64 * 1024]u8 = undefined; // /json target discovery
var request_buf: [1 * 1024 * 1024]u8 = undefined; // JSON-RPC request (holds the extractor JS)
var content_buf: [64 * 1024 * 1024]u8 = undefined; // decoded extractor result (page HTML or content array)
var doc_buf: [80 * 1024 * 1024]u8 = undefined; // final Elementor document (page escaped twice)

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator()) catch
        std.process.fatal("cannot read command line", .{});
    defer args.deinit();

    _ = args.next(); // executable

    var url_storage: [4096]u8 = undefined;
    var out_storage: [4096]u8 = undefined;
    var url: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var port: u16 = 9222;
    var keep_open = false;
    // Default is `clone`: a pixel-perfect capture of the rendered page (CSS +
    // JS + animations) wrapped in one Elementor HTML widget (iframe srcdoc).
    // `--widgets` opts into the editable widget-decomposition instead.
    var clone = true;

    // Parse: first positional is the URL, second is the output path; flags
    // --port N, --keep-open, --widgets/--clone may appear anywhere.
    while (args.next()) |raw| {
        if (eqIgnoreCase(raw, "--keep-open")) {
            keep_open = true;
        } else if (eqIgnoreCase(raw, "--widgets")) {
            clone = false;
        } else if (eqIgnoreCase(raw, "--clone")) {
            clone = true;
        } else if (eqIgnoreCase(raw, "--port")) {
            const v = args.next() orelse usage(io);
            port = parsePort(v) orelse std.process.fatal("bad --port value", .{});
        } else if (url == null) {
            url = copyArg(raw, &url_storage);
        } else if (output_path == null) {
            output_path = copyArg(raw, &out_storage);
        }
    }

    const target = url orelse usage(io);
    if (!isUrl(target)) std.process.fatal(
        "url2elementor takes an http(s):// URL. For a local PNG use img2elementor.",
        .{},
    );

    // A throwaway profile so we never touch the operator's real browser data.
    var profile_storage: [4096]u8 = undefined;
    const profile = tempProfileDir(io, &profile_storage);

    // ── 1–2. Launch the browser and attach to its page target. ──
    std.debug.print("url2elementor: launching headless browser (port {d}) ...\n", .{port});
    var browser = cdp.Browser.launch(io, .{
        .port = port,
        .width = 1440,
        .height = 2200,
        .user_data_dir = profile,
        // SPA sites paint images/fonts after load; give them time to settle.
        .settle_ms = 2500,
    }) catch |err| switch (err) {
        cdp.Error.NoBrowserFound => std.process.fatal(
            "no headless browser found (install Chrome/Edge/Chromium/Brave)",
            .{},
        ),
        else => std.process.fatal("could not launch/attach to browser: {t}", .{err}),
    };
    defer if (!keep_open) browser.shutdown(io);

    var bufs = cdp.Browser.PageBuffers{
        .recv = &recv_buf,
        .scratch = &ws_scratch,
        .http = &http_buf,
        .request = &request_buf,
    };
    var page = browser.attach(io, &bufs) catch |err|
        std.process.fatal("could not open a CDP page session: {t}", .{err});
    defer page.close(io);

    // ── 3. Navigate and wait for load. ──
    std.debug.print("url2elementor: navigating to {s} ...\n", .{target});
    page.navigate(io, target) catch |err|
        std.process.fatal("navigation failed: {t}", .{err});

    // ── 4. Run the extractor in the page. ──
    // Clone mode captures the whole rendered document (pixel-perfect + JS);
    // widget mode decomposes it into editable Elementor widgets.
    const extractor = if (clone) dom_import.clone_extractor_js else dom_import.extractor_js;
    const content = page.evaluate(io, extractor, &content_buf) catch |err|
        std.process.fatal("extraction failed: {t}", .{err});
    if (content.len == 0) std.process.fatal("extractor returned no content", .{});

    // ── 5. Wrap into a full Elementor document and write it. ──
    var title_storage: [256]u8 = undefined;
    const title = deriveTitle(target, &title_storage);
    const doc = (if (clone)
        dom_import.wrapHtmlWidget(&doc_buf, title, content)
    else
        dom_import.wrap(&doc_buf, title, content)) orelse
        std.process.fatal("document exceeded output buffer", .{});

    var default_out: [4096]u8 = undefined;
    const out_path = output_path orelse deriveOutputPath(target, &default_out);

    const cwd: std.Io.Dir = .cwd();
    const out_file = cwd.createFile(io, out_path, .{}) catch |err|
        std.process.fatal("cannot create '{s}': {t}", .{ out_path, err });
    defer out_file.close(io);
    out_file.writeStreamingAll(io, doc) catch |err|
        std.process.fatal("write error: {t}", .{err});

    std.debug.print(
        "url2elementor: {s} -> {s} ({s} mode, {d} bytes, {d}-byte capture)\n",
        .{ target, out_path, if (clone) "clone" else "widgets", doc.len, content.len },
    );
}

// ── Helpers ──

fn isUrl(s: []const u8) bool {
    return startsWithIgnoreCase(s, "http://") or startsWithIgnoreCase(s, "https://");
}

fn parsePort(s: []const u8) ?u16 {
    var v: u32 = 0;
    if (s.len == 0) return null;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        if (v > 65535) return null;
    }
    return @intCast(v);
}

/// Resolve a throwaway profile directory next to the current working directory,
/// so the headless run never shares (and clobbers) the operator's real browser
/// profile. A relative path is accepted by every Chromium build; the browser
/// creates it if missing.
fn tempProfileDir(io: std.Io, storage: []u8) []const u8 {
    _ = io;
    const name = ".u2e-profile";
    if (name.len > storage.len) return "";
    @memcpy(storage[0..name.len], name);
    return storage[0..name.len];
}

fn deriveTitle(url: []const u8, buf: []u8) []const u8 {
    const host = urlHost(url);
    const prefix = "Reconstructed: ";
    var n: usize = 0;
    for (prefix) |c| {
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    for (host) |c| {
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn deriveOutputPath(url: []const u8, buf: []u8) []const u8 {
    const suffix = ".json";
    const host = urlHost(url);
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

fn copyArg(v: []const u8, storage: []u8) ?[]const u8 {
    if (v.len == 0 or v.len > storage.len) return null;
    @memcpy(storage[0..v.len], v);
    return storage[0..v.len];
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (s[0..prefix.len], prefix) |a, b| {
        if (lower(a) != lower(b)) return false;
    }
    return true;
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

fn usage(io: std.Io) noreturn {
    _ = io;
    std.debug.print(
        \\usage: url2elementor <https://site> [output.json] [flags]
        \\  Renders the live page in a headless browser and builds an Elementor
        \\  template from it, importable via Templates -> Import.
        \\
        \\  --clone      (default) pixel-perfect: capture the rendered page (CSS +
        \\               JS + animations) into one full-width Elementor HTML
        \\               widget (an <iframe srcdoc>). Looks and behaves like the
        \\               source, but is one block, not editable widgets.
        \\  --widgets    editable: decompose the DOM into Elementor widgets
        \\               (headings, text, buttons, images). Editable, but an
        \\               approximation — no original CSS/JS/animations.
        \\  --port N     remote debugging port to use (default 9222)
        \\  --keep-open  leave the browser running after extraction (debugging)
        \\
    , .{});
    std.process.exit(2);
}

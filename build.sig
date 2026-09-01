const sig_build = @import("sig_build");
const builtin = @import("builtin");

fn noop(ctx: *sig_build.Step_Context) sig_build.SigError!void { _ = ctx; }

// zpm is a path dependency (see build.sig.zon). Consume its reusable modules
// directly by source path — general capability lives in zpm, not here.
// zpm is consumed as a sibling path dependency (see build.sig.zon), matching
// the layout other SB0 projects use and how CI checks both repos out side by
// side. Reusable capability lives in zpm; this project only orchestrates it.
const ZPM = "../zpm/";

fn importEntry(name: []const u8, path: []const u8) sig_build.Import_Entry {
    var entry: sig_build.Import_Entry = .{};
    @memcpy(entry.name[0..name.len], name);
    entry.name_len = name.len;
    @memcpy(entry.path[0..path.len], path);
    entry.path_len = path.len;
    return entry;
}

fn wire(ctx: *sig_build.Build_Context, module: sig_build.Module_Handle, name: []const u8, path: []const u8) !void {
    try ctx.addImport(module, name, path);
}

fn runApp(ctx: *sig_build.Step_Context) sig_build.SigError!void {
    const build_ctx = ctx.build_ctx;
    const prefix = build_ctx.install_prefix[0..build_ctx.install_prefix_len];
    const suffix = if (builtin.os.tag == .windows) "/bin/stools.exe" else "/bin/stools";
    var path: [sig_build.PATH_BUF_SIZE]u8 = undefined;
    if (prefix.len + suffix.len > path.len) return error.BufferTooSmall;
    @memcpy(path[0..prefix.len], prefix);
    @memcpy(path[prefix.len .. prefix.len + suffix.len], suffix);
    var command: sig_build.Command_Buffer = .{};
    try command.appendArg(path[0 .. prefix.len + suffix.len]);
    var stderr: [sig_build.STDERR_CAPTURE_SIZE]u8 = undefined;
    var stderr_len: usize = 0;
    const exit_code = try sig_build.runCommand(&command, &stderr, &stderr_len, ctx.io);
    if (exit_code != 0) {
        sig_build.printMsg(ctx.io, "application failed: {s}", .{stderr[0..stderr_len]});
        return error.BufferTooSmall;
    }
}

pub fn build(ctx: *sig_build.Build_Context) !void {
    const win32_path = if (builtin.os.tag == .windows)
        ZPM ++ "src/platform/win32.sig"
    else
        ZPM ++ "src/transport/linux_platform.sig";

    // Register the zpm modules we consume and wire their own imports so the
    // flat module registry resolves nested `@import("win32")` inside screencap.
    //   main -> slicker -> { screencap -> win32, ui_detect }
    _ = try ctx.addModule("win32", win32_path);
    _ = try ctx.addModule("ui_detect", ZPM ++ "src/core/ui_detect.sig");
    const screencap = try ctx.addModule("screencap", ZPM ++ "src/platform/screencap.sig");
    try wire(ctx, screencap, "win32", win32_path);

    const app_imports = [_]sig_build.Import_Entry{
        importEntry("screencap", ZPM ++ "src/platform/screencap.sig"),
        importEntry("ui_detect", ZPM ++ "src/core/ui_detect.sig"),
        importEntry("win32", win32_path),
    };

    const executable = try ctx.addCompileStep(.{
        .source_path = "src/main.sig",
        .output_name = "stools",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = null,
        .imports = &app_imports,
        .compiler_path = "",
    });
    const install = try ctx.addStep("install", "Build the native application", &noop);
    try ctx.addDependency(install, executable);
    const run = try ctx.addStep("run", "Build and run the native application", &runApp);
    try ctx.addDependency(run, executable);

    const test_all = try ctx.addStep("test", "Run the project tests", &noop);
    const tests = try ctx.addTestStep(.{ .name = "test-source", .source_path = "src/main.sig", .imports = &app_imports });
    try ctx.addDependency(test_all, tests);
}

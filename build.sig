const sig_build = @import("sig_build");
const builtin = @import("builtin");

fn noop(ctx: *sig_build.Step_Context) sig_build.SigError!void { _ = ctx; }

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
    const executable = try ctx.addCompileStep(.{
        .source_path = "src/main.sig",
        .output_name = "stools",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = null,
        .imports = &.{},
        .compiler_path = "",
    });
    const install = try ctx.addStep("install", "Build the native application", &noop);
    try ctx.addDependency(install, executable);
    const run = try ctx.addStep("run", "Build and run the native application", &runApp);
    try ctx.addDependency(run, executable);
    const test_all = try ctx.addStep("test", "Run the project tests", &noop);
    const tests = try ctx.addTestStep(.{ .name = "test-source", .source_path = "src/main.sig", .imports = &.{} });
    try ctx.addDependency(test_all, tests);
}

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
    // Always wire the real win32 FFI module. Its extern declarations are inert
    // (never referenced) unless the screencap backend selects the Windows path
    // at comptime for a Windows TARGET — so it compiles cleanly on any build
    // host. Keying this off the host `builtin.os.tag` was wrong: cross-compiling
    // to a Windows target from a Linux CI host must still provide real win32.
    const win32_path = ZPM ++ "src/platform/win32.sig";

    // The app icon is a Win32 resource (.rc), which the compiler only accepts
    // for COFF/Windows targets. Attach it ONLY when the effective target is
    // Windows: either an explicit `-Dtarget=...-windows-...` or (no -Dtarget) a
    // Windows build host. On any other target (the release CI cross-compiles to
    // linux/macos/sb0) attaching a .rc is a hard error, so we pass "" there.
    const targeting_windows = blk: {
        if (ctx.target.os_len > 0) {
            if (ctx.target.os_len < 7) break :blk false;
            const os = ctx.target.os[0..7];
            break :blk os[0] == 'w' and os[1] == 'i' and os[2] == 'n' and os[3] == 'd' and
                os[4] == 'o' and os[5] == 'w' and os[6] == 's';
        }
        break :blk builtin.os.tag == .windows;
    };
    const app_rc: []const u8 = if (targeting_windows) "src/stools.rc" else "";

    // Register the zpm modules we consume and wire their own imports so the
    // flat module registry resolves nested `@import("win32")` inside screencap.
    //   main -> slicker -> { screencap -> win32, ui_detect }
    _ = try ctx.addModule("win32", win32_path);
    _ = try ctx.addModule("ui_detect", ZPM ++ "src/core/ui_detect.sig");
    const screencap = try ctx.addModule("screencap", ZPM ++ "src/platform/screencap.sig");
    try wire(ctx, screencap, "win32", win32_path);

    // slicker's --template mode loads a PNG and matches it across windows, so
    // stools also consumes the zpm PNG decoder (Layer 0). png_decode depends on
    // inflate; register both before the compile step and wire the nested import
    // so the flat registry resolves png_decode -> inflate.
    _ = try ctx.addModule("inflate", ZPM ++ "src/core/inflate.sig");
    const app_png_decode = try ctx.addModule("png_decode", ZPM ++ "src/image/png_decode.sig");
    try wire(ctx, app_png_decode, "inflate", ZPM ++ "src/core/inflate.sig");

    const app_imports = [_]sig_build.Import_Entry{
        importEntry("screencap", ZPM ++ "src/platform/screencap.sig"),
        importEntry("ui_detect", ZPM ++ "src/core/ui_detect.sig"),
        importEntry("win32", win32_path),
        importEntry("png_decode", ZPM ++ "src/image/png_decode.sig"),
        importEntry("inflate", ZPM ++ "src/core/inflate.sig"),
    };

    const executable = try ctx.addCompileStep(.{
        .source_path = "src/main.sig",
        .output_name = "stools",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = null,
        .imports = &app_imports,
        .compiler_path = "",
        // Native app icon (icon id 1 → src/stools.ico).
        .win32_resource = app_rc,
    });
    const install = try ctx.addStep("install", "Build the native application", &noop);
    try ctx.addDependency(install, executable);
    const run = try ctx.addStep("run", "Build and run the native application", &runApp);
    try ctx.addDependency(run, executable);

    // ── img2elementor: reconstruct an Elementor template from a screenshot ──
    // Consumes the zpm image-analysis + elementor modules. inflate + png_decode
    // are already registered (and wired png_decode -> inflate) above for the
    // slicker --template path; here we add the remaining image/elementor
    // modules and wire layout/text_analyze -> image.
    _ = try ctx.addModule("image", ZPM ++ "src/image/image.sig");
    const layout = try ctx.addModule("layout", ZPM ++ "src/image/layout.sig");
    try wire(ctx, layout, "image", ZPM ++ "src/image/image.sig");
    const text_analyze = try ctx.addModule("text_analyze", ZPM ++ "src/image/text_analyze.sig");
    try wire(ctx, text_analyze, "image", ZPM ++ "src/image/image.sig");
    _ = try ctx.addModule("elementor_document", ZPM ++ "src/elementor/document.sig");

    // img2elementor is PNG-only: it consumes just the image-analysis +
    // elementor modules. (URL/DOM reconstruction lives in url2elementor below,
    // which is the tool that drives a headless browser.)
    const img_imports = [_]sig_build.Import_Entry{
        importEntry("png_decode", ZPM ++ "src/image/png_decode.sig"),
        importEntry("inflate", ZPM ++ "src/core/inflate.sig"),
        importEntry("image", ZPM ++ "src/image/image.sig"),
        importEntry("layout", ZPM ++ "src/image/layout.sig"),
        importEntry("text_analyze", ZPM ++ "src/image/text_analyze.sig"),
        importEntry("elementor_document", ZPM ++ "src/elementor/document.sig"),
    };
    const img2elementor = try ctx.addCompileStep(.{
        .source_path = "src/img2elementor.sig",
        .output_name = "img2elementor",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = null,
        .imports = &img_imports,
        .compiler_path = "",
        // Native app icon (icon id 1 → src/stools.ico).
        .win32_resource = app_rc,
    });
    try ctx.addDependency(install, img2elementor);

    // ── url2elementor: reconstruct an Elementor template from a live URL ──
    // Drives a headless browser over the DevTools Protocol and reads the
    // rendered DOM. The whole transport is pure-Sig and lives in zpm:
    //   url2elementor -> cdp -> { subprocess, websocket }
    //                 -> elementor_dom_import
    // Register the modules and wire cdp's nested imports so the flat registry
    // resolves cdp -> subprocess and cdp -> websocket.
    _ = try ctx.addModule("subprocess", ZPM ++ "src/platform/subprocess.sig");
    _ = try ctx.addModule("websocket", ZPM ++ "src/net/websocket.sig");
    const u2e_cdp = try ctx.addModule("cdp", ZPM ++ "src/platform/cdp.sig");
    try wire(ctx, u2e_cdp, "subprocess", ZPM ++ "src/platform/subprocess.sig");
    try wire(ctx, u2e_cdp, "websocket", ZPM ++ "src/net/websocket.sig");
    _ = try ctx.addModule("elementor_dom_import", ZPM ++ "src/elementor/dom_import.sig");

    const u2e_imports = [_]sig_build.Import_Entry{
        importEntry("cdp", ZPM ++ "src/platform/cdp.sig"),
        importEntry("subprocess", ZPM ++ "src/platform/subprocess.sig"),
        importEntry("websocket", ZPM ++ "src/net/websocket.sig"),
        importEntry("elementor_dom_import", ZPM ++ "src/elementor/dom_import.sig"),
    };
    const url2elementor = try ctx.addCompileStep(.{
        .source_path = "src/url2elementor.sig",
        .output_name = "url2elementor",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = null,
        .imports = &u2e_imports,
        .compiler_path = "",
        // Native app icon (icon id 1 → src/stools.ico).
        .win32_resource = app_rc,
    });
    try ctx.addDependency(install, url2elementor);

    // ── pdf2audiobook: PDF/TXT -> verified text -> native TTS -> WAV ──
    // Consumes the zpm pdf text extractor, the English G2P frontend, the
    // source-filter narrator synthesizer, the WAV writer, the GGUF reader (to
    // condition the voice from a Qwen3 0.6B custom-voice model when present),
    // and subprocess (to fetch that model into ./models on --fetch). Register
    // the modules and wire nested imports so the flat registry resolves them:
    //   pdf2audiobook -> pdf_render -> { parser, raster, text -> inflate }
    //                 -> english_phonemes -> { sig_mem, sig_text -> sig_mem }
    //                 -> tts_voice -> { math, sig_math, english_phonemes }
    //                 -> wav
    //                 -> gguf -> { sig_math, sig_mem }
    //                 -> subprocess
    _ = try ctx.addModule("sig_mem", ZPM ++ "src/core/sig_mem.sig");
    const p2a_sig_text = try ctx.addModule("sig_text", ZPM ++ "src/core/sig_text.sig");
    try wire(ctx, p2a_sig_text, "sig_mem", ZPM ++ "src/core/sig_mem.sig");
    _ = try ctx.addModule("math", ZPM ++ "src/core/math.sig");
    _ = try ctx.addModule("sig_math", ZPM ++ "src/core/sig_math.sig");

    const p2a_pdf = try ctx.addModule("pdf_render", ZPM ++ "src/pdf_render/root.sig");
    try wire(ctx, p2a_pdf, "inflate", ZPM ++ "src/core/inflate.sig");

    _ = try ctx.addModule("wav", ZPM ++ "src/core/wav.sig");

    const p2a_gguf = try ctx.addModule("gguf", ZPM ++ "src/core/gguf.sig");
    try wire(ctx, p2a_gguf, "sig_math", ZPM ++ "src/core/sig_math.sig");
    try wire(ctx, p2a_gguf, "sig_mem", ZPM ++ "src/core/sig_mem.sig");

    // subprocess is already registered above (for cdp/url2elementor).

    // ── The real neural Qwen3-TTS voice (zpm src/tts/*). pdf2audiobook imports
    // src/tts_neural.sig, which drives the full Talker -> code predictor -> RVQ
    // codec transformer -> ConvNeXt/SnakeBeta vocoder stack over the native
    // SB0M model container. Register every tts module + its shared deps
    // (quantized_linear, transformer_ops, the BPE tokenizer) and wire nested
    // imports so the flat registry resolves the closure. ──
    _ = try ctx.addModule("quantized_linear", ZPM ++ "src/core/quantized_linear.sig");
    const p2a_transformer_ops = try ctx.addModule("transformer_ops", ZPM ++ "src/core/transformer_ops.sig");
    try wire(ctx, p2a_transformer_ops, "sig_math", ZPM ++ "src/core/sig_math.sig");

    // Qwen BPE tokenizer (tokenizer -> tokenizer_index -> gguf).
    const p2a_tok_index = try ctx.addModule("tokenizer_index", ZPM ++ "src/core/tokenizer_index.sig");
    try wire(ctx, p2a_tok_index, "gguf", ZPM ++ "src/core/gguf.sig");
    try wire(ctx, p2a_tok_index, "sig_math", ZPM ++ "src/core/sig_math.sig");
    try wire(ctx, p2a_tok_index, "sig_mem", ZPM ++ "src/core/sig_mem.sig");
    const p2a_tokenizer = try ctx.addModule("tokenizer", ZPM ++ "src/core/tokenizer.sig");
    try wire(ctx, p2a_tokenizer, "gguf", ZPM ++ "src/core/gguf.sig");
    try wire(ctx, p2a_tokenizer, "sig_math", ZPM ++ "src/core/sig_math.sig");
    try wire(ctx, p2a_tokenizer, "sig_mem", ZPM ++ "src/core/sig_mem.sig");
    try wire(ctx, p2a_tokenizer, "tokenizer_index", ZPM ++ "src/core/tokenizer_index.sig");

    // tts model container + Talker stack.
    _ = try ctx.addModule("tts_model_container", ZPM ++ "src/tts/model_container.sig");
    _ = try ctx.addModule("tts_talker_plan", ZPM ++ "src/tts/talker_plan.sig");

    // Optional cuBLAS GPU weight cache (imports matmul_cuda). Consumed by both
    // tensor backends + the neural driver; a no-op when there is no GPU.
    _ = try ctx.addModule("matmul_cuda", ZPM ++ "src/matmul/cuda.sig");
    const p2a_gpu = try ctx.addModule("tts_gpu", ZPM ++ "src/tts/gpu.sig");
    try wire(ctx, p2a_gpu, "tts_model_container", ZPM ++ "src/tts/model_container.sig");
    try wire(ctx, p2a_gpu, "quantized_linear", ZPM ++ "src/core/quantized_linear.sig");
    try wire(ctx, p2a_gpu, "matmul_cuda", ZPM ++ "src/matmul/cuda.sig");

    const p2a_tnp = try ctx.addModule("tts_talker_native_plan", ZPM ++ "src/tts/talker_native_plan.sig");
    try wire(ctx, p2a_tnp, "tts_model_container", ZPM ++ "src/tts/model_container.sig");
    try wire(ctx, p2a_tnp, "tts_talker_plan", ZPM ++ "src/tts/talker_plan.sig");
    const p2a_tbk = try ctx.addModule("tts_talker_backend", ZPM ++ "src/tts/talker_backend.sig");
    try wire(ctx, p2a_tbk, "tts_model_container", ZPM ++ "src/tts/model_container.sig");
    try wire(ctx, p2a_tbk, "quantized_linear", ZPM ++ "src/core/quantized_linear.sig");
    try wire(ctx, p2a_tbk, "tts_gpu", ZPM ++ "src/tts/gpu.sig");
    // Custom-CUDA-kernel module — registered here (before ANY module wires it)
    // so later addModule calls aren't duplicate-name registrations. Consumed by
    // tts_talker_executor, tts_codec_transformer, and tts_vocoder GPU paths.
    const p2a_kernels = try ctx.addModule("tts_kernels", ZPM ++ "src/tts/kernels.sig");
    try wire(ctx, p2a_kernels, "matmul_cuda", ZPM ++ "src/matmul/cuda.sig");
    try wire(ctx, p2a_kernels, "tts_model_container", ZPM ++ "src/tts/model_container.sig");
    try wire(ctx, p2a_kernels, "quantized_linear", ZPM ++ "src/core/quantized_linear.sig");

    const p2a_tex = try ctx.addModule("tts_talker_executor", ZPM ++ "src/tts/talker_executor.sig");
    try wire(ctx, p2a_tex, "tts_talker_plan", ZPM ++ "src/tts/talker_plan.sig");
    try wire(ctx, p2a_tex, "tts_talker_backend", ZPM ++ "src/tts/talker_backend.sig");
    try wire(ctx, p2a_tex, "transformer_ops", ZPM ++ "src/core/transformer_ops.sig");
    try wire(ctx, p2a_tex, "tts_kernels", ZPM ++ "src/tts/kernels.sig");
    const p2a_tsamp = try ctx.addModule("tts_sampler", ZPM ++ "src/tts/sampler.sig");
    try wire(ctx, p2a_tsamp, "tts_talker_plan", ZPM ++ "src/tts/talker_plan.sig");
    const p2a_tsyn = try ctx.addModule("tts_synth", ZPM ++ "src/tts/synth.sig");
    try wire(ctx, p2a_tsyn, "tts_talker_plan", ZPM ++ "src/tts/talker_plan.sig");
    try wire(ctx, p2a_tsyn, "tts_talker_backend", ZPM ++ "src/tts/talker_backend.sig");
    try wire(ctx, p2a_tsyn, "tts_talker_executor", ZPM ++ "src/tts/talker_executor.sig");
    try wire(ctx, p2a_tsyn, "tts_sampler", ZPM ++ "src/tts/sampler.sig");

    // tts codec + vocoder stack.
    const p2a_cp = try ctx.addModule("tts_codec_plan", ZPM ++ "src/tts/codec_plan.sig");
    try wire(ctx, p2a_cp, "tts_model_container", ZPM ++ "src/tts/model_container.sig");
    const p2a_cbk = try ctx.addModule("tts_codec_backend", ZPM ++ "src/tts/codec_backend.sig");
    try wire(ctx, p2a_cbk, "tts_model_container", ZPM ++ "src/tts/model_container.sig");
    try wire(ctx, p2a_cbk, "quantized_linear", ZPM ++ "src/core/quantized_linear.sig");
    try wire(ctx, p2a_cbk, "tts_gpu", ZPM ++ "src/tts/gpu.sig");
    const p2a_ctr = try ctx.addModule("tts_codec_transformer", ZPM ++ "src/tts/codec_transformer.sig");
    try wire(ctx, p2a_ctr, "tts_model_container", ZPM ++ "src/tts/model_container.sig");
    try wire(ctx, p2a_ctr, "tts_codec_plan", ZPM ++ "src/tts/codec_plan.sig");
    try wire(ctx, p2a_ctr, "tts_codec_backend", ZPM ++ "src/tts/codec_backend.sig");
    try wire(ctx, p2a_ctr, "tts_kernels", ZPM ++ "src/tts/kernels.sig");
    const p2a_voc = try ctx.addModule("tts_vocoder", ZPM ++ "src/tts/vocoder.sig");
    try wire(ctx, p2a_voc, "tts_model_container", ZPM ++ "src/tts/model_container.sig");
    try wire(ctx, p2a_voc, "tts_codec_plan", ZPM ++ "src/tts/codec_plan.sig");
    try wire(ctx, p2a_voc, "tts_codec_backend", ZPM ++ "src/tts/codec_backend.sig");
    try wire(ctx, p2a_voc, "tts_kernels", ZPM ++ "src/tts/kernels.sig");
    const p2a_codec = try ctx.addModule("tts_codec", ZPM ++ "src/tts/codec.sig");
    try wire(ctx, p2a_codec, "tts_model_container", ZPM ++ "src/tts/model_container.sig");
    try wire(ctx, p2a_codec, "tts_codec_plan", ZPM ++ "src/tts/codec_plan.sig");
    try wire(ctx, p2a_codec, "tts_codec_transformer", ZPM ++ "src/tts/codec_transformer.sig");
    try wire(ctx, p2a_codec, "tts_vocoder", ZPM ++ "src/tts/vocoder.sig");

    // The stools-local neural driver module and its wired imports.
    const p2a_neural = try ctx.addModule("tts_neural", "src/tts_neural.sig");
    try wire(ctx, p2a_neural, "gguf", ZPM ++ "src/core/gguf.sig");
    try wire(ctx, p2a_neural, "tokenizer", ZPM ++ "src/core/tokenizer.sig");
    try wire(ctx, p2a_neural, "tokenizer_index", ZPM ++ "src/core/tokenizer_index.sig");
    try wire(ctx, p2a_neural, "tts_model_container", ZPM ++ "src/tts/model_container.sig");
    try wire(ctx, p2a_neural, "tts_talker_plan", ZPM ++ "src/tts/talker_plan.sig");
    try wire(ctx, p2a_neural, "tts_talker_native_plan", ZPM ++ "src/tts/talker_native_plan.sig");
    try wire(ctx, p2a_neural, "tts_synth", ZPM ++ "src/tts/synth.sig");
    try wire(ctx, p2a_neural, "tts_codec_plan", ZPM ++ "src/tts/codec_plan.sig");
    try wire(ctx, p2a_neural, "tts_codec", ZPM ++ "src/tts/codec.sig");
    try wire(ctx, p2a_neural, "tts_gpu", ZPM ++ "src/tts/gpu.sig");

    const p2a_imports = [_]sig_build.Import_Entry{
        importEntry("pdf_render", ZPM ++ "src/pdf_render/root.sig"),
        importEntry("inflate", ZPM ++ "src/core/inflate.sig"),
        importEntry("sig_mem", ZPM ++ "src/core/sig_mem.sig"),
        importEntry("sig_text", ZPM ++ "src/core/sig_text.sig"),
        importEntry("math", ZPM ++ "src/core/math.sig"),
        importEntry("sig_math", ZPM ++ "src/core/sig_math.sig"),
        importEntry("wav", ZPM ++ "src/core/wav.sig"),
        importEntry("gguf", ZPM ++ "src/core/gguf.sig"),
        importEntry("subprocess", ZPM ++ "src/platform/subprocess.sig"),
        // Neural Qwen3-TTS voice (src/tts_neural.sig + the zpm tts stack).
        importEntry("tts_neural", "src/tts_neural.sig"),
        importEntry("quantized_linear", ZPM ++ "src/core/quantized_linear.sig"),
        importEntry("transformer_ops", ZPM ++ "src/core/transformer_ops.sig"),
        importEntry("tokenizer", ZPM ++ "src/core/tokenizer.sig"),
        importEntry("tokenizer_index", ZPM ++ "src/core/tokenizer_index.sig"),
        importEntry("tts_model_container", ZPM ++ "src/tts/model_container.sig"),
        importEntry("tts_talker_plan", ZPM ++ "src/tts/talker_plan.sig"),
        importEntry("tts_talker_native_plan", ZPM ++ "src/tts/talker_native_plan.sig"),
        importEntry("tts_talker_backend", ZPM ++ "src/tts/talker_backend.sig"),
        importEntry("tts_talker_executor", ZPM ++ "src/tts/talker_executor.sig"),
        importEntry("tts_sampler", ZPM ++ "src/tts/sampler.sig"),
        importEntry("tts_synth", ZPM ++ "src/tts/synth.sig"),
        importEntry("tts_codec_plan", ZPM ++ "src/tts/codec_plan.sig"),
        importEntry("tts_codec_backend", ZPM ++ "src/tts/codec_backend.sig"),
        importEntry("tts_codec_transformer", ZPM ++ "src/tts/codec_transformer.sig"),
        importEntry("tts_vocoder", ZPM ++ "src/tts/vocoder.sig"),
        importEntry("tts_codec", ZPM ++ "src/tts/codec.sig"),
        importEntry("tts_gpu", ZPM ++ "src/tts/gpu.sig"),
        importEntry("matmul_cuda", ZPM ++ "src/matmul/cuda.sig"),
    };
    const pdf2audiobook = try ctx.addCompileStep(.{
        .source_path = "src/pdf2audiobook.sig",
        .output_name = "pdf2audiobook",
        .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
        .optimize = ctx.optimize,
        .target = null,
        .imports = &p2a_imports,
        .compiler_path = "",
        .win32_resource = app_rc,
    });
    try ctx.addDependency(install, pdf2audiobook);

    const test_all = try ctx.addStep("test", "Run the project tests", &noop);
    const tests = try ctx.addTestStep(.{ .name = "test-source", .source_path = "src/main.sig", .imports = &app_imports });
    try ctx.addDependency(test_all, tests);
    const p2a_tests = try ctx.addTestStep(.{ .name = "test-pdf2audiobook", .source_path = "src/pdf2audiobook.sig", .imports = &p2a_imports });
    try ctx.addDependency(test_all, p2a_tests);

    // ── stools-ui: the translucent launcher GUI (WINDOWS ONLY) ──
    // A Layer-3 shell that renders the data-driven command registry and launches
    // any tool via subprocess. It consumes the zpm windowing + GL + render
    // (materials/primitives/text/color) stack, which are Win32/WGL-backed — so
    // the GUI only exists for Windows targets. The release CI cross-compiles the
    // suite to linux/macos/sb0 too; there we simply don't register this step
    // (the CLI tools `stools`/`img2elementor` still build for every target).
    //   launcher -> window -> { win32, gl }
    //             -> primitives -> { gl, color }
    //             -> text -> { win32, gl, color }
    //             -> materials -> gl
    //             -> subprocess
    if (targeting_windows) {
        _ = try ctx.addModule("gl", ZPM ++ "src/platform/gl.sig");
        _ = try ctx.addModule("color", ZPM ++ "src/render/color.sig");

        const ui_window = try ctx.addModule("window", ZPM ++ "src/platform/window.sig");
        try wire(ctx, ui_window, "win32", win32_path);
        try wire(ctx, ui_window, "gl", ZPM ++ "src/platform/gl.sig");

        const ui_prim = try ctx.addModule("primitives", ZPM ++ "src/render/primitives.sig");
        try wire(ctx, ui_prim, "gl", ZPM ++ "src/platform/gl.sig");
        try wire(ctx, ui_prim, "color", ZPM ++ "src/render/color.sig");

        const ui_text = try ctx.addModule("text", ZPM ++ "src/render/text.sig");
        try wire(ctx, ui_text, "win32", win32_path);
        try wire(ctx, ui_text, "gl", ZPM ++ "src/platform/gl.sig");
        try wire(ctx, ui_text, "color", ZPM ++ "src/render/color.sig");

        const ui_mats = try ctx.addModule("materials", ZPM ++ "src/render/materials.sig");
        try wire(ctx, ui_mats, "gl", ZPM ++ "src/platform/gl.sig");

        const ui_icon = try ctx.addModule("icon", ZPM ++ "src/render/icon.sig");
        try wire(ctx, ui_icon, "gl", ZPM ++ "src/platform/gl.sig");
        try wire(ctx, ui_icon, "win32", win32_path);

        // subprocess is already registered above (for cdp/url2elementor); the
        // launcher just references it in its import table below.

        const ui_imports = [_]sig_build.Import_Entry{
            importEntry("win32", win32_path),
            importEntry("gl", ZPM ++ "src/platform/gl.sig"),
            importEntry("color", ZPM ++ "src/render/color.sig"),
            importEntry("window", ZPM ++ "src/platform/window.sig"),
            importEntry("primitives", ZPM ++ "src/render/primitives.sig"),
            importEntry("text", ZPM ++ "src/render/text.sig"),
            importEntry("materials", ZPM ++ "src/render/materials.sig"),
            importEntry("icon", ZPM ++ "src/render/icon.sig"),
            importEntry("subprocess", ZPM ++ "src/platform/subprocess.sig"),
        };
        const launcher = try ctx.addCompileStep(.{
            .source_path = "src/launcher.sig",
            .output_name = "stools-ui",
            .cache_dir = ctx.cache_dir[0..ctx.cache_dir_len],
            .optimize = ctx.optimize,
            .target = null,
            .imports = &ui_imports,
            .compiler_path = "",
            // Embed the app icon natively via the resource script (icon id 1 →
            // src/stools.ico). The compiler compiles the .rc and links its .res
            // in, so the exe carries the Explorer/taskbar icon — no post step.
            .win32_resource = app_rc,
        });
        try ctx.addDependency(install, launcher);

        // Cover the launcher's schema + argv-assembly logic (tool_schema.sig,
        // launch.sig). Uses the same UI import graph so subprocess/tool_schema
        // resolve.
        const ui_tests = try ctx.addTestStep(.{ .name = "test-ui", .source_path = "src/launch.sig", .imports = &ui_imports });
        try ctx.addDependency(test_all, ui_tests);
    }
}

// stools tts_neural — the real Qwen3-TTS-12Hz-0.6B neural voice.
//
// A thin driver over the pure-Sig zpm `tts` stack (extracted from the SB0
// Nexus runtime): it loads the native SB0M Talker + codec artifacts and the
// Qwen BPE tokenizer, then turns text into 24 kHz mono PCM16 by running the
// full Talker -> code predictor -> RVQ codec transformer -> ConvNeXt/SnakeBeta
// vocoder pipeline. This is a genuine neural text-to-waveform decoder, not a
// formant synthesizer.
//
// Model artifacts (in ./models, git-ignored):
//   talker.sb0m    Talker + code predictor + codec heads (402 tensors)
//   codec.sb0m     RVQ + sliding transformer + vocoder   (271 tensors)
//   tokenizer.gguf Qwen3 BPE vocabulary + merges          (tokenizer metadata)
//
// Honest performance note: the executor is a correct but unaccelerated
// row-sliced CPU kernel — about 644x slower than realtime on a warm desktop
// (≈51 s for 80 ms of audio). It is exact, not fast; whole-book narration is
// impractical without acceleration, so pdf2audiobook uses it for bounded
// excerpts and keeps the instant built-in narrator for full books.

const std = @import("std");
const gguf = @import("gguf");
const tok_index = @import("tokenizer_index");
const bpe = @import("tokenizer");
const sb0m = @import("tts_model_container");
const talker_plan_module = @import("tts_talker_plan");
const talker_native_plan = @import("tts_talker_native_plan");
const synth = @import("tts_synth");
const codec_plan_module = @import("tts_codec_plan");
const codec = @import("tts_codec");
const gpu = @import("tts_gpu");

pub const SAMPLE_RATE: u32 = codec_plan_module.SAMPLE_RATE;
pub const PERIOD_SAMPLES: usize = codec.PERIOD_SAMPLES;
pub const MAX_FRAMES: usize = synth.MAX_FRAMES;

/// Per-utterance voice controls (language, think, sampling) — the knobs the
/// Qwen3-TTS model exposes. Re-exported so callers build one without importing
/// the zpm synth module directly.
pub const VoiceConfig = synth.VoiceConfig;

/// Map a language name ("english", "japanese", …) to its codec token, or null.
pub const languageToken = synth.languageToken;

/// A monotonic nanosecond clock (for progress/ETA timing).
pub fn nowNs() u64 {
    return gpu.nowNs();
}
pub const SAMPLES_PER_FRAME: usize = codec_plan_module.SAMPLES_PER_FRAME;
/// Longest audio one begin()/utterance can produce (frames × samples).
pub const MAX_UTTERANCE_SAMPLES: usize = MAX_FRAMES * SAMPLES_PER_FRAME;

const TALKER_TENSORS: usize = 402;
const Vocabulary = tok_index.VocabularyIndex(160_000, 262_144);
const Merges = tok_index.MergeIndex(262_144, 512);

pub const Error = error{
    ModelMissing,
    ModelInvalid,
    TokenizerInvalid,
    PromptTooLong,
    SynthesisFailed,
    OutputFull,
};

// ── File-scope model state (no heap). One loaded engine per process. ──
var talker_index: sb0m.Index(TALKER_TENSORS) = .{};
var codec_index: sb0m.Index(codec_plan_module.NATIVE_TENSORS) = .{};
var talker_plan: talker_plan_module.Plan = .{};
var codec_plan: codec_plan_module.Plan = .{};
var vocabulary: Vocabulary = .{};
var merges: Merges = .{};
var tokenizer_gguf_index: gguf.Index(2048) = .{};

var talker_runtime: synth.Runtime = .{};
var codec_runtime: codec.Runtime = .{};
var tokens: [synth.MAX_TEXT_TOKENS]u32 = @splat(0);

// Open model files stay mapped through positional reads for the engine's life.
var talker_reader: FileSource = undefined;
var tokenizer_reader: FileSource = undefined;
var codec_reader: FileSource = undefined;
var talker_source: sb0m.Source = undefined;
var tokenizer_source: gguf.Source = undefined;
var codec_source: sb0m.Source = undefined;

// PCM collection target for one utterance (set per synthesize call).
var pcm_target: []i16 = &.{};
var pcm_filled: usize = 0;
var sink_identity: u8 = 0x53;

/// A positional file reader with a 1 MB cache, adapted to both the SB0M and
/// GGUF Source interfaces (identical read_at signature).
const FileSource = struct {
    const CACHE_BYTES: usize = 1024 * 1024;
    file: std.Io.File,
    io: std.Io,
    cache: [CACHE_BYTES]u8 = undefined,
    cache_start: u64 = 0,
    cache_length: usize = 0,

    fn read(context: *const anyopaque, offset: u64, destination: []u8) bool {
        const self: *FileSource = @ptrCast(@alignCast(@constCast(context)));
        var source_offset = offset;
        var destination_offset: usize = 0;
        while (destination_offset < destination.len) {
            const cache_end = self.cache_start + self.cache_length;
            if (self.cache_length == 0 or source_offset < self.cache_start or source_offset >= cache_end) {
                self.cache_start = source_offset - (source_offset % CACHE_BYTES);
                self.cache_length = self.file.readPositionalAll(self.io, &self.cache, self.cache_start) catch return false;
                if (self.cache_length == 0) return false;
            }
            const cache_offset: usize = @intCast(source_offset - self.cache_start);
            const count = @min(destination.len - destination_offset, self.cache_length - cache_offset);
            @memcpy(destination[destination_offset..][0..count], self.cache[cache_offset..][0..count]);
            destination_offset += count;
            source_offset += count;
        }
        return true;
    }

    fn sb0Source(self: *const FileSource, size: u64) sb0m.Source {
        return .{ .context = self, .size = size, .read_at = read };
    }
    fn ggufSource(self: *const FileSource, size: u64) gguf.Source {
        return .{ .context = self, .size = size, .read_at = read };
    }
};

/// True if all three artifacts exist at the given directory-relative paths.
pub fn artifactsPresent(io: std.Io, cwd: std.Io.Dir, talker: []const u8, tokenizer: []const u8, codec_path: []const u8) bool {
    return exists(io, cwd, talker) and exists(io, cwd, tokenizer) and exists(io, cwd, codec_path);
}

fn exists(io: std.Io, cwd: std.Io.Dir, path: []const u8) bool {
    const f = cwd.openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

/// Load the Talker, tokenizer, and codec from disk and validate them. Must be
/// called once before `synthesize`. All three files stay open for the engine's
/// lifetime (positional reads, no full map).
pub fn load(io: std.Io, cwd: std.Io.Dir, talker: []const u8, tokenizer: []const u8, codec_path: []const u8) Error!void {
    const talker_file = cwd.openFile(io, talker, .{}) catch return error.ModelMissing;
    const talker_size = talker_file.length(io) catch return error.ModelInvalid;
    talker_reader = .{ .file = talker_file, .io = io };
    talker_source = talker_reader.sb0Source(talker_size);
    sb0m.parse(TALKER_TENSORS, talker_source, &talker_index) catch return error.ModelInvalid;
    talker_native_plan.build(TALKER_TENSORS, &talker_index, &talker_plan) catch return error.ModelInvalid;

    // Bring up the GPU (cuBLAS) and lift the Talker's matmul weights into VRAM.
    // If there is no CUDA device (or --cpu forced it off), this is a no-op and
    // decode stays on the exact CPU path.
    gpu_ready = if (gpu_disabled) false else gpu.init();
    if (gpu_ready) _ = gpu.preloadAllMatrices(TALKER_TENSORS, talker_source, &talker_index);

    const tokenizer_file = cwd.openFile(io, tokenizer, .{}) catch return error.ModelMissing;
    const tokenizer_size = tokenizer_file.length(io) catch return error.TokenizerInvalid;
    tokenizer_reader = .{ .file = tokenizer_file, .io = io };
    tokenizer_source = tokenizer_reader.ggufSource(tokenizer_size);
    gguf.parse(2048, tokenizer_source, &tokenizer_gguf_index) catch return error.TokenizerInvalid;
    vocabulary.build(tokenizer_source, tokenizer_gguf_index.summary.tokenizer_tokens) catch return error.TokenizerInvalid;
    merges.build(tokenizer_source, tokenizer_gguf_index.summary.tokenizer_merges, &vocabulary) catch return error.TokenizerInvalid;

    const codec_file = cwd.openFile(io, codec_path, .{}) catch return error.ModelMissing;
    const codec_size = codec_file.length(io) catch return error.ModelInvalid;
    codec_reader = .{ .file = codec_file, .io = io };
    codec_source = codec_reader.sb0Source(codec_size);
    sb0m.parse(codec_plan_module.NATIVE_TENSORS, codec_source, &codec_index) catch return error.ModelInvalid;
    codec_plan_module.build(codec_plan_module.NATIVE_TENSORS, &codec_index, &codec_plan) catch return error.ModelInvalid;

    // Lift the codec transformer + linear projections into VRAM too.
    if (gpu_ready) _ = gpu.preloadAllMatrices(codec_plan_module.NATIVE_TENSORS, codec_source, &codec_index);

    // Move the vocoder (latent → PCM) onto the GPU: preload every conv/snake/
    // norm weight into VRAM (dequantized f32) and switch the codec runtime to
    // the custom-kernel decode path. No-op without a GPU (CPU vocoder stays).
    // Custom-kernel GPU decode paths (vocoder, codec transformer, talker,
    // predictor). Gated on gpu_ready so --cpu forces the exact CPU path.
    if (gpu_ready) {
        vocoder_gpu_active = codec_runtime.enableGpu(codec_plan_module.NATIVE_TENSORS, codec_source, &codec_index, &codec_plan);
        talker_gpu_active = talker_runtime.enableGpu(TALKER_TENSORS, talker_source, &talker_index, &talker_plan);
    }
}

var gpu_disabled: bool = false;
var talker_gpu_active: bool = false;

/// Force the exact CPU decode path (disable all GPU acceleration). Call before
/// `load`. Used by the --cpu benchmark flag.
pub fn disableGpu() void {
    gpu_disabled = true;
}

/// True when the Talker + predictor forwards run GPU-resident.
pub fn talkerOnGpu() bool {
    return talker_gpu_active;
}

var vocoder_gpu_active: bool = false;

/// True when the GPU vocoder (custom CUDA kernels, f32-exact) is decoding
/// latent → PCM. False means the exact CPU vocoder is in use.
pub fn vocoderOnGpu() bool {
    return vocoder_gpu_active;
}

/// True after `load` if the cuBLAS GPU backend is active (weights resident in
/// VRAM); false means the exact CPU path is in use.
pub fn gpuActive() bool {
    return gpu_ready and gpu.armed();
}

/// Number of weight matrices resident in VRAM (0 = CPU-only).
pub fn gpuResidentMatrices() usize {
    return gpu.entryCount();
}

/// (hits, misses, ms) for GPU matvec dispatch since load — a hit means cuBLAS
/// ran the matmul, a miss means CPU fallback; ms is total time inside GPU
/// matvec (upload+gemm+download).
pub fn gpuDispatch() struct { hits: u64, misses: u64, ms: u64, up_ms: u64, gemm_ms: u64, down_ms: u64 } {
    return .{
        .hits = gpu.gpu_hits,
        .misses = gpu.gpu_misses,
        .ms = gpu.gpu_ns / 1_000_000,
        .up_ms = gpu.up_ns / 1_000_000,
        .gemm_ms = gpu.gemm_ns / 1_000_000,
        .down_ms = gpu.down_ns / 1_000_000,
    };
}

var gpu_ready: bool = false;

/// Synthesize `text` into `out` as 24 kHz mono PCM16, returning the number of
/// samples written. `max_frames` bounds the utterance (1..MAX_FRAMES); each
/// frame is 1,920 samples (80 ms). `entropy_seed` makes sampling reproducible.
/// One call is one Talker utterance, so keep `text` to roughly a sentence
/// (≤ MAX_TEXT_TOKENS BPE tokens after the prompt scaffold).
pub fn synthesize(
    io: std.Io,
    text: []const u8,
    max_frames: usize,
    entropy_seed: u64,
    voice: synth.VoiceConfig,
    out: []i16,
) Error!usize {
    _ = io;
    const frame_ceiling = if (max_frames == 0 or max_frames > MAX_FRAMES) MAX_FRAMES else max_frames;

    const token_count = buildPrompt(text) catch return error.PromptTooLong;
    talker_runtime.begin(
        TALKER_TENSORS,
        talker_source,
        &talker_index,
        &talker_plan,
        tokens[0..token_count],
        entropy_seed,
        voice,
    ) catch return error.SynthesisFailed;

    // Wire the PCM sink to fill `out`.
    pcm_target = out;
    pcm_filled = 0;
    const pcm_sink = codec.PcmSink{ .context = &sink_identity, .submit_fn = collect };

    var emitted: usize = 0;
    while (emitted < frame_ceiling) {
        const result = talker_runtime.step(TALKER_TENSORS, talker_source, &talker_index, &talker_plan, 4096, .{}) catch
            return error.SynthesisFailed;
        switch (result) {
            .pending => {},
            .frame_ready => {
                var frame: synth.Frame = .{};
                talker_runtime.takeFrame(&frame) catch return error.SynthesisFailed;
                codec_runtime.decodeAndSubmit(
                    codec_plan_module.NATIVE_TENSORS,
                    codec_source,
                    &codec_index,
                    &codec_plan,
                    &frame.codes,
                    1,
                    pcm_sink,
                ) catch return error.SynthesisFailed;
                emitted += 1;
            },
            .complete => break,
        }
    }
    return pcm_filled;
}

/// Reset the codec's streaming state between independent utterances so causal
/// convolution rings and the transformer KV window do not bleed across a hard
/// sentence boundary. (The Talker resets itself inside `begin`.)
pub fn resetCodec() void {
    codec_runtime.reset();
}

fn buildPrompt(text: []const u8) bpe.Error!usize {
    var count: usize = 0;
    count = try appendSpecial("<|im_start|>", count);
    count += try bpe.encodeText(tokenizer_source, &vocabulary, &merges, "assistant\n", tokens[count..]);
    count += try bpe.encodeText(tokenizer_source, &vocabulary, &merges, text, tokens[count..]);
    count = try appendSpecial("<|im_end|>", count);
    count += try bpe.encodeText(tokenizer_source, &vocabulary, &merges, "\n", tokens[count..]);
    count = try appendSpecial("<|im_start|>", count);
    count += try bpe.encodeText(tokenizer_source, &vocabulary, &merges, "assistant\n", tokens[count..]);
    return count;
}

fn appendSpecial(value: []const u8, count: usize) bpe.Error!usize {
    if (count == tokens.len) return error.TokenCapacity;
    tokens[count] = vocabulary.lookup(tokenizer_source, value) orelse return error.MissingSpecialToken;
    return count + 1;
}

/// codec PcmSink callback: append one 480-sample period into `pcm_target`.
fn collect(context: ?*anyopaque, correlation_id: u64, samples: []const i16) bool {
    if (context != @as(?*anyopaque, @ptrCast(&sink_identity)) or correlation_id != 1 or
        samples.len != PERIOD_SAMPLES or pcm_filled + samples.len > pcm_target.len)
        return false;
    @memcpy(pcm_target[pcm_filled..][0..samples.len], samples);
    pcm_filled += samples.len;
    return true;
}

test "utterance sample ceiling matches the frame contract" {
    try std.testing.expectEqual(MAX_UTTERANCE_SAMPLES, MAX_FRAMES * SAMPLES_PER_FRAME);
    try std.testing.expectEqual(@as(u32, 24_000), SAMPLE_RATE);
    try std.testing.expectEqual(@as(usize, 480), PERIOD_SAMPLES);
}

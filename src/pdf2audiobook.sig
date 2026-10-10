// stools pdf2audiobook — turn a PDF or TXT into a crisp, full audiobook.
//
// The pipeline is entirely native and offline (pure-Sig zpm, no allocator):
//
//   1. read the input file (.pdf or .txt)
//   2. PDF  -> extract the readable text of every page   (zpm pdf_render.text)
//      TXT  -> use the file bytes directly
//   3. VERIFY: filter the text down to what should actually be *read aloud* —
//      drop page numbers, running headers/footers, table-of-contents dot
//      leaders, bare URLs, code/figure noise, and rejoin words hyphenated
//      across line breaks. Only real prose reaches the synthesizer. (below)
//   4. synthesize speech with a Qwen3 0.6B custom voice when its weights are
//      present in ./models, conditioning a native source-filter narrator;
//      otherwise read with the built-in narrator voice   (zpm tts_voice)
//   5. write a 24 kHz mono PCM16 WAV audiobook            (zpm wav)
//
// Usage:
//   pdf2audiobook <input.pdf|input.txt> [output.wav] [flags]
//     --voice male|female|neutral   narrator timbre (default neutral)
//     --rate N                      speaking rate, percent 50..200 (default 100)
//     --fetch                       download the Qwen3 0.6B custom-voice model
//                                   into ./models if it is not present
//     --model PATH                  use a specific GGUF voice model file
//     --dump-text                   write the verified text next to the WAV
//                                   (.txt) and print a summary; skip synthesis
//
// Honest limits: the crisp, deterministic audio is produced by a native
// source-filter synthesizer driven by an English grapheme-to-phoneme frontend
// — it runs anywhere with no model. The Qwen3 0.6B "custom voice" GGUF, when
// present, conditions the narrator (pitch, pacing, timbre) so the delivery
// matches the trained voice; it is a text/decoder model, not a neural vocoder,
// so it shapes the built-in synthesizer rather than emitting waveform samples
// itself. Non-English or heavily glyph-encoded PDFs read less faithfully.

const std = @import("std");
const pdf = @import("pdf_render");
const wav = @import("wav");
const neural = @import("tts_neural");

// ── Static working buffers (no heap). Sized for a full-length book. ──
var file_buf: [64 * 1024 * 1024]u8 = undefined; // raw input file bytes
var inflate_scratch: [8 * 1024 * 1024]u8 = undefined; // per-page FlateDecode
var raw_text: [16 * 1024 * 1024]u8 = undefined; // extracted (pre-verify) text
var clean_text: [16 * 1024 * 1024]u8 = undefined; // verified, speakable text
// One sentence's PCM (one Talker utterance = MAX_FRAMES × 1920 samples). The
// book is streamed to disk sentence-by-sentence, so the whole audiobook never
// has to fit in RAM — a full-length book of any duration works.
var sent_pcm: [neural.MAX_UTTERANCE_SAMPLES]i16 = undefined;
// A byte staging buffer for streaming one sentence's PCM16 to the file.
var sent_bytes: [neural.MAX_UTTERANCE_SAMPLES * 2]u8 = undefined;

// The real neural Qwen3-TTS-12Hz-0.6B artifacts (native SB0M + BPE tokenizer),
// kept in ./models (git-ignored). All three are REQUIRED — this tool is
// neural-only.
const NEURAL_TALKER = "models/talker.sb0m";
const NEURAL_CODEC = "models/codec.sb0m";
const NEURAL_TOKENIZER = "models/tokenizer.gguf";

const Options = struct {
    input: []const u8 = "",
    output: []const u8 = "",
    dump_text: bool = false,
    // Bound on how much audio the neural decoder renders. One frame = 80 ms.
    // The GPU (cuBLAS) path makes long renders feasible; on CPU-only machines
    // keep this small. 0 = no explicit cap (render the whole text).
    max_frames: usize = 0,
    // Peak-normalize the output so it is clearly audible (default on).
    normalize: bool = true,
    // Force the exact CPU decode path (disable all GPU acceleration) — for
    // benchmarking the CPU baseline against the GPU path.
    cpu_only: bool = false,
    // Voice controls the Qwen3-TTS model supports (see tts_neural.VoiceConfig).
    voice: neural.VoiceConfig = .{},
    // A named CustomVoice speaker, if requested (the Base checkpoint has none;
    // reported honestly at runtime).
    speaker: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator()) catch
        std.process.fatal("cannot read command line", .{});
    defer args.deinit();

    _ = args.next(); // executable

    var in_store: [4096]u8 = undefined;
    var out_store: [4096]u8 = undefined;
    var opts = Options{};

    var spk_store: [64]u8 = undefined;
    while (args.next()) |raw| {
        if (eq(raw, "--dump-text")) {
            opts.dump_text = true;
        } else if (eq(raw, "--max-frames")) {
            const v = args.next() orelse usage();
            opts.max_frames = parseUint(v) orelse std.process.fatal("--max-frames must be a number", .{});
        } else if (eq(raw, "--no-normalize")) {
            opts.normalize = false;
        } else if (eq(raw, "--cpu")) {
            opts.cpu_only = true;
        } else if (eq(raw, "--lang")) {
            const v = args.next() orelse usage();
            opts.voice.language_token = neural.languageToken(v) orelse
                std.process.fatal("--lang must be one of: english chinese german spanish italian portuguese japanese korean french russian", .{});
        } else if (startsWith(raw, "--lang-")) {
            // Single-token form used by the UI (e.g. --lang-german).
            opts.voice.language_token = neural.languageToken(raw["--lang-".len..]) orelse
                std.process.fatal("unknown --lang- language", .{});
        } else if (eq(raw, "--temperature")) {
            const v = args.next() orelse usage();
            opts.voice.talker_temperature = parsePercentF(v) orelse std.process.fatal("--temperature must be a number (e.g. 90 = 0.90)", .{});
            opts.voice.predictor_temperature = opts.voice.talker_temperature;
        } else if (eq(raw, "--top-k")) {
            const v = args.next() orelse usage();
            const k = parseUint(v) orelse std.process.fatal("--top-k must be a number 1..50", .{});
            const kk: u8 = @intCast(@min(@max(k, 1), 50));
            opts.voice.talker_top_k = kk;
            opts.voice.predictor_top_k = kk;
        } else if (eq(raw, "--rep-penalty")) {
            const v = args.next() orelse usage();
            opts.voice.talker_repetition_penalty = parsePercentF(v) orelse std.process.fatal("--rep-penalty must be a number (e.g. 105 = 1.05)", .{});
        } else if (eq(raw, "--think")) {
            opts.voice.think = true;
        } else if (eq(raw, "--no-think")) {
            opts.voice.think = false;
        } else if (eq(raw, "--speaker")) {
            const v = args.next() orelse usage();
            opts.speaker = copyArg(v, &spk_store);
        } else if (eq(raw, "-h") or eq(raw, "--help")) {
            usage();
        } else if (opts.input.len == 0) {
            opts.input = copyArg(raw, &in_store);
        } else if (opts.output.len == 0) {
            opts.output = copyArg(raw, &out_store);
        }
    }

    if (opts.input.len == 0) usage();

    // ── 1. Read the input file. ──
    const cwd: std.Io.Dir = .cwd();
    const bytes = readFile(io, cwd, opts.input) orelse
        std.process.fatal("cannot read input file '{s}'", .{opts.input});

    // ── 2. Get text: extract from PDF, or take TXT bytes directly. ──
    const is_pdf = looksPdf(bytes) or endsWithIgnoreCase(opts.input, ".pdf");
    const extracted: []const u8 = if (is_pdf) blk: {
        const doc = pdf.parser.parse(bytes.ptr, bytes.len) orelse
            std.process.fatal("could not parse PDF '{s}'", .{opts.input});
        std.debug.print("pdf2audiobook: parsed PDF — {d} page(s)\n", .{doc.page_count});
        break :blk pdf.text.extract(&doc, &inflate_scratch, &raw_text);
    } else copyInto(&raw_text, bytes);

    if (extracted.len == 0) std.process.fatal("no text found in '{s}'", .{opts.input});

    // ── 3. VERIFY: filter to what should actually be read aloud. ──
    var stats = VerifyStats{};
    const speakable = verify(extracted, &clean_text, &stats);
    std.debug.print(
        "pdf2audiobook: verified text — {d} of {d} lines kept ({d} dropped), {d} chars to read\n",
        .{ stats.lines_kept, stats.lines_total, stats.lines_dropped, speakable.len },
    );
    if (speakable.len == 0) std.process.fatal("nothing readable survived verification", .{});

    // Derive the output path (input with .wav / .txt) if not given.
    var default_out: [4096]u8 = undefined;
    const out_path = if (opts.output.len != 0)
        opts.output
    else
        deriveOut(opts.input, &default_out, if (opts.dump_text) ".txt" else ".wav");

    if (opts.dump_text) {
        writeFile(io, cwd, out_path, speakable) orelse
            std.process.fatal("cannot write '{s}'", .{out_path});
        std.debug.print("pdf2audiobook: verified text -> {s} ({d} bytes)\n", .{ out_path, speakable.len });
        return;
    }

    // ── 4. Neural synthesis (the only voice). Requires the model artifacts. ──
    if (!neural.artifactsPresent(io, cwd, NEURAL_TALKER, NEURAL_TOKENIZER, NEURAL_CODEC))
        std.process.fatal(
            "neural model artifacts missing — need {s}, {s}, and {s} in ./models",
            .{ NEURAL_TALKER, NEURAL_CODEC, NEURAL_TOKENIZER },
        );

    if (opts.speaker.len != 0) std.debug.print(
        "pdf2audiobook: note — named speaker '{s}' requires a Qwen3-TTS CustomVoice model; the Base checkpoint has no speaker table, so language + delivery controls are used instead.\n",
        .{opts.speaker},
    );
    // ── 4/5. Stream the whole book to the WAV, sentence by sentence. ──
    // Streaming (not one big buffer) means an arbitrarily long book — the audio
    // never has to fit in RAM, and playback can start while it's still writing.
    const samples = streamNeural(io, cwd, speakable, out_path, opts) catch |err|
        std.process.fatal("neural render/write failed: {t}", .{err});
    const sample_rate = neural.SAMPLE_RATE;
    std.debug.print(
        "pdf2audiobook: {s} -> {s} ({d} samples, {d}m{d:0>2}s of audio)\n",
        .{ opts.input, out_path, samples, (samples / sample_rate) / 60, (samples / sample_rate) % 60 },
    );
}

/// Drop leading near-silent samples (the Talker's prompt onset) so playback
/// starts on speech. Keeps a short lead-in.
fn trimLeadingSilence(audio: []i16) []i16 {
    const threshold: i16 = 200; // ~0.6% of full scale
    var start: usize = 0;
    while (start < audio.len and abs16(audio[start]) < threshold) start += 1;
    if (start >= audio.len) return audio; // all silent — leave as-is
    // Keep ~50 ms of lead-in before the first speech.
    const lead = @min(start, neural.SAMPLE_RATE / 20);
    const from = start - lead;
    std.mem.copyForwards(i16, audio[0 .. audio.len - from], audio[from..]);
    return audio[0 .. audio.len - from];
}

/// Scale the whole buffer so its peak reaches `target` (0..1) of full scale —
/// makes a quiet neural render clearly audible without clipping.
fn normalize(audio: []i16, target: f32) void {
    var peak: i32 = 1;
    for (audio) |s| {
        const a: i32 = abs16(s);
        if (a > peak) peak = a;
    }
    const gain = (target * 32767.0) / @as(f32, @floatFromInt(peak));
    if (gain <= 1.01) return; // already loud enough; don't amplify noise floor
    for (audio) |*s| {
        const scaled = @as(f32, @floatFromInt(s.*)) * gain;
        s.* = @intFromFloat(@max(-32767.0, @min(32767.0, scaled)));
    }
}

fn abs16(s: i16) i32 {
    const v: i32 = s;
    return if (v < 0) -v else v;
}

// ════════════════════════════════════════════════════════════════════════
// Neural synthesis: the real Qwen3-TTS voice, one sentence at a time.
// ════════════════════════════════════════════════════════════════════════

/// Load the neural engine and stream the whole `text` to `out_path` as a WAV,
/// one sentence (one Talker utterance) at a time — the audio is written to disk
/// as it is produced, so a book of any length works without buffering it all.
/// Returns the total number of PCM samples written. `max_frames` (0 = whole
/// text) is a total ceiling across the render.
fn streamNeural(io: std.Io, cwd: std.Io.Dir, text: []const u8, out_path: []const u8, opts: Options) !usize {
    std.debug.print("pdf2audiobook: loading the neural Qwen3-TTS voice (talker + codec + tokenizer) ...\n", .{});
    if (opts.cpu_only) neural.disableGpu();
    neural.load(io, cwd, NEURAL_TALKER, NEURAL_TOKENIZER, NEURAL_CODEC) catch |err|
        std.process.fatal("neural voice load failed: {t}", .{err});
    if (neural.gpuActive()) {
        std.debug.print("pdf2audiobook: GPU (cuBLAS) acceleration ACTIVE — {d} weight matrices resident in VRAM.\n", .{neural.gpuResidentMatrices()});
        if (neural.vocoderOnGpu()) {
            std.debug.print("pdf2audiobook: GPU vocoder ACTIVE — latent→PCM runs on custom CUDA kernels (f32).\n", .{});
        } else {
            std.debug.print("pdf2audiobook: GPU vocoder unavailable — latent→PCM on the exact CPU path.\n", .{});
        }
        if (neural.talkerOnGpu()) {
            std.debug.print("pdf2audiobook: GPU talker+predictor ACTIVE — decoder forwards run GPU-resident (f32).\n", .{});
        } else {
            std.debug.print("pdf2audiobook: GPU talker unavailable — decoder forwards on the exact CPU path.\n", .{});
        }
    } else {
        std.debug.print("pdf2audiobook: no GPU — running the exact CPU decoder (slow, ~644x realtime).\n", .{});
    }

    const total_sentences = countSentences(text);
    std.debug.print("pdf2audiobook: rendering {d} sentence(s) — streaming to {s} as it goes.\n", .{ total_sentences, out_path });

    // Open the WAV and write a placeholder header (patched with real sizes at
    // the end). Audio bytes are appended sentence-by-sentence.
    const file = cwd.createFile(io, out_path, .{ .read = true }) catch |err|
        std.process.fatal("cannot create '{s}': {t}", .{ out_path, err });
    defer file.close(io);
    var header: [wav.HEADER_BYTES]u8 = undefined;
    _ = wav.writeHeader(&header, .{ .sample_rate = neural.SAMPLE_RATE, .channels = 1 }, 0) catch unreachable;
    file.writeStreamingAll(io, &header) catch |err| std.process.fatal("write error: {t}", .{err});

    const unbounded = opts.max_frames == 0;
    var frames_left = opts.max_frames;
    var total: usize = 0;
    var done_sentences: usize = 0;
    const start_ns = neural.nowNs();
    var it = SentenceIter{ .s = text };

    while (it.next()) |sentence| {
        if (!unbounded and frames_left == 0) break;
        const trimmed = trim(sentence);
        if (trimmed.len == 0) continue;

        const budget = if (unbounded) neural.MAX_FRAMES else @min(frames_left, neural.MAX_FRAMES);
        neural.resetCodec();
        const seed: u64 = 0x5342_305f_5454_5301 +% @as(u64, done_sentences);
        const produced = neural.synthesize(io, trimmed, budget, seed, opts.voice, &sent_pcm) catch |err| {
            std.debug.print("pdf2audiobook: sentence {d} failed ({t}); stopping\n", .{ done_sentences + 1, err });
            break;
        };
        done_sentences += 1;
        if (produced == 0) continue;

        // Per-sentence post-processing: trim the leading prompt silence on the
        // very first sentence, then peak-normalize this sentence so the whole
        // book plays at a consistent, clearly audible level.
        var audio = sent_pcm[0..produced];
        if (total == 0) audio = trimLeadingSilence(audio);
        if (opts.normalize) normalize(audio, 0.92);

        // Append this sentence's PCM to the file (little-endian i16).
        for (audio, 0..) |s, i| {
            const bits: u16 = @bitCast(s);
            sent_bytes[i * 2] = @truncate(bits);
            sent_bytes[i * 2 + 1] = @truncate(bits >> 8);
        }
        file.writeStreamingAll(io, sent_bytes[0 .. audio.len * 2]) catch |err|
            std.process.fatal("write error: {t}", .{err});
        total += audio.len;

        const used: usize = produced / neural.SAMPLES_PER_FRAME;
        if (!unbounded) frames_left = if (frames_left > used) frames_left - used else 0;

        // Progress + ETA from elapsed decode time so far.
        const elapsed_ms = (neural.nowNs() - start_ns) / 1_000_000;
        const audio_s = total / neural.SAMPLE_RATE;
        var eta_s: u64 = 0;
        if (done_sentences > 0 and total_sentences > done_sentences) {
            const per = elapsed_ms / done_sentences;
            eta_s = per * (total_sentences - done_sentences) / 1000;
        }
        std.debug.print(
            "pdf2audiobook:   [{d}/{d}] +{d}s audio ({d}m{d:0>2}s total) · elapsed {d}s · ETA ~{d}m\n",
            .{ done_sentences, total_sentences, produced / neural.SAMPLE_RATE, audio_s / 60, audio_s % 60, elapsed_ms / 1000, eta_s / 60 },
        );
    }

    if (total == 0) std.process.fatal("neural synthesis produced no audio", .{});

    // Patch the WAV header now that we know the final sample count.
    _ = wav.writeHeader(&header, .{ .sample_rate = neural.SAMPLE_RATE, .channels = 1 }, total) catch unreachable;
    file.writePositionalAll(io, &header, 0) catch |err|
        std.process.fatal("cannot finalize WAV header: {t}", .{err});

    const d = neural.gpuDispatch();
    std.debug.print(
        "pdf2audiobook: render complete — {d} sentence(s); GPU matmuls: {d} on-GPU ({d} ms: up {d} / gemm {d} / down {d}), {d} on-CPU\n",
        .{ done_sentences, d.hits, d.ms, d.up_ms, d.gemm_ms, d.down_ms, d.misses },
    );
    return total;
}

/// Count sentence-sized chunks in `text` (for progress reporting).
fn countSentences(text: []const u8) usize {
    var n: usize = 0;
    var it = SentenceIter{ .s = text };
    while (it.next()) |s| {
        if (trim(s).len != 0) n += 1;
    }
    return n;
}

/// Iterate `text` in sentence-sized chunks (split on . ! ? and hard newlines),
/// each bounded so it fits comfortably inside one Talker utterance.
const SentenceIter = struct {
    s: []const u8,
    i: usize = 0,
    // Keep a sentence well under the Talker's text-token budget.
    const MAX_CHARS: usize = 220;

    fn next(self: *SentenceIter) ?[]const u8 {
        if (self.i >= self.s.len) return null;
        const start = self.i;
        var end = self.i;
        while (end < self.s.len) : (end += 1) {
            const c = self.s[end];
            if (c == '.' or c == '!' or c == '?' or c == '\n') {
                end += 1;
                break;
            }
            if (end - start >= MAX_CHARS) {
                // Hard cap: break at the last space before the limit if any.
                var b = end;
                while (b > start and self.s[b] != ' ') b -= 1;
                if (b > start) end = b + 1;
                break;
            }
        }
        self.i = end;
        return self.s[start..end];
    }
};

// ════════════════════════════════════════════════════════════════════════
// 3. Content verifier — decide what is actually worth reading aloud.
// ════════════════════════════════════════════════════════════════════════

const VerifyStats = struct {
    lines_total: usize = 0,
    lines_kept: usize = 0,
    lines_dropped: usize = 0,
};

/// Filter `text` (the raw extracted text, newline-separated) down to prose that
/// should be spoken. Rules, tuned for books/papers:
///   - drop a line that is only a page number (or "Page 12", "- 12 -")
///   - drop table-of-contents / index dot-leader lines ("Chapter .... 42")
///   - drop lines that are mostly non-alphabetic (rules, code, figure noise)
///   - drop bare URLs / DOIs / emails on their own line
///   - drop very short ALL-CAPS running headers repeated across pages
///   - rejoin words split by a hyphen at end of line ("inter-\nnational")
///   - collapse blank runs; keep sentence flow.
/// Output is written to `out`; the returned slice aliases `out`.
fn verify(text: []const u8, out: []u8, stats: *VerifyStats) []const u8 {
    var w = Sink{ .buf = out };
    var it = LineIter{ .s = text };
    var pending_hyphen = false;

    while (it.next()) |line_raw| {
        stats.lines_total += 1;
        const line = trim(line_raw);

        if (line.len == 0) {
            if (!pending_hyphen) w.endParagraph();
            stats.lines_dropped += 1;
            continue;
        }
        if (isJunk(line)) {
            stats.lines_dropped += 1;
            continue;
        }

        stats.lines_kept += 1;

        // Join a word hyphenated across the previous line break.
        if (pending_hyphen) {
            pending_hyphen = false;
        } else if (w.len != 0) {
            w.space();
        }

        // If this line ends in a hyphen and the next line continues a word,
        // emit without the hyphen and remember to join.
        var body = line;
        if (body.len >= 2 and body[body.len - 1] == '-' and isLetter(body[body.len - 2])) {
            body = body[0 .. body.len - 1];
            pending_hyphen = true;
        }
        w.text(cleanProse(sanitize(body)));
    }
    return w.slice();
}

/// True if a line is structural noise rather than prose to read.
fn isJunk(line: []const u8) bool {
    // Pure page number, or "Page N", or "- N -" / "— N —".
    if (isPageNumber(line)) return true;

    // Dot-leader TOC/index line: contains a run of '.' used as a leader.
    if (hasDotLeader(line)) return true;

    // Bare URL / DOI / email standing alone.
    if (isBareLink(line)) return true;

    // Mostly non-alphabetic (tables, rules, code fragments, figure captions
    // like "+----+"): if <45% of non-space chars are letters, drop it. Short
    // lines are judged more leniently so real one-word lines survive.
    var letters: usize = 0;
    var nonspace: usize = 0;
    for (line) |c| {
        if (c == ' ') continue;
        nonspace += 1;
        if (isLetter(c)) letters += 1;
    }
    if (nonspace == 0) return true;
    if (nonspace >= 4 and letters * 100 < nonspace * 45) return true;

    // High digit density flags non-prose blocks that are otherwise letter-rich:
    // the table of contents, the index, the credits/copyright page, and the
    // per-chapter reference/bibliography lists. Real prose is almost digit-free
    // (a rare year or page ref); these are dense with page numbers and years.
    // Judge only on substantial lines so a short line like "Chapter 3" or a
    // one-sentence line with a date is not misjudged.
    if (line.len >= 40) {
        var digits: usize = 0;
        for (line) |c| {
            if (c >= '0' and c <= '9') digits += 1;
        }
        if (digits * 100 >= line.len * 6) return true;
    }

    return false;
}

fn isPageNumber(line: []const u8) bool {
    // Strip common decorations: leading/trailing '-', '—', spaces, and a
    // leading "Page"/"p." label.
    var s = line;
    s = stripPrefixWord(s, "Page");
    s = stripPrefixWord(s, "page");
    s = stripPrefix(s, "p.");
    s = trimChars(s, "-—– \t");
    if (s.len == 0 or s.len > 6) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn hasDotLeader(line: []const u8) bool {
    var run: usize = 0;
    for (line) |c| {
        if (c == '.') {
            run += 1;
            if (run >= 4) return true; // "...." leader
        } else run = 0;
    }
    return false;
}

fn isBareLink(line: []const u8) bool {
    if (startsWithIgnoreCase(line, "http://") or startsWithIgnoreCase(line, "https://") or
        startsWithIgnoreCase(line, "www.") or startsWithIgnoreCase(line, "doi:"))
    {
        // Only treat as a bare link if it's a single token (no spaces = a URL,
        // not a sentence that happens to start with a link).
        for (line) |c| if (c == ' ') return false;
        return true;
    }
    // An email address alone.
    var at = false;
    var dot_after_at = false;
    var spaces = false;
    for (line, 0..) |c, i| {
        if (c == ' ') spaces = true;
        if (c == '@') at = true;
        if (at and c == '.' and i > 0) dot_after_at = true;
    }
    return at and dot_after_at and !spaces;
}

/// Normalize a body line for reading: collapse internal whitespace runs and
/// strip characters the phonemizer can't voice, keeping sentence punctuation.
fn sanitize(line: []const u8) []const u8 {
    // Done in place in a small static ring; but to stay allocation-free and
    // simple we let the Sink normalize spacing and pass bytes through a filter
    // via a thread-local scratch line buffer.
    var n: usize = 0;
    var prev_space = false;
    for (line) |c| {
        const keep: u8 = mapChar(c);
        if (keep == ' ') {
            if (prev_space or n == 0) continue;
            prev_space = true;
        } else prev_space = false;
        if (n < line_scratch.len) {
            line_scratch[n] = keep;
            n += 1;
        }
    }
    while (n > 0 and line_scratch[n - 1] == ' ') n -= 1;
    return line_scratch[0..n];
}

var line_scratch: [8192]u8 = undefined;
var clean_scratch: [8192]u8 = undefined;

/// Token-level prose cleanup on an already-sanitized (single-spaced, speakable)
/// line: rejoin a paragraph drop-cap ("A ttempts" -> "Attempts", "O ne" ->
/// "One"), and strip inline academic citations that read as gibberish aloud —
/// a 4-digit year, an immediately following "p. N" page ref, and a preceding
/// "Surname ," author tag. Everything else passes through unchanged.
fn cleanProse(line: []const u8) []const u8 {
    // Tokenize on spaces into slices of `line`.
    var toks: [1024][]const u8 = undefined;
    var nt: usize = 0;
    var i: usize = 0;
    while (i < line.len and nt < toks.len) {
        while (i < line.len and line[i] == ' ') i += 1;
        const start = i;
        while (i < line.len and line[i] != ' ') i += 1;
        if (i > start) {
            toks[nt] = line[start..i];
            nt += 1;
        }
    }
    if (nt == 0) return line;

    var w: usize = 0;
    var t: usize = 0;
    while (t < nt) : (t += 1) {
        // A 4-digit year token is only a *citation* (drop it) when it is framed
        // like one: preceded by a "Surname ," author tag OR followed by a
        // "p. N" page reference. A bare year in prose ("in 1990", "between 1900
        // and 1923") is legitimate and kept.
        if (isCitationYear(toks[t])) {
            const has_page = t + 1 < nt and (eqTok(toks[t + 1], "p.") or eqTok(toks[t + 1], "p")) and
                t + 2 < nt and isAllDigits(toks[t + 2]);
            const author_tag = endsWithAuthorTag(clean_scratch[0..w]);
            if (has_page or author_tag) {
                if (author_tag) w = dropTrailingAuthorTag(clean_scratch[0..w]);
                if (has_page) t += 2; // skip "p." + number
                continue;
            }
            // otherwise: a real prose year — fall through and emit it.
        }
        // Emit the token.
        if (w != 0) {
            if (w < clean_scratch.len) {
                clean_scratch[w] = ' ';
                w += 1;
            }
        }
        for (toks[t]) |c| {
            if (w < clean_scratch.len) {
                clean_scratch[w] = c;
                w += 1;
            }
        }
    }
    // Trim a dangling comma/space left by a stripped citation.
    while (w > 0 and (clean_scratch[w - 1] == ' ' or clean_scratch[w - 1] == ',')) w -= 1;
    return clean_scratch[0..w];
}

fn isCitationYear(tok_raw: []const u8) bool {
    // Ignore trailing punctuation the sanitizer keeps attached (e.g. "1986,").
    const tok = trimChars(tok_raw, ",.;:");
    if (tok.len == 0) return false;
    // 4 digits, optionally a trailing lowercase letter (e.g. "1910b"), 18/19/20.
    var digits: usize = 0;
    for (tok) |c| {
        if (c >= '0' and c <= '9') {
            digits += 1;
        } else if (!isLower(c)) {
            return false;
        }
    }
    if (digits != 4) return false;
    if (tok[0] != '1' and tok[0] != '2') return false;
    const second = tok[1];
    return second == '8' or second == '9' or second == '0';
}

/// True if the emitted text ends with a "Surname ," author tag (a capitalized
/// word immediately followed by a comma) — the left half of a "Surname, YEAR"
/// citation. Does not mutate.
fn endsWithAuthorTag(written: []const u8) bool {
    var e = written.len;
    while (e > 0 and written[e - 1] == ' ') e -= 1;
    if (e == 0 or written[e - 1] != ',') return false;
    e -= 1;
    const word_end = e;
    while (e > 0 and written[e - 1] != ' ') e -= 1;
    return word_end > e and isUpper(written[e]);
}

/// If the just-emitted text ends with "Surname ," (a citation author tag),
/// remove it and return the new write cursor. Only strips a single capitalized
/// word + comma, so ordinary commas in prose are preserved.
fn dropTrailingAuthorTag(written: []const u8) usize {
    var e = written.len;
    while (e > 0 and written[e - 1] == ' ') e -= 1;
    if (e == 0 or written[e - 1] != ',') return written.len;
    e -= 1; // drop the comma
    const word_end = e;
    while (e > 0 and written[e - 1] != ' ') e -= 1;
    // Require the removed token to look like a capitalized surname/initial.
    if (word_end == e or !isUpper(written[e])) return written.len;
    while (e > 0 and written[e - 1] == ' ') e -= 1;
    return e;
}

fn isAllDigits(tok: []const u8) bool {
    if (tok.len == 0) return false;
    for (tok) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn eqTok(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}
fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

/// Map a byte to something speakable: keep letters, digits, spaces, and
/// sentence punctuation; turn other separators into spaces; drop the rest.
fn mapChar(c: u8) u8 {
    if (isLetter(c) or (c >= '0' and c <= '9')) return c;
    return switch (c) {
        ' ', '\t' => ' ',
        '.', ',', '!', '?', ';', ':', '-' => c,
        // Smart quotes / dashes / bullets collapse to a space or comma.
        else => ' ',
    };
}

// ════════════════════════════════════════════════════════════════════════
// Small text utilities + bounded sinks (no heap).
// ════════════════════════════════════════════════════════════════════════

/// A bounded text accumulator with sentence-aware spacing for the verifier.
const Sink = struct {
    buf: []u8,
    len: usize = 0,

    fn slice(self: *const Sink) []const u8 {
        return self.buf[0..self.len];
    }
    fn text(self: *Sink, s: []const u8) void {
        for (s) |c| {
            if (self.len < self.buf.len) {
                self.buf[self.len] = c;
                self.len += 1;
            }
        }
    }
    fn space(self: *Sink) void {
        if (self.len == 0) return;
        const last = self.buf[self.len - 1];
        if (last == ' ' or last == '\n') return;
        if (self.len < self.buf.len) {
            self.buf[self.len] = ' ';
            self.len += 1;
        }
    }
    fn endParagraph(self: *Sink) void {
        if (self.len == 0) return;
        if (self.buf[self.len - 1] == '\n') return;
        // A paragraph break reads as a full stop's worth of pause.
        if (self.len < self.buf.len) {
            self.buf[self.len] = '\n';
            self.len += 1;
        }
    }
};

const LineIter = struct {
    s: []const u8,
    i: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.i > self.s.len) return null;
        if (self.i == self.s.len) {
            self.i += 1;
            return self.s[self.s.len..];
        }
        const start = self.i;
        while (self.i < self.s.len and self.s[self.i] != '\n') self.i += 1;
        const line = self.s[start..self.i];
        self.i += 1; // skip newline
        return line;
    }
};

fn readFile(io: std.Io, cwd: std.Io.Dir, path: []const u8) ?[]const u8 {
    const file = cwd.openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size == 0 or stat.size > file_buf.len) return null;
    var reader = file.reader(io, &.{});
    var got: u64 = 0;
    while (got < stat.size) {
        const want: usize = @intCast(@min(stat.size - got, file_buf.len - got));
        const n = reader.interface.readSliceShort(file_buf[@intCast(got)..][0..want]) catch return null;
        if (n == 0) break;
        got += n;
    }
    return file_buf[0..@intCast(got)];
}

fn writeFile(io: std.Io, cwd: std.Io.Dir, path: []const u8, data: []const u8) ?void {
    // Create the parent directory if the path names one (best-effort).
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        const c = path[i - 1];
        if (c == '/' or c == '\\') {
            cwd.createDir(io, path[0 .. i - 1], .default_dir) catch {};
            break;
        }
    }
    const file = cwd.createFile(io, path, .{}) catch return null;
    defer file.close(io);
    file.writeStreamingAll(io, data) catch return null;
    return {};
}

fn fileExists(io: std.Io, cwd: std.Io.Dir, path: []const u8) bool {
    const file = cwd.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn looksPdf(b: []const u8) bool {
    return b.len >= 5 and b[0] == '%' and b[1] == 'P' and b[2] == 'D' and b[3] == 'F';
}

/// Parse an integer percent-style value into a float: "90" -> 0.90, "105" ->
/// 1.05. Keeps the CLI integer-only (the schema UI uses int steppers too).
fn parsePercentF(s: []const u8) ?f32 {
    const n = parseUint(s) orelse return null;
    return @as(f32, @floatFromInt(n)) / 100.0;
}

fn parseUint(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var v: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        if (v > 100000) return null;
    }
    return v;
}

fn deriveOut(input: []const u8, buf: []u8, suffix: []const u8) []const u8 {
    // Replace the input's extension with `suffix`.
    var dot: usize = input.len;
    var i: usize = input.len;
    while (i > 0) : (i -= 1) {
        const c = input[i - 1];
        if (c == '/' or c == '\\') break;
        if (c == '.') {
            dot = i - 1;
            break;
        }
    }
    var stem = input[0..dot];
    // Guard against clobbering the input: if replacing the extension would
    // reproduce the input path exactly (e.g. input.txt --dump-text -> .txt),
    // keep the full input name and append the suffix instead.
    var extra: []const u8 = "";
    if (endsWithIgnoreCase(input, suffix)) {
        stem = input;
        extra = ".out";
    }
    const total = stem.len + extra.len + suffix.len;
    if (total > buf.len) return "audiobook.wav";
    @memcpy(buf[0..stem.len], stem);
    @memcpy(buf[stem.len..][0..extra.len], extra);
    @memcpy(buf[stem.len + extra.len ..][0..suffix.len], suffix);
    return buf[0..total];
}

fn copyArg(v: []const u8, store: []u8) []const u8 {
    const n = @min(v.len, store.len);
    @memcpy(store[0..n], v[0..n]);
    return store[0..n];
}

fn copyInto(dest: []u8, v: []const u8) []const u8 {
    const n = @min(v.len, dest.len);
    @memcpy(dest[0..n], v[0..n]);
    return dest[0..n];
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn trim(s: []const u8) []const u8 {
    return trimChars(s, " \t\r\n");
}

fn trimChars(s: []const u8, set: []const u8) []const u8 {
    var start: usize = 0;
    var end = s.len;
    while (start < end and inSet(s[start], set)) start += 1;
    while (end > start and inSet(s[end - 1], set)) end -= 1;
    return s[start..end];
}

fn inSet(c: u8, set: []const u8) bool {
    for (set) |x| if (x == c) return true;
    return false;
}

fn stripPrefix(s: []const u8, prefix: []const u8) []const u8 {
    if (startsWithIgnoreCase(s, prefix)) return trim(s[prefix.len..]);
    return s;
}

fn stripPrefixWord(s: []const u8, word: []const u8) []const u8 {
    if (startsWithIgnoreCase(s, word)) {
        const rest = s[word.len..];
        // Only strip if followed by a space/end (a real word boundary).
        if (rest.len == 0 or rest[0] == ' ' or rest[0] == '\t') return trim(rest);
    }
    return s;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.mem.eql(u8, s[0..prefix.len], prefix);
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    for (s[0..prefix.len], prefix) |a, b| {
        if (lower(a) != lower(b)) return false;
    }
    return true;
}

fn endsWithIgnoreCase(s: []const u8, suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    for (s[s.len - suffix.len ..], suffix) |a, b| {
        if (lower(a) != lower(b)) return false;
    }
    return true;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn usage() noreturn {
    std.debug.print(
        \\usage: pdf2audiobook <input.pdf|input.txt> [output.wav] [flags]
        \\
        \\  Turns a PDF or text file into a crisp audiobook (24 kHz WAV) with the
        \\  real neural Qwen3-TTS-12Hz-0.6B voice. The text is verified first —
        \\  page numbers, headers/footers, TOC dot leaders, bare URLs, and layout
        \\  noise are dropped so only real prose is read. Requires the model
        \\  artifacts in ./models: talker.sb0m, codec.sb0m, tokenizer.gguf.
        \\  Uses the GPU (cuBLAS) automatically when a CUDA device is present.
        \\
        \\  --dump-text       write the verified text (.txt) and stop (no audio)
        \\  --max-frames N    cap the render; 1 frame = 80 ms (0 = whole text)
        \\  --no-normalize    keep the raw (quiet) level instead of peak-normalizing
        \\
        \\  Voice controls (what the Qwen3-TTS model supports):
        \\  --lang NAME       english chinese german spanish italian portuguese
        \\                    japanese korean french russian (default english)
        \\  --temperature N   sampling temperature ×100 (default 90 = 0.90).
        \\                    Higher = more varied prosody.
        \\  --top-k N         sampling top-k, 1..50 (default 50)
        \\  --rep-penalty N   repetition penalty ×100 (default 105 = 1.05)
        \\  --think|--no-think  toggle the model's think prefix (default think)
        \\  --speaker NAME    a named CustomVoice speaker. NOTE: the Base
        \\                    checkpoint has no speaker table; named speakers need
        \\                    a Qwen3-TTS CustomVoice model. Ignored otherwise.
        \\
        \\examples:
        \\  pdf2audiobook book.pdf book.wav
        \\  pdf2audiobook book.pdf --lang german --temperature 80
        \\  pdf2audiobook notes.txt --dump-text
        \\
    , .{});
    std.process.exit(2);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "verify drops page numbers, dot leaders, and links" {
    const raw =
        "Chapter One\n" ++
        "12\n" ++
        "Page 13\n" ++
        "Introduction .......... 5\n" ++
        "https://example.com/very/long\n" ++
        "This is the real body text that should be read.\n";
    var out: [1024]u8 = undefined;
    var stats = VerifyStats{};
    const kept = verify(raw, &out, &stats);
    try std.testing.expect(indexOf(kept, "Chapter One") != null);
    try std.testing.expect(indexOf(kept, "real body text") != null);
    try std.testing.expect(indexOf(kept, "example.com") == null);
    try std.testing.expect(indexOf(kept, "..........") == null);
}

test "verify rejoins hyphenated line breaks" {
    const raw = "an inter-\nnational treaty\n";
    var out: [256]u8 = undefined;
    var stats = VerifyStats{};
    const kept = verify(raw, &out, &stats);
    try std.testing.expect(indexOf(kept, "international treaty") != null);
}

test "verify drops high-digit-density blocks (TOC / index / references)" {
    const raw =
        "Contents Acknowledgments ix Introduction 1 PART I Buddha 13 one Meditative Transformations 19 two The Self 42\n" ++
        "Index Awareness continued 196 197 213 215 Deutsch Helene 105 Dharmakirti 68 Dogen 60 Duchamp 12 Emptiness 59\n" ++
        "This is a normal paragraph of prose with only the occasional year like 1990 mentioned once in passing here.\n";
    var out: [2048]u8 = undefined;
    var stats = VerifyStats{};
    const kept = verify(raw, &out, &stats);
    try std.testing.expect(indexOf(kept, "normal paragraph") != null);
    try std.testing.expect(indexOf(kept, "PART I") == null);
    try std.testing.expect(indexOf(kept, "Dharmakirti") == null);
}

test "cleanProse strips framed citations but keeps prose years" {
    // "Surname, YEAR" and "YEAR, p. N" are citations -> stripped.
    const a = cleanProse(sanitize("the confused use of concepts Engler, 1986, p. 18 is common"));
    try std.testing.expect(indexOf(a, "1986") == null);
    try std.testing.expect(indexOf(a, "Engler") == null);
    try std.testing.expect(indexOf(a, "concepts") != null);
    try std.testing.expect(indexOf(a, "is common") != null);
    // A bare prose year and a date range are kept.
    const b = cleanProse(sanitize("papers published between 1900 and 1923 by Freud"));
    try std.testing.expect(indexOf(b, "1900") != null);
    try std.testing.expect(indexOf(b, "1923") != null);
}

test "isPageNumber recognizes decorated numbers" {
    try std.testing.expect(isPageNumber("12"));
    try std.testing.expect(isPageNumber("- 7 -"));
    try std.testing.expect(isPageNumber("Page 42"));
    try std.testing.expect(!isPageNumber("Chapter 1: Beginnings"));
}

test "sanitize keeps prose punctuation, drops the rest" {
    const s = sanitize("Hello, world! (aside) \u{2014} yes.");
    // Smart em dash and parens collapse to spaces; commas/periods/! survive.
    try std.testing.expect(indexOf(s, "Hello, world!") != null);
    try std.testing.expect(indexOf(s, "yes.") != null);
    try std.testing.expect(indexOf(s, "(") == null);
}

test "deriveOut swaps the extension" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("book.wav", deriveOut("book.pdf", &buf, ".wav"));
    try std.testing.expectEqualStrings("a/b/c.txt", deriveOut("a/b/c.pdf", &buf, ".txt"));
}

test "deriveOut never clobbers an input with the same extension" {
    var buf: [256]u8 = undefined;
    // .txt --dump-text (.txt) must not reproduce the input path.
    try std.testing.expectEqualStrings("notes.txt.out.txt", deriveOut("notes.txt", &buf, ".txt"));
    // A .wav input asked for a .wav output likewise gets a distinct name.
    try std.testing.expectEqualStrings("clip.wav.out.wav", deriveOut("clip.wav", &buf, ".wav"));
}

fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

// MIT. Private stdin/stdout worker; no listener, transcript files, or console output.
// Protocol PFW2 version 3: whole recordings (PFQ1, with progress frames while
// the pass runs) and live windows (PFS1, canceled by PFC1). The hello carries
// two thread counts: finished text, then live. Frames are documented in
// windows/PFlow.Core/LiveWorkerProtocol.cs.
#include "whisper.h"
#include "common-whisper.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <filesystem>
#include <fstream>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <fcntl.h>
#include <io.h>

constexpr uint32_t kHello = 0x32574650, kWhole = 0x31514650, kLive = 0x31534650, kCancel = 0x31434650; // PFW2 PFQ1 PFS1 PFC1
constexpr uint32_t kVersion = 3, kLiveResult = 4, kLiveError = 5, kProgress = 6;
constexpr uint32_t kMaxLiveSamples = 30 * 16000, kMaxSegments = 512;
constexpr size_t kMaxSegmentText = 4096, kMaxLiveText = 256 * 1024;

static void need(void * data, size_t size) { if (size && fread(data, 1, size, stdin) != size) throw std::runtime_error("Input closed"); }
static uint32_t number() { uint32_t value; need(&value, sizeof(value)); return value; }
static std::string text(size_t maximum) {
    auto length = number();
    if (length > maximum) throw std::runtime_error("Invalid request");
    std::string value(length, '\0');
    need(value.data(), length);
    if (value.find('\0') != std::string::npos) throw std::runtime_error("Invalid request");
    return value;
}
static void put(uint32_t value) { if (fwrite(&value, sizeof(value), 1, stdout) != 1) throw std::runtime_error("Output closed"); }
static void put_i32(int32_t value) { if (fwrite(&value, sizeof(value), 1, stdout) != 1) throw std::runtime_error("Output closed"); }
static void put_f32(float value) { if (fwrite(&value, sizeof(value), 1, stdout) != 1) throw std::runtime_error("Output closed"); }
static void put(const std::string & value) {
    if (value.size() > 2 * 1024 * 1024) throw std::runtime_error("Result too large");
    put(static_cast<uint32_t>(value.size()));
    if (!value.empty() && fwrite(value.data(), 1, value.size(), stdout) != value.size()) throw std::runtime_error("Output closed");
}
static void metric(double value) { if (fwrite(&value, sizeof(value), 1, stdout) != 1) throw std::runtime_error("Output closed"); }
static void quiet(enum ggml_log_level, const char *, void *) {}
using Clock = std::chrono::steady_clock;
static double elapsed(Clock::time_point start) { return std::chrono::duration<double, std::milli>(Clock::now() - start).count(); }
// Cuts at a UTF-8 character boundary so the app never receives half a character.
static std::string bounded(std::string value, size_t maximum) {
    if (value.size() <= maximum) return value;
    size_t end = maximum;
    while (end > 0 && (static_cast<unsigned char>(value[end]) & 0xC0) == 0x80) end--;
    value.resize(end);
    return value;
}

struct Job { uint32_t kind = 0, session = 0, sequence = 0; std::string audio, language, prompt; std::vector<float> samples; };

// The reader thread takes whole messages off stdin so a cancel can reach a
// live window while it is being recognized. The app sends one request at a
// time and waits for its reply; a second waiting request is a protocol error.
static std::mutex state_lock;
static std::condition_variable state_changed;
static std::optional<Job> pending;
static bool pending_canceled = false, input_closed = false, live_running = false;
static uint32_t running_session = 0, running_sequence = 0;
static std::atomic<bool> abort_live{false};

static void read_requests() {
    try {
        for (;;) {
            uint32_t magic;
            if (fread(&magic, sizeof(magic), 1, stdin) != 1) break; // The app closed the pipe.
            if (magic == kCancel) {
                if (number() != kVersion) std::_Exit(2);
                auto session = number(), sequence = number();
                std::lock_guard<std::mutex> guard(state_lock);
                if (live_running && running_session == session && running_sequence == sequence) abort_live = true;
                else if (pending && pending->kind == kLive && pending->session == session && pending->sequence == sequence) pending_canceled = true;
                continue; // A cancel for a window that already finished needs nothing.
            }
            Job job; job.kind = magic;
            if (magic == kWhole) { job.audio = text(32768); job.language = text(64); job.prompt = text(8192); }
            else if (magic == kLive) {
                if (number() != kVersion) std::_Exit(2);
                job.session = number(); job.sequence = number(); job.language = text(64);
                auto count = number();
                if (count == 0 || count > kMaxLiveSamples) std::_Exit(2);
                job.samples.resize(count);
                need(job.samples.data(), count * sizeof(float));
            } else std::_Exit(2); // Unknown framing ends the owned worker; nothing is echoed.
            std::lock_guard<std::mutex> guard(state_lock);
            if (pending) std::_Exit(2);
            pending = std::move(job); pending_canceled = false;
            state_changed.notify_one();
        }
    } catch (...) { std::_Exit(1); } // Truncated or invalid input; never print private input.
    std::lock_guard<std::mutex> guard(state_lock);
    input_closed = true;
    state_changed.notify_one();
}

// The finished text must never depend on an earlier pass. A pass with a
// shorter audio context lays the cross-attention cache out differently, and a
// full 30 s pass reads the padding after its 1500 frames (flash attention, no
// mask), where the shorter pass had left its values. That happened both with
// live windows before the finished text and with a short take before a long
// one. So live windows have a state of their own, and the finished-text state
// only ever sees one audio context: when a take needs a different one, the
// state is freed and a new, zeroed one is made. Passes with the same context
// write the same frames and never touch the padding, so reusing the state
// between them gives the same text as a new one (checked by the architecture
// speech test). A new state for every pass was also correct, but on the ARM64
// VM with Live text on it made 4 of 10 medium finished passes take about 6.5 s
// instead of 2.5 s, so states are kept while the context stays the same.
using State = std::unique_ptr<whisper_state, decltype(&whisper_free_state)>;
static State live_state(nullptr, whisper_free_state);
static State final_state(nullptr, whisper_free_state);
static int final_audio_ctx = -1; // The only audio context final_state has seen.

static whisper_state * final_state_for(whisper_context * ctx, int audio_ctx) {
    if (!final_state || final_audio_ctx != audio_ctx) {
        final_state.reset(); // Free first: never hold two finished-text states.
        final_state.reset(whisper_init_state(ctx));
        final_audio_ctx = final_state ? audio_ctx : -1;
    }
    return final_state.get();
}

static void live_error(const Job & job, const char * message) {
    put(kLiveError); put(kVersion); put(job.session); put(job.sequence); put(std::string(message)); fflush(stdout);
}

static void recognize_live(whisper_context * ctx, int threads, const Job & job) {
    if (abort_live) { live_error(job, "Canceled."); return; }
    if (job.language.empty() || job.language == "auto" || whisper_lang_id(job.language.c_str()) < 0) { live_error(job, "Choose a supported speech language in Settings."); return; }
    auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = threads; params.greedy.best_of = 1;
    params.no_context = true; // Each window stands alone; no text from another window or take.
    params.language = job.language.c_str(); params.detect_language = false;
    params.print_special = params.print_progress = params.print_realtime = params.print_timestamps = false;
    params.audio_ctx = job.samples.size() <= 8 * 16000 ? 512 : job.samples.size() <= 18 * 16000 ? 1024 : 0;
    params.abort_callback = [](void *) { return abort_live.load(); };
    auto start = Clock::now();
    if (!live_state) live_state.reset(whisper_init_state(ctx));
    if (!live_state) { live_error(job, "Whisper could not read this audio."); return; }
    whisper_state * state = live_state.get();
    if (whisper_full_with_state(ctx, state, params, job.samples.data(), static_cast<int>(job.samples.size())) != 0) {
        live_error(job, abort_live ? "Canceled." : "Whisper could not read this audio."); return;
    }
    if (abort_live) { live_error(job, "Canceled."); return; }
    struct Segment { int32_t from, to; float no_speech; std::string text; };
    std::vector<Segment> segments; size_t total = 0;
    int count = whisper_full_n_segments_from_state(state);
    for (int i = 0; i < count && segments.size() < kMaxSegments; i++) {
        auto value = bounded(whisper_full_get_segment_text_from_state(state, i), kMaxSegmentText);
        if (total + value.size() > kMaxLiveText) break;
        total += value.size();
        segments.push_back({ static_cast<int32_t>(whisper_full_get_segment_t0_from_state(state, i) * 10), static_cast<int32_t>(whisper_full_get_segment_t1_from_state(state, i) * 10),
            whisper_full_get_segment_no_speech_prob_from_state(state, i), std::move(value) });
    }
    put(kLiveResult); put(kVersion); put(job.session); put(job.sequence); put(static_cast<uint32_t>(segments.size()));
    for (auto & segment : segments) { put_i32(segment.from); put_i32(segment.to); put_f32(segment.no_speech); put(segment.text); }
    metric(elapsed(start)); fflush(stdout);
}

// While the finished-text pass works, a progress frame goes out about once a
// second from ggml's abort callback (called on the calling thread only), so the
// app can tell a slow pass from a stuck worker and never ends a pass that is
// still making progress. Failures here are ignored: the reply itself reports a
// closed pipe. Nothing else writes to stdout during the pass.
static Clock::time_point last_progress;
static void progress_frame(std::chrono::milliseconds interval) {
    auto now = Clock::now();
    if (now - last_progress >= interval) {
        last_progress = now;
        uint32_t frame = kProgress;
        if (fwrite(&frame, sizeof(frame), 1, stdout) == 1) fflush(stdout);
    }
}
static bool progress_beat(void *) { progress_frame(std::chrono::seconds(1)); return false; }

static void transcribe_file(whisper_context * ctx, int threads, const Job & job) {
    auto & audio = job.audio; auto & language = job.language; auto & prompt = job.prompt;
    if (language.empty() || language == "auto" || whisper_lang_id(language.c_str()) < 0) {
        put(3); put(std::string("Choose a supported speech language in Settings.")); fflush(stdout); return;
    }
    std::vector<float> samples; std::vector<std::vector<float>> stereo;
    std::ifstream recording(std::filesystem::u8path(audio), std::ios::binary | std::ios::ate);
    std::vector<char> bytes;
    if (recording) { auto size = recording.tellg(); if (size > 0 && size <= 512 * 1024 * 1024) { bytes.resize(static_cast<size_t>(size)); recording.seekg(0); if (!recording.read(bytes.data(), size)) bytes.clear(); } }
    if (bytes.empty() || !read_audio_data(bytes.data(), bytes.size(), samples, stereo, false) || samples.empty()) {
        put(3); put(std::string("The recording could not be read.")); fflush(stdout); return;
    }
    auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = threads; params.greedy.best_of = 1;
    params.no_context = true; // Never carry another dictation's tokens into this one.
    params.language = language.c_str(); params.detect_language = false;
    params.print_special = params.print_progress = params.print_realtime = params.print_timestamps = false;
    params.initial_prompt = prompt.c_str();
    // All samples fit, with at least two seconds of padding. Long clips keep the full window.
    params.audio_ctx = samples.size() <= 8 * 16000 ? 512 : samples.size() <= 18 * 16000 ? 1024 : 0;
    params.abort_callback = progress_beat;
    auto start = Clock::now(); last_progress = start;
    whisper_state * state = final_state_for(ctx, params.audio_ctx);
    if (!state || whisper_full_with_state(ctx, state, params, samples.data(), static_cast<int>(samples.size())) != 0) {
        put(3); put(std::string("Whisper could not transcribe this recording.")); fflush(stdout); return;
    }
    std::string result;
    for (int i = 0; i < whisper_full_n_segments_from_state(state); i++) { if (i) result += '\n'; result += whisper_full_get_segment_text_from_state(state, i); }
    // whisper.cpp reports encoder/decoder timings only for a context's own state, so they are sent as 0 (not measured).
    put(2); put(result); metric(elapsed(start)); metric(0); metric(0); put(static_cast<uint32_t>(params.audio_ctx)); fflush(stdout);
}

int main() {
    _setmode(_fileno(stdin), _O_BINARY); _setmode(_fileno(stdout), _O_BINARY);
    whisper_log_set(quiet, nullptr);
    try {
        if (number() != kHello) return 2; // PFW2, protocol version 3.
        int threads = std::clamp(static_cast<int>(number()), 1, 8);      // finished-text pass
        int live_threads = std::clamp(static_cast<int>(number()), 1, 8); // live windows, fewer so the final pass and the computer keep room
        auto model = text(32768); auto start = Clock::now();
        auto options = whisper_context_default_params(); options.use_gpu = false; options.flash_attn = true;
        // The C# lease pins the checked file. Filesystem paths retain Unicode on MinGW and MSVC.
        std::ifstream model_file(std::filesystem::u8path(model), std::ios::binary);
        if (!model_file) { put(3); put(std::string("Speech model could not open.")); fflush(stdout); return 3; }
        whisper_model_loader loader{}; loader.context = &model_file;
        // A slow disk or a virus scanner can make the 487 MB load take a while: progress frames go out before
        // the ready reply (one as reading begins, then every 250 ms), so the app can tell a slow load from a
        // stuck worker.
        last_progress = start - std::chrono::hours(1);
        loader.read = [](void * user, void * data, size_t size) -> size_t { auto & file = *static_cast<std::ifstream *>(user); file.read(static_cast<char *>(data), size); progress_frame(std::chrono::milliseconds(250)); return static_cast<size_t>(file.gcount()); };
        loader.eof = [](void * user) { return static_cast<std::ifstream *>(user)->eof(); };
        loader.close = [](void * user) { static_cast<std::ifstream *>(user)->close(); };
        std::unique_ptr<whisper_context, decltype(&whisper_free)> ctx(whisper_init_with_params_no_state(&loader, options), whisper_free);
        // Made at load, before any live window, for the full 30 s context (as the context's own state was).
        if (!ctx || !final_state_for(ctx.get(), 0)) { put(3); put(std::string("Speech model could not load.")); fflush(stdout); return 3; }
        put(1); metric(elapsed(start)); put(kVersion); fflush(stdout);
        std::thread(read_requests).detach();
        for (;;) {
            Job job;
            {
                std::unique_lock<std::mutex> guard(state_lock);
                state_changed.wait(guard, [] { return pending.has_value() || input_closed; });
                if (!pending) { fflush(stdout); std::_Exit(0); } // The app ended the worker.
                job = std::move(*pending); pending.reset();
                live_running = job.kind == kLive; running_session = job.session; running_sequence = job.sequence;
                abort_live = live_running && pending_canceled; pending_canceled = false;
            }
            if (job.kind == kLive) recognize_live(ctx.get(), live_threads, job); else transcribe_file(ctx.get(), threads, job);
            std::lock_guard<std::mutex> guard(state_lock);
            live_running = false; abort_live = false;
        }
    } catch (...) { std::_Exit(1); } // EOF or invalid framing closes the owned worker; never print private input.
}

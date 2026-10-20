// MIT. pFlow live-preview worker for macOS. Loads the Whisper model once (Metal)
// and recognizes short audio windows sent over a private stdin/stdout pipe.
// At the end of a take it can also run the finished-text pass on the take's
// own recording, with the model already loaded and exactly the decoding
// whisper-cli uses. No listener, no console output; the only file it reads
// besides the model is that recording. Protocol PFL1 is documented in
// Sources/Services/WhisperLiveWorker.swift.
#include "whisper.h"
#include "common-whisper.h"
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

static void need(void * data, size_t size) {
    if (size && fread(data, 1, size, stdin) != size) throw std::runtime_error("Input closed");
}
static uint32_t number() { uint32_t value; need(&value, sizeof(value)); return value; }
static std::string text(size_t maximum) {
    auto length = number();
    if (length > maximum) throw std::runtime_error("Invalid request");
    std::string value(length, '\0');
    need(value.data(), length);
    if (value.find('\0') != std::string::npos) throw std::runtime_error("Invalid request");
    return value;
}
template <typename T> static void put(T value) {
    if (fwrite(&value, sizeof(value), 1, stdout) != 1) throw std::runtime_error("Output closed");
}
static void put(const std::string & value) {
    if (value.size() > 4 * 1024 * 1024) throw std::runtime_error("Result too large");
    put(static_cast<uint32_t>(value.size()));
    if (!value.empty() && fwrite(value.data(), 1, value.size(), stdout) != value.size()) throw std::runtime_error("Output closed");
}
static void quiet(enum ggml_log_level, const char *, void *) {}

// The finished text, decoded exactly as `whisper-cli -m model -f audio -l
// language -t threads -otxt -np` does in whisper.cpp 1.9.5: beam search 5,
// best of 5, temperature fallback, timestamps on (so each 30 s window resumes
// at the last finished segment; without them words past about a minute were
// lost), full audio context, on a fresh state so nothing from the live windows
// carries over. Lines are whisper-cli's text output: each segment without
// leading blanks, then "\n"; the timestamps are never part of the text.
static bool finish_take(whisper_context * ctx, const std::string & path, const std::string & language, int threads, std::string & out) {
    std::vector<float> pcmf32;
    std::vector<std::vector<float>> pcmf32s;
    if (!read_audio_data(path, pcmf32, pcmf32s, false)) return false;
    whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    const int beam_size = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH).beam_search.beam_size;
    const int best_of = whisper_full_default_params(WHISPER_SAMPLING_GREEDY).greedy.best_of;
    wparams.strategy = beam_size > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY;
    wparams.print_realtime = false;
    wparams.print_progress = false;
    wparams.print_timestamps = false;
    wparams.print_special = false;
    wparams.translate = false;
    wparams.language = language.c_str();
    wparams.detect_language = false;
    wparams.n_threads = threads;
    wparams.offset_ms = 0;
    wparams.duration_ms = 0;
    wparams.token_timestamps = false;
    wparams.thold_pt = 0.01f;
    wparams.max_len = 0;
    wparams.split_on_word = false;
    wparams.audio_ctx = 0;
    wparams.debug_mode = false;
    wparams.tdrz_enable = false;
    wparams.suppress_regex = nullptr;
    wparams.initial_prompt = "";
    wparams.carry_initial_prompt = false;
    wparams.greedy.best_of = best_of;
    wparams.beam_search.beam_size = beam_size;
    wparams.temperature_inc = 0.2f;
    wparams.temperature = 0.0f;
    wparams.entropy_thold = 2.40f;
    wparams.logprob_thold = -1.00f;
    wparams.no_speech_thold = 0.6f;
    wparams.no_timestamps = false;
    wparams.suppress_nst = false;
    wparams.vad = false;
    std::unique_ptr<whisper_state, decltype(&whisper_free_state)> state(whisper_init_state(ctx), whisper_free_state);
    if (!state) return false;
    if (whisper_full_with_state(ctx, state.get(), wparams, pcmf32.data(), static_cast<int>(pcmf32.size())) != 0) return false;
    out.clear();
    const int segments = whisper_full_n_segments_from_state(state.get());
    for (int i = 0; i < segments; i++) {
        const char * text = whisper_full_get_segment_text_from_state(state.get(), i);
        while (*text == ' ' || *text == '\t') text++;
        out += text;
        out += "\n";
    }
    return true;
}
using Clock = std::chrono::steady_clock;
static double elapsed(Clock::time_point start) { return std::chrono::duration<double, std::milli>(Clock::now() - start).count(); }

int main() {
    whisper_log_set(quiet, nullptr);
    try {
        if (number() != 0x314C4650) return 2; // PFL1
        int threads = std::clamp(static_cast<int>(number()), 1, 8);
        auto model = text(32768);
        auto start = Clock::now();
        // Default context options keep Metal on, as the whole-take pass does.
        // Live windows get their own state; the finished-text pass frees it
        // first, so the helper never holds two states at once.
        std::unique_ptr<whisper_context, decltype(&whisper_free)> ctx(
            whisper_init_from_file_with_params_no_state(model.c_str(), whisper_context_default_params()), whisper_free);
        using State = std::unique_ptr<whisper_state, decltype(&whisper_free_state)>;
        State live(ctx ? whisper_init_state(ctx.get()) : nullptr, whisper_free_state);
        if (!ctx || !live) { put<uint32_t>(3); put(std::string("Speech model could not load.")); fflush(stdout); return 3; }
        put<uint32_t>(1); put(elapsed(start)); fflush(stdout);
        std::vector<float> samples;
        for (;;) {
            uint32_t magic;
            if (fread(&magic, sizeof(magic), 1, stdin) != 1) return 0; // The take ended.
            if (magic == 0x31464C50) { // PLF1: the take's finished text
                auto id = number();
                auto language = text(16);
                int final_threads = std::clamp(static_cast<int>(number()), 1, 8);
                auto path = text(4096);
                if (language.empty() || language == "auto" || whisper_lang_id(language.c_str()) < 0) {
                    put<uint32_t>(3); put(id); put(std::string("Unsupported language.")); fflush(stdout); continue;
                }
                start = Clock::now();
                live.reset();
                std::string result;
                if (!finish_take(ctx.get(), path, language, final_threads, result)) {
                    put<uint32_t>(3); put(id); put(std::string("Whisper could not read this recording.")); fflush(stdout); continue;
                }
                put<uint32_t>(4); put(id); put(result); put(elapsed(start)); fflush(stdout);
                continue;
            }
            if (magic != 0x31514C50) return 2; // PLQ1
            auto id = number();
            auto language = text(16);
            auto count = number();
            if (count == 0 || count > 30 * 16000) return 2;
            samples.resize(count);
            need(samples.data(), count * sizeof(float));
            if (language.empty() || (language != "auto" && whisper_lang_id(language.c_str()) < 0)) {
                put<uint32_t>(3); put(id); put(std::string("Unsupported language.")); fflush(stdout); continue;
            }
            auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
            params.n_threads = threads;
            params.no_context = true; // Each window stands alone; no text from another window or take.
            params.language = language.c_str();
            params.detect_language = false;
            params.print_special = params.print_progress = params.print_realtime = params.print_timestamps = false;
            // Short windows use a shorter encoder context, as on Windows.
            params.audio_ctx = count <= 8 * 16000 ? 512 : count <= 18 * 16000 ? 1024 : 0;
            start = Clock::now();
            if (!live) live.reset(whisper_init_state(ctx.get()));
            if (!live || whisper_full_with_state(ctx.get(), live.get(), params, samples.data(), static_cast<int>(count)) != 0) {
                put<uint32_t>(3); put(id); put(std::string("Whisper could not read this audio.")); fflush(stdout); continue;
            }
            auto segments = whisper_full_n_segments_from_state(live.get());
            put<uint32_t>(2); put(id); put(static_cast<uint32_t>(std::clamp(segments, 0, 512)));
            for (int i = 0; i < std::min(segments, 512); i++) {
                put(static_cast<int32_t>(whisper_full_get_segment_t0_from_state(live.get(), i) * 10));
                put(static_cast<int32_t>(whisper_full_get_segment_t1_from_state(live.get(), i) * 10));
                put(whisper_full_get_segment_no_speech_prob_from_state(live.get(), i));
                put(std::string(whisper_full_get_segment_text_from_state(live.get(), i)));
            }
            put(elapsed(start)); fflush(stdout);
        }
    } catch (...) { return 1; } // Closed pipe or bad framing ends the worker; private input is never printed.
}

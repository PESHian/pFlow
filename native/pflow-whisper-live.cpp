// MIT. pFlow live-preview worker for macOS. Loads the Whisper model once (Metal)
// and recognizes short audio windows sent over a private stdin/stdout pipe.
// No listener, no files, no console output. Protocol PFL1 is documented in
// Sources/Services/WhisperLiveWorker.swift.
#include "whisper.h"
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
    if (value.size() > 65536) throw std::runtime_error("Result too large");
    put(static_cast<uint32_t>(value.size()));
    if (!value.empty() && fwrite(value.data(), 1, value.size(), stdout) != value.size()) throw std::runtime_error("Output closed");
}
static void quiet(enum ggml_log_level, const char *, void *) {}
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
        std::unique_ptr<whisper_context, decltype(&whisper_free)> ctx(
            whisper_init_from_file_with_params(model.c_str(), whisper_context_default_params()), whisper_free);
        if (!ctx) { put<uint32_t>(3); put(std::string("Speech model could not load.")); fflush(stdout); return 3; }
        put<uint32_t>(1); put(elapsed(start)); fflush(stdout);
        std::vector<float> samples;
        for (;;) {
            uint32_t magic;
            if (fread(&magic, sizeof(magic), 1, stdin) != 1) return 0; // The take ended.
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
            if (whisper_full(ctx.get(), params, samples.data(), static_cast<int>(count)) != 0) {
                put<uint32_t>(3); put(id); put(std::string("Whisper could not read this audio.")); fflush(stdout); continue;
            }
            auto segments = whisper_full_n_segments(ctx.get());
            put<uint32_t>(2); put(id); put(static_cast<uint32_t>(std::clamp(segments, 0, 512)));
            for (int i = 0; i < std::min(segments, 512); i++) {
                put(static_cast<int32_t>(whisper_full_get_segment_t0(ctx.get(), i) * 10));
                put(static_cast<int32_t>(whisper_full_get_segment_t1(ctx.get(), i) * 10));
                put(whisper_full_get_segment_no_speech_prob(ctx.get(), i));
                put(std::string(whisper_full_get_segment_text(ctx.get(), i)));
            }
            put(elapsed(start)); fflush(stdout);
        }
    } catch (...) { return 1; } // Closed pipe or bad framing ends the worker; private input is never printed.
}

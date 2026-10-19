// MIT. Private stdin/stdout worker; no listener, transcript files, or console output.
#include "whisper.h"
#include "common-whisper.h"
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <fcntl.h>
#include <io.h>

static uint32_t number() {
    uint32_t value;
    if (fread(&value, sizeof(value), 1, stdin) != 1) throw std::runtime_error("Input closed");
    return value;
}
static std::string text(size_t maximum) {
    auto length = number();
    if (length > maximum) throw std::runtime_error("Invalid request");
    std::string value(length, '\0');
    if (length && fread(value.data(), 1, length, stdin) != length) throw std::runtime_error("Input closed");
    if (value.find('\0') != std::string::npos) throw std::runtime_error("Invalid request");
    return value;
}
static void put(uint32_t value) { if (fwrite(&value, sizeof(value), 1, stdout) != 1) throw std::runtime_error("Output closed"); }
static void put(const std::string & value) {
    if (value.size() > 2 * 1024 * 1024) throw std::runtime_error("Result too large");
    put(static_cast<uint32_t>(value.size()));
    if (fwrite(value.data(), 1, value.size(), stdout) != value.size()) throw std::runtime_error("Output closed");
}
static void metric(double value) { if (fwrite(&value, sizeof(value), 1, stdout) != 1) throw std::runtime_error("Output closed"); }
static void quiet(enum ggml_log_level, const char *, void *) {}
using Clock = std::chrono::steady_clock;
static double elapsed(Clock::time_point start) { return std::chrono::duration<double, std::milli>(Clock::now() - start).count(); }

int main() {
    _setmode(_fileno(stdin), _O_BINARY); _setmode(_fileno(stdout), _O_BINARY);
    whisper_log_set(quiet, nullptr);
    try {
        if (number() != 0x31574650) return 2; // PFW1, protocol version 1.
        int threads = std::clamp(static_cast<int>(number()), 1, 8);
        auto model = text(32768); auto start = Clock::now();
        auto options = whisper_context_default_params(); options.use_gpu = false; options.flash_attn = true;
        // The C# lease pins the checked file. Filesystem paths retain Unicode on MinGW and MSVC.
        std::ifstream model_file(std::filesystem::u8path(model), std::ios::binary);
        if (!model_file) { put(3); put(std::string("Speech model could not open.")); fflush(stdout); return 3; }
        whisper_model_loader loader{}; loader.context = &model_file;
        loader.read = [](void * user, void * data, size_t size) -> size_t { auto & file = *static_cast<std::ifstream *>(user); file.read(static_cast<char *>(data), size); return static_cast<size_t>(file.gcount()); };
        loader.eof = [](void * user) { return static_cast<std::ifstream *>(user)->eof(); };
        loader.close = [](void * user) { static_cast<std::ifstream *>(user)->close(); };
        std::unique_ptr<whisper_context, decltype(&whisper_free)> ctx(whisper_init_with_params(&loader, options), whisper_free);
        if (!ctx) { put(3); put(std::string("Speech model could not load.")); fflush(stdout); return 3; }
        put(1); metric(elapsed(start)); fflush(stdout);
        while (!feof(stdin)) {
            if (number() != 0x31514650) return 2; // PFQ1.
            auto audio = text(32768), language = text(64), prompt = text(8192);
            if (language.empty() || language == "auto" || whisper_lang_id(language.c_str()) < 0) {
                put(3); put(std::string("Choose a supported speech language in Settings.")); fflush(stdout); continue;
            }
            std::vector<float> samples; std::vector<std::vector<float>> stereo;
            std::ifstream recording(std::filesystem::u8path(audio), std::ios::binary | std::ios::ate);
            std::vector<char> bytes;
            if (recording) { auto size = recording.tellg(); if (size > 0 && size <= 512 * 1024 * 1024) { bytes.resize(static_cast<size_t>(size)); recording.seekg(0); if (!recording.read(bytes.data(), size)) bytes.clear(); } }
            if (bytes.empty() || !read_audio_data(bytes.data(), bytes.size(), samples, stereo, false) || samples.empty()) {
                put(3); put(std::string("The recording could not be read.")); fflush(stdout); continue;
            }
            auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
            params.n_threads = threads; params.greedy.best_of = 1;
            params.no_context = true; // Never carry another dictation's tokens into this one.
            params.language = language.c_str(); params.detect_language = false;
            params.print_special = params.print_progress = params.print_realtime = params.print_timestamps = false;
            params.initial_prompt = prompt.c_str();
            // All samples fit, with at least two seconds of padding. Long clips keep the full window.
            params.audio_ctx = samples.size() <= 8 * 16000 ? 512 : samples.size() <= 18 * 16000 ? 1024 : 0;
            whisper_reset_timings(ctx.get()); start = Clock::now();
            if (whisper_full(ctx.get(), params, samples.data(), static_cast<int>(samples.size())) != 0) {
                put(3); put(std::string("Whisper could not transcribe this recording.")); fflush(stdout); continue;
            }
            std::string result;
            for (int i = 0; i < whisper_full_n_segments(ctx.get()); i++) { if (i) result += '\n'; result += whisper_full_get_segment_text(ctx.get(), i); }
            auto timing = whisper_get_timings(ctx.get());
            put(2); put(result); metric(elapsed(start)); metric(timing->encode_ms); metric(timing->decode_ms + timing->batchd_ms + timing->prompt_ms); put(static_cast<uint32_t>(params.audio_ctx)); fflush(stdout);
        }
    } catch (...) { return 1; } // EOF or invalid framing closes the owned worker; never print private input.
    return 0;
}

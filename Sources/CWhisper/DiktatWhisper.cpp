#include "DiktatWhisper.h"
#include "whisper.h"
#include <atomic>
#include <string>
#include <vector>
#include <algorithm>
#include <cctype>

struct Word { std::string text; double start; double end; };
struct DiktatWhisper {
    whisper_context * context = nullptr;
    whisper_vad_context * vad = nullptr;
    std::atomic<bool> cancelled{false};
    std::atomic<int> progress{0};
    std::vector<Word> words;
};
static bool cancelled(void * data) {
    return static_cast<DiktatWhisper *>(data)->cancelled.load();
}
DiktatWhisper * diktat_whisper_create() { return new DiktatWhisper(); }
int diktat_whisper_load(DiktatWhisper * handle, const char * model) {
    whisper_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
    if (handle->cancelled.load()) return -2;
    if (handle->context) return 0;
    auto params = whisper_context_default_params();
    params.use_gpu = true;
    handle->context = whisper_init_from_file_with_params(model, params);
    if (handle->cancelled.load()) return -2;
    return handle->context ? 0 : -1;
}
int diktat_whisper_run(DiktatWhisper * handle, const float * samples, int count,
                      const char * language, const char * vad) {
    handle->words.clear();
    if (handle->cancelled.load()) return -2;
    if (!handle->context) return -1;
    if (!handle->vad) {
        auto options = whisper_vad_default_context_params();
        options.n_threads = 2;
        options.use_gpu = false;
        handle->vad = whisper_vad_init_from_file_with_params(vad, options);
        if (!handle->vad) return -1;
    }
    if (!whisper_vad_detect_speech(handle->vad, samples, count)) return -1;
    bool hasSpeech = false;
    const float * probabilities = whisper_vad_probs(handle->vad);
    for (int i = 0; i < whisper_vad_n_probs(handle->vad); ++i) {
        if (probabilities[i] >= 0.5f) { hasSpeech = true; break; }
    }
    if (!hasSpeech) return 0;
    auto params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
    params.n_threads = 4;
    params.beam_search.beam_size = 5;
    params.language = language;
    params.translate = false;
    // Audio overlap provides context. Do not feed old prose as a prompt,
    // which can repeat previous sentences over silence.
    params.no_context = true;
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.token_timestamps = true;
    params.progress_callback = [](whisper_context *, whisper_state *, int progress, void * data) {
        static_cast<DiktatWhisper *>(data)->progress.store(std::clamp(progress, 0, 99));
    };
    params.progress_callback_user_data = handle;
    params.abort_callback = cancelled;
    params.abort_callback_user_data = handle;
    // Skip wholly silent chunks, but keep the original waveform intact when
    // speech exists. Trimming individual VAD regions can remove quiet words.
    params.vad = false;
    const int result = whisper_full(handle->context, params, samples, count);
    if (handle->cancelled.load()) return -2;
    if (result != 0) return result;
    auto ctx = handle->context;
    for (int segment = 0; segment < whisper_full_n_segments(ctx); ++segment) {
        for (int token = 0; token < whisper_full_n_tokens(ctx, segment); ++token) {
            if (whisper_full_get_token_id(ctx, segment, token) >= whisper_token_eot(ctx)) continue;
            const char * bytes = whisper_full_get_token_text(ctx, segment, token);
            if (!bytes || !*bytes) continue;
            double start = whisper_full_get_token_t0(ctx, segment, token) / 100.0;
            double end = whisper_full_get_token_t1(ctx, segment, token) / 100.0;
            if (start < 0) start = whisper_full_get_segment_t0(ctx, segment) / 100.0;
            if (end < start) end = start;
            const bool startsWord = std::isspace(static_cast<unsigned char>(*bytes));
            if (startsWord || handle->words.empty()) {
                handle->words.push_back({bytes, start, end});
            } else {
                // Combine subword bytes before Swift decodes UTF-8, preserving æ/ø/å.
                auto & word = handle->words.back();
                word.text += bytes;
                word.end = std::max(word.end, end);
            }
        }
    }
    return 0;
}
int diktat_whisper_progress(DiktatWhisper * h) { return h->progress.load(); }
void diktat_whisper_reset_progress(DiktatWhisper * h) { h->progress.store(0); }
int diktat_whisper_word_count(DiktatWhisper * h) { return static_cast<int>(h->words.size()); }
const char * diktat_whisper_word_text(DiktatWhisper * h, int i) { return h->words.at(i).text.c_str(); }
double diktat_whisper_word_start(DiktatWhisper * h, int i) { return h->words.at(i).start; }
double diktat_whisper_word_end(DiktatWhisper * h, int i) { return h->words.at(i).end; }
void diktat_whisper_cancel(DiktatWhisper * h) { h->cancelled.store(true); }
void diktat_whisper_reset_cancel(DiktatWhisper * h) { h->cancelled.store(false); }
void diktat_whisper_unload(DiktatWhisper * h) {
    if (h->context) whisper_free(h->context);
    if (h->vad) whisper_vad_free(h->vad);
    h->context = nullptr;
    h->vad = nullptr;
}
void diktat_whisper_free(DiktatWhisper * h) {
    diktat_whisper_unload(h);
    delete h;
}

#include "localseek_llama.h"
#include "llama.h"

#include <algorithm>
#include <cmath>
#include <climits>
#include <cstring>
#include <exception>
#include <mutex>
#include <memory>
#include <vector>

struct ls_llama_ctx {
    llama_model   *model = nullptr;
    llama_context *ctx   = nullptr;
    int32_t        n_embd = 0;
    int32_t        max_tokens = 0;
    ~ls_llama_ctx() { if (ctx) llama_free(ctx); if (model) llama_model_free(model); }
};

static void ls_quiet_log(enum ggml_log_level, const char *, void *) {}

static void ls_backend_init_once() {
    static std::once_flag initialized;
    std::call_once(initialized, [] {
        llama_log_set(ls_quiet_log, nullptr);
        ggml_log_set(ls_quiet_log, nullptr);
        llama_backend_init();
    });
}

ls_llama_ctx *ls_llama_load(const char *model_path) {
    if (!model_path) { return nullptr; }
    // llama.cpp wirft bei inkompatiblen Modellen/Vokabularen C++-Ausnahmen; die dürfen
    // nicht über die C-Grenze entkommen (sonst std::terminate → App-Crash).
    try {
        ls_backend_init_once();

        llama_model_params mparams = llama_model_default_params();
        auto handle = std::make_unique<ls_llama_ctx>();
        handle->model = llama_model_load_from_file(model_path, mparams);
        llama_model *model = handle->model;
        if (!model) { return nullptr; }

        // BERT besitzt eine feste Positionstabelle. Die getestete E5-Konvertierung
        // hat 511 Positionen; ein pauschales 512-Token-Limit löst einen nativen
        // ggml-Abort aus, den try/catch nicht abfangen kann.
        const int32_t max_tokens = std::min<int32_t>(512, llama_model_n_ctx_train(model));
        if (max_tokens <= 0) { return nullptr; }

        llama_context_params cparams = llama_context_default_params();
        cparams.embeddings   = true;
        cparams.pooling_type = LLAMA_POOLING_TYPE_MEAN;
        cparams.n_ctx        = max_tokens * 4;
        cparams.n_batch      = max_tokens * 4;
        cparams.n_ubatch     = max_tokens * 4;
        cparams.n_seq_max    = 4;
        cparams.n_threads = 2;
        cparams.n_threads_batch = 2;

        handle->ctx = llama_init_from_model(model, cparams);
        if (!handle->ctx) { return nullptr; }
        handle->n_embd = llama_model_n_embd(model);
        handle->max_tokens = max_tokens;
        return handle.release();
    } catch (...) {
        return nullptr;
    }
}

void ls_llama_free(ls_llama_ctx *handle) {
    if (!handle) { return; }
    delete handle;
}

int32_t ls_llama_n_embd(ls_llama_ctx *handle) {
    return handle ? handle->n_embd : 0;
}

int32_t ls_llama_max_tokens(ls_llama_ctx *handle) {
    return handle ? handle->max_tokens : 0;
}

int32_t ls_llama_token_count(ls_llama_ctx *handle, const char *text) {
    if (!handle || !handle->model || !text) { return -1; }
    try {
        const size_t length = strlen(text);
        if (length > INT32_MAX) { return -1; }
        const int32_t n = llama_tokenize(llama_model_get_vocab(handle->model), text,
            (int32_t) length, nullptr, 0, true, false);
        return n < 0 && n != INT32_MIN ? -n : n;
    } catch (...) { return -1; }
}

int32_t ls_llama_embed(ls_llama_ctx *handle, const char *text,
                       float *out_embd, int32_t out_capacity) {
    const char *texts[] = {text};
    return ls_llama_embed_batch(handle, texts, 1, out_embd, out_capacity);
}

int32_t ls_llama_embed_batch(ls_llama_ctx *handle, const char * const *texts, int32_t count,
                             float *out_embd, int32_t out_capacity) {
    if (!handle || !handle->ctx || !texts || !out_embd || count < 1 || count > 4) { return -1; }
    const int32_t dimensions = handle->n_embd;
    if (dimensions <= 0 || out_capacity / dimensions < count) { return -1; }
    try {
        const llama_vocab *vocab = llama_model_get_vocab(handle->model);
        const int32_t cap = handle->max_tokens;
        const int32_t vocab_size = llama_vocab_n_tokens(vocab);
        if (cap <= 0) { return -1; }
        std::vector<std::vector<llama_token>> sequences;
        int32_t total = 0;
        for (int32_t sequence = 0; sequence < count; ++sequence) {
            if (!texts[sequence]) { return -1; }
            const size_t length = strlen(texts[sequence]);
            if (length > INT32_MAX) { return -1; }
            std::vector<llama_token> tokens(cap);
            int32_t n = llama_tokenize(vocab, texts[sequence], (int32_t) length,
                tokens.data(), cap, true, false);
            if (n < 0 && n != INT32_MIN) {
                tokens.resize(-n);
                n = llama_tokenize(vocab, texts[sequence], (int32_t) length,
                    tokens.data(), (int32_t) tokens.size(), true, false);
            }
            if (n <= 0) { return -1; }
            tokens.resize(n);
            if (n > cap) {
                const llama_token eos = llama_vocab_eos(vocab);
                const bool had_eos = eos >= 0 && tokens.back() == eos;
                tokens.resize(cap);
                if (had_eos) { tokens.back() = eos; }
            }
            if (std::any_of(tokens.begin(), tokens.end(), [vocab_size](llama_token token) {
                return token < 0 || token >= vocab_size;
            })) { return -1; }
            total += (int32_t) tokens.size();
            sequences.push_back(std::move(tokens));
        }
        llama_batch batch = llama_batch_init(total, 0, 1);
        struct BatchGuard { llama_batch batch; ~BatchGuard() { llama_batch_free(batch); } } guard{batch};
        int32_t offset = 0;
        for (int32_t sequence = 0; sequence < count; ++sequence) {
            for (int32_t position = 0; position < (int32_t) sequences[sequence].size(); ++position, ++offset) {
                batch.token[offset] = sequences[sequence][position];
                batch.pos[offset] = position;
                batch.n_seq_id[offset] = 1;
                batch.seq_id[offset][0] = sequence;
                batch.logits[offset] = 1;
            }
        }
        batch.n_tokens = total;
        if (llama_encode(handle->ctx, batch) != 0) { return -1; }
        for (int32_t sequence = 0; sequence < count; ++sequence) {
            const float *embedding = llama_get_embeddings_seq(handle->ctx, sequence);
            if (!embedding && count == 1) { embedding = llama_get_embeddings(handle->ctx); }
            if (!embedding) { return -1; }
            double norm = 0;
            for (int32_t i = 0; i < dimensions; ++i) { norm += (double) embedding[i] * embedding[i]; }
            norm = std::sqrt(norm);
            if (!(norm > 0) || !std::isfinite(norm)) { return -1; }
            for (int32_t i = 0; i < dimensions; ++i) {
                out_embd[sequence * dimensions + i] = (float) (embedding[i] / norm);
            }
        }
        return count * dimensions;
    } catch (...) { return -1; }
}

#ifndef LOCALSEEK_LLAMA_H
#define LOCALSEEK_LLAMA_H
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ls_llama_ctx ls_llama_ctx;

// Lädt das GGUF-Embedding-Modell. NULL bei Fehler.
ls_llama_ctx *ls_llama_load(const char *model_path);
void ls_llama_free(ls_llama_ctx *ctx);
// Ausgabedimension des geladenen Modells (z. B. 384). 0 wenn ungeladen.
int32_t ls_llama_n_embd(ls_llama_ctx *ctx);
int32_t ls_llama_max_tokens(ls_llama_ctx *ctx);
// Counts actual tokenizer tokens, including special tokens. Negative on failure.
int32_t ls_llama_token_count(ls_llama_ctx *ctx, const char *text);
// Bettet EINEN bereits präfigierten Text ein. Schreibt n_embd Floats (L2-normiert)
// nach out_embd (Kapazität out_capacity). Rückgabe: Anzahl geschriebener Floats, <0 bei Fehler.
int32_t ls_llama_embed(ls_llama_ctx *ctx, const char *text,
                       float *out_embd, int32_t out_capacity);
// Up to four independent sequences; each keeps the model's per-sequence token limit.
// Output is count consecutive L2-normalized vectors. Returns total floats written.
int32_t ls_llama_embed_batch(ls_llama_ctx *ctx, const char * const *texts, int32_t count,
                             float *out_embd, int32_t out_capacity);

typedef struct ls_ann_index ls_ann_index;
ls_ann_index *ls_ann_create(int32_t dimensions, int64_t capacity, int64_t maximum_capacity);
void ls_ann_free(ls_ann_index *index);
bool ls_ann_upsert(ls_ann_index *index, int64_t label, const float *vector, int32_t dimensions);
bool ls_ann_remove(ls_ann_index *index, int64_t label);
int32_t ls_ann_search(ls_ann_index *index, const float *query, int32_t dimensions,
                      int32_t limit, int64_t *labels, float *scores);
int64_t ls_ann_count(ls_ann_index *index);

#ifdef __cplusplus
}
#endif
#endif

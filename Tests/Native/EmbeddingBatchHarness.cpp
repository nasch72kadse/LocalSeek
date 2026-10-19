#include "localseek_llama.h"
#include <cassert>
#include <chrono>
#include <cmath>
#include <iostream>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    assert(argc == 2);
    auto* context = ls_llama_load(argv[1]); assert(context);
    const int dimensions = ls_llama_n_embd(context); assert(dimensions == 384);
    const int maximumTokens = ls_llama_max_tokens(context); assert(maximumTokens == 511);
    std::string longText = "passage: ";
    for (int i = 0; i < 800; ++i) longText += "Sicherheitsnachweis für die Datenbank. ";
    const std::vector<std::string> texts = {
        "passage: Invoices are payable within thirty days by bank transfer.",
        "passage: Tomaten brauchen Sonne und Wasser. 東京 und Grüße.",
        "passage: Create encrypted daily backups and test restoring files.", longText};
    const char* inputs[4]; for (int i = 0; i < 4; ++i) inputs[i] = texts[i].c_str();
    std::vector<float> batch(dimensions * 4), singles(dimensions * 4);
    assert(ls_llama_embed_batch(context, inputs, 4, batch.data(), int(batch.size())) == int(batch.size()));
    double minimumCosine = 1;
    for (int i = 0; i < 4; ++i) {
        assert(ls_llama_embed(context, inputs[i], singles.data() + i * dimensions, dimensions) == dimensions);
        double dot = 0, a = 0, b = 0;
        for (int d = 0; d < dimensions; ++d) {
            const double x = batch[i * dimensions + d], y = singles[i * dimensions + d];
            dot += x * y; a += x * x; b += y * y;
        }
        const double cosine = dot / std::sqrt(a * b);
        minimumCosine = std::min(minimumCosine, cosine);
        assert(cosine > 0.9999);
    }
    assert(ls_llama_embed_batch(context, inputs, 5, batch.data(), int(batch.size())) == -1);
    assert(ls_llama_embed_batch(context, inputs, 4, batch.data(), dimensions) == -1);
    std::cout << "{\"nativeEmbeddingBatchPassed\":true,\"sequences\":4,\"dimensions\":" << dimensions
              << ",\"maximumTokens\":" << maximumTokens << ",\"minimumCosineAgainstSingles\":" << minimumCosine
              << ",\"includesTruncationAndUnicode\":true}\n";
    ls_llama_free(context);
}

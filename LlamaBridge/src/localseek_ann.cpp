#include "localseek_llama.h"
#include "../vendor/hnswlib/hnswlib.h"
#include <algorithm>
#include <cmath>
#include <memory>
#include <mutex>
#include <vector>

struct ls_ann_index {
    size_t dimensions, maximum;
    std::mutex mutex;
    hnswlib::InnerProductSpace space;
    hnswlib::HierarchicalNSW<float> graph;
    ls_ann_index(size_t d, size_t capacity, size_t max_capacity)
        : dimensions(d), maximum(max_capacity), space(d),
          graph(&space, capacity, 16, 160, 42, true) {}
};

static bool normalized(const float *input, size_t dimensions, std::vector<float> &output) {
    if (!input) { return false; }
    double norm = 0;
    for (size_t i = 0; i < dimensions; ++i) {
        if (!std::isfinite(input[i])) { return false; }
        norm += (double) input[i] * input[i];
    }
    norm = std::sqrt(norm);
    if (!(norm > 0) || !std::isfinite(norm)) { return false; }
    output.resize(dimensions);
    for (size_t i = 0; i < dimensions; ++i) { output[i] = (float) (input[i] / norm); }
    return true;
}

ls_ann_index *ls_ann_create(int32_t dimensions, int64_t capacity, int64_t maximum_capacity) {
    if (dimensions < 1 || dimensions > 8192 || capacity < 1 || maximum_capacity < capacity ||
        (uint64_t) maximum_capacity > (4ULL * 1024 * 1024 * 1024) / (dimensions * 4ULL + 512)) {
        return nullptr;
    }
    try { return new ls_ann_index(dimensions, capacity, maximum_capacity); }
    catch (...) { return nullptr; }
}

void ls_ann_free(ls_ann_index *index) { delete index; }

bool ls_ann_upsert(ls_ann_index *index, int64_t label, const float *vector, int32_t dimensions) {
    if (!index || label <= 0 || dimensions != (int32_t) index->dimensions) { return false; }
    try {
        std::lock_guard<std::mutex> lock(index->mutex);
        std::vector<float> values;
        if (!normalized(vector, index->dimensions, values)) { return false; }
        auto existing = index->graph.label_lookup_.find((hnswlib::labeltype) label);
        if (existing != index->graph.label_lookup_.end()) {
            if (index->graph.isMarkedDeleted(existing->second)) { index->graph.unmarkDelete(label); }
        } else if (index->graph.getCurrentElementCount() >= index->graph.getMaxElements() &&
                   index->graph.getDeletedCount() == 0) {
            const size_t capacity = index->graph.getMaxElements();
            const size_t next = std::min(index->maximum, capacity + std::max<size_t>(256, capacity / 8));
            if (next <= capacity) { return false; }
            index->graph.resizeIndex(next);
        }
        index->graph.addPoint(values.data(), (hnswlib::labeltype) label,
                              existing == index->graph.label_lookup_.end());
        return true;
    } catch (...) { return false; }
}

bool ls_ann_remove(ls_ann_index *index, int64_t label) {
    if (!index || label <= 0) { return false; }
    try {
        std::lock_guard<std::mutex> lock(index->mutex);
        const auto found = index->graph.label_lookup_.find((hnswlib::labeltype) label);
        if (found != index->graph.label_lookup_.end() && !index->graph.isMarkedDeleted(found->second)) {
            index->graph.markDelete(label);
        }
        return true;
    } catch (...) { return false; }
}

int64_t ls_ann_count(ls_ann_index *index) {
    if (!index) { return 0; }
    std::lock_guard<std::mutex> lock(index->mutex);
    return (int64_t) (index->graph.getCurrentElementCount() - index->graph.getDeletedCount());
}

int32_t ls_ann_search(ls_ann_index *index, const float *query, int32_t dimensions,
                      int32_t limit, int64_t *labels, float *scores) {
    if (!index || dimensions != (int32_t) index->dimensions || limit < 1 || limit > 8192 || !labels || !scores) { return -1; }
    try {
        std::lock_guard<std::mutex> lock(index->mutex);
        std::vector<float> values;
        if (!normalized(query, index->dimensions, values)) { return -1; }
        const size_t available = index->graph.getCurrentElementCount() - index->graph.getDeletedCount();
        const size_t k = std::min<size_t>(limit, available);
        if (k == 0) { return 0; }
        index->graph.setEf(std::max<size_t>(256, k * 2));
        auto matches = index->graph.searchKnn(values.data(), k);
        const int32_t count = (int32_t) matches.size();
        for (int32_t i = count - 1; i >= 0; --i) {
            labels[i] = (int64_t) matches.top().second;
            scores[i] = 1.0f - matches.top().first;
            matches.pop();
        }
        return count;
    } catch (...) { return -1; }
}

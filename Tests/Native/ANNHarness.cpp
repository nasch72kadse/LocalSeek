#include "localseek_llama.h"
#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <numeric>
#include <random>
#include <unordered_set>
#include <vector>

using Clock = std::chrono::steady_clock;
static double milliseconds(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
static void normalize(std::vector<float>& v) {
    double sum = 0; for (float x : v) sum += double(x) * x;
    for (float& x : v) x = float(x / std::sqrt(sum));
}
static std::vector<int64_t> search(ls_ann_index* graph, const std::vector<float>& query, int k) {
    std::vector<int64_t> ids(k); std::vector<float> scores(k);
    const int n = ls_ann_search(graph, query.data(), int(query.size()), k, ids.data(), scores.data());
    assert(n >= 0); ids.resize(n); return ids;
}
int main(int argc, char** argv) {
    const int count = argc > 1 ? std::stoi(argv[1]) : 10000;
    const int dimensions = 384;
    assert(count >= 1000 && count <= 1000000);
    assert(!ls_ann_create(0, 10, 100));
    auto* graph = ls_ann_create(dimensions, 256, count + 256);
    assert(graph);
    std::mt19937 random(42); std::normal_distribution<float> noise(0, 1);
    // Clustered, distinct synthetic vectors. Retrieval recall is not semantic quality.
    std::vector<std::vector<float>> centers(128, std::vector<float>(dimensions));
    for (auto& center : centers) { for (float& x : center) x = noise(random); normalize(center); }
    std::vector<std::vector<float>> vectors(count, std::vector<float>(dimensions));
    const auto buildStart = Clock::now();
    for (int i = 0; i < count; ++i) {
        for (int d = 0; d < dimensions; ++d) vectors[i][d] = centers[i % centers.size()][d] + noise(random) * 0.025f;
        normalize(vectors[i]);
        assert(ls_ann_upsert(graph, i + 1, vectors[i].data(), dimensions));
    }
    const double buildMS = milliseconds(buildStart);
    assert(ls_ann_count(graph) == count);
    const auto& query = vectors[0];
    assert(search(graph, query, 10).front() == 1);
    assert(ls_ann_remove(graph, 1));
    assert(ls_ann_remove(graph, 1));
    assert(ls_ann_upsert(graph, 2, query.data(), dimensions)); // update while another slot is deleted
    assert(ls_ann_count(graph) == count - 1);
    assert(search(graph, query, 10).front() == 2);
    assert(ls_ann_upsert(graph, 1, query.data(), dimensions)); // undelete the same label
    assert(ls_ann_upsert(graph, 2, vectors[1].data(), dimensions));
    assert(ls_ann_count(graph) == count);
    std::vector<double> timings; double recall = 0;
    for (int i = 0; i < 32; ++i) {
        const auto& q = vectors[(i * 7919) % count];
        auto began = Clock::now(); auto candidates = search(graph, q, 256);
        timings.push_back(milliseconds(began));
        std::vector<std::pair<double,int64_t>> exact; exact.reserve(count);
        for (int row = 0; row < count; ++row) {
            double dot = 0; for (int d = 0; d < dimensions; ++d) dot += double(q[d]) * vectors[row][d];
            exact.emplace_back(dot, row + 1);
        }
        std::partial_sort(exact.begin(), exact.begin() + 10, exact.end(), std::greater<>());
        std::unordered_set<int64_t> selected(candidates.begin(), candidates.end());
        int overlap = 0; for (int k = 0; k < 10; ++k) overlap += selected.count(exact[k].second);
        recall += overlap / 10.0;
    }
    std::sort(timings.begin(), timings.end());
    assert(recall / 32 >= 0.90);
    std::cout << "{\"nativeChecksPassed\":true,\"vectors\":" << count
              << ",\"dimensions\":" << dimensions << ",\"buildSeconds\":" << buildMS / 1000
              << ",\"candidateSearchP95Milliseconds\":" << timings[30]
              << ",\"recallAt10Within256Candidates\":" << recall / 32
              << ",\"queries\":32,\"fixture\":\"128 Gaussian clusters; distinct normalized vectors\"}\n";
    ls_ann_free(graph);
}

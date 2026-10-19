import Foundation
@testable import SharedCore

/// Deterministischer Provider für Unit-Tests — kein llama. Bildet Text stabil auf
/// einen normierten 3-dim-Vektor ab (für Tests ist die Dimension frei wählbar).
struct FakeEmbeddingProvider: EmbeddingProvider {
    let dimensions: Int
    init(dimensions: Int = 3) { self.dimensions = dimensions }

    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]] {
        texts.map { text in
            var v = [Float](repeating: 0, count: dimensions)
            for (i, scalar) in text.unicodeScalars.enumerated() {
                v[i % dimensions] += Float(scalar.value % 97)
            }
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            return norm == 0 ? v : v.map { $0 / norm }
        }
    }
}

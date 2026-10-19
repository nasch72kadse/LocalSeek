import Foundation

/// e5 verlangt Präfixe: Anfragen "query: …", Dokumente "passage: …".
public enum EmbeddingKind: Sendable { case query, passage }

public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    /// Liefert je Eingabetext einen L2-normierten Vektor der Länge `dimensions`.
    func embed(_ texts: [String], kind: EmbeddingKind) async throws -> [[Float]]
}

public enum EmbeddingError: Error, Equatable {
    case modelMissing
    case modelLoadFailed
    case dimensionMismatch(expected: Int, got: Int)
    case inferenceFailed
}

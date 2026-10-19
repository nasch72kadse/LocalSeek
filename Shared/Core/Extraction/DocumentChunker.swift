import Foundation

public protocol TextTokenizer: Sendable {
    /// Includes the document prefix and special tokens used for embedding.
    func countTokens(in text: String) async throws -> Int
    func maximumTokens() async throws -> Int
}

public extension TextTokenizer {
    func maximumTokens() async throws -> Int { 511 }
}

/// Safe offline fallback without a model. UTF-8 bytes overestimate the E5 token
/// count, including scripts without word boundaries; never pretend these are exact tokens.
public struct ConservativeTokenizer: TextTokenizer {
    public init() {}
    public func countTokens(in text: String) async throws -> Int { text.utf8.count + 8 }
}

public struct DocumentChunker: Sendable {
    public static let defaultVersion = "extract-4:chunk-2:utf8"
    public let version: String
    private let tokenizer: any TextTokenizer
    private let target: Int
    private let overlap: Int

    public init(tokenizer: any TextTokenizer = ConservativeTokenizer(),
                version: String = Self.defaultVersion, target: Int = 350, overlap: Int = 40) {
        self.tokenizer = tokenizer
        self.version = version
        self.target = max(32, target)
        self.overlap = max(0, min(overlap, target / 2))
    }

    public func chunks(from document: ExtractedDocument, fileId: Int64) async throws -> [ChunkRecord] {
        let budget = min(target, try await tokenizer.maximumTokens() - 8)
        guard budget >= 16 else { throw ExtractionError.resourceLimit }
        var result: [ChunkRecord] = []
        for segment in document.segments {
            try Task.checkCancellation()
            let text = segment.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var start = text.startIndex
            while start < text.endIndex {
                try Task.checkCancellation()
                let windowEnd = text.unicodeScalars.index(start, offsetBy: budget * 8,
                                                         limitedBy: text.endIndex) ?? text.endIndex
                var boundaries = Array(text.unicodeScalars[start..<windowEnd].indices)
                boundaries.append(windowEnd)
                var low = 1, high = boundaries.count - 1, best = 0
                while low <= high {
                    let middle = (low + high) / 2
                    if try await tokenizer.countTokens(in: String(text[start..<boundaries[middle]])) <= budget {
                        best = middle; low = middle + 1
                    } else { high = middle - 1 }
                }
                guard best > 0 else { throw ExtractionError.resourceLimit }
                // Prefer a structural boundary, but certify the resulting token count again.
                var end = boundaries[best]
                if end < text.endIndex,
                   let boundary = boundaries[(best / 2)..<best].last(where: {
                       text.unicodeScalars[$0].properties.isWhitespace
                   }) {
                    let candidate = text.unicodeScalars.index(after: boundary)
                    if try await tokenizer.countTokens(in: String(text[start..<candidate])) <= budget { end = candidate }
                }
                let chunkText = String(text[start..<end])
                let tokens = try await tokenizer.countTokens(in: chunkText)
                result.append(ChunkRecord(fileId: fileId, ordinal: result.count, text: chunkText,
                                          locationType: segment.kind == .ocr && segment.location.locationType == "page" ? "pageOCR" : segment.location.locationType,
                                          locationValue: segment.location.locationValue,
                                          textHash: StableHash.hex(chunkText), tokenCount: tokens))
                if end == text.endIndex { break }
                let endPosition = boundaries.firstIndex(of: end) ?? best
                var overlapLow = 1, overlapHigh = endPosition, overlapStart = end
                while overlapLow <= overlapHigh {
                    let middle = (overlapLow + overlapHigh) / 2
                    let candidate = boundaries[middle]
                    if try await tokenizer.countTokens(in: String(text[candidate..<end])) <= overlap {
                        overlapStart = candidate; overlapHigh = middle - 1
                    } else { overlapLow = middle + 1 }
                }
                start = overlapStart > start ? overlapStart : end
            }
        }
        return result
    }
}

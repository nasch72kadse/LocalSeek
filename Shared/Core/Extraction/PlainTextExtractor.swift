import Foundation

/// Extraktor für reine Textformate (TXT, LOG, JSON, XML, YAML …). Liefert den
/// gesamten dekodierten Text als einen Body-Abschnitt ohne spezifische Fundstelle.
public struct PlainTextExtractor: DocumentExtractor {
    public init() {}

    public let supportedExtensions: Set<String> = [
        "txt", "text", "log", "json", "xml", "yaml", "yml",
    ]

    public func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument {
        let text = try readText(fileURL: fileURL, context: context)
        guard !text.isEmpty else { return ExtractedDocument(segments: []) }
        return ExtractedDocument(segments: [DocumentSegment(text: text, location: .none, kind: .body)])
    }
}

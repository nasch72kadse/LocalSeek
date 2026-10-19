import Foundation

/// Extraktor für Markdown. Teilt den Text an ATX-Überschriften (`#`…`######`)
/// in Abschnitte: jede Überschrift wird ein eigener Heading-Abschnitt, der
/// Fließtext darunter folgt als Body-Abschnitt mit `.section(Überschrift)`.
/// Absätze (durch Leerzeilen getrennt) werden eigene Body-Abschnitte.
public struct MarkdownExtractor: DocumentExtractor {
    public init() {}

    public let supportedExtensions: Set<String> = ["md", "markdown", "mdown"]

    public func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument {
        let text = try readText(fileURL: fileURL, context: context)
        guard !text.isEmpty else { return ExtractedDocument(segments: []) }

        var segments: [DocumentSegment] = []
        var title: String?
        var currentSection = ""
        var paragraph: [String] = []

        func flushParagraph() {
            let body = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll(keepingCapacity: true)
            guard !body.isEmpty else { return }
            segments.append(DocumentSegment(
                text: body, location: .section(currentSection), kind: .body))
        }

        for line in text.components(separatedBy: "\n") {
            if let heading = Self.headingText(line) {
                flushParagraph()
                currentSection = heading
                if title == nil { title = heading }
                segments.append(DocumentSegment(
                    text: heading, location: .section(heading), kind: .heading))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()

        return ExtractedDocument(title: title, segments: segments)
    }

    /// Liefert den Text einer ATX-Überschrift (`#` bis `######` + Leerzeichen) oder `nil`.
    static func headingText(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }
}

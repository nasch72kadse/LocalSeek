import Foundation

/// Lokalisiert eine Fundstelle innerhalb eines Dokuments. Wird beim Persistieren
/// auf `chunks.locationType` / `chunks.locationValue` abgebildet.
public enum DocumentLocation: Sendable, Equatable {
    case none
    case page(Int)
    case slide(Int)
    case sheet(name: String, range: String?)
    case section(String)

    public var locationType: String {
        switch self {
        case .none: return "none"
        case .page: return "page"
        case .slide: return "slide"
        case .sheet: return "sheet"
        case .section: return "section"
        }
    }

    public var locationValue: String {
        switch self {
        case .none: return ""
        case .page(let n): return String(n)
        case .slide(let n): return String(n)
        case .sheet(let name, let range):
            return range.map { "\(name)!\($0)" } ?? name
        case .section(let s): return s
        }
    }
}

/// Art eines extrahierten Abschnitts (für spätere Gewichtung/Darstellung).
public enum SegmentKind: String, Sendable, Equatable {
    case body, heading, table, list, note, header, footer, comment, footnote, ocr
}

/// Ein extrahierter Textabschnitt inkl. Fundstelle und Art.
public struct DocumentSegment: Sendable, Equatable {
    public let text: String
    public let location: DocumentLocation
    public let kind: SegmentKind

    public init(text: String, location: DocumentLocation = .none, kind: SegmentKind = .body) {
        self.text = text
        self.location = location
        self.kind = kind
    }
}

/// Ergebnis einer Extraktion: optionaler Titel, Metadaten und Textabschnitte.
public struct ExtractedDocument: Sendable, Equatable {
    public let title: String?
    public let metadata: [String: String]
    public let segments: [DocumentSegment]

    public init(title: String? = nil, metadata: [String: String] = [:], segments: [DocumentSegment]) {
        self.title = title
        self.metadata = metadata
        self.segments = segments
    }
}

/// Rahmenbedingungen der Extraktion (Ressourcengrenzen gem. SPEC §8).
public struct ExtractionContext: Sendable {
    /// Obergrenze gelesener Bytes je Datei (Schutz vor übergroßen Textdateien).
    public var maxBytes: Int
    /// Hard deadline per image / scanned PDF page. Vision runs in a killable helper.
    public var ocrTimeout: TimeInterval
    public var ocrCache: (any OCRResultCaching)?
    public var checkpoint: @Sendable () throws -> Void

    public init(maxBytes: Int = 50 * 1024 * 1024, ocrTimeout: TimeInterval = 30,
                ocrCache: (any OCRResultCaching)? = nil,
                checkpoint: @escaping @Sendable () throws -> Void = { try Task.checkCancellation() }) {
        self.maxBytes = maxBytes
        self.ocrTimeout = ocrTimeout
        self.ocrCache = ocrCache
        self.checkpoint = checkpoint
    }
}

public enum ExtractionError: Error, Equatable {
    case cannotDecodeText
    case unreadable
    case resourceLimit
    case changedDuringRead
    case ocrTimedOut
    case ocrFailed
    case ocrUnavailable
}

/// Modularer Dokumentparser. Jede Implementierung meldet ihre Dateiendungen und
/// liefert strukturierte Textabschnitte. Verändert niemals die Quelldatei (nur Lesen).
public protocol DocumentExtractor: Sendable {
    var supportedExtensions: Set<String> { get }
    func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument
}

/// Wählt anhand der Dateiendung den passenden Extraktor und delegiert.
/// Austauschbar/erweiterbar (SPEC §4: alternative Extraktoren müssen möglich sein).
public struct ExtractorRegistry: Sendable {
    private let byExtension: [String: DocumentExtractor]

    public init(extractors: [DocumentExtractor]) {
        var map: [String: DocumentExtractor] = [:]
        for extractor in extractors {
            for ext in extractor.supportedExtensions { map[ext.lowercased()] = extractor }
        }
        byExtension = map
    }

    public func extractor(for fileExtension: String) -> DocumentExtractor? {
        byExtension[fileExtension.lowercased()]
    }

    /// Alle unterstützten Dateiendungen (lowercase) über alle registrierten Extraktoren.
    public var supportedExtensions: Set<String> { Set(byExtension.keys) }

    /// Extrahiert `fileURL`, sofern ein Extraktor die Endung unterstützt; sonst `nil`.
    public func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument? {
        guard let extractor = extractor(for: fileURL.pathExtension) else { return nil }
        return try extractor.extract(fileURL: fileURL, context: context)
    }

    /// Standard-Registrierung der aktuell verfügbaren Extraktoren.
    public static let standard = ExtractorRegistry(extractors: [
        PlainTextExtractor(), CSVExtractor(), MarkdownExtractor(), PDFExtractor(),
        DOCXExtractor(), PPTXExtractor(), XLSXExtractor(), ImageOCRExtractor(),
        HTMLExtractor(), RTFExtractor(), EMLExtractor(),
    ])
}

/// Liest Dateidaten (auf `maxBytes` begrenzt) und dekodiert robust zu Text:
/// UTF-8, zuletzt ISO-Latin-1 (bildet jedes Byte ab, schlägt nie fehl).
func readText(fileURL: URL, context: ExtractionContext) throws -> String {
    let data = try boundedData(fileURL: fileURL, maxBytes: context.maxBytes)

    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
    if let s = String(data: data, encoding: .utf8) { return s }
    if let s = String(data: data, encoding: .isoLatin1) { return s }
    throw ExtractionError.cannotDecodeText
}

func boundedData(fileURL: URL, maxBytes: Int) throws -> Data {
    guard maxBytes >= 0, maxBytes < Int.max else { throw ExtractionError.resourceLimit }
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else { throw ExtractionError.resourceLimit }
    try Task.checkCancellation()
    return data
}

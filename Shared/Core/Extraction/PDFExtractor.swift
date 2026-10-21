import Foundation
import PDFKit

/// Extraktor für PDF (PDFKit, seitenweise). Jede Seite mit Textebene wird ein
/// Body-Abschnitt mit `.page(n)`-Fundstelle. Seiten ohne extrahierbaren Text
/// (z. B. Scans) werden per Vision-OCR nachbearbeitet; nur echt leere Seiten
/// bleiben ohne Abschnitt. Verändert die Quelldatei nie (nur Lesen).
public struct PDFExtractor: DocumentExtractor {
    private let ocr: OCRService
    public init() { ocr = OCRService() }
    init(ocr: OCRService) { self.ocr = ocr }

    public let supportedExtensions: Set<String> = ["pdf"]

    public func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument {
        let batch = try extractBatch(fileURL: fileURL, startPage: 0, maxPages: .max, maxSeconds: .infinity, context: context)
        return ExtractedDocument(title: batch.title, segments: batch.segments)
    }

    func extractBatch(fileURL: URL, startPage: Int, maxPages: Int, maxSeconds: TimeInterval,
                      context: ExtractionContext) throws -> PDFPageBatch {
        try context.checkpoint()
        guard let pdf = PDFDocument(url: fileURL) else { throw ExtractionError.unreadable }
        guard pdf.pageCount <= 1000, startPage >= 0, startPage <= pdf.pageCount, maxPages > 0 else { throw ExtractionError.resourceLimit }
        let end = startPage + min(pdf.pageCount - startPage, maxPages)
        let deadline = ProcessInfo.processInfo.systemUptime + maxSeconds
        var segments: [DocumentSegment] = []
        var bytes = 0, nextPage = startPage
        for index in startPage..<end {
            if index > startPage, ProcessInfo.processInfo.systemUptime >= deadline { break }
            try context.checkpoint()
            if let page = pdf.page(at: index) {
                var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var usedOCR = false
                if text.isEmpty, let image = Self.render(page) {
                    usedOCR = true
                    text = try ocr.recognizeLines(in: image, context: context).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if !text.isEmpty {
                    bytes += text.utf8.count
                    guard bytes <= context.maxBytes else { throw ExtractionError.resourceLimit }
                    segments.append(DocumentSegment(text: text, location: .page(index + 1), kind: usedOCR ? .ocr : .body))
                }
            }
            nextPage = index + 1
        }
        let title = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return PDFPageBatch(title: title?.isEmpty == false ? title : nil, segments: segments,
            nextPage: nextPage, totalPages: pdf.pageCount, bytes: bytes)
    }

    /// Rastert eine Seite (`.mediaBox`) auf ~200 dpi für die OCR. `nil` bei leerer Box.
    private static func render(_ page: PDFPage, scale: CGFloat = 200.0 / 72.0) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(scale, 4096 / max(bounds.width, bounds.height))
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}

struct PDFPageBatch: Sendable {
    let title: String?
    let segments: [DocumentSegment]
    let nextPage: Int
    let totalPages: Int
    let bytes: Int
}

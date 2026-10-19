import Foundation
import ImageIO

/// Extraktor für Rasterbilder: lädt das Bild (ImageIO) und erkennt enthaltenen
/// Text per Vision-OCR (`OCRService`). Liefert einen Body-Abschnitt oder nichts,
/// wenn kein Text erkannt wurde. Verändert die Quelldatei nie (nur Lesen).
public struct ImageOCRExtractor: DocumentExtractor {
    private let ocr: OCRService
    public init() { ocr = OCRService() }
    init(ocr: OCRService) { self.ocr = ocr }

    public let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "bmp", "gif",
    ]

    public func extract(fileURL: URL, context: ExtractionContext) throws -> ExtractedDocument {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
            throw ExtractionError.unreadable
        }

        let text = try ocr.recognizeLines(in: image, context: context)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ExtractedDocument(segments: []) }

        return ExtractedDocument(segments: [DocumentSegment(text: text, location: .none, kind: .body)])
    }
}

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin
import CryptoKit

/// Vision runs only in a disposable child process. A blocked native call must
/// never retain the single indexing worker or prevent cancellation/shutdown.
struct OCRService: Sendable {
    private let helperURL: URL?

    init(helperURL: URL? = nil) { self.helperURL = helperURL }

    private static var bundledHelper: URL? {
        let framework = Bundle(for: OCRBundleToken.self).bundleURL
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalSeekOCR"),
            framework.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Helpers/LocalSeekOCR"),
            // Unhosted unit tests: the tool and framework share BUILT_PRODUCTS_DIR.
            framework.deletingLastPathComponent().appendingPathComponent("LocalSeekOCR"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func recognizeLines(in image: CGImage, languages: [String] = ["de-DE", "en-US"],
                        context: ExtractionContext) throws -> [String] {
        try Self.checkpoint(context)
        guard context.ocrTimeout.isFinite, context.ocrTimeout > 0, context.ocrTimeout <= 120,
              image.width <= 4096, image.height <= 4096 else { throw ExtractionError.resourceLimit }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded as CFMutableData,
            UTType.png.identifier as CFString, 1, nil) else { throw ExtractionError.unreadable }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ExtractionError.unreadable }
        let png = Data(referencing: encoded)
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        var hash = SHA256()
        hash.update(data: Data(("vision-accurate-correction-v2:" + version).utf8))
        hash.update(data: try JSONEncoder().encode(languages))
        hash.update(data: png)
        let key = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if let cached = try? context.ocrCache?.lookup(key: key) {
            try Self.checkpoint(context)
            return cached
        }
        guard let executable = helperURL ?? Self.bundledHelper,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ExtractionError.ocrUnavailable
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("localseek-ocr-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.png")
        let output = root.appendingPathComponent("result.json")
        try png.write(to: input, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        try Self.checkpoint(context)

        let process = Process()
        process.executableURL = executable
        process.arguments = [input.path, output.path,
            String(decoding: try JSONEncoder().encode(languages), as: UTF8.self),
            String(context.ocrTimeout), String(getpid())]
        // No pipes: a full log pipe must not introduce another blocking wait.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let deadline = ProcessInfo.processInfo.systemUptime + context.ocrTimeout
        do { try process.run() } catch { throw ExtractionError.ocrUnavailable }
        defer { Self.killIfRunning(process) }
        while process.isRunning {
            try Self.checkpoint(context)
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ExtractionError.ocrTimedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        try Self.checkpoint(context)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ExtractionError.ocrFailed
        }
        do {
            let data = try boundedData(fileURL: output, maxBytes: min(context.maxBytes, 4 * 1024 * 1024))
            let lines = try JSONDecoder().decode([String].self, from: data)
            try? context.ocrCache?.store(lines, key: key)
            return lines
        } catch is CancellationError { throw CancellationError() }
        catch { throw ExtractionError.ocrFailed }
    }

    private static func checkpoint(_ context: ExtractionContext) throws {
        try Task.checkCancellation()
        try context.checkpoint()
    }

    private static func killIfRunning(_ process: Process) {
        guard process.isRunning else { return }
        // SIGTERM / VNRequest.cancel cannot reliably interrupt a Vision stall.
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        // Foundation reaps the child. Never use an unbounded waitUntilExit here.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}

private final class OCRBundleToken {}

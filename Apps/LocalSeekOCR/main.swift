import Foundation
import Vision
import ImageIO
import Darwin

// Private protocol: a local raster snapshot, result path, languages, deadline,
// owner PID. No original document paths or index/database access.
let args = CommandLine.arguments
guard args.count == 6, let timeout = Double(args[4]), timeout.isFinite,
      timeout > 0, timeout <= 120, let owner = pid_t(args[5]),
      let languageData = args[3].data(using: .utf8),
      let languages = try? JSONDecoder().decode([String].self, from: languageData) else {
    exit(2)
}

// Also bound orphan lifetime if the app crashes while Vision is blocked.
let deadline = ProcessInfo.processInfo.systemUptime + timeout + 2
let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "LocalSeek.OCR.watchdog"))
watchdog.schedule(deadline: .now(), repeating: .milliseconds(100))
watchdog.setEventHandler {
    if getppid() != owner || ProcessInfo.processInfo.systemUptime >= deadline { _exit(124) }
}
watchdog.resume()

do {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width <= 4096, image.height <= 4096 else { exit(2) }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.preferBackgroundProcessing = true
    request.usesLanguageCorrection = true
    request.recognitionLanguages = languages
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let data = try JSONEncoder().encode(lines)
    guard data.count <= 4 * 1024 * 1024 else { exit(2) }
    let result = URL(fileURLWithPath: args[2])
    try data.write(to: result, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: result.path)
    watchdog.cancel()
    exit(0)
} catch { exit(2) }

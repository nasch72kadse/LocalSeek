import Combine
import Foundation
import Sparkle

@MainActor
final class SparkleUpdateEngine: NSObject, UpdateEngine, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private let defaults: UserDefaults
    private let defaultPreview: Bool
    private let preferenceChanged = PassthroughSubject<Void, Never>()
    private(set) var availableVersion: String? { didSet { preferenceChanged.send() } }
    private var controller: SPUStandardUpdaterController!

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        defaultPreview = bundle.object(forInfoDictionaryKey: "LocalSeekUpdateChannel") as? String == "dev"
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    var changes: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            controller.updater.publisher(for: \.canCheckForUpdates).map { _ in () }.eraseToAnyPublisher(),
            controller.updater.publisher(for: \.automaticallyChecksForUpdates).map { _ in () }.eraseToAnyPublisher(),
            controller.updater.publisher(for: \.lastUpdateCheckDate).map { _ in () }.eraseToAnyPublisher(),
            preferenceChanged.eraseToAnyPublisher()
        ]).eraseToAnyPublisher()
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }
    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }
    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var includesPreviews: Bool {
        get { defaults.object(forKey: "LocalSeekIncludePreviewUpdates") as? Bool ?? defaultPreview }
        set {
            defaults.set(newValue, forKey: "LocalSeekIncludePreviewUpdates")
            controller.updater.resetUpdateCycleAfterShortDelay()
            preferenceChanged.send()
        }
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated { availableVersion = update.displayVersionString }
    }
    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { availableVersion = nil }
    }

    func start() { controller.startUpdater() }
    func check() { controller.checkForUpdates(nil) }
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        includesPreviews ? ["dev"] : []
    }
}

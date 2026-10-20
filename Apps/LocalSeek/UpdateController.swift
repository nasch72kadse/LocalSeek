import Combine
import Foundation

/// The view model never starts the engine during initialization or in CLI self-tests.
@MainActor
protocol UpdateEngine: AnyObject {
    var changes: AnyPublisher<Void, Never> { get }
    var canCheck: Bool { get }
    var automaticChecks: Bool { get set }
    var lastCheck: Date? { get }
    var availableVersion: String? { get }
    var includesPreviews: Bool { get set }
    func start()
    func check()
}

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var availableVersion: String?
    @Published private(set) var includesPreviews = false
    private let engine: any UpdateEngine
    private var observation: AnyCancellable?
    private var started = false

    init(engine: any UpdateEngine) {
        self.engine = engine
        refresh()
        observation = engine.changes.sink { [weak self] in
            // Sparkle delivers updater KVO on the main thread.
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        engine.start()
        refresh()
    }

    func checkForUpdates() {
        guard started, canCheck else { return }
        engine.check()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard enabled != automaticChecks else { return }
        engine.automaticChecks = enabled
        refresh()
    }

    func setIncludesPreviews(_ enabled: Bool) {
        guard enabled != includesPreviews else { return }
        engine.includesPreviews = enabled
        refresh()
    }

    private func refresh() {
        canCheck = started && engine.canCheck
        automaticChecks = engine.automaticChecks
        lastCheck = engine.lastCheck
        availableVersion = engine.availableVersion
        includesPreviews = engine.includesPreviews
    }
}

import Foundation
import OSLog
import SharedCore

@MainActor
final class IndexService: ObservableObject {
    @Published var sources: [SourceStatusDTO] = []
    @Published var status: IndexStatusDTO = .empty
    @Published var jobs = JobCounts()
    @Published var lastError: String?
    @Published var pauseReason: String?
    @Published var activity = "Bereit"
    @Published var isPaused = false
    @Published var pauseHeavyOnBattery = false
    @Published var favorites = Set<Int64>()
    @Published var modelName = "Kein Modell"

    private let log = Logger(subsystem: "com.localseek.app", category: "index")
    private var db: IndexDatabase?
    private let databaseURL: URL
    private let control: IndexControl
    private var scheduler: IndexScheduler?
    private var embeddingProvider: LlamaEmbeddingProvider?
    private var activeModelId: String?
    private var modelTask: Task<Void, Never>?
    private var watcher: FSEventsWatcher?
    private var pendingPaths: [String: Set<String>] = [:]
    private var sourceRoots: [String: String] = [:]
    private var firstPendingChange: Date?
    private var debounceTask: Task<Void, Never>?
    private var backgroundStarted = false

    init(database: IndexDatabase? = nil, modelURL: URL? = nil, databaseURL: URL? = nil,
         control suppliedControl: IndexControl? = nil) {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LocalSeek/index.sqlite", isDirectory: false)
        self.databaseURL = database?.storageURL ?? databaseURL ?? (try? IndexDatabase.defaultURL()) ?? fallback
        do {
            db = try database ?? IndexDatabase(url: self.databaseURL)
            if let db { try SourceManifest.save(try db.allSources(), for: self.databaseURL) }
        } catch {
            db = nil
            lastError = "Der Index konnte nicht geöffnet werden. Du kannst ihn aus den gemerkten Quellen neu aufbauen."
            log.error("Index konnte nicht geöffnet werden")
        }
        let paused = (try? db?.setting("indexPaused")) == "1"
        let battery = (try? db?.setting("pauseHeavyOnBattery")) == "1"
        isPaused = paused; pauseHeavyOnBattery = battery
        control = suppliedControl ?? IndexControl(paused: paused, pauseHeavyOnBattery: battery)
        if let db {
            let worker = IndexWorker(db: db, content: ContentIndexer(context: ExtractionContext(checkpoint: { @Sendable [control] in try control.extractionCheckpoint() })))
            scheduler = IndexScheduler(db: db, control: control) { job, gate in
                try await worker.perform(job, checkpoint: gate)
            }
        }
        reload()
        startWatching()
        modelTask = Task { [weak self] in
            guard let self else { return }
            await startBackground()
            _ = await loadActiveModelIfAvailable(url: modelURL)
        }
    }

    var hasEmbeddingModel: Bool { embeddingProvider != nil }
    var canRebuild: Bool { true }

    private func startBackground() async {
        guard let scheduler, !backgroundStarted else { return }
        backgroundStarted = true
        await scheduler.setOnChange { [weak self] in await self?.reloadAsync() }
        do {
            try await scheduler.start()
            let requests = try db?.allSources().filter(\.enabled).map { IndexJobRequest(sourceId: $0.id, kind: .metadata) } ?? []
            let lastCheck = Double((try db?.setting("lastIntegrityCheck")) ?? "") ?? 0
            let due = Date(timeIntervalSince1970: lastCheck + 12 * 3600)
            let maintenance = IndexJobRequest(kind: .maintenance,
                notBefore: max(Date(), due), priority: due <= Date() ? -10 : 100)
            try await scheduler.enqueue(requests + [maintenance])
        } catch { lastError = "Die Hintergrundverarbeitung konnte nicht gestartet werden." }
    }

    private func loadActiveModelIfAvailable(url explicitURL: URL? = nil) async -> Bool {
        guard let db else { return false }
        do {
            let preferred = try db.activeModel()?.name
            guard let url = try explicitURL ?? ModelLocator.installedModel(preferredName: preferred) else { return false }
            let checksum = try await Task.detached(priority: .utility) { try ModelLocator.checksum(of: url) }.value
            let provider = LlamaEmbeddingProvider(modelURL: url)
            try await provider.prepare()
            guard !Task.isCancelled else { await provider.unload(); return false }
            let name = url.lastPathComponent
            let id = "\(name)-\(checksum.prefix(12))"
            try db.upsertModel(ModelRecord(modelId: id, name: name, dimensions: 384, checksum: checksum, active: true))
            try db.setActiveModel(modelId: id)
            let oldProvider = embeddingProvider
            embeddingProvider = provider; activeModelId = id; modelName = name
            let chunker = DocumentChunker(tokenizer: provider, version: "extract-4:chunk-2:\(checksum)")
            let worker = IndexWorker(db: db, content: ContentIndexer(context: ExtractionContext(checkpoint: { @Sendable [control] in try control.extractionCheckpoint() }), chunker: chunker), provider: provider, modelId: id)
            await scheduler?.replaceWorker { job, gate in try await worker.perform(job, checkpoint: gate) }
            db.vectorIndex.release()
            await oldProvider?.unload()
            let requests = try db.allSources().filter(\.enabled).map { IndexJobRequest(sourceId: $0.id, kind: .content) }
            try await scheduler?.enqueue(requests)
            lastError = nil
            await reloadAsync()
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            lastError = Self.errorMessage(error)
            log.error("Embedding-Modell konnte nicht aktiviert werden")
            return false
        }
    }

    func installModel(from url: URL) {
        modelTask?.cancel()
        modelTask = Task { [weak self] in
            guard let self else { return }
            await startBackground()
            do {
                let installed = try await Task.detached(priority: .utility) { try ModelLocator.install(from: url) }.value
                guard !Task.isCancelled else { return }
                _ = await loadActiveModelIfAvailable(url: installed)
            } catch { lastError = "Das Suchmodell konnte nicht installiert werden." }
        }
    }

    func addSource(url: URL) {
        guard let db else { return }
        let path = url.standardizedFileURL.path
        lastError = nil
        do {
            if try db.source(id: path) == nil { try db.upsertSource(SourceRecord(id: path, path: path)) }
            try SourceManifest.save(try db.allSources(), for: databaseURL)
            reload(); startWatching()
            Task { [weak self] in
                do { try await self?.scheduler?.enqueue([.init(sourceId: path, kind: .metadata)]) }
                catch { self?.lastError = "Der Ordner konnte nicht eingeplant werden." }
            }
        } catch { lastError = "Der Ordner konnte nicht hinzugefügt werden." }
    }

    func removeSource(id: String) {
        Task { [weak self] in
            guard let self, let db else { return }
            do {
                try await scheduler?.cancel(sourceId: id)
                try db.removeSource(id: id)
                try SourceManifest.save(try db.allSources(), for: databaseURL)
                reload(); startWatching()
            } catch { lastError = "Die Quelle konnte nicht entfernt werden." }
        }
    }

    func setSourceEnabled(id: String, enabled: Bool) {
        Task { [weak self] in
            guard let self, let db else { return }
            do {
                guard var source = try db.source(id: id) else { return }
                if !enabled { try await scheduler?.cancel(sourceId: id) }
                source.enabled = enabled
                try db.upsertSource(source)
                try SourceManifest.save(try db.allSources(), for: databaseURL)
                if enabled { try await scheduler?.enqueue([.init(sourceId: id, kind: .metadata)]) }
                reload(); startWatching()
            } catch { lastError = "Die Quelle konnte nicht aktualisiert werden." }
        }
    }

    func rescanSource(id: String) {
        Task { [weak self] in
            guard let self, let db else { return }
            do {
                try db.clearExtractionFailures(sourceId: id)
                try await scheduler?.enqueue([.init(sourceId: id, kind: .metadata)])
                lastError = nil
            } catch { lastError = "Der erneute Abgleich konnte nicht gestartet werden." }
        }
    }

    func cancelSource(id: String) {
        Task { [weak self] in
            do { try await self?.scheduler?.cancel(sourceId: id) }
            catch { self?.lastError = "Der Auftrag konnte nicht abgebrochen werden." }
        }
    }

    func setPaused(_ value: Bool) {
        isPaused = value
        Task { [weak self] in
            do { try await self?.scheduler?.setPaused(value) }
            catch { self?.lastError = "Der Pausenzustand konnte nicht gespeichert werden." }
            await self?.reloadAsync()
        }
    }

    func setPauseHeavyOnBattery(_ value: Bool) {
        pauseHeavyOnBattery = value
        Task { [weak self] in
            guard let self else { return }
            await control.setPauseHeavyOnBattery(value)
            do { try db?.setSetting("pauseHeavyOnBattery", value: value ? "1" : "0") }
            catch { lastError = "Die Energieeinstellung konnte nicht gespeichert werden." }
            await scheduler?.wake()
            await reloadAsync()
        }
    }

    func systemResourcesChanged() {
        Task { [weak self] in
            try? await self?.scheduler?.resourcesChanged()
            await self?.reloadAsync()
        }
    }

    func rebuildIndex() {
        Task { [weak self] in
            guard let self else { return }
            modelTask?.cancel()
            await modelTask?.value
            await scheduler?.stop()
            await embeddingProvider?.unload()
            do {
                if let db { try db.rebuildDerivedIndex() }
                else {
                    let savedSources = try SourceManifest.load(for: databaseURL)
                    let backup = databaseURL.deletingLastPathComponent().appendingPathComponent("index-recovery-\(UUID().uuidString).sqlite")
                    for suffix in ["", "-wal", "-shm"] {
                        let original = URL(fileURLWithPath: databaseURL.path + suffix, isDirectory: false)
                        if FileManager.default.fileExists(atPath: original.path) {
                            try FileManager.default.moveItem(at: original, to: URL(fileURLWithPath: backup.path + suffix, isDirectory: false))
                        }
                    }
                    let recovered = try IndexDatabase(url: databaseURL)
                    for var source in savedSources { source.scanStatus = "idle"; try recovered.upsertSource(source) }
                    db = recovered
                }
                guard let db else { return }
                let worker = IndexWorker(db: db, content: ContentIndexer(context: ExtractionContext(checkpoint: { @Sendable [control] in try control.extractionCheckpoint() })))
                scheduler = IndexScheduler(db: db, control: control) { job, gate in try await worker.perform(job, checkpoint: gate) }
                backgroundStarted = false
                lastError = nil
                await startBackground()
                _ = await loadActiveModelIfAvailable()
                await reloadAsync(); startWatching()
            } catch { lastError = "Der Index konnte nicht neu aufgebaut werden. Die Sicherung bleibt erhalten." }
        }
    }

    func search(_ query: String) -> [FileRecord] { (try? db?.searchFilenames(query)) ?? [] }

    func searchAsync(_ query: String, filters: SearchFilters = SearchFilters(), limit: Int = 50) async -> [FileRecord] {
        guard let db else { return [] }
        await control.beginInteractive()
        let result = await Task.detached { (try? db.searchFilenames(query, limit: limit, filters: filters)) ?? [] }.value
        await control.endInteractive()
        return result
    }

    func searchContentAsync(_ query: String, strategy: SearchStrategy, filters: SearchFilters = SearchFilters(), limit: Int = 50) async -> [ContentSearchHit] {
        guard let db else { return [] }
        await control.beginInteractive()
        let engine = HybridSearchEngine(db: db, provider: embeddingProvider,
            store: embeddingProvider == nil ? nil : AdaptiveVectorStore(db: db), modelId: activeModelId)
        do {
            let result = try await engine.search(query, strategy: strategy, limit: limit, filters: filters)
            await control.endInteractive()
            await scheduler?.wake()
            return result
        } catch {
            await control.endInteractive()
            await scheduler?.wake()
            if !(error is CancellationError) { lastError = Self.errorMessage(error) }
            return []
        }
    }

    func toggleFavorite(_ id: Int64) {
        do { try db?.toggleFavorite(fileId: id); reload() }
        catch { lastError = "Der Favorit konnte nicht gespeichert werden." }
    }

    func exportDiagnostics(to url: URL) {
        // Deliberately excludes file names, paths, queries and document contents.
        let report: [String: Any] = ["app": "LocalSeek", "date": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "sources": status.sourceCount, "files": status.fileCount, "chunks": status.chunkCount,
            "embeddings": status.embeddingCount, "queuedJobs": jobs.pending,
            "failedJobs": jobs.failed, "extractionFailures": jobs.extractionFailures,
            "embeddingFailures": jobs.embeddingFailures, "paused": isPaused,
            "modelLoaded": hasEmbeddingModel, "activity": activity,
            "acceleratedSearchReady": db?.vectorIndex.isReady ?? false]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic) }
        catch { lastError = "Die Diagnose konnte nicht exportiert werden." }
    }

    func refresh() { Task { [weak self] in await self?.reloadAsync() } }

    func shutdown() async {
        modelTask?.cancel(); debounceTask?.cancel()
        watcher?.stop()
        await modelTask?.value
        await scheduler?.stop()
        db?.vectorIndex.release()
        await embeddingProvider?.unload()
        if let db { try? await Task.detached { try db.checkpoint() }.value }
    }

    private func startWatching() {
        guard db != nil else { return }
        if watcher == nil {
            watcher = FSEventsWatcher(latency: 0.5) { [weak self] paths in
                Task { @MainActor in self?.handleFSChanges(paths) }
            }
        }
        watcher?.start(paths: sources.filter(\.isEnabled).compactMap { sourceRoots[$0.id] })
    }

    private func handleFSChanges(_ paths: [String]) {
        for source in sources where source.isEnabled {
            guard let root = sourceRoots[source.id] else { continue }
            let prefix = root == "/" ? "/" : root + "/"
            for path in paths {
                if path == root || root.hasPrefix(path + "/") {
                    pendingPaths[source.id] = [""]
                } else if path.hasPrefix(prefix), pendingPaths[source.id]?.contains("") != true {
                    pendingPaths[source.id, default: []].insert(String(path.dropFirst(prefix.count)))
                    if pendingPaths[source.id, default: []].count > 512 { pendingPaths[source.id] = [""] }
                }
            }
        }
        guard !pendingPaths.isEmpty else { return }
        if firstPendingChange == nil { firstPendingChange = Date() }
        let delay = min(2, max(0, 5 - Date().timeIntervalSince(firstPendingChange!)))
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let changes = pendingPaths
            pendingPaths.removeAll(); firstPendingChange = nil
            do {
                for (sourceId, paths) in changes {
                    try await scheduler?.enqueueChanges(sourceId: sourceId, relativePaths: paths)
                }
            }
            catch { lastError = "Dateiänderungen konnten nicht eingeplant werden." }
        }
    }

    private func reload() {
        guard let db else { return }
        do {
            let records = try db.allSources()
            sourceRoots = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.path) })
            sources = try records.map { record in
                SourceStatusDTO(id: record.id, displayPath: (record.path as NSString).lastPathComponent,
                    state: Self.mapState(record.scanStatus), fileCount: try db.fileCount(forSource: record.id), isEnabled: record.enabled, lastScan: record.lastScan)
            }
            status = IndexStatusDTO(fileCount: try db.fileCount(), chunkCount: try db.chunkCount(),
                embeddingCount: try activeModelId.map { try db.embeddingCount(modelId: $0) } ?? 0,
                sourceCount: try db.sourceCount(), isPaused: isPaused)
            jobs = try db.jobCounts()
            favorites = try db.favoriteIDs()
        } catch { lastError = "Der Indexstatus konnte nicht gelesen werden." }
    }

    private func reloadAsync() async {
        if let snapshot = await scheduler?.snapshot() {
            pauseReason = snapshot.pauseReason
            switch snapshot.activeKind {
            case .metadata, .changes: activity = "Dateien erfassen"
            case .content: activity = "Inhalte lesen"
            case .embeddings: activity = "Semantischen Index aufbauen"
            case .vectorIndex: activity = "Semantische Suche vorbereiten"
            case .maintenance: activity = "Index prüfen"
            case nil: activity = "Bereit"
            }
            if let failure = snapshot.lastFailure { lastError = failure }
        }
        reload()
    }

    private static func mapState(_ raw: String) -> SourceState {
        switch raw { case "scanning": .scanning; case "unavailable": .unavailable; case "error": .error; default: .idle }
    }

    nonisolated private static func errorMessage(_ error: any Error) -> String {
        switch error {
        case EmbeddingError.modelMissing: "Das Suchmodell wurde nicht gefunden. Bitte eine GGUF-Datei wählen."
        case EmbeddingError.modelLoadFailed: "Das Suchmodell konnte nicht geladen werden. Bitte eine llama.cpp-kompatible GGUF-Datei wählen."
        case EmbeddingError.dimensionMismatch: "Das Suchmodell muss 384-dimensionale Einbettungen erzeugen."
        case EmbeddingError.inferenceFailed: "Die semantische Verarbeitung ist fehlgeschlagen."
        default: "Die Verarbeitung konnte nicht abgeschlossen werden."
        }
    }
}

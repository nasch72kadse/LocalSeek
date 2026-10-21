import Foundation
import LlamaBridge

/// C++ owns its buffers; every native operation is protected by its own mutex.
private final class NativeANNGraph: @unchecked Sendable {
    let pointer: OpaquePointer
    let dimensions: Int
    init?(dimensions: Int, capacity: Int, maximum: Int) {
        guard let pointer = ls_ann_create(Int32(dimensions), Int64(capacity), Int64(maximum)) else { return nil }
        self.pointer = pointer; self.dimensions = dimensions
    }
    deinit { ls_ann_free(pointer) }
    var count: Int { Int(ls_ann_count(pointer)) }
    func put(id: Int64, vector: [Float]) -> Bool {
        vector.withUnsafeBufferPointer { ls_ann_upsert(pointer, id, $0.baseAddress, Int32(vector.count)) }
    }
    func remove(id: Int64) -> Bool { ls_ann_remove(pointer, id) }
    func search(_ query: [Float], limit: Int) -> [Int64]? {
        let capacity = min(8192, max(1, limit))
        var labels = [Int64](repeating: 0, count: capacity)
        var scores = [Float](repeating: 0, count: capacity)
        let found = query.withUnsafeBufferPointer { input in
            labels.withUnsafeMutableBufferPointer { labels in
                scores.withUnsafeMutableBufferPointer {
                    ls_ann_search(pointer, input.baseAddress, Int32(query.count), Int32(capacity),
                                  labels.baseAddress, $0.baseAddress)
                }
            }
        }
        guard found >= 0 else { return nil }
        return Array(labels.prefix(Int(found)))
    }
}

private final class ANNBuildState: @unchecked Sendable {
    let modelId: String
    let dimensions: Int
    let graph: NativeANNGraph
    var revision: Int64
    var cursor: Int64 = 0
    var scanning = true
    init(modelId: String, dimensions: Int, graph: NativeANNGraph, revision: Int64) {
        self.modelId = modelId; self.dimensions = dimensions; self.graph = graph; self.revision = revision
    }
}

final class VectorIndexHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var controller: AdaptiveVectorIndex?
    func get(database: IndexDatabase) -> AdaptiveVectorIndex {
        lock.withLock {
            if let controller { return controller }
            let value = AdaptiveVectorIndex(database: database)
            controller = value
            return value
        }
    }
}

/// SQLite stays authoritative. HNSW is disposable, versioned and memory bounded.
/// It is built only by the background worker, never by an interactive query.
public final class AdaptiveVectorIndex: @unchecked Sendable {
    private struct Ready: Sendable {
        let modelId: String
        let dimensions: Int
        let revision: Int64
        let graph: NativeANNGraph
    }
    private weak var database: IndexDatabase?
    public let minimumVectors: Int
    public let memoryBudget: UInt64
    private let maximumCandidates: Int
    private let lock = NSLock()
    private struct FilterPlan {
        let modelId: String
        let revision: Int64
        let filters: SearchFilters
        let parsed: ParsedQuery
        let exact: Bool
        let expires: Double
    }
    private var filterPlans: [FilterPlan] = []
    private var ready: Ready?
    private var working: ANNBuildState?
    private var preparing = false
    private var lastRequest = -Double.infinity
    private var pressuredUntil = -Double.infinity
    private var generation: UInt64 = 0
    private var pressureSource: (any DispatchSourceMemoryPressure)?

    public init(database: IndexDatabase, minimumVectors: Int = 50_000, memoryBudget: UInt64? = nil, maximumCandidates: Int = 8192) {
        self.database = database
        self.minimumVectors = max(1, minimumVectors)
        self.maximumCandidates = min(8192, max(1, maximumCandidates))
        self.memoryBudget = memoryBudget ?? min(2 * 1024 * 1024 * 1024, ProcessInfo.processInfo.physicalMemory / 8)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.ready = nil; self.working = nil
                self.generation &+= 1
                self.pressuredUntil = ProcessInfo.processInfo.systemUptime + 60
            }
            try? self.database?.stopVectorTracking()
        }
        pressureSource = source
        source.resume()
    }
    deinit { pressureSource?.cancel() }
    public var isReady: Bool { lock.withLock { ready != nil } }

    public func release() {
        lock.withLock { ready = nil; working = nil; filterPlans.removeAll(); generation &+= 1 }
        try? database?.stopVectorTracking()
    }

    func requestBuild(modelId: String) {
        guard let database else { return }
        if let current = lock.withLock({ ready }), current.modelId == modelId,
           (try? database.vectorRevision(modelId: modelId)) == current.revision { return }
        let request = lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard now >= pressuredUntil, now - lastRequest >= 30 else { return false }
            lastRequest = now
            return true
        }
        if request, (try? database.hasVectorCount(minimumVectors, modelId: modelId)) == true {
            try? database.enqueueJobs([.init(kind: .vectorIndex)])
        }
    }

    /// Runs on the existing serial background queue. Checkpoints retain a
    /// partially built graph on priority yields and keep UI/source work ahead.
    @discardableResult
    public func prepare(modelId: String, dimensions: Int, checkpoint: IndexCheckpoint = { _ in try Task.checkCancellation() }) async throws -> Bool {
        guard let database, dimensions > 0, dimensions <= 8192 else { return false }
        let acquired = lock.withLock { () -> UInt64? in
            guard !preparing, ProcessInfo.processInfo.systemUptime >= pressuredUntil else { return nil }
            preparing = true
            return generation
        }
        guard let acquired else { return false }
        defer { lock.withLock { preparing = false } }
        var target = try database.vectorRevision(modelId: modelId)
        if lock.withLock({ ready?.modelId == modelId && ready?.dimensions == dimensions && ready?.revision == target }) { return true }
        let count = try database.embeddingCount(modelId: modelId)
        guard count >= minimumVectors else { release(); return false }
        let bytesPerPoint = UInt64(dimensions * 4 + 512)
        let maximum = memoryBudget > 8 * 1024 * 1024 ? Int((memoryBudget - 8 * 1024 * 1024) / bytesPerPoint) : 0
        guard count <= maximum else { release(); return false }
        var state = lock.withLock { () -> ANNBuildState? in
            if let working, working.modelId == modelId, working.dimensions == dimensions { return working }
            if let ready, ready.modelId == modelId, ready.dimensions == dimensions {
                let value = ANNBuildState(modelId: modelId, dimensions: dimensions, graph: ready.graph, revision: ready.revision)
                value.scanning = false
                working = value; self.ready = nil
                return value
            }
            ready = nil; working = nil
            return nil
        }
        if let old = state, target < old.revision || target - old.revision > 100_000 {
            lock.withLock { ready = nil; working = nil }
            state = nil
        }
        if state == nil {
            try await checkpoint(.embedding)
            let revision = try database.beginVectorTracking(modelId: modelId)
            let capacity = min(maximum, count + max(256, count / 20))
            guard let graph = NativeANNGraph(dimensions: dimensions, capacity: capacity, maximum: maximum) else { return false }
            state = ANNBuildState(modelId: modelId, dimensions: dimensions, graph: graph, revision: revision)
            guard lock.withLock({ () -> Bool in
                guard generation == acquired else { return false }
                working = state
                return true
            }) else { return false }
        }
        guard let state else { return false }
        while state.scanning {
            try await checkpoint(.embedding)
            if lock.withLock({ generation != acquired || ProcessInfo.processInfo.systemUptime < pressuredUntil }) { return false }
            let rows = try database.vectorsForIndex(modelId: modelId, afterId: state.cursor)
            if rows.isEmpty { state.scanning = false; break }
            for row in rows {
                try Task.checkCancellation()
                if row.vector.count == dimensions, row.vector.allSatisfy(\.isFinite), row.vector.contains(where: { $0 != 0 }) {
                    guard state.graph.put(id: row.id, vector: row.vector) else { release(); return false }
                }
                state.cursor = row.id
            }
        }
        while true {
            try await checkpoint(.embedding)
            if lock.withLock({ generation != acquired || ProcessInfo.processInfo.systemUptime < pressuredUntil }) { return false }
            let updates = try database.vectorChanges(modelId: modelId, after: state.revision)
            if updates.isEmpty { break }
            for update in updates {
                try Task.checkCancellation()
                if let vector = update.vector, vector.count == dimensions,
                   vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) {
                    guard state.graph.put(id: update.id, vector: vector) else { release(); return false }
                } else if !state.graph.remove(id: update.id) { release(); return false }
                state.revision = update.sequence
            }
        }
        target = try database.vectorRevision(modelId: modelId)
        guard target == state.revision else {
            // Tracking was interrupted or overflowed; never publish a stale graph.
            release()
            return false
        }
        guard lock.withLock({ () -> Bool in
            guard generation == acquired else { return false }
            ready = Ready(modelId: modelId, dimensions: dimensions, revision: target, graph: state.graph)
            working = nil
            return true
        }) else { return false }
        try database.acknowledgeVectorChanges(modelId: modelId, through: target)
        return true
    }

    private func preferExact(_ current: Ready, filters: SearchFilters, parsed: ParsedQuery, database: IndexDatabase) throws -> Bool {
        guard !filters.isEmpty || parsed.hasFilters else { return false }
        var criteria = parsed
        criteria.terms = []; criteria.phrases = []
        let now = ProcessInfo.processInfo.systemUptime
        if let known = lock.withLock({ filterPlans.first { $0.modelId == current.modelId && $0.revision == current.revision && $0.filters == filters && $0.parsed == criteria && $0.expires > now } }) {
            return known.exact
        }
        // Scanning a small eligible subset is cheaper than repeatedly widening
        // a graph query. Cache only the plan, never results or visibility checks.
        let threshold = min(16_384, max(512, current.graph.count / 8))
        let count = try database.vectorCandidateCount(modelId: current.modelId, dimensions: current.dimensions,
            limit: threshold + 1, filters: filters, parsed: criteria, documents: false)
        let exact = count <= threshold
        lock.withLock {
            filterPlans.removeAll { $0.expires <= now }
            if filterPlans.count >= 16 { filterPlans.removeFirst() }
            filterPlans.append(FilterPlan(modelId: current.modelId, revision: current.revision,
                filters: filters, parsed: criteria, exact: exact, expires: now + 30))
        }
        return exact
    }

    func nearest(_ query: [Float], modelId: String, limit: Int, filters: SearchFilters = .init(),
                 parsed: ParsedQuery = .init(), documents: Bool = false) throws -> [VectorMatch]? {
        guard let database, let current = lock.withLock({ ready }),
              current.modelId == modelId, current.dimensions == query.count,
              try database.vectorRevision(modelId: modelId) == current.revision else { return nil }
        if try preferExact(current, filters: filters, parsed: parsed, database: database) { return nil }
        let boundedLimit = min(2000, max(0, limit))
        let expected = try database.vectorCandidateCount(modelId: modelId, dimensions: query.count,
            limit: boundedLimit, filters: filters, parsed: parsed, documents: documents)
        guard expected > 0 else { return [] }
        let maximum = min(maximumCandidates, current.graph.count)
        var count = min(maximum, max(256, boundedLimit * 4))
        while count > 0 {
            try Task.checkCancellation()
            guard let ids = current.graph.search(query, limit: count) else { return nil }
            let matches = try database.rankVectorCandidates(ids, query: query, modelId: modelId,
                limit: boundedLimit, filters: filters, parsed: parsed, documents: documents)
            guard try database.vectorRevision(modelId: modelId) == current.revision else { return nil }
            if matches.count >= expected { return matches }
            if count >= maximum || (count >= 1024 && matches.count * 4 < expected) { break }
            count = min(maximum, count * 2)
        }
        return nil // Selective filters or concentrated documents require an exact fallback.
    }
}

public struct AdaptiveVectorStore: VectorStore {
    private let db: IndexDatabase
    private let index: AdaptiveVectorIndex
    public init(db: IndexDatabase, index: AdaptiveVectorIndex? = nil) {
        self.db = db; self.index = index ?? db.vectorIndex
    }
    public func upsert(chunkId: Int64, modelId: String, textHash: String, embedding: [Float]) throws {
        try BruteForceVectorStore(db: db).upsert(chunkId: chunkId, modelId: modelId, textHash: textHash, embedding: embedding)
    }
    public func upsertBatch(_ writes: [EmbeddingWrite]) throws { try BruteForceVectorStore(db: db).upsertBatch(writes) }
    public func remove(chunkIds: [Int64]) throws { try BruteForceVectorStore(db: db).remove(chunkIds: chunkIds) }
    public func nearest(to query: [Float], modelId: String, limit: Int) throws -> [VectorMatch] {
        try nearest(to: query, modelId: modelId, limit: limit, matching: SearchFilters(), parsedQuery: ParsedQuery())
    }
    public func nearest(to query: [Float], modelId: String, limit: Int,
                        matching filters: SearchFilters, parsedQuery: ParsedQuery) throws -> [VectorMatch] {
        if limit > 0 {
            if let matches = try index.nearest(query, modelId: modelId, limit: limit, filters: filters, parsed: parsedQuery) { return matches }
            index.requestBuild(modelId: modelId)
        }
        return try BruteForceVectorStore(db: db).nearest(to: query, modelId: modelId, limit: limit,
                                                       matching: filters, parsedQuery: parsedQuery)
    }
    public func nearestDocuments(to query: [Float], modelId: String, limit: Int,
                                 matching filters: SearchFilters, parsedQuery: ParsedQuery) throws -> [VectorMatch] {
        if limit > 0 {
            if let matches = try index.nearest(query, modelId: modelId, limit: limit, filters: filters, parsed: parsedQuery, documents: true) { return matches }
            index.requestBuild(modelId: modelId)
        }
        return try BruteForceVectorStore(db: db).nearestDocuments(to: query, modelId: modelId, limit: limit,
                                                                matching: filters, parsedQuery: parsedQuery)
    }
}

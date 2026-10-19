import Foundation

public struct SchedulerSnapshot: Sendable {
    public var activeKind: IndexJobKind?
    public var pauseReason: String?
    public var lastFailure: String?
}

private struct IndexYield: Error {}

public actor IndexScheduler {
    public typealias Worker = @Sendable (IndexJob, IndexCheckpoint) async throws -> [IndexJobRequest]
    private let db: IndexDatabase
    public let control: IndexControl
    private var worker: Worker
    private var onChange: @Sendable () async -> Void = {}
    private var loop: Task<Void, Never>?
    private var active: Task<[IndexJobRequest], any Error>?
    private var sleeper: Task<Void, any Error>?
    private var currentJob: IndexJob?
    private var stopped = false
    private var started = false
    private var lastFailure: String?
    private var lastProgress = Date.distantPast

    public init(db: IndexDatabase, control: IndexControl, worker: @escaping Worker) {
        self.db = db; self.control = control; self.worker = worker
    }

    public func setOnChange(_ callback: @escaping @Sendable () async -> Void) { onChange = callback }

    public func start() throws {
        guard !started else { wake(); return }
        started = true
        stopped = false
        try db.recoverInterruptedJobs()
        wake()
    }

    public func enqueue(_ requests: [IndexJobRequest]) throws {
        try db.enqueueJobs(requests)
        wake()
    }

    public func enqueueChanges(sourceId: String, relativePaths: Set<String>) throws {
        try db.enqueueFileEvents(sourceId: sourceId, relativePaths: relativePaths)
        wake()
    }

    public func wake() {
        sleeper?.cancel()
        guard started, loop == nil, !stopped else { return }
        loop = Task { [weak self] in await self?.runLoop() }
    }

    public func resourcesChanged() throws {
        try db.retryResourceJobs()
        wake()
    }

    public func replaceWorker(_ newWorker: @escaping Worker) async {
        worker = newWorker
        active?.cancel()
        _ = try? await active?.value
        wake()
    }

    public func setPaused(_ value: Bool) async throws {
        try db.setSetting("indexPaused", value: value ? "1" : "0")
        await control.setPaused(value)
        if value { active?.cancel(); sleeper?.cancel() }
        else { wake() }
        await onChange()
    }

    public func cancel(sourceId: String) async throws {
        try db.cancelJobs(sourceId: sourceId)
        if currentJob?.sourceId == sourceId {
            active?.cancel()
            _ = try? await active?.value
        }
        try db.cancelJobs(sourceId: sourceId)
        await onChange()
    }

    public func stop() async {
        stopped = true
        loop?.cancel(); active?.cancel(); sleeper?.cancel()
        await loop?.value
        loop = nil; active = nil; sleeper = nil
        started = false
    }

    public func snapshot() async -> SchedulerSnapshot {
        SchedulerSnapshot(activeKind: currentJob?.kind, pauseReason: await control.pauseReason(), lastFailure: lastFailure)
    }

    private func progress(_ workload: IndexWorkload) async throws {
        try await control.checkpoint(workload)
        if Date().timeIntervalSince(lastProgress) >= 0.5 {
            lastProgress = Date()
            if let currentJob, try db.hasHigherPriorityJob(than: currentJob.priority) { throw IndexYield() }
            await onChange()
        }
    }

    private func runLoop() async {
        defer { loop = nil; currentJob = nil }
        while !stopped && !Task.isCancelled {
            if await control.isPaused() { return }
            do {
                guard let job = try db.claimNextJob() else {
                    guard let next = try db.nextJobDate() else { return }
                    let delay = max(0.01, next.timeIntervalSinceNow)
                    sleeper = Task { try await Task.sleep(for: .seconds(delay)) }
                    _ = try? await sleeper?.value
                    sleeper = nil
                    continue
                }
                currentJob = job
                await onChange()
                guard !stopped, !Task.isCancelled else { try db.requeueJob(job); return }
                // Cancellation may happen while the status callback suspends, before
                // an active Task exists to cancel. The durable row is authoritative.
                guard try db.isJobRunning(id: job.id) else { currentJob = nil; continue }
                let perform = worker
                let gate: IndexCheckpoint = { [weak self, control] workload in
                    if let self { try await self.progress(workload) }
                    else { try await control.checkpoint(workload) }
                }
                active = Task.detached(priority: .utility) { try await perform(job, gate) }
                do {
                    let followUps = try await active!.value
                    try Task.checkCancellation()
                    try db.finishJob(job, followUps: followUps)
                    lastFailure = nil
                } catch is IndexYield {
                    try db.requeueJob(job)
                } catch is CancellationError {
                    try db.requeueJob(job)
                } catch let deferred as ResourceDeferred {
                    try db.deferJob(job, code: deferred.reason.rawValue, resourcePause: true)
                } catch {
                    try db.deferJob(job, code: "indexingFailed")
                    lastFailure = "Ein Hintergrundauftrag wird erneut versucht."
                }
                active = nil; currentJob = nil
                await onChange()
            } catch {
                lastFailure = "Die Hintergrundwarteschlange konnte nicht aktualisiert werden."
                await onChange()
                return
            }
        }
    }
}

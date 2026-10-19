import Foundation
import IOKit.ps

public struct ResourceSnapshot: Sendable {
    public var thermalLevel: Int
    public var lowPower: Bool
    public var onBattery: Bool
    public init(thermalLevel: Int = 0, lowPower: Bool = false, onBattery: Bool = false) {
        self.thermalLevel = thermalLevel; self.lowPower = lowPower; self.onBattery = onBattery
    }
    public static func current() -> Self {
        var battery = false
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() {
            battery = (source as String) == kIOPMBatteryPowerKey
        }
        return Self(thermalLevel: ProcessInfo.processInfo.thermalState.rawValue,
                    lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, onBattery: battery)
    }
}

public struct ResourceDeferred: Error, Sendable {
    public enum Reason: String, Sendable { case temperature, battery }
    public let reason: Reason
}

/// Background jobs checkpoint between files/chunks. Foreground search never waits
/// for an entire corpus and background inference uses at most two CPU threads.
public actor IndexControl {
    private var paused: Bool
    private var pauseHeavyOnBattery: Bool
    private var interactive = 0
    private let environment: @Sendable () -> ResourceSnapshot

    public init(paused: Bool = false, pauseHeavyOnBattery: Bool = false,
                environment: @escaping @Sendable () -> ResourceSnapshot = ResourceSnapshot.current) {
        self.paused = paused; self.pauseHeavyOnBattery = pauseHeavyOnBattery; self.environment = environment
    }
    public nonisolated func extractionCheckpoint() throws {
        try Task.checkCancellation()
        if environment().thermalLevel >= 2 { throw ResourceDeferred(reason: .temperature) }
    }
    public func setPaused(_ value: Bool) { paused = value }
    public func setPauseHeavyOnBattery(_ value: Bool) { pauseHeavyOnBattery = value }
    public func isPaused() -> Bool { paused }
    public func beginInteractive() { interactive += 1 }
    public func endInteractive() { interactive = max(0, interactive - 1) }

    public func pauseReason() -> String? {
        if paused { return "Manuell pausiert" }
        let resource = environment()
        if resource.thermalLevel >= 2 { return "Hohe Temperatur" }
        if resource.onBattery && pauseHeavyOnBattery { return "OCR und KI auf Akku pausiert" }
        if resource.lowPower { return "Stromsparmodus: reduzierte Verarbeitung" }
        return nil
    }

    public func checkpoint(_ workload: IndexWorkload) async throws {
        try Task.checkCancellation()
        if paused { throw CancellationError() }
        let resource = environment()
        if resource.thermalLevel >= 2 { throw ResourceDeferred(reason: .temperature) }
        let heavy = workload == .embedding || workload == .ocr
        if heavy && pauseHeavyOnBattery && resource.onBattery { throw ResourceDeferred(reason: .battery) }
        while interactive > 0 && workload != .metadata {
            try await Task.sleep(for: .milliseconds(25))
            if paused { throw CancellationError() }
        }
        if resource.lowPower && heavy { try await Task.sleep(for: .milliseconds(150)) }
        try Task.checkCancellation()
    }
}

import Foundation
import IOKit.ps
import Observation

/// Why the guardrails are refusing to let the wake lock stay engaged.
enum YieldReason: Equatable {
    case batteryFloor(pct: Int, floor: Int)
    case notOnACPower
    case lowPowerMode
    case thermal(ProcessInfo.ThermalState)
    case lidClosedTooLong(minutes: Int)

    var summary: String {
        switch self {
        case let .batteryFloor(pct, floor): return "Battery \(pct)% is below the \(floor)% floor"
        case .notOnACPower:                 return "Not connected to AC power"
        case .lowPowerMode:                 return "Low Power Mode is on"
        case let .thermal(s):               return "Thermal state is \(s.label)"
        case let .lidClosedTooLong(m):      return "Lid has been shut for \(m) min — the safety cap released the lock"
        }
    }

    /// Identity without the moving parts. `.batteryFloor(19,20)` and `.batteryFloor(18,20)`
    /// are the same ongoing condition, not two separate trips, and only a change of kind
    /// is worth interrupting the user for.
    var kind: String {
        switch self {
        case .batteryFloor:     return "battery"
        case .notOnACPower:     return "ac"
        case .lowPowerMode:     return "lpm"
        case .thermal:          return "thermal"
        case .lidClosedTooLong: return "lidcap"
        }
    }

    var short: String {
        switch self {
        case .batteryFloor: return "Battery"
        case .notOnACPower: return "On battery"
        case .lowPowerMode: return "Low Power"
        case .thermal:          return "Thermal"
        case .lidClosedTooLong: return "Time cap"
        }
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal:  return "Nominal"
        case .fair:     return "Fair"
        case .serious:  return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

/// Watches battery, power source, Low Power Mode and thermal pressure.
///
/// Every signal here is public API, entitlement-free and event-driven — there is no
/// polling loop. `onYieldChange` fires whenever the verdict flips so `PowerManager`
/// can drop its assertions immediately.
@Observable
@MainActor
final class PowerGuardrailManager {

    private(set) var batteryPercent: Int = 100
    private(set) var onACPower: Bool = true
    private(set) var isCharging: Bool = false
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var lowPowerMode: Bool = false
    /// Estimated minutes of battery left, or nil while macOS is still calculating
    /// (it reports -1 for a while after unplugging) or when on AC.
    private(set) var minutesRemaining: Int?

    /// Minutes left before the lid-closed cap releases the lock, or nil when the cap is
    /// off or the lid is open. Surfaced so the cap is never a silent termination.
    private(set) var lidCapRemaining: Int?
    /// Fires once per lid-close when the cap is close enough to warn about.
    var onLidCapWarning: ((Int) -> Void)?
    private var warnedForThisLidClose = false

    /// Non-nil when the guardrails are actively blocking. Drives the whole app.
    private(set) var yieldReason: YieldReason?

    /// Set by `PowerManager` so a trip can release assertions and notify the user.
    var onYieldChange: ((YieldReason?) -> Void)?

    /// Set by the app so the lid state can tighten the thermal rule.
    var lidIsClosed: () -> Bool = { false }
    /// When the lid was last shut, for the duration cap. Nil while the lid is open.
    var lidClosedSince: () -> Date? = { nil }

    private let prefs = Preferences.shared
    private var runLoopSource: CFRunLoopSource?

    init() {
        refreshPowerSource()
        refreshRunway()
        thermalState = ProcessInfo.processInfo.thermalState
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        installObservers()
        evaluate()
    }

    // MARK: - Observers

    private func installObservers() {
        // Battery / power source: event-driven via IOPS, no timer.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ raw in
            guard let raw else { return }
            let me = Unmanaged<PowerGuardrailManager>.fromOpaque(raw).takeUnretainedValue()
            // The IOPS callback lands on the run loop that registered it (main), but
            // hop explicitly so this stays correct if that ever changes.
            Task { @MainActor in
                me.refreshPowerSource()
                me.refreshRunway()
                me.evaluate()
            }
        }, ctx)?.takeRetainedValue() {
            runLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }

        // Thermal and power-state notifications post on the global queue — hop to main.
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            let s = ProcessInfo.processInfo.thermalState
            Task { @MainActor in
                self?.thermalState = s
                self?.evaluate()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil, queue: nil
        ) { [weak self] _ in
            let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { @MainActor in
                self?.lowPowerMode = lpm
                self?.evaluate()
            }
        }
    }

    // MARK: - Reads

    func refreshPowerSource() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            batteryPercent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : 0
            onACPower = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
            return
        }

        // No internal battery (desktop Mac): nothing to guard against.
        batteryPercent = 100
        onACPower = true
    }

    /// IOPSGetTimeRemainingEstimate returns kIOPSTimeRemainingUnknown (-1) while macOS is
    /// still working it out, and kIOPSTimeRemainingUnlimited (-2) on AC. Both mean
    /// "no number to show" rather than an error.
    private func refreshRunway() {
        let t = IOPSGetTimeRemainingEstimate()
        minutesRemaining = (t == kIOPSTimeRemainingUnknown || t == kIOPSTimeRemainingUnlimited)
            ? nil : Int(t / 60)
    }

    /// Recompute the verdict and fire `onYieldChange` only on an actual transition.
    ///
    /// The stored value always tracks the live numbers so the UI stays current, but the
    /// callback — which chimes and posts a banner — only fires when the *kind* of block
    /// changes. Otherwise a draining battery reported a new trip at every percent.
    func evaluate() {
        let next = computeYield()
        guard next != yieldReason else { return }
        let changedKind = next?.kind != yieldReason?.kind
        yieldReason = next
        if changedKind { onYieldChange?(next) }
    }

    private func computeYield() -> YieldReason? {
        // Thermal first — it is the only one that can damage hardware.
        if thermalState == .critical { return .thermal(.critical) }
        // A closed lid traps heat, so treat .serious as actionable there.
        if thermalState == .serious && lidIsClosed() { return .thermal(.serious) }

        // Hard cap on lid-closed time. The thermal signal assumes airflow, so it will not
        // save a Mac pinned awake inside a closed bag; this is the backstop that does.
        if prefs.maxLidClosedEnabled, let since = lidClosedSince() {
            let mins = Int(Date().timeIntervalSince(since) / 60)
            if mins >= prefs.maxLidClosedMinutes {
                return .lidClosedTooLong(minutes: mins)
            }
        }

        if prefs.yieldOnLowPowerMode && lowPowerMode { return .lowPowerMode }
        if prefs.acPowerOnly && !onACPower { return .notOnACPower }
        // Any time the battery is not actually gaining charge: a charger too weak for the
        // load reads as AC while the battery drains straight through the floor.
        if !(onACPower && isCharging) && batteryPercent < prefs.batteryFloor {
            return .batteryFloor(pct: batteryPercent, floor: prefs.batteryFloor)
        }
        return nil
    }

    var isBlocking: Bool { yieldReason != nil }

    /// Re-evaluate after the user moves a slider or flips a toggle.
    func settingsChanged() {
        refreshPowerSource()
        refreshRunway()
        evaluate()
    }

    /// Called on the app's slow tick so time-based guardrails (the lid cap) are noticed
    /// without their own timer.
    func tick() {
        refreshRunway()
        refreshLidCap()
        evaluate()
    }

    /// How long the lid-closed cap has left, plus a single warning shot before it trips.
    private func refreshLidCap() {
        guard prefs.maxLidClosedEnabled, let since = lidClosedSince() else {
            lidCapRemaining = nil
            warnedForThisLidClose = false
            return
        }
        let elapsed = Int(Date().timeIntervalSince(since) / 60)
        let left = max(0, prefs.maxLidClosedMinutes - elapsed)
        lidCapRemaining = left

        // Warn with enough runway to do something about it, but only once per lid close,
        // and never for a cap so short the warning would arrive with the trip.
        let warnAt = min(10, max(1, prefs.maxLidClosedMinutes / 6))
        if left <= warnAt, left > 0, !warnedForThisLidClose {
            warnedForThisLidClose = true
            onLidCapWarning?(left)
        }
    }

    // No deinit: lives for the whole process, and tearing down a run loop source from
    // an arbitrary deinit thread would be worse than leaving it.
}

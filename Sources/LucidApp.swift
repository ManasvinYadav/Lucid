import SwiftUI
import AppKit
import Observation

enum LockMode: String, CaseIterable, Identifiable {
    case disabled, auto, forced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: return "Disabled"
        case .auto:     return "Auto (Agent-driven)"
        case .forced:   return "Force Always Awake"
        }
    }

    /// For the segmented control in the menu, where the full titles do not fit.
    var shortTitle: String {
        switch self {
        case .disabled: return "Off"
        case .auto:     return "Auto"
        case .forced:   return "Always"
        }
    }
}

/// Wires the four managers together and owns the single arm/disarm decision.
@Observable
@MainActor
final class AppState {
    let power = PowerManager()
    let guardrails = PowerGuardrailManager()
    let lifecycle = AgentLifecycleManager()
    let notifications = NotificationManager()

    var mode: LockMode = .auto {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "lockMode")
            evaluate()
        }
    }

    /// Set by the Pause menu items. Nil means not paused.
    private(set) var pausedUntil: Date?
    private var agentsWantLock = false
    private var pauseTimer: Timer?
    private var guardrailTimer: Timer?

    var privilegeRuleInstalled: Bool

    init() {
        mode = LockMode(rawValue: UserDefaults.standard.string(forKey: "lockMode") ?? "auto") ?? .auto
        privilegeRuleInstalled = PowerManager.isPrivilegeRuleInstalled()
        loginItemEnabled = LoginItem.isEnabled

        lifecycle.batteryReader = { [weak guardrails] in
            (guardrails?.batteryPercent ?? 100, guardrails?.onACPower ?? true)
        }
        guardrails.lidIsClosed = { [weak power] in power?.lidClosed ?? false }
        guardrails.lidClosedSince = { [weak power] in power?.lidClosedSince }
        // The lid cap is time-based, so it needs a nudge rather than an event.
        power.onLidChange = { [weak self] closed in
            guard let self else { return }
            self.guardrails.tick()
            if closed {
                self.lidClosedAt = Date()
                self.awayReport = nil
            } else if let since = self.lidClosedAt {
                self.lidClosedAt = nil
                let report = AwayReport.build(closedSince: since, state: self)
                if report.isWorthShowing {
                    self.awayReport = report
                    self.notifications.post(.awayReport(report.headline))
                }
                self.refreshPreflight()
            }
        }
        guardrails.onLidCapWarning = { [weak self] mins in
            self?.notifications.post(.lidCapWarning(minutes: mins))
        }


        lifecycle.onShouldArmChange = { [weak self] want in
            guard let self else { return }
            self.agentsWantLock = want
            self.evaluate()
            self.notifications.post(want ? .lockEngaged : .sessionComplete)
        }

        // Session list changes that do not flip the arm decision (a new session appearing,
        // a status label changing) still need to reach the status file.
        lifecycle.onSessionsChanged = { [weak self] in self?.writeStatusFile() }

        guardrails.onYieldChange = { [weak self] reason in
            guard let self else { return }
            self.evaluate()
            if let reason { self.notifications.post(.guardrailTripped(reason)) }
        }

        notifications.onToggle = { [weak self] in self?.toggleFromHotkey() }

        // The lid-closed cap is time-based: nothing fires an event when it expires.
        guardrailTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.guardrails.tick() }
        }

        // A crash-restart should not abandon agents that are still running. This must run
        // after every callback above is wired, or the re-adopted sessions publish into a
        // manager with nothing listening and the lock is never re-armed.
        lifecycle.readoptSurvivingSessions()

        evaluate()

        // First run: the two things that cannot happen silently (an admin password and
        // editing the user's agent config) get an explicit, previewable pass.
        DispatchQueue.main.async { [self] in
            OnboardingController.shared.showIfFirstRun(state: self)
        }
    }

    // MARK: - The single decision

    func evaluate() {
        let wasArmed = power.isArmed
        if wantsLock {
            power.arm()
        } else {
            power.disarm()
        }
        // Only on the transition into armed, so this is not re-run on every hook event.
        if !wasArmed, power.isArmed { refreshPreflight() }
        if !power.isArmed { preflightIssues = [] }
        writeStatusFile()
    }

    /// Mirrors live state to ~/.lucid/status.json on every transition.
    /// This is how you debug a misbehaving hook without attaching a console.
    private func writeStatusFile() {
        let payload: [String: Any] = [
            "mode": mode.rawValue,
            "armed": power.isArmed,
            "sleepDisabled": power.sleepDisabledEngaged,
            "lidClosed": power.lidClosed,
            "paused": isPaused,
            "graceRemaining": lifecycle.graceRemaining as Any,
            "blockedBy": guardrails.yieldReason?.short as Any,
            "battery": guardrails.batteryPercent,
            "onAC": guardrails.onACPower,
            "thermal": guardrails.thermalState.label,
            "sessions": lifecycle.sessions.map {
                ["agent": $0.agent, "session": $0.sessionID, "status": $0.status.rawValue,
                 "source": $0.source.rawValue, "detail": $0.detail as Any,
                 "pid": $0.pid as Any]
            },
            "lidCapRemaining": guardrails.lidCapRemaining as Any,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: AppPaths.status, options: .atomic)
    }

    var wantsLock: Bool {
        if guardrails.isBlocking { return false }
        if isPaused { return false }
        switch mode {
        case .disabled: return false
        case .forced:   return true
        case .auto:     return agentsWantLock
        }
    }

    var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return until > Date()
    }

    func pause(minutes: Int) {
        pausedUntil = Date().addingTimeInterval(Double(minutes) * 60)
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60 + 1,
                                          repeats: false) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
        evaluate()
    }

    func resume() {
        pausedUntil = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        evaluate()
    }

    /// Option-Command-L. Forced <-> Auto, or un-pause if paused.
    func toggleFromHotkey() {
        if isPaused { resume(); return }
        mode = (mode == .forced) ? .auto : .forced
    }

    func settingsChanged() {
        guardrails.settingsChanged()
        evaluate()
        // evaluate() calls arm(), which returns early when already armed. The lid-close
        // layer has to be reapplied explicitly or the toggle does nothing until the next
        // disarm/arm cycle.
        power.applyLidCoverage()
    }

    func refreshPrivilegeRule() {
        privilegeRuleInstalled = PowerManager.isPrivilegeRuleInstalled()
        loginItemEnabled = LoginItem.isEnabled
    }

    /// LoginItem reads the filesystem directly; this just nudges the view to re-read it.
    var loginItemEnabled = false
    func refreshLoginItem() { loginItemEnabled = LoginItem.isEnabled }

    // MARK: - Menu bar presentation

    var statusSymbol: String {
        if mode == .forced && power.isArmed { return "cup.and.saucer.fill" }
        if guardrails.isBlocking             { return "exclamationmark.triangle.fill" }
        if power.isArmed                     { return "brain.fill" }
        if mode == .disabled                 { return "laptopcomputer" }
        return "brain"
    }

    var statusSummary: String {
        if guardrails.isBlocking { return guardrails.yieldReason?.short ?? "Blocked" }
        if isPaused              { return "Paused" }
        if power.isArmed         { return mode == .forced ? "Forced awake" : "Awake" }
        return "Sleepable"
    }

    /// A full sentence for the menu header — what is happening and why.
    var statusDetail: String {
        if let r = guardrails.yieldReason { return r.summary }
        if isPaused {
            guard let until = pausedUntil else { return "Paused" }
            let mins = max(0, Int(until.timeIntervalSinceNow / 60) + 1)
            return "Paused for another \(mins) min"
        }
        if mode == .disabled { return "Not holding the Mac awake" }
        if power.isArmed {
            if mode == .forced { return "Holding awake until you turn this off" }
            let n = workingCount
            return n == 1 ? "1 agent working" : "\(n) agents working"
        }
        if lifecycle.sessions.isEmpty { return "Waiting for an agent to start" }
        return "All agents idle — the Mac can sleep"
    }

    /// Colour for the status pill: green while holding, orange when something is
    /// stopping it, grey when idle by design.
    var statusTint: StatusTint {
        if guardrails.isBlocking { return .warning }
        if isPaused || mode == .disabled { return .neutral }
        return power.isArmed ? .active : .neutral
    }

    enum StatusTint { case active, warning, neutral }

    var workingCount: Int { lifecycle.sessions.filter(\.isWorking).count }

    /// Refreshed whenever the lock arms with the lid still open — the last moment the user
    /// can act on anything that is wrong.
    private(set) var preflightIssues: [Preflight.Issue] = []

    /// Set when the lid opens on a run worth summarising. Cleared when the user dismisses
    /// it or the lid shuts again.
    var awayReport: AwayReport?
    private var lidClosedAt: Date?

    func refreshPreflight() {
        guard power.isArmed, !power.lidClosed else { preflightIssues = []; return }
        preflightIssues = Preflight.run(state: self)
    }
}

struct LucidApp: App {
    @State private var state = AppState()

    var body: some Scene {
        // .window style is required: MenuBarExtra(.menu) does not re-render its body while
        // open and never fires onAppear (FB13683957), so the live session list would show
        // stale rows. Trade-off: a .window popover cannot be closed programmatically
        // (FB11984872), so there is deliberately no Close button below.
        MenuBarExtra {
            LucidMenuView(state: state)
        } label: {
            Image(systemName: state.statusSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(state: state)
        }
    }
}

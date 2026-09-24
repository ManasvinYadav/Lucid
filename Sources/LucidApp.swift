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
    /// The lock is held because agents are working, not for Always or a lid test.
    private var heldForAgents = false
    private var pauseTimer: Timer?
    private var guardrailTimer: Timer?

    /// PowerManager checks the rule itself (it needs the answer before any arm), so this
    /// only forwards; a second copy here went stale whenever the rule changed.
    var privilegeRuleInstalled: Bool { power.ruleInstalled }

    init() {
        mode = LockMode(rawValue: UserDefaults.standard.string(forKey: "lockMode") ?? "auto") ?? .auto
        loginItemEnabled = LoginItem.isEnabled
        HookInstaller.syncClient()

        lifecycle.batteryReader = { [weak guardrails] in
            (guardrails?.batteryPercent ?? 100, guardrails?.onACPower ?? true)
        }
        // Docked with the lid shut is the desk, not a bag: no cap, no lid-shut thermal rule.
        guardrails.lidIsClosed = { [weak power] in power?.lidShutUndocked ?? false }
        guardrails.lidClosedSince = { [weak power] in
            power?.lidShutUndocked == true ? power?.lidClosedSince : nil
        }
        // The lid cap is time-based, so it needs a nudge rather than an event.
        power.onLidChange = { [weak self] closed in
            guard let self else { return }
            if closed {
                self.awayReport = nil
                // Docked is the desk: the user is right here, not away.
                if !self.power.docked { self.startAway(since: Date()) }
            } else {
                // Before the tick below: opening the lid ends the lid cap.
                self.endAway()
                self.refreshPreflight()
            }
            self.guardrails.tick()
        }
        guardrails.onLidCapWarning = { [weak self] mins in
            // The cap only ends a lock; with none held there is nothing to warn about.
            guard let self, self.power.isArmed else { return }
            self.notifications.post(.lidCapWarning(minutes: mins))
        }

        lifecycle.onShouldArmChange = { [weak self] want in
            guard let self else { return }
            self.agentsWantLock = want
            self.evaluate()
        }

        // A lid test ending, a rule change, or a flag cleared behind our back can each
        // change what the lock should be.
        power.onStateChange = { [weak self] in
            guard let self else { return }
            // Docking or undocking with the lid still shut moves the away window: undocked
            // is the bag, docked is the desk.
            if self.power.lidShutUndocked, self.lidClosedAt == nil {
                self.startAway(since: self.power.lidClosedSince ?? Date())
            } else if self.power.docked, self.lidClosedAt != nil {
                self.endAway()
            }
            self.evaluate()
        }

        // Session list changes that do not flip the arm decision (a new session appearing,
        // a status label changing) still need to reach the status file.
        lifecycle.onSessionsChanged = { [weak self] in self?.writeStatusFile() }

        guardrails.onYieldChange = { [weak self] reason in
            guard let self else { return }
            let wasArmed = self.power.isArmed
            self.evaluate()
            guard let reason else { return }
            // Only a guardrail that actually released a lock is news, here and in the away
            // report. Unplugging with no agent working used to chime "wake lock released"
            // for a lock never held.
            if wasArmed, !self.power.isArmed {
                if self.lidClosedAt != nil { self.awayTrips.append(reason.summary) }
                self.notifications.post(.guardrailTripped(reason))
            }
        }

        notifications.onToggle = { [weak self] in self?.toggleFromHotkey() }

        // The lid-closed cap is time-based: nothing fires an event when it expires.
        // Pause expiry is checked here too: the one-shot pause timer does not fire while the
        // Mac sleeps, which left the lock released long after the pause ran out.
        guardrailTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.pausedUntil != nil, !self.isPaused { self.resume() }
                self.guardrails.tick()
            }
        }

        // A crash-restart should not abandon agents that are still running. This must run
        // after every callback above is wired, or the re-adopted sessions publish into a
        // manager with nothing listening and the lock is never re-armed.
        lifecycle.readoptSurvivingSessions()

        evaluate()
        // Recovery cleared a flag that had vetoed the lid-close sleep. With nothing to
        // hold the lock now, that sleep has to be asked for, as disarm() would have.
        if power.recoveredAtLaunch, !power.isArmed { power.sleepNowIfLidShut() }

        // First run: the two things that cannot happen silently (an admin password and
        // editing the user's agent config) get an explicit, previewable pass.
        DispatchQueue.main.async { [self] in
            OnboardingController.shared.showIfFirstRun(state: self)
        }
    }

    // MARK: - The single decision

    func evaluate() {
        let wasArmed = power.isArmed
        let wasHeldForAgents = heldForAgents
        if wantsLock {
            power.arm()
        } else {
            power.disarm()
        }
        heldForAgents = power.isArmed && mode == .auto && agentsWantLock && !power.lidTestRunning
        // Banners follow the lock itself, not agent intent: an agent starting while paused
        // or blocked used to announce a lock that was never taken. Forced mode and the lid
        // test are the user's own doing, so they get no banner. A guardrail release posts
        // its own, more specific one. "Session complete" only when the agents going idle
        // is what let go: not a pause, leaving Always, or the end of a lid test.
        if !wasArmed, power.isArmed, mode == .auto, !power.lidTestRunning {
            notifications.post(.lockEngaged)
        } else if wasArmed, !power.isArmed, wasHeldForAgents, !agentsWantLock,
                  !guardrails.isBlocking {
            notifications.post(.sessionComplete)
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
        // A running lid test needs the lock whatever the mode, but never past a guardrail.
        if power.lidTestRunning { return true }
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

    /// Control-Option-Command-L. Forced <-> Auto, or un-pause if paused. Always
    /// announced: a global shortcut pressed by accident must not silently hold the Mac awake.
    func toggleFromHotkey() {
        if isPaused { resume() } else { mode = (mode == .forced) ? .auto : .forced }
        var text: String
        switch mode {
        case .forced:   text = "Always awake, until you press ⌃⌥⌘L again."
        case .auto:     text = "Automatic: awake only while an agent works."
        case .disabled: text = "Off: Lucid is not keeping this Mac awake."
        }
        if mode != .disabled, let r = guardrails.yieldReason { text += " Held off for now: \(r.short)." }
        notifications.post(.shortcut(text))
    }

    func settingsChanged() {
        guardrails.settingsChanged()
        evaluate()
        // evaluate() calls arm(), which returns early when already armed. The lid-close
        // layer has to be reapplied explicitly or the toggle does nothing until the next
        // disarm/arm cycle.
        power.applyLidCoverage()
        writeStatusFile()
    }

    func refreshPrivilegeRule() {
        power.refreshRuleInstalled()
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
    /// Battery at the moment the lid shut, or nil if it shut on AC. One reading for the
    /// whole window: summing per-session drain counted concurrent sessions twice.
    private(set) var lidClosedBattery: Int?
    /// Guardrails that tripped while the lid was shut. The live reason is gone by the time
    /// the lid opens (opening it ends the lid cap), so the report needs its own record.
    private(set) var awayTrips: [String] = []

    private func startAway(since: Date) {
        lidClosedAt = since
        lidClosedBattery = guardrails.onACPower ? nil : guardrails.batteryPercent
        awayTrips = []
        awayReport = nil
    }

    /// The user is back: the lid opened, or the Mac was docked with the lid still shut.
    private func endAway() {
        guard let since = lidClosedAt else { return }
        lidClosedAt = nil
        let report = AwayReport.build(closedSince: since, state: self)
        if report.isWorthShowing {
            awayReport = report
            notifications.post(.awayReport(report.headline))
        }
    }

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

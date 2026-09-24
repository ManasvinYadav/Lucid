import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt
import Observation
import os

private let log = Logger(subsystem: "com.lucid.app", category: "power")

/// True while *this process* owns the SleepDisabled flag — set by us, not merely observed.
/// Global because `atexit` takes a bare C function pointer that cannot capture context,
/// and this flag has to survive into that teardown path. Written only by
/// engageSleepDisabled: mirroring the live value here made quitting wipe a flag the user
/// had set by hand, and skipped teardown when someone else had cleared ours.
nonisolated(unsafe) private var gSleepDisabledEngaged = false

/// Registered with `atexit`. Covers normal termination and uncaught-exception exits.
/// `kill -9` cannot be covered here — the arm-marker file handles that on next launch.
private func emergencyTeardown() {
    // Unconditional: if the panel was dimmed we must undo it whether or not the sleep
    // flag was engaged, because a dark screen is the more alarming thing to leave behind.
    DisplayBrightness.restore()
    guard gSleepDisabledEngaged else { return }
    // The marker goes only once the flag is really clear. If sudo failed (the rule was
    // removed under us), the marker is what makes the next launch retry and say so.
    guard PowerManager.setSleepDisabledSync(false),
          PowerManager.readSleepDisabled() != true else { return }
    try? FileManager.default.removeItem(at: AppPaths.armMarker)
    gSleepDisabledEngaged = false
}

/// Registered separately from the sleep teardown: this must run on every clean exit,
/// not just when SleepDisabled was engaged. A socket file left behind makes a dead app
/// look alive to anything that only checks for the file.
///
/// status.json goes with it, and that is the whole difference between a clean quit and a
/// crash. It mirrors live state, so surviving a clean quit made the next launch re-adopt
/// sessions that nothing had crashed out of — and label them "Recovered after restart".
/// After a kill -9 no atexit handler runs, the file survives, and re-adoption means what
/// it says.
private func removeSocketFile() {
    unlink(AppPaths.socket.path)
    unlink(AppPaths.status.path)
}

/// Owns every mechanism that keeps the Mac awake, in three deliberately separate layers:
///
///  1. **Assertion** (unprivileged) — `PreventUserIdleSystemSleep`. Stops idle sleep.
///     This is all you need while the lid is open.
///  2. **Display** (unprivileged) — we never assert display wake, and can actively blank
///     the panel. Keeping the screen lit under a closed lid just traps heat.
///  3. **SleepDisabled** (root, via a scoped sudoers rule) — the only thing that actually
///     survives lid close.
///
/// Layer 3 is why this class is careful: SleepDisabled lives in
/// /Library/Preferences/com.apple.PowerManagement.plist and persists across reboot, so a
/// crash while engaged would leave the Mac permanently unable to sleep.
@Observable
@MainActor
final class PowerManager {

    // MARK: Observable state

    private(set) var isArmed = false
    private(set) var sleepDisabledEngaged = false
    private(set) var lidClosed = false
    /// A display other than the built-in panel is online: the user is at the desk, not
    /// carrying a closed bag. Apple's clamshell mode always has one. Not from
    /// AppleClamshellCausesSleep, which reads No whenever the lid is open.
    private(set) var docked = false
    /// The lid is shut and nobody is using the Mac through another display. What the lid
    /// cap and the lid-shut thermal rule are about.
    var lidShutUndocked: Bool { lidClosed && !docked }
    /// Set when launch found the arm marker and cleared a SleepDisabled a crash left behind.
    private(set) var recoveredAtLaunch = false
    private(set) var lastError: String?

    /// Set when the Mac slept while we were supposed to be holding it awake — i.e. the
    /// lock failed. The whole point of this app is that this never happens, so it is
    /// surfaced prominently rather than logged and forgotten.
    private(set) var lastFailedSleep: Date?
    /// Every sleep we observed, armed or not, newest first. Capped.
    private(set) var sleepHistory: [(at: Date, wasArmed: Bool)] = []
    /// When the lid was last shut. Drives the safety cap and the lid test.
    private(set) var lidClosedSince: Date?
    private var displayWatchdog: Timer?
    /// How long the panel stayed lit with the lid shut. The honest measure of whether
    /// blanking is working, rather than whether the blank call was made.
    private(set) var displayLitSeconds = 0
    private(set) var displayBlanked = false
    /// Processes that kept the panel lit when blanking was attempted. Empty until it fails.
    private(set) var panelHeldBy: [String] = []

    // MARK: Lid test

    /// Which mechanism is under test.
    ///
    /// Worth separating, because the two differ enormously in cost. The assertion is
    /// unprivileged and free; SleepDisabled needs a root-installed sudoers rule and, if it
    /// is ever left set, a Mac that cannot sleep. If the assertion alone survives a lid
    /// close on a given machine, the privileged layer is dead weight there and should be
    /// turned off. That is a question about the machine, not about anyone's opinion, so the
    /// test asks it directly.
    enum LidTestLayer: String, Equatable {
        case assertionOnly
        case sleepDisabled

        var label: String {
            switch self {
            case .assertionOnly: return "power assertion only"
            case .sleepDisabled: return "assertion + SleepDisabled"
            }
        }
    }

    enum LidTestState: Equatable {
        case idle
        case waitingForClose(LidTestLayer)          // armed, lid still open
        case lidClosed(since: Date, layer: LidTestLayer)
        case passed(closedFor: TimeInterval, panelLitSeconds: Int, layer: LidTestLayer)
        case failed(sleptAt: Date, layer: LidTestLayer)
        case cancelled(String)
    }
    private(set) var lidTest: LidTestState = .idle
    /// Set only while a lid test is running, to force one layer on or off.
    private var testOverrideLidCoverage: Bool?

    /// A running test needs the lock held, so AppState counts it as a reason to arm. The
    /// test used to arm this class directly, behind AppState's back: an agent finishing
    /// mid-test dropped the test's lock (and reported a false pass), and a finished test
    /// dropped a lock that a working agent still needed.
    var lidTestRunning: Bool {
        switch lidTest {
        case .waitingForClose, .lidClosed: return true
        default: return false
        }
    }

    /// Whether the scoped sudoers rule is in place. Lid coverage is never attempted
    /// without it: that only produced a failed sudo on every arm and a permanent red error.
    private(set) var ruleInstalled = false

    /// AppState re-derives the lock from this, so it must fire on any change that could
    /// alter what the lock should be (a test ending, a rule change, a flag cleared by
    /// someone else). Re-entrant calls are harmless: arm and disarm are no-ops when state
    /// already matches.
    var onStateChange: (() -> Void)?
    /// Fired on a lid open/close transition.
    var onLidChange: ((Bool) -> Void)?

    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    /// True only while *this app* is the reason SleepDisabled is set.
    private var sleepDisabledSetByUs = false
    var ownsSleepDisabled: Bool { sleepDisabledSetByUs }
    private var signalSources: [DispatchSourceSignal] = []
    private var clamshellTimer: Timer?

    private let prefs = Preferences.shared

    init() {
        atexit(emergencyTeardown)
        atexit(removeSocketFile)
        installSignalHandlers()
        ruleInstalled = PowerManager.isPrivilegeRuleInstalled()
        recoverFromCrashIfNeeded()
        refreshSystemState()

        // The lid state has no cheap notification, and it only matters at human timescales.
        clamshellTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSystemState() }
        }

        observeSleep()
    }

    /// The Mac tells us before it sleeps. If that happens while we are armed, the lock did
    /// not hold — record it so the user gets an answer instead of a suspicion.
    private func observeSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Clamshell sleep follows the lid within about a second, usually before
                // the 5 s poll. Catch the close here, or the lid test never reaches a
                // verdict and the away report is never built for the sleep it exists for.
                self.refreshSystemState()
                let armed = self.isArmed
                self.sleepHistory.insert((Date(), armed), at: 0)
                if self.sleepHistory.count > 20 { self.sleepHistory.removeLast() }
                // Only a sleep the lock promised to prevent is a failure. Read the lid
                // directly: the 5 s poll has usually not seen it close yet. With the lid
                // shut and no SleepDisabled (no rule, or coverage off), sleeping is the
                // documented behaviour, not a broken lock.
                let lidShut = PowerManager.readClamshellFlag("AppleClamshellState") ?? self.lidClosed
                if armed && (!lidShut || self.sleepDisabledSetByUs) {
                    self.lastFailedSleep = Date()
                    log.error("SLEPT WHILE ARMED — the wake lock did not hold")
                } else if armed {
                    log.info("system sleeping with the lid shut and no SleepDisabled — expected")
                } else {
                    log.info("system sleeping (not armed)")
                }
                self.onStateChange?()
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The lid-closed clock measures trapped heat, and sleeping ended that.
                // Waking with the lid still shut must start a fresh window, or the cap
                // fires immediately on a clock that ran through the sleep.
                if self.lidClosed { self.lidClosedSince = Date() }
                // SleepDisabled survives sleep, but re-read so the UI cannot drift.
                self.refreshSystemState()
                self.onStateChange?()
            }
        }
    }

    // MARK: - Lid test
    //
    // The one thing that cannot be verified from a terminal is whether the lock actually
    // survives a lid close. This drives that test end to end and reports what it saw.

    func startLidTest(layer: LidTestLayer = .assertionOnly) {
        if layer == .sleepDisabled, !ruleInstalled {
            lidTest = .cancelled("The privilege rule is not installed, so this layer cannot be tested.")
            onStateChange?(); return
        }

        // The test is a reason to hold the lock, so AppState arms for it. If the lock is
        // already held, switch it to the layer under test.
        if docked {
            lidTest = .cancelled(Self.dockedTestNote)
            onStateChange?(); return
        }
        testOverrideLidCoverage = (layer == .sleepDisabled)
        lidTest = lidClosed ? .lidClosed(since: Date(), layer: layer) : .waitingForClose(layer)
        applyLidCoverage()
        onStateChange?()

        if !isArmed {
            abortLidTest("A guardrail is holding the lock off, so there is nothing to test.")
        } else if layer == .sleepDisabled, !sleepDisabledSetByUs {
            abortLidTest("SleepDisabled did not engage — check the Privileges tab.")
        } else if layer == .assertionOnly, sleepDisabledEngaged {
            abortLidTest("SleepDisabled is still set, so this would not be a clean test of the assertion alone.")
        }
    }

    /// Hands the lock decision back to AppState. The test state must already be terminal,
    /// so AppState no longer counts the test as a reason to hold the lock.
    /// With a display attached macOS never sleeps on lid close, so the test would pass
    /// whatever the lock did — and then advise removing the layer that is needed.
    private static let dockedTestNote =
        "With an external display attached, macOS does not sleep on lid close, so this would pass whatever the lock does. Disconnect the display and try again."

    private func endLidTestArming() {
        testOverrideLidCoverage = nil
        onStateChange?()      // AppState drops the lock unless something else still wants it
        applyLidCoverage()    // and if it does, puts back the user's layer (no-op if disarmed)
    }

    private func abortLidTest(_ why: String) {
        lidTest = .cancelled(why)
        endLidTestArming()
    }

    func cancelLidTest() {
        lidTest = .idle
        endLidTestArming()
    }

    private func advanceLidTest(closed: Bool) {
        switch lidTest {
        case .waitingForClose where closed && docked:
            abortLidTest(Self.dockedTestNote); return
        case let .waitingForClose(layer) where closed:
            lidTest = .lidClosed(since: Date(), layer: layer)
        case let .lidClosed(since, layer) where !closed:
            // Reopened. Any sleep in the window is a failure — armed or not. Filtering on
            // "armed" turned a lock that was dropped mid-test into a false pass.
            let slept = sleepHistory.first { $0.at >= since }
            let held = Date().timeIntervalSince(since)
            if let s = slept {
                lidTest = .failed(sleptAt: s.at, layer: layer)
            } else if held < 60 {
                lidTest = .cancelled("Lid was only shut for \(Int(held))s — try at least a minute.")
            } else {
                lidTest = .passed(closedFor: held, panelLitSeconds: displayLitSeconds,
                                  layer: layer)
            }
            endLidTestArming()
        default:
            break
        }
        onStateChange?()
    }

    func clearFailureRecord() {
        lastFailedSleep = nil
        onStateChange?()
    }

    // MARK: - Arming

    func arm() {
        guard !isArmed else { return }
        isArmed = true

        createAssertion()
        applyLidCoverage()
        if prefs.blankDisplayOnWork { displaySleepNow() }
        // Arming while the lid is already shut leaves the panel lit just the same.
        if lidClosed { blankIfLidShut(); startDisplayWatchdog() }

        log.info("armed (lidCoverage=\(self.prefs.lidCloseCoverage))")
        onStateChange?()
    }

    /// Bring the privileged layer in line with the preference. Called on arm and again
    /// whenever settings change, because the toggle has to mean something while armed —
    /// `arm()` returns early once armed, so doing this only there made the switch inert.
    func applyLidCoverage() {
        guard isArmed else { return }
        // The lid test can force the unprivileged layer on its own, to find out whether
        // the privileged one is needed at all on this machine.
        engageSleepDisabled((testOverrideLidCoverage ?? prefs.lidCloseCoverage) && ruleInstalled)
    }

    func disarm() {
        guard isArmed else { return }
        isArmed = false

        // AppState counts a running test as a reason to hold the lock, so reaching here
        // mid-test means a guardrail overrode it. Say so rather than grading a test whose
        // lock was pulled out from under it.
        if lidTestRunning {
            lidTest = .cancelled("The lock was released during the test (a guardrail tripped).")
            testOverrideLidCoverage = nil
        }

        releaseAssertion()
        // Only ever clears a flag we set; engageSleepDisabled checks ownership itself.
        engageSleepDisabled(false)
        stopDisplayWatchdog()
        sleepNowIfLidShut()

        log.info("disarmed")
        onStateChange?()
    }

    /// Clearing SleepDisabled does not make the Mac sleep — clamshell sleep is decided at
    /// the moment the lid closes, and that decision was already vetoed. Without this, work
    /// that finishes with the lid down leaves the Mac awake until it is physically opened,
    /// which is the half of the promise about letting it sleep.
    func sleepNowIfLidShut() {
        // Live, not the 5 s poll: a lid opened a moment ago must not be put to sleep in
        // front of the user, and one shut a moment ago still needs it.
        guard !isArmed, PowerManager.readClamshellFlag("AppleClamshellState") ?? lidClosed else { return }
        // An external display attached with the lid shut means the user is deliberately
        // using the Mac right now.
        guard PowerManager.externalDisplayCount == 0 else { return }
        log.info("work finished with the lid shut — requesting sleep")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        try? p.run()
    }

    /// Called by the guardrails. Drops everything immediately, regardless of agent state.
    func yieldNow(reason: YieldReason) {
        log.notice("yielding: \(reason.summary, privacy: .public)")
        disarm()
    }

    // MARK: - Layer 1: unprivileged assertion

    private func createAssertion() {
        guard !hasAssertion else { return }
        // NOTE: kIOPMAssertionTypePreventSystemSleep is deliberately NOT used. Apple's own
        // header marks it "Deprecated in 10.9 ... not supported in any OS X releases", and it
        // returns kIOReturnSuccess while doing nothing — a silent no-op. Layer 3 is what
        // actually survives lid close.
        var id: IOPMAssertionID = 0
        let rc = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Lucid: agent session active" as CFString,
            &id)

        if rc == kIOReturnSuccess {
            assertionID = id
            hasAssertion = true
        } else {
            lastError = "Could not create power assertion (\(rc))"
            log.error("IOPMAssertionCreateWithName failed: \(rc)")
        }
    }

    private func releaseAssertion() {
        guard hasAssertion else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        hasAssertion = false
    }

    // MARK: - Layer 2: display, explicitly decoupled

    /// Blank the panel now. This is a pmset *command*, not a *setting*, so it needs no root.
    /// We never hold PreventUserIdleDisplaySleep — letting the screen die is the whole point.
    func displaySleepNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    // MARK: - Display blanking while the lid is shut
    //
    // Closing the lid normally blanks the panel as one step of the clamshell sleep
    // sequence. SleepDisabled vetoes that whole sequence, so the blanking never happens
    // either and the panel stays lit inside the closed lid. Nothing else turns it off,
    // because the app deliberately holds no display assertion. So we blank it ourselves.

    /// Every connected display. The online list, unlike the active one, still includes
    /// displays that are asleep, so counts taken from it do not change when we blank.
    nonisolated static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &n) == .success else { return [] }
        return Array(ids.prefix(Int(n)))
    }

    /// The built-in panel. Everything here targets it by id, never CGMainDisplayID(): with
    /// the lid shut on an external monitor, the main display IS that monitor, and blanking
    /// or dimming "the main display" took down the screen the user was working on.
    nonisolated static var builtinDisplay: CGDirectDisplayID? {
        onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Displays other than the built-in panel. Any at all means the user may be working on
    /// one, so nothing is blanked or put to sleep.
    nonisolated static var externalDisplayCount: Int {
        onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    /// Whether the built-in panel is dark. Inactive counts as dark: in Apple's clamshell
    /// mode the panel is switched off rather than asleep. Public CoreGraphics, no entitlement.
    nonisolated static var displayIsAsleep: Bool {
        guard let id = builtinDisplay else { return true }
        return CGDisplayIsAsleep(id) != 0 || CGDisplayIsActive(id) == 0
    }

    /// Processes currently holding an assertion that keeps the panel lit, newest first.
    ///
    /// `pmset displaysleepnow` is a request that loses to any of these, so when the panel
    /// will not go dark this is the answer to why. Public API, no entitlement.
    nonisolated static func displayHolders() -> [(process: String, reason: String)] {
        var out: [(String, String)] = []
        var byProc: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProc) == kIOReturnSuccess,
              let dict = byProc?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }

        let keepsPanelLit: Set<String> = [
            kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
            "PreventUserIdleDisplaySleep",
            "InternalPreventDisplaySleep",
            "UserIsActive",
        ]
        for (pid, list) in dict {
            for a in list {
                let type = (a["AssertionTrueType"] as? String)
                    ?? (a[kIOPMAssertionTypeKey as String] as? String) ?? ""
                guard keepsPanelLit.contains(type) else { continue }
                let name = (a["Process Name"] as? String) ?? "pid \(pid)"
                let detail = (a[kIOPMAssertionNameKey as String] as? String) ?? type
                // powerd's own lid-open assertion goes away when the lid shuts, so it is
                // never the reason a panel stays lit inside a closed lid.
                if detail.contains("com.apple.powermanagement.lidopen") { continue }
                out.append((name, detail))
            }
        }
        return out
    }

    /// Blank the panel if the lid is shut, we are the reason it did not blank itself, and
    /// no external display is attached.
    private func blankIfLidShut() {
        guard panelNeedsBlanking, !PowerManager.displayIsAsleep else { return }
        log.info("lid shut with the lock held — blanking the panel")
        displaySleepNow()
    }

    /// Not gated on SleepDisabled: whichever layer vetoes the clamshell sleep also vetoes
    /// the blank that is one of its steps, so the panel stays lit either way. Never with
    /// an external display attached — `displaysleepnow` sleeps every display, including
    /// the one the user is looking at.
    private var panelNeedsBlanking: Bool {
        isArmed && lidClosed && PowerManager.externalDisplayCount == 0
    }

    /// `pmset displaysleepnow` is a request, not a command: a live UserIsActive assertion
    /// (a trackpad tickle, an app holding one) overrides it and the panel stays lit.
    /// Measured on an M4 — the call returns 0 and nothing happens. So this retries on a
    /// timer that only exists while the lid is shut and the lock is held, and it records
    /// what it actually observed rather than assuming the request landed.
    private func startDisplayWatchdog() {
        guard displayWatchdog == nil else { return }
        displayLitSeconds = 0
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.isArmed, self.lidClosed else { self.stopDisplayWatchdog(); return }
                if PowerManager.displayIsAsleep {
                    self.displayBlanked = true
                } else if self.panelNeedsBlanking {
                    self.displayLitSeconds += 5
                    self.blankIfLidShut()
                    // displaysleepnow is a request, and it loses to any process holding a
                    // display assertion. After 15s of losing, stop asking and take the
                    // brightness to zero instead. Reversible, and the brightness keys
                    // still work, so this can never strand the user with a dark screen.
                    if self.displayLitSeconds >= 15, !DisplayBrightness.isDimmed {
                        self.panelHeldBy = PowerManager.displayHolders().map(\.process)
                        if DisplayBrightness.dim() {
                            log.info("panel would not sleep — dimmed to zero instead")
                        }
                    }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        displayWatchdog = t
    }

    private func stopDisplayWatchdog() {
        displayWatchdog?.invalidate()
        displayWatchdog = nil
        DisplayBrightness.restore()
        panelHeldBy = []
    }

    // MARK: - Layer 3: SleepDisabled (root)

    /// Every decision here keys off ownership (`sleepDisabledSetByUs`), never the live
    /// flag: we set it only if nobody else has, and clear it only if we set it.
    private func engageSleepDisabled(_ on: Bool) {
        if on, removingRule { return }
        #if DEBUG_RENDER
        // Screenshots only: never touch the real flag.
        sleepDisabledEngaged = on; return
        #endif
        if on {
            guard !sleepDisabledSetByUs else { return }
            // Already set by the user or another tool: it holds the lid for us, and it is
            // not ours to clear later.
            if PowerManager.readSleepDisabled() == true { sleepDisabledEngaged = true; return }
            // Marker BEFORE engaging, so a crash in between still self-heals. No marker,
            // no engage: without it a crash would leave the flag set with nothing to undo it.
            guard AppPaths.writeArmMarker() else {
                lastError = "Could not write \(AppPaths.armMarker.path), so SleepDisabled was not engaged."
                return
            }
            gSleepDisabledEngaged = true      // teardown clears it from here on
            guard PowerManager.setSleepDisabledSync(true) else {
                gSleepDisabledEngaged = false
                try? FileManager.default.removeItem(at: AppPaths.armMarker)
                lastError = "Could not set SleepDisabled — the privilege rule may not be installed."
                return
            }
            sleepDisabledSetByUs = true
        } else {
            guard sleepDisabledSetByUs else { return }
            // Someone may already have cleared it; then there is nothing to run.
            if PowerManager.readSleepDisabled() != false {
                guard PowerManager.setSleepDisabledSync(false) else {
                    // Keep ownership and the marker, so quitting or relaunching retries.
                    lastError = "Could not clear SleepDisabled, so this Mac cannot sleep. Run: sudo pmset -a disablesleep 0"
                    log.error("failed to clear SleepDisabled")
                    return
                }
            }
            sleepDisabledSetByUs = false
            gSleepDisabledEngaged = false
            try? FileManager.default.removeItem(at: AppPaths.armMarker)
        }

        // Read back rather than trusting the exit code.
        let live = PowerManager.readSleepDisabled()
        sleepDisabledEngaged = live ?? on
        if live != nil && live != on {
            lastError = "SleepDisabled did not take effect"
            log.error("SleepDisabled readback mismatch (wanted \(on))")
        } else {
            lastError = nil
        }
    }

    /// Synchronous so it is usable from `atexit`. Returns true on a clean exit status.
    nonisolated static func setSleepDisabledSync(_ on: Bool) -> Bool {
        // -n: never prompt. With the scoped NOPASSWD rule this succeeds silently;
        // without it this fails fast instead of hanging on a password prompt.
        runTool("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]).ok
    }

    /// Runs a tool to completion without spinning the run loop. `waitUntilExit()` does
    /// spin it, which let queued main-actor work run in the middle of an arm: a disarm or
    /// a SIGTERM handler could land between writing the marker and setting the flag, and
    /// leave SleepDisabled=1 with nothing tracking it. Bounded, so a wedged tool cannot
    /// freeze the app.
    nonisolated static func runTool(_ path: String, _ args: [String], timeout: TimeInterval = 5,
                                    mergeStderr: Bool = false) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return (false, error.localizedDescription) }
        // Drained while it runs: a child that fills the pipe buffer blocks until someone
        // reads, and would otherwise sit there until the timeout.
        let buf = OutputBuffer()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            buf.data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        let finished = exited.wait(timeout: .now() + timeout) == .success
        if !finished { p.terminate() }
        let data = drained.wait(timeout: .now() + 1) == .success ? buf.data : Data()
        return (finished && p.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }

    /// Reads the live value. `IOPMCopySystemPowerSettings` is private but not root-gated,
    /// so we resolve it at runtime rather than linking it — if it ever disappears we
    /// degrade to `nil` instead of failing to launch.
    nonisolated static func readSleepDisabled() -> Bool? {
        typealias CopyFn = @convention(c) () -> Unmanaged<CFDictionary>?
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let sym = dlsym(h, "IOPMCopySystemPowerSettings")
        else { return nil }
        let fn = unsafeBitCast(sym, to: CopyFn.self)
        guard let d = fn()?.takeRetainedValue() as? [String: Any] else { return nil }
        if let n = d["SleepDisabled"] as? NSNumber { return n.boolValue }
        return nil
    }

    // MARK: - Crash recovery

    /// If the marker survives from a previous run, we died while SleepDisabled was engaged.
    /// Clear it. We only act when the marker is present — the user may have set the flag
    /// themselves, and silently clearing that would be rude.
    private func recoverFromCrashIfNeeded() {
        // Brightness first, and independently of the arm marker: a previous run may have
        // died while the panel was dimmed, which leaves a screen the user cannot explain.
        if DisplayBrightness.isDimmed {
            log.notice("panel was left dimmed by a previous run — restoring brightness")
            DisplayBrightness.restore()
        }
        guard FileManager.default.fileExists(atPath: AppPaths.armMarker.path) else { return }
        log.notice("arm marker present at launch — recovering from unclean shutdown")
        if PowerManager.readSleepDisabled() == false {
            // Already clear (someone else cleared it); only the marker was left behind.
            try? FileManager.default.removeItem(at: AppPaths.armMarker)
            return
        }
        guard PowerManager.setSleepDisabledSync(false),
              PowerManager.readSleepDisabled() != true else {
            // Keep the marker so the next launch tries again, and say what is wrong.
            lastError = "A previous run left SleepDisabled set and it could not be cleared, so this Mac cannot sleep. Run: sudo pmset -a disablesleep 0"
            return
        }
        try? FileManager.default.removeItem(at: AppPaths.armMarker)
        recoveredAtLaunch = true
        lastError = "Recovered from an unclean shutdown: sleep was re-enabled."
    }

    func clearError() { lastError = nil }

    private func installSignalHandlers() {
        // DispatchSource is the safe way to do this — a raw signal handler cannot spawn
        // a subprocess. Ignore the default disposition first or the process still dies.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                emergencyTeardown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: - System state

    nonisolated static func readClamshellFlag(_ key: String) -> Bool? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        return IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    func refreshSystemState() {
        var changed = false
        // Before the lid transition below: the lid test's verdict depends on it.
        let wasDocked = docked
        docked = PowerManager.externalDisplayCount > 0
        // Undocked with the lid still shut: the bag starts now, not when the lid first
        // closed at the desk, or the cap would trip the moment the cable came out.
        if wasDocked, !docked, lidClosed { lidClosedSince = Date(); changed = true }
        if docked != wasDocked { changed = true }
        if let nowClosed = PowerManager.readClamshellFlag("AppleClamshellState"),
           nowClosed != lidClosed {
            lidClosed = nowClosed
            lidClosedSince = nowClosed ? Date() : nil
            if nowClosed {
                // The clamshell blank we suppressed. Do it ourselves, then keep
                // watching, because agent activity can light the panel again.
                blankIfLidShut()
                startDisplayWatchdog()
            } else {
                stopDisplayWatchdog()
            }
            // The test first: it may end and hand the lock back, and the lid handler's
            // preflight must then see the settled state, not the test's forced layer.
            advanceLidTest(closed: nowClosed)
            onLidChange?(nowClosed)
            changed = true
        }
        // Display only: ownership is never taken from the live value.
        let heldByOther = sleepDisabledEngaged && !sleepDisabledSetByUs
        let live = PowerManager.readSleepDisabled()
        if let live, live != sleepDisabledEngaged { sleepDisabledEngaged = live; changed = true }
        if live == false, sleepDisabledSetByUs {
            // Cleared outside Lucid while we held it. Stop claiming it, drop the marker,
            // and say so — the lid is no longer covered.
            log.notice("SleepDisabled was cleared outside Lucid")
            sleepDisabledSetByUs = false
            gSleepDisabledEngaged = false
            try? FileManager.default.removeItem(at: AppPaths.armMarker)
            lastError = "SleepDisabled was cleared outside Lucid, so the lid is not covered until the lock next re-arms."
        } else if live == false, heldByOther {
            // Another tool let go of a flag that was covering the lid for us. Set our own,
            // tracked by the marker. Once per hand-over, so a failing engage is not retried
            // every poll.
            applyLidCoverage()
        }
        if changed { onStateChange?() }
    }

    // MARK: - Privilege rule management

    /// The rule is scoped to two exact argument strings. Never widen this to `pmset *`,
    /// which would be a general root escalation.
    nonisolated static func sudoersRuleText(user: String) -> String {
        """
        # Installed by Lucid. Allows toggling clamshell sleep without a password.
        # Scoped to exactly two commands - nothing else is granted.
        \(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
        """
    }

    nonisolated static var currentUser: String { NSUserName() }

    /// The two commands the rule grants, exactly as sudo lists them.
    private nonisolated static let grantedCommands = [
        "/usr/bin/pmset -a disablesleep 1", "/usr/bin/pmset -a disablesleep 0",
    ]

    /// Asks sudo whether both commands run without a password, without running pmset.
    ///
    /// `sudo -l <cmd>` is not that question: it succeeds whenever any rule permits the
    /// command, including the stock `%admin ALL=(ALL) ALL` that still wants a password, so
    /// an admin with any unrelated NOPASSWD entry read as "installed". This lists the
    /// rules and looks for a NOPASSWD line naming each command.
    nonisolated static func isPrivilegeRuleInstalled() -> Bool {
        let r = runTool("/usr/bin/sudo", ["-n", "-l"])
        guard r.ok else { return false }
        let nopasswd = r.out.split(separator: "\n").filter { $0.contains("NOPASSWD:") }
        return grantedCommands.allSatisfy { cmd in nopasswd.contains { $0.contains(cmd) } }
    }

    /// File names Lucid owns under /etc/sudoers.d. `liddownai` is the pre-rename name; it
    /// grants the same two commands and is removed wherever the current one is.
    nonisolated static let sudoersFiles = [AppPaths.sudoersFile, "/etc/sudoers.d/liddownai"]

    /// One admin prompt, ever. The privileged shell writes the rule itself: root never
    /// reads a file the user can write, because anything running as the user could swap
    /// a staged file for `ALL=(ALL) NOPASSWD: ALL` while the password prompt was open.
    /// It is written under a dotted name, which sudo ignores, validated by visudo, and
    /// only then moved into place — a bad rule can never lock the user out of sudo.
    func installPrivilegeRule() async -> Bool {
        let user = PowerManager.currentUser
        // The name is the only variable part. macOS short names never need quoting, but
        // refuse rather than build a root shell line from something unexpected.
        guard !user.isEmpty, user.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            lastError = "Unexpected user name; install the rule by hand (Settings → Privileges)."
            return false
        }
        let lines = PowerManager.sudoersRuleText(user: user)
            .split(separator: "\n").map { "'\($0)'" }.joined(separator: " ")
        let staged = "/etc/sudoers.d/.lucid.tmp"
        let script = "umask 0337; /usr/bin/printf '%s\\n' \(lines) > \(staged)"
            + " && /usr/sbin/visudo -cf \(staged)"
            + " && /usr/sbin/chown root:wheel \(staged)"
            + " && /bin/mv -f \(staged) \(AppPaths.sudoersFile); rc=$?"
            + "; /bin/rm -f \(staged)"
            + "; [ $rc -eq 0 ] && /bin/rm -f /etc/sudoers.d/liddownai; exit $rc"
        let ok = await PowerManager.runAdmin(script)

        ruleInstalled = PowerManager.isPrivilegeRuleInstalled()
        if ok && ruleInstalled {
            lastError = nil
            // Arming while the rule was missing skipped the lid layer, and arm() will not
            // run again while already armed. Engage it now, not on the next turn.
            applyLidCoverage()
        } else {
            lastError = "Privilege rule installation was cancelled or failed."
        }
        onStateChange?()
        return ok && ruleInstalled
    }

    /// Clears a flag we set in the same root shell that deletes the rule. Deleting the rule
    /// first would take away the only password-free way to clear it, leaving a Mac that
    /// cannot sleep, across reboots. This runs as root through the one-off admin prompt,
    /// not through sudoers, so the rule itself stays limited to its two commands.
    ///
    /// The password dialog frees the main actor for as long as it is open, and the rule
    /// still works until the shell deletes it. So nothing engages meanwhile, and the shell
    /// decides by the marker when it runs, not by ownership read before the dialog.
    func removePrivilegeRule() async -> Bool {
        removingRule = true
        let marker = AppPaths.armMarker.path.replacingOccurrences(of: "'", with: "'\\''")
        let clear = "if [ -e '\(marker)' ]; then /usr/bin/pmset -a disablesleep 0 || exit 1; fi; "
        let files = PowerManager.sudoersFiles.map { "'\($0)'" }.joined(separator: " ")
        let ok = await PowerManager.runAdmin(clear + "/bin/rm -f \(files)")
        removingRule = false
        let live = PowerManager.readSleepDisabled()
        if ok, sleepDisabledSetByUs, live != true {
            sleepDisabledSetByUs = false
            gSleepDisabledEngaged = false
            try? FileManager.default.removeItem(at: AppPaths.armMarker)
        }
        sleepDisabledEngaged = live ?? sleepDisabledEngaged
        ruleInstalled = PowerManager.isPrivilegeRuleInstalled()
        if !ok {
            lastError = "Removing the privilege rule was cancelled or failed."
            applyLidCoverage()    // cancelled: engage what the open dialog held back
        } else if sleepDisabledSetByUs {
            lastError = "Could not clear SleepDisabled, so this Mac cannot sleep. Run: sudo pmset -a disablesleep 0"
        }
        onStateChange?()
        return ok
    }

    #if DEBUG_RENDER
    /// Test builds only: stands in for the password dialog.
    nonisolated(unsafe) static var adminStub: (@Sendable (String) async -> Bool)?
    #endif

    /// Set while the removal dialog is open. See `removePrivilegeRule`.
    private var removingRule = false

    /// Re-checks, and brings the lock in line if the rule appeared or went away.
    func refreshRuleInstalled() {
        let now = PowerManager.isPrivilegeRuleInstalled()
        guard now != ruleInstalled else { return }
        ruleInstalled = now
        applyLidCoverage()
    }

    /// Off the main actor: the password dialog can sit open for as long as the user likes,
    /// and blocking here froze the menu and held back guardrail and hook events meanwhile.
    private nonisolated static func runAdmin(_ shellCommand: String) async -> Bool {
        #if DEBUG_RENDER
        if let stub = adminStub { return await stub(shellCommand) }
        #endif
        let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return await Task.detached {
            runTool("/usr/bin/osascript", ["-e", script], timeout: 600).ok
        }.value
    }
}

private final class OutputBuffer: @unchecked Sendable { var data = Data() }

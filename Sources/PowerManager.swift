import AppKit
import CoreGraphics
import Foundation
import IOKit
import IOKit.pwr_mgt
import Observation
import os

private let log = Logger(subsystem: "com.lucid.app", category: "power")

/// Tracks whether the root-level SleepDisabled flag is currently engaged.
/// Global because `atexit` takes a bare C function pointer that cannot capture context,
/// and this flag has to survive into that teardown path.
nonisolated(unsafe) private var gSleepDisabledEngaged = false

/// Registered with `atexit`. Covers normal termination and uncaught-exception exits.
/// `kill -9` cannot be covered here — the arm-marker file handles that on next launch.
private func emergencyTeardown() {
    // Unconditional: if the panel was dimmed we must undo it whether or not the sleep
    // flag was engaged, because a dark screen is the more alarming thing to leave behind.
    DisplayBrightness.restore()
    guard gSleepDisabledEngaged else { return }
    _ = PowerManager.setSleepDisabledSync(false)
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
    /// True when macOS itself will not sleep on lid close (external display + AC).
    private(set) var externalClamshellMode = false
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
    private var lidTestArmedByUs = false
    /// Set only while a lid test is running, to force one layer on or off.
    private var testOverrideLidCoverage: Bool?

    var onStateChange: (() -> Void)?
    /// Fired on a lid open/close transition.
    var onLidChange: ((Bool) -> Void)?

    private var assertionID: IOPMAssertionID = 0
    private var hasAssertion = false
    /// True only while *this app* is the reason SleepDisabled is set.
    private var sleepDisabledSetByUs = false
    private var signalSources: [DispatchSourceSignal] = []
    private var clamshellTimer: Timer?

    private let prefs = Preferences.shared

    init() {
        atexit(emergencyTeardown)
        atexit(removeSocketFile)
        installSignalHandlers()
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
                let armed = self.isArmed
                self.sleepHistory.insert((Date(), armed), at: 0)
                if self.sleepHistory.count > 20 { self.sleepHistory.removeLast() }
                if armed {
                    self.lastFailedSleep = Date()
                    log.error("SLEPT WHILE ARMED — the wake lock did not hold")
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
    // survives a lid close. This drives that test end to end and gives a verdict, so the
    // This drives that test end to end and reports the observed result.

    func startLidTest(layer: LidTestLayer = .assertionOnly) {
        if layer == .sleepDisabled, !PowerManager.isPrivilegeRuleInstalled() {
            lidTest = .cancelled("The privilege rule is not installed, so this layer cannot be tested.")
            onStateChange?(); return
        }

        // Re-arm cleanly so the requested layer is the one actually in force, rather than
        // whatever an existing arm happened to set up.
        if isArmed { disarm() }
        testOverrideLidCoverage = (layer == .sleepDisabled)
        lidTestArmedByUs = true
        arm()

        if layer == .sleepDisabled, !sleepDisabledEngaged {
            lidTest = .cancelled("SleepDisabled did not engage — check the Privileges tab.")
            endLidTestArming()
            onStateChange?(); return
        }
        if layer == .assertionOnly, sleepDisabledEngaged {
            lidTest = .cancelled("SleepDisabled is still set, so this would not be a clean test of the assertion alone.")
            endLidTestArming()
            onStateChange?(); return
        }

        lidTest = lidClosed ? .lidClosed(since: Date(), layer: layer) : .waitingForClose(layer)
        onStateChange?()
    }

    private func endLidTestArming() {
        if lidTestArmedByUs { disarm(); lidTestArmedByUs = false }
        testOverrideLidCoverage = nil
    }

    func cancelLidTest() {
        endLidTestArming()
        lidTest = .idle
        onStateChange?()
    }

    private func advanceLidTest(closed: Bool) {
        switch lidTest {
        case let .waitingForClose(layer) where closed:
            lidTest = .lidClosed(since: Date(), layer: layer)
        case let .lidClosed(since, layer) where !closed:
            // Reopened. If the Mac had slept, willSleep would have recorded it while armed.
            let slept = sleepHistory.first { $0.at >= since && $0.wasArmed }
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
        engageSleepDisabled(testOverrideLidCoverage ?? prefs.lidCloseCoverage)
    }

    func disarm() {
        guard isArmed else { return }
        isArmed = false

        releaseAssertion()
        // Only ours to clear. refreshSystemState() adopts the live value for display, so
        // without this a flag the user set by hand would be wiped by our next disarm.
        if sleepDisabledSetByUs { engageSleepDisabled(false) }
        stopDisplayWatchdog()
        sleepNowIfLidShut()

        log.info("disarmed")
        onStateChange?()
    }

    /// Clearing SleepDisabled does not make the Mac sleep — clamshell sleep is decided at
    /// the moment the lid closes, and that decision was already vetoed. Without this, work
    /// that finishes with the lid down leaves the Mac awake until it is physically opened,
    /// which is the half of the promise about letting it sleep.
    private func sleepNowIfLidShut() {
        guard lidClosed else { return }
        // Not in Apple's own clamshell mode: an external display attached with the lid shut
        // means the user is deliberately using the Mac right now.
        guard !externalClamshellMode, PowerManager.activeDisplayCount == 1 else { return }
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

    /// Whether the built-in panel is currently asleep. Public CoreGraphics, no entitlement.
    nonisolated static var displayIsAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Number of displays macOS considers active. More than one means an external screen
    /// is attached, where blanking would take the user's monitor down with it.
    nonisolated static var activeDisplayCount: Int {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return 1 }
        return Int(count)
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
        // Not gated on SleepDisabled: whichever layer vetoes the clamshell sleep also
        // vetoes the blank that is one of its steps, so the panel stays lit either way.
        guard isArmed, lidClosed else { return }
        guard PowerManager.activeDisplayCount == 1 else { return }
        guard !PowerManager.displayIsAsleep else { return }
        log.info("lid shut with the lock held — blanking the panel")
        displaySleepNow()
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
                } else {
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

    private func engageSleepDisabled(_ on: Bool) {
        guard on != sleepDisabledEngaged else { return }

        if on {
            // Write the marker BEFORE engaging, so a crash in between still self-heals.
            try? Data().write(to: AppPaths.armMarker)
        }

        guard PowerManager.setSleepDisabledSync(on) else {
            if on {
                try? FileManager.default.removeItem(at: AppPaths.armMarker)
                lastError = "Could not set SleepDisabled — the privilege rule may not be installed."
            }
            return
        }

        sleepDisabledEngaged = on
        sleepDisabledSetByUs = on
        gSleepDisabledEngaged = on
        if !on { try? FileManager.default.removeItem(at: AppPaths.armMarker) }

        // Read back rather than trusting the exit code.
        if PowerManager.readSleepDisabled() != on {
            lastError = "SleepDisabled did not take effect"
            log.error("SleepDisabled readback mismatch (wanted \(on))")
        } else {
            lastError = nil
        }
    }

    /// Synchronous so it is usable from `atexit`. Returns true on a clean exit status.
    nonisolated static func setSleepDisabledSync(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -n: never prompt. With the scoped NOPASSWD rule this succeeds silently;
        // without it this fails fast instead of hanging on a password prompt.
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
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
        _ = PowerManager.setSleepDisabledSync(false)
        try? FileManager.default.removeItem(at: AppPaths.armMarker)
        lastError = "Recovered from an unclean shutdown: sleep was re-enabled."
    }

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

    func refreshSystemState() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("IOPMrootDomain"))
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            func flag(_ k: String) -> Bool? {
                IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Bool
            }
            let nowClosed = flag("AppleClamshellState") ?? false
            if nowClosed != lidClosed {
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
                onLidChange?(nowClosed)
                advanceLidTest(closed: nowClosed)
            }
            // NOTE: this is NOT a success signal for our own mechanism. It stays true even
            // when SleepDisabled is engaged, because SleepDisabled vetoes later, down in
            // privateSleepSystem. It only tells us whether macOS itself would sleep on lid
            // close — i.e. whether Apple's sanctioned clamshell mode is active.
            externalClamshellMode = !(flag("AppleClamshellCausesSleep") ?? true)
        }
        sleepDisabledEngaged = PowerManager.readSleepDisabled() ?? sleepDisabledEngaged
        gSleepDisabledEngaged = sleepDisabledEngaged
    }

    // MARK: - Privilege rule management

    /// The rule is scoped to two exact argument strings. Never widen this to `pmset *`,
    /// which would be a general root escalation.
    nonisolated static func sudoersRuleText(user: String) -> String {
        """
        # Installed by Lucid. Allows toggling clamshell sleep without a password.
        # Scoped to exactly two commands — nothing else is granted.
        \(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
        """
    }

    nonisolated static var currentUser: String { NSUserName() }

    /// Asks sudo whether the rule is in place, without running pmset.
    nonisolated static func isPrivilegeRuleInstalled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    static var manualInstallCommand: String {
        "sudo sh -c 'echo \"\(sudoersRuleText(user: currentUser).split(separator: "\n").last ?? "")\" "
        + "> \(AppPaths.sudoersFile) && chmod 0440 \(AppPaths.sudoersFile) "
        + "&& visudo -cf \(AppPaths.sudoersFile)'"
    }

    /// One admin prompt, ever. Stages the file as the user, then has the privileged shell
    /// install and validate it — reverting if visudo rejects it, so a bad rule can never
    /// lock the user out of sudo.
    @discardableResult
    func installPrivilegeRule() -> Bool {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lucid.sudoers")
        do {
            try PowerManager.sudoersRuleText(user: PowerManager.currentUser)
                .write(to: tmp, atomically: true, encoding: .utf8)
        } catch {
            lastError = "Could not stage the privilege rule: \(error.localizedDescription)"
            return false
        }

        let inner = "/usr/bin/install -m 0440 -o root -g wheel '\(tmp.path)' "
            + "'\(AppPaths.sudoersFile)' && /usr/sbin/visudo -cf '\(AppPaths.sudoersFile)' "
            + "|| /bin/rm -f '\(AppPaths.sudoersFile)'"
        let ok = runOSAScriptAsAdmin(inner)
        try? FileManager.default.removeItem(at: tmp)

        if !ok { lastError = "Privilege rule installation was cancelled or failed." }
        onStateChange?()
        return ok
    }

    @discardableResult
    func removePrivilegeRule() -> Bool {
        let ok = runOSAScriptAsAdmin("/bin/rm -f '\(AppPaths.sudoersFile)'")
        onStateChange?()
        return ok
    }

    private func runOSAScriptAsAdmin(_ shellCommand: String) -> Bool {
        let escaped = shellCommand.replacingOccurrences(of: "\\", with: "\\\\")
                                  .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}

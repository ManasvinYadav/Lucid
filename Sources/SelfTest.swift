import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// `Lucid --selftest` — prints every signal the app depends on and asserts the ones
/// that must hold. This is the harness for manual verification; run it before debugging
/// anything else.
enum SelfTest {

    static func run() {
        var failures: [String] = []
        func check(_ label: String, _ value: String, ok: Bool = true, note: String = "") {
            let mark = ok ? "ok  " : "FAIL"
            print("  [\(mark)] \(label.padded(28)) \(value)\(note.isEmpty ? "" : "   \(note)")")
            if !ok { failures.append(label) }
        }

        print("Lucid self-test\n")

        // --- Power source -------------------------------------------------------
        print("Power")
        var pct = -1, ac = false
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue()
                        as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
                let mx  = d[kIOPSMaxCapacityKey] as? Int ?? 100
                pct = mx > 0 ? cur * 100 / mx : 0
                ac = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            }
        }
        check("battery", pct >= 0 ? "\(pct)%" : "no internal battery", ok: true)
        check("power source", ac ? "AC" : "battery")
        check("low power mode", "\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        check("thermal state", ProcessInfo.processInfo.thermalState.label)

        // --- Clamshell ----------------------------------------------------------
        print("\nClamshell")
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("IOPMrootDomain"))
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            func flag(_ k: String) -> Bool? {
                IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Bool
            }
            check("lid closed", "\(flag("AppleClamshellState") ?? false)")
            check("clamshell causes sleep", "\(flag("AppleClamshellCausesSleep") ?? true)",
                  note: "(informational only)")
        } else {
            check("IOPMrootDomain", "unavailable", ok: false)
        }

        // --- Assertion ----------------------------------------------------------
        print("\nAssertions")
        var aid: IOPMAssertionID = 0
        let rc = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Lucid selftest" as CFString, &aid)
        check("PreventUserIdleSystemSleep", rc == kIOReturnSuccess ? "created" : "rc=\(rc)",
              ok: rc == kIOReturnSuccess)
        if rc == kIOReturnSuccess { IOPMAssertionRelease(aid) }

        // --- Privileged layer ---------------------------------------------------
        print("\nLid-close support")
        let installed = PowerManager.isPrivilegeRuleInstalled()
        check("privilege rule", installed ? "installed" : "NOT installed", ok: installed,
              note: installed ? "" : "-> Settings > Privileges")
        let sd = PowerManager.readSleepDisabled()
        check("SleepDisabled", sd.map { $0 ? "1 (engaged)" : "0" } ?? "unreadable",
              ok: sd != nil)
        check("launch at login", LoginItem.isEnabled ? "enabled" : "disabled")
        // The marker only means an unclean shutdown if nobody is home. A live, armed
        // app is supposed to have one.
        let marker = FileManager.default.fileExists(atPath: AppPaths.armMarker.path)
        let live = probeSocket()
        check("arm marker",
              !marker ? "clean"
                      : live ? "present (app is running and armed)"
                             : "PRESENT with no listener (unclean shutdown)",
              ok: !marker || live)

        // --- Display ------------------------------------------------------------
        // Closing the lid normally blanks the panel as part of the clamshell sleep
        // sequence. SleepDisabled vetoes that sequence, so the panel can stay lit inside
        // a shut lid unless the app blanks it explicitly.
        print("\nDisplay")
        check("panel asleep", PowerManager.displayIsAsleep ? "yes" : "no")
        let displays = PowerManager.activeDisplayCount
        check("active displays", "\(displays)",
              note: displays > 1 ? "external attached — blanking is left to macOS" : "")
        let holders = PowerManager.displayHolders()
        check("holding the panel lit",
              holders.isEmpty ? "nothing"
                              : holders.map { "\($0.process)" }.joined(separator: ", "))
        for h in holders {
            print("           \(h.process.padded(20)) \(h.reason)")
        }

        // --- IPC ---------------------------------------------------------------
        print("\nHook listener")
        check("socket path", AppPaths.socket.path)
        // File existence proves nothing — a stale socket outlives a crashed instance.
        // Actually connect to find out whether anything is listening.
        check("listener", probeSocket() ? "accepting connections" : "not running")

        // --- Process fallback ---------------------------------------------------
        print("\nProcess scan")
        let procs = AgentLifecycleManager.liveProcesses()
        check("processes visible", "\(procs.count)", ok: procs.count > 50)
        let mine = procs.filter { $0.uid == getuid() }
        check("own-uid processes", "\(mine.count)", note: "(rusage is EPERM beyond these)")

        let needles = Preferences.shared.processWhitelist.map { $0.lowercased() }
        var matched: [String] = []
        for p in mine {
            guard let path = AgentLifecycleManager.executablePath(p.pid)?.lowercased(),
                  needles.contains(where: { path.contains($0) }) else { continue }
            matched.append("\(p.pid) \((path as NSString).lastPathComponent)")
        }
        check("whitelist matches", matched.isEmpty ? "none" : matched.joined(separator: ", "))

        // --- Logic that can't be exercised from outside ------------------------
        //
        // The duration cap only fires with the lid physically shut, and the history
        // rollup only after a session ends. Both are branchy enough to be worth a
        // check that doesn't need a lid or an agent.
        print("")
        print("Logic")
        MainActor.assumeIsolated {
            let prefs = Preferences.shared
            let savedEnabled = prefs.maxLidClosedEnabled
            let savedMinutes = prefs.maxLidClosedMinutes
            defer {
                prefs.maxLidClosedEnabled = savedEnabled
                prefs.maxLidClosedMinutes = savedMinutes
            }

            let g = PowerGuardrailManager()
            prefs.maxLidClosedEnabled = true
            prefs.maxLidClosedMinutes = 60

            @MainActor func capFired(_ g: PowerGuardrailManager) -> Bool {
                if case .lidClosedTooLong = g.yieldReason { return true }
                return false
            }

            g.lidClosedSince = { Date().addingTimeInterval(-30 * 60) }
            g.tick()
            check("cap: 30m under a 60m cap", g.yieldReason?.summary ?? "no yield",
                  ok: !capFired(g))

            g.lidClosedSince = { Date().addingTimeInterval(-90 * 60) }
            g.tick()
            check("cap: 90m over a 60m cap", g.yieldReason?.summary ?? "no yield",
                  ok: capFired(g))

            prefs.maxLidClosedEnabled = false
            g.tick()
            check("cap: disabled honours off", g.yieldReason?.summary ?? "no yield",
                  ok: !capFired(g))
            check("cap: no countdown when off", g.lidCapRemaining.map(String.init) ?? "nil",
                  ok: g.lidCapRemaining == nil)

            // Countdown and the single warning shot before the cap trips.
            prefs.maxLidClosedEnabled = true
            prefs.maxLidClosedMinutes = 60
            var warnings: [Int] = []
            g.onLidCapWarning = { warnings.append($0) }

            g.lidClosedSince = { Date().addingTimeInterval(-20 * 60) }
            g.tick()
            check("cap: 40 min left at 20 min in", "\(g.lidCapRemaining ?? -1)",
                  ok: g.lidCapRemaining == 40)
            check("cap: no warning that early", "\(warnings.count) warning(s)",
                  ok: warnings.isEmpty)

            g.lidClosedSince = { Date().addingTimeInterval(-55 * 60) }
            g.tick()
            check("cap: 5 min left at 55 min in", "\(g.lidCapRemaining ?? -1)",
                  ok: g.lidCapRemaining == 5)
            check("cap: warned once", "\(warnings)", ok: warnings == [5])

            g.tick()
            check("cap: does not re-warn", "\(warnings.count) warning(s)",
                  ok: warnings.count == 1)

            // Opening the lid must clear the countdown and re-arm the warning.
            g.lidClosedSince = { nil }
            g.tick()
            check("cap: cleared on lid open", g.lidCapRemaining.map(String.init) ?? "nil",
                  ok: g.lidCapRemaining == nil)
            g.lidClosedSince = { Date().addingTimeInterval(-58 * 60) }
            g.tick()
            check("cap: warns again after a new lid close", "\(warnings)",
                  ok: warnings.count == 2)
            g.onLidCapWarning = nil

            // A guardrail that stays tripped must not keep announcing itself. Its
            // associated value moves every minute, so comparing the whole case made each
            // tick look like a brand new trip — one chime and one banner per minute, for
            // as long as the condition lasted.
            var trips: [String] = []
            g.onYieldChange = { trips.append($0?.kind ?? "clear") }

            g.lidClosedSince = { Date().addingTimeInterval(-70 * 60) }
            g.tick()
            check("cap: announces the trip once", "\(trips)",
                  ok: trips.filter { $0 == "lidcap" }.count == 1)

            g.lidClosedSince = { Date().addingTimeInterval(-71 * 60) }
            g.tick()
            check("cap: the live number still updates", g.yieldReason?.summary ?? "no yield",
                  ok: (g.yieldReason?.summary ?? "").contains("71 min"))
            check("cap: does not re-announce every minute",
                  "\(trips.filter { $0 == "lidcap" }.count) announcement(s)",
                  ok: trips.filter { $0 == "lidcap" }.count == 1)
            g.onYieldChange = nil

            // Away report: it must stay quiet for short or empty lid closes, and speak up
            // for the cases that matter.
            let quick = AwayReport(closedFor: 120, finished: [], stillWorking: [],
                                   guardrailTripped: nil, batterySpent: nil,
                                   sleptWhileArmed: false, panelLitSeconds: 0)
            check("away: silent for a 2 min lid close", "\(quick.isWorthShowing)",
                  ok: !quick.isWorthShowing)

            let empty = AwayReport(closedFor: 3600, finished: [], stillWorking: [],
                                   guardrailTripped: nil, batterySpent: nil,
                                   sleptWhileArmed: false, panelLitSeconds: 0)
            check("away: silent when nothing happened", "\(empty.isWorthShowing)",
                  ok: !empty.isWorthShowing)

            let rec = SessionRecord(agent: "Claude Code", started: Date().addingTimeInterval(-600),
                                    ended: Date(), reason: "Turn complete",
                                    batteryStart: 60, batteryEnd: 52, wasOnAC: false)
            check("away: battery spend computed", "\(rec.batterySpent ?? -1)",
                  ok: rec.batterySpent == 8)
            let onAC = SessionRecord(agent: "x", started: Date().addingTimeInterval(-600),
                                     ended: Date(), reason: "r",
                                     batteryStart: 60, batteryEnd: 52, wasOnAC: true)
            check("away: no spend attributed on AC", "\(onAC.batterySpent.map(String.init) ?? "nil")",
                  ok: onAC.batterySpent == nil)

            let done = AwayReport(closedFor: 3600, finished: [rec], stillWorking: [],
                                  guardrailTripped: nil, batterySpent: 8,
                                  sleptWhileArmed: false, panelLitSeconds: 0)
            check("away: reports a finished session", done.headline,
                  ok: done.isWorthShowing && done.headline.contains("1 session finished"))

            let failed = AwayReport(closedFor: 3600, finished: [], stillWorking: [],
                                    guardrailTripped: nil, batterySpent: nil,
                                    sleptWhileArmed: true, panelLitSeconds: 0)
            check("away: a sleep while armed outranks everything", failed.headline,
                  ok: failed.isWorthShowing && failed.headline.contains("slept"))

            let h = SessionHistory.shared
            let before = h.awakeToday
            check("history: today's awake time", before.compactDuration)
            check("history: records on disk", "\(h.records.count)")
        }

        print("")
        if failures.isEmpty {
            print("All checks passed.")
        } else {
            print("\(failures.count) check(s) failed: \(failures.joined(separator: ", "))")
        }
    }
}

/// Returns true only if something is actually accepting on the hook socket.
private func probeSocket() -> Bool {
    let path = AppPaths.socket.path
    guard FileManager.default.fileExists(atPath: path) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: cap) { _ = strlcpy($0, path, cap) }
    }
    return withUnsafePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
}

private extension String {
    func padded(_ n: Int) -> String {
        count >= n ? self : self + String(repeating: " ", count: n - count)
    }
}

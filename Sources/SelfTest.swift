import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// `Lucid --selftest` — prints every signal the app depends on and asserts the ones
/// that must hold. This is the harness for manual verification; run it before debugging
/// anything else.
enum SelfTest {

    /// True when every asserted check passed; `--selftest` exits non-zero otherwise.
    static func run() -> Bool {
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
        // Only required when lid-close coverage is wanted; without it the rule is unused.
        let installed = PowerManager.isPrivilegeRuleInstalled()
        let wanted = Preferences.shared.lidCloseCoverage
        check("privilege rule",
              installed ? "installed" : wanted ? "NOT installed" : "not installed (lid-close coverage off)",
              ok: installed || !wanted,
              note: installed || !wanted ? "" : "-> Settings > Privileges")
        // A flag the user set is theirs, so it is reported rather than failed. Lucid's own
        // leftovers are caught by the arm-marker check below.
        let live = probeSocket()
        let sd = PowerManager.readSleepDisabled()
        check("SleepDisabled", sd.map { $0 ? "1 (engaged)" : "0" } ?? "unreadable",
              ok: sd != nil,
              note: sd == true && !live
                  ? "-> Lucid is not running, so this was set outside it. If not by you: sudo pmset -a disablesleep 0"
                  : "")
        check("launch at login", LoginItem.isEnabled ? "enabled" : "disabled")
        // The marker only means an unclean shutdown if nobody is home. A live, armed
        // app is supposed to have one.
        let marker = FileManager.default.fileExists(atPath: AppPaths.armMarker.path)
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
        check("built-in panel", PowerManager.builtinDisplay.map { "display \($0)" } ?? "none online")
        check("panel asleep", PowerManager.displayIsAsleep ? "yes" : "no")
        let externals = PowerManager.externalDisplayCount
        check("external displays", "\(externals)",
              note: externals > 0 ? "attached — blanking is left to macOS" : "")
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

        // The same matcher the scanner uses, so this shows what it would track.
        let needles = Preferences.shared.processWhitelist.map { $0.lowercased() }.filter { !$0.isEmpty }
        var matched: [String] = []
        for p in mine {
            guard let n = AgentLifecycleManager.matchedNeedle(p.pid, needles) else { continue }
            let name = (AgentLifecycleManager.executablePath(p.pid) as NSString?)?.lastPathComponent ?? "?"
            matched.append("\(p.pid) \(name) (\(n))")
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
            check("away: reports a finished turn", done.headline,
                  ok: done.isWorthShowing && done.headline.contains("1 agent turn finished"))

            let failed = AwayReport(closedFor: 3600, finished: [], stillWorking: [],
                                    guardrailTripped: nil, batterySpent: nil,
                                    sleptWhileArmed: true, panelLitSeconds: 0)
            check("away: a sleep while armed outranks everything", failed.headline,
                  ok: failed.isWorthShowing && failed.headline.contains("slept"))

            // History rollups: overlapping sessions are one stretch of time, and a
            // session that began before the cut-off only counts from it.
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            func r(_ a: Double, _ b: Double, _ bs: Int? = nil, _ be: Int? = nil) -> SessionRecord {
                SessionRecord(agent: "a", started: t0.addingTimeInterval(a * 60),
                              ended: t0.addingTimeInterval(b * 60), reason: "r",
                              batteryStart: bs, batteryEnd: be, wasOnAC: bs == nil ? nil : false)
            }
            let overlap = [r(0, 10), r(5, 20), r(30, 40)]
            let worked = SessionHistory.workingTime(overlap, since: .distantPast) / 60
            check("history: overlaps merged", "\(Int(worked)) min", ok: worked == 30)
            let clipped = SessionHistory.workingTime(overlap, since: t0.addingTimeInterval(15 * 60)) / 60
            check("history: clipped to the cut-off", "\(Int(clipped)) min", ok: clipped == 15)
            let drain = SessionHistory.batterySpent([r(0, 10, 60, 52), r(5, 20, 58, 50)],
                                                    since: .distantPast)
            check("history: battery counted once per span", "\(drain?.points ?? -1) points",
                  ok: drain?.points == 10)

            // Whitelist migration, on a throwaway defaults domain.
            let suite = "com.lucid.selftest"
            if let d = UserDefaults(suiteName: suite) {
                d.set(["aider", "gemini", "mine"], forKey: "processWhitelist")
                let v0 = Preferences.migratedWhitelist(d)
                check("whitelist: v0 gains defaults, loses gemini", v0.joined(separator: ","),
                      ok: v0.contains("ollama") && !v0.contains("gemini") && v0.contains("mine"))
                d.set(["aider", "copilot"], forKey: "processWhitelist")
                d.set(1, forKey: "whitelistVersion")
                let v1 = Preferences.migratedWhitelist(d)
                check("whitelist: v1 keeps removals, loses copilot", v1.joined(separator: ","),
                      ok: v1 == ["aider"])
                let v2 = Preferences.migratedWhitelist(d)
                check("whitelist: runs once", v2.joined(separator: ","), ok: v2 == ["aider"])
                // 0.10 stored version 1 with its own defaults; codeium matched by path then.
                d.set(["cline", "codeium", "ollama"], forKey: "processWhitelist")
                d.set(1, forKey: "whitelistVersion")
                let v10 = Preferences.migratedWhitelist(d)
                check("whitelist: 0.10's codeium becomes .codeium/", v10.joined(separator: ","),
                      ok: v10 == ["cline", ".codeium/", "ollama"])
                d.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: FileManager.default
                    .homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Preferences/\(suite).plist"))
            }

            check("history: records on disk", "\(SessionHistory.shared.records.count)")
        }

        print("")
        if failures.isEmpty {
            print("All checks passed.")
        } else {
            print("\(failures.count) check(s) failed: \(failures.joined(separator: ", "))")
        }
        return failures.isEmpty
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

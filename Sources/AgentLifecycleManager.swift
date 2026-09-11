import Foundation
import Darwin
import Observation
import os

private let log = Logger(subsystem: "com.lucid.app", category: "lifecycle")

// MARK: - Wire format

enum AgentStatus: String, Codable {
    case working, idle, ended
}

/// The JSON contract hooks speak. One object per line.
struct AgentEvent: Codable {
    let agent: String
    let session_id: String
    let status: AgentStatus
    /// Optional human-readable detail, e.g. "Tool Running" or "Waiting for prompt".
    let detail: String?
    /// The agent's own pid. When present the app watches it, so a killed agent drops its
    /// session immediately rather than lingering until the stale-session timeout.
    let pid: pid_t?
}

enum SessionSource: String {
    case hook, process

    var badge: String {
        switch self {
        case .hook:    return "Hook"
        case .process: return "Process"
        }
    }
}

struct AgentSession: Identifiable {
    let key: String
    var agent: String
    var sessionID: String
    var status: AgentStatus
    var detail: String?
    var lastSeen: Date
    var startedWorkingAt: Date?
    /// Battery percentage and power source when this session began working.
    var batteryAtStart: Int?
    var startedOnAC: Bool?
    var source: SessionSource
    var pid: pid_t?

    var id: String { key }
    var isWorking: Bool { status == .working }

    var displayName: String {
        switch agent {
        case "claude-code": return "Claude Code"
        case "codex":       return "Codex"
        case "opencode":    return "opencode"
        case "gemini":      return "Gemini"
        case "copilot":     return "Copilot"
        default:            return agent.capitalized
        }
    }

    var statusLine: String {
        if source == .process { return "Active Process" }
        switch status {
        case .working: return "Working (\(detail ?? "running"))"
        case .idle:    return "Idle (\(detail ?? "waiting for prompt"))"
        case .ended:   return "Ended"
        }
    }
}

// MARK: - Manager

/// Decides whether an agent is *actually working* rather than merely running.
///
/// Primary signal is a local hook server: agents push `working`/`idle` transitions over a
/// Unix domain socket. That is the only way to tell "generating" from "sat at a prompt",
/// which no amount of CPU or GPU sampling can do.
///
/// Secondary signal is process activity, for GUI tools with no hook interface. It is
/// always badged separately in the UI so an inferred state is never mistaken for a
/// reported one.
@Observable
@MainActor
final class AgentLifecycleManager {

    private(set) var sessions: [AgentSession] = []

    /// Supplied by the app so finished sessions can record what they cost.
    var batteryReader: () -> (pct: Int, onAC: Bool) = { (100, true) }
    /// Seconds left on the grace countdown, or nil when not counting down.
    private(set) var graceRemaining: Int?
    private(set) var listenerError: String?
    private(set) var isListening = false

    /// Fires with the desired lock state whenever it changes.
    var onShouldArmChange: ((Bool) -> Void)?
    /// Fires on any session-list change, including ones that do not flip the arm decision.
    var onSessionsChanged: (() -> Void)?

    private var registry: [String: AgentSession] = [:]
    private var shouldArm = false
    private var graceTask: Task<Void, Never>?
    private var reaper: Timer?
    private var processScanTimer: Timer?
    private var listenFD: Int32 = -1
    private var lastCPUSample: [pid_t: (ns: UInt64, at: UInt64)] = [:]
    /// kqueue watchers keyed by session, so a dead agent is noticed the moment it exits.
    private var exitWatchers: [String: DispatchSourceProcess] = [:]

    private let prefs = Preferences.shared

    init() {
        startListener()

        // Reap sessions whose agent died without sending `idle`. Without this, one
        // kill -9'd agent would pin the Mac awake forever.
        reaper = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reapExpired() }
        }
        processScanTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanProcesses() }
        }
        scanProcesses()
    }

    // MARK: - Event handling

    /// The registry key for a session. Every path that touches the registry must build it
    /// here — a second copy of this expression is what let a re-adopted session sit beside
    /// the live one it was supposed to be, permanently "working" and never updated again.
    nonisolated static func key(agent: String, session: String) -> String {
        "\(agent)#\(session)"
    }

    func handle(_ event: AgentEvent) {
        let key = Self.key(agent: event.agent, session: event.session_id)

        if event.status == .ended {
            exitWatchers[key]?.cancel(); exitWatchers[key] = nil
            finish(key: key, reason: "session ended")
            log.debug("session ended: \(key, privacy: .public)")
            return
        } else if var existing = registry[key] {
            if existing.status != .working && event.status == .working {
                existing.startedWorkingAt = Date()
                let b = batteryReader()
                existing.batteryAtStart = b.pct
                existing.startedOnAC = b.onAC
            } else if existing.status == .working && event.status != .working {
                // Close the burst here rather than waiting for the session to end. An
                // agent CLI stays open across many turns, so recording only at exit threw
                // away every turn but the last — and the away report is built from these.
                recordWork(existing, reason: "turn complete")
                existing.startedWorkingAt = nil
            }
            existing.status = event.status
            existing.lastSeen = Date()
            if let d = event.detail { existing.detail = d }
            if let p = event.pid { existing.pid = p }
            registry[key] = existing
        } else {
            registry[key] = AgentSession(
                key: key, agent: event.agent, sessionID: event.session_id,
                status: event.status, detail: event.detail,
                lastSeen: Date(),
                startedWorkingAt: event.status == .working ? Date() : nil,
                batteryAtStart: event.status == .working ? batteryReader().pct : nil,
                startedOnAC: event.status == .working ? batteryReader().onAC : nil,
                source: .hook, pid: event.pid)
        }

        if let p = event.pid, event.status != .ended { watchForExit(key: key, pid: p) }
        publish()
    }

    /// Watch the agent's pid with kqueue NOTE_EXIT. This is push, not poll, and works on
    /// any pid without special permission. Without it, an agent killed mid-turn would keep
    /// the Mac awake for the whole stale-session timeout.
    private func watchForExit(key: String, pid: pid_t) {
        guard exitWatchers[key] == nil else { return }
        guard kill(pid, 0) == 0 || errno == EPERM else { return }   // pid must exist

        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                log.notice("agent pid \(pid) exited — reaping \(key, privacy: .public)")
                self.finish(key: key, reason: "agent exited")
                self.exitWatchers[key]?.cancel()
                self.exitWatchers[key] = nil
            }
        }
        src.resume()
        exitWatchers[key] = src
    }

    /// Write one stretch of work to history. No-op unless the session was actually
    /// working, and `SessionHistory` drops anything shorter than a couple of seconds.
    private func recordWork(_ s: AgentSession, reason: String) {
        guard let started = s.startedWorkingAt else { return }
        let now = batteryReader()
        SessionHistory.shared.record(
            agent: s.displayName, started: started, ended: Date(), reason: reason,
            batteryStart: s.batteryAtStart, batteryEnd: now.pct,
            // Only "on battery" if it never touched AC at either end; a session that was
            // plugged in for part of it cannot be attributed cleanly.
            wasOnAC: (s.startedOnAC ?? true) || now.onAC)
    }

    /// Remove a session and record whatever work was still open on it.
    private func finish(key: String, reason: String) {
        guard let s = registry.removeValue(forKey: key) else { return }
        recordWork(s, reason: reason)
        publish()
    }

    /// A session that has not checked in within the TTL is presumed dead.
    /// Releases sessions that have gone silent — but only once the process behind them is
    /// actually gone.
    ///
    /// Heartbeats alone are not enough. PreToolUse fires before a tool runs and PostToolUse
    /// after it, so a single long command — a test suite, a build — emits nothing for its
    /// whole duration. Reaping on silence alone would put the Mac to sleep in the middle of
    /// exactly the work this app exists to protect. Silence is therefore only a reason to
    /// look at the process, never a verdict on its own.
    private func reapExpired() {
        let cutoff = Date().addingTimeInterval(-Double(prefs.sessionTTL))
        var reaped: [String] = []
        var alive: [String] = []

        for (k, s) in registry where s.source == .hook && s.isWorking && s.lastSeen < cutoff {
            if let pid = s.pid, Self.processIsAlive(pid) {
                // Still running. Refresh so the next window is measured from now, and say
                // in the UI that this is inferred from the process, not reported by it.
                registry[k]?.lastSeen = Date()
                registry[k]?.detail = "Running (no heartbeat — process alive)"
                alive.append(k)
            } else {
                registry[k]?.status = .idle
                registry[k]?.detail = s.pid == nil
                    ? "stale — no heartbeat"
                    : "stale — agent process gone"
                reaped.append(k)
            }
        }

        if !alive.isEmpty {
            log.info("kept \(alive.count) silent but live session(s): \(alive.joined(separator: ", "), privacy: .public)")
        }
        if !reaped.isEmpty {
            log.notice("reaped \(reaped.count) stale session(s): \(reaped.joined(separator: ", "), privacy: .public)")
        }
        if !alive.isEmpty || !reaped.isEmpty { publish() }
    }

    /// True if the pid still names a running process. EPERM means it exists but belongs to
    /// another user, which still counts as alive.
    nonisolated static func processIsAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Re-adopt sessions that outlived a crash.
    ///
    /// The registry deliberately starts empty — persisting "working" blind would let one
    /// bad shutdown pin the Mac awake forever. Re-adoption is safe because it is not
    /// belief, it is a check: only a session whose recorded pid is still a running process
    /// comes back, and it comes back labelled as recovered.
    func readoptSurvivingSessions() {
        guard let data = try? Data(contentsOf: AppPaths.status),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["sessions"] as? [[String: Any]]
        else { return }

        var adopted = 0
        for row in rows {
            guard let agent = row["agent"] as? String,
                  let sid = row["session"] as? String,
                  (row["status"] as? String) == AgentStatus.working.rawValue,
                  let rawPid = row["pid"] as? Int32,
                  Self.processIsAlive(rawPid)
            else { continue }

            let key = Self.key(agent: agent, session: sid)
            guard registry[key] == nil else { continue }
            registry[key] = AgentSession(
                key: key, agent: agent, sessionID: sid,
                status: .working, detail: "Recovered after restart",
                lastSeen: Date(), startedWorkingAt: Date(),
                batteryAtStart: batteryReader().pct, startedOnAC: batteryReader().onAC,
                source: .hook, pid: rawPid)
            watchForExit(key: key, pid: rawPid)
            adopted += 1
        }
        if adopted > 0 {
            log.notice("re-adopted \(adopted) session(s) whose processes survived a restart")
            publish()
        }
    }

    // MARK: - Arming decision

    private func publish() {
        sessions = registry.values.sorted {
            if $0.isWorking != $1.isWorking { return $0.isWorking }
            return $0.displayName < $1.displayName
        }

        let anyWorking = registry.values.contains { $0.isWorking }

        if anyWorking {
            graceTask?.cancel()
            graceTask = nil
            graceRemaining = nil
            if !shouldArm {
                shouldArm = true
                onShouldArmChange?(true)
            }
        } else if shouldArm && graceTask == nil {
            startGraceCountdown()
        }

        // Last, so observers see the arming decision and the countdown together with
        // the session list rather than one step behind it.
        onSessionsChanged?()
    }

    /// Hold the lock briefly after the last session goes idle, so a quick follow-up
    /// prompt does not thrash the assertion.
    private func startGraceCountdown() {
        let total = max(0, prefs.gracePeriod)
        graceRemaining = total
        graceTask = Task { @MainActor [weak self] in
            var left = total
            while left > 0 {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                left -= 1
                self?.graceRemaining = left
                self?.onSessionsChanged?()
            }
            guard let self, !Task.isCancelled else { return }
            self.graceRemaining = nil
            self.graceTask = nil
            self.shouldArm = false
            self.onShouldArmChange?(false)
        }
    }

    func reset() {
        registry.removeAll()
        graceTask?.cancel()
        graceTask = nil
        graceRemaining = nil
        shouldArm = false
        publish()
    }

    // MARK: - Socket listener

    /// A Unix domain socket, not a loopback TCP port. A listener on 127.0.0.1 is reachable
    /// by every process and every user on the machine — and by any web page that can make
    /// the browser hit localhost, which would let a random site pin the Mac awake.
    /// Filesystem permissions on ~/.lucid (0700) give real access control for free.
    private func startListener() {
        let path = AppPaths.socket.path
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            listenerError = "socket() failed: \(String(cString: strerror(errno)))"
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < pathCapacity else {
            listenerError = "socket path too long"
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dst in
                _ = strlcpy(dst, path, pathCapacity)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            listenerError = "bind() failed: \(String(cString: strerror(errno)))"
            close(fd)
            return
        }

        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            listenerError = "listen() failed: \(String(cString: strerror(errno)))"
            close(fd)
            return
        }

        listenFD = fd
        isListening = true
        log.info("listening on \(path, privacy: .public)")

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop(fd)
        }
    }

    private nonisolated func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // listener closed
            }
            handleClient(client)
        }
    }

    /// One-shot line protocol: read complete newline-terminated JSON objects, then close.
    ///
    /// The close is what makes `nc -U` work — nc waits for the server to hang up, while a
    /// server that waited for EOF from nc would deadlock against it. A read timeout bounds
    /// how long a stalled client can hold this thread, since accepts are serialised here.
    private nonisolated func handleClient(_ client: Int32) {
        defer { close(client) }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var delivered = 0

        while true {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            pending.append(contentsOf: buf[0..<n])

            // Process every complete line we have so far.
            while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<nl]
                pending = pending[pending.index(after: nl)...]
                if !line.isEmpty && deliver(Data(line)) { delivered += 1 }
            }

            if delivered > 0 { break }              // one-shot: hook sent its event, done
            if pending.count > 64 * 1024 { break }  // don't let a bad client grow us
        }

        // Tolerate a final line with no trailing newline.
        if delivered == 0 && !pending.isEmpty { _ = deliver(Data(pending)) }
    }

    private nonisolated func deliver(_ raw: Data) -> Bool {
        guard let event = try? JSONDecoder().decode(AgentEvent.self, from: raw) else {
            log.debug("dropped malformed payload (\(raw.count) bytes)")
            return false
        }
        Task { @MainActor [weak self] in self?.handle(event) }
        return true
    }

    // MARK: - Process fallback (Cursor, Cline, and other hookless GUI tools)

    /// Discovery via one sysctl call. `proc_listallpids` is avoided deliberately: it can
    /// silently return a partial list to a non-root caller, with no truncation indicator.
    private func scanProcesses() {
        guard prefs.processFallbackEnabled else {
            if registry.contains(where: { $0.value.source == .process }) {
                registry = registry.filter { $0.value.source != .process }
                publish()
            }
            return
        }

        let needles = prefs.processWhitelist.map { $0.lowercased() }
        guard !needles.isEmpty else { return }

        let me = getuid()
        var seen = Set<String>()
        var changed = false

        for proc in Self.liveProcesses() {
            // rusage is EPERM across uid boundaries, so only consider our own processes.
            guard proc.uid == me else { continue }
            guard let path = Self.executablePath(proc.pid)?.lowercased() else { continue }
            guard let needle = needles.first(where: { path.contains($0) }) else { continue }

            let key = "process#\(proc.pid)"
            seen.insert(key)
            let busy = cpuCoresBusy(proc.pid)
            let active = busy >= prefs.processCPUThreshold

            if var existing = registry[key] {
                let newStatus: AgentStatus = active ? .working : .idle
                if existing.status != newStatus {
                    if newStatus == .working {
                        existing.startedWorkingAt = Date()
                        let b = batteryReader()
                        existing.batteryAtStart = b.pct
                        existing.startedOnAC = b.onAC
                    } else {
                        recordWork(existing, reason: "process went idle")
                        existing.startedWorkingAt = nil
                    }
                    existing.status = newStatus
                    changed = true
                }
                existing.lastSeen = Date()
                registry[key] = existing
            } else if active {
                registry[key] = AgentSession(
                    key: key, agent: needle, sessionID: String(proc.pid),
                    status: .working, detail: nil, lastSeen: Date(),
                    startedWorkingAt: Date(),
                    batteryAtStart: batteryReader().pct,
                    startedOnAC: batteryReader().onAC,
                    source: .process, pid: proc.pid)
                changed = true
            }
        }

        // Drop process entries whose pid is gone.
        for (k, s) in registry where s.source == .process && !seen.contains(k) {
            registry.removeValue(forKey: k)
            lastCPUSample.removeValue(forKey: s.pid ?? -1)
            changed = true
        }

        if changed { publish() }
    }

    /// Cores busy since the previous sample. First call for a pid returns 0.
    private func cpuCoresBusy(_ pid: pid_t) -> Double {
        var info = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            // rusage_info_t is `typedef void *`, so this rebind is mandatory —
            // passing &info directly does not compile.
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard rc == 0 else { return 0 }

        let cpu = info.ri_user_time &+ info.ri_system_time
        let now = Self.machNowNanos()
        defer { lastCPUSample[pid] = (cpu, now) }

        guard let prev = lastCPUSample[pid], now > prev.at, cpu >= prev.ns else { return 0 }
        return Double(cpu - prev.ns) / Double(now - prev.at)
    }

    // MARK: - Low-level process helpers

    struct LiveProcess { let pid: pid_t; let uid: uid_t }

    nonisolated static func liveProcesses() -> [LiveProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // The table can grow between the sizing call and the real one — add slack, then
        // take the count from the returned length rather than from what we asked for.
        size += 64 * MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &buf, &size, nil, 0) == 0 else { return [] }

        let count = size / MemoryLayout<kinfo_proc>.stride
        return buf.prefix(count).compactMap {
            let pid = $0.kp_proc.p_pid
            return pid > 0 ? LiveProcess(pid: pid, uid: $0.kp_eproc.e_ucred.cr_uid) : nil
        }
    }

    /// Works across uid boundaries with no TCC prompt.
    /// PROC_PIDPATHINFO_MAXSIZE does not import into Swift, hence the literal.
    nonisolated static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, 4096) > 0 else { return nil }
        return String(cString: buf)
    }

    nonisolated static func machNowNanos() -> UInt64 {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return mach_absolute_time() &* UInt64(tb.numer) / UInt64(tb.denom)
    }

    // No deinit: this manager lives for the whole process. The socket file is unlinked
    // at startup before bind(), so a stale one left by a crash is harmless.
}

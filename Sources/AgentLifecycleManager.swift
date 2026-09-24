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
    /// Re-adopted after a restart and not heard from since. Its pid may be a reuse, or its
    /// turn may have ended while Lucid was down, so a live pid alone does not keep it.
    var recovered = false

    var id: String { key }
    var isWorking: Bool { status == .working }

    var displayName: String {
        // A process row's agent is its whitelist entry, which may be a path fragment.
        AgentRegistry.find(agent)?.name ?? agent.trimmingCharacters(in: .punctuationCharacters).capitalized
    }

    var statusLine: String {
        if source == .process { return status == .working ? "Active Process" : "Idle Process" }
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
    /// status.json as the previous run left it, read before this run can write it:
    /// AppState's init overwrites the file (its mode didSet runs evaluate) before the
    /// re-adoption below gets to read it.
    private let statusAtLaunch = try? Data(contentsOf: AppPaths.status)
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
        // The wire pid is untrusted input. Only a live process of this user can be an
        // agent: pid 0 or 1 (a detached hook reports launchd) never exits and pinned the
        // Mac awake, and a negative pid trapped in makeProcessSource.
        let pid = event.pid.flatMap { Self.isOwnLiveProcess($0) ? $0 : nil }
        let detail = event.detail.flatMap { $0.isEmpty ? nil : $0 }

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
            existing.recovered = false
            if let d = detail { existing.detail = d }
            if let p = pid { existing.pid = p }
            registry[key] = existing
        } else {
            // A new session in a process whose other sessions sit idle: those are over.
            // Cline in VS Code runs every task under one extension host and sends no end
            // event, so finished tasks otherwise stayed listed until the window closed.
            if let p = pid {
                for (k, s) in registry where s.source == .hook && s.agent == event.agent
                                              && s.pid == p && !s.isWorking {
                    exitWatchers[k]?.cancel(); exitWatchers[k] = nil
                    registry[k] = nil
                }
            }
            registry[key] = AgentSession(
                key: key, agent: event.agent, sessionID: event.session_id,
                status: event.status, detail: detail,
                lastSeen: Date(),
                startedWorkingAt: event.status == .working ? Date() : nil,
                batteryAtStart: event.status == .working ? batteryReader().pct : nil,
                startedOnAC: event.status == .working ? batteryReader().onAC : nil,
                source: .hook, pid: pid)
        }

        if let p = pid {
            watchForExit(key: key, pid: p)
            // The hook now speaks for this process; a CPU-guessed row for it is noise.
            if registry.removeValue(forKey: "process#\(p)") != nil { lastCPUSample[p] = nil }
        }
        publish()
    }

    /// Watch the agent's pid with kqueue NOTE_EXIT. This is push, not poll, and works on
    /// any pid without special permission. Without it, an agent killed mid-turn would keep
    /// the Mac awake for the whole stale-session timeout.
    private func watchForExit(key: String, pid: pid_t) {
        // Follow the latest pid. Staying on the first one meant a transient shell that
        // happened to send the first event reaped the session the moment it exited.
        if let w = exitWatchers[key] {
            guard w.handle != pid else { return }
            w.cancel()
            exitWatchers[key] = nil
        }
        guard Self.isOwnLiveProcess(pid) else { return }

        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.exitWatchers[key]?.handle == pid else { return }
                log.notice("agent pid \(pid) exited — reaping \(key, privacy: .public)")
                self.finish(key: key, reason: "agent exited")
                self.exitWatchers[key]?.cancel()
                self.exitWatchers[key] = nil
            }
        }
        src.resume()
        exitWatchers[key] = src
    }

    /// Agents always run as the same user as the app. Anything else — pid 0 or 1, another
    /// user's process, a dead pid — cannot be one, and must not be kept alive on its say-so.
    nonisolated static func isOwnLiveProcess(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_pid == pid && info.kp_eproc.e_ucred.cr_uid == getuid()
    }

    /// Write one stretch of work to history. No-op unless the session was actually
    /// working, and `SessionHistory` drops anything shorter than a couple of seconds.
    private func recordWork(_ s: AgentSession, reason: String, ended: Date = Date()) {
        guard let started = s.startedWorkingAt else { return }
        let now = batteryReader()
        SessionHistory.shared.record(
            agent: s.displayName, started: started, ended: ended, reason: reason,
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

        for (k, s) in registry where s.source == .hook && s.lastSeen < cutoff {
            if let pid = s.pid, !s.recovered, Self.isOwnLiveProcess(pid) {
                // Still running. A silent working session is kept, refreshed so the next
                // window is measured from now, and labelled as inferred from the process.
                // A silent idle one is simply left alone: the agent is open, waiting.
                guard s.isWorking else { continue }
                registry[k]?.lastSeen = Date()
                registry[k]?.detail = "Running (no heartbeat — process alive)"
                alive.append(k)
            } else {
                // Silent and nothing alive behind it: gone. Removed and recorded, not
                // relabelled — relabelled rows piled up in the menu for good.
                if let started = s.startedWorkingAt {
                    recordWork(s, reason: "reaped — no heartbeat", ended: max(started, s.lastSeen))
                }
                registry.removeValue(forKey: k)
                exitWatchers[k]?.cancel(); exitWatchers[k] = nil
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

    /// Re-adopt sessions that outlived a crash.
    ///
    /// The registry deliberately starts empty — persisting "working" blind would let one
    /// bad shutdown pin the Mac awake forever. Re-adoption is safe because it is not
    /// belief, it is a check: only a session whose recorded pid is still a running process
    /// comes back, and it comes back labelled as recovered.
    func readoptSurvivingSessions() {
        guard let data = statusAtLaunch,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["sessions"] as? [[String: Any]]
        else { return }

        var adopted = 0
        for row in rows {
            // Hook rows only. A process-fallback row came back as a "hook" session that no
            // hook would ever update, and held the Mac awake for as long as that process
            // (an ollama daemon, a Cursor helper) lived. The scanner rebuilds those itself.
            guard let agent = row["agent"] as? String,
                  let sid = row["session"] as? String,
                  (row["source"] as? String) == SessionSource.hook.rawValue,
                  (row["status"] as? String) == AgentStatus.working.rawValue,
                  let rawPid = row["pid"] as? Int32,
                  Self.isOwnLiveProcess(rawPid)
            else { continue }

            let key = Self.key(agent: agent, session: sid)
            guard registry[key] == nil else { continue }
            registry[key] = AgentSession(
                key: key, agent: agent, sessionID: sid,
                status: .working, detail: "Recovered after restart",
                lastSeen: Date(), startedWorkingAt: Date(),
                batteryAtStart: batteryReader().pct, startedOnAC: batteryReader().onAC,
                source: .hook, pid: rawPid, recovered: true)
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
                // A client that hung up while queued, or a momentary fd shortage, must not
                // end the listener — it used to, silently, while the UI said "Accepting".
                switch errno {
                case EINTR, ECONNABORTED: continue
                case EMFILE, ENFILE, ENOMEM, ENOBUFS: usleep(100_000); continue
                default:
                    let why = String(cString: strerror(errno))
                    Task { @MainActor [weak self] in
                        self?.isListening = false
                        self?.listenerError = "accept() failed: \(why)"
                    }
                    return
                }
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
        // The timeout above is per read. This bounds the whole exchange, so a client that
        // trickles a byte a second cannot hold the only accept thread for hours.
        let deadline = Self.machNowNanos() + 2_000_000_000

        var pending = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var delivered = 0

        while Self.machNowNanos() < deadline {
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
        // Off, or nothing to match: drop every process row. An empty whitelist used to
        // return before this, leaving a working row in place forever.
        let hookAgents = Set(registry.values.compactMap { $0.source == .hook ? $0.agent : nil })
        let needles = prefs.processWhitelist.map { $0.lowercased() }
            .filter { !$0.isEmpty && !Self.reportsViaHooks($0, live: hookAgents) }
        guard prefs.processFallbackEnabled, !needles.isEmpty else {
            let rows = registry.filter { $0.value.source == .process }
            guard !rows.isEmpty else { return }
            for (k, s) in rows { recordWork(s, reason: "process tracking off"); registry[k] = nil }
            lastCPUSample.removeAll()
            publish()
            return
        }

        let me = getuid()
        let hookPids = Set(registry.values.compactMap { $0.source == .hook ? $0.pid : nil })
        var seen = Set<String>()
        var matchedPids = Set<pid_t>()
        var changed = false

        for proc in Self.liveProcesses() {
            // rusage is EPERM across uid boundaries, so only consider our own processes.
            guard proc.uid == me, !hookPids.contains(proc.pid),
                  let needle = Self.matchedNeedle(proc.pid, needles) else { continue }

            let key = "process#\(proc.pid)"
            seen.insert(key)
            matchedPids.insert(proc.pid)
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

        // Drop process entries whose pid is gone, recording the work they were doing.
        for (k, s) in registry where s.source == .process && !seen.contains(k) {
            recordWork(s, reason: "process exited")
            registry.removeValue(forKey: k)
            changed = true
        }
        // Samples for every matched pid, row or not; anything else is a dead pid whose
        // number may be reused.
        lastCPUSample = lastCPUSample.filter { matchedPids.contains($0.key) }

        if changed { publish() }
    }

    /// An agent that reports through hooks, its own or Claude Code's relabelled, has its
    /// state from the source. Guessing from its busy processes as well (Cursor indexing, a
    /// TS server) held the Mac awake while its hooks said it was waiting.
    private static func reportsViaHooks(_ needle: String, live: Set<String>) -> Bool {
        guard let owner = ["cursor helper": "cursor", "cline": "cline"][needle] else { return false }
        return live.contains(owner) || (AgentRegistry.find(owner)?.installed ?? false)
    }

    /// The whitelist entry this process answers to, if any.
    ///
    /// Matched against the names a process goes by, never its full path: a path match on
    /// "gemini" caught every helper inside Google's Gemini desktop app. For an interpreter
    /// the executable is just `node` or `python`, so the script it runs is checked too —
    /// that is the only way a node- or python-based CLI can match at all.
    nonisolated static func matchedNeedle(_ pid: pid_t, _ needles: [String]) -> String? {
        guard let path = executablePath(pid) else { return nil }
        var names = [(path as NSString).lastPathComponent.lowercased()]
        let interpreters = ["node", "python", "bun", "deno", "ruby"]
        if interpreters.contains(where: { names[0].hasPrefix($0) }) {
            names += arguments(pid).dropFirst().prefix(2)
                .map { ($0 as NSString).lastPathComponent.lowercased() }
        }
        // An entry with a slash is a path fragment, as every entry was in 0.10: match it
        // against the whole path. Bare names match names only, or "gemini" matched
        // Google's own app through its bundle path.
        let full = path.lowercased()
        return needles.first { n in n.contains("/") ? full.contains(n) : names.contains { $0.contains(n) } }
    }

    /// A process's argv, via KERN_PROCARGS2 — readable for our own processes with no
    /// TCC prompt. Layout: argc (Int32), the exec path, NUL padding, then argc strings.
    nonisolated static func arguments(_ pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }      // exec path
        while i < size, buf[i] == 0 { i += 1 }      // padding
        var args: [String] = []
        while args.count < argc, i < size {
            var j = i
            while j < size, buf[j] != 0 { j += 1 }
            args.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return args
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

        // ri_user_time and ri_system_time are Mach ticks, not nanoseconds: 24 MHz on Apple
        // Silicon. Dividing them by nanoseconds read every process ~41x too idle, so
        // nothing ever crossed the busy threshold.
        let cpu = Self.ticksToNanos(info.ri_user_time &+ info.ri_system_time)
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

    private nonisolated static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    nonisolated static func ticksToNanos(_ t: UInt64) -> UInt64 {
        t &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    nonisolated static func machNowNanos() -> UInt64 { ticksToNanos(mach_absolute_time()) }

    // No deinit: this manager lives for the whole process. The socket file is unlinked
    // at startup before bind(), so a stale one left by a crash is harmless.
}

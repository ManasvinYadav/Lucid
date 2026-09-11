import Foundation
import Observation

struct SessionRecord: Codable, Identifiable {
    let id: UUID
    let agent: String
    let started: Date
    let ended: Date
    let reason: String
    /// Battery percentage at each end, and whether it was on wall power throughout.
    /// Optional because records written by older versions do not carry them.
    var batteryStart: Int?
    var batteryEnd: Int?
    var wasOnAC: Bool?

    var duration: TimeInterval { ended.timeIntervalSince(started) }

    /// Percentage points spent, or nil when it ran on AC or the readings are missing.
    /// Negative drain (charging) reads as nil rather than as a gain.
    var batterySpent: Int? {
        guard wasOnAC == false, let a = batteryStart, let b = batteryEnd, a > b else { return nil }
        return a - b
    }

    init(agent: String, started: Date, ended: Date, reason: String,
         batteryStart: Int? = nil, batteryEnd: Int? = nil, wasOnAC: Bool? = nil) {
        self.id = UUID(); self.agent = agent
        self.started = started; self.ended = ended; self.reason = reason
        self.batteryStart = batteryStart; self.batteryEnd = batteryEnd
        self.wasOnAC = wasOnAC
    }
}

/// Append-only record of work sessions, so you can see where the awake time went.
/// Capped and pruned — this is a debugging aid, not an analytics pipeline.
@Observable
@MainActor
final class SessionHistory {
    static let shared = SessionHistory()

    private(set) var records: [SessionRecord] = []
    private let maxRecords = 300
    private let keepDays: TimeInterval = 14 * 86_400

    private init() { load() }

    func record(agent: String, started: Date, ended: Date, reason: String,
                batteryStart: Int? = nil, batteryEnd: Int? = nil, wasOnAC: Bool? = nil) {
        // Ignore blips: a turn shorter than a couple of seconds is noise.
        guard ended.timeIntervalSince(started) >= 2 else { return }
        records.insert(SessionRecord(agent: agent, started: started,
                                     ended: ended, reason: reason,
                                     batteryStart: batteryStart, batteryEnd: batteryEnd,
                                     wasOnAC: wasOnAC), at: 0)
        prune()
        save()
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-keepDays)
        records.removeAll { $0.ended < cutoff }
        if records.count > maxRecords { records.removeLast(records.count - maxRecords) }
    }

    // MARK: Aggregates

    func totalAwake(since: Date) -> TimeInterval {
        records.filter { $0.ended >= since }.reduce(0) { $0 + $1.duration }
    }

    var awakeToday: TimeInterval {
        totalAwake(since: Calendar.current.startOfDay(for: Date()))
    }

    var byAgentToday: [(agent: String, total: TimeInterval)] {
        let start = Calendar.current.startOfDay(for: Date())
        var totals: [String: TimeInterval] = [:]
        for r in records where r.ended >= start { totals[r.agent, default: 0] += r.duration }
        return totals.sorted { $0.value > $1.value }.map { (agent: $0.key, total: $0.value) }
    }

    /// Battery points spent today on agent work, and the hours that covers. Only sessions
    /// that actually ran on battery contribute, so an all-AC day reports nothing.
    var batteryTodaySpent: (points: Int, hours: Double)? {
        let start = Calendar.current.startOfDay(for: Date())
        let onBattery = records.filter { $0.ended >= start && $0.batterySpent != nil }
        guard !onBattery.isEmpty else { return nil }
        let pts = onBattery.reduce(0) { $0 + ($1.batterySpent ?? 0) }
        let hrs = onBattery.reduce(0.0) { $0 + $1.duration } / 3600
        guard pts > 0, hrs > 0 else { return nil }
        return (pts, hrs)
    }

    func clear() {
        records = []
        try? FileManager.default.removeItem(at: AppPaths.history)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.history) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        records = (try? dec.decode([SessionRecord].self, from: data)) ?? []
        prune()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted]
        guard let data = try? enc.encode(records) else { return }
        try? data.write(to: AppPaths.history, options: .atomic)
    }
}

extension TimeInterval {
    /// "2h 14m" / "3m 12s" / "48s"
    var compactDuration: String {
        let s = Int(self)
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60   { return "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }
}

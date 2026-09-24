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

    /// Records merged into non-overlapping spans and clipped to start at `since`. Two
    /// agents working at once is one stretch of time, not two, and a session that began
    /// before midnight only counts its part of today.
    nonisolated static func spans(_ rs: [SessionRecord], since: Date)
        -> [(start: Date, end: Date, members: [SessionRecord])] {
        var out: [(start: Date, end: Date, members: [SessionRecord])] = []
        for r in rs.filter({ $0.ended > since }).sorted(by: { $0.started < $1.started }) {
            let start = max(r.started, since)
            if let last = out.last, start <= last.end {
                out[out.count - 1].end = max(last.end, r.ended)
                out[out.count - 1].members.append(r)
            } else {
                out.append((start, r.ended, [r]))
            }
        }
        return out
    }

    /// Wall-clock time at least one of `rs` was working, from `since` on.
    nonisolated static func workingTime(_ rs: [SessionRecord], since: Date) -> TimeInterval {
        spans(rs, since: since).reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    /// Battery points spent on agent work, and the hours that covers. Only records that
    /// ran on battery count, and drain is taken once per overlapping span rather than
    /// once per session inside it.
    nonisolated static func batterySpent(_ rs: [SessionRecord], since: Date)
        -> (points: Int, hours: Double)? {
        let groups = spans(rs.filter { $0.batterySpent != nil }, since: since)
        let pts = groups.reduce(0) { acc, g in
            let hi = g.members.compactMap(\.batteryStart).max() ?? 0
            let lo = g.members.compactMap(\.batteryEnd).min() ?? hi
            return acc + max(0, hi - lo)
        }
        let hrs = groups.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } / 3600
        guard pts > 0, hrs > 0 else { return nil }
        return (pts, hrs)
    }

    private var startOfToday: Date { Calendar.current.startOfDay(for: Date()) }

    var awakeToday: TimeInterval { Self.workingTime(records, since: startOfToday) }

    var byAgentToday: [(agent: String, total: TimeInterval)] {
        Dictionary(grouping: records, by: \.agent)
            .map { (agent: $0.key, total: Self.workingTime($0.value, since: startOfToday)) }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
    }

    var batteryTodaySpent: (points: Int, hours: Double)? {
        Self.batterySpent(records, since: startOfToday)
    }

    func clear() {
        records = []
        try? FileManager.default.removeItem(at: AppPaths.history)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.history) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        do {
            records = try dec.decode([SessionRecord].self, from: data)
        } catch {
            // Kept, not overwritten by the next save: it may be recoverable by hand.
            let aside = AppPaths.history.appendingPathExtension(
                "corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: AppPaths.history, to: aside)
            records = []
        }
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

import Foundation

/// What happened while the lid was shut.
///
/// The whole interaction model is: close the lid, walk away, come back. On return the
/// only evidence is a menu bar icon and a session list showing the present moment, so
/// anything that finished, failed or tripped in between has to be reconstructed from
/// history rows. Any notification fired at a closed laptop was also never seen.
struct AwayReport {
    let closedFor: TimeInterval
    let finished: [SessionRecord]
    let stillWorking: [String]
    let guardrailTripped: String?
    let batterySpent: Int?
    let sleptWhileArmed: Bool
    let panelLitSeconds: Int

    /// Nothing to say about a brief lid close, or one where nothing happened.
    var isWorthShowing: Bool {
        closedFor >= 10 * 60
            && (!finished.isEmpty || guardrailTripped != nil || sleptWhileArmed
                || !stillWorking.isEmpty)
    }

    var headline: String {
        if sleptWhileArmed { return "The Mac slept while the lock was held" }
        if let g = guardrailTripped { return g }
        if !finished.isEmpty && stillWorking.isEmpty {
            return finished.count == 1
                ? "1 session finished while you were away"
                : "\(finished.count) sessions finished while you were away"
        }
        if !stillWorking.isEmpty {
            return stillWorking.count == 1
                ? "1 agent is still working"
                : "\(stillWorking.count) agents are still working"
        }
        return "Nothing to report"
    }

    /// Built from state the app already keeps, at the moment the lid opens.
    @MainActor
    static func build(closedSince: Date, state: AppState) -> AwayReport {
        let closedFor = Date().timeIntervalSince(closedSince)
        let finished = SessionHistory.shared.records.filter { $0.ended >= closedSince }
        let spent = finished.compactMap(\.batterySpent).reduce(0, +)
        return AwayReport(
            closedFor: closedFor,
            finished: finished,
            stillWorking: state.lifecycle.sessions.filter(\.isWorking).map(\.displayName),
            guardrailTripped: state.guardrails.yieldReason?.summary,
            batterySpent: spent > 0 ? spent : nil,
            sleptWhileArmed: state.power.sleepHistory.contains {
                $0.at >= closedSince && $0.wasArmed
            },
            panelLitSeconds: state.power.displayLitSeconds)
    }
}

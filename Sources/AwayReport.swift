import Foundation

/// What happened while the lid was shut.
///
/// The whole interaction model is: close the lid, walk away, come back. On return the
/// only evidence is a menu bar icon and a session list showing the present moment, so
/// anything that finished, failed or tripped in between has to be reconstructed from
/// history rows. Any notification fired at a closed laptop was also never seen.
struct AwayReport {
    let closedFor: TimeInterval
    /// Agent turns that ended while the lid was shut. One session can finish many.
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
                ? "1 agent turn finished while you were away"
                : "\(finished.count) agent turns finished while you were away"
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
        // One reading across the whole window. Summing each session's drain counted the
        // same battery once per concurrent session.
        let g = state.guardrails
        let spent = state.lidClosedBattery.map { g.onACPower ? 0 : $0 - g.batteryPercent } ?? 0
        return AwayReport(
            closedFor: closedFor,
            finished: finished,
            stillWorking: state.lifecycle.sessions.filter(\.isWorking).map(\.displayName),
            // What tripped during the close, never what is live now: Low Power Mode left
            // on before the lid shut is not news, and opening the lid ends the lid cap.
            guardrailTripped: state.awayTrips.last,
            batterySpent: spent > 0 ? spent : nil,
            // PowerManager's verdict, not every armed sleep: with the lid shut and no
            // SleepDisabled (no rule, or coverage off), sleeping is what was promised.
            sleptWhileArmed: state.power.lastFailedSleep.map { $0 >= closedSince } ?? false,
            panelLitSeconds: state.power.displayLitSeconds)
    }
}

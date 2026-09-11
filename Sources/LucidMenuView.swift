import SwiftUI

struct LucidMenuView: View {
    #if !DEBUG_RENDER
    @Environment(\.openSettings) private var openSettings
    #endif
    @Bindable var state: AppState
    private var prefs: Preferences { Preferences.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            awayReport
            sessionList
            controls
            statsStrip
            alerts
            footer
        }
        .frame(width: 320)
    }

    // MARK: Header

    private var tint: Color {
        switch state.statusTint {
        case .active:  return .green
        case .warning: return .orange
        case .neutral: return .secondary
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: state.statusSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.statusSummary)
                    .font(.system(size: 13, weight: .semibold))
                Text(state.statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let g = state.lifecycle.graceRemaining {
                countdown("\(g)s", "grace", .secondary)
                    .help("Releasing the lock after the grace period")
            } else if let cap = state.guardrails.lidCapRemaining, state.power.isArmed {
                countdown(cap >= 60 ? "\(cap / 60)h\(cap % 60)m" : "\(cap)m", "cap",
                          cap <= 10 ? .orange : .secondary)
                    .help("Time left before the lid-closed safety cap releases the lock")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private func countdown(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.caption.monospacedDigit().weight(.medium))
            Text(label).font(.system(size: 9))
        }
        .foregroundStyle(color)
    }

    // MARK: Away report

    @ViewBuilder private var awayReport: some View {
        if let r = state.awayReport {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Label(r.headline,
                          systemImage: r.sleptWhileArmed
                              ? "exclamationmark.octagon.fill" : "clock.arrow.circlepath")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(r.sleptWhileArmed ? Color.red : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { state.awayReport = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }

                Text("Lid shut for \(r.closedFor.compactDuration)")
                    .font(.caption).foregroundStyle(.secondary)

                ForEach(r.finished.prefix(4)) { rec in
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9)).foregroundStyle(.green)
                        Text(rec.agent).font(.caption)
                        Text(rec.duration.compactDuration)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                if r.finished.count > 4 {
                    Text("and \(r.finished.count - 4) more")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    if let b = r.batterySpent {
                        Label("\(b)% battery", systemImage: "battery.50")
                    }
                    if r.panelLitSeconds > 0 {
                        Label("panel lit \(TimeInterval(r.panelLitSeconds).compactDuration)",
                              systemImage: "sun.max")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.quaternary.opacity(0.3))
            Divider()
        }
    }

    // MARK: Sessions

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Sessions",
                         trailing: state.lifecycle.sessions.isEmpty
                                   ? nil : "\(state.workingCount) working")

            if state.lifecycle.sessions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: state.lifecycle.isListening
                          ? "ellipsis.circle" : "exclamationmark.octagon.fill")
                    Text(state.lifecycle.isListening
                         ? "No agent has reported in yet."
                         : "Listener unavailable — \(state.lifecycle.listenerError ?? "unknown error")")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(state.lifecycle.isListening ? Color.secondary : Color.red)
                .padding(.horizontal, 14).padding(.bottom, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(state.lifecycle.sessions) { session in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(dotColor(session))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(session.displayName).font(.callout)
                                Text(session.statusLine)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                            Text(session.source.badge)
                                .font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(badgeColor(session).opacity(0.15), in: Capsule())
                                .foregroundStyle(badgeColor(session))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 5)
                    }
                }
                .padding(.bottom, 6)
            }
            Divider()
        }
    }

    private func dotColor(_ s: AgentSession) -> Color {
        guard s.isWorking else { return .secondary.opacity(0.5) }
        return s.source == .hook ? .green : .blue
    }

    private func badgeColor(_ s: AgentSession) -> Color {
        s.source == .hook ? (s.isWorking ? .green : .secondary) : .blue
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: $state.mode) {
                ForEach(LockMode.allCases) { Text($0.shortTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                if state.isPaused {
                    Button { state.resume() } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                } else {
                    Button("Pause 30m") { state.pause(minutes: 30) }
                    Button("Pause 1h")  { state.pause(minutes: 60) }
                }
                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { prefs.lidCloseCoverage },
                set: { prefs.lidCloseCoverage = $0; state.settingsChanged() })) {
                    Text("Keep awake with the lid shut").font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!state.privilegeRuleInstalled)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Stats

    private var statsStrip: some View {
        HStack(spacing: 0) {
            stat(state.guardrails.onACPower ? "powerplug.fill" : "battery.50",
                 "\(state.guardrails.batteryPercent)%",
                 state.guardrails.batteryPercent <= prefs.batteryFloor && !state.guardrails.onACPower
                    ? .orange : .secondary)
            stat("thermometer.medium", state.guardrails.thermalState.label,
                 state.guardrails.thermalState == .nominal ? .secondary : .orange)
            stat(state.power.lidClosed ? "laptopcomputer.slash" : "laptopcomputer",
                 state.power.lidClosed ? "Shut" : "Open", .secondary)
            stat(PowerManager.displayIsAsleep ? "moon.fill" : "sun.max.fill",
                 PowerManager.displayIsAsleep ? "Dark" : "Lit",
                 state.power.lidClosed && !PowerManager.displayIsAsleep ? .orange : .secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.quaternary.opacity(0.25))
    }

    private func stat(_ icon: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 11))
            Text(value).font(.system(size: 10, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
    }

    // MARK: Alerts

    @ViewBuilder private var alerts: some View {
        let items = alertItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.text) { item in
                    Label(item.text, systemImage: item.icon)
                        .font(.caption)
                        .foregroundStyle(item.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var alertItems: [(text: String, icon: String, color: Color)] {
        var out: [(String, String, Color)] = []
        if let r = state.guardrails.yieldReason {
            out.append((r.summary, "exclamationmark.triangle.fill", .orange))
        }
        if !state.privilegeRuleInstalled {
            out.append(("Lid-close support needs a one-time setup in Settings → Privileges.",
                        "lock.fill", .orange))
        }
        if state.power.lidClosed, !state.power.panelHeldBy.isEmpty {
            let who = Set(state.power.panelHeldBy).sorted().joined(separator: ", ")
            out.append(("The screen is being kept on by \(who). Brightness has been set to zero instead.",
                        "sun.max.trianglebadge.exclamationmark", .orange))
        }
        for issue in state.preflightIssues {
            out.append((issue.text,
                        issue.severity == .blocking
                            ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
                        issue.severity == .blocking ? .red : .orange))
        }
        if let err = state.power.lastError {
            out.append((err, "exclamationmark.octagon.fill", .red))
        }
        return out
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                #if DEBUG_RENDER
                Button("Settings…") {}
                #else
                // An accessory (LSUIElement) app is never made active when a window opens,
                // so the Settings window lands behind the frontmost app. SwiftUI has
                // already ordered it front within this app by the time openSettings()
                // returns, so activation is the only missing piece. Not
                // orderFrontRegardless(): that fronts the window without focusing it.
                Button("Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                #endif
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }
}

/// A small uppercase section heading with an optional right-hand count.
private struct SectionLabel: View {
    let title: String
    let trailing: String?
    init(_ title: String, trailing: String? = nil) {
        self.title = title; self.trailing = trailing
    }
    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 4)
    }
}

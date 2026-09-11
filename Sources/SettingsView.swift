import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            GeneralSettings(state: state)
                .tabItem { Label("General", systemImage: "gearshape") }
            PowerSettings(state: state)
                .tabItem { Label("Power", systemImage: "bolt") }
            AgentSettings(state: state)
                .tabItem { Label("Agents", systemImage: "sparkles") }
            PrivilegeSettings(state: state)
                .tabItem { Label("Privileges", systemImage: "lock.shield") }
            HistorySettings(state: state)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            DiagnosticsSettings(state: state)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 560, height: 500)
    }
}

// MARK: - Shared bits

/// A caption under a control. Used often enough to be worth the four lines.
private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Bindable var state: AppState
    @Bindable private var prefs = Preferences.shared
    @State private var loginItem = LoginItem.isEnabled
    @State private var showUninstall = false
    @State private var uninstallPrivilege = true
    @State private var uninstallSteps: [Uninstaller.Step] = []

    var body: some View {
        Form {
            Section("Behaviour") {
                Picker("Default mode", selection: $state.mode) {
                    ForEach(LockMode.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Grace period") {
                    HStack {
                        Slider(value: .init(get: { Double(prefs.gracePeriod) },
                                            set: { prefs.gracePeriod = Int($0) }),
                               in: 10...300, step: 5)
                        Text("\(prefs.gracePeriod)s")
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                }
                Hint("How long to keep the lock after the last agent goes idle, so a quick follow-up prompt doesn't thrash it.")

                LabeledContent("Stale session timeout") {
                    Stepper(value: $prefs.sessionTTL, in: 60...1800, step: 60) {
                        Text("\(prefs.sessionTTL / 60) min").monospacedDigit()
                    }
                }
                Hint("An agent that exits without reporting idle is released after this. Clean exits are released immediately.")
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $loginItem)
                    .disabled(LoginItem.blockedReason != nil)
                    .onChange(of: loginItem) { _, on in
                        LoginItem.setEnabled(on)
                        state.refreshLoginItem()
                        loginItem = LoginItem.isEnabled
                    }
                if let why = LoginItem.blockedReason {
                    Label(why, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Hint("Runs in the menu bar with no Dock icon.")
                }
            }

            Section("Feedback") {
                Toggle("Notification banners", isOn: $prefs.notificationsEnabled)
                Toggle("Play chimes", isOn: $prefs.chimesEnabled)
                Toggle("Global shortcut (⌥⌘L)", isOn: $prefs.hotkeyEnabled)
                    .onChange(of: prefs.hotkeyEnabled) { _, on in
                        state.notifications.setHotKeyEnabled(on)
                    }
                if let e = state.notifications.hotKeyError {
                    Label(e, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Uninstall") {
                Button("Remove Everything…", role: .destructive) { showUninstall = true }
                Hint("Releases the lock, then removes hooks from every agent, the login item, the privilege rule, preferences and ~/.lucid. The app bundle itself is left for you to delete.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove Lucid from this Mac?",
                            isPresented: $showUninstall, titleVisibility: .visible) {
            Button("Remove Everything", role: .destructive) {
                uninstallSteps = Uninstaller.run(power: state.power,
                                                 removePrivilege: uninstallPrivilege)
                state.refreshPrivilegeRule()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The wake lock is released first, so the Mac can sleep afterwards. Agent configs are backed up before hooks are removed.")
        }
        .sheet(isPresented: .init(get: { !uninstallSteps.isEmpty },
                                  set: { if !$0 { uninstallSteps = [] } })) {
            UninstallReport(steps: uninstallSteps) { uninstallSteps = [] }
        }
    }
}

private struct UninstallReport: View {
    let steps: [Uninstaller.Step]
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall complete").font(.title3.weight(.semibold))
            ForEach(steps) { s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: s.ok ? "checkmark.circle.fill"
                                           : "exclamationmark.triangle.fill")
                        .foregroundStyle(s.ok ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name)
                        Text(s.detail).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Divider()
            Text("Remove the app bundle manually:")
                .font(.caption).foregroundStyle(.secondary)
            Text(Uninstaller.bundlePath)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        URL(fileURLWithPath: Uninstaller.bundlePath)])
                }
                Spacer()
                Button("Quit Lucid") { NSApp.terminate(nil) }
                    .buttonStyle(.borderedProminent)
                Button("Close", action: done)
            }
        }
        .padding(20).frame(width: 460)
    }
}

// MARK: - Power

struct PowerSettings: View {
    @Bindable var state: AppState
    @Bindable private var prefs = Preferences.shared

    private var runway: String {
        guard !state.guardrails.onACPower else { return "on AC" }
        guard let m = state.guardrails.minutesRemaining else { return "estimating…" }
        return m >= 60 ? "\(m / 60)h \(m % 60)m left" : "\(m)m left"
    }

    var body: some View {
        Form {
            Section("Now") {
                LabeledContent("Battery") {
                    HStack(spacing: 6) {
                        Image(systemName: state.guardrails.onACPower
                              ? "powerplug.fill" : "battery.50")
                        Text("\(state.guardrails.batteryPercent)%").monospacedDigit()
                        Text(runway).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Thermal", value: state.guardrails.thermalState.label)
                LabeledContent("Low Power Mode",
                               value: state.guardrails.lowPowerMode ? "On" : "Off")
                LabeledContent("Lid") {
                    HStack(spacing: 6) {
                        Text(state.power.lidClosed ? "Closed" : "Open")
                        if let since = state.power.lidClosedSince {
                            Text("for \(Date().timeIntervalSince(since).compactDuration)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Panel") {
                    HStack(spacing: 6) {
                        Text(PowerManager.displayIsAsleep ? "Dark" : "Lit")
                        if state.power.lidClosed && state.power.displayLitSeconds > 0 {
                            Text("lit for \(TimeInterval(state.power.displayLitSeconds).compactDuration) with the lid shut")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                LabeledContent("Status") {
                    if let r = state.guardrails.yieldReason {
                        Label(r.summary, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Label("Guardrails clear", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Guardrails") {
                LabeledContent("Battery floor") {
                    HStack {
                        Slider(value: .init(get: { Double(prefs.batteryFloor) },
                                            set: { prefs.batteryFloor = Int($0) }),
                               in: 10...50, step: 5)
                        Text("\(prefs.batteryFloor)%")
                            .monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                }
                .onChange(of: prefs.batteryFloor) { _, _ in state.settingsChanged() }

                Toggle("Only hold awake on AC power", isOn: $prefs.acPowerOnly)
                    .onChange(of: prefs.acPowerOnly) { _, _ in state.settingsChanged() }
                Toggle("Release when Low Power Mode turns on",
                       isOn: $prefs.yieldOnLowPowerMode)
                    .onChange(of: prefs.yieldOnLowPowerMode) { _, _ in state.settingsChanged() }

                Hint("Thermal release is always on: yields at Critical, and at Serious while the lid is shut. There is no temperature threshold.")
            }

            Section("Time limit") {
                Toggle("Release after the lid has been shut too long",
                       isOn: $prefs.maxLidClosedEnabled)
                    .onChange(of: prefs.maxLidClosedEnabled) { _, _ in state.settingsChanged() }
                LabeledContent("Cap") {
                    HStack {
                        Slider(value: .init(get: { Double(prefs.maxLidClosedMinutes) },
                                            set: { prefs.maxLidClosedMinutes = Int($0) }),
                               in: 15...480, step: 15)
                        Text(prefs.maxLidClosedMinutes >= 60
                             ? "\(prefs.maxLidClosedMinutes / 60)h \(prefs.maxLidClosedMinutes % 60)m"
                             : "\(prefs.maxLidClosedMinutes)m")
                            .monospacedDigit().frame(width: 58, alignment: .trailing)
                    }
                }
                .disabled(!prefs.maxLidClosedEnabled)
                .onChange(of: prefs.maxLidClosedMinutes) { _, _ in state.settingsChanged() }

                if let left = state.guardrails.lidCapRemaining {
                    LabeledContent("Time left") {
                        Text(left >= 60 ? "\(left / 60)h \(left % 60)m" : "\(left) min")
                            .monospacedDigit()
                            .foregroundStyle(left <= 10 ? Color.orange : Color.primary)
                    }
                }

                Hint("Backstop for an agent that never reports idle: the lock is released once the lid has been shut this long, regardless of session state.")
            }

            Section("Display") {
                Toggle("Keep awake with the lid closed", isOn: $prefs.lidCloseCoverage)
                    .disabled(!state.privilegeRuleInstalled)
                    .onChange(of: prefs.lidCloseCoverage) { _, _ in state.settingsChanged() }
                if !state.privilegeRuleInstalled {
                    Label("Needs the privilege rule — see Privileges.",
                          systemImage: "lock").font(.caption).foregroundStyle(.orange)
                }
                Toggle("Blank the display when an agent starts working",
                       isOn: $prefs.blankDisplayOnWork)
                Hint("Lucid never holds the display awake; display sleep stays controlled by System Settings.")
                Button("Blank display now") { state.power.displaySleepNow() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Agents

struct AgentSettings: View {
    @Bindable var state: AppState
    @Bindable private var prefs = Preferences.shared
    @State private var newEntry = ""
    @State private var refresh = 0
    @State private var log: String?
    @State private var wrapperFor: String?

    var body: some View {
        Form {
            Section("Lifecycle hooks") {
                ForEach(AgentRegistry.all) { agent in
                    AgentRow(agent: agent, refresh: $refresh, log: $log,
                             wrapperFor: $wrapperFor)
                }
                .id(refresh)

                Hint("Hooks report whether an agent is working or waiting for input. Existing config is merged and backed up, never replaced.")
            }

            Section("Listener") {
                LabeledContent("Status") {
                    Label(state.lifecycle.isListening ? "Accepting" : "Down",
                          systemImage: state.lifecycle.isListening
                                        ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(state.lifecycle.isListening ? Color.green : Color.red)
                }
                LabeledContent("Socket") {
                    Text(AppPaths.socket.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Hint("A Unix socket in a 0700 directory rather than a TCP port, so access is limited to this user account.")
            }

            Section("Process fallback") {
                Toggle("Track tools that have no hooks", isOn: $prefs.processFallbackEnabled)
                LabeledContent("Busy threshold") {
                    HStack {
                        Slider(value: $prefs.processCPUThreshold, in: 0.05...2.0, step: 0.05)
                        Text(String(format: "%.2f cores", prefs.processCPUThreshold))
                            .monospacedDigit().frame(width: 78, alignment: .trailing)
                    }
                }
                .disabled(!prefs.processFallbackEnabled)
                Hint("Matched as substrings against the full executable path. Used for GUI tools like Cursor and Cline that can't report their own state.")

                VStack(spacing: 0) {
                    ForEach(Array(prefs.processWhitelist.enumerated()), id: \.offset) { i, item in
                        HStack {
                            Image(systemName: "terminal").foregroundStyle(.secondary)
                            Text(item).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button {
                                prefs.processWhitelist.remove(at: i)
                            } label: { Image(systemName: "minus.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.red)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        if i < prefs.processWhitelist.count - 1 { Divider() }
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    TextField("Add a process name or path fragment", text: $newEntry)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Reset") { prefs.processWhitelist = Preferences.defaultWhitelist }
                }
                .disabled(!prefs.processFallbackEnabled)
            }
        }
        .formStyle(.grouped)
        .sheet(item: Binding(get: { log.map(TextSheet.init) },
                             set: { if $0 == nil { log = nil } })) { sheet in
            OutputSheet(title: "Installer output", body: sheet.text) { log = nil }
        }
        .sheet(item: Binding(get: { wrapperFor.map(TextSheet.init) },
                             set: { if $0 == nil { wrapperFor = nil } })) { sheet in
            OutputSheet(title: "Wrapper script",
                        body: AgentRegistry.wrapperSnippet(agent: sheet.text)) {
                wrapperFor = nil
            }
        }
    }

    private func add() {
        let v = newEntry.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !prefs.processWhitelist.contains(v) else { return }
        prefs.processWhitelist.append(v)
        newEntry = ""
    }
}

private struct TextSheet: Identifiable {
    let text: String
    var id: String { text }
    init(_ t: String) { text = t }
}

private struct OutputSheet: View {
    let title: String
    let body_: String
    let done: () -> Void
    init(title: String, body: String, done: @escaping () -> Void) {
        self.title = title; self.body_ = body; self.done = done
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView {
                Text(body_)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body_, forType: .string)
                }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
    }
}

private struct AgentRow: View {
    let agent: AgentDefinition
    @Binding var refresh: Int
    @Binding var log: String?
    @Binding var wrapperFor: String?

    private var isManual: Bool {
        if case .manual = agent.mechanism { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(agent.name).fontWeight(.medium)
                if agent.verified {
                    Badge(text: "verified", color: .green)
                } else if !isManual {
                    Badge(text: "best-effort", color: .orange)
                }
                Spacer()
                status
            }

            if let p = agent.configPath {
                Text(p).font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text(agent.note).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if isManual {
                    Button("Show wrapper…") { wrapperFor = agent.id }
                } else {
                    Button(agent.installed ? "Reinstall" : "Install") { run("--apply") }
                        .disabled(!agent.detected)
                    Button("Remove") { run("--uninstall") }
                        .disabled(!agent.installed)
                    Button("Preview") { run("preview") }
                        .disabled(!agent.detected)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var status: some View {
        if agent.installed {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if agent.detected {
            Label("Detected", systemImage: "circle.dashed").foregroundStyle(.orange)
        } else {
            Label("Not found", systemImage: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    private func run(_ mode: String) {
        let r = HookInstaller.run(agent: agent.id, mode)
        log = r.output.isEmpty ? "(no output)" : r.output
        refresh += 1
    }
}

// MARK: - Privileges

struct PrivilegeSettings: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Privilege rule") {
                    Label(state.privilegeRuleInstalled ? "Installed" : "Not installed",
                          systemImage: state.privilegeRuleInstalled
                                        ? "checkmark.seal.fill" : "xmark.seal")
                        .foregroundStyle(state.privilegeRuleInstalled ? Color.green : Color.orange)
                }
                LabeledContent("SleepDisabled flag") {
                    Text(state.power.sleepDisabledEngaged ? "1 — engaged" : "0")
                        .monospacedDigit()
                }
            }

            Section("You may not need this") {
                Hint("""
                     Lucid always holds a PreventUserIdleSystemSleep assertion, which \
                     needs no privileges. On many Apple Silicon Macs that alone is enough to \
                     survive a lid close, and this whole tab is unnecessary.

                     The rule below is the fallback for machines where it is not: it allows \
                     setting the root-only SleepDisabled flag. Run the lid test in \
                     Diagnostics first — it answers which one this Mac needs, and if the \
                     assertion alone holds, remove this rule.

                     The rule is limited to exactly two commands. It is not `pmset *`, which \
                     would be a general root escalation.
                     """)

                Text(PowerManager.sudoersRuleText(user: PowerManager.currentUser))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5),
                                in: RoundedRectangle(cornerRadius: 6))
            }

            Section {
                HStack {
                    Button(state.privilegeRuleInstalled ? "Reinstall…" : "Install…") {
                        state.power.installPrivilegeRule(); state.refreshPrivilegeRule()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Remove") {
                        state.power.removePrivilegeRule(); state.refreshPrivilegeRule()
                    }
                    .disabled(!state.privilegeRuleInstalled)
                    Spacer()
                    Text("Asks for your password once")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - History

struct HistorySettings: View {
    @Bindable var state: AppState
    @Bindable private var history = SessionHistory.shared
    @State private var confirmClear = false

    private var fmt: DateFormatter {
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"; return f
    }

    var body: some View {
        Form {
            Section("Today") {
                LabeledContent("Time held awake",
                               value: history.awakeToday.compactDuration)
                if let cost = history.batteryTodaySpent {
                    LabeledContent("Battery spent") {
                        Text("\(cost.points)% over \(String(format: "%.1f", cost.hours))h  ·  about \(Int(Double(cost.points) / cost.hours))%/h")
                            .monospacedDigit()
                    }
                }
                if history.byAgentToday.isEmpty {
                    Text("No completed sessions yet today.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(history.byAgentToday, id: \.agent) { row in
                        LabeledContent(row.agent, value: row.total.compactDuration)
                    }
                }
            }

            Section("Sessions") {
                if history.records.isEmpty {
                    Text("Nothing recorded yet. A session is written when an agent finishes, exits, or is reaped.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(history.records) { r in          // already newest-first
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.agent)
                                Text(r.reason).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                HStack(spacing: 5) {
                                    if let spent = r.batterySpent {
                                        Text("\(spent)%")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.orange)
                                    }
                                    Text(r.duration.compactDuration).monospacedDigit()
                                }
                                Text(fmt.string(from: r.started))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 1)
                    }
                }
            }

            Section {
                HStack {
                    Button("Clear history", role: .destructive) { confirmClear = true }
                        .disabled(history.records.isEmpty)
                    Spacer()
                    Text("Battery figures cover sessions run wholly on battery")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear session history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsSettings: View {
    @Bindable var state: AppState

    private var fmt: DateFormatter {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }

    var body: some View {
        Form {
            Section("Lock") {
                LabeledContent("Armed", value: state.power.isArmed ? "Yes" : "No")
                LabeledContent("Mode", value: state.mode.title)
                LabeledContent("Sessions", value: "\(state.lifecycle.sessions.count)")
                LabeledContent("Working", value: "\(state.workingCount)")
            }

            Section("Lid test") {
                LidTestView(state: state)
                Hint("Two mechanisms can hold a Mac awake with the lid shut: an unprivileged power assertion, and the root-gated SleepDisabled flag. Which one a given Mac needs can only be settled by closing the lid. This does that and reports the result.")
            }

            Section("Lock failures") {
                if let f = state.power.lastFailedSleep {
                    Label("Slept while armed at \(fmt.string(from: f)) — the lock did not hold",
                          systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Button("Clear") { state.power.clearFailureRecord() }
                } else {
                    Label("No sleep has occurred while armed",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            Section("Recent sleeps observed") {
                if state.power.sleepHistory.isEmpty {
                    Text("None since launch.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(state.power.sleepHistory.enumerated()), id: \.offset) { _, e in
                        HStack {
                            Text(fmt.string(from: e.at)).monospacedDigit()
                            Spacer()
                            Text(e.wasArmed ? "while armed" : "not armed")
                                .foregroundStyle(e.wasArmed ? Color.red : Color.secondary)
                        }
                        .font(.caption)
                    }
                }
            }

            Section("State file") {
                Text(AppPaths.status.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.status])
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct LidTestView: View {
    @Bindable var state: AppState

    var body: some View {
        switch state.power.lidTest {
        case .idle:
            start

        case let .waitingForClose(layer):
            row("Close the lid now and leave it shut for at least a minute. Testing \(layer.label).",
                "laptopcomputer.and.arrow.down", .accentColor, cancel: true)

        case let .lidClosed(since, layer):
            row("Lid shut for \(Date().timeIntervalSince(since).compactDuration) — testing \(layer.label). Reopen the lid to finish the test.",
                "moon.zzz.fill", .accentColor, cancel: true)

        case let .passed(closedFor, panelLit, layer):
            passed(closedFor, panelLit, layer)

        case let .failed(at, layer):
            VStack(alignment: .leading, spacing: 8) {
                Label("Failed — the Mac slept at \(at.formatted(date: .omitted, time: .standard)) with \(layer.label) in force.",
                      systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if layer == .assertionOnly {
                    Text("This is the expected result on most Macs. Try the privileged layer next.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Test assertion + SleepDisabled") {
                        state.power.startLidTest(layer: .sleepDisabled)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("Lid-close coverage cannot work on this Mac by either route.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Run again") { state.power.startLidTest(layer: .sleepDisabled) }
                }
            }

        case let .cancelled(why):
            VStack(alignment: .leading, spacing: 8) {
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                start
            }
        }
    }

    private var start: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Test assertion only") {
                    state.power.startLidTest(layer: .assertionOnly)
                }
                .buttonStyle(.borderedProminent)
                Button("Test with SleepDisabled") {
                    state.power.startLidTest(layer: .sleepDisabled)
                }
                .disabled(!state.privilegeRuleInstalled)
                Spacer()
            }
            Text("Start with the assertion alone. If that holds the lid closed on this Mac, the privileged layer is unnecessary and can be turned off.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func passed(_ closedFor: TimeInterval, _ panelLit: Int,
                        _ layer: PowerManager.LidTestLayer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Passed — stayed awake for \(closedFor.compactDuration) with the lid shut, using \(layer.label).",
                  systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)

            Label(panelLit == 0
                  ? "The panel was dark throughout."
                  : "The panel stayed lit for \(TimeInterval(panelLit).compactDuration) of it.",
                  systemImage: panelLit == 0 ? "moon.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(panelLit == 0 ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)

            if layer == .assertionOnly {
                Text("The unprivileged assertion is enough on this Mac. You can turn off \"Keep awake with the lid closed\" and remove the privilege rule — nothing needs root.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Run again") { state.power.startLidTest(layer: layer) }
        }
    }

    private func row(_ text: String, _ icon: String, _ color: Color,
                     cancel: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(text, systemImage: icon).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if cancel { Button("Cancel") { state.power.cancelLidTest() } }
        }
    }
}

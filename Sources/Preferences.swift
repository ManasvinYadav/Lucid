import Foundation
import Observation

/// UserDefaults-backed settings. Every knob the UI exposes lives here.
@Observable
final class Preferences {
    static let shared = Preferences()

    private let d = UserDefaults.standard

    // Static so they can be called before every stored property is initialised. As
    // instance methods they could not be, which forced init() to assign each property
    // twice — and the second assignment fired didSet, persisting every default.
    private static func int(_ k: String, _ fallback: Int) -> Int {
        let d = UserDefaults.standard
        return d.object(forKey: k) == nil ? fallback : d.integer(forKey: k)
    }
    private static func bool(_ k: String, _ fallback: Bool) -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: k) == nil ? fallback : d.bool(forKey: k)
    }

    // MARK: Lifecycle / arming

    /// Seconds to keep the lock after the last session goes idle.
    var gracePeriod: Int {
        didSet { d.set(gracePeriod, forKey: "gracePeriod") }
    }
    /// A session with no heartbeat for this long is presumed dead and reaped.
    /// This is the safety net for an agent that is kill -9'd mid-turn.
    var sessionTTL: Int {
        didSet { d.set(sessionTTL, forKey: "sessionTTL") }
    }

    // MARK: Guardrails

    var batteryFloor: Int {
        didSet { d.set(batteryFloor, forKey: "batteryFloor") }
    }
    var acPowerOnly: Bool {
        didSet { d.set(acPowerOnly, forKey: "acPowerOnly") }
    }
    var yieldOnLowPowerMode: Bool {
        didSet { d.set(yieldOnLowPowerMode, forKey: "yieldOnLowPowerMode") }
    }

    /// Hard ceiling on how long the lock may be held while the lid is shut, in minutes.
    /// The thermal guardrail assumes airflow; a Mac pinned awake in a closed bag is the
    /// failure mode that actually causes damage, and nothing else catches it.
    var maxLidClosedMinutes: Int {
        didSet { d.set(maxLidClosedMinutes, forKey: "maxLidClosedMinutes") }
    }
    var maxLidClosedEnabled: Bool {
        didSet { d.set(maxLidClosedEnabled, forKey: "maxLidClosedEnabled") }
    }

    // MARK: Power behaviour

    /// Use the root-gated SleepDisabled setting so the Mac survives lid close.
    /// Without this, only idle sleep is prevented (lid-open only).
    var lidCloseCoverage: Bool {
        didSet { d.set(lidCloseCoverage, forKey: "lidCloseCoverage") }
    }
    /// Blank the internal panel as soon as an agent starts working.
    var blankDisplayOnWork: Bool {
        didSet { d.set(blankDisplayOnWork, forKey: "blankDisplayOnWork") }
    }

    // MARK: Fallback detection

    var processFallbackEnabled: Bool {
        didSet { d.set(processFallbackEnabled, forKey: "processFallbackEnabled") }
    }
    /// Matched as case-insensitive substrings against the full executable path.
    var processWhitelist: [String] {
        didSet { d.set(processWhitelist, forKey: "processWhitelist") }
    }
    /// Cores-busy threshold above which a fallback process counts as active.
    var processCPUThreshold: Double {
        didSet { d.set(processCPUThreshold, forKey: "processCPUThreshold") }
    }

    // MARK: Feedback

    var chimesEnabled: Bool {
        didSet { d.set(chimesEnabled, forKey: "chimesEnabled") }
    }
    var notificationsEnabled: Bool {
        didSet { d.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    var hotkeyEnabled: Bool {
        didSet { d.set(hotkeyEnabled, forKey: "hotkeyEnabled") }
    }

    /// Agents with no usable lifecycle hooks, covered by process activity instead.
    static let defaultWhitelist = [
        "Cursor Helper", "cline", "windsurf", "codeium", "continue",
        "aider", "gemini", "copilot",
        "llama-server", "ollama", "mlx", "comfy",
    ]

    /// Existing installs have the whitelist frozen at the defaults of whichever version
    /// first wrote it. Fold in entries added since, once, without touching anything the
    /// user removed or added themselves after that point.
    private static func migratedWhitelist(_ d: UserDefaults) -> [String] {
        guard var stored = d.stringArray(forKey: "processWhitelist") else { return defaultWhitelist }
        let version = 1
        guard d.integer(forKey: "whitelistVersion") < version else { return stored }
        stored.append(contentsOf: defaultWhitelist.filter { !stored.contains($0) })
        d.set(stored, forKey: "processWhitelist")
        d.set(version, forKey: "whitelistVersion")
        return stored
    }

    private init() {
        // Assign each property exactly once. A second assignment inside init() fires
        // didSet, which persisted every default on first launch — and a persisted
        // whitelist can never pick up agents added in a later version.
        maxLidClosedMinutes  = Preferences.int("maxLidClosedMinutes", 120)
        maxLidClosedEnabled  = Preferences.bool("maxLidClosedEnabled", true)
        gracePeriod          = Preferences.int("gracePeriod", 45)
        sessionTTL           = Preferences.int("sessionTTL", 300)
        batteryFloor         = Preferences.int("batteryFloor", 20)
        acPowerOnly          = Preferences.bool("acPowerOnly", false)
        yieldOnLowPowerMode  = Preferences.bool("yieldOnLowPowerMode", true)
        lidCloseCoverage     = Preferences.bool("lidCloseCoverage", true)
        blankDisplayOnWork   = Preferences.bool("blankDisplayOnWork", false)
        processFallbackEnabled = Preferences.bool("processFallbackEnabled", true)
        processWhitelist     = Preferences.migratedWhitelist(UserDefaults.standard)
        processCPUThreshold  = UserDefaults.standard.object(forKey: "processCPUThreshold") as? Double ?? 0.25
        chimesEnabled        = Preferences.bool("chimesEnabled", true)
        notificationsEnabled = Preferences.bool("notificationsEnabled", true)
        hotkeyEnabled        = Preferences.bool("hotkeyEnabled", true)
    }
}

/// Everything Lucid owns lives under ~/.lucid (mode 0700).
enum AppPaths {
    static let dir: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lucid")
        try? FileManager.default.createDirectory(
            at: u, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return u
    }()
    static var socket: URL { dir.appendingPathComponent("agent.sock") }
    /// Written while SleepDisabled is engaged. Its presence at launch means we crashed.
    static var armMarker: URL { dir.appendingPathComponent("armed") }
    /// Live state mirror, rewritten on every transition. Read-only for everyone else.
    static var status: URL { dir.appendingPathComponent("status.json") }
    /// Append-only record of completed sessions, for the history view.
    static var history: URL { dir.appendingPathComponent("history.json") }
    /// Holds the pre-dim brightness while the panel is dimmed, so a crash while dimmed
    /// can be undone on the next launch.
    static var dimmedBrightness: URL { dir.appendingPathComponent("brightness") }
    static let sudoersFile = "/etc/sudoers.d/lucid"
}

/// Launch at login via a plain LaunchAgent.
///
/// Deliberately not SMAppService.mainApp: its designated requirement is the code's cdhash,
/// which changes on every ad-hoc rebuild, so registrations go stale and pile up duplicates
/// in BTM. A LaunchAgent plist involves no signing identity at all.
enum LoginItem {
    static let label = "com.lucid.app"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// The executable inside the running .app bundle, so a moved bundle re-registers
    /// correctly the next time the toggle is flipped.
    static var executablePath: String? {
        Bundle.main.executableURL?.path
    }

    /// True only if the agent exists AND still points at a binary that is there. A plist
    /// left behind by a translocated or since-deleted bundle would otherwise report as
    /// enabled forever while silently failing at every login.
    static var isEnabled: Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String], let exe = args.first
        else { return false }
        return FileManager.default.isExecutableFile(atPath: exe)
    }

    /// Non-nil when launch at login cannot work from where the app currently is.
    static var blockedReason: String? {
        InstallLocation.isTranslocated ? InstallLocation.advice : nil
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        let fm = FileManager.default
        guard on else {
            _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
            try? fm.removeItem(at: plistURL)
            return true
        }

        // Refuse to record a path that will not exist next login. A translocated bundle
        // runs from a randomised mount that is destroyed on quit.
        guard InstallLocation.isStable else { return false }
        guard let exe = executablePath else { return false }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            // Restart on a crash, never after a clean quit: SuccessfulExit false means
            // "keep alive only if it exited badly", so Quit from the menu still means quit.
            // ThrottleInterval bounds a crash loop if the failure is deterministic.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 30,
            "ProcessType": "Interactive",
        ]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0) else { return false }

        try? fm.createDirectory(at: plistURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        do { try data.write(to: plistURL, options: .atomic) } catch { return false }

        // Re-register so the change takes effect without a logout.
        _ = runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        return runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }
}

import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import UserNotifications
import os

private let log = Logger(subsystem: "com.lucid.app", category: "notify")

// Carbon hands us a bare C callback, so the target has to live at file scope.
nonisolated(unsafe) private var gHotKeyAction: (() -> Void)?

private func hotKeyEventHandler(_ next: EventHandlerCallRef?,
                                _ event: EventRef?,
                                _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    DispatchQueue.main.async { gHotKeyAction?() }
    return noErr
}

enum AppEvent {
    case lockEngaged
    case sessionComplete
    case guardrailTripped(YieldReason)
    /// The lid-closed cap is about to release the lock, with this many minutes left.
    case lidCapWarning(minutes: Int)
    /// Summary of a lid-closed run, delivered when the lid opens.
    case awayReport(String)

    var title: String {
        switch self {
        case .lockEngaged:      return "Wake lock engaged"
        case .sessionComplete:  return "Session complete"
        case .guardrailTripped: return "Wake lock released"
        case .lidCapWarning:    return "Time cap approaching"
        case .awayReport:       return "While you were away"
        }
    }

    var body: String {
        switch self {
        case .lockEngaged:          return "An agent is working. This Mac will stay awake."
        case .sessionComplete:      return "All agents are idle. This Mac can sleep."
        case let .guardrailTripped(r): return r.summary
        case let .lidCapWarning(m):
            return m == 1
                ? "The lid has been shut close to the limit. The lock releases in about a minute."
                : "The lid has been shut close to the limit. The lock releases in about \(m) minutes."
        case let .awayReport(h): return h
        }
    }

    /// Built-in system sounds — no bundled audio assets needed.
    var sound: String? {
        switch self {
        case .lockEngaged:      return "Funk"
        case .sessionComplete:  return "Glass"
        case .guardrailTripped: return "Basso"
        case .lidCapWarning:    return "Basso"
        case .awayReport:       return "Glass"
        }
    }

    /// Routine engage/release is the chatty pair — everything else is an interruption
    /// the user asked for, and is never coalesced away.
    var isRoutine: Bool {
        switch self {
        case .lockEngaged, .sessionComplete: return true
        default: return false
        }
    }
}

/// Global hotkey, system chimes and notification banners.
@Observable
@MainActor
final class NotificationManager {

    private(set) var hotKeyRegistered = false
    private(set) var hotKeyError: String?
    private(set) var notificationsAuthorized = false

    /// Invoked when the user presses the global shortcut.
    var onToggle: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var lastRoutineAt: Date = .distantPast

    private let prefs = Preferences.shared

    init() {
        gHotKeyAction = { [weak self] in self?.onToggle?() }
        if prefs.hotkeyEnabled { registerHotKey() }
        requestNotificationAuthorization()
    }

    // MARK: - Global hotkey (Option-Command-L)

    /// Carbon's RegisterEventHotKey needs no permission at all. The AppKit alternative,
    /// NSEvent.addGlobalMonitorForEvents, would require an Accessibility (TCC) grant.
    func registerHotKey() {
        guard hotKeyRef == nil else { return }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(),
                                                hotKeyEventHandler, 1, &spec, nil, &handlerRef)
        guard installStatus == noErr else {
            hotKeyError = "Could not install the hotkey handler (\(installStatus))"
            return
        }

        let id = EventHotKeyID(signature: OSType(0x4C444149), id: 1)  // 'LDAI'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_L),
                                         UInt32(optionKey | cmdKey),
                                         id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
            hotKeyRegistered = true
            hotKeyError = nil
            log.info("registered hotkey Option-Command-L")
        } else {
            // Almost always means another app already owns the combination.
            hotKeyError = "Option-Command-L is already taken by another app (\(status))"
            hotKeyRegistered = false
            log.error("RegisterEventHotKey failed: \(status)")
        }
    }

    func unregisterHotKey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        hotKeyRegistered = false
    }

    func setHotKeyEnabled(_ on: Bool) {
        on ? registerHotKey() : unregisterHotKey()
    }

    // MARK: - Banners and chimes

    private func requestNotificationAuthorization() {
        // UNUserNotificationCenter needs a real bundle identity; from a bare binary
        // currentNotificationCenter() throws. Degrade to chimes only.
        guard Bundle.main.bundleIdentifier != nil else {
            log.notice("no bundle identifier — notifications disabled, chimes still work")
            return
        }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, err in
                Task { @MainActor in
                    self?.notificationsAuthorized = granted
                    if let err { log.error("notification auth: \(err.localizedDescription, privacy: .public)") }
                }
            }
    }

    func post(_ event: AppEvent) {
        // A chatty agent can flip working/idle several times a second. Coalesce those,
        // but only those: the old rule was a blanket 2s window, so a guardrail trip that
        // landed just after a routine engage was silently dropped.
        let now = Date()
        if event.isRoutine {
            guard now.timeIntervalSince(lastRoutineAt) > 2.0 else { return }
            lastRoutineAt = now
        }

        if prefs.chimesEnabled, let name = event.sound {
            NSSound(named: name)?.play()
        }

        guard prefs.notificationsEnabled,
              notificationsAuthorized,
              Bundle.main.bundleIdentifier != nil else { return }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body

        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // No deinit: the hotkey registration is process-lifetime and Carbon tears it down
    // with the app.
}

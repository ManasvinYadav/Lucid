import CoreGraphics
import Foundation

/// Panel brightness, via DisplayServices.
///
/// Needed because `pmset displaysleepnow` is only a request: any process holding a
/// display assertion — a browser playing video is the common one — overrides it and the
/// panel stays lit. Normally closing the lid resolves that, but the whole point of this
/// app is to veto the sleep that closing the lid would cause, so the override never
/// arrives and the panel burns inside a shut lid.
///
/// Dimming is a fallback, not the first move, and it is always recoverable: the physical
/// brightness keys keep working, the previous value is written to disk before dimming,
/// and it is restored on lid open, on disarm, on exit and on the next launch after a
/// crash.
enum DisplayBrightness {

    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_LAZY)

    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    static var isAvailable: Bool {
        guard let h = handle else { return false }
        return dlsym(h, "DisplayServicesGetBrightness") != nil
            && dlsym(h, "DisplayServicesSetBrightness") != nil
    }

    // The built-in panel, never CGMainDisplayID(): with the lid shut on a dock, the main
    // display is the external monitor the user is working on.
    static func read() -> Float? {
        guard let h = handle, let p = dlsym(h, "DisplayServicesGetBrightness"),
              let id = PowerManager.builtinDisplay else { return nil }
        var v: Float = 0
        return unsafeBitCast(p, to: GetFn.self)(id, &v) == 0 ? v : nil
    }

    @discardableResult
    static func write(_ v: Float) -> Bool {
        guard let h = handle, let p = dlsym(h, "DisplayServicesSetBrightness"),
              let id = PowerManager.builtinDisplay else { return false }
        return unsafeBitCast(p, to: SetFn.self)(id, max(0, min(1, v))) == 0
    }

    /// True while we are holding the panel dark.
    static var isDimmed: Bool {
        FileManager.default.fileExists(atPath: AppPaths.dimmedBrightness.path)
    }

    /// Records the current brightness, then takes the panel to zero. No-op if already dimmed.
    @discardableResult
    static func dim() -> Bool {
        guard !isDimmed, let current = read(), current > 0 else { return false }
        // Write the old value BEFORE dimming, so a crash mid-call is still recoverable.
        // No record, no dimming: nothing could restore the panel afterwards.
        do {
            try "\(current)".write(to: AppPaths.dimmedBrightness, atomically: true, encoding: .utf8)
        } catch { return false }
        guard write(0) else {
            try? FileManager.default.removeItem(at: AppPaths.dimmedBrightness)
            return false
        }
        return true
    }

    /// Puts back whatever brightness was recorded. Safe to call when not dimmed.
    @discardableResult
    static func restore() -> Bool {
        guard let text = try? String(contentsOf: AppPaths.dimmedBrightness, encoding: .utf8),
              let v = Float(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        // The record goes only once the value is back; if the panel is offline right now
        // it is retried on the next lid open or launch.
        guard write(v) else { return false }
        try? FileManager.default.removeItem(at: AppPaths.dimmedBrightness)
        return true
    }
}

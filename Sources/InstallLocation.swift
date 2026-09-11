import Foundation
import Security

/// Where the app is running from, and whether that location is real.
///
/// macOS runs a quarantined app from a randomised read-only mount ("App Translocation")
/// until the user moves the bundle in Finder. That path is destroyed on quit, so anything
/// recorded from it — a LaunchAgent's ProgramArguments, an "app is here" instruction —
/// points at nothing the next time. Dragging out of a DMG to /Applications is a move, so
/// this only affects launching straight from the disk image or Downloads.
enum InstallLocation {

    /// `SecTranslocateIsTranslocatedURL` is declared in Security's headers but is not
    /// exposed to Swift, so it is resolved at runtime. The path check is the fallback,
    /// and is what actually fires on the versions where the symbol is absent.
    static var isTranslocated: Bool {
        typealias Fn = @convention(c)
            (CFURL, UnsafeMutablePointer<DarwinBoolean>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),   // RTLD_DEFAULT
                           "SecTranslocateIsTranslocatedURL") {
            var out = DarwinBoolean(false)
            if unsafeBitCast(sym, to: Fn.self)(
                Bundle.main.bundleURL as CFURL, &out, nil).boolValue {
                return out.boolValue
            }
        }
        return Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    static var isInApplications: Bool {
        let p = Bundle.main.bundlePath
        return p.hasPrefix("/Applications/")
            || p.hasPrefix(NSString(string: "~/Applications/").expandingTildeInPath)
    }

    /// True when the bundle sits somewhere stable enough to record its path.
    static var isStable: Bool { !isTranslocated }

    static var advice: String {
        isTranslocated
            ? "Lucid is running from a temporary location. Move it to your Applications folder and open it again."
            : ""
    }
}

import AppKit
import ServiceManagement

/// Wraps `SMAppService.mainApp` so launch-at-login works for the packaged `.app`
/// (DMG → /Applications). Errors are surfaced instead of swallowed; status is
/// re-synced on launch because ad-hoc rebuilds invalidate prior BTM registrations.
enum LaunchAtLogin {
    enum Status: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
        case unavailable

        var label: String {
            switch self {
            case .enabled: return "Will open at login"
            case .requiresApproval: return "Waiting for approval in System Settings → General → Login Items"
            case .notRegistered: return "Not registered"
            case .notFound: return "Login item not found (re-save after installing to /Applications)"
            case .unavailable: return "Unavailable (run the packaged app, not swift run)"
            }
        }
    }

    struct Result: Equatable {
        var status: Status
        var errorMessage: String?
        var installHint: String?
    }

    static var currentStatus: Status {
        status(of: SMAppService.mainApp.status)
    }

    /// True when Bundle.main is a real `.app` (not `swift run` / bare binary).
    static var isPackagedApp: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    /// True when running from a DMG / App Translocation copy — login items would
    /// point at a path that disappears after eject.
    static var isTransientInstall: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }

    static func installHint(bundlePath: String = Bundle.main.bundlePath) -> String? {
        if bundlePath.contains("/AppTranslocation/") || bundlePath.hasPrefix("/Volumes/") {
            return "Copy agentNotch.app to /Applications, open it from there, then enable again."
        }
        if !bundlePath.lowercased().hasSuffix(".app") && !bundlePath.lowercased().contains(".app/") {
            return "Launch at login needs the packaged .app (./scripts/package-app.sh), not swift run."
        }
        return nil
    }

    /// Apply desired on/off. Idempotent: skips register/unregister when already correct.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result {
        let service = SMAppService.mainApp
        let before = status(of: service.status)
        let hint = enabled ? installHint() : nil

        do {
            if enabled {
                switch before {
                case .enabled, .requiresApproval:
                    break
                case .notRegistered, .notFound, .unavailable:
                    try service.register()
                }
            } else {
                switch before {
                case .notRegistered, .unavailable:
                    break
                case .enabled, .requiresApproval, .notFound:
                    try service.unregister()
                }
            }
            return Result(status: status(of: service.status), errorMessage: nil, installHint: hint)
        } catch {
            return Result(
                status: status(of: service.status),
                errorMessage: error.localizedDescription,
                installHint: hint)
        }
    }

    /// Re-apply config after launch / reinstall. No-op when disabled or not packaged.
    @discardableResult
    static func sync(enabled: Bool) -> Result {
        guard enabled else {
            return Result(status: currentStatus, errorMessage: nil, installHint: nil)
        }
        guard isPackagedApp else {
            return Result(
                status: .unavailable,
                errorMessage: nil,
                installHint: installHint())
        }
        return setEnabled(true)
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func status(of raw: SMAppService.Status) -> Status {
        switch raw {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unavailable
        }
    }
}

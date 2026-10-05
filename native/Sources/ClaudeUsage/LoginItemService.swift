import Foundation
import ServiceManagement

enum LoginItemService {
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound:
            return false
        @unknown default:
            return false
        }
    }

    static var statusMessage: String? {
        switch SMAppService.mainApp.status {
        case .requiresApproval:
            return "macOS is waiting for approval."
        case .notFound where !isBundledApp:
            return "Available in the installed app."
        case .enabled, .notRegistered, .notFound:
            return nil
        @unknown default:
            return nil
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    private static var isBundledApp: Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let macos = executable.deletingLastPathComponent()
        let contents = macos.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        return macos.lastPathComponent == "MacOS"
            && contents.lastPathComponent == "Contents"
            && bundle.pathExtension == "app"
    }
}

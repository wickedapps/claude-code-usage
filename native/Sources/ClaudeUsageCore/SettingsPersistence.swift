import Darwin
import Foundation

public enum SettingsPersistence {
    public static func load(bundleID: String) -> AppSettings {
        load(bundleID: bundleID, environment: ProcessInfo.processInfo.environment)
    }

    public static func save(_ settings: AppSettings, bundleID: String) throws {
        try save(settings, bundleID: bundleID, environment: ProcessInfo.processInfo.environment)
    }

    static func load(bundleID: String, environment: [String: String]) -> AppSettings {
        guard let file = settingsFileURL(bundleID: bundleID, environment: environment) else {
            return AppSettings()
        }
        return load(from: file)
    }

    static func save(_ settings: AppSettings, bundleID: String, environment: [String: String]) throws {
        guard let file = settingsFileURL(bundleID: bundleID, environment: environment) else {
            throw SettingsSaveError.noHome
        }
        try save(settings, to: file)
    }

    static func load(from file: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !hasNullValue(json, keys: ["menu_bar", "start_hidden", "refresh"]) else {
            return AppSettings()
        }
        if let menu = json["menu_bar"] as? [String: Any],
           hasNullValue(menu, keys: ["show_five_hour", "show_seven_day", "percent", "show_labels", "show_reset"]) {
            return AppSettings()
        }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    static func save(_ settings: AppSettings, to file: URL) throws {
        let directory = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SettingsSaveError.createDirectory(directory.path, error.localizedDescription)
        }

        let json = encode(settings)
        let temporary = file.deletingPathExtension().appendingPathExtension("json.tmp")
        do {
            try Data(json.utf8).write(to: temporary, options: [])
        } catch {
            throw SettingsSaveError.write(temporary.path, error.localizedDescription)
        }

        let replaced = temporary.path.withCString { temporaryPath in
            file.path.withCString { destinationPath in
                rename(temporaryPath, destinationPath)
            }
        }
        if replaced != 0 {
            throw SettingsSaveError.replace(file.path, String(cString: strerror(errno)))
        }
    }

    static func settingsFileURL(bundleID: String, environment: [String: String]) -> URL? {
        guard let home = environment["HOME"] else { return nil }
        let homeURL = URL(fileURLWithPath: home, isDirectory: !home.isEmpty)
        return homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    /// The layout earlier releases wrote: two-space indent, fixed field order, no space before the colon.
    static func encode(_ settings: AppSettings) -> String {
        let menu = settings.menuBar
        let lines = [
            "{",
            "  \"menu_bar\": {",
            "    \"show_five_hour\": \(jsonBool(menu.showFiveHour)),",
            "    \"show_seven_day\": \(jsonBool(menu.showSevenDay)),",
            "    \"percent\": \"\(menu.percent.rawValue)\",",
            "    \"show_labels\": \(jsonBool(menu.showLabels)),",
            "    \"show_reset\": \(jsonBool(menu.showReset))",
            "  },",
            "  \"start_hidden\": \(jsonBool(settings.startHidden)),",
            "  \"refresh\": \"\(settings.refresh.rawValue)\"",
            "}",
        ]
        return lines.joined(separator: "\n")
    }

    private static func jsonBool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    /// A present field set to null resets the file to defaults, as earlier releases did.
    /// `JSONDecoder` treats that null as missing, so reject it before decoding.
    private static func hasNullValue(_ object: [String: Any], keys: [String]) -> Bool {
        keys.contains { object[$0] is NSNull }
    }
}

enum SettingsSaveError: LocalizedError {
    case noHome
    case createDirectory(String, String)
    case write(String, String)
    case replace(String, String)

    var errorDescription: String? {
        switch self {
        case .noHome:
            return "No home directory to save settings in"
        case .createDirectory(let path, let detail):
            return "Could not create \(path): \(detail)"
        case .write(let path, let detail):
            return "Could not write \(path): \(detail)"
        case .replace(let path, let detail):
            return "Could not save \(path): \(detail)"
        }
    }
}

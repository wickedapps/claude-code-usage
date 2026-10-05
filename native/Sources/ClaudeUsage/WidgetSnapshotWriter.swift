import Foundation
import ClaudeUsageCore
import WidgetKit

@MainActor
enum WidgetSnapshotWriter {
    private static let filename = "widget-snapshot.json"
    private static let version = 1
    private static var lastDisplay: Data?
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func sync(_ store: UsageStore) {
        guard !store.isDemo else { return }
        guard let groupID = appGroupID,
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        else { return }

        guard let file = try? encodedSnapshot(store), let signature = try? displaySignature(store) else { return }
        do {
            try writeIfChanged(file, to: directory.appendingPathComponent(filename))
        } catch {
            return
        }
        guard signature != lastDisplay else { return }
        lastDisplay = signature
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static var appGroupID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func encodedSnapshot(_ store: UsageStore) throws -> Data {
        try encoder.encode(makeSnapshot(store))
    }

    static func displaySignature(_ store: UsageStore) throws -> Data {
        var snapshot = makeSnapshot(store)
        snapshot.updatedAt = nil
        return try encoder.encode(snapshot)
    }

    private static func makeSnapshot(_ store: UsageStore) -> Snapshot {
        let mode = store.settings.menuBar.percent.rawValue
        switch store.state {
        case .signedOut:
            return Snapshot.empty("signed_out", mode)
        case .apiBilling:
            return Snapshot.empty("api_billing", mode)
        case .expired:
            return Snapshot.empty("expired", mode)
        case .loading, .ready, .cliMissing, .unavailable:
            break
        }
        if store.limitsError != nil {
            return Snapshot.empty("unavailable", mode)
        }
        guard let limits = store.limits else {
            let state = store.loading || store.state == .loading ? "loading" : "unavailable"
            return Snapshot.empty(state, mode)
        }
        if limits.isEmpty {
            return Snapshot.empty("no_limits", mode)
        }
        var windows: [Window] = []
        for (kind, window) in limits.shown(store.settings.menuBar) {
            let name: String
            switch kind {
            case .fiveHour: name = "five_hour"
            case .sevenDay: name = "seven_day"
            }
            windows.append(Window(
                kind: name,
                used: window.used,
                remaining: window.remaining,
                resetsAt: window.resetsAt.map { timestamp.string(from: $0) }
            ))
        }
        return Snapshot(
            schemaVersion: version,
            state: "ready",
            updatedAt: store.limitsUpdatedAt.map { timestamp.string(from: $0) },
            percentMode: mode,
            windows: windows
        )
    }

    private static func writeIfChanged(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), existing == data { return }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(filename + ".tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}

private struct Snapshot: Encodable {
    var schemaVersion: Int
    var state: String
    var updatedAt: String?
    var percentMode: String
    var windows: [Window]

    static func empty(_ state: String, _ percentMode: String) -> Snapshot {
        Snapshot(schemaVersion: 1, state: state, updatedAt: nil, percentMode: percentMode, windows: [])
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case state
        case updatedAt = "updated_at"
        case percentMode = "percent_mode"
        case windows
    }
}

private struct Window: Encodable {
    var kind: String
    var used: Double
    var remaining: Double
    var resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case kind, used, remaining
        case resetsAt = "resets_at"
    }
}

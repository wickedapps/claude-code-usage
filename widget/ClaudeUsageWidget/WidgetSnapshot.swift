import Foundation

let widgetSnapshotVersion = 1
let widgetSnapshotFilename = "widget-snapshot.json"

enum WidgetSnapshotState: String, Decodable, Equatable {
  case loading
  case ready
  case signedOut = "signed_out"
  case unavailable
}

enum WidgetPercentMode: String, Decodable, Equatable {
  case left
  case used
}

enum WidgetWindowKind: String, Decodable, Equatable {
  case fiveHour = "five_hour"
  case sevenDay = "seven_day"

  var label: String {
    switch self {
    case .fiveHour: "5-hour"
    case .sevenDay: "Weekly"
    }
  }
}

struct WidgetQuotaWindow: Decodable, Equatable {
  let kind: WidgetWindowKind
  let used: Double
  let remaining: Double
  let resetsAt: Date?

  enum CodingKeys: String, CodingKey {
    case kind, used, remaining
    case resetsAt = "resets_at"
  }

  func percentage(for mode: WidgetPercentMode) -> Double {
    switch mode {
    case .left: remaining
    case .used: used
    }
  }

  func percentageLabel(for mode: WidgetPercentMode) -> String {
    let suffix = mode == .left ? "left" : "used"
    return String(format: "%.0f%% %@", percentage(for: mode), suffix)
  }

  var level: WidgetQuotaLevel {
    if remaining <= 10 {
      .danger
    } else if remaining <= 30 {
      .warning
    } else {
      .healthy
    }
  }

  func resetStatus(at date: Date) -> WidgetResetStatus {
    guard let resetsAt else {
      return kind == .fiveHour ? .startsWithMessage : .unknown
    }
    return resetsAt <= date ? .due : .countdown(resetsAt)
  }
}

enum WidgetQuotaLevel: Equatable {
  case healthy
  case warning
  case danger
}

enum WidgetResetStatus: Equatable {
  case startsWithMessage
  case unknown
  case due
  case countdown(Date)
}

struct WidgetSnapshot: Decodable, Equatable {
  let schemaVersion: Int
  let state: WidgetSnapshotState
  let updatedAt: Date?
  let percentMode: WidgetPercentMode
  let windows: [WidgetQuotaWindow]

  enum CodingKeys: String, CodingKey {
    case state, windows
    case schemaVersion = "schema_version"
    case updatedAt = "updated_at"
    case percentMode = "percent_mode"
  }

  func age(at date: Date) -> TimeInterval? {
    updatedAt.map { max(0, date.timeIntervalSince($0)) }
  }
}

enum WidgetSnapshotLoad: Equatable {
  case missing
  case corrupt
  case snapshot(WidgetSnapshot)

  static func decode(_ data: Data?) -> Self {
    guard let data else {
      return .missing
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
      snapshot.schemaVersion == widgetSnapshotVersion
    else {
      return .corrupt
    }
    return .snapshot(snapshot)
  }

  static func read(appGroupID: String?) -> Self {
    guard let appGroupID,
      !appGroupID.isEmpty,
      let container = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    else {
      return .missing
    }
    let url = container.appendingPathComponent(widgetSnapshotFilename)
    return decode(try? Data(contentsOf: url))
  }

  var snapshot: WidgetSnapshot? {
    guard case .snapshot(let snapshot) = self else {
      return nil
    }
    return snapshot
  }
}

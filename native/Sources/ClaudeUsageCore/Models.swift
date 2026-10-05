import Foundation

public enum PercentMode: String, Codable, CaseIterable { case left, used }
public enum RefreshRate: String, Codable, CaseIterable {
    case oneMinute = "one_minute", fiveMinutes = "five_minutes", fifteenMinutes = "fifteen_minutes"
    public var interval: TimeInterval { self == .oneMinute ? 60 : self == .fiveMinutes ? 300 : 900 }
    public var label: String { self == .oneMinute ? "1 minute" : self == .fiveMinutes ? "5 minutes" : "15 minutes" }
}
public struct MenuBarSettings: Codable, Equatable {
    public var showFiveHour = true, showSevenDay = true, percent: PercentMode = .left, showLabels = true, showReset = false
    public init() {}
    enum CodingKeys: String, CodingKey { case showFiveHour = "show_five_hour", showSevenDay = "show_seven_day", percent, showLabels = "show_labels", showReset = "show_reset" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showFiveHour = try c.decodeIfPresent(Bool.self, forKey: .showFiveHour) ?? true
        showSevenDay = try c.decodeIfPresent(Bool.self, forKey: .showSevenDay) ?? true
        percent = try c.decodeIfPresent(PercentMode.self, forKey: .percent) ?? .left
        showLabels = try c.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
        showReset = try c.decodeIfPresent(Bool.self, forKey: .showReset) ?? false
    }
}
public struct AppSettings: Codable, Equatable {
    public var menuBar = MenuBarSettings(), startHidden = false, refresh: RefreshRate = .fiveMinutes
    public init() {}
    enum CodingKeys: String, CodingKey { case menuBar = "menu_bar", startHidden = "start_hidden", refresh }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menuBar = try c.decodeIfPresent(MenuBarSettings.self, forKey: .menuBar) ?? MenuBarSettings()
        startHidden = try c.decodeIfPresent(Bool.self, forKey: .startHidden) ?? false
        refresh = try c.decodeIfPresent(RefreshRate.self, forKey: .refresh) ?? .fiveMinutes
    }
}
public struct TokenCounts: Equatable {
    public var input: UInt64, output: UInt64, cacheCreate: UInt64, cacheRead: UInt64
    public init(input: UInt64 = 0, output: UInt64 = 0, cacheCreate: UInt64 = 0, cacheRead: UInt64 = 0) { self.input = input; self.output = output; self.cacheCreate = cacheCreate; self.cacheRead = cacheRead }
    public var total: UInt64 { input + output + cacheCreate + cacheRead }
    public mutating func add(_ other: TokenCounts) { input += other.input; output += other.output; cacheCreate += other.cacheCreate; cacheRead += other.cacheRead }
}
public struct UsageRow: Identifiable, Equatable {
    public var id: String, title: String, detail: String, tokens: TokenCounts, active: Bool
    public init(id: String, title: String, detail: String, tokens: TokenCounts, active: Bool = false) { self.id = id; self.title = title; self.detail = detail; self.tokens = tokens; self.active = active }
}
public enum UsageTab: String, CaseIterable { case daily = "Daily", weekly = "Weekly", monthly = "Monthly", sessions = "Session", blocks = "5h Block" }
public struct UsageReport: Equatable {
    public var daily: [UsageRow] = [], weekly: [UsageRow] = [], monthly: [UsageRow] = [], sessions: [UsageRow] = [], blocks: [UsageRow] = []
    /// Hourly ledger behind the range-based dashboard, oldest first. See `summary(_:now:timeZone:)`.
    public var samples: [UsageSample] = []
    public init() {}
    public func rows(for tab: UsageTab) -> [UsageRow] { switch tab { case .daily: return daily; case .weekly: return weekly; case .monthly: return monthly; case .sessions: return sessions; case .blocks: return blocks } }
}
public enum QuotaKind: String, CaseIterable { case fiveHour = "five_hour", sevenDay = "seven_day"
    public var label: String { self == .fiveHour ? "5-hour" : "Weekly" }
    public var shortLabel: String { self == .fiveHour ? "5h" : "7d" }
    /// Full length of the rolling window, for pace estimates.
    public var duration: TimeInterval { self == .fiveHour ? 5 * 3_600 : 7 * 86_400 }
}
public struct QuotaWindow: Equatable {
    public var used: Double, resetsAt: Date?
    public init(used: Double, resetsAt: Date? = nil) { self.used = used; self.resetsAt = resetsAt }
    public var remaining: Double { max(0, min(100, 100 - used)) }
    public func percentage(_ mode: PercentMode) -> Double { mode == .left ? remaining : used }
}
public struct QuotaLimits: Equatable {
    public var fiveHour: QuotaWindow?, sevenDay: QuotaWindow?
    public init(fiveHour: QuotaWindow? = nil, sevenDay: QuotaWindow? = nil) { self.fiveHour = fiveHour; self.sevenDay = sevenDay }
    public var isEmpty: Bool { fiveHour == nil && sevenDay == nil }
    public var windows: [(QuotaKind, QuotaWindow)] { [(QuotaKind.fiveHour, fiveHour), (.sevenDay, sevenDay)].compactMap { kind, value in value.map { (kind, $0) } } }
    public func shown(_ settings: MenuBarSettings) -> [(QuotaKind, QuotaWindow)] { windows.filter { $0.0 == .fiveHour ? settings.showFiveHour : settings.showSevenDay } }
}
public enum SessionState: String { case loading, ready, cliMissing, signedOut, expired, apiBilling, unavailable }
public struct SessionResult {
    public var state: SessionState, accountLabel: String?, limits: QuotaLimits?, error: String?
    public init(state: SessionState, accountLabel: String? = nil, limits: QuotaLimits? = nil, error: String? = nil) { self.state = state; self.accountLabel = accountLabel; self.limits = limits; self.error = error }
}
public func resetDescription(_ date: Date?, now: Date = Date(), fiveHour: Bool = false) -> String {
    guard let date else { return fiveHour ? "Starts with your next message" : "Reset time unavailable" }
    let seconds = Int(date.timeIntervalSince(now)); if seconds <= 0 { return "Reset due" }
    let minutes = seconds / 60; let hours = minutes / 60; let days = hours / 24
    if days > 0 { return "\(days)d \(hours % 24)h" }
    if hours > 0 { return "\(hours)h \(minutes % 60)m" }
    return "\(max(1, minutes))m"
}

/// Token use for one session, project, and model inside one UTC hour.
public struct UsageSample: Equatable {
    /// Start of the UTC hour the turns landed in.
    public var hour: Date
    public var sessionID: String
    /// Last path component of the session's cwd; empty when unknown.
    public var project: String
    /// Short model label (`opus-5-5`, `sonnet-4-5`); `unknown` when the line had none.
    public var model: String
    public var tokens: TokenCounts
    public init(hour: Date, sessionID: String, project: String, model: String, tokens: TokenCounts) { self.hour = hour; self.sessionID = sessionID; self.project = project; self.model = model; self.tokens = tokens }
}
public enum UsageRange: String, CaseIterable, Codable {
    case day = "24h", week = "7d", month = "30d", quarter = "90d"
    public var label: String { switch self { case .day: return "Past 24h"; case .week: return "7 days"; case .month: return "30 days"; case .quarter: return "90 days" } }
    /// Hourly points for the past day, local calendar days otherwise.
    public var hourly: Bool { self == .day }
}
public struct UsageSeriesPoint: Identifiable, Equatable {
    public var start: Date
    public var tokens: TokenCounts
    /// Total tokens per short model label within this bucket.
    public var byModel: [String: UInt64]
    public var id: Date { start }
    public init(start: Date, tokens: TokenCounts = TokenCounts(), byModel: [String: UInt64] = [:]) { self.start = start; self.tokens = tokens; self.byModel = byModel }
}
public struct UsageBreakdownRow: Identifiable, Equatable {
    public var id: String, title: String, sessions: Int, tokens: TokenCounts
    /// Fraction of the range's total tokens, 0...1.
    public var share: Double
    public init(id: String, title: String, sessions: Int, tokens: TokenCounts, share: Double) { self.id = id; self.title = title; self.sessions = sessions; self.tokens = tokens; self.share = share }
}
public struct UsageSummary: Equatable {
    public var range: UsageRange, start: Date, end: Date
    public var totals = TokenCounts()
    /// Distinct sessions with any tokens in the range.
    public var sessions = 0
    /// Zero-filled buckets from `start` to `end`, oldest first: 24 hours or N local days.
    public var series: [UsageSeriesPoint] = []
    /// Largest first.
    public var models: [UsageBreakdownRow] = []
    /// Newest first, days with tokens only. Title like `Oct 4`.
    public var days: [UsageBreakdownRow] = []
    /// Largest first. Unknown project titled `Other`.
    public var projects: [UsageBreakdownRow] = []
    public init(range: UsageRange, start: Date, end: Date) { self.range = range; self.start = start; self.end = end }
    public var isEmpty: Bool { totals.total == 0 }
}

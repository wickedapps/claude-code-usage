import Foundation
import Combine
import ClaudeUsageCore

@MainActor
final class UsageStore: ObservableObject {
    let isDemo: Bool
    let bundleID: String
    @Published var settings: AppSettings
    @Published var state: SessionState = .loading
    @Published var report: UsageReport?
    @Published var limits: QuotaLimits?
    @Published var accountLabel: String?
    @Published var loading = false
    @Published var usageError: String?
    @Published var limitsError: String?
    @Published var limitsUpdatedAt: Date?
    @Published var settingsError: String?
    @Published var loginEnabled = false
    @Published var loginMessage: String?
    /// Dashboard page and token range. Shared by the toolbar and the dashboard views.
    @Published var section: DashboardSection = .limits
    @Published var range: UsageRange = .month
    /// Window appearance. Kept in UserDefaults so settings.json keeps the format earlier releases wrote.
    @Published var appearance: AppAppearance = .system {
        didSet { if !isDemo { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) } }
    }
    private static let appearanceKey = "appearance"
    var onChange: (() -> Void)?
    private let demoNow: Date
    private var windowVisible = false
    private var lastPoll = Date.distantPast
    private var polling = false
    private var pendingRefresh = false
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(demo: Bool = false, now: Date = Date()) {
        demoNow = now
        isDemo = demo
        bundleID = Bundle.main.bundleIdentifier ?? "com.example.claude-usage"
        settings = demo ? AppSettings() : SettingsPersistence.load(bundleID: bundleID)
        if demo {
            loadDemo()
        } else {
            appearance = UserDefaults.standard.string(forKey: Self.appearanceKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
            loginEnabled = LoginItemService.isEnabled
            loginMessage = LoginItemService.statusMessage
            refresh()
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    let interval = self.windowVisible ? 60 : self.settings.refresh.interval
                    if Date().timeIntervalSince(self.lastPoll) >= interval { self.poll() }
                    self.onChange?()
                }
            }
        }
    }

    deinit { pollTask?.cancel(); refreshTask?.cancel() }

    func refresh() {
        if isDemo { loadDemo(); onChange?(); return }
        if polling { pendingRefresh = true; return }
        reload(includeTranscripts: true)
    }

    private func reload(includeTranscripts: Bool) {
        guard !loading, !polling else { return }
        loading = true
        onChange?()
        refreshTask = Task { [weak self] in
            let result = await SessionService.load()
            guard let self, !Task.isCancelled else { return }
            let shouldRead = result.state != .signedOut && result.state != .cliMissing && (includeTranscripts || self.report == nil || (self.state == .apiBilling && result.state != .apiBilling))
            var transcriptResult: Result<UsageReport, Error>?
            if shouldRead {
                do { transcriptResult = .success(try await SessionService.readTranscripts()) }
                catch { transcriptResult = .failure(error) }
            }
            guard !Task.isCancelled else { return }
            self.applySession(result, transcripts: transcriptResult)
            self.loading = false
            self.lastPoll = Date()
            self.onChange?()
        }
    }

    enum PollAction: Equatable { case full, quotas, billing }

    var pollAction: PollAction {
        switch state {
        case .ready, .expired, .unavailable: return .quotas
        case .apiBilling: return .billing
        case .loading, .signedOut, .cliMissing: return .full
        }
    }

    private func poll() {
        guard !loading, !polling else { return }
        let action = pollAction
        if action == .full { reload(includeTranscripts: true); return }
        polling = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            if action == .billing {
                let label = await SessionService.pollBillingLabel()
                self.polling = false
                self.lastPoll = Date()
                if label != self.accountLabel || self.pendingRefresh {
                    self.pendingRefresh = false
                    self.reload(includeTranscripts: true)
                }
            } else {
                let result = await SessionService.pollQuotas(accountLabel: self.accountLabel)
                guard !Task.isCancelled else { self.polling = false; return }
                self.applySession(result)
                self.polling = false
                self.lastPoll = Date()
                self.onChange?()
                if self.pendingRefresh {
                    self.pendingRefresh = false
                    self.reload(includeTranscripts: true)
                }
            }
        }
    }

    func applySession(_ result: SessionResult, transcripts: Result<UsageReport, Error>? = nil) {
        state = result.state
        accountLabel = result.accountLabel
        limits = result.limits
        limitsError = result.error
        limitsUpdatedAt = result.limits == nil ? nil : Date()
        if result.state == .signedOut || result.state == .cliMissing {
            report = nil
            usageError = nil
        } else if let transcripts {
            switch transcripts {
            case .success(let value): report = value; usageError = nil
            case .failure(let error): report = nil; usageError = error.localizedDescription
            }
        }
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        var updated = settings
        change(&updated)
        if !updated.menuBar.showFiveHour && !updated.menuBar.showSevenDay { return }
        settings = updated
        if !isDemo {
            do { try SettingsPersistence.save(settings, bundleID: bundleID); settingsError = nil }
            catch { settingsError = error.localizedDescription }
        }
        onChange?()
    }

    func setLoginEnabled(_ enabled: Bool) {
        guard !isDemo else { loginEnabled = enabled; loginMessage = "Demo preference only"; return }
        do { try LoginItemService.setEnabled(enabled); loginEnabled = LoginItemService.isEnabled; loginMessage = LoginItemService.statusMessage }
        catch { loginEnabled = LoginItemService.isEnabled; loginMessage = error.localizedDescription }
        onChange?()
    }

    func setWindowVisible(_ visible: Bool) { windowVisible = visible }

    private func loadDemo() {
        state = .ready
        accountLabel = "Max 20x plan"
        loading = false
        let now = demoNow
        limits = QuotaLimits(fiveHour: QuotaWindow(used: 38, resetsAt: now.addingTimeInterval(9660)), sevenDay: QuotaWindow(used: 59, resetsAt: now.addingTimeInterval(273600)))
        limitsUpdatedAt = now
        report = Self.demoReport(now: now)
    }

    /// Reproducible hourly sessions, scaled to 700M tokens over the last 30 calendar days.
    static func demoReport(now: Date) -> UsageReport {
        var generator = DemoGenerator()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: now)
        let currentHour = calendar.dateInterval(of: .hour, for: now)!.start
        let projects = ["GPUI", "website", "agent-sdk", "macOS-app", "widgets", "docs"]
        let models = ["opus-5-5", "opus-5", "sonnet-5-5", "haiku-4-5"]
        let shares = [0.60, 0.22, 0.13, 0.05]
        let spikeAges = [7, 19, 25].map { age -> Int in
            var age = age
            while calendar.isDateInWeekend(calendar.date(byAdding: .day, value: -age, to: today)!) { age += 1 }
            return age
        }
        var samples: [UsageSample] = []
        for age in (0..<90).reversed() {
            let day = calendar.date(byAdding: .day, value: -age, to: today)!
            let weekend = calendar.isDateInWeekend(day)
            let sessions = weekend ? 1 : 2 + (age % 3 == 0 ? 0 : 1)
            let spike = age == spikeAges[0] ? 4.0 : age == spikeAges[1] ? 2.6 : age == spikeAges[2] ? 1.8 : 1.0
            let dayWeight = (weekend ? 0.30 : 1.0) * spike * (0.75 + generator.unit() * 0.5)
            for session in 0..<sessions {
                let id = String(format: "demo-%03d-%02d", age, session)
                let project = projects[generator.integer(projects.count)]
                let duration = 1 + generator.integer(6)
                // Sessions use a few models, not all of them, so per-model session counts differ.
                let used = models.indices.map { index in index == 0 ? generator.unit() < 0.85 : generator.unit() < [0, 0.4, 0.3, 0.45][index] }
                let inSession = used.contains(true) ? used : [true, false, false, false]
                let startHour = 8 + generator.integer(11)
                let start = age == 0
                    ? currentHour.addingTimeInterval(Double(-duration + 1 - session * 6) * 3600)
                    : day.addingTimeInterval(Double(startHour) * 3600)
                for offset in 0..<duration {
                    let hour = start.addingTimeInterval(Double(offset) * 3600)
                    let total = 3_000_000 * dayWeight * (0.60 + generator.unit() * 0.8)
                    let weights = shares.indices.map { inSession[$0] ? shares[$0] * (0.75 + generator.unit() * 0.5) : 0 }
                    let sum = weights.reduce(0, +)
                    for (index, model) in models.enumerated() where inSession[index] {
                        let count = UInt64(total * weights[index] / sum)
                        samples.append(UsageSample(hour: hour, sessionID: id, project: project, model: model, tokens: demoTokens(count)))
                    }
                }
            }
        }
        let monthStart = calendar.date(byAdding: .day, value: -29, to: today)!
        let monthTotal = samples.filter { $0.hour >= monthStart }.reduce(UInt64(0)) { $0 + $1.tokens.total }
        let scale = 700_000_000.0 / Double(monthTotal)
        samples = samples.map { sample in
            var sample = sample
            sample.tokens = demoTokens(UInt64(Double(sample.tokens.total) * scale))
            return sample
        }.sorted {
            if $0.hour != $1.hour { return $0.hour < $1.hour }
            if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
            return $0.model < $1.model
        }
        var report = UsageReport()
        report.samples = samples
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d, yyyy"
        func rows(_ key: (UsageSample) -> String, title: (UsageSample) -> String) -> [UsageRow] {
            let groups = Dictionary(grouping: samples, by: key)
            return groups.values.sorted { $0.last!.hour > $1.last!.hour }.map { group in
                let first = group[0]
                var tokens = TokenCounts()
                for sample in group { tokens.add(sample.tokens) }
                return UsageRow(id: key(first), title: title(first), detail: Array(Set(group.map(\.model))).sorted().joined(separator: ", "), tokens: tokens, active: group.contains { $0.hour == currentHour })
            }
        }
        report.daily = rows({ formatter.string(from: $0.hour) }, title: { formatter.string(from: $0.hour) })
        report.weekly = rows({ formatter.string(from: calendar.dateInterval(of: .weekOfYear, for: $0.hour)!.start) }, title: { "Week of " + formatter.string(from: calendar.dateInterval(of: .weekOfYear, for: $0.hour)!.start) })
        report.monthly = rows({ formatter.string(from: calendar.dateInterval(of: .month, for: $0.hour)!.start) }, title: { formatter.string(from: calendar.dateInterval(of: .month, for: $0.hour)!.start) })
        report.sessions = rows({ $0.sessionID }, title: { $0.project })
        report.blocks = rows({ String(Int($0.hour.timeIntervalSince1970) / 18_000) }, title: { formatter.string(from: $0.hour) + " · 5-hour block" })
        return report
    }

    private static func demoTokens(_ total: UInt64) -> TokenCounts {
        // Normalize the requested approximate proportions, which sum to 99.4%.
        let input = UInt64(Double(total) * 2.2 / 99.4)
        let output = UInt64(Double(total) * 0.6 / 99.4)
        let cacheWrite = UInt64(Double(total) * 1.1 / 99.4)
        return TokenCounts(input: input, output: output, cacheCreate: cacheWrite, cacheRead: total - input - output - cacheWrite)
    }
}

private struct DemoGenerator {
    private var state: UInt64 = 0xC1A0DE2026
    mutating func unit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
    mutating func integer(_ limit: Int) -> Int { Int(unit() * Double(limit)) }
}

import XCTest
import ClaudeUsageCore
@testable import ClaudeUsage

final class UsageFormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testTokenCompactCounts() {
        XCTAssertEqual(UsageFormat.tokens(0), "0")
        XCTAssertEqual(UsageFormat.tokens(999), "999")
        XCTAssertEqual(UsageFormat.tokens(1_000), "1K")
        XCTAssertEqual(UsageFormat.tokens(12_480), "12.5K")
        XCTAssertEqual(UsageFormat.tokens(1_000_000), "1M")
        XCTAssertEqual(UsageFormat.tokens(1_284_600), "1.3M")
    }

    func testDashboardTokenCountsUseThreeSignificantDigits() {
        let examples: [(UInt64, String)] = [
            (0, "0"), (950, "950"), (999, "999"), (1_000, "1K"),
            (1_590_000_000, "1.59B"), (702_000_000, "702M"),
            (34_900_000, "34.9M"), (9_050_000, "9.05M"), (17_200_000, "17.2M"),
            (1_005, "1.01K"), (12_480, "12.5K"), (123_480, "123K")
        ]
        for (value, expected) in examples {
            XCTAssertEqual(UsageFormat.compactTokens(value), expected, "Count: \(value)")
        }
    }

    func testDashboardTokenRoundingPromotesUnits() {
        XCTAssertEqual(UsageFormat.compactTokens(999_499), "999K")
        XCTAssertEqual(UsageFormat.compactTokens(999_500), "1M")
        XCTAssertEqual(UsageFormat.compactTokens(999_950), "1M")
        XCTAssertEqual(UsageFormat.compactTokens(999_950_000), "1B")
        XCTAssertEqual(UsageFormat.compactTokens(9_995_000), "10M")
        XCTAssertEqual(UsageFormat.compactTokens(UInt64.max), "18400000000B")
    }

    func testDashboardSharesUseOneDecimalPlace() {
        XCTAssertEqual(UsageFormat.share(0.342), "34.2%")
        XCTAssertEqual(UsageFormat.share(0.443), "44.3%")
        XCTAssertEqual(UsageFormat.share(0), "0.0%")
        XCTAssertEqual(UsageFormat.share(1), "100.0%")
        XCTAssertEqual(UsageFormat.share(-1), "0.0%")
        XCTAssertEqual(UsageFormat.share(2), "100.0%")
        XCTAssertEqual(UsageFormat.share(.nan), "0.0%")
    }

    func testPercentLabelsRoundAndFollowTheMode() {
        let window = QuotaWindow(used: 38)
        XCTAssertEqual(UsageFormat.percentLabel(window, mode: .left), "62% left")
        XCTAssertEqual(UsageFormat.percentLabel(window, mode: .used), "38% used")
    }

    func testQuotaTimingSpellsOutAFutureReset() {
        let window = QuotaWindow(used: 38, resetsAt: now.addingTimeInterval(161 * 60 + 30))
        XCTAssertEqual(UsageFormat.quotaTiming(window, kind: .fiveHour, now: now), "Resets in 2h 41m")
        XCTAssertEqual(UsageFormat.quotaTiming(QuotaWindow(used: 10), kind: .fiveHour, now: now), "Starts with your next message")
        XCTAssertEqual(UsageFormat.quotaTiming(QuotaWindow(used: 10), kind: .sevenDay, now: now), "Reset time unavailable")
    }

    func testMenuBarTitleLine() {
        let settings = MenuBarSettings()
        XCTAssertEqual(title(settings: settings), "5h 62% · 7d 41%")

        var unlabeled = settings
        unlabeled.showLabels = false
        XCTAssertEqual(title(settings: unlabeled), "62% · 41%")

        var used = settings
        used.percent = .used
        XCTAssertEqual(title(settings: used), "5h 38% · 7d 59%")

        var countdown = settings
        countdown.showReset = true
        XCTAssertEqual(title(settings: countdown), "5h 62% (2h41m) · 7d 41% (3d4h)")

        var weeklyOnly = settings
        weeklyOnly.showFiveHour = false
        XCTAssertEqual(title(settings: weeklyOnly), "7d 41%")

        var none = settings
        none.showFiveHour = false
        none.showSevenDay = false
        XCTAssertEqual(title(settings: none), "Claude —")
    }

    func testMenuBarFallbacksIgnoreTheFigures() {
        let settings = MenuBarSettings()
        XCTAssertEqual(
            UsageFormat.menuBarTitle(state: .signedOut, limits: sampleLimits(), settings: settings, loading: false, now: now),
            "Claude: signed out"
        )
        XCTAssertEqual(
            UsageFormat.menuBarTitle(state: .apiBilling, limits: nil, settings: settings, loading: false, now: now),
            "Claude: API billing"
        )
        XCTAssertEqual(
            UsageFormat.menuBarTitle(state: .expired, limits: nil, settings: settings, loading: false, now: now),
            "Claude: session expired"
        )
        XCTAssertEqual(
            UsageFormat.menuBarTitle(state: .loading, limits: nil, settings: settings, loading: true, now: now),
            "Claude…"
        )
        XCTAssertEqual(
            UsageFormat.menuBarTitle(state: .ready, limits: nil, settings: settings, loading: false, now: now),
            "Claude —"
        )
        XCTAssertEqual(
            UsageFormat.menuBarTitle(state: .ready, limits: QuotaLimits(), settings: settings, loading: false, now: now),
            "Claude: no limits"
        )
    }

    func testAMissingResetDropsOnlyThatCountdown() {
        var settings = MenuBarSettings()
        settings.showReset = true
        var limits = sampleLimits()
        limits.fiveHour = QuotaWindow(used: 0, resetsAt: nil)
        XCTAssertEqual(
            UsageFormat.menuBarTitle(state: .ready, limits: limits, settings: settings, loading: false, now: now),
            "5h 100% · 7d 41% (3d4h)"
        )
    }

    func testColumnTitlesFollowTheFiveTabs() {
        XCTAssertEqual(UsageFormat.columnTitles(for: .daily).title, "Day")
        XCTAssertEqual(UsageFormat.columnTitles(for: .weekly).detail, "Models")
        XCTAssertEqual(UsageFormat.columnTitles(for: .sessions).title, "Session")
        XCTAssertEqual(UsageFormat.columnTitles(for: .sessions).detail, "Last active")
        XCTAssertEqual(UsageFormat.columnTitles(for: .blocks).title, "Started")
        XCTAssertEqual(UsageFormat.columnTitles(for: .blocks).detail, "Status")
    }

    func testNoticesStayQuietForANormalPlan() {
        XCTAssertNil(UsageFormat.dashboardNotice(state: .ready, limits: sampleLimits()))
        XCTAssertEqual(
            UsageFormat.dashboardNotice(state: .expired, limits: nil),
            "Claude Code's access token has expired. You're still logged in: open Claude Code to refresh it, and the limits return on the next refresh."
        )
        XCTAssertEqual(
            UsageFormat.dashboardNotice(state: .ready, limits: QuotaLimits()),
            "Your plan did not report any usage limits."
        )
    }

    private func title(settings: MenuBarSettings) -> String {
        UsageFormat.menuBarTitle(state: .ready, limits: sampleLimits(), settings: settings, loading: false, now: now)
    }

    private func sampleLimits() -> QuotaLimits {
        QuotaLimits(
            fiveHour: QuotaWindow(used: 38, resetsAt: now.addingTimeInterval(161 * 60 + 30)),
            sevenDay: QuotaWindow(used: 59, resetsAt: now.addingTimeInterval(Double(3 * 24 * 60 + 4 * 60) * 60 + 30))
        )
    }
}

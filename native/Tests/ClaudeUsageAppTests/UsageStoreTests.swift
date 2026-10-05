import AppKit
import XCTest
import ClaudeUsageCore
@testable import ClaudeUsage

final class UsageStoreTests: XCTestCase {
    func testSubscriptionPollsNeverUseTheFullCLIPath() async {
        await MainActor.run {
            let store = UsageStore(demo: true)
            for state in [SessionState.ready, .expired, .unavailable] {
                store.state = state
                XCTAssertEqual(store.pollAction, .quotas)
            }
            store.state = .apiBilling
            XCTAssertEqual(store.pollAction, .billing)
            store.state = .signedOut
            XCTAssertEqual(store.pollAction, .full)
        }
    }

    func testUnauthorizedDropsAllCachedNumbers() async {
        await MainActor.run {
            let store = UsageStore(demo: true)
            XCTAssertNotNil(store.report)
            store.applySession(SessionResult(state: .signedOut))
            XCTAssertNil(store.report)
            XCTAssertNil(store.limits)
            XCTAssertNil(store.limitsUpdatedAt)
            XCTAssertNil(store.accountLabel)
        }
    }
    func testExpiryAndTransientErrorsKeepTranscriptRows() async {
        await MainActor.run {
            let store = UsageStore(demo: true)
            let previous = store.report
            store.applySession(SessionResult(state: .expired, accountLabel: "Max 20x plan"))
            XCTAssertEqual(store.report, previous)
            XCTAssertNil(store.limits)
            XCTAssertNil(store.limitsError)
            store.applySession(SessionResult(state: .unavailable, error: "Usage API returned HTTP 500"))
            XCTAssertEqual(store.report, previous)
            XCTAssertNil(store.limits)
            XCTAssertNotNil(store.limitsError)
        }
    }
    func testAPIBillingHasTranscriptRowsWithoutQuotas() async {
        await MainActor.run {
            let store = UsageStore(demo: true)
            let previous = store.report
            store.applySession(SessionResult(state: .apiBilling, accountLabel: "Pay per token · API key"))
            XCTAssertEqual(store.report, previous)
            XCTAssertNil(store.limits)
        }
    }
    func testSettingsCannotHideBothMenuWindows() async {
        await MainActor.run {
            let store = UsageStore(demo: true)
            store.updateSettings { $0.menuBar.showFiveHour = false }
            XCTAssertFalse(store.settings.menuBar.showFiveHour)
            store.updateSettings { $0.menuBar.showSevenDay = false }
            XCTAssertTrue(store.settings.menuBar.showSevenDay)
            XCTAssertNil(store.settingsError)
        }
    }
    func testDemoSamplesAreReproducibleAndCoverEveryRange() async throws {
        try await MainActor.run {
            let now = Date(timeIntervalSince1970: 1_791_144_000)
            let store = UsageStore(demo: true, now: now)
            let report = try XCTUnwrap(store.report)
            store.refresh()
            XCTAssertEqual(store.report, report)
            XCTAssertEqual(report, UsageStore.demoReport(now: now))
            XCTAssertEqual(Set(report.samples.map(\.model)), ["opus-5-5", "opus-5", "sonnet-5-5", "haiku-4-5"])
            XCTAssertEqual(Set(report.samples.map(\.project)), ["GPUI", "website", "agent-sdk", "macOS-app", "widgets", "docs"])
            let currentHour = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3600) * 3600)
            XCTAssertTrue(report.samples.contains { $0.hour == currentHour })
            XCTAssertTrue(report.samples.allSatisfy { $0.hour <= now })
            XCTAssertGreaterThan(Set(report.samples.map(\.sessionID)).count, 180)
            XCTAssertLessThan(Set(report.samples.map(\.sessionID)).count, 220)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let monthStart = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
            let total = report.samples.filter { $0.hour >= monthStart }.reduce(UInt64(0)) { $0 + $1.tokens.total }
            XCTAssertEqual(Double(total), 700_000_000, accuracy: 10_000_000)
            for range in UsageRange.allCases {
                let summary = report.summary(range, now: now, timeZone: calendar.timeZone)
                XCTAssertFalse(summary.isEmpty, range.label)
                XCTAssertGreaterThan(summary.sessions, 0, range.label)
            }
            let ledgerTotal = report.samples.reduce(UInt64(0)) { $0 + $1.tokens.total }
            for rows in [report.daily, report.weekly, report.monthly, report.sessions, report.blocks] {
                XCTAssertEqual(rows.reduce(UInt64(0)) { $0 + $1.tokens.total }, ledgerTotal)
            }
            for group in Dictionary(grouping: report.samples, by: \.sessionID).values {
                XCTAssertEqual(Set(group.map(\.project)).count, 1)
                XCTAssertTrue((1...6).contains(Set(group.map(\.hour)).count))
            }
        }
    }

    func testNativeToolbarActionsUpdateTheStore() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let store = UsageStore(demo: true)
            let controller = MainToolbar(store: store)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
            controller.install(on: window)
            let controls = try XCTUnwrap(window.toolbar).items.compactMap { $0.view as? NSSegmentedControl }
            XCTAssertEqual(controls.count, 2)
            let page = try XCTUnwrap(controls.first)
            let range = try XCTUnwrap(controls.last)
            XCTAssertEqual(page.segmentStyle, .rounded)
            XCTAssertFalse(range.isEnabled)
            page.selectedSegment = 1
            NSApp.sendAction(try XCTUnwrap(page.action), to: page.target, from: page)
            XCTAssertEqual(store.section, .tokens)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertTrue(range.isEnabled)
            range.selectedSegment = 1
            NSApp.sendAction(try XCTUnwrap(range.action), to: range.target, from: range)
            XCTAssertEqual(store.range, .week)
            store.section = .limits
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(page.selectedSegment, 0)
            XCTAssertFalse(range.isEnabled)
        }
    }

}

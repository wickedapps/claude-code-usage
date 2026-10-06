import XCTest
@testable import ClaudeUsageCore

final class UsageSummaryTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let now = ISO8601DateFormatter().date(from: "2026-10-04T12:34:56Z")!

    func testEachRangeHasExpectedStartAndZeroFilledBuckets() {
        let cases: [(UsageRange, Int, String)] = [
            (.day, 24, "2026-10-03T13:00:00Z"),
            (.week, 7, "2026-09-28T00:00:00Z"),
            (.month, 30, "2026-09-05T00:00:00Z"),
            (.quarter, 90, "2026-07-07T00:00:00Z"),
        ]
        for (range, count, start) in cases {
            let summary = UsageReport().summary(range, now: now, timeZone: utc)
            XCTAssertEqual(summary.range, range)
            XCTAssertEqual(summary.start, date(start))
            XCTAssertEqual(summary.end, now)
            XCTAssertEqual(summary.series.count, count)
            XCTAssertEqual(summary.series.first?.start, summary.start)
            XCTAssertEqual(summary.series.last?.start, date(range.hourly ? "2026-10-04T12:00:00Z" : "2026-10-04T00:00:00Z"))
            XCTAssertEqual(summary.series.map(\.start), summary.series.map(\.start).sorted())
            XCTAssertTrue(summary.series.allSatisfy { $0.tokens == TokenCounts() && $0.byModel.isEmpty })
            XCTAssertTrue(summary.isEmpty)
            XCTAssertEqual(summary.sessions, 0)
            XCTAssertTrue(summary.models.isEmpty)
            XCTAssertTrue(summary.projects.isEmpty)
            XCTAssertTrue(summary.days.isEmpty)
        }
    }

    func testTotalsDistinctSessionsBreakdownsAndShares() throws {
        var report = UsageReport()
        report.samples = [
            sample("2026-10-03T20:00:00Z", session: "a", project: "Demo", model: "sonnet", tokens: TokenCounts(input: 10, output: 2, cacheCreate: 3, cacheRead: 5)),
            sample("2026-10-04T10:00:00Z", session: "a", project: "Demo", model: "opus", input: 30),
            sample("2026-10-04T11:00:00Z", session: "b", project: "", model: "sonnet", input: 20),
            sample("2026-10-04T12:00:00Z", session: "b", project: "", model: "sonnet", input: 30),
        ]
        let summary = report.summary(.week, now: now, timeZone: utc)
        XCTAssertEqual(summary.totals, TokenCounts(input: 90, output: 2, cacheCreate: 3, cacheRead: 5))
        XCTAssertEqual(summary.sessions, 2)
        XCTAssertEqual(summary.models.map(\.id), ["sonnet", "opus"])
        XCTAssertEqual(summary.models.map(\.title), ["sonnet", "opus"])
        XCTAssertEqual(summary.models.map(\.sessions), [2, 1])
        XCTAssertEqual(summary.models.map(\.tokens.total), [70, 30])
        XCTAssertEqual(summary.models.map(\.share), [0.7, 0.3])
        XCTAssertEqual(summary.projects.map(\.id), ["", "Demo"])
        XCTAssertEqual(summary.projects.map(\.title), ["Other", "Demo"])
        XCTAssertEqual(summary.projects.map(\.sessions), [1, 1])
        XCTAssertEqual(summary.projects.map(\.tokens.total), [50, 50])
        XCTAssertEqual(summary.days.map(\.id), ["2026-10-04", "2026-10-03"])
        XCTAssertEqual(summary.days.map(\.title), ["Oct 4", "Oct 3"])
        XCTAssertEqual(summary.days.map(\.sessions), [2, 1])
        XCTAssertEqual(summary.days.map(\.tokens.total), [80, 20])
        for rows in [summary.models, summary.projects, summary.days] {
            XCTAssertEqual(rows.reduce(0) { $0 + $1.share }, 1, accuracy: 0.000_001)
        }
        XCTAssertEqual(summary.series[5].tokens, report.samples[0].tokens)
        XCTAssertEqual(summary.series[5].byModel, ["sonnet": 20])
        XCTAssertEqual(summary.series[6].byModel, ["sonnet": 50, "opus": 30])
        XCTAssertTrue(summary.series.prefix(5).allSatisfy { $0.tokens.total == 0 })
        var seriesTokens = TokenCounts()
        summary.series.forEach { seriesTokens.add($0.tokens) }
        XCTAssertEqual(seriesTokens, summary.totals)
    }

    func testBreakdownTiesSortByNameAndInputOrderDoesNotMatter() {
        var report = UsageReport()
        report.samples = [
            sample("2026-10-04T10:00:00Z", session: "b", project: "Zebra", model: "zebra", input: 10),
            sample("2026-10-04T09:00:00Z", session: "a", project: "Alpha", model: "alpha", input: 10),
        ]
        let summary = report.summary(.day, now: now, timeZone: utc)
        XCTAssertEqual(summary.models.map(\.id), ["alpha", "zebra"])
        XCTAssertEqual(summary.projects.map(\.id), ["Alpha", "Zebra"])
        report.samples.reverse()
        XCTAssertEqual(report.summary(.day, now: now, timeZone: utc), summary)
    }

    func testZeroTokenSamplesHaveZeroSharesAndDoNotCountSessionsOrDays() {
        var report = UsageReport()
        report.samples = [sample("2026-10-04T12:00:00Z", session: "zero", project: "", model: "unknown", input: 0)]
        let summary = report.summary(.day, now: now, timeZone: utc)
        XCTAssertTrue(summary.isEmpty)
        XCTAssertEqual(summary.sessions, 0)
        XCTAssertTrue(summary.days.isEmpty)
        XCTAssertEqual(summary.models, [UsageBreakdownRow(id: "unknown", title: "unknown", sessions: 0, tokens: TokenCounts(), share: 0)])
        XCTAssertEqual(summary.projects, [UsageBreakdownRow(id: "", title: "Other", sessions: 0, tokens: TokenCounts(), share: 0)])
        XCTAssertEqual(summary.series.last?.byModel, ["unknown": 0])
        report.samples.append(sample("2026-10-04T12:00:00Z", session: "active", input: 1))
        XCTAssertEqual(report.summary(.day, now: now, timeZone: utc).sessions, 1)
    }

    func testSamplesBeforeStartAndAfterNowAreExcludedForEveryRange() {
        for range in UsageRange.allCases {
            let start = UsageReport().summary(range, now: now, timeZone: utc).start
            var report = UsageReport()
            report.samples = [
                UsageSample(hour: start.addingTimeInterval(-3_600), sessionID: "old", project: "old", model: "old", tokens: TokenCounts(input: 100)),
                UsageSample(hour: start, sessionID: "start", project: "", model: "sonnet", tokens: TokenCounts(input: 2)),
                sample("2026-10-04T12:00:00Z", session: "current", input: 3),
                sample("2026-10-04T13:00:00Z", session: "future", model: "future", input: 200),
            ]
            let summary = report.summary(range, now: now, timeZone: utc)
            XCTAssertEqual(summary.totals.input, 5)
            XCTAssertEqual(summary.sessions, 2)
            XCTAssertEqual(summary.series.first?.tokens.input, 2)
            XCTAssertEqual(summary.series.last?.tokens.input, 3)
            XCTAssertFalse(summary.models.contains { $0.id == "old" || $0.id == "future" })
        }
    }

    func testWeekAcrossNovemberDSTHasSevenLocalDaysAndBothRepeatedHours() {
        let zone = TimeZone(identifier: "America/New_York")!
        var report = UsageReport()
        report.samples = [
            sample("2026-10-29T03:00:00Z", session: "excluded", input: 100),
            sample("2026-10-29T04:00:00Z", input: 2),
            sample("2026-11-01T05:00:00Z", input: 3),
            sample("2026-11-01T06:00:00Z", input: 5),
            sample("2026-11-02T04:00:00Z", input: 7),
            sample("2026-11-02T05:00:00Z", input: 11),
        ]
        let summary = report.summary(.week, now: date("2026-11-04T18:30:00Z"), timeZone: zone)
        XCTAssertEqual(summary.series.map(\.start), [
            date("2026-10-29T04:00:00Z"), date("2026-10-30T04:00:00Z"),
            date("2026-10-31T04:00:00Z"), date("2026-11-01T04:00:00Z"),
            date("2026-11-02T05:00:00Z"), date("2026-11-03T05:00:00Z"),
            date("2026-11-04T05:00:00Z"),
        ])
        XCTAssertEqual(summary.start, date("2026-10-29T04:00:00Z"))
        XCTAssertEqual(summary.series.map(\.tokens.input), [2, 0, 0, 15, 11, 0, 0])
        XCTAssertEqual(summary.totals.input, 28)
        XCTAssertEqual(summary.days.map(\.id), ["2026-11-02", "2026-11-01", "2026-10-29"])
        XCTAssertEqual(summary.days.map(\.title), ["Nov 2", "Nov 1", "Oct 29"])
    }

    func testHourlyRangeGroupsBreakdownIntoLocalDays() {
        var report = UsageReport()
        report.samples = [
            sample("2026-10-03T13:00:00Z", input: 2),
            sample("2026-10-04T03:00:00Z", input: 3),
            sample("2026-10-04T04:00:00Z", input: 5),
            sample("2026-10-04T12:00:00Z", input: 7),
        ]
        let summary = report.summary(.day, now: now, timeZone: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(summary.series.count, 24)
        XCTAssertEqual(summary.start, date("2026-10-03T13:00:00Z"))
        XCTAssertEqual(summary.days.map(\.id), ["2026-10-04", "2026-10-03"])
        XCTAssertEqual(summary.days.map(\.tokens.input), [12, 5])
        XCTAssertEqual(summary.series[0].tokens.input, 2)
        XCTAssertEqual(summary.series[14].tokens.input, 3)
        XCTAssertEqual(summary.series[15].tokens.input, 5)
        XCTAssertEqual(summary.series[23].tokens.input, 7)
    }

    func testHalfHourZoneAssignsTokensToDayTheUTCHourStartsIn() {
        var report = UsageReport()
        report.samples = [
            sample("2026-09-27T18:00:00Z", input: 100), // Sep 27, 23:30 local, outside range.
            sample("2026-09-27T19:00:00Z", input: 2),
            sample("2026-10-03T18:00:00Z", input: 3), // Oct 3, 23:30 local.
            sample("2026-10-03T19:00:00Z", input: 5),
        ]
        let summary = report.summary(.week, now: now, timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        XCTAssertEqual(summary.start, date("2026-09-27T18:30:00Z"))
        XCTAssertEqual(summary.series.map(\.tokens.input), [2, 0, 0, 0, 0, 3, 5])
        XCTAssertEqual(summary.days.map(\.id), ["2026-10-04", "2026-10-03", "2026-09-28"])
        XCTAssertEqual(summary.totals.input, 10)
    }

    func testMatchingNarrowsTotalsSeriesAndBreakdowns() {
        var report = UsageReport()
        report.samples = [
            sample("2026-10-03T20:00:00Z", session: "a", project: "Demo", model: "sonnet", input: 10),
            sample("2026-10-04T10:00:00Z", session: "a", project: "Demo", model: "opus", input: 30),
            sample("2026-10-04T11:00:00Z", session: "b", project: "Site", model: "sonnet", input: 20),
        ]
        let summary = report.summary(.week, now: now, timeZone: utc) { $0.model == "sonnet" }
        XCTAssertEqual(summary.totals.input, 30)
        XCTAssertEqual(summary.sessions, 2)
        XCTAssertEqual(summary.models.map(\.id), ["sonnet"])
        XCTAssertEqual(summary.projects.map(\.id), ["Site", "Demo"])
        XCTAssertEqual(summary.projects.map(\.share), [2.0 / 3, 1.0 / 3])
        XCTAssertEqual(summary.series[5].byModel, ["sonnet": 10])
        XCTAssertEqual(summary.series[6].byModel, ["sonnet": 20])
    }

    func testDaySummaryHasLocalHoursOfThatDayOnly() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        var report = UsageReport()
        report.samples = [
            sample("2026-10-03T03:00:00Z", session: "before", input: 100), // Oct 2, 23:00 local.
            sample("2026-10-03T04:00:00Z", session: "a", input: 2),
            sample("2026-10-03T20:00:00Z", session: "b", model: "opus", input: 3),
            sample("2026-10-04T03:00:00Z", session: "a", input: 5),
            sample("2026-10-04T04:00:00Z", session: "after", input: 100), // Oct 4, 00:00 local.
        ]
        let summary = try XCTUnwrap(report.summary(day: "2026-10-03", now: now, timeZone: zone))
        XCTAssertEqual(summary.range, .day)
        XCTAssertEqual(summary.series.count, 24)
        XCTAssertEqual(summary.start, date("2026-10-03T04:00:00Z"))
        XCTAssertEqual(summary.series.last?.start, date("2026-10-04T03:00:00Z"))
        XCTAssertEqual(summary.totals.input, 10)
        XCTAssertEqual(summary.sessions, 2)
        XCTAssertEqual(summary.series[16].byModel, ["opus": 3])
        XCTAssertEqual(summary.days.map(\.id), ["2026-10-03"])
        XCTAssertNil(report.summary(day: "not a day", now: now, timeZone: zone))
    }

    func testDaySummaryForTodayStopsAtNowAndSpansDSTDays() throws {
        var report = UsageReport()
        report.samples = [
            sample("2026-10-04T12:00:00Z", input: 2),
            sample("2026-10-04T13:00:00Z", session: "future", input: 100),
        ]
        let today = try XCTUnwrap(report.summary(day: "2026-10-04", now: now, timeZone: utc))
        XCTAssertEqual(today.series.count, 24)
        XCTAssertEqual(today.end, now)
        XCTAssertEqual(today.totals.input, 2)
        let zone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(UsageReport().summary(day: "2026-11-01", now: now, timeZone: zone)?.series.count, 25)
        XCTAssertEqual(UsageReport().summary(day: "2026-03-08", now: now, timeZone: zone)?.series.count, 23)
    }

    func testHundredThousandSamplesAggregateWithoutLosingCounts() {
        let start = date("2026-07-07T00:00:00Z")
        var report = UsageReport()
        report.samples = (0..<100_000).map { index in
            UsageSample(
                hour: start.addingTimeInterval(TimeInterval(index % 2_100) * 3_600),
                sessionID: "session-\(index % 100)", project: "project-\(index % 10)",
                model: "model-\(index % 3)", tokens: TokenCounts(input: 1, output: 2, cacheCreate: 3, cacheRead: 4)
            )
        }
        let started = Date()
        let summary = report.summary(.quarter, now: now, timeZone: utc)
        let elapsed = Date().timeIntervalSince(started)
        print("100k sample summary: \(String(format: "%.2f", elapsed * 1_000)) ms")
        XCTAssertEqual(summary.totals, TokenCounts(input: 100_000, output: 200_000, cacheCreate: 300_000, cacheRead: 400_000))
        XCTAssertEqual(summary.sessions, 100)
        XCTAssertEqual(summary.models.count, 3)
        XCTAssertEqual(summary.projects.count, 10)
        XCTAssertEqual(summary.series.count, 90)
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func sample(
        _ hour: String, session: String = "a", project: String = "Demo", model: String = "sonnet",
        input: UInt64 = 1, tokens: TokenCounts? = nil
    ) -> UsageSample {
        UsageSample(hour: date(hour), sessionID: session, project: project, model: model, tokens: tokens ?? TokenCounts(input: input))
    }
}

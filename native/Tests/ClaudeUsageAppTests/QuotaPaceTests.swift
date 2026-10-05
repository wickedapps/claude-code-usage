import XCTest
import ClaudeUsageCore
@testable import ClaudeUsage

final class QuotaPaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testOnTrackForBothWindowKinds() {
        for kind in QuotaKind.allCases {
            let pace = estimate(used: 32, elapsed: 0.5, kind: kind)
            guard case .onTrack(let projected) = pace.status else { return XCTFail("Expected on track for \(kind)") }
            XCTAssertEqual(projected, 64, accuracy: 0.001)
            XCTAssertEqual(pace.sentence, "On pace to use about 64% by reset")
        }
    }

    func testAheadIncludes85And100PercentProjection() {
        for used in [42.5, 47.5, 50] {
            XCTAssertEqual(estimate(used: used, elapsed: 0.5).status, .ahead)
        }
        XCTAssertEqual(estimate(used: 42.5, elapsed: 0.5).sentence, "Close to the limit at this pace")
    }

    func testOverCalculatesRunoutBeforeResetForBothKinds() {
        for kind in QuotaKind.allCases {
            let pace = estimate(used: 80, elapsed: 0.5, kind: kind)
            guard case .over(let runsOutIn) = pace.status else { return XCTFail("Expected over for \(kind)") }
            XCTAssertEqual(runsOutIn, kind.duration * 0.125, accuracy: 0.001)
            XCTAssertLessThan(runsOutIn, kind.duration * 0.5)
            XCTAssertTrue(pace.needsAttention)
        }
    }

    func testRunoutSentenceUsesHoursAndMinutes() {
        XCTAssertEqual(
            estimate(used: 48, elapsed: 0.4).sentence,
            "At this pace, runs out in about 2h 10m"
        )
    }

    func testMissingResetAndVeryEarlyWindowsAreUnknown() {
        XCTAssertEqual(QuotaPace(window: QuotaWindow(used: 30), kind: .fiveHour, now: now).status, .unknown)
        for kind in QuotaKind.allCases {
            XCTAssertEqual(estimate(used: 30, elapsed: 0.04, kind: kind).status, .unknown)
            XCTAssertNotEqual(estimate(used: 1, elapsed: 0.05, kind: kind).status, .unknown)
        }
        XCTAssertNil(estimate(used: 10, elapsed: 0.01).sentence)
        XCTAssertNil(estimate(used: 10, elapsed: 0.01).symbol)
    }

    func testElapsedFractionClampsToWindowBounds() {
        for kind in QuotaKind.allCases {
            XCTAssertEqual(estimate(used: 30, elapsed: -0.5, kind: kind).status, .unknown)
            XCTAssertEqual(estimate(used: 30, elapsed: 1.5, kind: kind).status, .onTrack(projected: 30))
            XCTAssertEqual(estimate(used: 100, elapsed: 1, kind: kind).status, .ahead)
        }
    }

    func testZeroAndOutOfRangeUsageStayFinite() {
        XCTAssertEqual(estimate(used: 0, elapsed: 0.5).status, .onTrack(projected: 0))
        XCTAssertEqual(estimate(used: -10, elapsed: 0.5).status, .onTrack(projected: 0))
        XCTAssertEqual(estimate(used: 120, elapsed: 0.5).status, .over(runsOutIn: 0))
        XCTAssertEqual(estimate(used: .nan, elapsed: 0.5).status, .unknown)
        XCTAssertEqual(estimate(used: .infinity, elapsed: 0.5).status, .unknown)
    }

    private func estimate(used: Double, elapsed: Double, kind: QuotaKind = .fiveHour) -> QuotaPace {
        let window = QuotaWindow(used: used, resetsAt: now.addingTimeInterval(kind.duration * (1 - elapsed)))
        return QuotaPace(window: window, kind: kind, now: now)
    }
}

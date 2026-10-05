import XCTest
@testable import ClaudeUsageCore

final class ModelsTests: XCTestCase {
    func testMenuSelectionsPreserveOrder() {
        let limits = QuotaLimits(fiveHour: QuotaWindow(used: 38), sevenDay: QuotaWindow(used: 59))
        var settings = MenuBarSettings()
        XCTAssertEqual(limits.shown(settings).map { $0.0 }, [.fiveHour, .sevenDay])
        settings.showFiveHour = false
        XCTAssertEqual(limits.shown(settings).map { $0.0 }, [.sevenDay])
        settings.showSevenDay = false
        XCTAssertTrue(limits.shown(settings).isEmpty)
    }

    func testRemainingClampsWhileUsedRetainsOverage() {
        XCTAssertEqual(QuotaWindow(used: 130).remaining, 0)
        XCTAssertEqual(QuotaWindow(used: -5).remaining, 100)
        XCTAssertEqual(QuotaWindow(used: 130).percentage(.used), 130)
        XCTAssertEqual(QuotaWindow(used: 38).percentage(.left), 62)
    }

    func testResetStates() {
        let now = Date(timeIntervalSince1970: 1800000000)
        XCTAssertEqual(resetDescription(nil, now: now, fiveHour: true), "Starts with your next message")
        XCTAssertEqual(resetDescription(now, now: now), "Reset due")
        XCTAssertEqual(resetDescription(now.addingTimeInterval(9660), now: now), "2h 41m")
        XCTAssertEqual(resetDescription(now.addingTimeInterval(273600), now: now), "3d 4h")
    }
}

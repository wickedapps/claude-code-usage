import XCTest
import ClaudeUsageCore
@testable import ClaudeUsage

final class WidgetWriterTests: XCTestCase {
    func testSnapshotMatchesExistingWidgetContract() async throws {
        try await MainActor.run {
            let store = UsageStore(demo: true)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: WidgetSnapshotWriter.encodedSnapshot(store)) as? [String: Any])
            XCTAssertEqual(object["schema_version"] as? Int, 1)
            XCTAssertEqual(object["state"] as? String, "ready")
            XCTAssertEqual(object["percent_mode"] as? String, "left")
            let windows = try XCTUnwrap(object["windows"] as? [[String: Any]])
            XCTAssertEqual(windows.compactMap { $0["kind"] as? String }, ["five_hour", "seven_day"])
            XCTAssertEqual(windows[0]["remaining"] as? Double, 62)
            XCTAssertNotNil(windows[0]["resets_at"] as? String)
            XCTAssertNil(object["token"])
            XCTAssertNil(object["transcripts"])
        }
    }
    func testFetchTimeDoesNotChangeDisplaySignature() async throws {
        try await MainActor.run {
            let store = UsageStore(demo: true)
            let previous = try WidgetSnapshotWriter.displaySignature(store)
            store.limitsUpdatedAt = Date(timeIntervalSince1970: 1800000000)
            XCTAssertEqual(try WidgetSnapshotWriter.displaySignature(store), previous)
            store.settings.menuBar.percent = .used
            XCTAssertNotEqual(try WidgetSnapshotWriter.displaySignature(store), previous)
        }
    }
    func testFailedFetchDoesNotExposePreviousQuotaFigures() async throws {
        try await MainActor.run {
            let store = UsageStore(demo: true)
            store.applySession(SessionResult(state: .unavailable, error: "HTTP 500"))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: WidgetSnapshotWriter.encodedSnapshot(store)) as? [String: Any])
            XCTAssertEqual(object["state"] as? String, "unavailable")
            XCTAssertEqual((object["windows"] as? [Any])?.count, 0)
        }
    }
    func testSnapshotContainsOnlyTheSelectedQuotaWindow() async throws {
        try await MainActor.run {
            let store = UsageStore(demo: true)
            store.updateSettings { $0.menuBar.showFiveHour = false }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: WidgetSnapshotWriter.encodedSnapshot(store)) as? [String: Any])
            let windows = try XCTUnwrap(object["windows"] as? [[String: Any]])
            XCTAssertEqual(windows.compactMap { $0["kind"] as? String }, ["seven_day"])
            XCTAssertEqual(Set(object.keys), ["schema_version", "state", "updated_at", "percent_mode", "windows"])
        }
    }

}

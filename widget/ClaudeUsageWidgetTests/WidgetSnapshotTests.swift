import Foundation
import XCTest

final class WidgetSnapshotTests: XCTestCase {
  private var readyJSON: String {
    let source = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try! String(
      contentsOf: source.appendingPathComponent("Fixtures/ready.json"), encoding: .utf8)
  }

  func testDecodesTheRustContract() throws {
    let load = WidgetSnapshotLoad.decode(Data(readyJSON.utf8))
    guard case .snapshot(let snapshot) = load else {
      return XCTFail("ready fixture did not decode")
    }
    XCTAssertEqual(snapshot.state, .ready)
    XCTAssertEqual(snapshot.percentMode, .left)
    XCTAssertEqual(snapshot.windows.map(\.kind), [.fiveHour, .sevenDay])
    XCTAssertEqual(snapshot.windows[0].percentageLabel(for: .left), "62% left")
    XCTAssertEqual(snapshot.windows[0].percentageLabel(for: .used), "38% used")
  }

  func testMissingCorruptAndUnknownVersionsAreDistinct() {
    XCTAssertEqual(WidgetSnapshotLoad.decode(nil), .missing)
    XCTAssertEqual(WidgetSnapshotLoad.decode(Data("not json".utf8)), .corrupt)
    let future = readyJSON.replacingOccurrences(
      of: "\"schema_version\": 1", with: "\"schema_version\": 2")
    XCTAssertEqual(WidgetSnapshotLoad.decode(Data(future.utf8)), .corrupt)
  }

  func testAllSnapshotStatesDecode() throws {
    for state in ["loading", "signed_out", "unavailable"] {
      let json = """
        {"schema_version":1,"state":"\(state)","updated_at":null,"percent_mode":"used","windows":[]}
        """
      guard case .snapshot(let snapshot) = WidgetSnapshotLoad.decode(Data(json.utf8)) else {
        return XCTFail("\(state) did not decode")
      }
      XCTAssertTrue(snapshot.windows.isEmpty)
    }
  }

  func testQuotaLevelsMatchTheAppThresholds() {
    XCTAssertEqual(window(remaining: 31).level, .healthy)
    XCTAssertEqual(window(remaining: 30).level, .warning)
    XCTAssertEqual(window(remaining: 10).level, .danger)
  }

  func testResetStatusHandlesMissingAndElapsedDates() {
    let now = Date(timeIntervalSince1970: 1_000)
    XCTAssertEqual(window(kind: .fiveHour, reset: nil).resetStatus(at: now), .startsWithMessage)
    XCTAssertEqual(window(kind: .sevenDay, reset: nil).resetStatus(at: now), .unknown)
    XCTAssertEqual(window(reset: Date(timeIntervalSince1970: 999)).resetStatus(at: now), .due)
    XCTAssertEqual(
      window(reset: Date(timeIntervalSince1970: 1_100)).resetStatus(at: now),
      .countdown(Date(timeIntervalSince1970: 1_100))
    )
  }

  func testSnapshotAgeNeverGoesNegative() throws {
    guard case .snapshot(let snapshot) = WidgetSnapshotLoad.decode(Data(readyJSON.utf8)),
      let updatedAt = snapshot.updatedAt
    else {
      return XCTFail("ready fixture did not decode")
    }
    XCTAssertEqual(snapshot.age(at: updatedAt.addingTimeInterval(90)), 90)
    XCTAssertEqual(snapshot.age(at: updatedAt.addingTimeInterval(-90)), 0)
  }

  private func window(
    kind: WidgetWindowKind = .fiveHour,
    remaining: Double = 50,
    reset: Date? = nil
  ) -> WidgetQuotaWindow {
    WidgetQuotaWindow(kind: kind, used: 100 - remaining, remaining: remaining, resetsAt: reset)
  }
}

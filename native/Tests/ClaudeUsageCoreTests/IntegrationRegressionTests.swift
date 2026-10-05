import XCTest
@testable import ClaudeUsageCore

final class IntegrationRegressionTests: XCTestCase {
    func testInheritedPipeWriterCannotKeepCaptureOpen() throws {
        let start = Date()
        let result = try XCTUnwrap(ProcessRunner.capture(
            executable: "/bin/sh", arguments: ["-c", "(sleep 3) & printf '__DONE__\\n'; exec sleep 10"],
            timeout: 2, untilMarker: "__DONE__"))
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertTrue(String(data: result.stdout, encoding: .utf8)?.contains("__DONE__") == true)
    }

    func testExtremeDatesFailWithoutIntegerConversionTraps() {
        XCTAssertNil(JSONValues.int64(NSNumber(value: Double(Int64.max))))
        XCTAssertNil(JSONValues.epochSeconds(NSNumber(value: Double(Int64.max))))
        XCTAssertNil(JSONValues.double(NSNumber(value: Double.infinity)))
        XCTAssertEqual(JSONValues.epochSeconds(NSNumber(value: 1800000000.75)), 1800000000)
    }
    func testMalformedQuotaWindowsCannotLookLikeUnlimitedPlans() {
        for body in [#"{"five_hour":"bad"}"#, #"{"seven_day":{"utilization":"bad"}}"#, #"{"five_hour":{"utilization":true}}"#] {
            XCTAssertThrowsError(try QuotaService.parseLimits(Data(body.utf8)).get())
        }
        XCTAssertNoThrow(try QuotaService.parseLimits(Data(#"{"five_hour":null}"#.utf8)).get())
    }
}

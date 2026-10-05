import XCTest
@testable import ClaudeUsageCore

final class TranscriptTests: XCTestCase {
    private var root: URL!
    private let gmt = TimeZone(secondsFromGMT: 0)!
    private let now = Date(timeIntervalSince1970: 1_718_467_200) // 2024-06-15T16:00:00Z

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-transcripts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCalendarGroupsModelsAndSessionOrder() throws {
        let project = root.appendingPathComponent("cfg", isDirectory: true)
        try write([
            line(timestamp: "2024-06-15T16:00:00Z", messageID: "day", sessionID: "abcdef0123456789-1111", cwd: "/work/demo", model: "claude-opus-4-5-20251101", input: 10, output: 20, cacheCreate: 30, cacheRead: 40),
            line(timestamp: "2024-06-15T18:00:00Z", messageID: "day-2", sessionID: "abcdef0123456789-1111", cwd: "/work/other", model: "claude-3-5-sonnet-20241022", input: 1, output: 2, cacheCreate: 3, cacheRead: 4),
            line(timestamp: "2023-06-15T16:00:00Z", messageID: "old", sessionID: "zzzzzzzz-2222", cwd: nil, model: "claude-sonnet-4-5-20250929-extra", input: 7),
            line(timestamp: "2024-06-15T17:00:00Z", messageID: "blank-model", sessionID: "abcdef0123456789-1111", model: "   ", input: 5),
            line(timestamp: "2024-12-30T12:00:00Z", messageID: "week-year", sessionID: "bbbbbbbb-3333", cwd: "/work/later", model: "claude-20251101-opus-4", input: 9),
        ], relativeTo: project, path: "projects/demo/abcdef0123456789-1111.jsonl")

        let report = try TranscriptLoader.load(
            environment: [configKey: project.path],
            now: now,
            timeZone: gmt
        )

        let june = try XCTUnwrap(report.daily.first { $0.id == "2024-06-15" })
        XCTAssertEqual(june.title, format(year: 2024, month: 6, day: 15, pattern: "MMM dd"))
        XCTAssertFalse(june.title.contains("2024"))
        XCTAssertEqual(june.detail, "3-5-sonnet, opus-4-5")
        XCTAssertEqual(june.tokens, TokenCounts(input: 16, output: 22, cacheCreate: 33, cacheRead: 44))
        XCTAssertFalse(june.active)

        let old = try XCTUnwrap(report.daily.first { $0.id == "2023-06-15" })
        XCTAssertEqual(old.title, format(year: 2023, month: 6, day: 15, pattern: "MMM dd, yyyy"))
        XCTAssertEqual(old.detail, "sonnet-4-5")
        XCTAssertEqual(old.tokens.input, 7)

        XCTAssertEqual(report.daily.map(\.id), ["2024-12-30", "2024-06-15", "2023-06-15"])
        XCTAssertEqual(try XCTUnwrap(report.daily.first { $0.id == "2024-12-30" }).detail, "opus-4")

        XCTAssertEqual(try XCTUnwrap(report.weekly.first { $0.id == "2024-W24" }).title, "W24 2024")
        XCTAssertEqual(try XCTUnwrap(report.weekly.first { $0.id == "2025-W01" }).title, "W01 2025")
        XCTAssertEqual(try XCTUnwrap(report.weekly.first { $0.id == "2023-W24" }).title, "W24 2023")
        XCTAssertEqual(report.weekly.map(\.id), ["2025-W01", "2024-W24", "2023-W24"])

        XCTAssertEqual(try XCTUnwrap(report.monthly.first { $0.id == "2024-06" }).title, format(year: 2024, month: 6, day: 1, pattern: "MMM yyyy"))
        XCTAssertEqual(report.monthly.map(\.id), ["2024-12", "2024-06", "2023-06"])

        XCTAssertEqual(report.sessions.map(\.id), ["abcdef0123456789-1111", "bbbbbbbb-3333", "zzzzzzzz-2222"])
        XCTAssertEqual(report.sessions.map(\.tokens.input), [16, 9, 7])
        XCTAssertEqual(report.sessions[0].title, "demo \u{00B7} abcdef01")
        XCTAssertEqual(report.sessions[0].detail, format(timestamp: "2024-06-15T18:00:00Z", pattern: "MMM dd, yyyy"))
        XCTAssertEqual(report.sessions[2].title, "zzzzzzzz")
        XCTAssertEqual(report.sessions[1].title, "later \u{00B7} bbbbbbbb")
    }

    func testISOWeekUsesTheWeekYear() throws {
        let project = root.appendingPathComponent("weeks", isDirectory: true)
        try write([
            line(timestamp: "2021-01-01T12:00:00Z", messageID: "new-year", input: 3),
        ], relativeTo: project, path: "projects/p/session.jsonl")
        let report = try TranscriptLoader.load(environment: [configKey: project.path], now: now, timeZone: gmt)
        XCTAssertEqual(report.daily.map(\.id), ["2021-01-01"])
        XCTAssertEqual(report.weekly.map(\.id), ["2020-W53"])
        XCTAssertEqual(report.weekly.map(\.title), ["W53 2020"])
        XCTAssertEqual(report.monthly.map(\.id), ["2021-01"])
    }

    func testLocalTimeZoneChoosesTheCalendarBucket() throws {
        let project = root.appendingPathComponent("shift", isDirectory: true)
        try write([
            line(timestamp: "2024-06-15T12:00:00Z", messageID: "shift", input: 4),
            line(timestamp: "2024-06-15T23:30:00-05:00", messageID: "offset", input: 6),
        ], relativeTo: project, path: "projects/p/session.jsonl")
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 14 * 60 * 60))
        let report = try TranscriptLoader.load(environment: [configKey: project.path], now: now, timeZone: zone)
        XCTAssertEqual(report.daily.map(\.id).sorted(), ["2024-06-16"])
        XCTAssertEqual(report.daily[0].tokens.input, 10)

        let utc = try TranscriptLoader.load(environment: [configKey: project.path], now: now, timeZone: gmt)
        XCTAssertEqual(utc.daily.map(\.id).sorted(), ["2024-06-15", "2024-06-16"])
    }

    func testSubagentPathRollsIntoTheParentSession() throws {
        let project = root.appendingPathComponent("agents", isDirectory: true)
        try write([
            line(timestamp: "2024-06-15T16:00:00Z", messageID: nil, requestID: nil, sessionID: nil, cwd: nil, input: 2),
        ], relativeTo: project, path: "projects/proj/abcdef01-ffff.jsonl")
        try write([
            line(timestamp: "2024-06-15T16:05:00Z", messageID: nil, requestID: nil, sessionID: nil, cwd: "/work/demo", input: 8),
            line(timestamp: "2024-06-15T16:06:00Z", messageID: "owned", requestID: nil, sessionID: "custom-session-id", cwd: "/work/other", input: 1),
        ], relativeTo: project, path: "projects/proj/abcdef01-ffff/subagents/agent.jsonl")

        let report = try TranscriptLoader.load(environment: [configKey: project.path], now: now, timeZone: gmt)
        let parent = try XCTUnwrap(report.sessions.first { $0.id == "abcdef01-ffff" })
        XCTAssertEqual(parent.tokens.input, 10)
        XCTAssertEqual(parent.title, "demo \u{00B7} abcdef01")
        let custom = try XCTUnwrap(report.sessions.first { $0.id == "custom-session-id" })
        XCTAssertEqual(custom.tokens.input, 1)
        XCTAssertEqual(custom.title, "other \u{00B7} custom")
    }

    func testEqualSessionTotalsKeepSessionIDOrder() throws {
        let project = root.appendingPathComponent("ties", isDirectory: true)
        try write([
            line(timestamp: "2024-06-15T16:00:00Z", messageID: "a", sessionID: "bbbbbbbb-1", input: 5),
            line(timestamp: "2024-06-15T16:00:00Z", messageID: "b", sessionID: "aaaaaaaa-1", input: 5),
        ], relativeTo: project, path: "projects/p/sessions.jsonl")
        let report = try TranscriptLoader.load(environment: [configKey: project.path], now: now, timeZone: gmt)
        XCTAssertEqual(report.sessions.map(\.id), ["aaaaaaaa-1", "bbbbbbbb-1"])
    }

    func testFiveHourBlocksFloorOnTheUTCHour() throws {
        let project = root.appendingPathComponent("blocks", isDirectory: true)
        try write([
            line(timestamp: "2024-06-15T14:30:45Z", messageID: "open", input: 10, output: 1),
        ], relativeTo: project, path: "projects/p/open.jsonl")
        let during = try TranscriptLoader.load(
            environment: [configKey: project.path],
            now: date("2024-06-15T16:00:00Z"),
            timeZone: gmt
        )
        XCTAssertEqual(during.blocks.map(\.id), ["2024-06-15T14:00:00Z"])
        XCTAssertEqual(during.blocks[0].tokens, TokenCounts(input: 10, output: 1, cacheCreate: 0, cacheRead: 0))
        XCTAssertTrue(during.blocks[0].active)
        XCTAssertEqual(during.blocks[0].detail, "3h 0m left")
        XCTAssertTrue(during.blocks[0].title.contains("14:00"))

        let closed = try TranscriptLoader.load(
            environment: [configKey: project.path],
            now: date("2024-06-15T19:00:00Z"),
            timeZone: gmt
        )
        XCTAssertFalse(closed.blocks[0].active)
        XCTAssertEqual(closed.blocks[0].detail, "Completed \u{00B7} 30m")

        let early = root.appendingPathComponent("blocks-early", isDirectory: true)
        try write([
            line(timestamp: "2024-06-15T14:00:00Z", messageID: "early", input: 1),
        ], relativeTo: early, path: "projects/p/early.jsonl")
        let trailing = try TranscriptLoader.load(
            environment: [configKey: early.path],
            now: date("2024-06-15T18:59:30Z"),
            timeZone: gmt
        )
        XCTAssertTrue(trailing.blocks[0].active)
        XCTAssertEqual(trailing.blocks[0].detail, "0m left")
    }

    func testFiveHourBoundarySortAndGap() throws {
        let project = root.appendingPathComponent("gap", isDirectory: true)
        try write([
            line(timestamp: "2024-06-15T10:00:00Z", messageID: "start", input: 10),
            line(timestamp: "2024-06-15T15:00:00Z", messageID: "exact", input: 20),
        ], relativeTo: project, path: "projects/p/exact.jsonl")
        let exact = try TranscriptLoader.load(environment: [configKey: project.path], now: date("2024-06-16T00:00:00Z"), timeZone: gmt)
        XCTAssertEqual(exact.blocks.count, 1)
        XCTAssertEqual(exact.blocks[0].id, "2024-06-15T10:00:00Z")
        XCTAssertEqual(exact.blocks[0].tokens.input, 30)
        XCTAssertEqual(exact.blocks[0].detail, "Completed \u{00B7} 5h 0m")

        let splitRoot = root.appendingPathComponent("split", isDirectory: true)
        try write([
            line(timestamp: "2024-06-15T20:30:00Z", messageID: "later", input: 5),
        ], relativeTo: splitRoot, path: "projects/p/a.jsonl")
        try write([
            line(timestamp: "2024-06-15T10:00:00Z", messageID: "earlier", input: 7),
            line(timestamp: "2024-06-15T15:00:01Z", messageID: "over", input: 20),
        ], relativeTo: splitRoot, path: "projects/p/b.jsonl")
        let split = try TranscriptLoader.load(environment: [configKey: splitRoot.path], now: date("2024-06-16T02:00:00Z"), timeZone: gmt)
        XCTAssertEqual(split.blocks.map(\.id), [
            "2024-06-15T20:00:00Z",
            "2024-06-15T15:00:00Z",
            "2024-06-15T10:00:00Z",
        ])
        XCTAssertEqual(split.blocks.map(\.tokens.input), [5, 20, 7])
        XCTAssertTrue(split.blocks.allSatisfy { !$0.active })
    }

    func testExactDuplicateKeepsTheLargerCopy() throws {
        let project = root.appendingPathComponent("dedup-larger", isDirectory: true)
        try write([
            line(messageID: "m", requestID: "r", input: 4, output: 1, cacheCreate: 1, cacheRead: 1),
        ], relativeTo: project, path: "projects/p/a.jsonl")
        try write([
            line(messageID: "m", requestID: "r", input: 10, output: 7, cacheCreate: 0, cacheRead: 3),
        ], relativeTo: project, path: "projects/p/b.jsonl")
        let report = try load(project)
        XCTAssertEqual(report.daily[0].tokens, TokenCounts(input: 10, output: 7, cacheCreate: 0, cacheRead: 3))

        let smallerLater = root.appendingPathComponent("dedup-smaller", isDirectory: true)
        try write([
            line(messageID: "m", requestID: "r", input: 10, output: 9),
            line(messageID: "m", requestID: "r", input: 3, output: 1),
        ], relativeTo: smallerLater, path: "projects/p/same.jsonl")
        let kept = try load(smallerLater)
        XCTAssertEqual(kept.daily[0].tokens, TokenCounts(input: 10, output: 9, cacheCreate: 0, cacheRead: 0))
    }

    func testSidechainLosesEvenWithMoreTokens() throws {
        let mainFirst = root.appendingPathComponent("side-main", isDirectory: true)
        try write([
            line(messageID: "m", requestID: "parent", sidechain: false, input: 5, output: 1),
            line(messageID: "m", requestID: "child", sidechain: true, input: 100, output: 100),
        ], relativeTo: mainFirst, path: "projects/p/main.jsonl")
        XCTAssertEqual(try load(mainFirst).daily[0].tokens, TokenCounts(input: 5, output: 1, cacheCreate: 0, cacheRead: 0))

        let sideFirst = root.appendingPathComponent("side-first", isDirectory: true)
        try write([
            line(messageID: "m", requestID: "child", sidechain: true, input: 100, output: 80),
            line(messageID: "m", requestID: "parent", sidechain: false, input: 5, output: 1),
        ], relativeTo: sideFirst, path: "projects/p/main.jsonl")
        XCTAssertEqual(try load(sideFirst).daily[0].tokens, TokenCounts(input: 5, output: 1, cacheCreate: 0, cacheRead: 0))

        let sameRequest = root.appendingPathComponent("side-exact", isDirectory: true)
        try write([
            line(messageID: "m", requestID: "r", sidechain: false, input: 5, output: 1),
            line(messageID: "m", requestID: "r", sidechain: true, input: 90, output: 90),
        ], relativeTo: sameRequest, path: "projects/p/main.jsonl")
        XCTAssertEqual(try load(sameRequest).daily[0].tokens, TokenCounts(input: 5, output: 1, cacheCreate: 0, cacheRead: 0))
    }

    func testSameMessageAndFlagWithDifferentRequestsBothCount() throws {
        let project = root.appendingPathComponent("two-requests", isDirectory: true)
        try write([
            line(messageID: "m", requestID: "a", input: 10),
            line(messageID: "m", requestID: "b", input: 20),
            line(messageID: "m", requestID: nil, input: 3),
            line(messageID: "m", requestID: "", input: 4),
        ], relativeTo: project, path: "projects/p/main.jsonl")
        XCTAssertEqual(try load(project).daily[0].tokens.input, 37)
    }

    func testReplacingASidechainKeepsTheOldRequestKey() throws {
        let project = root.appendingPathComponent("key-retain", isDirectory: true)
        try write([
            line(messageID: "m", requestID: "a", sidechain: true, input: 1, output: 50),
            line(messageID: "m", requestID: "b", sidechain: false, input: 5, output: 6),
            line(messageID: "m", requestID: "a", sidechain: false, input: 100, output: 7),
        ], relativeTo: project, path: "projects/p/main.jsonl")
        XCTAssertEqual(try load(project).daily[0].tokens, TokenCounts(input: 100, output: 7, cacheCreate: 0, cacheRead: 0))
    }

    func testMissingMessageIDsAreNotDeduplicated() throws {
        let project = root.appendingPathComponent("no-id", isDirectory: true)
        try write([
            line(messageID: nil, requestID: "r", input: 10, output: 1),
            line(messageID: nil, requestID: "r", input: 10, output: 1),
        ], relativeTo: project, path: "projects/p/main.jsonl")
        XCTAssertEqual(try load(project).daily[0].tokens, TokenCounts(input: 20, output: 2, cacheCreate: 0, cacheRead: 0))
    }

    func testAdvisorIterationsAreSeparateBilledTurns() throws {
        let iterations: [[String: Any]] = [
            ["type": "other", "input_tokens": 999, "output_tokens": 999],
            [
                "type": "advisor_message",
                "model": "claude-sonnet-4-5-20250929",
                "input_tokens": 10,
                "output_tokens": 2,
                "cache_creation_input_tokens": 3,
                "cache_read_input_tokens": 4,
            ],
            ["type": "advisor_message", "model": "claude-opus-4-5-20251101", "input_tokens": 20],
        ]
        let project = root.appendingPathComponent("advisor", isDirectory: true)
        let text = line(
            messageID: "parent",
            requestID: "req",
            model: "claude-opus-4-5-20251101",
            input: 100,
            iterations: iterations
        )
        let decoy = line(messageID: "parent:advisor:0", requestID: "req", input: 1000)
        try write([text, text, decoy], relativeTo: project, path: "projects/p/a.jsonl")
        try write([text], relativeTo: project, path: "projects/p/b.jsonl")
        let report = try load(project)
        XCTAssertEqual(report.daily[0].tokens, TokenCounts(input: 1130, output: 2, cacheCreate: 3, cacheRead: 4))
        XCTAssertEqual(report.daily[0].detail, "opus-4-5, sonnet-4-5")
    }

    func testAdvisorWithoutAMessageIDIsKeptOnEveryCopy() throws {
        let project = root.appendingPathComponent("advisor-anon", isDirectory: true)
        let text = line(messageID: nil, requestID: "req", input: 5, iterations: [
            ["type": "advisor_message", "input_tokens": 8],
        ])
        try write([text, text], relativeTo: project, path: "projects/p/a.jsonl")
        XCTAssertEqual(try load(project).daily[0].tokens.input, 26)
    }

    func testSyntheticModelIsLeftOutOfTheLabel() throws {
        let project = root.appendingPathComponent("synthetic", isDirectory: true)
        try write([
            line(messageID: "real", model: "claude-sonnet-4-5-20250929", input: 7),
            line(messageID: "fake", model: "<synthetic>", input: 5, output: 6),
        ], relativeTo: project, path: "projects/p/main.jsonl")
        let mixed = try load(project)
        XCTAssertEqual(mixed.daily[0].detail, "sonnet-4-5")
        XCTAssertEqual(mixed.daily[0].tokens, TokenCounts(input: 12, output: 6, cacheCreate: 0, cacheRead: 0))

        let only = root.appendingPathComponent("synthetic-only", isDirectory: true)
        try write([
            line(messageID: "fake", model: "<synthetic>", input: 5),
        ], relativeTo: only, path: "projects/p/main.jsonl")
        let synthetic = try load(only)
        XCTAssertEqual(synthetic.daily[0].detail, "unknown model")
        XCTAssertEqual(synthetic.daily[0].tokens.input, 5)
    }

    func testIncompleteLinesAndTheUsageMarker() throws {
        let project = root.appendingPathComponent("partial", isDirectory: true)
        let good = line(messageID: "good", input: 11, output: 12, cacheCreate: 13, cacheRead: 14)
        let text = [
            good,
            #"{"timestamp":"2024-06-15T16:00:00Z","message":{"id":"cut","usage":{"input_tokens":99"#,
            #"{"timestamp":"yesterday","message":{"id":"bad-time","usage":{"input_tokens":4}}}"#,
            #"{"timestamp":"2024-06-15T16:00:00Z","message":{"id":"bad-count","usage":{"input_tokens":"nope"}}}"#,
            #"{"timestamp":"2024-06-15T16:00:00Z","message":{"usage": {"input_tokens": 8}}}"#,
            #"{"timestamp":"2024-06-15T16:00:00Z","message":{"id":"no-usage","content":"hello"}}"#,
            "{not json",
        ].joined(separator: "\n")
        try writeRaw(text, relativeTo: project, path: "projects/p/main.jsonl")
        let report = try load(project)
        XCTAssertEqual(report.daily.count, 1)
        XCTAssertEqual(report.daily[0].tokens, TokenCounts(input: 11, output: 12, cacheCreate: 13, cacheRead: 14))
    }

    func testZeroUsageStillCountsAsALog() throws {
        let project = root.appendingPathComponent("zeros", isDirectory: true)
        try writeRaw(
            #"{"timestamp":"2024-06-15T16:00:00Z","message":{"id":"empty","usage":{}}}"#,
            relativeTo: project,
            path: "projects/p/empty.jsonl"
        )
        let report = try load(project)
        XCTAssertEqual(report.daily[0].tokens, TokenCounts())
        XCTAssertEqual(report.daily[0].detail, "unknown model")
    }

    func testDiscoveryRootsRecursionAndErrors() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let xdg = root.appendingPathComponent("xdg", isDirectory: true)
        let explicit = root.appendingPathComponent("explicit", isDirectory: true)
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        try write([line(messageID: "claude", input: 1)], relativeTo: home, path: ".claude/projects/a/one.jsonl")
        try write([line(messageID: "config", input: 2)], relativeTo: home, path: ".config/claude/projects/b/two.jsonl")
        try write([line(messageID: "custom", input: 4)], relativeTo: xdg, path: "claude/projects/c/nested/deep/four.jsonl")
        try write([line(messageID: "explicit", input: 8)], relativeTo: explicit, path: "projects/d/eight.jsonl")
        try writeRaw("hello", relativeTo: explicit, path: "projects/d/skip.txt")
        try writeRaw("nope", relativeTo: explicit, path: "projects/d/SKIP.JSONL")
        try write([line(messageID: "also", input: 16)], relativeTo: explicit, path: "projects/d/inner/sixteen.jsonl")

        let defaults = try TranscriptLoader.load(environment: ["HOME": home.path], now: now)
        XCTAssertEqual(sumInput(defaults), 3)

        let customXDG = try TranscriptLoader.load(environment: [
            "HOME": home.path,
            "XDG_CONFIG_HOME": xdg.path,
        ], now: now)
        XCTAssertEqual(sumInput(customXDG), 5)

        let onlyExplicit = try TranscriptLoader.load(environment: [
            "HOME": home.path,
            configKey: " \(explicit.path) , \(missing.path) ",
        ], now: now)
        XCTAssertEqual(sumInput(onlyExplicit), 24)

        let projectsPointer = try TranscriptLoader.load(environment: [
            "HOME": home.path,
            configKey: explicit.appendingPathComponent("projects").path + "/",
        ], now: now)
        XCTAssertEqual(sumInput(projectsPointer), 24)

        let fallback = try TranscriptLoader.load(environment: [
            "HOME": home.path,
            configKey: missing.path,
        ], now: now)
        XCTAssertEqual(sumInput(fallback), 3)

        let tildeHome = root.appendingPathComponent("tilde-home", isDirectory: true)
        try write([line(messageID: "tilde", input: 32)], relativeTo: tildeHome, path: "cfg/projects/e/tilde.jsonl")
        let tilde = try TranscriptLoader.load(environment: [
            "HOME": tildeHome.path,
            configKey: "~/cfg",
        ], now: now)
        XCTAssertEqual(sumInput(tilde), 32)

        XCTAssertThrowsError(try TranscriptLoader.load(environment: ["HOME": missing.path], now: now)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "No Claude Code logs found in ~/.claude/projects or ~/.config/claude/projects"
            )
        }

        let emptyProjects = root.appendingPathComponent("empty-projects", isDirectory: true)
        try FileManager.default.createDirectory(
            at: emptyProjects.appendingPathComponent(".claude/projects", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try TranscriptLoader.load(environment: ["HOME": emptyProjects.path], now: now)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "No Claude Code logs found in ~/.claude/projects or ~/.config/claude/projects"
            )
        }

        let noTokens = root.appendingPathComponent("no-tokens", isDirectory: true)
        try writeRaw(
            #"{"timestamp":"2024-06-15T16:00:00Z","message":{"id":"prompt","content":"hi"}}"#,
            relativeTo: noTokens,
            path: "projects/p/prompt.jsonl"
        )
        XCTAssertThrowsError(try TranscriptLoader.load(environment: [configKey: noTokens.path], now: now)) { error in
            XCTAssertEqual(error.localizedDescription, "Found Claude Code logs, but none had token usage")
        }
    }

    func testSamplesBucketHoursNormalizeModelsAndKeepFirstProject() throws {
        let project = root.appendingPathComponent("samples", isDirectory: true)
        try write([
            line(timestamp: "2024-06-15T16:00:00Z", messageID: "no-project", sessionID: "b", cwd: nil, model: nil, input: 0),
            line(timestamp: "2024-06-15T17:20:00Z", messageID: "later", sessionID: "b", cwd: "/work/first", model: "<synthetic>", input: 10),
            line(timestamp: "2024-06-15T16:59:59Z", messageID: "earlier", sessionID: "b", cwd: "/work/second", model: nil, input: 2, output: 3),
            line(timestamp: "2024-06-15T16:30:00Z", messageID: "blank", sessionID: "b", cwd: nil, model: "", input: 0, cacheCreate: 4, cacheRead: 5),
            line(timestamp: "2024-06-15T16:05:00Z", messageID: "sonnet", sessionID: "a", cwd: nil, model: "claude-sonnet-4-5-20250929", input: 6),
            line(timestamp: "2024-06-15T16:10:00Z", messageID: "opus", sessionID: "a", cwd: nil, model: "claude-opus-4-5-20251101", input: 7),
        ], relativeTo: project, path: "projects/p/main.jsonl")
        let report = try TranscriptLoader.load(
            environment: [configKey: project.path], now: date("2024-06-15T18:00:00Z"),
            timeZone: TimeZone(identifier: "Asia/Kolkata")!
        )
        XCTAssertEqual(report.samples, [
            UsageSample(hour: date("2024-06-15T16:00:00Z"), sessionID: "a", project: "", model: "opus-4-5", tokens: TokenCounts(input: 7)),
            UsageSample(hour: date("2024-06-15T16:00:00Z"), sessionID: "a", project: "", model: "sonnet-4-5", tokens: TokenCounts(input: 6)),
            UsageSample(hour: date("2024-06-15T16:00:00Z"), sessionID: "b", project: "first", model: "unknown", tokens: TokenCounts(input: 2, output: 3, cacheCreate: 4, cacheRead: 5)),
            UsageSample(hour: date("2024-06-15T17:00:00Z"), sessionID: "b", project: "first", model: "unknown", tokens: TokenCounts(input: 10)),
        ])
        XCTAssertEqual(report.samples, try TranscriptLoader.load(
            environment: [configKey: project.path], now: date("2024-06-15T18:00:00Z"), timeZone: gmt
        ).samples)
        XCTAssertEqual(report.sessions.first { $0.id == "b" }?.title, "first \u{00B7} b")
    }

    func testSamplesUseDeduplicatedTurnsIncludingAdvisors() throws {
        let project = root.appendingPathComponent("samples-dedup", isDirectory: true)
        let full = line(messageID: "parent", requestID: "r", input: 10, output: 2, iterations: [
            ["type": "advisor_message", "model": "claude-sonnet-4-5-20250929", "input_tokens": 3],
        ])
        try write([
            line(messageID: "parent", requestID: "r", input: 1),
            full, full,
            line(messageID: "parent", requestID: "child", sidechain: true, input: 100),
            line(messageID: nil, input: 4), line(messageID: nil, input: 4),
        ], relativeTo: project, path: "projects/p/main.jsonl")
        let report = try load(project)
        XCTAssertEqual(report.samples.map(\.model), ["opus-4-5", "sonnet-4-5"])
        XCTAssertEqual(report.samples.map(\.tokens), [TokenCounts(input: 18, output: 2), TokenCounts(input: 3)])
        var tokens = TokenCounts()
        report.samples.forEach { tokens.add($0.tokens) }
        XCTAssertEqual(tokens, report.daily[0].tokens)
    }

    func testSamplesCutoffUsesHourAndPreservesProjectFromOlderEntries() throws {
        let project = root.appendingPathComponent("samples-cutoff", isDirectory: true)
        let cutoff = now.addingTimeInterval(-92 * 86_400)
        let formatter = ISO8601DateFormatter()
        try write([
            line(timestamp: formatter.string(from: cutoff.addingTimeInterval(-1)), messageID: "old", cwd: "/work/original", input: 100),
            line(timestamp: formatter.string(from: cutoff), messageID: "boundary", cwd: "/work/new", input: 2),
            line(timestamp: formatter.string(from: now.addingTimeInterval(3_600)), messageID: "future", input: 200),
        ], relativeTo: project, path: "projects/p/main.jsonl")
        let report = try load(project)
        XCTAssertEqual(report.samples, [UsageSample(
            hour: cutoff, sessionID: "abcdef0123456789-1111", project: "original", model: "opus-4-5", tokens: TokenCounts(input: 2)
        )])
        XCTAssertEqual(sumInput(report), 302, "Existing rows retain their full history")
        let partialHour = try TranscriptLoader.load(
            environment: [configKey: project.path], now: now.addingTimeInterval(1), timeZone: gmt
        )
        XCTAssertTrue(partialHour.samples.isEmpty, "Retention compares the UTC hour start to the cutoff")
    }

    private let configKey = "CLAUDE_CONFIG_DIR"

    private func load(_ project: URL) throws -> UsageReport {
        try TranscriptLoader.load(environment: [configKey: project.path], now: now, timeZone: gmt)
    }

    private func sumInput(_ report: UsageReport) -> UInt64 {
        report.daily.reduce(0) { $0 + $1.tokens.input }
    }

    private func write(_ lines: [String], relativeTo base: URL, path: String) throws {
        try writeRaw(lines.joined(separator: "\n") + "\n", relativeTo: base, path: path)
    }

    private func writeRaw(_ text: String, relativeTo base: URL, path: String) throws {
        var url = base
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func line(
        timestamp: String = "2024-06-15T16:00:00Z",
        messageID: String? = "m",
        requestID: String? = "r",
        sessionID: String? = "abcdef0123456789-1111",
        sidechain: Bool? = nil,
        cwd: String? = "/work/demo",
        model: String? = "claude-opus-4-5-20251101",
        input: Int = 1,
        output: Int = 0,
        cacheCreate: Int = 0,
        cacheRead: Int = 0,
        iterations: [[String: Any]] = []
    ) -> String {
        var usage: [String: Any] = [
            "input_tokens": input,
            "output_tokens": output,
            "cache_creation_input_tokens": cacheCreate,
            "cache_read_input_tokens": cacheRead,
        ]
        if !iterations.isEmpty {
            usage["iterations"] = iterations
        }
        var message: [String: Any] = ["usage": usage]
        if let messageID { message["id"] = messageID }
        if let model { message["model"] = model }
        var object: [String: Any] = [
            "timestamp": timestamp,
            "message": message,
        ]
        if let requestID { object["requestId"] = requestID }
        if let sessionID { object["sessionId"] = sessionID }
        if let sidechain { object["isSidechain"] = sidechain }
        if let cwd { object["cwd"] = cwd }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = gmt
        return formatter.date(from: text)!
    }

    private func format(timestamp: String, pattern: String) -> String {
        format(date: date(timestamp), pattern: pattern)
    }

    private func format(year: Int, month: Int, day: Int, pattern: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = gmt
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        return format(date: calendar.date(from: components)!, pattern: pattern)
    }

    private func format(date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = gmt
        formatter.calendar = calendar
        formatter.timeZone = gmt
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

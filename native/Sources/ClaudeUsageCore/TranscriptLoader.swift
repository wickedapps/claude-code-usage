import Foundation

private let sessionLength: TimeInterval = 5 * 60 * 60
private let syntheticModel = "<synthetic>"
private let advisorIteration = "advisor_message"
private let usageMarker = "\"usage\":{"
private let modelLabelSegments = 3
private let modelDateLength = 8
private let sessionIDCharacters = 8
private let projectsDirectoryName = "projects"
private let configDirectoryEnvironment = "CLAUDE_CONFIG_DIR"
private let xdgConfigEnvironment = "XDG_CONFIG_HOME"

enum TranscriptLoadError: LocalizedError {
    case noLogs
    case noTokenUsage

    var errorDescription: String? {
        switch self {
        case .noLogs:
            return "No Claude Code logs found in ~/.claude/projects or ~/.config/claude/projects"
        case .noTokenUsage:
            return "Found Claude Code logs, but none had token usage"
        }
    }
}

public enum TranscriptLoader {
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()
    ) throws -> UsageReport {
        try load(environment: environment, now: now, timeZone: .current)
    }

    static func load(
        environment: [String: String],
        now: Date,
        timeZone: TimeZone
    ) throws -> UsageReport {
        let files = usageFiles(environment: environment)
        if files.isEmpty {
            throw TranscriptLoadError.noLogs
        }

        var entries: [TranscriptEntry] = []
        for file in files {
            readFile(file, into: &entries)
        }
        entries = deduplicate(entries)
        if entries.isEmpty {
            throw TranscriptLoadError.noTokenUsage
        }

        var report = UsageReport()
        report.daily = aggregateDaily(entries, now: now, timeZone: timeZone)
        report.weekly = aggregateWeekly(entries, timeZone: timeZone)
        report.monthly = aggregateMonthly(entries, timeZone: timeZone)
        report.sessions = aggregateSessions(entries, timeZone: timeZone)
        report.blocks = aggregateBlocks(entries, now: now, timeZone: timeZone)
        report.samples = aggregateSamples(entries, now: now)
        return report
    }
}

private struct TranscriptEntry {
    var timestamp: Date
    var sessionID: String
    var project: String
    var model: String
    var tokens: TokenCounts
    var messageID: String?
    var requestID: String?
    var isSidechain: Bool
}

private struct ExactKey: Hashable {
    var messageID: String
    var requestID: String?
}

private struct UsageBucket {
    var tokens = TokenCounts()
    var models = Set<String>()
    var first: Date?
    var last: Date?

    mutating func add(_ entry: TranscriptEntry) {
        tokens.add(entry.tokens)
        if !entry.model.isEmpty && entry.model != syntheticModel {
            models.insert(shortModel(entry.model))
        }
        first = first.map { min($0, entry.timestamp) } ?? entry.timestamp
        last = last.map { max($0, entry.timestamp) } ?? entry.timestamp
    }
}

private struct TranscriptLine: Decodable {
    var timestamp: String?
    var requestID: String?
    var sessionID: String?
    var isSidechain: Bool?
    var cwd: String?
    var message: TranscriptMessage?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case requestID = "requestId"
        case sessionID = "sessionId"
        case isSidechain
        case cwd
        case message
    }
}

private struct TranscriptMessage: Decodable {
    var id: String?
    var model: String?
    var usage: RawUsage?
}

private struct RawUsage: Decodable {
    var inputTokens: UInt64 = 0
    var outputTokens: UInt64 = 0
    var cacheCreationInputTokens: UInt64 = 0
    var cacheReadInputTokens: UInt64 = 0
    var iterations: [RawIteration] = []

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case iterations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try decodeCount(container, .inputTokens)
        outputTokens = try decodeCount(container, .outputTokens)
        cacheCreationInputTokens = try decodeCount(container, .cacheCreationInputTokens)
        cacheReadInputTokens = try decodeCount(container, .cacheReadInputTokens)
        if container.contains(.iterations) {
            iterations = try container.decode([RawIteration].self, forKey: .iterations)
        } else {
            iterations = []
        }
    }
}

private struct RawIteration: Decodable {
    var kind: String?
    var model: String?
    var inputTokens: UInt64 = 0
    var outputTokens: UInt64 = 0
    var cacheCreationInputTokens: UInt64 = 0
    var cacheReadInputTokens: UInt64 = 0

    enum CodingKeys: String, CodingKey {
        case kind = "type"
        case model
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        inputTokens = try decodeCount(container, .inputTokens)
        outputTokens = try decodeCount(container, .outputTokens)
        cacheCreationInputTokens = try decodeCount(container, .cacheCreationInputTokens)
        cacheReadInputTokens = try decodeCount(container, .cacheReadInputTokens)
    }
}

/// Missing counts default to zero. An explicit null fails the line.
private func decodeCount<Key: CodingKey>(
    _ container: KeyedDecodingContainer<Key>,
    _ key: Key
) throws -> UInt64 {
    if container.contains(key) {
        return try container.decode(UInt64.self, forKey: key)
    }
    return 0
}

private func usageFiles(environment: [String: String]) -> [URL] {
    var files: [URL] = []
    for root in claudeRoots(environment: environment) {
        walkJSONL(root.appendingPathComponent(projectsDirectoryName, isDirectory: true), into: &files)
    }
    files.sort { $0.path < $1.path }
    return files
}

/// An explicit `CLAUDE_CONFIG_DIR` wins outright. A value that points nowhere
/// falls through, and then both `~/.config/claude` and `~/.claude` count.
private func claudeRoots(environment: [String: String]) -> [URL] {
    if let raw = environment[configDirectoryEnvironment] {
        var roots: [URL] = []
        for part in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            let expanded = expandHome(trimmed, home: environment["HOME"])
            let root = configRoot(expanded)
            if isDirectory(root.appendingPathComponent(projectsDirectoryName, isDirectory: true)) {
                roots.append(root)
            }
        }
        if !roots.isEmpty {
            return roots
        }
    }

    guard let home = environment["HOME"] else { return [] }
    let homeURL = URL(fileURLWithPath: home, isDirectory: !home.isEmpty)
    let configHome: URL
    if let xdg = environment[xdgConfigEnvironment] {
        configHome = URL(fileURLWithPath: xdg, isDirectory: !xdg.isEmpty)
    } else {
        configHome = homeURL.appendingPathComponent(".config", isDirectory: true)
    }

    var roots: [URL] = []
    for root in [
        configHome.appendingPathComponent("claude", isDirectory: true),
        homeURL.appendingPathComponent(".claude", isDirectory: true),
    ] {
        if isDirectory(root.appendingPathComponent(projectsDirectoryName, isDirectory: true)) {
            roots.append(root)
        }
    }
    return roots
}

private func configRoot(_ path: String) -> URL {
    var lexical = path
    while lexical.count > 1 && lexical.hasSuffix("/") {
        lexical.removeLast()
    }
    let url = URL(fileURLWithPath: lexical, isDirectory: true)
    if url.lastPathComponent == projectsDirectoryName {
        return url.deletingLastPathComponent()
    }
    return url
}

private func expandHome(_ raw: String, home: String?) -> String {
    guard raw.hasPrefix("~/"), let home else { return raw }
    let rest = String(raw.dropFirst(2))
    if rest.isEmpty { return home }
    var url = URL(fileURLWithPath: home, isDirectory: true)
    for part in rest.split(separator: "/") where !part.isEmpty {
        url.appendPathComponent(String(part))
    }
    return url.path
}

private func walkJSONL(_ directory: URL, into files: inout [URL]) {
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    ) else { return }

    for entry in entries {
        if isDirectory(entry) {
            walkJSONL(entry, into: &files)
        } else if isJSONL(entry) {
            files.append(entry)
        }
    }
}

private func isJSONL(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    guard let dot = name.lastIndex(of: ".") else { return false }
    if dot == name.startIndex { return false }
    return name[name.index(after: dot)...] == "jsonl"
}

private func isDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
}

private func readFile(_ url: URL, into entries: inout [TranscriptEntry]) {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
    let pathSessionID = sessionID(from: url)
    let decoder = JSONDecoder()
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = Substring(rawLine)
        if line.last == "\r" { line = line.dropLast() }
        if !line.contains(usageMarker) { continue }
        guard let data = String(line).data(using: .utf8),
              let parsed = try? decoder.decode(TranscriptLine.self, from: data),
              let message = parsed.message,
              let usage = message.usage,
              let timestampText = parsed.timestamp,
              let timestamp = parseTimestamp(timestampText) else { continue }

        let model = message.model.flatMap { blank($0) ? nil : $0 } ?? ""
        let tokens = TokenCounts(
            input: usage.inputTokens,
            output: usage.outputTokens,
            cacheCreate: usage.cacheCreationInputTokens,
            cacheRead: usage.cacheReadInputTokens
        )
        let sessionID = parsed.sessionID.flatMap { $0.isEmpty ? nil : $0 } ?? pathSessionID
        let project = parsed.cwd.map(projectName) ?? ""
        let sidechain = parsed.isSidechain ?? false
        entries.append(TranscriptEntry(
            timestamp: timestamp,
            sessionID: sessionID,
            project: project,
            model: model,
            tokens: tokens,
            messageID: message.id,
            requestID: parsed.requestID,
            isSidechain: sidechain
        ))

        // Advisor turns are billed separately but nest inside the parent usage
        // block. The index keeps their derived message ids distinct.
        for (index, iteration) in usage.iterations.enumerated() {
            guard iteration.kind == advisorIteration else { continue }
            entries.append(TranscriptEntry(
                timestamp: timestamp,
                sessionID: sessionID,
                project: project,
                model: iteration.model ?? "",
                tokens: TokenCounts(
                    input: iteration.inputTokens,
                    output: iteration.outputTokens,
                    cacheCreate: iteration.cacheCreationInputTokens,
                    cacheRead: iteration.cacheReadInputTokens
                ),
                messageID: message.id.map { "\($0):advisor:\(index)" },
                requestID: parsed.requestID,
                isSidechain: sidechain
            ))
        }
    }
}

/// An exact `(message, request)` match is one turn written twice. The same
/// message under the opposite sidechain flag is the parent/subagent pair, and
/// the non-sidechain copy wins. Same message, different request, same flag
/// stays as two turns. `byMessage` keeps the latest index, matching `HashMap::insert`.
private func deduplicate(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
    var exact: [ExactKey: Int] = [:]
    var byMessage: [String: Int] = [:]
    var kept: [TranscriptEntry] = []

    for entry in entries {
        guard let messageID = entry.messageID else {
            kept.append(entry)
            continue
        }
        let exactKey = ExactKey(messageID: messageID, requestID: entry.requestID)
        if let index = exact[exactKey] {
            if shouldReplace(entry, kept[index]) {
                kept[index] = entry
            }
            continue
        }
        if let index = byMessage[messageID], entry.isSidechain != kept[index].isSidechain {
            if entry.isSidechain { continue }
            kept[index] = entry
            exact[exactKey] = index
            continue
        }
        let index = kept.count
        exact[exactKey] = index
        byMessage[messageID] = index
        kept.append(entry)
    }
    return kept
}

/// Prefer the non-sidechain copy, then the larger token count. A streaming
/// turn can be copied before it finishes, so the shorter copy loses.
private func shouldReplace(_ candidate: TranscriptEntry, _ existing: TranscriptEntry) -> Bool {
    if candidate.isSidechain != existing.isSidechain {
        return existing.isSidechain
    }
    return candidate.tokens.total > existing.tokens.total
}

private func aggregateDaily(_ entries: [TranscriptEntry], now: Date, timeZone: TimeZone) -> [UsageRow] {
    var buckets: [String: UsageBucket] = [:]
    for entry in entries {
        let key = localDateKey(entry.timestamp, timeZone: timeZone)
        var bucket = buckets[key] ?? UsageBucket()
        bucket.add(entry)
        buckets[key] = bucket
    }
    return newestRows(buckets) { key, bucket in
        usageRow(
            id: key,
            title: formatDayKey(key, now: now, timeZone: timeZone),
            detail: modelsLabel(bucket.models),
            bucket: bucket
        )
    }
}

private func aggregateWeekly(_ entries: [TranscriptEntry], timeZone: TimeZone) -> [UsageRow] {
    var buckets: [String: UsageBucket] = [:]
    for entry in entries {
        let key = weekKey(entry.timestamp, timeZone: timeZone)
        var bucket = buckets[key] ?? UsageBucket()
        bucket.add(entry)
        buckets[key] = bucket
    }
    return newestRows(buckets) { key, bucket in
        usageRow(id: key, title: formatWeekKey(key), detail: modelsLabel(bucket.models), bucket: bucket)
    }
}

private func aggregateMonthly(_ entries: [TranscriptEntry], timeZone: TimeZone) -> [UsageRow] {
    var buckets: [String: UsageBucket] = [:]
    for entry in entries {
        let key = monthKey(entry.timestamp, timeZone: timeZone)
        var bucket = buckets[key] ?? UsageBucket()
        bucket.add(entry)
        buckets[key] = bucket
    }
    return newestRows(buckets) { key, bucket in
        usageRow(id: key, title: formatMonthKey(key, timeZone: timeZone), detail: modelsLabel(bucket.models), bucket: bucket)
    }
}

private func aggregateSessions(_ entries: [TranscriptEntry], timeZone: TimeZone) -> [UsageRow] {
    var buckets: [String: UsageBucket] = [:]
    var projects: [String: String] = [:]
    for entry in entries {
        var bucket = buckets[entry.sessionID] ?? UsageBucket()
        bucket.add(entry)
        buckets[entry.sessionID] = bucket
        if !entry.project.isEmpty && projects[entry.sessionID] == nil {
            projects[entry.sessionID] = entry.project
        }
    }
    let ordered = buckets.keys.sorted().map { sessionID in
        (sessionID, buckets[sessionID] ?? UsageBucket())
    }
    let rows = ordered.map { sessionID, bucket -> (UInt64, UsageRow) in
        let last = bucket.last.map { formatSessionDate($0, timeZone: timeZone) } ?? "unknown"
        return (
            bucket.tokens.total,
            usageRow(
                id: sessionID,
                title: sessionTitle(project: projects[sessionID], sessionID: sessionID),
                detail: last,
                bucket: bucket
            )
        )
    }
    return rows.sorted { $0.0 > $1.0 }.map(\.1)
}

private struct SampleKey: Hashable {
    var hour: Date
    var sessionID: String
    var project: String
    var model: String
}

private func aggregateSamples(_ entries: [TranscriptEntry], now: Date) -> [UsageSample] {
    var projects: [String: String] = [:]
    for entry in entries where !entry.project.isEmpty && projects[entry.sessionID] == nil {
        projects[entry.sessionID] = entry.project
    }

    let cutoff = now.addingTimeInterval(-92 * 86_400)
    var buckets: [SampleKey: TokenCounts] = [:]
    for entry in entries {
        let hour = floorToHour(entry.timestamp)
        guard hour >= cutoff, hour <= now else { continue }
        let key = SampleKey(
            hour: hour,
            sessionID: entry.sessionID,
            project: projects[entry.sessionID] ?? "",
            model: entry.model.isEmpty || entry.model == syntheticModel ? "unknown" : shortModel(entry.model)
        )
        buckets[key, default: TokenCounts()].add(entry.tokens)
    }
    return buckets.map { key, tokens in
        UsageSample(hour: key.hour, sessionID: key.sessionID, project: key.project, model: key.model, tokens: tokens)
    }.sorted {
        if $0.hour != $1.hour { return $0.hour < $1.hour }
        if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
        if $0.project != $1.project { return $0.project < $1.project }
        return $0.model < $1.model
    }
}

/// The first turn opens a block on the UTC hour. A later turn closes it when
/// it lands more than five hours after the block started or after the previous turn.
private func aggregateBlocks(_ entries: [TranscriptEntry], now: Date, timeZone: TimeZone) -> [UsageRow] {
    let sorted = entries.sorted { $0.timestamp < $1.timestamp }
    var rows: [UsageRow] = []
    var start: Date?
    var current: [TranscriptEntry] = []

    for entry in sorted {
        guard let blockStart = start else {
            start = floorToHour(entry.timestamp)
            current = [entry]
            continue
        }
        let last = current.last?.timestamp ?? blockStart
        let sinceStart = entry.timestamp.timeIntervalSince(blockStart)
        let sinceLast = entry.timestamp.timeIntervalSince(last)
        if sinceStart > sessionLength || sinceLast > sessionLength {
            rows.append(blockRow(start: blockStart, entries: current, now: now, timeZone: timeZone))
            start = floorToHour(entry.timestamp)
            current = [entry]
        } else {
            current.append(entry)
        }
    }

    if let blockStart = start {
        rows.append(blockRow(start: blockStart, entries: current, now: now, timeZone: timeZone))
    }
    rows.reverse()
    return rows
}

private func blockRow(start: Date, entries: [TranscriptEntry], now: Date, timeZone: TimeZone) -> UsageRow {
    let end = start.addingTimeInterval(sessionLength)
    let actualEnd = entries.last?.timestamp ?? start
    let active = now.timeIntervalSince(actualEnd) < sessionLength && now < end
    var bucket = UsageBucket()
    for entry in entries {
        bucket.add(entry)
    }
    let status: String
    if active {
        status = "\(formatDuration(max(0, end.timeIntervalSince(now)))) left"
    } else {
        status = "Completed \u{00B7} \(formatDuration(actualEnd.timeIntervalSince(start)))"
    }
    return usageRow(
        id: utcTimestamp(start),
        title: formatLocal(start, pattern: "MMM dd HH:mm", timeZone: timeZone),
        detail: status,
        bucket: bucket,
        active: active
    )
}

private func floorToHour(_ timestamp: Date) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let parts = calendar.dateComponents([.year, .month, .day, .hour], from: timestamp)
    return calendar.date(from: parts) ?? timestamp
}

private func newestRows(
    _ buckets: [String: UsageBucket],
    toRow: (String, UsageBucket) -> UsageRow
) -> [UsageRow] {
    var rows = buckets.keys.sorted().map { toRow($0, buckets[$0] ?? UsageBucket()) }
    rows.reverse()
    return rows
}

private func usageRow(
    id: String,
    title: String,
    detail: String,
    bucket: UsageBucket,
    active: Bool = false
) -> UsageRow {
    UsageRow(id: id, title: title, detail: detail, tokens: bucket.tokens, active: active)
}

/// `projects/<project>/<session>.jsonl`, or `.../<session>/subagents/<agent>.jsonl`.
/// Subagent files report the parent session. Used only when a line has no sessionId.
private func sessionID(from url: URL) -> String {
    let parts = url.pathComponents
    guard let projectsIndex = parts.firstIndex(of: projectsDirectoryName) else {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "unknown" : stem
    }
    let relative = Array(parts.suffix(from: projectsIndex + 1))
    if relative.count >= 4 && relative[relative.count - 2] == "subagents" {
        return relative[relative.count - 3]
    }
    if relative.isEmpty { return "unknown" }
    let index = relative.count >= 2 ? relative.count - 2 : 0
    if relative.count == 2 {
        return strippingJSONLSuffix(relative[1])
    }
    return strippingJSONLSuffix(relative[index])
}

private func strippingJSONLSuffix(_ name: String) -> String {
    guard name.hasSuffix(".jsonl") else { return name }
    return String(name.dropLast(".jsonl".count))
}

private func parseTimestamp(_ value: String) -> Date? {
    let bytes = Array(value.utf8)
    func digit(_ index: Int) -> Int? {
        guard index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 else { return nil }
        return Int(bytes[index] - 48)
    }
    func number(_ start: Int, _ count: Int) -> Int? {
        var value = 0
        for offset in 0..<count {
            guard let part = digit(start + offset) else { return nil }
            value = value * 10 + part
        }
        return value
    }
    guard bytes.count >= 20,
          let year = number(0, 4), bytes[4] == 45,
          let month = number(5, 2), bytes[7] == 45,
          let day = number(8, 2),
          bytes[10] == 84,
          let hour = number(11, 2), bytes[13] == 58,
          let minute = number(14, 2), bytes[16] == 58,
          let second = number(17, 2),
          (1...12).contains(month),
          (1...31).contains(day),
          (0...23).contains(hour),
          (0...59).contains(minute),
          (0...59).contains(second) else { return nil }

    var index = 19
    var nanoseconds = 0
    if index < bytes.count && bytes[index] == 46 {
        index += 1
        var digits = 0
        var sawDigit = false
        while index < bytes.count, let part = digit(index) {
            if digits < 9 {
                nanoseconds = nanoseconds * 10 + part
                digits += 1
            }
            sawDigit = true
            index += 1
        }
        guard sawDigit else { return nil }
        while digits < 9 {
            nanoseconds *= 10
            digits += 1
        }
    }

    guard index < bytes.count else { return nil }
    let offset: Int
    if bytes[index] == 90 {
        offset = 0
        index += 1
    } else if bytes[index] == 43 || bytes[index] == 45 {
        let sign = bytes[index] == 45 ? -1 : 1
        index += 1
        guard let offsetHour = number(index, 2), index + 2 < bytes.count, bytes[index + 2] == 58 else { return nil }
        index += 3
        guard let offsetMinute = number(index, 2), (0...23).contains(offsetHour), (0...59).contains(offsetMinute) else {
            return nil
        }
        index += 2
        offset = sign * (offsetHour * 3600 + offsetMinute * 60)
    } else {
        return nil
    }
    guard index == bytes.count else { return nil }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    components.nanosecond = nanoseconds
    guard let parsed = calendar.date(from: components) else { return nil }
    let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed)
    guard roundTrip.year == year,
          roundTrip.month == month,
          roundTrip.day == day,
          roundTrip.hour == hour,
          roundTrip.minute == minute,
          roundTrip.second == second else { return nil }
    return parsed.addingTimeInterval(TimeInterval(-offset))
}

private func localDateKey(_ timestamp: Date, timeZone: TimeZone) -> String {
    let calendar = gregorian(timeZone)
    let parts = calendar.dateComponents([.year, .month, .day], from: timestamp)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

private func weekKey(_ timestamp: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = timeZone
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    let week = calendar.component(.weekOfYear, from: timestamp)
    let year = calendar.component(.yearForWeekOfYear, from: timestamp)
    return String(format: "%d-W%02d", year, week)
}

private func monthKey(_ timestamp: Date, timeZone: TimeZone) -> String {
    let calendar = gregorian(timeZone)
    let parts = calendar.dateComponents([.year, .month], from: timestamp)
    return String(format: "%d-%02d", parts.year ?? 0, parts.month ?? 0)
}

private func formatDayKey(_ key: String, now: Date, timeZone: TimeZone) -> String {
    let parts = key.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2]),
          let date = localDate(year: year, month: month, day: day, timeZone: timeZone) else { return key }
    let nowYear = gregorian(timeZone).component(.year, from: now)
    let pattern = year == nowYear ? "MMM dd" : "MMM dd, yyyy"
    return formatLocal(date, pattern: pattern, timeZone: timeZone)
}

private func formatWeekKey(_ key: String) -> String {
    guard let separator = key.range(of: "-W") else { return key }
    let year = key[..<separator.lowerBound]
    let week = key[separator.upperBound...]
    return "W\(week) \(year)"
}

private func formatMonthKey(_ key: String, timeZone: TimeZone) -> String {
    let parts = key.split(separator: "-")
    guard let yearPart = parts.first,
          let monthPart = parts.dropFirst().first,
          let year = Int(yearPart),
          let month = Int(monthPart),
          let date = localDate(year: year, month: month, day: 1, timeZone: timeZone) else { return key }
    return formatLocal(date, pattern: "MMM yyyy", timeZone: timeZone)
}

private func formatSessionDate(_ timestamp: Date, timeZone: TimeZone) -> String {
    formatLocal(timestamp, pattern: "MMM dd, yyyy", timeZone: timeZone)
}

private func formatLocal(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.calendar = gregorian(timeZone)
    formatter.timeZone = timeZone
    formatter.dateFormat = pattern
    return formatter.string(from: date)
}

private func localDate(year: Int, month: Int, day: Int, timeZone: TimeZone) -> Date? {
    let calendar = gregorian(timeZone)
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = 12
    guard let date = calendar.date(from: components) else { return nil }
    let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
    guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
    return date
}

private func gregorian(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

private func shortModel(_ model: String) -> String {
    var rest = model
    let prefix = "claude-"
    while rest.hasPrefix(prefix) {
        rest.removeFirst(prefix.count)
    }
    let parts = rest.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    return parts.filter { !isDateSuffix($0) }.prefix(modelLabelSegments).joined(separator: "-")
}

private func isDateSuffix(_ part: String) -> Bool {
    part.count == modelDateLength && part.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
}

private func projectName(_ cwd: String) -> String {
    if cwd.isEmpty { return "" }
    var path = cwd
    while path.count > 1 && path.hasSuffix("/") {
        path.removeLast()
    }
    if path == "/" { return cwd }
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty ? cwd : name
}

private func sessionTitle(project: String?, sessionID: String) -> String {
    let short = shortSession(sessionID)
    guard let project else { return short }
    return "\(project) \u{00B7} \(short)"
}

private func shortSession(_ sessionID: String) -> String {
    let head: String
    if let dash = sessionID.firstIndex(of: "-") {
        head = String(sessionID[..<dash])
    } else {
        head = sessionID
    }
    return String(head.prefix(sessionIDCharacters))
}

private func modelsLabel(_ models: Set<String>) -> String {
    if models.isEmpty { return "unknown model" }
    return models.sorted().joined(separator: ", ")
}

private func formatDuration(_ interval: TimeInterval) -> String {
    let totalMinutes = max(0, Int(interval / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

private func utcTimestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func blank(_ value: String) -> Bool {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

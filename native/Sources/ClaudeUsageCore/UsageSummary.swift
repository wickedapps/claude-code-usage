import Foundation

extension UsageReport {
    /// Range totals, chart series, and breakdowns computed from `samples`.
    /// Ranges end at `now`: the past 24 hours, or the last N local calendar days including today.
    /// `include` narrows the samples, as for one model's or project's detail.
    public func summary(
        _ range: UsageRange, now: Date = Date(), timeZone: TimeZone = .current,
        matching include: (UsageSample) -> Bool = { _ in true }
    ) -> UsageSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let currentHour = utcHour(now)
        let starts: [Date]
        if range.hourly {
            starts = (0..<24).map { currentHour.addingTimeInterval(TimeInterval($0 - 23) * 3_600) }
        } else {
            let count: Int
            switch range {
            case .day: count = 24
            case .week: count = 7
            case .month: count = 30
            case .quarter: count = 90
            }
            let today = calendar.startOfDay(for: now)
            starts = (0..<count).map { calendar.date(byAdding: .day, value: $0 - count + 1, to: today)! }
        }

        var result = UsageSummary(range: range, start: starts[0], end: now)
        result.series = starts.map { UsageSeriesPoint(start: $0) }

        // Compute hour-to-bucket assignments once, rather than doing calendar
        // arithmetic for every sample. Half-hour zones attribute an hour's tokens
        // to the local day in which that UTC hour starts.
        var assignments: [Date: SummaryAssignment] = [:]
        if range.hourly {
            for (index, hour) in starts.enumerated() {
                assignments[hour] = SummaryAssignment(index: index, day: calendar.startOfDay(for: hour))
            }
        } else {
            var hour = utcHour(starts[0])
            if hour < starts[0] { hour = hour.addingTimeInterval(3_600) }
            var index = 0
            while hour <= currentHour {
                while index + 1 < starts.count && hour >= starts[index + 1] { index += 1 }
                assignments[hour] = SummaryAssignment(index: index, day: starts[index])
                hour = hour.addingTimeInterval(3_600)
            }
        }

        aggregate(into: &result, assignments: assignments, calendar: calendar, include: include)
        return result
    }

    /// One local calendar day in hourly buckets, for a day's detail. `id` is a
    /// `UsageSummary.days` id (`yyyy-MM-dd`); nil when it doesn't parse. The
    /// result's range is `.day` because its buckets are hours.
    public func summary(day id: String, now: Date = Date(), timeZone: TimeZone = .current) -> UsageSummary? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let parsed = dayFormatter(pattern: "yyyy-MM-dd", calendar: calendar).date(from: id),
              let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: parsed)) else { return nil }
        let day = calendar.startOfDay(for: parsed)
        // Same attribution as the range summary: an hour belongs to the day it starts in.
        var hour = utcHour(day)
        if hour < day { hour = hour.addingTimeInterval(3_600) }
        var starts: [Date] = []
        while hour < next {
            starts.append(hour)
            hour = hour.addingTimeInterval(3_600)
        }
        guard let first = starts.first else { return nil }

        var result = UsageSummary(range: .day, start: first, end: min(now, next.addingTimeInterval(-1)))
        result.series = starts.map { UsageSeriesPoint(start: $0) }
        var assignments: [Date: SummaryAssignment] = [:]
        for (index, start) in starts.enumerated() {
            assignments[start] = SummaryAssignment(index: index, day: day)
        }
        aggregate(into: &result, assignments: assignments, calendar: calendar, include: { _ in true })
        return result
    }

    /// Adds every included sample up to `result.end` to its assigned bucket and breakdowns.
    private func aggregate(
        into result: inout UsageSummary, assignments: [Date: SummaryAssignment],
        calendar: Calendar, include: (UsageSample) -> Bool
    ) {
        var sessions = Set<String>()
        var models: [String: SummaryBucket] = [:]
        var projects: [String: SummaryBucket] = [:]
        var days: [Date: SummaryBucket] = [:]
        for sample in samples {
            guard sample.hour <= result.end,
                  let assignment = assignments[sample.hour],
                  include(sample) else { continue }
            result.totals.add(sample.tokens)
            if sample.tokens.total > 0 { sessions.insert(sample.sessionID) }
            result.series[assignment.index].tokens.add(sample.tokens)
            result.series[assignment.index].byModel[sample.model, default: 0] += sample.tokens.total
            models[sample.model, default: SummaryBucket()].add(sample)
            projects[sample.project, default: SummaryBucket()].add(sample)
            days[assignment.day, default: SummaryBucket()].add(sample)
        }
        result.sessions = sessions.count
        let total = result.totals.total
        result.models = models.map { key, bucket in
            bucket.row(id: key, title: key, total: total)
        }.sorted(by: largestFirst)
        result.projects = projects.map { key, bucket in
            bucket.row(id: key, title: key.isEmpty ? "Other" : key, total: total)
        }.sorted(by: largestFirst)

        let idFormatter = dayFormatter(pattern: "yyyy-MM-dd", calendar: calendar)
        let titleFormatter = dayFormatter(pattern: "MMM d", calendar: calendar)
        result.days = days.keys.filter { days[$0]!.tokens.total > 0 }.sorted(by: >).map { day in
            days[day]!.row(
                id: idFormatter.string(from: day), title: titleFormatter.string(from: day), total: total
            )
        }
    }
}

private struct SummaryAssignment {
    var index: Int
    var day: Date
}

private struct SummaryBucket {
    var tokens = TokenCounts()
    var sessions = Set<String>()

    mutating func add(_ sample: UsageSample) {
        tokens.add(sample.tokens)
        if sample.tokens.total > 0 { sessions.insert(sample.sessionID) }
    }

    func row(id: String, title: String, total: UInt64) -> UsageBreakdownRow {
        UsageBreakdownRow(
            id: id, title: title, sessions: sessions.count, tokens: tokens,
            share: total == 0 ? 0 : Double(tokens.total) / Double(total)
        )
    }
}

private func largestFirst(_ lhs: UsageBreakdownRow, _ rhs: UsageBreakdownRow) -> Bool {
    if lhs.tokens.total != rhs.tokens.total { return lhs.tokens.total > rhs.tokens.total }
    return lhs.id < rhs.id
}

private func utcHour(_ date: Date) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3_600) * 3_600)
}

private func dayFormatter(pattern: String, calendar: Calendar) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = pattern
    return formatter
}

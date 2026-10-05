import Foundation
import ClaudeUsageCore

/// A constant-rate estimate from the usage accumulated in this quota window.
struct QuotaPace: Equatable {
    enum Status: Equatable {
        case unknown
        case over(runsOutIn: TimeInterval)
        case ahead
        case onTrack(projected: Double)
    }

    let status: Status

    init(window: QuotaWindow, kind: QuotaKind, now: Date) {
        guard let reset = window.resetsAt, window.used.isFinite else {
            status = .unknown
            return
        }
        let remainingSeconds = reset.timeIntervalSince(now)
        let elapsed = min(1, max(0, 1 - remainingSeconds / kind.duration))
        guard elapsed >= 0.05 else {
            status = .unknown
            return
        }
        let used = min(100, max(0, window.used))
        let projected = used / elapsed
        if projected > 100 {
            let rate = used / (elapsed * kind.duration)
            let runsOutIn = max(0, (100 - used) / rate)
            if runsOutIn < remainingSeconds {
                status = .over(runsOutIn: runsOutIn)
                return
            }
        }
        status = projected >= 85 && projected <= 100 ? .ahead : .onTrack(projected: projected)
    }

    var sentence: String? {
        switch status {
        case .unknown: return nil
        case .ahead: return "Close to the limit at this pace"
        case .onTrack(let projected): return "On pace to use about \(Int(projected.rounded()))% by reset"
        case .over(let interval): return "At this pace, runs out in about \(Self.duration(interval))"
        }
    }

    var symbol: String? {
        switch status {
        case .unknown: return nil
        case .onTrack: return "chart.line.downtrend.xyaxis"
        case .ahead, .over: return "chart.line.uptrend.xyaxis"
        }
    }

    var needsAttention: Bool {
        switch status {
        case .ahead, .over: return true
        case .unknown, .onTrack: return false
        }
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(1, Int((interval / 60).rounded()))
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

import Foundation
import ClaudeUsageCore

/// Display strings shared by the dashboard and the menu-bar preview.
enum UsageFormat {
    static let dangerRemaining = 10.0
    static let warningRemaining = 30.0

    static func tokens(_ value: UInt64) -> String {
        if value >= 1_000_000 {
            return compact(Double(value) / 1_000_000, unit: "M")
        }
        if value >= 1_000 {
            return compact(Double(value) / 1_000, unit: "K")
        }
        return String(value)
    }

    /// Dashboard counts use three significant digits, with rounding into the next unit.
    static func compactTokens(_ value: UInt64) -> String {
        guard value >= 1_000 else { return String(value) }
        let units = [(1_000, "K"), (1_000_000, "M"), (1_000_000_000, "B")]
        var index = value >= 1_000_000_000 ? 2 : value >= 1_000_000 ? 1 : 0
        let locale = Locale(identifier: "en_US_POSIX")
        var scaled = Decimal(string: String(value), locale: locale)! / Decimal(units[index].0)
        let places = 2 - Int(floor(log10(NSDecimalNumber(decimal: scaled).doubleValue)))
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, places, .plain)
        if rounded >= 1_000, index < units.count - 1 {
            index += 1
            rounded /= 1_000
        }
        let text = NSDecimalNumber(decimal: rounded).description(withLocale: locale)
        return text + units[index].1
    }

    static func share(_ fraction: Double) -> String {
        let value = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), value * 100)
    }

    static func percentLabel(_ window: QuotaWindow, mode: PercentMode) -> String {
        String(format: "%.0f%% %@", window.percentage(mode), mode == .left ? "left" : "used")
    }

    /// Window-card timing. A future reset is spelled out; a missing one uses the model wording.
    static func quotaTiming(_ window: QuotaWindow, kind: QuotaKind, now: Date = Date()) -> String {
        let fiveHour = kind == .fiveHour
        let text = resetDescription(window.resetsAt, now: now, fiveHour: fiveHour)
        if window.resetsAt == nil || text == "Reset due" {
            return text
        }
        return "Resets in \(text)"
    }

    static func columnTitles(for tab: UsageTab) -> (title: String, detail: String) {
        switch tab {
        case .daily:
            return ("Day", "Models")
        case .weekly:
            return ("Week", "Models")
        case .monthly:
            return ("Month", "Models")
        case .sessions:
            return ("Session", "Last active")
        case .blocks:
            return ("Started", "Status")
        }
    }

    static func dashboardNotice(state: SessionState, limits: QuotaLimits?) -> String? {
        switch state {
        case .apiBilling:
            return "Claude Code is billed per token, so there are no 5-hour or weekly limits to track. The token counts below come from your local transcripts."
        case .expired:
            return "Claude Code's access token has expired. You're still logged in: open Claude Code to refresh it, and the limits return on the next refresh."
        default:
            if limits?.isEmpty == true {
                return "Your plan did not report any usage limits."
            }
            return nil
        }
    }

    /// Menu-bar line: `5h 62% · 7d 41%`.
    static func menuBarTitle(
        state: SessionState,
        limits: QuotaLimits?,
        settings: MenuBarSettings,
        loading: Bool,
        now: Date = Date()
    ) -> String {
        switch state {
        case .signedOut:
            return "Claude: signed out"
        case .apiBilling:
            return "Claude: API billing"
        case .expired:
            return "Claude: session expired"
        case .loading, .ready, .cliMissing, .unavailable:
            break
        }
        guard let limits else {
            return loading || state == .loading ? "Claude…" : "Claude —"
        }
        if limits.isEmpty {
            return "Claude: no limits"
        }
        let parts = limits.shown(settings).map { statusPart(kind: $0.0, window: $0.1, settings: settings, now: now) }
        return parts.isEmpty ? "Claude —" : parts.joined(separator: " · ")
    }

    private static func statusPart(kind: QuotaKind, window: QuotaWindow, settings: MenuBarSettings, now: Date) -> String {
        var part = ""
        if settings.showLabels {
            part += kind.shortLabel + " "
        }
        part += String(format: "%.0f%%", window.percentage(settings.percent))
        if settings.showReset, let countdown = packedCountdown(window.resetsAt, now: now) {
            part += " (\(countdown))"
        }
        return part
    }

    /// Packed countdown for the menu bar (`2h41m`). Nil when the API gave no reset time.
    private static func packedCountdown(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "due" }
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "\(days)d\(hours % 24)h" }
        if hours > 0 { return "\(hours)h\(minutes % 60)m" }
        return "\(minutes)m"
    }

    private static func compact(_ value: Double, unit: String) -> String {
        if abs(value - value.rounded()) < 0.05 {
            return "\(Int(value.rounded()))\(unit)"
        }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value) + unit
    }
}

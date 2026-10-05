import AppKit
import SwiftUI
import ClaudeUsageCore

struct LimitsView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Group {
            if store.state == .apiBilling {
                UsageEmptyState(
                    symbol: "gauge.with.dots.needle.0percent",
                    title: "No subscription limits",
                    message: "Claude Code is billed per token, so there are no 5-hour or weekly limits to track. Token counts come from your local transcripts."
                ) {
                    Button("Show Token Usage") { store.section = .tokens }
                        .buttonStyle(.borderedProminent)
                }
            } else if store.state == .expired && store.limits?.isEmpty != false {
                UsageEmptyState(
                    symbol: "clock.badge.exclamationmark",
                    title: "Session expired",
                    message: UsageFormat.dashboardNotice(state: .expired, limits: nil) ?? "Open Claude Code to refresh your session."
                ) {
                    Button("Refresh") { store.refresh() }
                        .buttonStyle(.bordered)
                        .disabled(store.loading)
                }
            } else if let limits = store.limits, !limits.isEmpty {
                limitsPage(limits: limits, placeholder: false)
            } else if store.limits == nil && store.loading {
                limitsPage(
                    limits: QuotaLimits(fiveHour: QuotaWindow(used: 38), sevenDay: QuotaWindow(used: 59)),
                    placeholder: true
                )
                .redacted(reason: .placeholder)
                .accessibilityLabel("Loading subscription limits")
            } else {
                UsageEmptyState(
                    symbol: "gauge.with.dots.needle.0percent",
                    title: "No usage limits",
                    message: store.limits?.isEmpty == true
                        ? "Your plan did not report any usage limits."
                        : "Subscription limits are unavailable. Refresh to check again."
                ) {
                    Button("Refresh") { store.refresh() }
                        .buttonStyle(.bordered)
                        .disabled(store.loading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("limits-view")
    }

    private func limitsPage(limits: QuotaLimits, placeholder: Bool) -> some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                // Demo snapshots use the time at which the sample was created.
                let now = store.isDemo ? store.limitsUpdatedAt ?? context.date : context.date
                VStack(alignment: .leading, spacing: 20) {
                    VStack(spacing: 12) {
                        ForEach(limits.windows, id: \.0.rawValue) { kind, window in
                            LimitWindowCard(kind: kind, window: window, mode: store.settings.menuBar.percent, now: now)
                        }
                    }
                    .accessibilityIdentifier("quota-cards")
                    if !placeholder, let updatedAt = store.limitsUpdatedAt {
                        Text(updatedDescription(updatedAt, now: now))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(maxWidth: 1100)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func updatedDescription(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes == 0 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes) min ago" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Updated \(formatter.localizedString(for: date, relativeTo: now))"
    }
}

private struct LimitWindowCard: View {
    let kind: QuotaKind
    let window: QuotaWindow
    let mode: PercentMode
    let now: Date
    @Environment(\.colorSchemeContrast) private var contrast

    private var pace: QuotaPace { QuotaPace(window: window, kind: kind, now: now) }
    private var percentage: String { String(format: "%.0f%%", window.percentage(mode)) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 28) {
                summary.frame(width: 260, alignment: .leading)
                meter.frame(minWidth: 240)
            }
            VStack(alignment: .leading, spacing: 20) {
                summary
                meter
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1.5 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind.label)
                .font(.body.weight(.medium))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(percentage)
                    .font(.system(size: 40, weight: .regular))
                    .monospacedDigit()
                Text(mode == .left ? "left" : "used")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if let symbol = pace.symbol, let sentence = pace.sentence {
                    Image(systemName: symbol)
                        .font(.callout)
                        .foregroundStyle(pace.needsAttention ? Color(nsColor: .systemOrange) : Color.secondary)
                        .help(sentence)
                }
            }
            if let sentence = pace.sentence {
                Text(sentence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var meter: some View {
        LimitMeter(window: window, kind: kind, mode: mode, now: now)
    }

    private var accessibilityDescription: String {
        var parts = [kind.label, UsageFormat.percentLabel(window, mode: mode)]
        if let reset = window.resetsAt {
            let seconds = reset.timeIntervalSince(now)
            if seconds <= 0 {
                parts.append("Reset due")
            } else {
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = seconds >= 86400 ? [.day, .hour] : [.hour, .minute]
                formatter.unitsStyle = .full
                parts.append("Resets in \(formatter.string(from: max(60, seconds)) ?? "less than a minute")")
            }
        } else {
            parts.append(resetDescription(nil, now: now, fiveHour: kind == .fiveHour))
        }
        if let sentence = pace.sentence { parts.append(sentence) }
        return parts.joined(separator: ", ")
    }
}

private struct LimitMeter: View {
    let window: QuotaWindow
    let kind: QuotaKind
    let mode: PercentMode
    let now: Date
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var fraction: Double { min(1, max(0, window.percentage(mode) / 100)) }
    private var tint: Color {
        if window.remaining <= UsageFormat.dangerRemaining { return Color(nsColor: .systemRed) }
        if window.remaining <= UsageFormat.warningRemaining { return Color(nsColor: .systemOrange) }
        return UsageTheme.claude
    }
    private var animation: Animation? {
        guard !reduceMotion else { return nil }
        if #available(macOS 14, *) { return .smooth(duration: 0.35) }
        return .easeInOut(duration: 0.35)
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(contrast == .increased ? 0.5 : colorScheme == .dark ? 0.38 : 0.28))
                    .frame(width: geometry.size.width * fraction)
                DiagonalHatch()
                    .stroke(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1.5 : 1)
                    .frame(width: geometry.size.width * (1 - fraction))
                    .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                Text(String(format: "%.0f%%", window.percentage(mode)))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .padding(.leading, 12)
            }
            .overlay(alignment: .trailing) {
                resetChip.padding(.trailing, 10)
            }
            .animation(animation, value: fraction)
        }
        .frame(height: 36)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var resetChip: some View {
        if window.resetsAt != nil {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise").font(.caption2)
                Text(resetDescription(window.resetsAt, now: now, fiveHour: kind == .fiveHour))
                    .monospacedDigit()
            }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.94), in: Capsule())
            .help(UsageFormat.quotaTiming(window, kind: kind, now: now))
        } else {
            Capsule()
                .fill(Color(nsColor: .labelColor).opacity(0.4))
                .frame(width: 14, height: 4)
                .help(kind == .fiveHour ? "Starts with your next message" : "Reset time unavailable")
        }
    }
}

private struct DiagonalHatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: -rect.height, through: rect.width, by: 6) {
            path.move(to: CGPoint(x: x, y: rect.height))
            path.addLine(to: CGPoint(x: x + rect.height, y: 0))
        }
        return path
    }
}


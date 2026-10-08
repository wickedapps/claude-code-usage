import SwiftUI
import ClaudeUsageCore

/// The breakdown row the detail card shows.
struct TokenDetailSelection: Equatable {
    let kind: TokenBreakdownKind
    let id: String
}

/// One breakdown row narrowed from the report. A model or project keeps the
/// page's range; a day is shown hour by hour.
struct TokenDetailData {
    let kind: TokenBreakdownKind
    let row: UsageBreakdownRow
    let page: TokenPageData
    /// The page's range, which a day's own hourly summary doesn't carry.
    let range: UsageRange

    /// Nil when the row is no longer in the page's summary, as after a range change.
    init?(_ selection: TokenDetailSelection, report: UsageReport, parent: TokenPageData) {
        guard let row = selection.kind.rows(in: parent.summary).first(where: { $0.id == selection.id }) else { return nil }
        let now = parent.summary.end
        let summary: UsageSummary?
        let samples: [UsageSample]
        switch selection.kind {
        case .model:
            summary = report.summary(parent.summary.range, now: now) { $0.model == row.id }
            samples = report.samples.filter { $0.model == row.id }
        case .project:
            summary = report.summary(parent.summary.range, now: now) { $0.project == row.id }
            samples = report.samples.filter { $0.project == row.id }
        case .day:
            summary = report.summary(day: row.id, now: now)
            samples = report.samples
        }
        guard let summary else { return nil }
        kind = selection.kind
        self.row = row
        page = TokenPageData(summary: summary, samples: samples, palette: parent.palette)
        range = parent.summary.range
    }
}

struct TokenDetailCard: View {
    let detail: TokenDetailData
    let onClose: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    private var summary: UsageSummary { detail.page.summary }

    private var title: String {
        guard detail.kind == .day else { return detail.row.title }
        return summary.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var subtitle: String {
        "\(detail.kind.rawValue) · \(UsageFormat.share(detail.row.share)) of tokens · \(detail.range.label)"
    }

    /// Share of input-side tokens served from cache.
    private var cacheHit: String {
        let totals = summary.totals
        let input = totals.input + totals.cacheRead + totals.cacheCreate
        guard input > 0 else { return "—" }
        return UsageFormat.share(Double(totals.cacheRead) / Double(input))
    }

    private var peak: (label: String, value: String) {
        let hourly = summary.range.hourly
        let label = hourly ? "Peak hour" : "Peak day"
        guard let busiest = summary.series.max(by: { $0.tokens.total < $1.tokens.total }),
              busiest.tokens.total > 0 else { return (label, "—") }
        let value = hourly
            ? busiest.start.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
            : busiest.start.formatted(.dateTime.month(.abbreviated).day())
        return (label, value)
    }

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(maxWidth: 760)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1.5 : 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("\(title) details")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 26) {
            header
            stats
            TokenUsageChart(data: detail.page, height: 200)
            HStack(alignment: .top, spacing: 32) {
                TokenTypeBar(totals: summary.totals)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TokenDetailRows(kind: detail.kind == .project ? .model : .project,
                                rows: detail.kind == .project ? summary.models : summary.projects,
                                palette: detail.page.palette)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    icon.accessibilityHidden(true)
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(title)
                }
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            closeButton
                .labelStyle(.iconOnly)
                .keyboardShortcut(.cancelAction)
                .help("Close")
        }
    }

    /// A round toolbar-sized button: Liquid Glass where available, a bordered circle before it.
    @ViewBuilder private var closeButton: some View {
        let button = Button(action: onClose) { Label("Close", systemImage: "xmark") }
        if #available(macOS 26, *) {
            button.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.extraLarge)
        } else if #available(macOS 14, *) {
            button.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.extraLarge)
        } else {
            button.buttonStyle(.bordered).controlSize(.large)
        }
    }

    @ViewBuilder private var icon: some View {
        switch detail.kind {
        case .model:
            Circle().fill(detail.page.palette.color(detail.row.id)).frame(width: 10, height: 10)
        case .project:
            Image(systemName: "folder").foregroundStyle(.secondary)
        case .day:
            Image(systemName: "calendar").foregroundStyle(.secondary)
        }
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: 20) {
            stat("Tokens", UsageFormat.compactTokens(summary.totals.total),
                 spoken: "\(summary.totals.total) tokens")
            stat("Sessions", "\(summary.sessions)")
            stat("Cache hit", cacheHit)
            stat(peak.label, peak.value)
        }
    }

    private func stat(_ label: String, _ value: String, spoken: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(spoken ?? value)")
    }
}

/// The narrowed row's own split: projects for a model or day, models for a project.
private struct TokenDetailRows: View {
    let kind: TokenBreakdownKind
    let rows: [UsageBreakdownRow]
    let palette: ModelPalette
    @Environment(\.colorSchemeContrast) private var contrast

    private static let limit = 5
    private var shown: [UsageBreakdownRow] { Array(rows.filter { $0.tokens.total > 0 }.prefix(Self.limit)) }
    private var hidden: Int { rows.filter { $0.tokens.total > 0 }.count - shown.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind == .model ? "Models" : "Projects").font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(shown) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(row.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(row.title)
                            Spacer(minLength: 8)
                            Text(UsageFormat.share(row.share)).foregroundStyle(.secondary)
                            Text(UsageFormat.compactTokens(row.tokens.total))
                                .frame(minWidth: 44, alignment: .trailing)
                        }
                        .font(.caption)
                        GeometryReader { geometry in
                            Capsule()
                                .fill(kind == .model ? palette.color(row.id) : UsageTheme.claude)
                                .opacity(contrast == .increased ? 1 : 0.85)
                                .frame(width: geometry.size.width * min(1, max(0, row.share)), height: 2)
                        }
                        .frame(height: 2)
                    }
                    .monospacedDigit()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(row.title), \(UsageFormat.share(row.share)), \(row.tokens.total) tokens")
                }
                if hidden > 0 {
                    Text("\(hidden) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

import SwiftUI
import ClaudeUsageCore

struct TokensView: View {
    @ObservedObject var store: UsageStore
    @State private var data: TokenPageData?

    var body: some View {
        ScrollView {
            if let data, !data.summary.isEmpty {
                VStack(alignment: .leading, spacing: 36) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 36) {
                            TokenOverview(data: data)
                                .frame(width: 300)
                            TokenUsageChart(data: data)
                                .frame(minWidth: 420)
                        }
                        VStack(alignment: .leading, spacing: 28) {
                            TokenOverview(data: data)
                            TokenUsageChart(data: data)
                        }
                    }
                    TokenTotals(totals: data.summary.totals)
                    TokenTypeBar(totals: data.summary.totals)
                    TokenUsageBreakdown(summary: data.summary, palette: data.palette)
                }
                .frame(maxWidth: 1_100, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 34, weight: .light))
                        .accessibilityHidden(true)
                    Text(emptyMessage)
                        .font(.body)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 360)
                .padding(32)
            }
        }
        .onAppear(perform: updateSummary)
        .onChange(of: store.report) { _ in updateSummary() }
        .onChange(of: store.range) { _ in updateSummary() }
    }

    private func updateSummary() {
        data = store.report.map { TokenPageData(summary: $0.summary(store.range), samples: $0.samples) }
    }

    private var emptyMessage: String {
        let period = store.range == .day ? "24 hours" : store.range.label
        return "No Claude Code usage in the past \(period)."
    }
}

struct TokenOverviewModel: Identifiable {
    let id: String
    let title: String
    let sessions: Int
    let tokens: UInt64
    let share: Double
    let modelIDs: Set<String>
    let color: Color
}

/// Prepared only when the report or selected range changes.
struct TokenPageData {
    let summary: UsageSummary
    let palette: ModelPalette
    let models: [TokenOverviewModel]
    let chartSeries: [TokenModelSeries]

    init(summary: UsageSummary, samples: [UsageSample]) {
        self.summary = summary
        let palette = ModelPalette(samples: samples)
        self.palette = palette
        // Hued models keep their own series. Grey models fold into one series so no
        // two lines share a color; a lone grey model keeps its name.
        let hued = summary.models.filter { palette.hasHue($0.id) }
        let grey = summary.models.filter { !palette.hasHue($0.id) }
        var models = hued.map { row in
            TokenOverviewModel(id: row.id, title: row.title, sessions: row.sessions,
                               tokens: row.tokens.total, share: row.share,
                               modelIDs: [row.id], color: palette.color(row.id))
        }
        if grey.count == 1, let row = grey.first {
            models.append(TokenOverviewModel(id: row.id, title: row.title, sessions: row.sessions,
                                             tokens: row.tokens.total, share: row.share,
                                             modelIDs: [row.id], color: UsageTheme.otherModel))
        } else if !grey.isEmpty {
            let ids = Set(grey.map(\.id))
            let tokens = grey.reduce(UInt64(0)) { $0 + $1.tokens.total }
            let sessions = Set(samples.filter {
                $0.hour >= summary.start && $0.hour <= summary.end &&
                $0.tokens.total > 0 && ids.contains($0.model)
            }.map(\.sessionID)).count
            models.append(TokenOverviewModel(id: "__other_models", title: "Other", sessions: sessions,
                                             tokens: tokens, share: Double(tokens) / Double(max(1, summary.totals.total)),
                                             modelIDs: ids, color: UsageTheme.otherModel))
        }
        self.models = models
        chartSeries = models.map { model in
            TokenModelSeries(model: model, points: summary.series.map { bucket in
                TokenChartPoint(date: bucket.start, tokens: model.modelIDs.reduce(UInt64(0)) {
                    $0 + (bucket.byModel[$1] ?? 0)
                })
            })
        }
    }
}

private struct TokenOverview: View {
    let data: TokenPageData

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 4) {
                Text(UsageFormat.compactTokens(data.summary.totals.total))
                    .font(.system(size: 44, weight: .regular))
                    .monospacedDigit()
                    .accessibilityLabel("\(data.summary.totals.total) processed tokens")
                Text("\(data.summary.sessions) sessions")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 22) {
                ForEach(data.models) { model in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(model.color).frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(model.title).font(.body).lineLimit(1).help(model.title)
                                Text("\(model.sessions) sessions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                            Spacer(minLength: 8)
                            Text(UsageFormat.compactTokens(model.tokens)).font(.body)
                        }
                        Text("\(UsageFormat.share(model.share)) of tokens")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .monospacedDigit()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(model.title), \(model.sessions) sessions, \(model.tokens) tokens, \(UsageFormat.share(model.share)) of tokens")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TokenTotals: View {
    let totals: TokenCounts

    private var values: [(String, UInt64)] {
        [("Processed tokens", totals.total), ("Cache read", totals.cacheRead),
         ("Uncached input", totals.input), ("Output", totals.output), ("Cache write", totals.cacheCreate)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Totals").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(values, id: \.0) { label, value in
                        cell(label, value: value).frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                          alignment: .leading, spacing: 22) {
                    ForEach(values, id: \.0) { label, value in cell(label, value: value) }
                }
            }
        }
    }

    private func cell(_ label: String, value: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(UsageFormat.compactTokens(value)).font(.title2).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value) tokens")
    }
}

private struct TokenTypeBar: View {
    let totals: TokenCounts
    @Environment(\.colorSchemeContrast) private var contrast

    private var segments: [(label: String, value: UInt64, opacity: Double)] {
        [("Input", totals.input, 0.40), ("Cache read", totals.cacheRead, 0.22),
         ("Cache write", totals.cacheCreate, 0.65), ("Output", totals.output, 0.90)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tokens by type").font(.headline)
            GeometryReader { geometry in
                let nonzero = segments.filter { $0.value > 0 }
                let gaps = CGFloat(max(0, nonzero.count - 1))
                let minimum = min(4, max(0, geometry.size.width - gaps) / CGFloat(max(1, nonzero.count)))
                let available = max(0, geometry.size.width - gaps - minimum * CGFloat(nonzero.count))
                HStack(spacing: 1) {
                    ForEach(nonzero, id: \.label) { segment in
                        Rectangle().fill(color(segment.opacity))
                            .frame(width: minimum + available * CGFloat(Double(segment.value) / Double(max(1, totals.total))))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tokens by type")
            .accessibilityValue(segments.map { "\($0.label), \($0.value) tokens" }.joined(separator: ", "))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    ForEach(segments, id: \.label) { legend($0) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)],
                          alignment: .leading, spacing: 10) {
                    ForEach(segments, id: \.label) { legend($0) }
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    private func color(_ opacity: Double) -> Color {
        Color.primary.opacity(contrast == .increased ? min(1, opacity + 0.12) : opacity)
    }

    private func legend(_ segment: (label: String, value: UInt64, opacity: Double)) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color(segment.opacity)).frame(width: 8, height: 8)
            Text(segment.label).foregroundStyle(.secondary)
            Text(UsageFormat.compactTokens(segment.value)).monospacedDigit()
        }
        .font(.caption)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(segment.label), \(segment.value) tokens")
    }
}

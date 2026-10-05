import SwiftUI
import ClaudeUsageCore

struct TokenUsageBreakdown: View {
    let summary: UsageSummary
    let palette: ModelPalette
    @State private var selection: Breakdown = .model
    @State private var hoveredRow: String?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Breakdown: String, CaseIterable, Identifiable {
        case model = "Model", day = "Day", project = "Project"
        var id: String { rawValue }
    }

    private var rows: [UsageBreakdownRow] {
        switch selection {
        case .model: return summary.models
        case .day: return summary.days
        case .project: return summary.projects
        }
    }
    private var largestShare: Double { rows.map(\.share).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Breakdown").font(.headline)
                Spacer(minLength: 16)
                Picker("Breakdown", selection: $selection) {
                    ForEach(Breakdown.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                .fixedSize()
                .accessibilityLabel("Break down tokens by")
            }
            LazyVStack(spacing: 0) {
                header
                Divider()
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    breakdownRow(row, index: index)
                    Divider()
                }
            }
        }
        .onChange(of: selection) { _ in hoveredRow = nil }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("#").frame(width: 24, alignment: .leading)
            Text(selection.rawValue).frame(maxWidth: .infinity, alignment: .leading)
            Text("Sessions").frame(width: 72, alignment: .trailing)
            Text("Share").frame(width: 70, alignment: .trailing)
            Text("Tokens").frame(width: 90, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 12)
        .accessibilityHidden(true)
    }

    private func breakdownRow(_ row: UsageBreakdownRow, index: Int) -> some View {
        HStack(spacing: 16) {
            Text("\(index + 1)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 9) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.title)
                GeometryReader { geometry in
                    let fraction = largestShare > 0 ? min(1, max(0, row.share / largestShare)) : 0
                    RoundedRectangle(cornerRadius: 1)
                        .fill(selection == .model ? palette.color(row.id) : UsageTheme.claude)
                        .frame(width: max(0, min(320, geometry.size.width) * fraction), height: 2)
                }
                .frame(height: 2)
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(row.sessions)")
                .frame(width: 72, alignment: .trailing)
            Text(UsageFormat.share(row.share))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(UsageFormat.compactTokens(row.tokens.total))
                .frame(width: 90, alignment: .trailing)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(hoveredRow == row.id ? (contrast == .increased ? 0.8 : 0.4) : 0))
        }
        .contentShape(Rectangle())
        .onHover { hovering in hoveredRow = hovering ? row.id : nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(index + 1). \(row.title), \(row.sessions) sessions, \(UsageFormat.share(row.share)) of tokens, \(row.tokens.total) tokens")
    }
}

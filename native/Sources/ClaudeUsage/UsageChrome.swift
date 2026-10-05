import AppKit
import SwiftUI

struct DemoBadge: View {
    var body: some View {
        Text("DEMO")
            .font(.caption2.weight(.bold))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(nsColor: .systemOrange), in: Capsule())
            .accessibilityLabel("Demo")
            .accessibilityIdentifier("demo-badge")
            .help("Sample data. Nothing here is saved.")
    }
}

struct StatusBanner: View {
    enum Kind { case error, notice }

    let kind: Kind
    let text: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: kind == .error ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(kind == .error ? Color(nsColor: .systemRed) : Color.secondary)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(border, lineWidth: contrast == .increased ? 1.5 : 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var background: Color {
        kind == .error
            ? Color(nsColor: .systemRed).opacity(0.07)
            : Color(nsColor: .quaternaryLabelColor).opacity(0.12)
    }

    private var border: Color {
        kind == .error
            ? Color(nsColor: .systemRed).opacity(contrast == .increased ? 0.55 : 0.18)
            : Color(nsColor: .separatorColor)
    }
}

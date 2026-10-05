import AppKit
import SwiftUI
import ClaudeUsageCore

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let installURL = URL(string: "https://code.claude.com/docs/en/quickstart")

    var body: some View {
        Group {
            switch store.state {
            case .cliMissing:
                cliMissing
            case .signedOut:
                signedOut
            case .loading, .ready, .expired, .apiBilling, .unavailable:
                VStack(spacing: 0) {
                    if !messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(messages.enumerated()), id: \.offset) { _, message in
                                StatusBanner(kind: message.kind, text: message.text)
                            }
                        }
                        .frame(maxWidth: 1100)
                        .padding(.horizontal, 32)
                        .padding(.top, 20)
                        .frame(maxWidth: .infinity)
                    }
                    Group {
                        switch store.section {
                        case .limits: LimitsView(store: store)
                        case .tokens: TokensView(store: store)
                        }
                    }
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: store.section)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("dashboard-view")
    }

    private var messages: [(kind: StatusBanner.Kind, text: String)] {
        var items: [(kind: StatusBanner.Kind, text: String)] = []
        if let usageError = store.usageError, !usageError.isEmpty {
            items.append((.error, usageError))
        }
        if let limitsError = store.limitsError, !limitsError.isEmpty, limitsError != store.usageError {
            items.append((.error, limitsError))
        }
        let noticeIsEmptyState = store.section == .limits && (
            store.state == .apiBilling ||
            (store.state == .expired && store.limits?.isEmpty != false) ||
            store.limits?.isEmpty == true
        )
        if !noticeIsEmptyState, let notice = UsageFormat.dashboardNotice(state: store.state, limits: store.limits) {
            items.append((.notice, notice))
        }
        return items
    }

    private var cliMissing: some View {
        UsageEmptyState(
            symbol: "terminal",
            title: "Claude Code not found",
            message: "Looked on your shell's PATH and in the usual install locations."
        ) {
            HStack(spacing: 8) {
                Button("Install Claude Code") {
                    if let installURL = Self.installURL { NSWorkspace.shared.open(installURL) }
                }
                .buttonStyle(.borderedProminent)
                Button("Check again") { store.refresh() }
                    .buttonStyle(.bordered)
                    .disabled(store.loading)
            }
        }
    }

    private var signedOut: some View {
        UsageEmptyState(
            symbol: "person.slash",
            title: "Not logged in",
            message: "Run this in Terminal, then refresh. The next check picks the login up."
        ) {
            VStack(spacing: 12) {
                Text("claude auth login")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                Button("Check again") { store.refresh() }
                    .buttonStyle(.bordered)
                    .disabled(store.loading)
            }
        }
    }
}

struct UsageEmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        if #available(macOS 14, *) {
            ContentUnavailableView {
                Label(title, systemImage: symbol)
            } description: {
                Text(message)
                    .frame(maxWidth: 460)
            } actions: {
                actions()
            }
            .padding(24)
        } else {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                actions().padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

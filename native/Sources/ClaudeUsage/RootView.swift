import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Group {
            if store.loading && store.report == nil && store.state == .loading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading usage…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                DashboardView(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("root-view")
    }
}

import SwiftUI
import WidgetKit

private let widgetKind = "ClaudeUsageLimits"
private let fallbackReload: TimeInterval = 30 * 60

struct ClaudeUsageEntry: TimelineEntry {
  let date: Date
  let load: WidgetSnapshotLoad
}

struct ClaudeUsageProvider: TimelineProvider {
  func placeholder(in context: Context) -> ClaudeUsageEntry {
    ClaudeUsageEntry(date: Date(), load: .snapshot(.preview))
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (ClaudeUsageEntry) -> Void
  ) {
    completion(
      ClaudeUsageEntry(date: Date(), load: context.isPreview ? .snapshot(.preview) : load()))
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<ClaudeUsageEntry>) -> Void
  ) {
    let now = Date()
    let load = load()
    let fallback = now.addingTimeInterval(fallbackReload)
    let resetDates =
      load.snapshot?.windows.compactMap(\.resetsAt).filter {
        $0 > now && $0 < fallback
      } ?? []
    let dates = Array(Set([now, fallback] + resetDates)).sorted()
    let entries = dates.map { ClaudeUsageEntry(date: $0, load: load) }
    completion(Timeline(entries: entries, policy: .atEnd))
  }

  private func load() -> WidgetSnapshotLoad {
    let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
    return .read(appGroupID: group)
  }
}

@main
struct ClaudeUsageWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: widgetKind, provider: ClaudeUsageProvider()) { entry in
      ClaudeUsageWidgetView(entry: entry)
    }
    .configurationDisplayName("Claude Code Usage")
    .description("See your remaining 5-hour and weekly Claude Code limits.")
    .supportedFamilies([.systemSmall])
  }
}

struct ClaudeUsageWidgetView: View {
  let entry: ClaudeUsageEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .widgetURL(openURL)
    .modifier(WidgetContainerBackground())
  }

  private var openURL: URL? {
    guard let scheme = Bundle.main.object(forInfoDictionaryKey: "HostURLScheme") as? String else {
      return nil
    }
    return URL(string: "\(scheme)://open")
  }

  @ViewBuilder
  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("Claude Usage")
        .font(.caption.weight(.semibold))
        .lineLimit(1)
      Spacer(minLength: 0)
      if let updatedAt = entry.load.snapshot?.updatedAt {
        Text(updatedAt, style: .relative)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .accessibilityLabel("Last updated")
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch entry.load {
    case .missing:
      status("Open Claude Code Usage", detail: "The app will load this widget.")
    case .corrupt:
      status("Widget data is unreadable", detail: "Open the app to repair it.")
    case .snapshot(let snapshot):
      snapshotContent(snapshot)
    }
  }

  @ViewBuilder
  private func snapshotContent(_ snapshot: WidgetSnapshot) -> some View {
    switch snapshot.state {
    case .loading:
      HStack(spacing: 7) {
        ProgressView().controlSize(.small)
        Text("Loading usage")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    case .signedOut:
      status("Sign in to Claude Code", detail: "Then open this app to refresh.")
    case .unavailable:
      status("Usage unavailable", detail: "Open the app to try again.")
    case .ready where snapshot.windows.isEmpty:
      status("Choose a quota window", detail: "Open Settings in the app.")
    case .ready:
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(snapshot.windows.prefix(2).enumerated()), id: \.offset) { _, window in
          quotaRow(window, mode: snapshot.percentMode)
        }
      }
    }
  }

  private func status(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.callout.weight(.medium))
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private func quotaRow(_ window: WidgetQuotaWindow, mode: WidgetPercentMode) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(window.kind.label)
          .font(.caption)
        Spacer(minLength: 0)
        Text(window.percentageLabel(for: mode))
          .font(.caption.monospacedDigit())
          .lineLimit(1)
      }
      ProgressView(value: min(100, max(0, window.used)), total: 100)
        .progressViewStyle(.linear)
        .tint(color(for: window.level))
      resetLabel(for: window)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
  }

  @ViewBuilder
  private func resetLabel(for window: WidgetQuotaWindow) -> some View {
    switch window.resetStatus(at: entry.date) {
    case .startsWithMessage:
      Text("Starts when you send a message")
    case .unknown:
      Text("Reset time unknown")
    case .due:
      Text("Reset due")
    case .countdown(let date):
      Text("Resets in \(date, style: .relative)")
    }
  }

  private func color(for level: WidgetQuotaLevel) -> Color {
    switch level {
    case .healthy: .green
    case .warning: .orange
    case .danger: .red
    }
  }
}

private struct WidgetContainerBackground: ViewModifier {
  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 14.0, *) {
      content.containerBackground(.background, for: .widget)
    } else {
      content
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }
  }
}

extension WidgetSnapshot {
  fileprivate static var preview: Self {
    WidgetSnapshot(
      schemaVersion: widgetSnapshotVersion,
      state: .ready,
      updatedAt: Date().addingTimeInterval(-4 * 60),
      percentMode: .left,
      windows: [
        WidgetQuotaWindow(
          kind: .fiveHour,
          used: 38,
          remaining: 62,
          resetsAt: Date().addingTimeInterval(2 * 60 * 60 + 41 * 60)
        ),
        WidgetQuotaWindow(
          kind: .sevenDay,
          used: 59,
          remaining: 41,
          resetsAt: Date().addingTimeInterval(3 * 24 * 60 * 60)
        ),
      ]
    )
  }
}

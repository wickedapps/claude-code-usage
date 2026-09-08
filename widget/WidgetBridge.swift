import WidgetKit

/// Called from Rust after the shared snapshot changes in a way the widget can
/// display. This app owns one widget kind, so reloading all of its timelines is
/// both simpler and less brittle than duplicating the kind string in Rust.
@_cdecl("claude_usage_reload_widgets")
public func reloadClaudeUsageWidgets() {
  WidgetCenter.shared.reloadAllTimelines()
}

import AppKit
import ClaudeUsageCore

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    var onOpen: (@MainActor () -> Void)?
    var onSettings: (@MainActor () -> Void)?
    var onRefresh: (@MainActor () -> Void)?
    var onQuit: (@MainActor () -> Void)?

    private let item: NSStatusItem
    private let infoItems: [NSMenuItem]
    private let infoSeparator: NSMenuItem
    private var limits: QuotaLimits?
    private var display = MenuBarSettings()
    private var countdown: Task<Void, Never>?

    override init() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let menu = NSMenu()
        let first = StatusBarController.makeInfoItem()
        let second = StatusBarController.makeInfoItem()
        menu.addItem(first)
        menu.addItem(second)
        let separator = NSMenuItem.separator()
        separator.isHidden = true
        menu.addItem(separator)
        self.item = item
        self.infoItems = [first, second]
        self.infoSeparator = separator
        super.init()
        menu.addItem(makeItem("Refresh", #selector(refreshClicked)))
        menu.addItem(makeItem("Open Claude Code Usage", #selector(openClicked)))
        let settings = makeItem("Settings\u{2026}", #selector(settingsClicked))
        settings.keyEquivalent = ","
        settings.keyEquivalentModifierMask = .command
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit", #selector(quitClicked)))
        menu.delegate = self
        item.menu = menu
    }

    deinit {
        countdown?.cancel()
    }

    func bind(_ store: UsageStore) {
        countdown?.cancel()
        countdown = Task { @MainActor [weak self, weak store] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self, let store, store.settings.menuBar.showReset else { continue }
                self.applyTitle(for: store)
            }
        }
    }

    func sync(_ store: UsageStore) {
        limits = store.state == .signedOut ? nil : store.limits
        display = store.settings.menuBar
        applyTitle(for: store)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let shown = limits?.shown(display) ?? []
        for (index, item) in infoItems.enumerated() {
            if index < shown.count {
                item.title = menuLine(shown[index].0, shown[index].1)
                item.isHidden = false
            } else {
                item.isHidden = true
            }
        }
        infoSeparator.isHidden = shown.isEmpty
    }

    private func applyTitle(for store: UsageStore) {
        item.button?.title = title(for: store)
    }

    private func title(for store: UsageStore, now: Date = Date()) -> String {
        switch store.state {
        case .signedOut:
            return "Claude: signed out"
        case .apiBilling:
            return "Claude: API billing"
        case .expired:
            return "Claude: session expired"
        case .loading, .ready, .cliMissing, .unavailable:
            break
        }
        guard let limits = store.limits else {
            return store.loading || store.state == .loading ? "Claude\u{2026}" : "Claude \u{2014}"
        }
        if limits.isEmpty { return "Claude: no limits" }
        let parts = limits.shown(store.settings.menuBar).map { part($0.0, $0.1, store.settings.menuBar, now) }
        return parts.isEmpty ? "Claude \u{2014}" : parts.joined(separator: " \u{00B7} ")
    }

    private func part(_ kind: QuotaKind, _ window: QuotaWindow, _ display: MenuBarSettings, _ now: Date) -> String {
        var text = display.showLabels ? kind.shortLabel + " " : ""
        text += String(format: "%.0f%%", window.percentage(display.percent))
        if display.showReset, let countdown = countdown(window.resetsAt, now: now) {
            text += " (\(countdown))"
        }
        return text
    }

    private func menuLine(_ kind: QuotaKind, _ window: QuotaWindow) -> String {
        let word = display.percent == .left ? "left" : "used"
        let figure = String(format: "%.0f%% %@", window.percentage(display.percent), word)
        return "\(kind.label): \(figure), \(timing(kind, window, now: Date()))"
    }

    private func timing(_ kind: QuotaKind, _ window: QuotaWindow, now: Date) -> String {
        guard let resetsAt = window.resetsAt else {
            return kind == .fiveHour ? "Starts when you send a message" : "Reset time unknown"
        }
        if resetsAt <= now { return "Reset due" }
        return "Resets in \(packed(Int(resetsAt.timeIntervalSince(now) / 60), spaced: true))"
    }

    private func countdown(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        if date <= now { return "due" }
        return packed(Int(date.timeIntervalSince(now) / 60), spaced: false)
    }

    private func packed(_ minutes: Int, spaced: Bool) -> String {
        let days = minutes / 1_440
        let hours = (minutes / 60) % 24
        let mins = minutes % 60
        let gap = spaced ? " " : ""
        if days > 0 { return "\(days)d\(gap)\(hours)h" }
        if hours > 0 { return "\(hours)h\(gap)\(mins)m" }
        return "\(mins)m"
    }

    private static func makeInfoItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.isHidden = true
        return item
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func refreshClicked() { onRefresh?() }
    @objc private func openClicked() { onOpen?() }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func quitClicked() { onQuit?() }
}

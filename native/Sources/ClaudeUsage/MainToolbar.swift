import AppKit
import Combine
import ClaudeUsageCore

@MainActor
final class MainToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    private static let pageID = NSToolbarItem.Identifier("usage.page")
    private static let rangeID = NSToolbarItem.Identifier("usage.range")
    private static let refreshID = NSToolbarItem.Identifier("usage.refresh")
    private let store: UsageStore
    private var observation: AnyCancellable?
    private var pageControls: [NSSegmentedControl] = []
    private var rangeControls: [NSSegmentedControl] = []
    private var refreshItems: [NSToolbarItem] = []
    private var refreshButtons: [NSButton] = []
    private var spinners: [NSProgressIndicator] = []

    init(store: UsageStore) {
        self.store = store
        super.init()
        observation = store.$section.combineLatest(store.$range, store.$loading)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
    }

    func install(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: "ClaudeUsage.main.v2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = !store.isDemo
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.pageID, .space, Self.rangeID, .space, Self.refreshID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.pageID, Self.rangeID, Self.refreshID, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.pageID:
            let control = segmentedControl(DashboardSection.allCases.map(\.rawValue), action: #selector(selectPage(_:)))
            control.setAccessibilityLabel("Usage page")
            pageControls.append(control)
            let item = segmentedItem(id, control: control, label: "Page", paletteLabel: "Usage page",
                                     titles: DashboardSection.allCases.map(\.rawValue), action: #selector(selectPageFromMenu(_:)))
            sync()
            return item
        case Self.rangeID:
            let control = segmentedControl(UsageRange.allCases.map(\.label), action: #selector(selectRange(_:)))
            control.setAccessibilityLabel("Token date range")
            rangeControls.append(control)
            let item = segmentedItem(id, control: control, label: "Range", paletteLabel: "Token date range",
                                     titles: UsageRange.allCases.map(\.label), action: #selector(selectRangeFromMenu(_:)))
            sync()
            return item
        case Self.refreshID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Refresh"
            item.paletteLabel = "Refresh usage"
            item.toolTip = "Refresh"
            item.target = self
            item.action = #selector(refresh)
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
            let button = NSButton(image: item.image!, target: self, action: #selector(refresh))
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.toolTip = "Refresh"
            button.setAccessibilityLabel("Refresh usage")
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.setAccessibilityLabel("Refreshing usage")
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 28))
            button.frame = view.bounds
            spinner.frame = NSRect(x: 8, y: 6, width: 16, height: 16)
            view.addSubview(button)
            view.addSubview(spinner)
            item.view = view
            refreshItems.append(item)
            refreshButtons.append(button)
            spinners.append(spinner)
            sync()
            return item
        default: return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.action == #selector(refresh) { return !store.loading }
        return true
    }

    private func sync() {
        for control in pageControls { control.selectedSegment = DashboardSection.allCases.firstIndex(of: store.section) ?? 0 }
        for control in rangeControls {
            control.selectedSegment = UsageRange.allCases.firstIndex(of: store.range) ?? 2
            control.isEnabled = store.section == .tokens
        }
        for item in refreshItems { item.isEnabled = !store.loading }
        for button in refreshButtons { button.isEnabled = !store.loading; button.isHidden = store.loading }
        for spinner in spinners {
            spinner.isHidden = !store.loading
            if store.loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        }
    }

    @objc private func selectPage(_ sender: NSSegmentedControl) {
        guard DashboardSection.allCases.indices.contains(sender.selectedSegment) else { return }
        store.section = DashboardSection.allCases[sender.selectedSegment]
    }

    @objc private func selectRange(_ sender: NSSegmentedControl) {
        guard store.section == .tokens, UsageRange.allCases.indices.contains(sender.selectedSegment) else { return }
        store.range = UsageRange.allCases[sender.selectedSegment]
    }

    @objc private func selectPageFromMenu(_ sender: NSMenuItem) {
        guard DashboardSection.allCases.indices.contains(sender.tag) else { return }
        store.section = DashboardSection.allCases[sender.tag]
    }

    @objc private func selectRangeFromMenu(_ sender: NSMenuItem) {
        guard store.section == .tokens, UsageRange.allCases.indices.contains(sender.tag) else { return }
        store.range = UsageRange.allCases[sender.tag]
    }

    /// The same rounded segmented control the page uses for its Breakdown picker.
    /// A plain control also avoids the delayed hover bezel toolbar button groups draw.
    private func segmentedControl(_ labels: [String], action: Selector) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
        control.segmentStyle = .rounded
        control.segmentDistribution = .fit
        control.controlSize = .large
        control.font = .systemFont(ofSize: NSFont.systemFontSize(for: .regular))
        return control
    }

    private func segmentedItem(_ id: NSToolbarItem.Identifier, control: NSSegmentedControl, label: String,
                               paletteLabel: String, titles: [String], action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = control
        item.label = label
        item.paletteLabel = paletteLabel
        // Text-only toolbars and the overflow menu show a submenu instead of the control.
        let menu = NSMenu()
        for (index, title) in titles.enumerated() {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.tag = index
            menu.addItem(entry)
        }
        let form = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        form.submenu = menu
        item.menuFormRepresentation = form
        return item
    }

    @objc private func refresh() { store.refresh() }
}

import AppKit
import Combine
import ClaudeUsageCore
import QuartzCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let options: LaunchOptions
    private let store: UsageStore
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var toolbar: MainToolbar?
    private var observations: Set<AnyCancellable> = []
    private var statusBar: StatusBarController?
    private var screenshotsFinished = false

    private let shots: [(name: String, appearance: NSAppearance.Name, section: DashboardSection?, settings: Bool)] = [
        ("demo-limits-light", .aqua, .limits, false),
        ("demo-limits-dark", .darkAqua, .limits, false),
        ("demo-tokens-light", .aqua, .tokens, false),
        ("demo-tokens-dark", .darkAqua, .tokens, false),
        ("demo-settings-light", .aqua, nil, true),
        ("demo-settings-dark", .darkAqua, nil, true),
    ]

    init(options: LaunchOptions) {
        self.options = options
        self.store = UsageStore(demo: options.demo)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installIcon()
        installMenus()
        let statusBar = StatusBarController()
        statusBar.onOpen = { [weak self] in self?.showWindow(reload: true) }
        statusBar.onSettings = { [weak self] in self?.openSettings() }
        statusBar.onRefresh = { [weak self] in self?.store.refresh() }
        statusBar.onQuit = { NSApp.terminate(nil) }
        statusBar.bind(store)
        statusBar.sync(store)
        self.statusBar = statusBar
        store.onChange = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.statusBar?.sync(self.store)
                WidgetSnapshotWriter.sync(self.store)
            }
        }

        store.$accountLabel.receive(on: RunLoop.main).sink { [weak self] label in
            guard let self else { return }
            self.window?.subtitle = self.store.isDemo ? "Demo data" : label ?? ""
        }.store(in: &observations)

        let capturing = options.screenshotDirectory != nil
        if !capturing {
            store.$appearance.removeDuplicates().receive(on: RunLoop.main).sink { mode in
                NSApp.appearance = mode.nsAppearance
            }.store(in: &observations)
        }
        if capturing || (!options.showSettings && !store.settings.startHidden) {
            showWindow(reload: false)
        }
        if options.showSettings && !capturing { openSettings() }
        if let directory = options.screenshotDirectory { beginScreenshots(in: directory) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard options.screenshotDirectory == nil else { return true }
        showWindow(reload: true)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard options.screenshotDirectory == nil else { return }
        guard urls.contains(where: isOwnURL) else { return }
        showWindow(reload: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        updateActivationPolicy()
        return false
    }

    private func installMenus() {
        let app = NSMenu(title: "Claude Code Usage")
        app.addItem(menuItem("About Claude Code Usage", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", target: NSApp))
        app.addItem(.separator())
        app.addItem(menuItem("Settings…", #selector(openSettings), ","))
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        app.addItem(servicesItem)
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(menuItem("Hide Claude Code Usage", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        let hideOthers = menuItem("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", target: NSApp)
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(menuItem("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", target: NSApp))
        app.addItem(.separator())
        app.addItem(menuItem("Quit Claude Code Usage", #selector(NSApplication.terminate(_:)), "q", target: NSApp))

        let edit = NSMenu(title: "Edit")
        for entry in [("Undo", #selector(UndoManager.undo), "z"), ("Redo", #selector(UndoManager.redo), "Z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            if entry.0 == "Cut" { edit.addItem(.separator()) }
            edit.addItem(NSMenuItem(title: entry.0, action: entry.1, keyEquivalent: entry.2))
        }
        let view = NSMenu(title: "View")
        for (index, page) in DashboardSection.allCases.enumerated() {
            let item = menuItem(page.rawValue, #selector(selectPage(_:)), String(index + 1))
            item.tag = index
            view.addItem(item)
        }
        view.addItem(.separator())
        for (index, range) in UsageRange.allCases.enumerated() {
            let item = menuItem(range.label, #selector(selectRange(_:)), String(index + 1))
            item.tag = index
            item.keyEquivalentModifierMask = [.command, .option]
            view.addItem(item)
        }
        view.addItem(.separator())
        view.addItem(menuItem("Refresh", #selector(refresh), "r"))
        let fullScreen = menuItem("Enter Full Screen", #selector(toggleFullScreen), "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        view.addItem(fullScreen)
        view.addItem(.separator())
        view.addItem(menuItem("Customize Toolbar…", #selector(customizeToolbar), ""))

        let windows = NSMenu(title: "Window")
        windows.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windows.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windows.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windows.addItem(.separator())
        windows.addItem(menuItem("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", target: NSApp))
        NSApp.windowsMenu = windows
        let help = NSMenu(title: "Help")
        help.addItem(menuItem("Claude Code Documentation", #selector(openDocumentation), ""))
        NSApp.helpMenu = help
        let main = NSMenu()
        for menu in [app, edit, view, windows, help] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(selectPage(_:)):
            item.state = DashboardSection.allCases[item.tag] == store.section ? .on : .off
        case #selector(selectRange(_:)):
            item.state = UsageRange.allCases[item.tag] == store.range ? .on : .off
            return store.section == .tokens
        case #selector(refresh): return !store.loading
        case #selector(toggleFullScreen):
            item.title = window?.styleMask.contains(.fullScreen) == true ? "Exit Full Screen" : "Enter Full Screen"
            return window?.isVisible == true && NSApp.keyWindow === window
        case #selector(customizeToolbar): return window?.isVisible == true && NSApp.keyWindow === window
        default: break
        }
        return true
    }

    @objc private func selectPage(_ sender: NSMenuItem) {
        store.section = DashboardSection.allCases[sender.tag]
        showWindow(reload: false)
    }

    @objc private func selectRange(_ sender: NSMenuItem) {
        guard store.section == .tokens else { return }
        store.range = UsageRange.allCases[sender.tag]
        showWindow(reload: false)
    }

    @objc private func toggleFullScreen() { window?.toggleFullScreen(nil) }
    @objc private func customizeToolbar() { window?.runToolbarCustomizationPalette(nil) }
    @objc private func openDocumentation() {
        NSWorkspace.shared.open(URL(string: "https://code.claude.com/docs")!)
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    @objc private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        if settingsWindow == nil {
            let window = SettingsWindow(store: store)
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        activate()
        updateActivationPolicy()
    }

    private func activate() {
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    private func updateActivationPolicy() {
        let mainVisible = window?.isVisible == true
        let anyVisible = mainVisible || settingsWindow?.isVisible == true
        NSApp.setActivationPolicy(anyVisible ? .regular : .accessory)
        store.setWindowVisible(mainVisible)
    }

    @objc private func refresh() {
        store.refresh()
    }

    private func showWindow(reload: Bool) {
        let existing = window != nil
        NSApp.setActivationPolicy(.regular)
        let window = self.window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        activate()
        updateActivationPolicy()
        if existing && reload { store.refresh() }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Code Usage"
        window.subtitle = store.isDemo ? "Demo data" : store.accountLabel ?? ""
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        let hosting = NSHostingView(rootView: RootView(store: store))
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        let toolbar = MainToolbar(store: store)
        toolbar.install(on: window)
        self.toolbar = toolbar
        window.setContentSize(NSSize(width: 1080, height: 780))
        window.center()
        if !store.isDemo && options.screenshotDirectory == nil {
            window.setFrameAutosaveName("ClaudeUsage.main")
        }
        return window
    }

    private func installIcon() {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            cwd.appendingPathComponent("assets/AppIcon.icns"),
            cwd.appendingPathComponent("assets/dock-icon.png"),
        ]
        for url in candidates.compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: url.path), let image = NSImage(contentsOf: url) else { continue }
            NSApp.applicationIconImage = image
            return
        }
    }

    private var bundleID: String { Bundle.main.bundleIdentifier ?? "com.example.claude-usage" }

    private func isOwnURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme else { return false }
        return scheme.caseInsensitiveCompare(bundleID) == .orderedSame
    }

    private func beginScreenshots(in directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fputs("could not create \(directory.path): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 40_000_000_000)
            if !self.screenshotsFinished {
                fputs("screenshot capture timed out\n", stderr)
                exit(1)
            }
        }
        captureStep(0)
    }

    private func captureStep(_ index: Int) {
        guard index < shots.count, let directory = options.screenshotDirectory else {
            screenshotsFinished = true
            exit(0)
        }
        guard window != nil else {
            fputs("screenshot window was not open\n", stderr)
            exit(1)
        }
        let shot = shots[index]
        if let section = shot.section { store.section = section }
        store.range = .month
        if shot.settings {
            window?.orderOut(nil)
            openSettings()
        } else {
            settingsWindow?.orderOut(nil)
            showWindow(reload: false)
            if let window {
                var frame = window.frame
                frame.size = NSSize(width: 1180, height: 820)
                window.setFrame(frame, display: true)
                window.center()
            }
        }
        let appearance = NSAppearance(named: shot.appearance)
        NSApp.appearance = appearance
        let captureWindow = shot.settings ? settingsWindow : window
        captureWindow?.appearance = appearance
        captureWindow?.contentView?.appearance = appearance
        captureWindow?.contentView?.needsLayout = true
        captureWindow?.contentView?.layoutSubtreeIfNeeded()
        captureWindow?.displayIfNeeded()
        CATransaction.flush()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.writeShot(shot.name, directory: directory, index: index)
        }
    }

    private func writeShot(_ name: String, directory: URL, index: Int) {
        guard let window = shots[index].settings ? settingsWindow : window else {
            fputs("screenshot window was not open\n", stderr)
            exit(1)
        }
        var best: (CGImage, String, Int)?
        for attempt in 0..<3 {
            window.displayIfNeeded()
            CATransaction.flush()
            if let shot = grab(window), best == nil || shot.2 > best!.2 {
                best = shot
            }
            if let best, best.2 >= 16 { break }
            if attempt < 2 {
                RunLoop.current.run(mode: .common, before: Date().addingTimeInterval(0.2))
            }
        }
        guard let best, best.2 >= 8 else {
            fputs("screenshot \(name) had no rendered content\n", stderr)
            exit(1)
        }
        let url = directory.appendingPathComponent(name + ".png")
        do {
            try writePNG(best.0, to: url)
        } catch {
            fputs("could not write \(url.path): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        print("wrote \(url.path) (\(best.1), \(best.0.width)x\(best.0.height))")
        fflush(stdout)
        if index + 1 >= shots.count {
            screenshotsFinished = true
            exit(0)
        }
        captureStep(index + 1)
    }

    private func grab(_ window: NSWindow) -> (CGImage, String, Int)? {
        var candidates: [(CGImage, String)] = []
        if let image = systemCapture(window) { candidates.append((image, "system")) }
        if let frame = window.contentView?.superview {
            if let image = cacheCapture(frame) { candidates.append((image, "frame-cache")) }
            if let image = layerCapture(frame, scale: window.backingScaleFactor) { candidates.append((image, "frame-layer")) }
        }
        if candidates.isEmpty, let content = window.contentView {
            if let image = cacheCapture(content) { candidates.append((image, "content-cache")) }
            if let image = layerCapture(content, scale: window.backingScaleFactor) { candidates.append((image, "content-layer")) }
        }
        let scored = candidates.compactMap { image, source -> (CGImage, String, Int)? in
            guard image.width > 80, image.height > 80 else { return nil }
            return (image, source, colorSpread(image))
        }
        return scored.max { lhs, rhs in
            if lhs.2 == rhs.2 { return lhs.1 != "system" && rhs.1 == "system" }
            return lhs.2 < rhs.2
        }
    }

    private func systemCapture(_ window: NSWindow) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
    }

    private func cacheCapture(_ view: NSView) -> CGImage? {
        let bounds = view.bounds
        guard bounds.width > 2, bounds.height > 2, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    private func layerCapture(_ view: NSView, scale: CGFloat) -> CGImage? {
        let bounds = view.bounds
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 2, height > 2, let layer = view.layer else { return nil }
        let colorSpace = view.window?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace, let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        return context.makeImage()
    }

    private func colorSpread(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data else { return 0 }
        let length = CFDataGetLength(data)
        guard length > 4, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var low = 255
        var high = 0
        var index = 0
        let step = max(4, length / 4_000)
        while index < length {
            let value = Int(bytes[index])
            if value < low { low = value }
            if value > high { high = value }
            index += step
        }
        return high - low
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }
}

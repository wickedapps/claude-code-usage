import AppKit
import SwiftUI

final class SettingsWindow: NSWindow {
    convenience init(store: UsageStore) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 1),
                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Settings"
        isReleasedWhenClosed = false
        isRestorable = false

        let titleBarHeight = frame.height - contentRect(forFrameRect: frame).height
        let availableHeight = (screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude
        let controller = SettingsHostingController(rootView: SettingsView(
            store: store, maximumHeight: availableHeight - titleBarHeight
        ))
        controller.sizingOptions = [.preferredContentSize]
        controller.onSizeChange = { [weak self] size in self?.fitContent(to: size) }
        contentViewController = controller
        fitContent(to: controller.sizeThatFits(in: NSSize(width: SettingsView.width,
                                                        height: .greatestFiniteMagnitude)))
    }

    private func fitContent(to size: NSSize) {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
        let contentSize = NSSize(width: SettingsView.width, height: ceil(size.height))
        guard contentRect(forFrameRect: frame).size != contentSize else { return }
        var newFrame = frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        newFrame.origin = NSPoint(x: frame.minX, y: frame.maxY - newFrame.height)
        setFrame(newFrame, display: true)
    }

    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

private final class SettingsHostingController: NSHostingController<SettingsView> {
    var onSizeChange: ((NSSize) -> Void)?

    override var preferredContentSize: NSSize {
        didSet {
            // Resize after SwiftUI finishes its layout pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onSizeChange?(self.preferredContentSize)
            }
        }
    }
}

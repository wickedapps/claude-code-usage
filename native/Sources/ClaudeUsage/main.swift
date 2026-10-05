import AppKit

struct LaunchOptions {
    var demo: Bool
    var showSettings: Bool
    var screenshotDirectory: URL?

    init(arguments: [String]) {
        var demo = false
        var showSettings = false
        var screenshotDirectory: URL?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--demo":
                demo = true
            case "--settings":
                showSettings = true
            case "--screenshot-dir":
                index += 1
                guard index < arguments.count, !arguments[index].isEmpty else {
                    fputs("missing path after --screenshot-dir\n", stderr)
                    exit(2)
                }
                screenshotDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
            default:
                fputs("unrecognized argument \(argument)\n", stderr)
                exit(2)
            }
            index += 1
        }
        // Screenshot runs stay on fixture data and never touch login items, preferences, or the widget file.
        if screenshotDirectory != nil {
            demo = true
        }
        self.demo = demo
        self.showSettings = showSettings
        self.screenshotDirectory = screenshotDirectory
    }
}

@MainActor
private func runApplication() {
    let options = LaunchOptions(arguments: CommandLine.arguments)
    let delegate = AppDelegate(options: options)
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}

MainActor.assumeIsolated {
    runApplication()
}

import AppKit

/// Without arguments: the menu bar app. With arguments: the command line (see CLI).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let arguments: [String]
    private var menuBar: MenuBarController?

    init(arguments: [String]) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if arguments.isEmpty {
            menuBar = MenuBarController()
            menuBar?.start()
        } else {
            CLI.run(arguments)
        }
    }
}

// A regular window-server connection: CGVirtualDisplay and ScreenCaptureKit need one.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Finder and `open` may pass a process serial number; it is not a command.
let delegate = AppDelegate(arguments: Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") })
app.delegate = delegate
app.run()

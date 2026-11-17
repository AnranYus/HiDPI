import AppKit

@main
enum Entry {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if args.contains("--list") || args.contains("--selftest") || args.contains("--menu") {
            app.setActivationPolicy(.prohibited)
            MainActor.assumeIsolated { SelfTest.run(args) }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController = StatusMenuController(manager: DisplayManager.shared)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The virtual displays would vanish with the process anyway; this just restores cleanly.
        DisplayManager.shared.turnEverythingOff()
    }
}

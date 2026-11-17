import AppKit
import Combine

/// The menu bar icon and its standard AppKit menu.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let manager: DisplayManager
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var cancellable: AnyCancellable?

    init(manager: DisplayManager) {
        self.manager = manager
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon()
        rebuild()

        // Keep the menu (and icon) current, also while it is open.
        cancellable = manager.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon(); self?.rebuild() }
        }
    }

    /// Text rendering of the menu, for `HiDPI --menu`.
    func dump() -> String {
        func lines(_ menu: NSMenu, _ indent: String) -> [String] {
            menu.items.flatMap { item -> [String] in
                if item.isSeparatorItem { return [indent + "────"] }
                var line = indent + (item.state == .on ? "✓ " : "  ") + item.title
                if #available(macOS 14.4, *), let sub = item.subtitle { line += "  [\(sub)]" }
                if #available(macOS 14.0, *), let badge = item.badge?.stringValue { line += "  <\(badge)>" }
                if !item.isEnabled { line += "  (disabled)" }
                return [line] + (item.submenu.map { lines($0, indent + "      ") } ?? [])
            }
        }
        return lines(menu, "").joined(separator: "\n")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        manager.refresh()
        rebuild()
    }

    private func updateIcon() {
        let active = manager.displays.contains(where: \.hiDPIActive)
        let image = NSImage(systemSymbolName: active ? "sparkles.tv.fill" : "sparkles.tv",
                            accessibilityDescription: "HiDPI")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func rebuild() {
        menu.removeAllItems()

        if let error = manager.lastError {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if manager.displays.isEmpty {
            menu.addItem(disabled("No External Displays"))
        }

        for (index, display) in manager.displays.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            addSection(for: display)
        }

        menu.addItem(.separator())
        menu.addItem(action("Show Low Resolution Modes", state: manager.showLowResolution) { [manager] in
            manager.showLowResolution.toggle()
        })
        menu.addItem(action("Launch at Login", state: manager.launchAtLogin) { [manager] in
            manager.setLaunchAtLogin(!manager.launchAtLogin)
        })
        menu.addItem(action("Displays Settings…") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
        })
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit HiDPI", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func addSection(for display: DisplayItem) {
        // Header: display name, with the current resolution underneath.
        let header: NSMenuItem
        if #available(macOS 14.0, *) {
            header = NSMenuItem.sectionHeader(title: display.name)
        } else {
            header = disabled(display.name)
        }
        menu.addItem(header)

        let hiDPI = action(display.busy ? "Software HiDPI (Starting…)" : "Software HiDPI",
                           state: display.hiDPIActive) { [manager] in
            manager.setHiDPI(!display.hiDPIActive, for: display)
        }
        hiDPI.isEnabled = !display.busy && manager.backend != nil
        hiDPI.toolTip = display.hiDPIActive
            ? "Rendering at 2x and scaling down to the panel's \(display.panelWidth) × \(display.panelHeight) pixels."
            : "Render the desktop at 2x and scale it down, for Retina-sharp text on this display."
        menu.addItem(hiDPI)

        let resolutionItem = NSMenuItem(title: "Resolution", action: nil, keyEquivalent: "")
        setSubtitle(display.subtitle, on: resolutionItem)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for resolution in display.resolutions {
            let item = action(resolution.label, state: resolution == display.current) { [manager] in
                manager.select(resolution, on: display)
            }
            if resolution.hiDPI && !display.hiDPIActive {
                tag(item, "HiDPI")
            } else if !resolution.hiDPI && resolution.width == display.panelWidth && resolution.height == display.panelHeight {
                tag(item, "Native")
            }
            item.isEnabled = !display.busy
            submenu.addItem(item)
        }
        if display.resolutions.isEmpty { submenu.addItem(disabled("No Modes")) }
        resolutionItem.submenu = submenu
        resolutionItem.isEnabled = !display.busy
        menu.addItem(resolutionItem)
    }

    // MARK: Item helpers

    private func setSubtitle(_ subtitle: String, on item: NSMenuItem) {
        if #available(macOS 14.4, *) {
            item.subtitle = subtitle
        } else {
            item.title += "  —  \(subtitle)"
        }
    }

    private func tag(_ item: NSMenuItem, _ text: String) {
        if #available(macOS 14.0, *) {
            item.badge = NSMenuItemBadge(string: text)
        } else {
            item.title += "  (\(text))"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, state: Bool? = nil, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        if let state { item.state = state ? .on : .off }
        return item
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

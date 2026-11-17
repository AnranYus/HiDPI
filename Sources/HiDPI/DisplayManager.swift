import AppKit
import Combine
import CoreGraphics
import ServiceManagement
import VirtualDisplayShim

/// What the menu shows for one physical display.
struct DisplayItem: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let key: String
    let name: String
    let isBuiltin: Bool
    let isMain: Bool
    let panelWidth: Int
    let panelHeight: Int
    let current: Resolution?
    let resolutions: [Resolution]
    let hiDPIActive: Bool
    let busy: Bool

    var subtitle: String {
        guard let current else { return "\(panelWidth) × \(panelHeight)" }
        return current.label + (current.hiDPI ? " · HiDPI" : "")
    }
}

@MainActor
final class DisplayManager: ObservableObject {
    static let shared = DisplayManager()

    @Published private(set) var displays: [DisplayItem] = []
    @Published var lastError: String?
    @Published var showLowResolution: Bool {
        didSet { defaults.set(showLowResolution, forKey: "showLowResolution"); refresh() }
    }
    @Published private(set) var launchAtLogin = false

    let backend = HDVirtualDisplay.backendName

    private var sessions: [String: HiDPISession] = [:] // by persistent display key
    private var busy: Set<String> = []
    private var failedRestore: Set<String> = [] // auto-restore failed; retried after a reconnect
    private var names: [String: String]
    private var refreshPending = false
    private let defaults = UserDefaults.standard

    /// Displays the user wants software HiDPI on, with the chosen "looks like" size.
    private var saved: [String: Resolution] {
        get {
            guard let data = defaults.data(forKey: "hidpi") else { return [:] }
            return (try? JSONDecoder().decode([String: Resolution].self, from: data)) ?? [:]
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "hidpi") }
    }

    private init() {
        showLowResolution = UserDefaults.standard.bool(forKey: "showLowResolution")
        names = (UserDefaults.standard.dictionary(forKey: "names") as? [String: String]) ?? [:]
        launchAtLogin = SMAppService.mainApp.status == .enabled

        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.beginConfigurationFlag) { return }
            DispatchQueue.main.async { DisplayManager.shared.scheduleRefresh() }
        }, nil)

        refresh()
        restoreSavedSessions()
    }

    // MARK: Listing

    func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            refreshPending = false
            refresh()
            dropSessionsForMissingDisplays()
            restoreSavedSessions()
        }
    }

    func refresh() {
        let mainID = CGMainDisplayID()
        var items: [DisplayItem] = []

        // Built-in screens are already Retina, so only external displays are listed.
        for id in Displays.online() where !HiDPISession.isOurVirtualDisplay(id) && CGDisplayIsBuiltin(id) == 0 {
            let key = Displays.persistentKey(of: id)
            if let name = Displays.name(of: id), names[key] != name {
                names[key] = name
                defaults.set(names, forKey: "names")
            }
            let session = sessions[key]
            let isBuiltin = CGDisplayIsBuiltin(id) != 0
            let panel = Displays.nativePixelSize(of: id)

            let current: Resolution?
            let resolutions: [Resolution]
            if let session {
                current = session.current
                resolutions = session.options
            } else {
                let mode = Displays.currentMode(of: id)
                current = mode?.resolution
                let all = Displays.resolutions(of: id, preferringRefresh: mode?.refreshRate ?? 60).keys
                resolutions = all
                    .filter { showLowResolution || $0.hiDPI || !hasHiDPITwin($0, in: all) }
                    .sorted { ($0.width, $0.height, $0.hiDPI ? 1 : 0) > ($1.width, $1.height, $1.hiDPI ? 1 : 0) }
            }

            let isMain = id == mainID || (session != nil && session!.virtualID == mainID)
            items.append(DisplayItem(
                id: id, key: key,
                name: names[key] ?? (isBuiltin ? "Built-in Display" : "Display \(id)"),
                isBuiltin: isBuiltin, isMain: isMain,
                panelWidth: panel.width, panelHeight: panel.height,
                current: current, resolutions: resolutions,
                hiDPIActive: session != nil, busy: busy.contains(key)
            ))
        }

        items.sort { ($0.isMain ? 0 : 1, $0.isBuiltin ? 1 : 0, $0.id) < ($1.isMain ? 0 : 1, $1.isBuiltin ? 1 : 0, $1.id) }
        if items != displays { displays = items }
    }

    /// Hide a 1x mode when the same size also exists in HiDPI, unless the user wants everything.
    private func hasHiDPITwin(_ r: Resolution, in all: Dictionary<Resolution, ModeInfo>.Keys) -> Bool {
        !r.hiDPI && all.contains(Resolution(width: r.width, height: r.height, hiDPI: true))
    }

    // MARK: Actions

    func select(_ resolution: Resolution, on item: DisplayItem) {
        lastError = nil
        do {
            if let session = sessions[item.key] {
                try session.select(resolution)
                var s = saved; s[item.key] = resolution; saved = s
            } else {
                let mode = Displays.currentMode(of: item.id)
                guard let info = Displays.resolutions(of: item.id, preferringRefresh: mode?.refreshRate ?? 60)[resolution]
                else { throw DisplayError.noMode(resolution) }
                try Displays.setMode(info.mode, on: item.id)
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func setHiDPI(_ on: Bool, for item: DisplayItem) {
        lastError = nil
        if on {
            failedRestore.remove(item.key)
            Task { await startSession(for: item.id, key: item.key, looksLike: saved[item.key], remember: true) }
        } else {
            var s = saved; s.removeValue(forKey: item.key); saved = s
            sessions.removeValue(forKey: item.key)?.stop()
            refresh()
        }
    }

    func turnEverythingOff() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
    }

    func setLaunchAtLogin(_ on: Bool) {
        lastError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Sessions

    private func startSession(for id: CGDirectDisplayID, key: String, looksLike: Resolution?, remember: Bool) async {
        guard sessions[key] == nil, !busy.contains(key) else { return }
        guard backend != nil else {
            lastError = "This version of macOS has no virtual display API."
            return
        }
        busy.insert(key)
        refresh()
        defer { busy.remove(key); refresh() }

        do {
            let session = try HiDPISession(target: id, looksLike: looksLike)
            try await session.start(name: names[key] ?? "Display")
            sessions[key] = session
            if remember { var s = saved; s[key] = session.current; saved = s }
        } catch {
            lastError = "Software HiDPI: \(error.localizedDescription)"
            if !remember { failedRestore.insert(key) }
        }
    }

    /// Turns HiDPI back on for displays that had it last time (at launch and on reconnect).
    private func restoreSavedSessions() {
        let wanted = saved
        for item in displays where wanted.keys.contains(item.key) && sessions[item.key] == nil
            && !busy.contains(item.key) && !failedRestore.contains(item.key) {
            Task { await startSession(for: item.id, key: item.key, looksLike: wanted[item.key], remember: false) }
        }
    }

    private func dropSessionsForMissingDisplays() {
        let online = Set(Displays.online())
        let onlineKeys = Set(online.map(Displays.persistentKey))
        failedRestore.formIntersection(onlineKeys)
        for (key, session) in sessions where !online.contains(session.targetID) {
            session.stop()
            sessions.removeValue(forKey: key)
        }
    }
}

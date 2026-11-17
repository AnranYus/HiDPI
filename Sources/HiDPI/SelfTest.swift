import AppKit
import CoreGraphics
import VirtualDisplayShim

/// Command-line checks, handy over SSH or when the menu bar is not reachable.
///   HiDPI --list                         displays and their modes
///   HiDPI --menu                         print the menu as text
///   HiDPI --selftest [--mirror] [--seconds N] [--display ID]
///                                        create a virtual HiDPI display for an external display,
///                                        print its modes, optionally mirror, then restore
@MainActor
enum SelfTest {
    static func run(_ args: [String]) {
        print("virtual display backend: \(HDVirtualDisplay.backendName ?? "none")")
        if args.contains("--list") { list(); exit(0) }
        if args.contains("--menu") {
            print(StatusMenuController(manager: DisplayManager.shared).dump())
            exit(0)
        }

        let seconds = value(after: "--seconds", in: args).flatMap(Double.init) ?? 3
        let mirror = args.contains("--mirror")
        let ids = Displays.online().filter { !HiDPISession.isOurVirtualDisplay($0) }
        guard let target = value(after: "--display", in: args).flatMap(UInt32.init)
            ?? ids.first(where: { CGDisplayIsBuiltin($0) == 0 }) ?? ids.first
        else { print("no display"); exit(1) }
        // NSApp is running (see Entry), so WindowServer reconfiguration events get processed.

        Task { @MainActor in
            do {
                let session = try HiDPISession(target: target, looksLike: nil)
                print("target \(target): panel \(Displays.nativePixelSize(of: target)), options \(session.options.map(\.label))")
                if mirror {
                    try await session.start(name: Displays.name(of: target) ?? "Display")
                } else {
                    try await startWithoutMirror(session)
                }
                let v = session.virtualID
                print("virtual display \(v) online; modes:")
                for m in Displays.modes(of: v) {
                    print("  \(m.resolution.label)  px \(m.pixelWidth)x\(m.pixelHeight)  \(m.refreshRate) Hz\(m.resolution.hiDPI ? "  HiDPI" : "")")
                }
                print("current: \(Displays.currentMode(of: v).map { "\($0.resolution.label) px \($0.pixelWidth)x\($0.pixelHeight)" } ?? "?")")
                if let other = session.options.first(where: { $0 != session.current }) {
                    try session.select(other)
                    print("switched to \(other.label): \(Displays.currentMode(of: v).map { "px \($0.pixelWidth)x\($0.pixelHeight)" } ?? "?")")
                }
                if mirror { print("target mirrors virtual: \(CGDisplayMirrorsDisplay(target) == v)") }
                try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                session.stop()
                try await Task.sleep(nanoseconds: 500_000_000)
                print("restored; target now \(Displays.currentMode(of: target).map { "\($0.resolution.label) px \($0.pixelWidth)x\($0.pixelHeight)" } ?? "?"), mirrors \(CGDisplayMirrorsDisplay(target))")
                exit(0)
            } catch {
                print("FAILED: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    /// Same as `start` but skips the mirror step, so the layout is only briefly extended.
    private static func startWithoutMirror(_ session: HiDPISession) async throws {
        try await session.start(name: "SelfTest", mirror: false)
    }

    private static func list() {
        for id in Displays.online() {
            let cur = Displays.currentMode(of: id)
            print("\(id) \(Displays.name(of: id) ?? "?")  key \(Displays.persistentKey(of: id))  panel \(Displays.nativePixelSize(of: id))  virtual(ours) \(HiDPISession.isOurVirtualDisplay(id))")
            print("  current \(cur.map { "\($0.resolution.label) px \($0.pixelWidth)x\($0.pixelHeight) \($0.refreshRate)Hz" } ?? "?")")
            let res = Displays.resolutions(of: id, preferringRefresh: cur?.refreshRate ?? 60)
            print("  " + res.keys.sorted { $0.width > $1.width }.map { $0.label + ($0.hiDPI ? "@2x" : "") }.joined(separator: ", "))
        }
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

import CoreGraphics
import Foundation
import VirtualDisplayShim

/// Software HiDPI for one physical display.
///
/// A virtual display is created whose every mode has a 2x backing store
/// (e.g. "looks like 2560x1440" = 5120x2880 pixels). The physical display is then set to
/// mirror it, so WindowServer renders at 2x and the panel just scales the result down.
/// Text and UI are drawn with Retina-quality anti-aliasing, so it stops looking blurry.
///
/// The virtual display only exists while this process is running: if the app quits or
/// crashes, the virtual display disappears and the physical display returns to normal.
@MainActor
final class HiDPISession {
    static let vendorID: UInt32 = 0x4844 // "HD": marks the virtual displays we create

    let targetID: CGDirectDisplayID
    let options: [Resolution]
    private(set) var current: Resolution
    private var virtual: HDVirtualDisplay?

    var virtualID: CGDirectDisplayID { virtual?.displayID ?? kCGNullDirectDisplay }

    static func isOurVirtualDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(id) == vendorID
    }

    /// The "looks like" sizes offered for a panel: same aspect ratio, from half the panel
    /// width (biggest UI) up to the panel width (most space, 1:1 with the panel's pixels).
    static func options(forPanel width: Int, _ height: Int) -> [Resolution] {
        guard width > 0, height > 0 else { return [] }
        let aspect = Double(width) / Double(height)
        let candidates = [1024, 1152, 1280, 1344, 1360, 1440, 1600, 1680, 1728, 1792, 1920, 2048, 2160, 2304,
                          2400, 2560, 2720, 2880, 3008, 3200, 3360, 3440, 3584, 3840, 4096, 4480, 5120]
        var seen = Set<String>()
        var result: [Resolution] = []
        for w in candidates + [width / 2, width] where w >= width / 2 && w <= width && w * 2 <= 16384 {
            var h = Int((Double(w) / aspect).rounded())
            if h % 2 == 1 { h += 1 }
            guard abs(Double(w) / Double(h) - aspect) < 0.01, h * 2 <= 16384 else { continue }
            let r = Resolution(width: w, height: h, hiDPI: true)
            if seen.insert(r.id).inserted { result.append(r) }
        }
        return result.sorted { $0.width > $1.width }
    }

    /// Chooses the option closest to `wanted`, by width.
    static func closest(to wantedWidth: Int, in options: [Resolution]) -> Resolution? {
        options.min { abs($0.width - wantedWidth) < abs($1.width - wantedWidth) }
    }

    init(target: CGDirectDisplayID, looksLike wanted: Resolution?) throws {
        targetID = target
        let panel = Displays.nativePixelSize(of: target)
        var options = Self.options(forPanel: panel.width, panel.height)
        if let only = ProcessInfo.processInfo.environment["HIDPI_ONLY"] {
            let widths = only.split(separator: ",").compactMap { Int($0) }
            options = options.filter { widths.contains($0.width) }
        }
        self.options = options

        // Keep the current UI size by default, so turning HiDPI on only makes things sharper.
        let currentWidth = Displays.currentMode(of: target)?.resolution.width ?? panel.width
        guard let first = wanted.flatMap({ w in options.first { $0.width == w.width && $0.height == w.height } })
            ?? Self.closest(to: currentWidth, in: options)
        else { throw DisplayError.timeout("This display reports no usable size.") }
        current = first
    }

    func start(name: String, mirror: Bool = true) async throws {
        let target = targetID
        let key = Displays.persistentKey(of: target)

        var mm = CGDisplayScreenSize(target)
        if mm.width < 1 || mm.height < 1 { // unknown size: assume a 27" panel
            let diag = 27 * 25.4
            let ratio = Double(current.width) / Double(current.height)
            let h = diag / (ratio * ratio + 1).squareRoot()
            mm = CGSize(width: h * ratio, height: h)
        }

        // The preferred mode goes first; the rest let the user switch without recreating the display.
        let points = [current] + options.filter { $0 != current }
        let refresh = Displays.currentMode(of: target)?.refreshRate ?? 60
        let rates = Set([refresh, 60.0]).filter { $0 >= 24 }.sorted(by: >)

        var created: HDVirtualDisplay?
        var lastError: Error?
        for hz in rates {
            do {
                created = try HDVirtualDisplay(
                    name: "HiDPI \(name)",
                    vendorID: Self.vendorID,
                    productID: CGDisplayModelNumber(target) & 0xFFFF,
                    serialNumber: fnv1a(key),
                    sizeInMillimeters: mm,
                    pointSizes: points.map { NSValue(size: $0.points) },
                    refreshRate: hz
                )
                break
            } catch {
                lastError = error
            }
        }
        guard let created else { throw lastError ?? DisplayError.timeout("Could not create the virtual display.") }
        virtual = created

        do {
            try await waitUntilOnline(created.displayID)
            try select(current)
            if mirror { try Displays.mirror(target, to: created.displayID) }
        } catch {
            stop()
            throw error
        }
    }

    func select(_ resolution: Resolution) throws {
        let id = virtualID
        guard id != kCGNullDirectDisplay else { return }
        let modes = Displays.modes(of: id)
        guard let info = modes.first(where: { $0.resolution == resolution })
            ?? modes.first(where: { $0.resolution.width == resolution.width && $0.resolution.height == resolution.height })
        else { throw DisplayError.noMode(resolution) }
        if Displays.currentMode(of: id)?.resolution != info.resolution {
            try Displays.setMode(info.mode, on: id, option: .forSession)
        }
        current = resolution
    }

    func stop() {
        guard let virtual else { return }
        if CGDisplayMirrorsDisplay(targetID) == virtual.displayID {
            try? Displays.mirror(targetID, to: nil)
        }
        virtual.destroy()
        self.virtual = nil
    }

    private func waitUntilOnline(_ id: CGDirectDisplayID) async throws {
        for _ in 0..<60 {
            if Displays.online().contains(id), !Displays.modes(of: id).isEmpty { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if ProcessInfo.processInfo.environment["HIDPI_DEBUG"] != nil {
            let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let raw = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
            print("debug: id \(id) online \(Displays.online()) rawModes \(raw.map { "\($0.width)x\($0.height)/\($0.pixelWidth) gui=\($0.isUsableForDesktopGUI())" })")
        }
        throw DisplayError.timeout("The virtual display did not come online.")
    }
}

private func fnv1a(_ string: String) -> UInt32 {
    var hash: UInt32 = 0x811C_9DC5
    for byte in string.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 0x0100_0193
    }
    return hash
}

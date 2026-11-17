import AppKit
import CoreGraphics

/// A resolution as the user sees it: "looks like W x H", rendered at 1x or 2x.
struct Resolution: Hashable, Identifiable, Codable {
    var width: Int
    var height: Int
    var hiDPI: Bool

    var id: String { "\(width)x\(height)\(hiDPI ? "@2x" : "")" }
    var label: String { "\(width) × \(height)" }
    var points: CGSize { CGSize(width: width, height: height) }
}

/// One `CGDisplayMode` together with the numbers we care about.
struct ModeInfo {
    let mode: CGDisplayMode
    let resolution: Resolution
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isNative: Bool

    init(_ mode: CGDisplayMode) {
        self.mode = mode
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = mode.refreshRate
        resolution = Resolution(width: mode.width, height: mode.height, hiDPI: mode.pixelWidth > mode.width)
        isNative = (mode.ioFlags & 0x0200_0000) != 0 // kDisplayModeNativeFlag
    }
}

enum DisplayError: LocalizedError {
    case cg(String, CGError)
    case noMode(Resolution)
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case let .cg(what, code): return "\(what) failed (CGError \(code.rawValue))."
        case let .noMode(r): return "The display has no \(r.label) mode."
        case let .timeout(what): return what
        }
    }
}

enum Displays {
    static func online() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func modes(of display: CGDirectDisplayID) -> [ModeInfo] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
        return modes.filter { $0.isUsableForDesktopGUI() }.map(ModeInfo.init)
    }

    static func currentMode(of display: CGDirectDisplayID) -> ModeInfo? {
        CGDisplayCopyDisplayMode(display).map(ModeInfo.init)
    }

    /// The panel's real pixel size.
    static func nativePixelSize(of display: CGDirectDisplayID) -> (width: Int, height: Int) {
        let all = modes(of: display)
        if let native = all.first(where: \.isNative) {
            return (native.pixelWidth, native.pixelHeight)
        }
        // Fall back to the biggest 1x mode, which is the panel size on almost every display.
        let lowRes = all.filter { !$0.resolution.hiDPI }
        if let biggest = lowRes.max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) {
            return (biggest.pixelWidth, biggest.pixelHeight)
        }
        return (Int(CGDisplayPixelsWide(display)), Int(CGDisplayPixelsHigh(display)))
    }

    /// One entry per resolution, using the mode closest to `refreshRate`.
    static func resolutions(of display: CGDirectDisplayID, preferringRefresh refreshRate: Double) -> [Resolution: ModeInfo] {
        var best: [Resolution: ModeInfo] = [:]
        for info in modes(of: display) {
            guard let current = best[info.resolution] else { best[info.resolution] = info; continue }
            if abs(info.refreshRate - refreshRate) < abs(current.refreshRate - refreshRate) {
                best[info.resolution] = info
            }
        }
        return best
    }

    static func setMode(_ mode: CGDisplayMode, on display: CGDirectDisplayID, option: CGConfigureOption = .permanently) throws {
        try configure("Changing the resolution", option: option) { config in
            CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
        }
    }

    /// Makes `display` show the content of `master` (or stop mirroring when `master` is nil).
    static func mirror(_ display: CGDirectDisplayID, to master: CGDirectDisplayID?, option: CGConfigureOption = .forSession) throws {
        try configure(master == nil ? "Stopping the mirror" : "Mirroring", option: option) { config in
            CGConfigureDisplayMirrorOfDisplay(config, display, master ?? kCGNullDirectDisplay)
        }
    }

    private static func configure(_ what: String, option: CGConfigureOption, _ body: (CGDisplayConfigRef?) -> CGError) throws {
        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success else { throw DisplayError.cg(what, error) }
        error = body(config)
        guard error == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError.cg(what, error)
        }
        error = CGCompleteDisplayConfiguration(config, option)
        guard error == .success else { throw DisplayError.cg(what, error) }
    }

    @MainActor
    static func name(of display: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if number?.uint32Value == display { return screen.localizedName }
        }
        return nil
    }

    /// Stable identity of a physical display across reconnects and reboots.
    static func persistentKey(of display: CGDirectDisplayID) -> String {
        "\(CGDisplayVendorNumber(display))-\(CGDisplayModelNumber(display))-\(CGDisplaySerialNumber(display))"
    }
}

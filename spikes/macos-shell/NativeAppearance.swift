import AppKit

private let themeAccentColors: [String: NSColor] = [
    "Graphite": NSColor(calibratedRed: 0.54, green: 0.56, blue: 0.62, alpha: 1.0),
    "Juniper": NSColor(calibratedRed: 0.18, green: 0.62, blue: 0.43, alpha: 1.0),
    "Harbor": NSColor(deviceRed: 0.10, green: 0.50, blue: 0.82, alpha: 1.0),
    "Rose": NSColor(calibratedRed: 0.78, green: 0.32, blue: 0.48, alpha: 1.0),
    "Paper": NSColor(calibratedRed: 0.78, green: 0.57, blue: 0.26, alpha: 1.0),
]

func themeAccentColor(_ theme: String?) -> NSColor {
    guard let theme else {
        return themeAccentColors["Graphite"] ?? NSColor.controlAccentColor
    }
    return themeAccentColors[theme] ?? NSColor.controlAccentColor
}

/// Owns the small amount of platform-specific navigation presentation in Satin.
///
/// Keep availability checks here so the rest of the shell can continue to use
/// semantic AppKit controls. When macOS changes its standard navigation
/// appearance again, this is the only compatibility boundary that should need
/// to change.
enum NativePlatformAppearance {
    enum WindowRole {
        case terminal
        case settings
    }

    static var usesLiquidGlass: Bool {
        #if SATIN_HAS_LIQUID_GLASS_SDK
            if #available(macOS 26.0, *) {
                return true
            }
        #endif
        return false
    }

    static func configureWindow(_ window: NSWindow, role: WindowRole) {
        window.titleVisibility = .hidden
        window.toolbarStyle = role == .terminal ? .unifiedCompact : .unified
        window.titlebarSeparatorStyle = .none
        guard role == .terminal else {
            return
        }
        if #available(macOS 26.0, *) {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
        }
    }

    static func configureTabControl(_ control: NSSegmentedControl) {
        control.segmentStyle = .separated
        control.segmentDistribution = .fit
        control.selectedSegmentBezelColor = nil
    }

}

final class NativeTerminalBackdropView: NSView {
    private var accentColor = themeAccentColor(nil)

    override var isOpaque: Bool {
        true
    }

    func updateAccentColor(_ color: NSColor) {
        accentColor = color
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let base = NSColor(calibratedRed: 0.078, green: 0.086, blue: 0.102, alpha: 1)
        base.setFill()
        dirtyRect.fill()
        let resolvedAccent = accentColor.usingColorSpace(.deviceRGB) ?? accentColor
        let top = base.blended(withFraction: 0.42, of: resolvedAccent) ?? base
        NSGradient(starting: base, ending: top)?.draw(in: bounds, angle: 90)
    }
}

func colorSwatchImage(_ color: NSColor) -> NSImage {
    let image = NSImage(size: NSSize(width: 14, height: 14))
    image.lockFocus()
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 12, height: 12), xRadius: 3, yRadius: 3)
        .fill()
    image.unlockFocus()
    return image
}

func metalObjectPointer(_ object: AnyObject) -> UnsafeMutableRawPointer {
    Unmanaged.passUnretained(object).toOpaque()
}

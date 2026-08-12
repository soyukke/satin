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
        control.segmentStyle = .automatic
    }

    static func makeToolbarControls(
        sessionControl: NSButton,
        actionControl: NSSegmentedControl
    ) -> NSView {
        #if SATIN_HAS_LIQUID_GLASS_SDK
            if #available(macOS 26.0, *) {
                sessionControl.isBordered = false
                sessionControl.bezelStyle = .inline
                actionControl.segmentStyle = .automatic
                return NativeLiquidGlassToolbarControls(
                    sessionControl: sessionControl,
                    actionControl: actionControl
                )
            }
        #endif

        sessionControl.bezelStyle = .texturedRounded
        actionControl.segmentStyle = .capsule
        let stack = NSStackView(views: [sessionControl, actionControl])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    static func toolbarControlsUseExpectedPresentation(_ view: NSView) -> Bool {
        #if SATIN_HAS_LIQUID_GLASS_SDK
            if #available(macOS 26.0, *) {
                return view is NativeLiquidGlassToolbarControls
            }
        #endif
        return view is NSStackView
    }

    static func toolbarControlContentSizeDidChange(_ view: NSView) {
        #if SATIN_HAS_LIQUID_GLASS_SDK
            if #available(macOS 26.0, *),
                let controls = view as? NativeLiquidGlassToolbarControls
            {
                controls.updatePreferredSize()
                return
            }
        #endif
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
        view.superview?.needsLayout = true
    }
}

#if SATIN_HAS_LIQUID_GLASS_SDK
    @available(macOS 26.0, *)
    private final class NativeLiquidGlassToolbarControls: NSView {
        private enum Metrics {
            static let height: CGFloat = 28
            static let spacing: CGFloat = 6
            static let controlVerticalInset: CGFloat = 1
            static let sessionHorizontalInset: CGFloat = 6
            static let actionsHorizontalInset: CGFloat = 2
            static let minimumSessionWidth: CGFloat = 86
            static let minimumActionsWidth: CGFloat = 94
        }

        private let sessionControl: NSButton
        private let actionControl: NSSegmentedControl
        private let container = NSGlassEffectContainerView()
        private let containerContent = NSView()
        private let sessionGlass = NSGlassEffectView()
        private let actionsGlass = NSGlassEffectView()
        private var preferredWidthConstraint: NSLayoutConstraint?
        private var preferredHeightConstraint: NSLayoutConstraint?

        init(sessionControl: NSButton, actionControl: NSSegmentedControl) {
            self.sessionControl = sessionControl
            self.actionControl = actionControl
            super.init(frame: .zero)

            sessionGlass.style = .regular
            sessionGlass.cornerRadius = Metrics.height / 2
            sessionGlass.contentView = sessionControl
            actionsGlass.style = .regular
            actionsGlass.cornerRadius = Metrics.height / 2
            actionsGlass.contentView = actionControl
            container.spacing = Metrics.spacing + 4
            container.contentView = containerContent
            containerContent.addSubview(sessionGlass)
            containerContent.addSubview(actionsGlass)
            addSubview(container)
            updatePreferredSize()
        }

        required init?(coder: NSCoder) {
            nil
        }

        override var intrinsicContentSize: NSSize {
            let sessionWidth = max(
                Metrics.minimumSessionWidth,
                sessionContentWidth + Metrics.sessionHorizontalInset * 2
            )
            let actionsWidth = max(
                Metrics.minimumActionsWidth,
                actionControl.fittingSize.width + Metrics.actionsHorizontalInset * 2
            )
            return NSSize(
                width: sessionWidth + Metrics.spacing + actionsWidth,
                height: Metrics.height
            )
        }

        func updatePreferredSize() {
            let size = intrinsicContentSize
            if preferredWidthConstraint == nil {
                preferredWidthConstraint = widthAnchor.constraint(equalToConstant: size.width)
                preferredHeightConstraint = heightAnchor.constraint(equalToConstant: size.height)
                preferredWidthConstraint?.isActive = true
                preferredHeightConstraint?.isActive = true
            } else {
                preferredWidthConstraint?.constant = size.width
                preferredHeightConstraint?.constant = size.height
            }
            invalidateIntrinsicContentSize()
            needsLayout = true
            superview?.needsLayout = true
        }

        override func layout() {
            super.layout()
            container.frame = bounds
            containerContent.frame = container.bounds

            let sessionWidth = max(
                Metrics.minimumSessionWidth,
                sessionContentWidth + Metrics.sessionHorizontalInset * 2
            )
            let actionsWidth = max(
                Metrics.minimumActionsWidth,
                bounds.width - sessionWidth - Metrics.spacing
            )
            sessionGlass.frame = NSRect(
                x: 0,
                y: 0,
                width: sessionWidth,
                height: bounds.height
            )
            actionsGlass.frame = NSRect(
                x: sessionWidth + Metrics.spacing,
                y: 0,
                width: actionsWidth,
                height: bounds.height
            )
            sessionControl.frame = sessionGlass.bounds.insetBy(
                dx: Metrics.sessionHorizontalInset,
                dy: Metrics.controlVerticalInset
            )
            actionControl.frame = actionsGlass.bounds.insetBy(
                dx: Metrics.actionsHorizontalInset,
                dy: Metrics.controlVerticalInset
            )
        }

        private var sessionContentWidth: CGFloat {
            let font = sessionControl.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let titleWidth = (sessionControl.title as NSString).size(withAttributes: [
                .font: font
            ]).width
            let imageWidth = sessionControl.image?.size.width ?? 0
            let imageSpacing: CGFloat = sessionControl.image == nil ? 0 : 5
            return ceil(titleWidth + imageWidth + imageSpacing)
        }
    }
#endif

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

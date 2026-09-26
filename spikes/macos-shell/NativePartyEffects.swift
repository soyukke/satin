import AppKit
import QuartzCore

/// Motion for party frames. Every effect is skipped when the system asks for
/// reduced motion, leaving the static status colors in place.
enum NativePartyEffects {
    private static let pulseKey = "satin.party.pulse"
    private static let flashKey = "satin.party.flash"

    static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func setPulse(
        _ layer: CALayer?,
        active: Bool,
        minimumOpacity: Float,
        duration: CFTimeInterval
    ) {
        guard let layer else {
            return
        }
        guard active, !reducesMotion else {
            layer.removeAnimation(forKey: pulseKey)
            return
        }
        guard layer.animation(forKey: pulseKey) == nil else {
            return
        }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = minimumOpacity
        pulse.duration = duration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: pulseKey)
    }

    static func flash(_ layer: CALayer?, color: NSColor) {
        guard let layer, !reducesMotion else {
            return
        }
        let flash = CABasicAnimation(keyPath: "backgroundColor")
        flash.fromValue = color.withAlphaComponent(0.55).cgColor
        flash.duration = 0.9
        flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(flash, forKey: flashKey)
    }
}

/// A transient banner over the panes announcing that an agent in another pane
/// needs input. Selecting it jumps there.
final class NativeRaidWarningView: NSView {
    private static let visibleDuration: TimeInterval = 4

    var onSelect: (() -> Void)?

    private let backgroundView = NSVisualEffectView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var hideWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        select()
    }

    override func accessibilityPerformPress() -> Bool {
        select()
        return true
    }

    func show(tabTitle: String, summary: String) {
        titleLabel.stringValue = "⚠ \(tabTitle) needs you"
        detailLabel.stringValue = summary.isEmpty ? "⌘J to jump" : "\(summary) · ⌘J to jump"
        setAccessibilityLabel("\(tabTitle) needs you. Press Command-J to jump.")
        hideWorkItem?.cancel()
        isHidden = false
        alphaValue = 1
        if !NativePartyEffects.reducesMotion, let layer {
            let pop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            pop.values = [-14, 3, 0]
            pop.keyTimes = [0, 0.6, 1]
            pop.duration = 0.35
            layer.add(pop, forKey: "satin.raid.pop")
        }
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [.announcement: titleLabel.stringValue, .priority: 90]
        )
        let hide = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        hideWorkItem = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: hide)
    }

    func dismiss() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard !isHidden else {
            return
        }
        guard !NativePartyEffects.reducesMotion else {
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.25
                animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                guard let self, self.alphaValue == 0 else {
                    return
                }
                self.isHidden = true
            }
        )
    }

    private func select() {
        dismiss()
        onSelect?()
    }

    private func configure() {
        wantsLayer = true
        isHidden = true
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 10
        backgroundView.layer?.borderWidth = 1.5
        backgroundView.layer?.borderColor = NSColor.systemOrange.cgColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .heavy)
        titleLabel.textColor = .systemOrange
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        addSubview(backgroundView)
        addSubview(titleLabel)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
    }
}

func runNativePartyEffectsSelfTests() -> Bool {
    let layer = CALayer()
    NativePartyEffects.setPulse(layer, active: true, minimumOpacity: 0.3, duration: 1)
    let pulsed = NativePartyEffects.reducesMotion || layer.animationKeys()?.count == 1
    NativePartyEffects.setPulse(layer, active: true, minimumOpacity: 0.3, duration: 1)
    let idempotent = NativePartyEffects.reducesMotion || layer.animationKeys()?.count == 1
    NativePartyEffects.setPulse(layer, active: false, minimumOpacity: 0.3, duration: 1)
    guard pulsed, idempotent, layer.animationKeys() == nil else {
        return false
    }

    let warning = NativeRaidWarningView(frame: NSRect(x: 0, y: 0, width: 400, height: 56))
    var selections = 0
    warning.onSelect = { selections += 1 }
    guard warning.isHidden else {
        return false
    }
    warning.show(tabTitle: "api", summary: "Claude Code needs approval")
    let labels = warning.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
    guard !warning.isHidden,
        labels == ["⚠ api needs you", "Claude Code needs approval · ⌘J to jump"],
        warning.accessibilityPerformPress(),
        selections == 1
    else {
        return false
    }
    return true
}

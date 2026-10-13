import AppKit
import QuartzCore

/// Motion for the attention hand. Every effect is skipped when the system asks
/// for reduced motion, leaving the static status colors in place.
enum NativeHandEffects {
    private static let pulseKey = "satin.hand.pulse"
    private static let flashKey = "satin.hand.flash"

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

func runNativeHandEffectsSelfTests() -> Bool {
    let layer = CALayer()
    NativeHandEffects.setPulse(layer, active: true, minimumOpacity: 0.3, duration: 1)
    let pulsed = NativeHandEffects.reducesMotion || layer.animationKeys()?.count == 1
    NativeHandEffects.setPulse(layer, active: true, minimumOpacity: 0.3, duration: 1)
    let idempotent = NativeHandEffects.reducesMotion || layer.animationKeys()?.count == 1
    NativeHandEffects.setPulse(layer, active: false, minimumOpacity: 0.3, duration: 1)
    return pulsed && idempotent && layer.animationKeys() == nil
}

/// A ball of fire that carries a new card from its tab to the hand, leaving a
/// tail long enough for a late eye to follow back to where it came from.
enum NativeHandComet {
    static let duration: CFTimeInterval = 0.7

    private static let spark: CGImage? = {
        let size = 32
        guard
            let context = CGContext(
                data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                    CGColor(red: 1, green: 1, blue: 1, alpha: 0),
                ] as CFArray,
                locations: [0, 1])
        else {
            return nil
        }
        let center = CGPoint(x: size / 2, y: size / 2)
        context.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center,
            endRadius: CGFloat(size / 2), options: [])
        return context.makeImage()
    }()

    /// The curve a comet flies and a tether hangs along.
    static func path(from start: CGPoint, to end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(
            to: end,
            control: CGPoint(
                x: (start.x + end.x) / 2 + (start.y - end.y) * 0.16,
                y: (start.y + end.y) / 2))
        return path
    }

    static func fly(
        in host: CALayer,
        from start: CGPoint,
        to end: CGPoint,
        color: NSColor,
        completion: @escaping () -> Void
    ) {
        let flight = path(from: start, to: end)
        let head = CALayer()
        head.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        head.cornerRadius = 6
        head.backgroundColor = NSColor.white.cgColor
        head.shadowColor = color.cgColor
        head.shadowOpacity = 1
        head.shadowRadius = 10
        head.shadowOffset = .zero
        head.position = end
        let tail = emitter(color: color, birthRate: 160, lifetime: 0.55, velocity: 16)
        tail.emitterPosition = end
        host.addSublayer(tail)
        host.addSublayer(head)

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            head.removeFromSuperlayer()
            tail.birthRate = 0
            burst(in: host, at: end, color: color)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                tail.removeFromSuperlayer()
            }
            completion()
        }
        for (layer, keyPath) in [(head, "position"), (tail as CALayer, "emitterPosition")] {
            let move = CAKeyframeAnimation(keyPath: keyPath)
            move.path = flight
            move.duration = duration
            move.calculationMode = .paced
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(move, forKey: "satin.hand.comet")
        }
        CATransaction.commit()
    }

    /// Sparks thrown out where a comet lands or a played card reaches its tab.
    static func burst(in host: CALayer, at point: CGPoint, color: NSColor) {
        guard !NativeHandEffects.reducesMotion else {
            return
        }
        let sparks = emitter(color: color, birthRate: 600, lifetime: 0.45, velocity: 120)
        sparks.emitterPosition = point
        host.addSublayer(sparks)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            sparks.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            sparks.removeFromSuperlayer()
        }
    }

    private static func emitter(
        color: NSColor,
        birthRate: Float,
        lifetime: Float,
        velocity: CGFloat
    ) -> CAEmitterLayer {
        let cell = CAEmitterCell()
        cell.contents = spark
        cell.birthRate = birthRate
        cell.lifetime = lifetime
        cell.lifetimeRange = lifetime * 0.4
        cell.velocity = velocity
        cell.velocityRange = velocity * 0.6
        cell.emissionRange = .pi * 2
        cell.scale = 0.42
        cell.scaleRange = 0.2
        cell.scaleSpeed = -0.6
        cell.alphaSpeed = -1 / lifetime
        cell.color = color.cgColor
        let layer = CAEmitterLayer()
        layer.emitterShape = .point
        layer.renderMode = .additive
        layer.emitterCells = [cell]
        return layer
    }
}

/// What the selected card's pane shows, large enough to read before playing it.
final class NativeHandPreviewView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let screenLabel = NSTextField(wrappingLabelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "release ⌘ or click to play · esc cancels")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor =
            NSColor(srgbRed: 0.05, green: 0.07, blue: 0.14, alpha: 0.96).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        titleLabel.font = .systemFont(ofSize: 10, weight: .bold)
        screenLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        screenLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        screenLabel.maximumNumberOfLines = 12
        screenLabel.lineBreakMode = .byTruncatingTail
        hintLabel.font = .systemFont(ofSize: 9.5)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        let stack = NSStackView(views: [titleLabel, screenLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(card: NativeHandCard, screen: String, color: NSColor) {
        titleLabel.stringValue = "\(card.title.uppercased()) · \(card.kind.title)"
        titleLabel.textColor = color
        screenLabel.stringValue = screen.isEmpty ? card.summary : screen
        layer?.borderColor = color.cgColor
    }
}

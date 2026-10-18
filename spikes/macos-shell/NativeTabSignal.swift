import AppKit
import QuartzCore

/// Light over the tab strip for work in a tab: a comet sweeping along the
/// foot of each tab whose work runs, and a flourish when it ends, a check
/// drawn and a shine through the tab, or a red cross and a double pulse.
final class NativeTabSignalView: NSView {
    private struct Comet: Equatable {
        let rect: NSRect
        let paper: Bool
    }

    /// The rectangle of a tab in the tab strip's coordinates.
    var segmentRect: ((Int) -> NSRect?)?
    /// The centre of a tab's badge in the tab strip's coordinates.
    var badgeCenter: ((Int) -> NSPoint?)?

    private var running = Set<Int>()
    private var shown = [Int: Comet]()
    private var cometLayers = [Int: CALayer]()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override var isFlipped: Bool {
        superview?.isFlipped ?? false
    }

    func refreshLook() {
        rebuild()
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    func update(running: Set<Int>) {
        self.running = running
        rebuild()
    }

    private func tabRect(_ segment: Int) -> NSRect? {
        guard let rect = segmentRect?(segment) else {
            return nil
        }
        return superview.map { convert(rect, from: $0) } ?? rect
    }

    /// The edge of a tab the comet runs along: the foot of the terminal
    /// look's frame, or the top of paper's folder tab, its foot being the
    /// line the tabs stand on.
    private func track(_ comet: Comet) -> (y: CGFloat, minX: CGFloat, maxX: CGFloat) {
        if comet.paper {
            let rect = NativePaperTab.rect(comet.rect, flipped: isFlipped)
            let top = isFlipped ? rect.minY + 1 : rect.maxY - 1
            return (top, rect.minX + 6, rect.maxX - 6)
        }
        let rect = nativeTerminalTabFrame(comet.rect)
        return (isFlipped ? rect.maxY : rect.minY, rect.minX, rect.maxX)
    }

    private func rebuild() {
        var wanted = [Int: Comet]()
        if !NativeHandEffects.reducesMotion {
            for segment in running {
                if let rect = tabRect(segment) {
                    wanted[segment] = Comet(rect: rect, paper: NativePageStyle.paper)
                }
            }
        }
        guard wanted != shown else {
            return
        }
        for (segment, layer) in cometLayers where wanted[segment] != shown[segment] {
            layer.removeFromSuperlayer()
            cometLayers.removeValue(forKey: segment)
        }
        for (segment, comet) in wanted where cometLayers[segment] == nil {
            let layer = makeComet(comet)
            self.layer?.addSublayer(layer)
            cometLayers[segment] = layer
        }
        shown = wanted
    }

    private var tint: NSColor {
        NativePageStyle.paper ? NativePageStyle.text : NativePageStyle.violet
    }

    private func makeComet(_ comet: Comet) -> CALayer {
        let track = track(comet)
        let width = track.maxX - track.minX
        let container = CALayer()
        // Tall enough for the glow, and clipped at the tab's ends so the
        // comet enters and leaves within the tab.
        container.frame = NSRect(x: track.minX, y: track.y - 5, width: width, height: 10)
        container.masksToBounds = true

        let rail = CALayer()
        rail.frame = NSRect(x: 0, y: 4, width: width, height: 2)
        rail.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        container.addSublayer(rail)

        // A bright head with a tail fading behind it, glowing.
        let length = max(18, width * 0.38)
        let head = CAGradientLayer()
        head.frame = NSRect(x: -length, y: 4, width: length, height: 2)
        head.startPoint = CGPoint(x: 0, y: 0.5)
        head.endPoint = CGPoint(x: 1, y: 0.5)
        head.colors = [
            tint.withAlphaComponent(0).cgColor,
            tint.withAlphaComponent(0.55).cgColor,
            tint.cgColor,
            NSColor.white.withAlphaComponent(0.95).cgColor,
        ]
        head.locations = [0, 0.55, 0.88, 1]
        head.shadowColor = tint.cgColor
        head.shadowOpacity = 0.9
        head.shadowRadius = 3
        head.shadowOffset = .zero
        container.addSublayer(head)

        // It crosses and comes back reversed, so the head always leads.
        let sweep = CAKeyframeAnimation(keyPath: "transform")
        let out = CATransform3DMakeTranslation(0, 0, 0)
        let across = CATransform3DMakeTranslation(width + length, 0, 0)
        let flipped = CATransform3DConcat(
            CATransform3DMakeScale(-1, 1, 1), CATransform3DMakeTranslation(width + length, 0, 0))
        let back = CATransform3DConcat(
            CATransform3DMakeScale(-1, 1, 1), CATransform3DMakeTranslation(0, 0, 0))
        sweep.values = [out, across, flipped, back].map { NSValue(caTransform3D: $0) }
        sweep.keyTimes = [0, 0.5, 0.5, 1]
        sweep.timingFunctions = [
            NativeEase.glide, CAMediaTimingFunction(name: .linear), NativeEase.glide,
        ]
        sweep.duration = 2.2
        sweep.repeatCount = .infinity
        sweep.preferredFrameRateRange = NativeHandEffects.ambientFrameRate
        head.add(sweep, forKey: "satin.tab.comet")

        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.55
        breathe.toValue = 1
        breathe.duration = 1.1
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.preferredFrameRateRange = NativeHandEffects.ambientFrameRate
        rail.add(breathe, forKey: "satin.tab.rail")
        return container
    }

    /// Plays the end of a tab's work over it once.
    func finish(segment: Int, failed: Bool) {
        guard !NativeHandEffects.reducesMotion, let rect = tabRect(segment),
            let center = badgeCenter?(segment).map({ point in
                superview.map { convert(point, from: $0) } ?? point
            }),
            let host = layer
        else {
            return
        }
        let color = failed ? NSColor.systemRed : NSColor.systemGreen
        let flourish = CALayer()
        flourish.frame = bounds
        host.addSublayer(flourish)
        let now = CACurrentMediaTime()

        // The tab's edge flares, once for a finish and twice for a failure.
        let paper = NativePageStyle.paper
        let outline = CAShapeLayer()
        if paper {
            let tab = NativePaperTab.rect(rect, flipped: isFlipped)
            let path = NativePaperTab.outline(tab, flipped: isFlipped)
            path.close()
            outline.path = path.cgPath
        } else {
            outline.path = CGPath(rect: nativeTerminalTabFrame(rect), transform: nil)
        }
        outline.fillColor = color.withAlphaComponent(0.12).cgColor
        outline.strokeColor = color.cgColor
        outline.lineWidth = 1.5
        outline.shadowColor = color.cgColor
        outline.shadowOpacity = 1
        outline.shadowRadius = 6
        outline.shadowOffset = .zero
        outline.opacity = 0
        flourish.addSublayer(outline)
        let flare = CAKeyframeAnimation(keyPath: "opacity")
        flare.values = failed ? [0, 1, 0.15, 1, 0] : [0, 1, 0]
        flare.keyTimes = failed ? [0, 0.12, 0.32, 0.46, 1] : [0, 0.14, 1]
        flare.duration = failed ? 1.1 : 0.95
        flare.beginTime = now + 0.12
        flare.fillMode = .backwards
        outline.add(flare, forKey: "satin.tab.flare")

        // A shine leaves the badge and runs through the tab.
        let frame =
            paper ? NativePaperTab.rect(rect, flipped: isFlipped) : nativeTerminalTabFrame(rect)
        let clip = CALayer()
        clip.frame = frame
        clip.masksToBounds = true
        flourish.addSublayer(clip)
        let band = max(24, frame.width * 0.45)
        let shine = CAGradientLayer()
        shine.frame = NSRect(x: -band, y: 0, width: band, height: frame.height)
        shine.startPoint = CGPoint(x: 0, y: 0.5)
        shine.endPoint = CGPoint(x: 1, y: 0.5)
        shine.colors = [
            color.withAlphaComponent(0).cgColor,
            color.withAlphaComponent(0.35).cgColor,
            NSColor.white.withAlphaComponent(0.45).cgColor,
            color.withAlphaComponent(0.35).cgColor,
            color.withAlphaComponent(0).cgColor,
        ]
        shine.opacity = 0
        clip.addSublayer(shine)
        let run = CABasicAnimation(keyPath: "position.x")
        run.fromValue = center.x - frame.minX
        run.toValue = frame.width + band / 2
        run.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.1, 0.25, 1)
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [0, 1, 1, 0]
        show.keyTimes = [0, 0.15, 0.7, 1]
        let sweep = CAAnimationGroup()
        sweep.animations = [run, show]
        sweep.duration = 0.65
        sweep.beginTime = now + 0.18
        shine.add(sweep, forKey: "satin.tab.shine")

        // A disc pops up at the badge and the mark is drawn into it; then it
        // settles into the badge's dot and is gone.
        let radius: CGFloat = 7
        let disc = CAShapeLayer()
        disc.frame = NSRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        disc.path = CGPath(ellipseIn: disc.bounds, transform: nil)
        disc.fillColor = color.cgColor
        disc.shadowColor = color.cgColor
        disc.shadowOpacity = 0.9
        disc.shadowRadius = 5
        disc.shadowOffset = .zero
        flourish.addSublayer(disc)

        let mark = CAShapeLayer()
        mark.frame = disc.bounds
        let path = CGMutablePath()
        let up: CGFloat = isFlipped ? -1 : 1
        let c = CGPoint(x: radius, y: radius)
        if failed {
            path.move(to: CGPoint(x: c.x - 2.6, y: c.y - 2.6))
            path.addLine(to: CGPoint(x: c.x + 2.6, y: c.y + 2.6))
            path.move(to: CGPoint(x: c.x - 2.6, y: c.y + 2.6))
            path.addLine(to: CGPoint(x: c.x + 2.6, y: c.y - 2.6))
        } else {
            path.move(to: CGPoint(x: c.x - 3.2, y: c.y + 0.2 * up))
            path.addLine(to: CGPoint(x: c.x - 0.9, y: c.y - 2.3 * up))
            path.addLine(to: CGPoint(x: c.x + 3.4, y: c.y + 2.6 * up))
        }
        mark.path = path
        mark.fillColor = nil
        mark.strokeColor = NSColor.white.cgColor
        mark.lineWidth = 1.7
        mark.lineCap = .round
        mark.lineJoin = .round
        mark.strokeEnd = 0
        disc.addSublayer(mark)

        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.2
        pop.toValue = 1
        pop.damping = 11
        pop.stiffness = 260
        pop.duration = pop.settlingDuration
        pop.beginTime = now
        pop.fillMode = .backwards
        disc.add(pop, forKey: "satin.tab.pop")

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = 0.3
        draw.beginTime = now + 0.14
        draw.timingFunction = NativeEase.glide
        draw.fillMode = .forwards
        draw.isRemovedOnCompletion = false
        mark.add(draw, forKey: "satin.tab.draw")

        let settle = CABasicAnimation(keyPath: "transform.scale")
        settle.toValue = 0.5
        let vanish = CABasicAnimation(keyPath: "opacity")
        vanish.toValue = 0
        let leave = CAAnimationGroup()
        leave.animations = [settle, vanish]
        leave.duration = 0.35
        leave.beginTime = now + 1.25
        leave.timingFunction = CAMediaTimingFunction(name: .easeIn)
        leave.fillMode = .forwards
        leave.isRemovedOnCompletion = false
        disc.add(leave, forKey: "satin.tab.leave")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
            flourish.removeFromSuperlayer()
        }
    }
}

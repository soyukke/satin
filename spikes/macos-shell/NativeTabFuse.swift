import AppKit
import QuartzCore

/// A spark running round the edge of each tab that is waiting for the user,
/// drawn over the tab strip. The tab a selected card belongs to gets a steady
/// outline instead, so the card's destination is seen before it is played.
final class NativeTabFuseView: NSView {
    private struct Fuse: Equatable {
        let rect: NSRect
        let color: NSColor
        let steady: Bool
        let paper: Bool
    }

    /// The rectangle of a tab in the tab strip's coordinates.
    var segmentRect: ((Int) -> NSRect?)?

    private var colors = [Int: NSColor]()
    private var target: (segment: Int, color: NSColor)?
    private var shown = [Int: Fuse]()
    private var fuseLayers = [Int: CALayer]()

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

    /// The tab strip's tabs have a top and a foot; the fuse follows them.
    override var isFlipped: Bool {
        superview?.isFlipped ?? false
    }

    /// Redraws the fuses in the current mode's tab shape.
    func refreshLook() {
        rebuild()
    }

    override func layout() {
        super.layout()
        rebuild()
    }

    func update(_ colors: [Int: NSColor]) {
        self.colors = colors
        rebuild()
    }

    func setTarget(segment: Int?, color: NSColor) {
        target = segment.map { ($0, color) }
        rebuild()
    }

    /// A tab's rectangle in this view. The tab strip lays this view out a
    /// little inside its own bounds, so the tab's rectangle is converted.
    private func tabRect(_ segment: Int) -> NSRect? {
        guard let rect = segmentRect?(segment) else {
            return nil
        }
        return superview.map { convert(rect, from: $0) } ?? rect
    }

    private func rebuild() {
        var wanted = [Int: Fuse]()
        for (segment, color) in colors {
            if let rect = tabRect(segment) {
                wanted[segment] = Fuse(
                    rect: rect, color: color, steady: false, paper: NativePageStyle.paper)
            }
        }
        if let target, let rect = tabRect(target.segment) {
            wanted[target.segment] = Fuse(
                rect: rect, color: target.color, steady: true, paper: NativePageStyle.paper)
        }
        guard wanted != shown else {
            return
        }
        for (segment, layer) in fuseLayers where wanted[segment] != shown[segment] {
            layer.removeFromSuperlayer()
            fuseLayers.removeValue(forKey: segment)
        }
        for (segment, fuse) in wanted where fuseLayers[segment] == nil {
            let layer = makeLayer(fuse)
            self.layer?.addSublayer(layer)
            fuseLayers[segment] = layer
        }
        shown = wanted
    }

    private func makeLayer(_ fuse: Fuse) -> CALayer {
        // The fuse runs along the tab's own edge: the terminal look's square
        // frame, or paper's folder tab with its foot closed.
        let path: CGPath
        let perimeter: CGFloat
        if fuse.paper {
            let rect = NativePaperTab.rect(fuse.rect, flipped: isFlipped)
            let outline = NativePaperTab.outline(rect, flipped: isFlipped)
            outline.close()
            path = outline.cgPath
            perimeter = NativePaperTab.perimeter(rect)
        } else {
            let rect = nativeTerminalTabFrame(fuse.rect)
            path = CGPath(rect: rect, transform: nil)
            perimeter = 2 * (rect.width + rect.height)
        }
        let container = CALayer()
        func stroke(length: CGFloat, alpha: CGFloat, width: CGFloat, color: NSColor) -> CAShapeLayer
        {
            let shape = CAShapeLayer()
            shape.path = path
            shape.fillColor = nil
            shape.strokeColor = color.withAlphaComponent(alpha).cgColor
            shape.lineWidth = width
            shape.lineCap = .round
            shape.shadowColor = fuse.color.cgColor
            shape.shadowOpacity = 0.9
            shape.shadowRadius = 4
            shape.shadowOffset = .zero
            if length < perimeter {
                shape.lineDashPattern = [
                    NSNumber(value: length), NSNumber(value: perimeter - length),
                ]
            }
            container.addSublayer(shape)
            return shape
        }
        guard !fuse.steady, !NativeHandEffects.reducesMotion else {
            _ = stroke(length: perimeter, alpha: 0.95, width: 2, color: fuse.color)
            return container
        }
        _ = stroke(length: perimeter, alpha: 0.22, width: 1, color: fuse.color)
        let layers = [
            stroke(length: perimeter * 0.34, alpha: 0.35, width: 2, color: fuse.color),
            stroke(length: perimeter * 0.16, alpha: 0.8, width: 2, color: fuse.color),
            stroke(length: 7, alpha: 1, width: 3, color: .white),
        ]
        for (index, shape) in layers.enumerated() {
            // Each shorter stroke sits at the front of the longer one behind it.
            let lead: [CGFloat] = [perimeter * 0.34, perimeter * 0.16, 7]
            let offset = lead[0] - lead[index]
            let run = CABasicAnimation(keyPath: "lineDashPhase")
            run.fromValue = -offset
            run.toValue = -offset - perimeter
            run.duration = 1.7
            run.repeatCount = .infinity
            run.preferredFrameRateRange = NativeHandEffects.ambientFrameRate
            shape.add(run, forKey: "satin.tab.fuse")
        }
        return container
    }
}

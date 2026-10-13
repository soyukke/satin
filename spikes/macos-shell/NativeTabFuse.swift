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
    }

    /// The rectangle of a tab in this view's coordinates.
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

    private func rebuild() {
        var wanted = [Int: Fuse]()
        for (segment, color) in colors {
            if let rect = segmentRect?(segment) {
                wanted[segment] = Fuse(rect: rect, color: color, steady: false)
            }
        }
        if let target, let rect = segmentRect?(target.segment) {
            wanted[target.segment] = Fuse(rect: rect, color: target.color, steady: true)
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
        let rect = fuse.rect.insetBy(dx: 3, dy: 2.5)
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        let perimeter = 2 * (rect.width + rect.height)
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
            shape.add(run, forKey: "satin.tab.fuse")
        }
        return container
    }
}

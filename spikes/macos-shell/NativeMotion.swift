import AppKit
import QuartzCore

/// A clock for motion drawn by hand: it steps a closure from 0 to 1 over a
/// duration. Views whose drawing moves, such as a highlight sliding between
/// rows, use it where a layer animation cannot reach. With motion reduced it
/// jumps straight to the end.
final class NativeTween {
    private var timer: Timer?
    private var start: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var step: ((CGFloat) -> Void)?

    var isRunning: Bool { timer != nil }

    func run(duration: CFTimeInterval, step: @escaping (CGFloat) -> Void) {
        stop()
        guard duration > 0, !NativeHandEffects.reducesMotion else {
            step(1)
            return
        }
        self.duration = duration
        self.step = step
        start = CACurrentMediaTime()
        step(0)
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        step = nil
    }

    private func tick() {
        let progress = min(1, CGFloat((CACurrentMediaTime() - start) / duration))
        let step = self.step
        if progress >= 1 {
            stop()
        }
        step?(progress)
    }
}

enum NativeEase {
    static func out(_ t: CGFloat) -> CGFloat {
        1 - pow(1 - min(max(t, 0), 1), 3)
    }

    /// Runs a little past the end and settles back, for things that land.
    static func back(_ t: CGFloat, overshoot: CGFloat = 1.7) -> CGFloat {
        let u = min(max(t, 0), 1) - 1
        return 1 + u * u * ((overshoot + 1) * u + overshoot)
    }

    static func mix(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
        from + (to - from) * t
    }

    static func mix(_ from: NSRect, _ to: NSRect, _ t: CGFloat) -> NSRect {
        NSRect(
            x: mix(from.minX, to.minX, t), y: mix(from.minY, to.minY, t),
            width: mix(from.width, to.width, t), height: mix(from.height, to.height, t))
    }

    /// A curve for things that settle with a small bounce.
    static let landing = CAMediaTimingFunction(controlPoints: 0.3, 1.4, 0.5, 1)
    static let glide = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
}

/// A blank sheet that flies between where a page is listed and where it is
/// read, so opening a page and going back look like one sheet moving.
enum NativePageFlight {
    /// `strip` colors the sheet's head, as the reader's strip is colored.
    static func fly(
        in view: NSView, from: NSRect, to: NSRect, duration: CFTimeInterval = 0.3,
        strip: NSColor? = nil, done: (() -> Void)? = nil
    ) {
        guard !NativeHandEffects.reducesMotion, from.width > 0, to.width > 0 else {
            done?()
            return
        }
        let sheet = NSView(frame: from)
        sheet.wantsLayer = true
        let paper = NativePageStyle.paper
        sheet.layer?.backgroundColor = NativePageStyle.surface.cgColor
        sheet.layer?.borderColor = (paper ? NativePageStyle.text : NativePageStyle.violet).cgColor
        sheet.layer?.borderWidth = paper ? 2 : 1
        sheet.layer?.cornerRadius = paper ? 4 : 0
        sheet.layer?.shadowColor = NSColor.black.cgColor
        sheet.layer?.shadowOpacity = paper ? 0.25 : 0.5
        sheet.layer?.shadowRadius = 18
        sheet.layer?.shadowOffset = CGSize(width: 0, height: -8)
        if let strip {
            let head = NSView(
                frame: NSRect(
                    x: 0, y: from.height - min(NativePageStyle.strip, from.height / 3),
                    width: from.width, height: min(NativePageStyle.strip, from.height / 3)))
            head.wantsLayer = true
            head.layer?.backgroundColor = strip.cgColor
            head.autoresizingMask = [.width, .minYMargin]
            sheet.addSubview(head)
        }
        view.addSubview(sheet, positioned: .above, relativeTo: nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = NativeEase.glide
            context.allowsImplicitAnimation = true
            sheet.frame = to
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                sheet.animator().alphaValue = 0
            } completionHandler: {
                sheet.removeFromSuperview()
            }
            done?()
        }
    }

    /// Fades views in once a flying sheet has nearly landed on them.
    static func fadeIn(_ views: [NSView], delay: TimeInterval = 0.14) {
        guard !NativeHandEffects.reducesMotion else {
            return
        }
        for view in views {
            view.alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for view in views {
                    view.animator().alphaValue = 1
                }
            }
        }
    }

    /// Fades a view out and takes it away.
    static func fadeOut(_ view: NSView, duration: TimeInterval = 0.16) {
        guard !NativeHandEffects.reducesMotion else {
            view.removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            view.animator().alphaValue = 0
        } completionHandler: {
            view.removeFromSuperview()
        }
    }
}

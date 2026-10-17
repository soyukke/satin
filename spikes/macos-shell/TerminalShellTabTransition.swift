import AppKit

/// Switching tabs pushes the old tab's work aside: a picture of it is taken
/// before the switch and slides away toward the side the old tab sits on,
/// fading, over the new tab's work.
extension TerminalShellViewController {
    /// Takes the picture of the work before a switch to tab `index`. Nil
    /// when there is nothing to move, such as choosing the tab already shown.
    func beginTabTransition(to index: Int) -> (image: CGImage, rect: NSRect, step: Int)? {
        guard !NativeHandEffects.reducesMotion, let active = lastSnapshot?.active_tab,
            active != index, terminalTextView.window != nil
        else {
            return nil
        }
        let rect = terminalTextView.terminalContentRect()
        guard let image = metalView.captureFrame(),
            let cropped = image.cropping(to: pixelRect(of: rect, in: image))
        else {
            return nil
        }
        return (cropped, rect, index > active ? 1 : -1)
    }

    func finishTabTransition(_ transition: (image: CGImage, rect: NSRect, step: Int)?) {
        guard let transition, lastSnapshot?.active_tab != nil else {
            return
        }
        let old = NSView(frame: transition.rect)
        old.wantsLayer = true
        old.layer?.contents = transition.image
        old.layer?.contentsGravity = .resize
        terminalTextView.addSubview(old, positioned: .above, relativeTo: nil)
        let away = CGFloat(-transition.step) * transition.rect.width * 0.16
        // It moves at once but fades late, so the eye follows it out.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.36
            context.timingFunction = NativeEase.glide
            context.allowsImplicitAnimation = true
            old.frame = transition.rect.offsetBy(dx: away, dy: 0)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.6)
            old.animator().alphaValue = 0
        } completionHandler: {
            old.removeFromSuperview()
        }
    }

    /// Where a rect of the terminal view lies in a picture of the whole
    /// Metal view, in the picture's pixels, top down.
    private func pixelRect(of rect: NSRect, in image: CGImage) -> CGRect {
        let inMetal = metalView.convert(rect, from: terminalTextView)
        let scale = CGFloat(image.width) / max(1, metalView.bounds.width)
        let top = metalView.isFlipped ? inMetal.minY : metalView.bounds.height - inMetal.maxY
        return CGRect(
            x: inMetal.minX * scale, y: top * scale, width: inMetal.width * scale,
            height: inMetal.height * scale
        ).integral
    }
}

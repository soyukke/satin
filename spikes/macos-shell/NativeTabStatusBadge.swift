import AppKit
import Foundation

enum NativeTabStatusBadge: Int, Equatable {
    // Higher raw values win when a tab contains panes in different states.
    case done = 0
    case running = 1
    case failed = 2
    case waiting = 3

    var toolTipDescription: String {
        switch self {
        case .done: "Finished — unread"
        case .running: "Running"
        case .failed: "Failed or blocked"
        case .waiting: "Waiting for input"
        }
    }
}

func nativeTabStatusBadge(
    for paneStates: [(status: String, unread: Bool)]
) -> NativeTabStatusBadge? {
    paneStates.compactMap { paneState in
        switch paneState.status {
        case "waiting": .waiting
        case "failed", "blocked": .failed
        case "running": .running
        case "done" where paneState.unread: .done
        default: nil
        }
    }.max { $0.rawValue < $1.rawValue }
}

enum NativeTabStatusBadgeRenderer {
    private static let badgeRadius: CGFloat = 5

    static func draw(
        _ badge: NativeTabStatusBadge,
        center: NSPoint,
        selected: Bool
    ) {
        switch badge {
        case .running:
            drawActivityIndicator(center: center, selected: selected)
        case .waiting:
            drawAttentionBadge(center: center, color: .systemOrange, drawsFailureMark: false)
        case .failed:
            drawAttentionBadge(center: center, color: .systemRed, drawsFailureMark: true)
        case .done:
            let radius: CGFloat = 3.5
            NSColor.systemGreen.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            ).fill()
        }
    }

    private static func drawAttentionBadge(
        center: NSPoint,
        color: NSColor,
        drawsFailureMark: Bool
    ) {
        color.setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: center.x - badgeRadius,
                y: center.y - badgeRadius,
                width: badgeRadius * 2,
                height: badgeRadius * 2
            )
        ).fill()

        let mark = NSBezierPath()
        if drawsFailureMark {
            let offset: CGFloat = 2
            mark.move(to: NSPoint(x: center.x - offset, y: center.y - offset))
            mark.line(to: NSPoint(x: center.x + offset, y: center.y + offset))
            mark.move(to: NSPoint(x: center.x - offset, y: center.y + offset))
            mark.line(to: NSPoint(x: center.x + offset, y: center.y - offset))
        } else {
            mark.move(to: NSPoint(x: center.x, y: center.y + 2.5))
            mark.line(to: NSPoint(x: center.x, y: center.y - 0.5))
            mark.move(to: NSPoint(x: center.x, y: center.y - 2.6))
            mark.line(to: NSPoint(x: center.x, y: center.y - 2.5))
        }
        mark.lineWidth = drawsFailureMark ? 1.25 : 1.5
        mark.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.94).setStroke()
        mark.stroke()
    }

    private static func drawActivityIndicator(center: NSPoint, selected: Bool) {
        let phase = ProcessInfo.processInfo.systemUptime * 5.2
        let color = selected ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        for index in 0..<8 {
            let progress = Double(index) / 8
            let angle = phase + progress * Double.pi * 2
            let inner = badgeRadius * 0.48
            let alpha = 0.2 + progress * 0.72
            let path = NSBezierPath()
            path.move(
                to: NSPoint(
                    x: center.x + CGFloat(cos(angle)) * inner,
                    y: center.y + CGFloat(sin(angle)) * inner
                ))
            path.line(
                to: NSPoint(
                    x: center.x + CGFloat(cos(angle)) * badgeRadius,
                    y: center.y + CGFloat(sin(angle)) * badgeRadius
                ))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            color.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }
    }
}

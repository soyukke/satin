import AppKit

/// Shows each tab's ⌘ digit in the windows sidebar while ⌘ is held. It waits
/// a moment, so the digits stay away from a shortcut pressed at speed.
extension TerminalShellViewController {
    private static let shortcutHintDelay: TimeInterval = 0.3

    func installShortcutHints() {
        guard shortcutHintMonitor == nil else {
            return
        }
        shortcutHintMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.handleShortcutHintEvent(event)
            return event
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideShortcutHints() }
        }
    }

    private func handleShortcutHintEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // A shortcut is being pressed. Digits already out stay, for the
            // next one.
            shortcutHintTimer?.invalidate()
            shortcutHintTimer = nil
            return
        }
        guard nativeHoldsOnlyCommand(event.modifierFlags), event.window === view.window else {
            hideShortcutHints()
            return
        }
        guard shortcutHintTimer == nil, !windowsSidebar.showsShortcuts else {
            return
        }
        let timer = Timer(timeInterval: Self.shortcutHintDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shortcutHintTimer = nil
                self?.windowsSidebar.showsShortcuts = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shortcutHintTimer = timer
    }

    private func hideShortcutHints() {
        shortcutHintTimer?.invalidate()
        shortcutHintTimer = nil
        windowsSidebar.showsShortcuts = false
    }
}

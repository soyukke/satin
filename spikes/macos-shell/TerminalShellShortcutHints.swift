import AppKit

/// Shows each tab's ⌘ digit in the windows sidebar while ⌘ is held, and shows
/// pane-tab digits (`1`...`9`) in the top pane tab bar when ⌘ is tapped once
/// and then pressed and held a second time.
extension TerminalShellViewController {
    private static let shortcutHintDelay: TimeInterval = 0.3

    func installShortcutHints() {
        guard shortcutHintMonitor == nil else {
            return
        }
        shortcutHintMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            self?.handleShortcutHintEvent(event) ?? event
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideShortcutHints() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, (notification.object as? NSWindow) === self.view.window else {
                    return
                }
                self.hideShortcutHints()
            }
        }
    }

    private func handleShortcutHintEvent(_ event: NSEvent) -> NSEvent? {
        let inTerminalWindow = event.window === view.window
        let paneGuideEnabled =
            inTerminalWindow
            && paneDisplayMode == .tab
            && pageBinder == nil
            && pageReaderChrome == nil

        if event.type == .keyDown {
            let transition = commandDoubleTapState.handleKeyDown(
                flags: event.modifierFlags,
                digit: nativePaneShortcutDigit(for: event),
                isEscape: event.keyCode == 53,
                enabled: paneGuideEnabled
            )
            switch transition {
            case .selectPaneShortcut(let digit):
                selectPaneTabFromShortcut(digit)
                return nil
            case .hidePaneShortcuts:
                terminalTextView.paneTabBarView.showsShortcuts = false
                if event.keyCode == 53 {
                    return nil
                }
            case .showPaneShortcuts, .none:
                break
            }
            // A shortcut is being pressed. Digits already out stay, for the
            // next one.
            shortcutHintTimer?.invalidate()
            shortcutHintTimer = nil
            return event
        }

        let transition = commandDoubleTapState.handleFlagsChanged(
            flags: event.modifierFlags,
            now: event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime,
            enabled: paneGuideEnabled
        )
        switch transition {
        case .showPaneShortcuts:
            shortcutHintTimer?.invalidate()
            shortcutHintTimer = nil
            windowsSidebar.showsShortcuts = false
            terminalTextView.paneTabBarView.showsShortcuts = true
            return event
        case .hidePaneShortcuts:
            terminalTextView.paneTabBarView.showsShortcuts = false
        case .selectPaneShortcut, .none:
            break
        }

        if commandDoubleTapState.isPaneShortcutGuideActive {
            return event
        }

        guard nativeHoldsOnlyCommand(event.modifierFlags), inTerminalWindow else {
            hideSidebarShortcutHints()
            return event
        }
        guard shortcutHintTimer == nil, !windowsSidebar.showsShortcuts else {
            return event
        }
        let timer = Timer(timeInterval: Self.shortcutHintDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.commandDoubleTapState.isPaneShortcutGuideActive else {
                    return
                }
                self.shortcutHintTimer = nil
                self.windowsSidebar.showsShortcuts = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        shortcutHintTimer = timer
        return event
    }

    private func hideSidebarShortcutHints() {
        shortcutHintTimer?.invalidate()
        shortcutHintTimer = nil
        windowsSidebar.showsShortcuts = false
    }

    private func hideShortcutHints() {
        hideSidebarShortcutHints()
        _ = commandDoubleTapState.reset()
        terminalTextView.paneTabBarView.showsShortcuts = false
    }
}

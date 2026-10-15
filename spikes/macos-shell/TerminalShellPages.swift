import AppKit
import Foundation

/// Pages: what agents save with `satin page add`. New ones wait in the
/// binder's inbox; one is read in a reader over the middle of the window.
extension TerminalShellViewController {
    /// The page store's folder, beside the control socket's.
    func pageStoreRoot() -> URL? {
        guard !controlSocketPath.isEmpty else {
            return nil
        }
        let socketDirectory = URL(fileURLWithPath: controlSocketPath).deletingLastPathComponent()
        return
            (socketDirectory.lastPathComponent == "run"
            ? socketDirectory.deletingLastPathComponent()
            : socketDirectory)
            .appendingPathComponent("artifacts", isDirectory: true)
    }

    func startPageInbox(attempt: Int = 0) {
        guard let root = pageStoreRoot() else {
            // The control socket is set up a moment after the window.
            if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startPageInbox(attempt: attempt + 1)
                }
            }
            return
        }
        pageHandView.onOpen = { [weak self] page in
            self?.openPage(page)
        }
        pageHandView.arrivalPoint = { [weak self] in
            guard let self, self.artifactButton.window != nil else {
                return nil
            }
            let frame = self.artifactButton.convert(self.artifactButton.bounds, to: nil)
            return self.pageHandView.convert(NSPoint(x: frame.midX, y: frame.minY), from: nil)
        }
        pageInbox.onChange = { [weak self] arrived in
            self?.pagesChanged(arrived: arrived)
        }
        pageInbox.start(root: root) { [weak self] completion in
            guard let self else { return }
            self.loadRecentArtifacts(limit: 40, completion: completion)
        }
    }

    private func pagesChanged(arrived: [NativeArtifactListItem]) {
        artifactButton.setBadgeCount(pageInbox.unread.count)
        pageHandView.show(unread: pageInbox.unread)
        attentionHandView.rightReserve = pageHandView.fanWidth
        if let binder = pageBinder {
            binder.show(pages: pageInbox.pages, unread: pageInbox.unread)
        }
        if !arrived.isEmpty {
            metalView.pulseBackdrop(NativePageStyle.teal)
            chillSound.chime(for: "done")
        }
    }

    @objc func togglePageBinder(_ sender: Any?) {
        if pageBinder != nil {
            closePageBinder()
        } else {
            openPageBinder()
        }
    }

    func openPageBinder() {
        closePageReader()
        let binder = NativePageBinderView(frame: terminalTextView.bounds)
        binder.autoresizingMask = [.width, .height]
        binder.panel = nativePageReaderFrames(in: terminalTextView.terminalContentRect()).panel
        binder.onOpen = { [weak self] page in
            self?.openPage(page)
        }
        binder.onClose = { [weak self] in
            self?.closePageBinder()
        }
        terminalTextView.addSubview(binder, positioned: .above, relativeTo: nil)
        binder.show(pages: pageInbox.pages, unread: pageInbox.unread)
        pageBinder = binder
        updateHandsSunk()
        view.window?.makeFirstResponder(binder)
        pageInbox.reload()
    }

    func closePageBinder() {
        guard let binder = pageBinder else {
            return
        }
        binder.removeFromSuperview()
        pageBinder = nil
        updateHandsSunk()
        focusTerminal()
    }

    /// Both hands lie over the panes, so they go down while a page or the
    /// binder is open, and come back when it closes.
    func updateHandsSunk() {
        let open = pageBinder != nil || pageReaderChrome != nil
        pageHandView.setSunk(open)
        attentionHandView.setSunk(open)
    }

    /// Opens a page in the reader, at its latest version unless asked.
    func openPage(_ page: NativeArtifactListItem, version: UInt32? = nil) {
        closePageBinder()
        guard let sourcePaneId = artifactSourcePaneId() else {
            NSSound.beep()
            return
        }
        let shown = min(page.version, max(1, version ?? page.version))
        pageReaderPage = page
        pageReaderVersion = shown
        pageInbox.markRead(page)
        let selector = shown == page.version ? page.id : "\(page.id)@v\(shown)"
        guard
            showArtifactSidebar(artifact: selector, sourcePaneId: sourcePaneId, focus: true) != nil
        else {
            NSSound.beep()
            return
        }
        focusTerminal()
    }

    /// Frames the reader's pane, adding the frame when the reader opened.
    func syncPageReaderChrome() {
        guard paneStore.runtimes[nativeArtifactSidebarPaneId] != nil else {
            removePageReaderChrome()
            return
        }
        let chrome = pageReaderChrome ?? makePageReaderChrome()
        let frames = nativePageReaderFrames(in: terminalTextView.terminalContentRect())
        chrome.frame = terminalTextView.bounds
        chrome.panel = frames.panel
        chrome.pane = frames.pane
        let selector = paneStore.artifactSelectors[nativeArtifactSidebarPaneId] ?? ""
        let id = String(selector.split(separator: "@").first ?? "")
        if pageReaderPage?.id != id {
            pageReaderPage = pageInbox.pages.first { $0.id == id }
            pageReaderVersion = pageReaderPage?.version ?? 1
            if let page = pageReaderPage {
                pageInbox.markRead(page)
            }
        }
        chrome.pageId = id
        chrome.title = pageReaderPage?.title ?? id
        chrome.version = pageReaderVersion
        chrome.latest = pageReaderPage?.version ?? pageReaderVersion
    }

    private func makePageReaderChrome() -> NativePageReaderChrome {
        let chrome = NativePageReaderChrome(frame: terminalTextView.bounds)
        chrome.onClose = { [weak self] in
            self?.closePageReader()
        }
        terminalTextView.addSubview(chrome, positioned: .above, relativeTo: nil)
        pageReaderChrome = chrome
        updateHandsSunk()
        pageKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handlePageReaderKey(event) else {
                return event
            }
            return nil
        }
        return chrome
    }

    func removePageReaderChrome() {
        pageReaderChrome?.removeFromSuperview()
        pageReaderChrome = nil
        pageReaderPage = nil
        updateHandsSunk()
        if let monitor = pageKeyMonitor {
            NSEvent.removeMonitor(monitor)
            pageKeyMonitor = nil
        }
    }

    func closePageReader() {
        if paneStore.runtimes[nativeArtifactSidebarPaneId] != nil {
            closeArtifactSidebar()
        }
        removePageReaderChrome()
    }

    /// Esc closes the reader; the arrows step through the page's versions.
    private func handlePageReaderKey(_ event: NSEvent) -> Bool {
        guard event.window === view.window, activePaneId == nativeArtifactSidebarPaneId,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else {
            return false
        }
        switch event.keyCode {
        case 53:
            closePageReader()
            return true
        case 123, 124:
            guard let page = pageReaderPage else {
                return false
            }
            let step: Int = event.keyCode == 123 ? -1 : 1
            let next = Int(pageReaderVersion) + step
            guard next >= 1, next <= Int(page.version) else {
                NSSound.beep()
                return true
            }
            openPage(page, version: UInt32(next))
            return true
        default:
            return false
        }
    }
}

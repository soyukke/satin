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
        pageInbox.persistRead = { [weak self] selectors in
            self?.markPagesRead(selectors)
        }
        pageInbox.start(root: root) { [weak self] completion in
            guard let self else { return }
            self.loadRecentArtifacts(limit: 40, completion: completion)
        }
    }

    /// Keeps pages read in the store with `satin page read`, where every
    /// client of it sees them; the store's folder changing reloads the list.
    private func markPagesRead(_ selectors: [String]) {
        let executable = controlCliPath
        let socket = controlSocketPath
        guard FileManager.default.isExecutableFile(atPath: executable), !socket.isEmpty else {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--socket", socket, "page", "read"] + selectors
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    NativeLog.runtimeError("page_read_failed")
                }
            } catch {
                NativeLog.runtimeError("page_read_failed")
            }
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
            self?.openPage(page, fromBinder: true)
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

    /// Opens a page in the reader, at its latest version unless asked. A page
    /// opened from the binder goes back to it; stepping through versions
    /// keeps where the page came from.
    func openPage(
        _ page: NativeArtifactListItem, version: UInt32? = nil, fromBinder: Bool? = nil
    ) {
        let returnsToBinder =
            fromBinder ?? (pageReaderFromBinder && pageReaderPage?.id == page.id)
        closePageBinder()
        pageReaderFromBinder = returnsToBinder
        pageReaderChrome?.returnsToBinder = returnsToBinder
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
        chrome.returnsToBinder = pageReaderFromBinder
        chrome.title = pageReaderPage?.title ?? id
        chrome.version = pageReaderVersion
        chrome.latest = pageReaderPage?.version ?? pageReaderVersion
        syncPageReaderDocument(id: id, selector: selector, pane: frames.pane, above: chrome)
    }

    /// Lays the rendered Markdown over the reader's pane. Other kinds of page
    /// keep the pane's own terminal rendering.
    private func syncPageReaderDocument(
        id: String, selector: String, pane: NSRect, above chrome: NSView
    ) {
        let version =
            selector.split(separator: "@").dropFirst().first
            .flatMap { UInt32($0.trimmingCharacters(in: CharacterSet(charactersIn: "v"))) }
            ?? pageReaderPage?.version ?? 1
        guard pageReaderPage?.kind == "markdown",
            let document = pageDocument(id: id, version: version)
        else {
            pageReaderDocument?.removeFromSuperview()
            pageReaderDocument = nil
            return
        }
        let view = pageReaderDocument ?? NativePageDocumentView(frame: pane)
        if pageReaderDocument == nil {
            terminalTextView.addSubview(view, positioned: .below, relativeTo: chrome)
            pageReaderDocument = view
        }
        view.frame = pane
        view.show(
            markdown: document.markdown, images: document.folder, key: "\(id)@\(version)")
    }

    /// The Markdown of one version of a page, and the folder its images sit in.
    func pageDocument(id: String, version: UInt32) -> (markdown: String, folder: URL)? {
        guard let root = pageStoreRoot(),
            let name = try? FileManager.default.contentsOfDirectory(atPath: root.path)
                .first(where: { $0.hasSuffix("--\(id)") })
        else {
            return nil
        }
        let page = root.appendingPathComponent(name, isDirectory: true)
        var path = String(format: "versions/v%03d/artifact.md", Int(version))
        if let data = try? Data(contentsOf: page.appendingPathComponent("metadata.json")),
            let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let versions = metadata["versions"] as? [[String: Any]],
            let entry = versions.first(where: { ($0["version"] as? Int) == Int(version) }),
            let document = entry["document"] as? String, !document.contains("..")
        {
            path = document
        }
        let file = page.appendingPathComponent(path)
        guard let markdown = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }
        return (markdown, file.deletingLastPathComponent())
    }

    private func makePageReaderChrome() -> NativePageReaderChrome {
        let chrome = NativePageReaderChrome(frame: terminalTextView.bounds)
        chrome.onClose = { [weak self] in
            self?.closePageReader()
        }
        chrome.onBack = { [weak self] in
            self?.leavePageReader()
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
        pageReaderDocument?.removeFromSuperview()
        pageReaderDocument = nil
        pageReaderPage = nil
        pageReaderFromBinder = false
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

    /// Closes the reader, back to the binder when the page came from it.
    func leavePageReader() {
        let back = pageReaderFromBinder
        closePageReader()
        if back {
            openPageBinder()
        }
    }

    /// Esc leaves the reader; the arrows step through the page's versions.
    private func handlePageReaderKey(_ event: NSEvent) -> Bool {
        guard event.window === view.window, activePaneId == nativeArtifactSidebarPaneId,
            event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else {
            return false
        }
        if let document = pageReaderDocument {
            // The document scrolls by itself: Space and the page keys by a
            // screen, the up and down arrows by a few lines.
            switch event.keyCode {
            case 49:
                document.scroll(down: !event.modifierFlags.contains(.shift))
                return true
            case 121, 116:
                document.scroll(down: event.keyCode == 121)
                return true
            case 125, 126:
                document.scroll(lines: 3, down: event.keyCode == 125)
                return true
            default:
                break
            }
        }
        switch event.keyCode {
        case 53:
            leavePageReader()
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

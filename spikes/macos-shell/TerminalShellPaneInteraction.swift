import AppKit
import Foundation

@discardableResult
func writeTerminalSelection(_ text: String?, to pasteboard: NSPasteboard) -> Bool {
    guard let text, !text.isEmpty else {
        return false
    }
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
}

extension TerminalShellViewController {
    func configureTerminalTextView() {
        terminalTextView.translatesAutoresizingMaskIntoConstraints = false
        terminalTextView.wantsLayer = true
        terminalTextView.layer?.backgroundColor = NSColor.clear.cgColor
        terminalTextView.layer?.zPosition = 1
    }

    func syncActivePane(_ snapshot: TerminalCoreSnapshot) {
        guard let paneId = activePaneId(in: snapshot) else {
            activePaneId = nil
            terminalTextView.setRendererModel(nil)
            return
        }

        if activePaneId != paneId {
            lastNvimModelScrollShift = nil
        }
        activePaneId = paneId
        _ = terminalPane(for: paneId)
        updateActiveFrame()
    }

    func activePaneId(in snapshot: TerminalCoreSnapshot) -> Int? {
        snapshot.tabs.first(where: { $0.index == snapshot.active_tab })?.active_pane
    }

    func terminalPane(for paneId: Int) -> NativePane? {
        if let pane = paneStore.runtimes[paneId] {
            return pane
        }

        let cwd =
            paneStore.workingDirectories[paneId]
            ?? pendingPaneWorkingDirectory
            ?? nativeWorkingDirectory()
        pendingPaneWorkingDirectory = nil
        let startupCommand = pendingPaneStartupCommand
        pendingPaneStartupCommand = nil
        let directStartup = pendingPaneDirectStartup
        pendingPaneDirectStartup = false
        let mode = paneStore.modes[paneId] ?? pendingPaneMode ?? defaultPaneMode
        pendingPaneMode = nil
        guard
            let pane = makePane(
                paneId: paneId,
                grid: paneGridSize(paneId),
                cwd: cwd,
                mode: mode,
                startupCommand: startupCommand,
                directStartup: directStartup
            )
        else {
            return nil
        }
        paneStore.runtimes[paneId] = pane
        installPaneWakeup(paneId: paneId, pane: pane)
        paneStore.modes[paneId] = pane.kind
        paneStore.workingDirectories[paneId] = cwd
        terminalTextView.refreshPaneChromeActionAvailability(paneId: paneId)
        (pane as? RustTerminalPane)?.setOptionAsAlt(optionAsAltEnabled)
        if pane.kind == .neovim {
            scheduleNvimDirectoryCorrection(
                paneId: paneId,
                directory: cwd
            )
        }
        return pane
    }

    func makePane(
        paneId: Int,
        grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
        cwd: String,
        mode: NativePaneMode,
        startupCommand: [String]? = nil,
        directStartup: Bool = false
    ) -> NativePane? {
        switch mode {
        case .terminal:
            return RustTerminalPane(
                grid: grid,
                cwd: cwd,
                shell: settings.shellPath,
                environment: controlEnvironment(paneId: paneId),
                startupCommand: startupCommand ?? [],
                directStartup: directStartup
            )
        case .neovim:
            let environment = ProcessInfo.processInfo.environment
            var arguments =
                environment["SATIN_NATIVE_SMOKE_CLEAN_NVIM"] == "1"
                ? ["-u", "NONE", "-n"]
                : []
            if let benchmarkInit = environment["SATIN_NATIVE_PERF_NVIM_INIT"],
                !benchmarkInit.isEmpty
            {
                arguments.append(contentsOf: [
                    "--cmd",
                    "lua dofile(vim.env.SATIN_NATIVE_PERF_NVIM_INIT)",
                ])
            }
            return RustNeovimPane(grid: grid, cwd: cwd, arguments: arguments)
        }
    }

    func prepareFinderEditorLaunch(_ launch: NativeFinderEditorLaunch) {
        pendingPaneWorkingDirectory = launch.workingDirectory
        var startupCommand = launch.startupCommand(editor: settings.finderEditorCommand)
        if settings.finderEditorCommand == "nvim",
            FileManager.default.isExecutableFile(atPath: nvimLauncherPath)
        {
            startupCommand[0] = nvimLauncherPath
        }
        pendingPaneStartupCommand = startupCommand
        pendingPaneMode = .terminal
    }

    func controlEnvironment(paneId: Int) -> [String: String] {
        guard !controlSocketPath.isEmpty else {
            return [:]
        }
        let tabId = lastSnapshot?.tabs.first(where: { $0.panes.contains(paneId) })?.id ?? 0
        var environment = [
            "SATIN_SOCKET": controlSocketPath,
            "SATIN_TAB_ID": String(tabId),
            "SATIN_PANE_ID": String(paneId),
            "NVTERM_SOCKET": controlSocketPath,
            "NVTERM_TAB_ID": String(tabId),
            "NVTERM_PANE_ID": String(paneId),
        ]
        if !controlCliPath.isEmpty {
            environment["SATIN_CLI"] = controlCliPath
            let cliDirectory = URL(fileURLWithPath: controlCliPath)
                .deletingLastPathComponent()
                .path
            let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            environment["PATH"] = "\(cliDirectory):\(inheritedPath)"
        }
        if !nvimLauncherPath.isEmpty,
            FileManager.default.isExecutableFile(atPath: nvimLauncherPath)
        {
            environment["SATIN_NVIM_LAUNCHER"] = nvimLauncherPath
        }
        if !zshIntegrationPath.isEmpty,
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: zshIntegrationPath)
                    .appendingPathComponent(".zshrc")
                    .path
            )
        {
            environment["SATIN_ZSH_INTEGRATION_DIR"] = zshIntegrationPath
        }
        if !claudeSettingsPath.isEmpty,
            FileManager.default.fileExists(atPath: claudeSettingsPath)
        {
            environment["SATIN_CLAUDE_SETTINGS"] = claudeSettingsPath
        }
        return environment
    }

    func resizeTerminalPanesToGrid(tmuxClientResizeImmediately: Bool = false) {
        pendingGeometryResizeWorkItem?.cancel()
        pendingGeometryResizeWorkItem = nil
        if let snapshot = lastSnapshot {
            syncPaneLayout(
                snapshot,
                tmuxClientResizeImmediately: tmuxClientResizeImmediately
            )
        }
        if let session = tmuxSession {
            for (nativePaneId, tmuxPaneId) in session.tmuxPaneIds {
                guard let snapshot = session.latestPanes[tmuxPaneId],
                    let runtime = projectedTmuxPane(nativePaneId)
                else {
                    continue
                }
                runtime.resize(grid: tmuxPaneGrid(snapshot))
            }
        }
        updateActiveFrame()
    }

    func scheduleTerminalPaneResize() {
        #if SATIN_SMOKE_SCENARIOS
            geometryResizeRequestCount += 1
        #endif
        guard pendingGeometryResizeWorkItem == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            pendingGeometryResizeWorkItem = nil
            #if SATIN_SMOKE_SCENARIOS
                geometryResizeApplicationCount += 1
            #endif
            resizeTerminalPanesToGrid()
        }
        pendingGeometryResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(16),
            execute: workItem
        )
    }

    #if SATIN_SMOKE_SCENARIOS
        func resetGeometryResizeDiagnostics() {
            geometryResizeRequestCount = 0
            geometryResizeApplicationCount = 0
        }

        func geometryResizeDiagnostics() -> (requests: Int, applications: Int) {
            (geometryResizeRequestCount, geometryResizeApplicationCount)
        }
    #endif

    @discardableResult
    func adjustTerminalZoom(by delta: CGFloat) -> Bool {
        guard terminalTextView.adjustZoom(by: delta) else {
            return false
        }
        resizeTerminalPanesToGrid(tmuxClientResizeImmediately: true)
        return true
    }

    @discardableResult
    func resetTerminalZoom() -> Bool {
        guard terminalTextView.resetZoom() else {
            return false
        }
        resizeTerminalPanesToGrid(tmuxClientResizeImmediately: true)
        return true
    }

    func paneGridSize(
        _ paneId: Int
    ) -> (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int) {
        guard let frame = paneStore.visibleFrames[paneId] else {
            return terminalTextView.terminalGridSize()
        }
        return terminalTextView.terminalGridSize(for: frame)
    }

    func writeToActivePane(_ data: Data) {
        guard let paneId = activePaneId,
            paneStore.artifactSelectors[paneId] == nil,
            let pane = terminalPane(for: paneId)
        else {
            return
        }
        pane.write(data)
        drainTerminalPanes()
    }

    func sendKeyToActivePane(_ event: NSEvent, released: Bool) -> Bool {
        guard let paneId = activePaneId else {
            return false
        }
        guard paneStore.artifactSelectors[paneId] == nil else {
            return true
        }
        guard let pane = terminalPane(for: paneId) as? RustTerminalPane else {
            return false
        }
        if !released, event.charactersIgnoringModifiers == "\u{1b}" {
            dismissAgentWaitingOnEscape(paneId: paneId)
        }
        let handled = pane.key(event, released: released)
        if handled {
            drainTerminalPanes()
        }
        // The terminal encoder is authoritative even when a physical key has
        // no terminal representation. Never fall back to hand-built escapes.
        return true
    }

    func writeTextToActivePane(_ text: String) {
        guard let paneId = activePaneId,
            paneStore.artifactSelectors[paneId] == nil,
            let pane = terminalPane(for: paneId)
        else {
            return
        }
        if let terminal = pane as? RustTerminalPane {
            terminal.writeText(text)
        } else {
            pane.write(Data(text.utf8))
        }
        drainTerminalPanes()
    }

    func sendMouseInputToActivePane(_ input: NativeMouseInput) -> NativeMouseHandling {
        guard let paneId = activePaneId, let pane = paneStore.runtimes[paneId] else {
            return .unhandled
        }
        let handling =
            if let terminal = pane as? RustTerminalPane {
                terminal.mouse(input) ? NativeMouseHandling.handled : .unhandled
            } else if let neovim = pane as? RustNeovimPane {
                neovim.mouse(input)
            } else {
                NativeMouseHandling.unhandled
            }
        guard handling != .unhandled else {
            return .unhandled
        }
        drainTerminalPanes()
        if handling == .messageSelection {
            if let neovim = pane as? RustNeovimPane,
                let text = neovim.takeMessageSelectionText(),
                !text.isEmpty
            {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            updateActiveFrame()
        }
        return handling
    }

    func activePaneUsesMouseTracking() -> Bool {
        guard let paneId = activePaneId, let pane = paneStore.runtimes[paneId] else {
            return false
        }
        if let terminal = pane as? RustTerminalPane {
            return terminal.isMouseTracking()
        }
        return pane is RustNeovimPane
    }

    func setTerminalFocus(_ focused: Bool) {
        guard let paneId = activePaneId,
            let terminal = paneStore.runtimes[paneId] as? RustTerminalPane
        else {
            return
        }
        terminal.focus(focused)
    }

    func clearTerminalSelection(paneId: Int) {
        guard let terminal = paneStore.runtimes[paneId] as? RustTerminalPane else {
            return
        }
        terminal.clearSelection()
        metalView.requestFrame()
    }

    func handleTerminalSelection(_ event: NativeTerminalSelectionEvent) -> Bool {
        guard let paneId = activePaneId,
            let pane = paneStore.runtimes[paneId] as? RustTerminalPane
        else {
            return false
        }
        let result = pane.selectionEvent(event)
        guard result != 0 else {
            return false
        }
        switch event {
        case .press, .drag, .autoscroll:
            updateActiveFrame()
        case .release, .cancel:
            break
        }
        return true
    }

    @discardableResult
    func copySelection() -> Bool {
        guard let paneId = activePaneId,
            let pane = paneStore.runtimes[paneId] as? RustTerminalPane
        else {
            return false
        }
        return writeTerminalSelection(pane.selectedText(), to: .general)
    }

    func openTerminalHyperlink(_ position: (row: Int, col: Int)) -> Bool {
        guard let paneId = activePaneId,
            let pane = paneStore.runtimes[paneId] as? RustTerminalPane,
            let value = pane.hyperlink(row: position.row, col: position.col),
            let url = URL(string: value)
        else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    @discardableResult
    func pasteClipboard() -> Bool {
        guard let paneId = activePaneId,
            let text = NSPasteboard.general.string(forType: .string),
            !text.isEmpty
        else {
            return false
        }
        if let pane = paneStore.runtimes[paneId] as? RustTerminalPane {
            pane.paste(text)
        } else {
            paneStore.runtimes[paneId]?.write(Data(text.utf8))
        }
        drainTerminalPanes()
        return true
    }

    @discardableResult
    func selectAllTerminalText() -> Bool {
        guard let paneId = activePaneId,
            let pane = paneStore.runtimes[paneId] as? RustTerminalPane
        else {
            return false
        }
        pane.selectAll()
        updateActiveFrame()
        return true
    }

    @discardableResult
    func findInScrollback() -> Bool {
        guard let paneId = activePaneId,
            let pane = paneStore.runtimes[paneId] as? RustTerminalPane
        else {
            return false
        }
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        input.stringValue = lastSearchQuery
        let alert = NSAlert()
        alert.messageText = "Find in Scrollback"
        alert.accessoryView = input
        alert.addButton(withTitle: "Find Next")
        alert.addButton(withTitle: "Find Previous")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
            focusTerminal()
            return true
        }
        let query = input.stringValue
        guard !query.isEmpty else {
            focusTerminal()
            return true
        }
        lastSearchQuery = query
        let found = pane.find(query, backwards: response == .alertSecondButtonReturn)
        if !found {
            NSSound.beep()
        }
        updateActiveFrame()
        focusTerminal()
        return true
    }

    func inheritedPaneWorkingDirectory(paneId requestedPaneId: Int? = nil) -> String? {
        guard let paneId = requestedPaneId ?? activePaneId else {
            return nil
        }
        return paneWorkingDirectory(paneId: paneId, logFailure: true)
    }

    func paneWorkingDirectory(paneId: Int, logFailure: Bool) -> String? {
        func unavailable(_ reason: String) -> String? {
            if logFailure {
                NativeLog.runtimeError("pane_cwd_unavailable pane=\(paneId) reason=\(reason)")
            }
            return nil
        }

        let directory: String?
        if let session = tmuxSession {
            guard let tmuxPaneId = session.tmuxPaneIds[paneId] else {
                return unavailable("tmux_mapping")
            }
            directory = session.latestPanes[tmuxPaneId]?.current_path
        } else if let terminal = paneStore.runtimes[paneId] as? RustTerminalPane {
            directory = terminal.currentWorkingDirectory()
        } else if let neovim = paneStore.runtimes[paneId] as? RustNeovimPane {
            directory = neovim.currentWorkingDirectory()
        } else {
            directory = paneStore.workingDirectories[paneId]
        }
        guard let directory, !directory.isEmpty else {
            return unavailable("missing")
        }
        guard (directory as NSString).isAbsolutePath else {
            return unavailable("not_absolute")
        }
        let standardized = URL(fileURLWithPath: directory).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return unavailable("not_directory")
        }
        return standardized
    }

}

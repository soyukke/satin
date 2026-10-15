import AppKit
import Foundation

extension TerminalShellViewController {
    @objc func showArtifacts(_ sender: NSButton) {
        togglePageBinder(sender)
    }

    func artifactSourcePaneId() -> Int? {
        if let activePaneId,
            activePaneId != nativeArtifactSidebarPaneId,
            lastSnapshot?.tabs.contains(where: { $0.panes.contains(activePaneId) }) == true
        {
            return activePaneId
        }
        return lastSnapshot.flatMap(activePaneId(in:))
    }

    func loadRecentArtifacts(
        limit: Int = 5,
        completion: @escaping ([NativeArtifactListItem]) -> Void
    ) {
        let executable = controlCliPath
        let socket = controlSocketPath
        guard FileManager.default.isExecutableFile(atPath: executable), !socket.isEmpty else {
            completion([])
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [
                "--socket", socket, "--json", "artifact", "list", "--limit", String(limit),
            ]
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let response = try JSONDecoder().decode(NativeArtifactCLIResponse.self, from: data)
                let artifacts = response.ok ? response.result?.artifacts ?? [] : []
                DispatchQueue.main.async {
                    completion(artifacts)
                }
            } catch {
                NativeLog.runtimeError("artifact_list_failed")
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }
    }

    @discardableResult
    func showArtifactSidebar(
        artifact: String,
        sourcePaneId: Int,
        focus: Bool
    ) -> Bool? {
        let cwd =
            paneStore.workingDirectories[sourcePaneId]
            ?? (paneStore.runtimes[sourcePaneId] as? TerminalPane)?.currentWorkingDirectory()
            ?? nativeWorkingDirectory()
        let sidebarFrame = artifactSidebarFrames(in: terminalTextView.terminalContentRect()).sidebar
        let grid = terminalTextView.terminalGridSize(
            for: nativePaneContentFrame(sidebarFrame)
        )
        guard
            let viewer = TerminalPane(
                grid: grid,
                cwd: cwd,
                shell: settings.shellPath,
                environment: controlEnvironment(paneId: sourcePaneId),
                startupCommand: [
                    controlCliPath,
                    "--socket",
                    controlSocketPath,
                    "artifact",
                    "view",
                    artifact,
                ],
                directStartup: true
            )
        else {
            return nil
        }

        let reused = paneStore.runtimes[nativeArtifactSidebarPaneId] != nil
        removePaneRuntime(nativeArtifactSidebarPaneId)
        paneStore.runtimes[nativeArtifactSidebarPaneId] = viewer
        paneStore.artifactSelectors[nativeArtifactSidebarPaneId] = artifact
        paneStore.workingDirectories[nativeArtifactSidebarPaneId] = cwd
        paneStore.modes[nativeArtifactSidebarPaneId] = .terminal
        viewer.setOptionAsAlt(optionAsAltEnabled)
        viewer.setThemeColors(paneThemeColors)
        installPaneWakeup(paneId: nativeArtifactSidebarPaneId, pane: viewer)
        paneStore.scrollRemainders[nativeArtifactSidebarPaneId] = 0
        lastNvimModelScrollShift = nil
        if let snapshot = lastSnapshot {
            syncPaneLayout(snapshot)
        }
        drainTerminalPanes()
        if focus {
            activePaneId = nativeArtifactSidebarPaneId
            terminalTextView.setActivePaneId(nativeArtifactSidebarPaneId)
            updateActiveFrame()
        }
        return reused
    }

    @discardableResult
    func closeArtifactSidebar() -> Bool {
        let paneId = nativeArtifactSidebarPaneId
        guard paneStore.runtimes[paneId] != nil else {
            return false
        }
        removeControlState(paneId)
        removePaneRuntime(paneId)
        removePageReaderChrome()
        paneStore.artifactSelectors.removeValue(forKey: paneId)
        paneStore.discardMetadata(for: paneId)
        if activePaneId == paneId {
            activePaneId = lastSnapshot.flatMap(activePaneId(in:))
        }
        if let snapshot = lastSnapshot {
            syncPaneLayout(snapshot)
        }
        updateActiveFrame()
        return true
    }

    /// The page reader floats over the middle of the work, which keeps its
    /// whole width.
    func artifactSidebarFrames(in rect: NSRect) -> (workspace: NSRect, sidebar: NSRect) {
        (workspace: rect, sidebar: nativePageReaderFrames(in: rect).pane)
    }

    func workspaceContentRect() -> NSRect {
        let content = terminalTextView.terminalContentRect()
        guard paneStore.runtimes[nativeArtifactSidebarPaneId] != nil else {
            return content
        }
        return artifactSidebarFrames(in: content).workspace
    }
}

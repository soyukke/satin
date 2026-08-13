import AppKit
import Foundation

extension TerminalShellViewController {
    @objc func showArtifacts(_ sender: NSButton) {
        guard let paneId = artifactSourcePaneId() else {
            NSSound.beep()
            return
        }
        showArtifactsPopover(relativeTo: sender, paneId: paneId)
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

    func showArtifactsPopover(relativeTo sourceView: NSView, paneId: Int) {
        if let popover = artifactsPopover, popover.isShown {
            popover.performClose(sourceView)
            artifactsPopover = nil
            artifactsPopoverPaneId = nil
            return
        }
        let popover = NSPopover()
        #if SATIN_SMOKE_SCENARIOS
            popover.behavior =
                smokeState.artifactPopoverResultPath == nil ? .transient : .applicationDefined
        #else
            popover.behavior = .transient
        #endif
        popover.animates = true
        let loading = NativeArtifactsPopoverViewController(artifacts: [])
        popover.contentViewController = loading
        popover.contentSize = loading.view.frame.size
        artifactsPopover = popover
        artifactsPopoverPaneId = paneId
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
        loadRecentArtifacts { [weak self, weak popover] artifacts in
            guard let self, let popover, self.artifactsPopover === popover, popover.isShown else {
                return
            }
            let content = NativeArtifactsPopoverViewController(artifacts: artifacts)
            content.onSelect = { [weak self] artifact in
                self?.openArtifactFromPopover(artifact)
            }
            popover.contentViewController = content
            popover.contentSize = content.view.frame.size
            #if SATIN_SMOKE_SCENARIOS
                if let resultPath = self.smokeState.artifactPopoverResultPath {
                    self.smokeState.artifactPopoverResultPath = nil
                    DispatchQueue.main.async {
                        let target =
                            ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_ARTIFACT"]
                            ?? ""
                        let targetAvailable = artifacts.contains { $0.id == target }
                        let status = targetAvailable ? "ok" : "failed"
                        self.writeArtifactPopoverSmokeResult(
                            resultPath,
                            result: "\(status) artifact-popover items=\(artifacts.count)\n"
                        )
                        if targetAvailable {
                            self.waitForArtifactPopoverSmokeOpen(
                                content,
                                artifact: target,
                                attempts: 300
                            )
                        }
                    }
                }
            #endif
        }
    }

    func loadRecentArtifacts(
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
                "--socket", socket, "--json", "artifact", "list", "--limit", "5",
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

    func openArtifactFromPopover(_ artifact: String) {
        let paneId = artifactsPopoverPaneId
        artifactsPopover?.performClose(nil)
        artifactsPopover = nil
        artifactsPopoverPaneId = nil
        guard let paneId,
            lastSnapshot?.tabs.contains(where: { $0.panes.contains(paneId) }) == true,
            validControlArtifactSelector(artifact),
            controlArtifactExists(artifact),
            FileManager.default.isExecutableFile(atPath: controlCliPath),
            showArtifactSidebar(artifact: artifact, sourcePaneId: paneId, focus: true) != nil
        else {
            NSSound.beep()
            return
        }
        focusTerminal()
    }

    @discardableResult
    func showArtifactSidebar(
        artifact: String,
        sourcePaneId: Int,
        focus: Bool
    ) -> Bool? {
        let cwd =
            paneStore.workingDirectories[sourcePaneId]
            ?? (paneStore.runtimes[sourcePaneId] as? RustTerminalPane)?.currentWorkingDirectory()
            ?? nativeWorkingDirectory()
        let sidebarFrame = artifactSidebarFrames(in: terminalTextView.terminalContentRect()).sidebar
        let grid = terminalTextView.terminalGridSize(
            for: nativePaneContentFrame(sidebarFrame),
            paneId: nativeArtifactSidebarPaneId
        )
        guard
            let viewer = RustTerminalPane(
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
        paneStore.artifactSelectors.removeValue(forKey: paneId)
        paneStore.discardMetadata(for: paneId)
        terminalTextView.discardPaneZoom(paneId)
        if activePaneId == paneId {
            activePaneId = lastSnapshot.flatMap(activePaneId(in:))
        }
        if let snapshot = lastSnapshot {
            syncPaneLayout(snapshot)
        }
        updateActiveFrame()
        return true
    }

    func artifactSidebarFrames(in rect: NSRect) -> (workspace: NSRect, sidebar: NSRect) {
        let maximumSidebarWidth = min(520, rect.width * 0.5)
        let sidebarWidth = min(max(240, rect.width * 0.38), maximumSidebarWidth)
        let workspaceWidth = max(1, rect.width - sidebarWidth)
        return (
            workspace: NSRect(
                x: rect.minX,
                y: rect.minY,
                width: workspaceWidth,
                height: rect.height
            ),
            sidebar: NSRect(
                x: rect.minX + workspaceWidth,
                y: rect.minY,
                width: max(1, rect.width - workspaceWidth),
                height: rect.height
            )
        )
    }

    func workspaceContentRect() -> NSRect {
        let content = terminalTextView.terminalContentRect()
        guard paneStore.runtimes[nativeArtifactSidebarPaneId] != nil else {
            return content
        }
        return artifactSidebarFrames(in: content).workspace
    }
}

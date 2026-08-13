import AppKit
import Foundation

extension TerminalShellViewController {
    func restoreSessionIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        let smokeScenario = environment["SATIN_NATIVE_SMOKE_SCENARIO"]
        guard smokeScenario == nil || smokeScenario == "tmux-restart-restore",
            preferredBool(NativePreferenceKey.sessionRestore, defaultValue: true),
            let data = UserDefaults.standard.data(forKey: NativePreferenceKey.sessionState)
        else {
            return
        }
        if let schemaVersion = sessionSchemaVersion(in: data),
            schemaVersion > currentSessionSchemaVersion
        {
            NativeLog.sessionWarning("session_from_newer_version_preserved")
            return
        }
        guard let state = decodeSessionState(data), !state.tabs.isEmpty else {
            NativeLog.sessionWarning("session_decode_failed state_removed=true")
            UserDefaults.standard.removeObject(forKey: NativePreferenceKey.sessionState)
            return
        }
        pendingTmuxReattach = state.tmuxAttachment.flatMap(validatedTmuxAttachment)
        consumePersistedTmuxAttachment(state)
        for (index, saved) in state.tabs.enumerated() {
            if index > 0 {
                core.newTab()
            }
            guard let snapshot = core.snapshot(),
                let tab = snapshot.tabs.first(where: { $0.index == index })
            else {
                continue
            }
            _ = core.selectTab(index)
            core.renameTab(index, title: saved.title)
            core.setTheme(saved.theme, tab: index)
            if let activePane = restoreSessionPane(saved.layout, paneId: tab.active_pane) {
                _ = core.selectPane(activePane)
            }
        }
        _ = core.selectTab(min(max(state.activeTab, 0), state.tabs.count - 1))
    }

    func decodeSessionState(_ data: Data) -> NativeSessionState? {
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(NativeSessionState.self, from: data) {
            if state.schemaVersion == currentSessionSchemaVersion {
                return state
            }
            if state.schemaVersion == 2 || state.schemaVersion == 3 {
                return NativeSessionState(
                    schemaVersion: currentSessionSchemaVersion,
                    activeTab: state.activeTab,
                    tabs: state.tabs,
                    tmuxAttachment: state.schemaVersion == 3 ? state.tmuxAttachment : nil
                )
            }
        }
        guard let legacy = try? decoder.decode(LegacyNativeSessionState.self, from: data) else {
            return nil
        }
        return NativeSessionState(
            schemaVersion: currentSessionSchemaVersion,
            activeTab: legacy.activeTab,
            tabs: legacy.tabs.map { tab in
                NativeSessionTab(
                    title: tab.title,
                    theme: tab.theme,
                    layout: NativeSessionPane(
                        kind: "leaf",
                        paneMode: NativePaneMode.terminal.sessionValue,
                        cwd: tab.cwd,
                        active: true
                    )
                )
            }
        )
    }

    func consumePersistedTmuxAttachment(_ state: NativeSessionState) {
        guard state.tmuxAttachment != nil else {
            return
        }
        let consumed = sessionStateWithoutTmuxAttachment(state)
        guard let data = try? JSONEncoder().encode(consumed) else {
            NativeLog.sessionWarning("tmux_reattach_consume_encode_failed")
            return
        }
        UserDefaults.standard.set(data, forKey: NativePreferenceKey.sessionState)
    }

    func sessionStateWithoutTmuxAttachment(
        _ state: NativeSessionState
    ) -> NativeSessionState {
        NativeSessionState(
            schemaVersion: currentSessionSchemaVersion,
            activeTab: state.activeTab,
            tabs: state.tabs
        )
    }

    func schedulePendingTmuxReattach() {
        guard let attachment = pendingTmuxReattach,
            let paneId = activePaneId,
            let gateway = paneStore.runtimes[paneId] as? RustTerminalPane
        else {
            return
        }
        pendingTmuxReattach = nil
        let persistedPath = attachment.executablePath ?? ""
        let configuredPath =
            FileManager.default.isExecutableFile(atPath: persistedPath)
            ? persistedPath
            : settings.tmuxExecutablePath
        NativeTmuxExecutableResolver.shared.resolve(
            configuredPath: configuredPath,
            shellPath: settings.shellPath
        ) { [weak self, weak gateway] resolution in
            guard let self, let gateway, self.tmuxSession == nil, !gateway.isExited() else {
                return
            }
            switch resolution {
            case .available(let executable):
                self.startTmuxReattach(
                    attachment,
                    executable: executable,
                    gateway: gateway
                )
            case .unavailable(let message):
                NativeLog.sessionWarning("tmux_reattach_resolve_failed message=\(message)")
                gateway.write(Data("Satin tmux reattach skipped: \(message)\r\n".utf8))
                self.drainTerminalPanes()
            }
        }
    }

    func startTmuxReattach(
        _ attachment: NativeTmuxAttachment,
        executable: NativeTmuxExecutable,
        gateway: RustTerminalPane
    ) {
        pendingTmuxExecutable = executable
        let command =
            "\(shellQuote(executable.path)) -S \(shellQuote(attachment.socketPath)) "
            + "-CC attach-session -t \(shellQuote(attachment.sessionName))"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak gateway] in
            guard let self, let gateway, self.tmuxSession == nil, !gateway.isExited() else {
                return
            }
            gateway.write(Data("\(command)\r".utf8))
            self.drainTerminalPanes()
            NativeLog.lifecycleInfo(
                "tmux_reattach_started session=\(attachment.sessionName)"
            )
        }
    }

    func sessionSchemaVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["schemaVersion"] as? Int
    }

    func restoreSessionPane(_ saved: NativeSessionPane, paneId: Int) -> Int? {
        if saved.kind == "leaf" {
            paneStore.workingDirectories[paneId] =
                saved.cwd.isEmpty
                ? nativeWorkingDirectory()
                : saved.cwd
            paneStore.modes[paneId] = NativePaneMode(sessionValue: saved.paneMode)
            return saved.active ? paneId : nil
        }
        guard saved.kind == "split",
            let first = saved.first,
            let second = saved.second,
            core.selectPane(paneId)
        else {
            return nil
        }
        let axis = saved.axis == "horizontal" ? ffiSplitHorizontal : ffiSplitVertical
        guard let secondPaneId = core.splitActive(axis: axis) else {
            return nil
        }
        let firstActivePane = restoreSessionPane(first, paneId: paneId)
        let secondActivePane = restoreSessionPane(second, paneId: secondPaneId)
        if let ratio = saved.ratio {
            _ = core.resizeSplit(
                firstPaneId: paneId,
                secondPaneId: secondPaneId,
                ratio: ratio
            )
        }
        return firstActivePane ?? secondActivePane
    }

    func switchTerminalPaneToNeovim(
        paneId: Int,
        cwd requestedDirectory: String? = nil,
        executable: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:],
        completion: NativeControlReply? = nil
    ) -> Bool {
        guard let terminal = paneStore.runtimes[paneId] as? RustTerminalPane,
            paneStore.suspendedSessions[paneId] == nil,
            paneStore.artifactSelectors[paneId] == nil
        else {
            return false
        }
        let cwd =
            requestedDirectory
            ?? terminal.currentWorkingDirectory()
            ?? nativeWorkingDirectory()
        guard
            let pane = RustNeovimPane(
                grid: paneGridSize(paneId),
                cwd: cwd,
                executable: executable,
                arguments: arguments,
                environment: environment
            )
        else {
            return false
        }
        paneStore.wakeupSources.removeValue(forKey: paneId)?.cancel()
        metalView.forgetRuntime(terminal.renderHandle())
        paneStore.runtimes.removeValue(forKey: paneId)
        paneStore.suspendedSessions[paneId] = NativeSuspendedTerminalSession(
            pane: terminal,
            completion: completion
        )
        installSuspendedPaneWakeup(paneId: paneId, pane: terminal)
        paneStore.runtimes[paneId] = pane
        installPaneWakeup(paneId: paneId, pane: pane)
        paneStore.workingDirectories[paneId] = cwd
        paneStore.modes[paneId] = .neovim
        paneStore.scrollRemainders[paneId] = 0
        lastNvimModelScrollShift = nil
        scheduleNvimDirectoryCorrection(paneId: paneId, directory: cwd)
        drainTerminalPanes()
        updateActiveFrame()
        return true
    }

    func scrollActivePane(deltaRows: CGFloat) {
        guard let paneId = activePaneId,
            let pane = terminalPane(for: paneId) as? RustTerminalPane
        else {
            return
        }

        let requestedRows = wholeScrollRows(deltaRows, paneId: paneId)
        guard requestedRows != 0 else {
            return
        }

        let movedRows = pane.scroll(rows: requestedRows)
        guard movedRows != 0 else {
            return
        }
        updateActiveFrame()
    }

    func wholeScrollRows(_ deltaRows: CGFloat, paneId: Int) -> Int {
        let accumulated = (paneStore.scrollRemainders[paneId] ?? 0) + deltaRows
        let wholeRows = Int(accumulated.rounded(.towardZero))
        paneStore.scrollRemainders[paneId] = accumulated - CGFloat(wholeRows)
        return wholeRows
    }

    func activePaneMode() -> NativePaneMode {
        guard let paneId = activePaneId,
            let pane = paneStore.runtimes[paneId]
        else {
            return defaultPaneMode
        }
        return pane.kind
    }

    func nativeWorkingDirectory() -> String {
        let configured = settings.startupDirectory
        var isDirectory: ObjCBool = false
        if !configured.isEmpty,
            FileManager.default.fileExists(atPath: configured, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return configured
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        if FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return home
        }
        return FileManager.default.currentDirectoryPath
    }

    func neovimChangeDirectoryCommand(_ directory: String) -> String {
        "execute 'cd' fnameescape('\(vimSingleQuoted(directory))')"
    }

    func neovimEditCommand(_ file: String) -> String {
        "execute 'edit!' fnameescape('\(vimSingleQuoted(file))')"
    }

    func neovimEditTopCommand(_ file: String) -> String {
        "\(neovimEditCommand(file)) | normal! gg"
    }

    func vimSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

}

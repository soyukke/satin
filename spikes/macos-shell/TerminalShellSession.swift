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

    func consumePersistedTmuxAttachment() {
        guard let persisted = UserDefaults.standard.data(forKey: NativePreferenceKey.sessionState),
            let state = decodeSessionState(persisted)
        else {
            return
        }
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
            !tmuxReattachInFlight,
            !tmuxReattachDeferred,
            let paneId = activePaneId,
            let gateway = tmuxConnectionGateway(paneId: paneId)
        else {
            return
        }
        let sequence = beginTmuxConnectionAttempt(clearPendingReattach: false)
        tmuxReattachInFlight = true
        tmuxReattachAttempt = 0
        let persistedPath = attachment.executablePath ?? ""
        let configuredPath =
            FileManager.default.isExecutableFile(atPath: persistedPath)
            ? persistedPath
            : settings.tmuxExecutablePath
        NativeTmuxExecutableResolver.shared.resolve(
            configuredPath: configuredPath,
            shellPath: settings.shellPath
        ) { [weak self, weak gateway] resolution in
            guard let self, let gateway,
                self.tmuxAdmissionSequence == sequence,
                self.pendingTmuxReattach == attachment,
                self.tmuxSession == nil,
                !gateway.isExited()
            else {
                return
            }
            switch resolution {
            case .available(let executable):
                self.discoverPendingTmuxReattach(
                    attachment,
                    executable: executable,
                    gateway: gateway,
                    sequence: sequence
                )
            case .unavailable(let message):
                self.deferPendingTmuxReattach(
                    attachment,
                    message: message,
                    sequence: sequence
                )
            }
        }
    }

    func discoverPendingTmuxReattach(
        _ attachment: NativeTmuxAttachment,
        executable: NativeTmuxExecutable,
        gateway: RustTerminalPane,
        sequence: Int
    ) {
        NativeTmuxSessionDiscovery.discover(
            executable: executable,
            socketPath: attachment.socketPath
        ) { [weak self, weak gateway] result in
            guard let self, let gateway,
                self.tmuxAdmissionSequence == sequence,
                self.pendingTmuxReattach == attachment,
                self.tmuxSession == nil,
                !gateway.isExited()
            else {
                return
            }
            switch result {
            case .sessions(let sessions):
                guard
                    let descriptor = sessions.first(where: {
                        $0.name == attachment.sessionName
                            && $0.socketPath == attachment.socketPath
                    })
                else {
                    self.failPendingTmuxReattach(
                        attachment,
                        message: "can't find session: \(attachment.sessionName)",
                        sequence: sequence
                    )
                    return
                }
                self.requestPendingTmuxAdmission(
                    attachment,
                    executable: executable,
                    descriptor: descriptor,
                    gateway: gateway,
                    sequence: sequence
                )
            case .unavailable(let message):
                self.deferPendingTmuxReattach(
                    attachment,
                    message: message,
                    sequence: sequence
                )
            }
        }
    }

    func requestPendingTmuxAdmission(
        _ attachment: NativeTmuxAttachment,
        executable: NativeTmuxExecutable,
        descriptor: NativeTmuxSessionDescriptor,
        gateway: RustTerminalPane,
        sequence: Int
    ) {
        NativeTmuxProjectionAdmission.request(
            executable: executable,
            descriptor: descriptor
        ) { [weak self, weak gateway] result in
            guard let self, let gateway,
                self.tmuxAdmissionSequence == sequence,
                self.pendingTmuxReattach == attachment,
                self.tmuxSession == nil,
                !gateway.isExited()
            else {
                return
            }
            switch result {
            case .admitted(let lease):
                self.stageTmuxLease(lease)
                self.startTmuxReattach(
                    attachment,
                    executable: executable,
                    gateway: gateway,
                    sequence: sequence
                )
            case .busy where self.tmuxReattachAttempt < 10:
                self.tmuxReattachAttempt += 1
                let workItem = DispatchWorkItem { [weak self, weak gateway] in
                    guard let self, let gateway,
                        self.tmuxAdmissionSequence == sequence
                    else {
                        return
                    }
                    self.pendingTmuxConnectionWorkItem = nil
                    self.requestPendingTmuxAdmission(
                        attachment,
                        executable: executable,
                        descriptor: descriptor,
                        gateway: gateway,
                        sequence: sequence
                    )
                }
                self.pendingTmuxConnectionWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
            case .busy:
                self.deferPendingTmuxReattach(
                    attachment,
                    message: "This tmux session is already open in another Satin window. "
                        + "Close or detach it there, then select it again; automatic restore "
                        + "will also retry on the next launch.",
                    sequence: sequence
                )
            case .unavailable(let message):
                self.deferPendingTmuxReattach(
                    attachment,
                    message: message,
                    sequence: sequence
                )
            }
        }
    }

    func deferPendingTmuxReattach(
        _ attachment: NativeTmuxAttachment,
        message: String,
        sequence: Int
    ) {
        guard tmuxAdmissionSequence == sequence,
            pendingTmuxReattach == attachment
        else {
            return
        }
        invalidateTmuxConnectionCallbacks()
        tmuxReattachInFlight = false
        tmuxReattachDeferred = true
        NativeLog.sessionWarning("tmux_reattach_deferred message=\(message)")
        saveSessionState()
        presentTmuxSessionError(message)
    }

    func failPendingTmuxReattach(
        _ attachment: NativeTmuxAttachment,
        message: String,
        sequence: Int
    ) {
        guard tmuxAdmissionSequence == sequence,
            pendingTmuxReattach == attachment
        else {
            return
        }
        invalidateTmuxConnectionCallbacks()
        pendingTmuxReattach = nil
        tmuxReattachInFlight = false
        tmuxReattachDeferred = false
        consumePersistedTmuxAttachment()
        NativeLog.sessionWarning("tmux_reattach_failed message=\(message)")
        saveSessionState()
        presentTmuxSessionError(message)
    }

    func startTmuxReattach(
        _ attachment: NativeTmuxAttachment,
        executable: NativeTmuxExecutable,
        gateway: RustTerminalPane,
        sequence: Int
    ) {
        guard tmuxAdmissionSequence == sequence,
            pendingTmuxReattach == attachment
        else {
            return
        }
        pendingTmuxExecutable = executable
        let command =
            "\(shellQuote(executable.path)) -u -S \(shellQuote(attachment.socketPath)) "
            + "-CC attach-session -t \(shellQuote(attachment.sessionName))"
        let workItem = DispatchWorkItem { [weak self, weak gateway] in
            guard let self, let gateway,
                self.tmuxAdmissionSequence == sequence
            else {
                return
            }
            self.pendingTmuxConnectionWorkItem = nil
            guard self.pendingTmuxReattach == attachment,
                self.tmuxSession == nil,
                !gateway.isExited()
            else {
                return
            }
            self.runTmuxCommandInActiveShell(command, sequence: sequence)
            NativeLog.lifecycleInfo(
                "tmux_reattach_started session=\(attachment.sessionName)"
            )
        }
        pendingTmuxConnectionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
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
        guard
            let cwd = nativeNeovimWorkingDirectory(
                paneId: paneId,
                terminal: terminal,
                requestedDirectory: requestedDirectory
            )
        else {
            return false
        }
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

    func nativeNeovimWorkingDirectory(
        paneId: Int,
        terminal: RustTerminalPane,
        requestedDirectory: String?
    ) -> String? {
        let runtimeDirectory = terminal.currentWorkingDirectory()
        let projectedDirectory = paneStore.workingDirectories[paneId]
        let directory =
            requestedDirectory
            ?? (terminal is RustTmuxPane
                ? projectedDirectory ?? runtimeDirectory : runtimeDirectory)
            ?? projectedDirectory
            ?? nativeWorkingDirectory()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            NativeLog.runtimeError(
                "neovim_launch_cwd_unavailable pane=\(paneId) cwd=\(directory)"
            )
            return nil
        }
        paneStore.workingDirectories[paneId] = directory
        return directory
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

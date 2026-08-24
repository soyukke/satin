import AppKit
import Foundation

extension TerminalShellViewController {
    func installPaneWakeup(paneId: Int, pane: NativePane) {
        paneStore.wakeupSources.removeValue(forKey: paneId)?.cancel()
        let descriptor = pane.wakeupFD()
        guard descriptor >= 0 else {
            return
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.drainTerminalPanes()
        }
        paneStore.wakeupSources[paneId] = source
        source.resume()
    }

    func installSuspendedPaneWakeup(paneId: Int, pane: RustTerminalPane) {
        paneStore.suspendedWakeupSources.removeValue(forKey: paneId)?.cancel()
        let descriptor = pane.wakeupFD()
        guard descriptor >= 0 else {
            return
        }
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.drainSuspendedTerminalPane(paneId)
        }
        paneStore.suspendedWakeupSources[paneId] = source
        source.resume()
    }

    func drainSuspendedTerminalPane(_ paneId: Int) {
        guard let pane = paneStore.suspendedSessions[paneId]?.pane else {
            paneStore.suspendedWakeupSources.removeValue(forKey: paneId)?.cancel()
            return
        }
        _ = pane.drain()
        while let event = pane.takeTmuxEvent() {
            handleTmuxEvent(event, gatewayPaneId: paneId, gateway: pane)
        }
        if tmuxSession?.gatewayPaneId != paneId {
            updateTerminalMetadata(pane, paneId: paneId)
        }
    }

    func projectedTmuxPane(_ paneId: Int) -> RustTmuxPane? {
        paneStore.runtimes[paneId] as? RustTmuxPane
    }

    func removePaneRuntime(_ paneId: Int) {
        paneStore.wakeupSources.removeValue(forKey: paneId)?.cancel()
        metalView.forgetRuntime(paneStore.runtimes[paneId]?.renderHandle())
        paneStore.runtimes.removeValue(forKey: paneId)
    }

    func discardSuspendedTerminalSession(_ paneId: Int) {
        paneStore.suspendedWakeupSources.removeValue(forKey: paneId)?.cancel()
        let suspended = paneStore.suspendedSessions.removeValue(forKey: paneId)
        suspended?.completion?(
            controlFailure("pane_closed", "The pane was closed while Neovim was active.")
        )
    }

    func drainTerminalPanes() {
        let performanceRecorder = NativePerformanceRecorder.shared
        let measurePerformance = performanceRecorder.isEnabled
        let drainStartedAt = measurePerformance ? CACurrentMediaTime() : 0
        defer {
            if measurePerformance {
                performanceRecorder.recordMainDrain(
                    milliseconds: (CACurrentMediaTime() - drainStartedAt) * 1_000
                )
            }
        }
        var activePaneChanged = false
        var visiblePaneChanged = false
        var exitedNvimPanes: [Int] = []
        var artifactSidebarExited = false
        var exitedTerminalPanes: [Int] = []
        var tmuxEvents: [(paneId: Int, pane: RustTerminalPane, event: TmuxControlEvent)] = []
        for (paneId, pane) in paneStore.runtimes {
            let paneDrainStartedAt = measurePerformance ? CACurrentMediaTime() : 0
            let changed = pane.drain()
            if measurePerformance, pane.kind == .neovim {
                performanceRecorder.recordNvimDrain(
                    milliseconds: (CACurrentMediaTime() - paneDrainStartedAt) * 1_000,
                    changed: changed
                )
            }
            activePaneChanged = activePaneChanged || (changed && paneId == activePaneId)
            visiblePaneChanged =
                visiblePaneChanged
                || (changed && paneStore.visibleFrames[paneId] != nil)
            if let terminal = pane as? RustTerminalPane {
                while let event = terminal.takeTmuxEvent() {
                    tmuxEvents.append((paneId, terminal, event))
                }
                if terminal is RustTmuxPane {
                    updateTerminalBells(terminal)
                } else if tmuxSession?.gatewayPaneId != paneId {
                    updateTerminalMetadata(terminal, paneId: paneId)
                }
            }
            if paneId == nativeArtifactSidebarPaneId, pane.isExited() {
                artifactSidebarExited = true
            } else if pane.kind == .neovim && pane.isExited() {
                exitedNvimPanes.append(paneId)
            } else if pane.kind == .terminal && pane.isExited() {
                exitedTerminalPanes.append(paneId)
            }
        }
        for item in tmuxEvents {
            handleTmuxEvent(item.event, gatewayPaneId: item.paneId, gateway: item.pane)
        }
        for paneId in exitedNvimPanes {
            replaceExitedNeovimPane(paneId)
            activePaneChanged = activePaneChanged || paneId == activePaneId
        }
        if artifactSidebarExited {
            activePaneChanged = closeArtifactSidebar() || activePaneChanged
        }
        if closeExitedTerminalPanes(exitedTerminalPanes) {
            return
        }
        if activePaneChanged {
            updateActiveFrame()
        } else if visiblePaneChanged {
            metalView.requestFrame()
        }
    }

    func handleTmuxEvent(
        _ event: TmuxControlEvent,
        gatewayPaneId: Int,
        gateway: RustTerminalPane
    ) {
        switch event.kind {
        case "entered":
            beginTmuxSession(gatewayPaneId: gatewayPaneId, gateway: gateway)
        case "pane_hydration":
            guard let paneId = event.pane_id, let bytes = event.data else {
                return
            }
            hydrateTmuxPane(paneId: paneId, data: Data(bytes))
        case "pane_output":
            guard let paneId = event.pane_id, let bytes = event.data else {
                return
            }
            feedTmuxOutput(paneId: paneId, data: Data(bytes))
        case "pane_scroll_metadata":
            guard let paneId = event.pane_id, let rows = event.rows else {
                return
            }
            recordTmuxScrollMetadata(
                paneId: paneId,
                metadata: NativeTmuxScrollMetadata(
                    rows: rows,
                    regionTop: event.region_top,
                    regionBottom: event.region_bottom,
                    regionLeft: event.region_left,
                    regionRight: event.region_right
                )
            )
        case "sessions":
            guard
                let controller = sessionPopover?.contentViewController
                    as? TmuxSessionPopoverController
            else {
                return
            }
            let descriptors = (event.sessions ?? []).map {
                NativeTmuxSessionDescriptor(
                    sessionID: $0.session_id,
                    name: $0.name,
                    windowCount: $0.window_count,
                    socketPath: $0.socket_path,
                    serverPID: $0.server_pid
                )
            }
            controller.update(
                sessions: currentTmuxSessionAdded(to: descriptors),
                status: event.session_error,
                canCreate: event.session_error == nil,
                isError: event.session_error != nil
            )
        case "snapshot":
            guard let snapshot = event.snapshot else {
                return
            }
            applyTmuxSnapshot(snapshot, gatewayPaneId: gatewayPaneId, gateway: gateway)
        case "protocol_error":
            NativeLog.runtimeError("tmux_protocol_error message=\(event.message ?? "unknown")")
            endTmuxSession(gatewayPaneId: gatewayPaneId)
        case "command_error":
            NativeLog.runtimeError("tmux_command_error message=\(event.message ?? "unknown")")
        case "exited":
            endTmuxSession(gatewayPaneId: gatewayPaneId)
        default:
            NativeLog.runtimeError("tmux_unknown_event kind=\(event.kind)")
        }
    }

    func beginTmuxSession(gatewayPaneId: Int, gateway: RustTerminalPane) {
        guard tmuxSession == nil, let workspace = core.snapshot() else {
            return
        }
        let session = NativeTmuxSession(
            gatewayPaneId: gatewayPaneId,
            gateway: gateway,
            savedWorkspace: workspace
        )
        session.executablePath = pendingTmuxExecutable?.path ?? ""
        session.lease = takePendingTmuxLease()
        invalidateTmuxConnectionCallbacks()
        if let pendingTmuxExecutable {
            resolvedTmuxExecutable = pendingTmuxExecutable
        }
        self.pendingTmuxExecutable = nil
        if pendingTmuxReattach != nil {
            pendingTmuxReattach = nil
            consumePersistedTmuxAttachment()
        }
        tmuxReattachInFlight = false
        tmuxReattachDeferred = false
        tmuxSession = session
        NativeLog.lifecycleInfo("tmux_control_entered gateway_pane=\(gatewayPaneId)")
    }

    func feedTmuxOutput(paneId: UInt32, data: Data) {
        guard let session = tmuxSession else {
            return
        }
        if let nativePaneId = session.nativePaneIds[paneId],
            let pane = projectedTmuxPane(nativePaneId)
        {
            pane.feed(data)
            if nativePaneId == activePaneId {
                updateActiveFrame()
            }
            return
        }
        session.bufferedOutput[paneId, default: Data()].append(data)
    }

    func recordTmuxScrollMetadata(
        paneId: UInt32,
        metadata: NativeTmuxScrollMetadata
    ) {
        guard let session = tmuxSession else {
            return
        }
        if let nativePaneId = session.nativePaneIds[paneId],
            let pane = projectedTmuxPane(nativePaneId)
        {
            _ = pane.recordScrollMetadata(
                rows: metadata.rows,
                regionTop: metadata.regionTop,
                regionBottom: metadata.regionBottom,
                regionLeft: metadata.regionLeft,
                regionRight: metadata.regionRight
            )
            return
        }
        session.bufferedScrollMetadata[paneId, default: []].append(metadata)
    }

    func hydrateTmuxPane(paneId: UInt32, data: Data) {
        guard let session = tmuxSession else {
            return
        }
        if let nativePaneId = session.nativePaneIds[paneId],
            let pane = projectedTmuxPane(nativePaneId)
        {
            _ = pane.prepareHydration()
            pane.feed(data)
            if let latest = session.latestPanes[paneId] {
                pane.syncCursor(latest)
            }
            if nativePaneId == activePaneId {
                updateActiveFrame()
            }
            return
        }
        session.bufferedHydration[paneId] = data
    }

    func applyTmuxSnapshot(
        _ snapshot: TmuxSnapshot,
        gatewayPaneId: Int,
        gateway: RustTerminalPane
    ) {
        if tmuxSession == nil {
            beginTmuxSession(gatewayPaneId: gatewayPaneId, gateway: gateway)
        }
        guard let session = tmuxSession, session.gatewayPaneId == gatewayPaneId else {
            return
        }
        guard admitTmuxSnapshot(snapshot, session: session) else {
            _ = session.gateway.tmuxCommand("detach-client")
            return
        }
        session.sessionID = snapshot.session_id
        session.sessionName = snapshot.session_name
        session.socketPath = snapshot.socket_path
        if !snapshot.socket_path.isEmpty {
            lastTmuxSocketPath = snapshot.socket_path
        }
        session.serverPid = snapshot.server_pid
        if isLocalTmuxEndpoint(
            socketPath: snapshot.socket_path,
            serverPid: snapshot.server_pid
        ),
            let executablePath = NativeTmuxExecutableResolver.executablePath(
                forProcessID: snapshot.server_pid
            )
        {
            session.executablePath = executablePath
        }
        session.activeWindowZoomed =
            snapshot.windows
            .first(where: { $0.window_id == snapshot.active_window_id })?.zoomed ?? false
        let paneSnapshots = snapshot.windows.flatMap(\.panes)
        session.latestPanes = Dictionary(
            uniqueKeysWithValues: paneSnapshots.map { ($0.pane_id, $0) }
        )
        let nextNativePaneIds = Dictionary(
            uniqueKeysWithValues: paneSnapshots.map {
                ($0.pane_id, session.nativePaneId($0.pane_id))
            }
        )
        let stalePaneIds = Set(session.nativePaneIds.values).subtracting(nextNativePaneIds.values)
        for paneId in stalePaneIds {
            removeControlState(paneId)
            removePaneRuntime(paneId)
            paneStore.artifactSelectors.removeValue(forKey: paneId)
            paneStore.discardMetadata(for: paneId)
        }
        for pane in paneSnapshots {
            let nativePaneId = nextNativePaneIds[pane.pane_id] ?? session.nativePaneId(pane.pane_id)
            updateTmuxPaneMetadata(pane, nativePaneId: nativePaneId)
            let grid = tmuxPaneGrid(pane)
            if let runtime = projectedTmuxPane(nativePaneId) {
                runtime.setCurrentCommand(pane.current_command)
                runtime.resize(grid: grid)
                runtime.syncCursor(pane)
                continue
            }
            guard
                let runtime = RustTmuxPane(
                    grid: grid,
                    paneId: pane.pane_id,
                    gateway: session.gateway
                )
            else {
                NativeLog.runtimeError("tmux_pane_create_failed pane=%\(pane.pane_id)")
                return
            }
            paneStore.runtimes[nativePaneId] = runtime
            paneStore.modes[nativePaneId] = .terminal
            runtime.setOptionAsAlt(optionAsAltEnabled)
            runtime.setCurrentCommand(pane.current_command)
            if let metadata = session.bufferedScrollMetadata.removeValue(forKey: pane.pane_id) {
                for update in metadata {
                    runtime.recordScrollMetadata(
                        rows: update.rows,
                        regionTop: update.regionTop,
                        regionBottom: update.regionBottom,
                        regionLeft: update.regionLeft,
                        regionRight: update.regionRight
                    )
                }
            }
            if let hydration = session.bufferedHydration.removeValue(forKey: pane.pane_id) {
                runtime.prepareHydration()
                runtime.feed(hydration)
            }
            if let buffered = session.bufferedOutput.removeValue(forKey: pane.pane_id) {
                runtime.feed(buffered)
            }
            runtime.syncCursor(pane)
        }
        session.nativePaneIds = nextNativePaneIds
        session.tmuxPaneIds = Dictionary(
            uniqueKeysWithValues: nextNativePaneIds.map { ($0.value, $0.key) }
        )
        session.nativeTabIds = Dictionary(
            uniqueKeysWithValues: snapshot.windows.map {
                ($0.window_id, session.nativeTabId($0.window_id))
            }
        )
        session.tmuxWindowIds = Dictionary(
            uniqueKeysWithValues: session.nativeTabIds.map { ($0.value, $0.key) }
        )
        guard core.applyWorkspace(tmuxWorkspace(snapshot, session: session)) else {
            NativeLog.runtimeError("tmux_workspace_apply_failed")
            return
        }
        syncFromCore()
        saveSessionState()
    }

    func stageTmuxLease(_ lease: NativeTmuxSessionLease) {
        pendingTmuxLeaseTimeoutWorkItem?.cancel()
        pendingTmuxLease = lease
        let identity = lease.identity
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.pendingTmuxLease?.identity == identity else {
                return
            }
            self.pendingTmuxLease = nil
            self.pendingTmuxLeaseTimeoutWorkItem = nil
            self.tmuxReattachInFlight = false
            self.tmuxReattachDeferred = self.pendingTmuxReattach != nil
            NativeLog.lifecycleInfo(
                "tmux_session_lease_staging_timed_out session=\(identity.sessionID)"
            )
        }
        pendingTmuxLeaseTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: workItem)
    }

    func takePendingTmuxLease() -> NativeTmuxSessionLease? {
        pendingTmuxLeaseTimeoutWorkItem?.cancel()
        pendingTmuxLeaseTimeoutWorkItem = nil
        defer {
            pendingTmuxLease = nil
        }
        return pendingTmuxLease
    }

    private func admitTmuxSnapshot(
        _ snapshot: TmuxSnapshot,
        session: NativeTmuxSession
    ) -> Bool {
        let identity = NativeTmuxSessionIdentity(snapshot: snapshot)
        if session.lease?.identity == identity {
            return true
        }
        if pendingTmuxLease?.identity == identity {
            session.lease = takePendingTmuxLease()
            return true
        }
        switch NativeTmuxSessionLease.acquire(identity: identity) {
        case .acquired(let lease):
            session.lease = lease
            return true
        case .busy:
            NativeLog.runtimeError(
                "tmux_projection_rejected reason=lease_busy session=\(snapshot.session_id)"
            )
        case .unavailable(let message):
            NativeLog.runtimeError(
                "tmux_projection_rejected reason=lease_unavailable message=\(message)"
            )
        }
        return false
    }

    private func updateTmuxPaneMetadata(_ pane: TmuxPaneSnapshot, nativePaneId: Int) {
        paneStore.workingDirectories[nativePaneId] = pane.current_path
        let previousTitle = paneStore.titles[nativePaneId] ?? ""
        guard previousTitle != pane.title else {
            return
        }
        paneStore.titles[nativePaneId] = pane.title
        updateAgentStatusFromTitle(pane.title, paneId: nativePaneId)
    }

    func tmuxWorkspace(
        _ snapshot: TmuxSnapshot,
        session: NativeTmuxSession
    ) -> TerminalCoreSnapshot {
        let theme =
            session.savedWorkspace.tabs
            .first(where: { $0.index == session.savedWorkspace.active_tab })?.theme ?? "Graphite"
        let tabs = snapshot.windows.enumerated().map { index, window in
            let visiblePanes = tmuxLayoutPaneIds(window.layout)
            return TerminalCoreTabSnapshot(
                id: session.nativeTabId(window.window_id),
                index: index,
                title: window.name,
                active_pane: session.nativePaneId(window.active_pane_id),
                theme: theme,
                panes: window.panes
                    .filter { visiblePanes.contains($0.pane_id) }
                    .map { session.nativePaneId($0.pane_id) },
                layout: tmuxLayout(window.layout, session: session)
            )
        }
        let active =
            tabs.firstIndex {
                $0.id == session.nativeTabId(snapshot.active_window_id)
            } ?? 0
        return TerminalCoreSnapshot(active_tab: active, tabs: tabs)
    }

    func tmuxLayout(
        _ layout: TmuxLayoutSnapshot,
        session: NativeTmuxSession
    ) -> PaneLayoutSnapshot {
        if layout.kind == "leaf", let paneId = layout.pane_id {
            return PaneLayoutSnapshot(kind: "leaf", paneId: session.nativePaneId(paneId))
        }
        return PaneLayoutSnapshot(
            kind: "split",
            axis: layout.axis,
            ratio: layout.ratio,
            first: layout.first.map { tmuxLayout($0, session: session) },
            second: layout.second.map { tmuxLayout($0, session: session) }
        )
    }

    func tmuxLayoutPaneIds(_ layout: TmuxLayoutSnapshot) -> Set<UInt32> {
        if layout.kind == "leaf", let paneId = layout.pane_id {
            return [paneId]
        }
        return (layout.first.map(tmuxLayoutPaneIds) ?? [])
            .union(layout.second.map(tmuxLayoutPaneIds) ?? [])
    }

    func tmuxPaneGrid(
        _ pane: TmuxPaneSnapshot
    ) -> (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int) {
        let base = tmuxClientGrid()
        let width = max(1, base.widthPixels * Int(pane.cols) / max(1, base.cols))
        let height = max(1, base.heightPixels * Int(pane.rows) / max(1, base.rows))
        return (Int(pane.rows), Int(pane.cols), width, height)
    }

    func endTmuxSession(gatewayPaneId: Int) {
        guard let session = tmuxSession, session.gatewayPaneId == gatewayPaneId else {
            return
        }
        invalidateTmuxConnectionCallbacks()
        if !session.socketPath.isEmpty {
            lastTmuxSocketPath = session.socketPath
        }
        for paneId in session.nativePaneIds.values {
            removeControlState(paneId)
            removePaneRuntime(paneId)
            paneStore.artifactSelectors.removeValue(forKey: paneId)
            paneStore.discardMetadata(for: paneId)
        }
        pendingTmuxLeaseTimeoutWorkItem?.cancel()
        pendingTmuxLeaseTimeoutWorkItem = nil
        pendingTmuxLease = nil
        tmuxSession = nil
        guard core.applyWorkspace(session.savedWorkspace) else {
            NativeLog.runtimeError("tmux_workspace_restore_failed")
            return
        }
        syncFromCore()
        saveSessionState()
        NativeLog.lifecycleInfo("tmux_control_exited gateway_pane=\(gatewayPaneId)")
    }

    func closeExitedTerminalPanes(_ paneIds: [Int]) -> Bool {
        var closed = false
        for paneId in paneIds {
            removeControlState(paneId)
            removePaneRuntime(paneId)
            paneStore.artifactSelectors.removeValue(forKey: paneId)
            paneStore.scrollRemainders.removeValue(forKey: paneId)
            paneStore.workingDirectories.removeValue(forKey: paneId)
            paneStore.modes.removeValue(forKey: paneId)
            paneStore.titles.removeValue(forKey: paneId)
            closed = core.closePane(paneId) || closed
        }
        guard closed else {
            return false
        }
        guard let snapshot = core.snapshot(), !snapshot.tabs.isEmpty else {
            NSApp.terminate(nil)
            return true
        }
        syncFromCore()
        return true
    }

    func replaceExitedNeovimPane(_ paneId: Int) {
        let exitCode = (paneStore.runtimes[paneId] as? RustNeovimPane)?.exitCode() ?? 1
        removePaneRuntime(paneId)
        paneStore.suspendedWakeupSources.removeValue(forKey: paneId)?.cancel()
        if let suspended = paneStore.suspendedSessions.removeValue(forKey: paneId) {
            if !suspended.pane.isExited() {
                let pane = suspended.pane
                paneStore.runtimes[paneId] = pane
                pane.resize(grid: paneGridSize(paneId))
                pane.setOptionAsAlt(optionAsAltEnabled)
                _ = pane.drain()
                updateTerminalMetadata(pane, paneId: paneId)
                installPaneWakeup(paneId: paneId, pane: pane)
                paneStore.modes[paneId] = .terminal
                paneStore.scrollRemainders[paneId] = 0
                lastNvimModelScrollShift = nil
                suspended.completion?(.success(["pane": paneId, "exitCode": exitCode]))
                return
            }
            suspended.completion?(
                controlFailure("shell_exited", "The suspended shell exited before Neovim.")
            )
        }
        let cwd = paneStore.workingDirectories[paneId] ?? nativeWorkingDirectory()
        guard
            let pane = RustTerminalPane(
                grid: paneGridSize(paneId),
                cwd: cwd,
                shell: settings.shellPath,
                environment: controlEnvironment(paneId: paneId)
            )
        else {
            return
        }
        paneStore.runtimes[paneId] = pane
        pane.setOptionAsAlt(optionAsAltEnabled)
        installPaneWakeup(paneId: paneId, pane: pane)
        paneStore.modes[paneId] = .terminal
        paneStore.scrollRemainders[paneId] = 0
        lastNvimModelScrollShift = nil
    }

    func updateTerminalMetadata(_ pane: RustTerminalPane, paneId: Int) {
        if let cwd = pane.currentWorkingDirectory() {
            paneStore.workingDirectories[paneId] = cwd
        }
        if let title = pane.title(), paneStore.titles[paneId] != title {
            paneStore.titles[paneId] = title
            updateAgentStatusFromTitle(title, paneId: paneId)
            if let tab = lastSnapshot?.tabs.first(where: { $0.active_pane == paneId }),
                let tabTitle = paneStore.tabTitles.automaticTitle(
                    tabId: tab.id,
                    rawTitle: title,
                    claudeSession: paneStore.agentTitleTracker.isClaudeSession(paneId: paneId)
                ),
                tab.title != tabTitle
            {
                core.renameTab(tab.index, title: tabTitle)
                syncFromCore()
            }
        }
        let bells = pane.takeBellCount()
        handleTerminalBells(bells)
    }

    private func updateAgentStatusFromTitle(_ title: String, paneId: Int) {
        guard let transition = paneStore.agentTitleTracker.update(paneId: paneId, title: title)
        else {
            return
        }
        if transition.status == "done" {
            guard let current = paneStatuses.status(for: paneId),
                current.status == "running" || current.status == "waiting"
            else {
                return
            }
        }
        paneStatuses.update(
            paneId: paneId,
            status: transition.status,
            summary: transition.summary
        )
    }

    func updateTerminalBells(_ pane: RustTerminalPane) {
        handleTerminalBells(pane.takeBellCount())
    }

    func handleTerminalBells(_ bells: UInt64) {
        guard bells > 0 else {
            return
        }
        NSSound.beep()
        if notificationsEnabled, !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    func updateActiveFrame() {
        guard let paneId = activePaneId,
            let pane = paneStore.runtimes[paneId]
        else {
            terminalTextView.setRendererModel(nil)
            terminalTextView.setTerminalCursor(nil)
            return
        }

        if let pane = pane as? RustNeovimPane {
            if capturesNvimRendererModels, let model = pane.rendererModel() {
                if let scrollHint = model.scroll_hint {
                    lastNvimModelScrollShift = scrollHint.outputShift
                }
                terminalTextView.setTerminalCursor(nil)
                terminalTextView.setRendererModel(model)
            } else {
                let state = pane.uiState()
                if let scrollHint = state?.scroll_hint {
                    lastNvimModelScrollShift = scrollHint.outputShift
                }
                terminalTextView.setRendererModel(nil)
                terminalTextView.setTerminalCursor(
                    state?.cursor.map { (x: Int($0.x), y: Int($0.y)) }
                )
            }
            metalView.requestFrame()
            return
        }

        terminalTextView.setRendererModel(nil)
        terminalTextView.setTerminalCursor((pane as? RustTerminalPane)?.cursorPosition())
        metalView.requestFrame()
    }

    func renderActiveMetalFrame(
        texture: MTLTexture,
        renderer: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let renderer else {
            return false
        }
        var frames = paneStore.visibleFrames.sorted { $0.key < $1.key }
        if frames.isEmpty, let paneId = activePaneId {
            frames = [(key: paneId, value: terminalTextView.terminalContentRect())]
        }
        var rendered = false
        for (index, entry) in frames.enumerated() {
            guard let pane = terminalPane(for: entry.key),
                let renderHandle = pane.renderHandle()
            else {
                continue
            }
            let geometry = terminalTextView.skiaRenderGeometry(for: entry.value)
            let clear: UInt8 = index == 0 ? 1 : 0
            let ok = renderPaneFrame(
                pane,
                renderHandle: renderHandle,
                texture: texture,
                renderer: renderer,
                geometry: geometry,
                clear: clear,
                preedit: terminalTextView.rendererMarkedText(for: entry.key)
            )
            rendered = rendered || ok
        }
        return rendered
    }

    private func renderPaneFrame(
        _ pane: NativePane,
        renderHandle: UnsafeMutableRawPointer,
        texture: MTLTexture,
        renderer: UnsafeMutableRawPointer,
        geometry: SkiaRenderGeometry,
        clear: UInt8,
        preedit: String?
    ) -> Bool {
        let render: (UnsafePointer<CChar>?) -> Bool = { preeditPointer in
            if pane.kind == .terminal {
                return satinSkiaMetalRenderTerminal(
                    renderer,
                    renderHandle,
                    metalObjectPointer(texture),
                    Int32(texture.width),
                    Int32(texture.height),
                    geometry.originX,
                    geometry.originY,
                    geometry.contentWidth,
                    geometry.contentHeight,
                    geometry.cellWidth,
                    geometry.cellHeight,
                    clear,
                    preeditPointer
                ) != 0
            }
            return satinSkiaMetalRenderNvim(
                renderer,
                renderHandle,
                metalObjectPointer(texture),
                Int32(texture.width),
                Int32(texture.height),
                geometry.originX,
                geometry.originY,
                geometry.contentWidth,
                geometry.contentHeight,
                geometry.cellWidth,
                geometry.cellHeight,
                clear,
                preeditPointer
            ) != 0
        }
        guard let preedit else {
            return render(nil)
        }
        return preedit.withCString { render($0) }
    }
}

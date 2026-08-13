import AppKit
import Foundation

extension TerminalShellViewController {
    func handleControlRequest(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if tmuxSession != nil, request.command == "open-neovim" {
            reply(
                controlFailure(
                    "tmux_owned",
                    "Native Neovim replacement is unavailable while tmux owns the pane."
                )
            )
            return
        }
        switch request.command {
        case "list":
            reply(.success(controlListResult()))
        case "read-screen":
            handleControlReadScreen(request, reply: reply)
        case "send":
            handleControlSend(request, reply: reply)
        case "key":
            handleControlKey(request, reply: reply)
        case "status-set":
            handleControlStatusSet(request, reply: reply)
        case "status-wait":
            handleControlStatusWait(request, reply: reply)
        case "new-tab":
            handleControlNewTab(request, reply: reply)
        case "split":
            handleControlSplit(request, reply: reply)
        case "artifact-show":
            handleControlArtifactShow(request, reply: reply)
        case "select-tab":
            handleControlSelectTab(request, reply: reply)
        case "move-tab":
            handleControlMoveTab(request, reply: reply)
        case "close-tab":
            handleControlCloseTab(request, reply: reply)
        case "select-pane":
            handleControlSelectPane(request, reply: reply)
        case "close-pane":
            handleControlClosePane(request, reply: reply)
        case "open-neovim":
            handleControlOpenNeovim(request, reply: reply)
        case "rename-tab":
            handleControlRenameTab(request, reply: reply)
        case "set-theme":
            handleControlSetTheme(request, reply: reply)
        default:
            reply(controlFailure("unknown_command", "Unknown control command."))
        }
    }

    func controlListResult() -> [String: Any] {
        guard let snapshot = core.snapshot() else {
            return ["tabs": [], "panes": []]
        }
        let activeTab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab })
        let artifactRuntime = paneStore.runtimes[nativeArtifactSidebarPaneId]
        let tabs: [[String: Any]] = snapshot.tabs.map { tab in
            [
                "id": tab.id,
                "index": tab.index,
                "title": tab.title,
                "theme": tab.theme,
                "active": tab.index == snapshot.active_tab,
                "activePane": tab.active_pane,
                "panes":
                    tab.id == activeTab?.id && artifactRuntime != nil
                    ? tab.panes + [nativeArtifactSidebarPaneId] : tab.panes,
            ]
        }
        var panes = snapshot.tabs.flatMap { tab in
            tab.panes.map { paneId -> [String: Any] in
                let pane = paneStore.runtimes[paneId]
                return [
                    "id": paneId,
                    "tab": tab.id,
                    "kind": (pane?.kind ?? paneStore.modes[paneId] ?? .terminal).sessionValue,
                    "cwd": paneStore.workingDirectories[paneId] ?? "",
                    "title": paneStore.titles[paneId] ?? "",
                    "kittyImages": pane?.controlImageCount() ?? 0,
                    "artifact": NSNull(),
                    "status": (paneStatuses.status(for: paneId)?.json as Any?) ?? NSNull(),
                ]
            }
        }
        if let artifactRuntime, let activeTab {
            panes.append([
                "id": nativeArtifactSidebarPaneId,
                "tab": activeTab.id,
                "kind": NativePaneMode.terminal.sessionValue,
                "cwd": paneStore.workingDirectories[nativeArtifactSidebarPaneId] ?? "",
                "title": "Artifact",
                "kittyImages": artifactRuntime.controlImageCount(),
                "artifact":
                    paneStore.artifactSelectors[nativeArtifactSidebarPaneId] ?? NSNull(),
                "status": NSNull(),
            ])
        }
        return [
            "socket": controlSocketPath,
            "activeTab":
                (snapshot.tabs.first(where: { $0.index == snapshot.active_tab })?.id as Any?)
                ?? NSNull(),
            "tabs": tabs,
            "panes": panes,
        ]
    }

    func handleControlReadScreen(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let paneId = request.pane, let pane = controlPane(paneId) else {
            reply(controlFailure("pane_not_found", "The requested pane does not exist."))
            return
        }
        _ = pane.drain()
        reply(.success(["pane": paneId, "text": pane.controlScreenText()]))
    }

    func handleControlSend(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let paneId = request.pane,
            let text = request.text,
            let pane = controlPane(paneId)
        else {
            reply(controlFailure("invalid_send", "A valid pane and text are required."))
            return
        }
        guard paneStore.artifactSelectors[paneId] == nil else {
            reply(.success(["pane": paneId, "bytes": 0, "ignored": true]))
            return
        }
        pane.write(Data(text.utf8))
        reply(.success(["pane": paneId, "bytes": text.utf8.count]))
    }

    func handleControlOpenNeovim(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let paneId = request.pane,
            controlPaneExists(paneId),
            paneStore.runtimes[paneId] is RustTerminalPane,
            paneStore.suspendedSessions[paneId] == nil,
            paneStore.artifactSelectors[paneId] == nil
        else {
            reply(controlFailure("pane_not_terminal", "The pane is not an active terminal."))
            return
        }
        guard let requestedDirectory = request.cwd,
            let cwd = validatedControlDirectory(requestedDirectory)
        else {
            reply(controlFailure("invalid_cwd", "The working directory is invalid."))
            return
        }
        guard let requestedExecutable = request.executable,
            (requestedExecutable as NSString).isAbsolutePath,
            FileManager.default.isExecutableFile(atPath: requestedExecutable)
        else {
            reply(controlFailure("invalid_nvim", "The Neovim executable is invalid."))
            return
        }
        let executable = URL(fileURLWithPath: requestedExecutable).standardizedFileURL.path
        let arguments = request.arguments ?? []
        guard arguments.count <= 256 else {
            reply(controlFailure("too_many_arguments", "Too many Neovim arguments were supplied."))
            return
        }
        let launched = switchTerminalPaneToNeovim(
            paneId: paneId,
            cwd: cwd,
            executable: executable,
            arguments: arguments,
            environment: request.environment ?? [:],
            completion: reply
        )
        if !launched {
            reply(controlFailure("nvim_launch_failed", "Native Neovim could not be started."))
        }
    }

    func handleControlKey(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let paneId = request.pane,
            let key = request.key,
            let pane = controlPane(paneId),
            let data = controlKeyData(key)
        else {
            reply(controlFailure("invalid_key", "The pane or key name is invalid."))
            return
        }
        guard paneStore.artifactSelectors[paneId] == nil else {
            reply(.success(["pane": paneId, "key": key, "ignored": true]))
            return
        }
        pane.write(data)
        reply(.success(["pane": paneId, "key": key]))
    }

    func handleControlStatusSet(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        let allowed = ["idle", "running", "waiting", "done", "failed", "blocked"]
        guard let paneId = request.pane,
            controlPaneExists(paneId),
            let status = request.status?.lowercased(),
            allowed.contains(status)
        else {
            reply(controlFailure("invalid_status", "The pane or status value is invalid."))
            return
        }
        let value = paneStatuses.update(
            paneId: paneId,
            status: status,
            summary: request.summary ?? ""
        )
        reply(.success(value.json))
    }

    func handleControlStatusWait(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let paneId = request.pane, controlPaneExists(paneId) else {
            reply(controlFailure("pane_not_found", "The requested pane does not exist."))
            return
        }
        let milliseconds = min(request.timeout_ms ?? 60_000, 3_600_000)
        paneStatuses.wait(paneId: paneId, timeoutMilliseconds: milliseconds, reply: reply)
    }

    func removeControlState(_ paneId: Int) {
        paneStatuses.remove(paneId: paneId)
    }

    func discardPaneState(_ paneId: Int) {
        removeControlState(paneId)
        discardSuspendedTerminalSession(paneId)
        removePaneRuntime(paneId)
        paneStore.artifactSelectors.removeValue(forKey: paneId)
        terminalTextView.discardPaneZoom(paneId)
        paneStore.discardMetadata(for: paneId)
    }

    func restoreControlContext(tabId: Int?, paneId: Int?) {
        guard let tabId,
            let tab = lastSnapshot?.tabs.first(where: { $0.id == tabId })
        else {
            return
        }
        _ = core.selectTab(tab.index)
        if let paneId, tab.panes.contains(paneId) {
            _ = core.selectPane(paneId)
        }
        syncFromCore()
    }

    func handleControlNewTab(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.title != nil && (title?.isEmpty ?? true) {
            reply(controlFailure("invalid_title", "The tab title cannot be empty."))
            return
        }
        if let session = tmuxSession {
            guard let cwd = validatedControlDirectory(request.cwd) else {
                reply(controlFailure("invalid_cwd", "The working directory is invalid."))
                return
            }
            var command = "new-window"
            if request.background == true {
                command += " -d"
            }
            command += " -c \(tmuxCommandArgument(cwd))"
            if let title {
                command += " -n \(tmuxCommandArgument(title))"
            }
            replyTmuxCommand(session, command: command, result: ["queued": true], reply: reply)
            return
        }
        let previousTabId = lastSnapshot.flatMap { snapshot in
            snapshot.tabs.first(where: { $0.index == snapshot.active_tab })?.id
        }
        let previousPaneId = activePaneId
        guard let cwd = validatedControlDirectory(request.cwd) else {
            reply(controlFailure("invalid_cwd", "The working directory is invalid."))
            return
        }
        pendingPaneWorkingDirectory = cwd
        let index = core.newTab()
        if let title {
            core.renameTab(index, title: title)
        }
        syncFromCore()
        guard let tab = lastSnapshot?.tabs.first(where: { $0.index == index }) else {
            reply(controlFailure("core_error", "The new tab was not created."))
            return
        }
        let result = ["tab": tab.id, "pane": tab.active_pane]
        if request.background == true {
            restoreControlContext(tabId: previousTabId, paneId: previousPaneId)
        }
        reply(.success(result))
    }

    func handleControlSplit(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if let session = tmuxSession {
            guard let paneId = request.pane,
                let tmuxPaneId = session.tmuxPaneIds[paneId],
                let cwd = validatedControlDirectory(request.cwd),
                let axisName = request.axis,
                ["horizontal", "vertical"].contains(axisName)
            else {
                reply(controlFailure("invalid_split", "The pane, axis, or directory is invalid."))
                return
            }
            let flag = axisName == "horizontal" ? "-v" : "-h"
            let detached = request.background == true ? " -d" : ""
            let command =
                "split-window \(flag)\(detached) -c \(tmuxCommandArgument(cwd)) "
                + "-t %\(tmuxPaneId)"
            replyTmuxCommand(
                session,
                command: command,
                result: ["pane": paneId, "queued": true],
                reply: reply
            )
            return
        }
        let previousTabId = lastSnapshot.flatMap { snapshot in
            snapshot.tabs.first(where: { $0.index == snapshot.active_tab })?.id
        }
        let previousPaneId = activePaneId
        guard let paneId = request.pane,
            let tab = lastSnapshot?.tabs.first(where: { $0.panes.contains(paneId) }),
            let cwd = validatedControlDirectory(request.cwd),
            let axisName = request.axis
        else {
            reply(controlFailure("invalid_split", "The pane, axis, or directory is invalid."))
            return
        }
        _ = core.selectTab(tab.index)
        _ = core.selectPane(paneId)
        pendingPaneWorkingDirectory = request.cwd == nil ? activeWorkingDirectory() : cwd
        let axis = axisName == "horizontal" ? ffiSplitHorizontal : ffiSplitVertical
        guard let newPane = core.splitActive(axis: axis) else {
            reply(controlFailure("core_error", "The pane could not be split."))
            return
        }
        syncFromCore()
        let result = ["tab": tab.id, "pane": newPane]
        if request.background == true {
            restoreControlContext(tabId: previousTabId, paneId: previousPaneId)
        }
        reply(.success(result))
    }

    func handleControlArtifactShow(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let paneId = request.pane,
            let tab = lastSnapshot?.tabs.first(where: { $0.panes.contains(paneId) }),
            let artifact = request.artifact,
            validControlArtifactSelector(artifact),
            controlArtifactExists(artifact),
            FileManager.default.isExecutableFile(atPath: controlCliPath),
            let axisName = request.axis,
            ["vertical", "horizontal"].contains(axisName)
        else {
            reply(
                controlFailure(
                    "invalid_artifact",
                    "The pane or artifact is invalid."
                )
            )
            return
        }
        guard
            let reused = showArtifactSidebar(
                artifact: artifact,
                sourcePaneId: paneId,
                focus: request.background != true
            )
        else {
            reply(controlFailure("runtime_error", "The artifact sidebar could not be opened."))
            return
        }
        let result: [String: Any] = [
            "artifact": artifact,
            "tab": tab.id,
            "pane": nativeArtifactSidebarPaneId,
            "reused": reused,
        ]
        reply(.success(result))
    }

    func validControlArtifactSelector(_ value: String) -> Bool {
        let components = value.split(separator: "@", omittingEmptySubsequences: false)
        guard components.count <= 2, let id = components.first, !id.isEmpty,
            id.utf8.count <= 64,
            id.utf8.allSatisfy({ byte in
                (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
            })
        else {
            return false
        }
        guard components.count == 2 else {
            return true
        }
        let version = components[1].first == "v" ? components[1].dropFirst() : components[1]
        return !version.isEmpty && version.count <= 10
            && version.utf8.allSatisfy { byte in
                byte >= 48 && byte <= 57
            }
    }

    func controlArtifactExists(_ artifact: String) -> Bool {
        let components = artifact.split(separator: "@", maxSplits: 1)
        guard let rawId = components.first else {
            return false
        }
        let id = String(rawId)
        let requestedVersion: UInt32?
        if components.count == 2 {
            let component =
                components[1].first == "v"
                ? components[1].dropFirst()
                : components[1][...]
            guard let version = UInt32(component) else {
                return false
            }
            requestedVersion = version
        } else {
            requestedVersion = nil
        }
        let socketDirectory = URL(fileURLWithPath: controlSocketPath).deletingLastPathComponent()
        let root =
            (socketDirectory.lastPathComponent == "run"
            ? socketDirectory.deletingLastPathComponent()
            : socketDirectory)
            .appendingPathComponent("artifacts", isDirectory: true)
        let marker =
            root
            .appendingPathComponent(".index", isDirectory: true)
            .appendingPathComponent(id)
        let suffix = "--\(id)"
        var directory: URL?
        if let markerData = try? Data(contentsOf: marker),
            let markerValue = String(data: markerData, encoding: .utf8)
        {
            let name = markerValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), name.hasSuffix(suffix) {
                directory = root.appendingPathComponent(name, isDirectory: true)
            }
        }
        if directory == nil {
            let matches = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { !$0.hasPrefix(".") && $0.hasSuffix(suffix) }
            guard matches.count == 1 else {
                return false
            }
            directory = root.appendingPathComponent(matches[0], isDirectory: true)
        }
        guard let directory else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            let data = try? Data(contentsOf: directory.appendingPathComponent("metadata.json")),
            let metadata = try? JSONDecoder().decode(
                NativeStoredArtifactMetadata.self,
                from: data
            ),
            metadata.id == id,
            !metadata.versions.isEmpty
        else {
            return false
        }
        guard let requestedVersion else {
            return true
        }
        return metadata.versions.contains { $0.version == requestedVersion }
    }

    func handleControlSelectTab(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if let session = tmuxSession {
            guard let tabId = request.tab,
                let windowId = session.tmuxWindowIds[tabId]
            else {
                reply(controlFailure("tab_not_found", "The requested tab does not exist."))
                return
            }
            replyTmuxCommand(
                session,
                command: "select-window -t @\(windowId)",
                result: ["tab": tabId],
                reply: reply
            )
            return
        }
        guard let tabId = request.tab,
            let tab = lastSnapshot?.tabs.first(where: { $0.id == tabId }),
            core.selectTab(tab.index)
        else {
            reply(controlFailure("tab_not_found", "The requested tab does not exist."))
            return
        }
        syncFromCore()
        focusTerminal()
        reply(.success(["tab": tabId]))
    }

    func handleControlMoveTab(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if let session = tmuxSession {
            guard let tabId = request.tab,
                let index = request.index,
                let snapshot = lastSnapshot,
                let source = snapshot.tabs.first(where: { $0.id == tabId }),
                let sourceWindow = session.tmuxWindowIds[source.id],
                index >= 0,
                index < snapshot.tabs.count
            else {
                reply(
                    controlFailure("invalid_tab_index", "The tab or destination index is invalid."))
                return
            }
            let remaining = snapshot.tabs.filter { $0.id != tabId }
            if remaining.isEmpty || source.index == index {
                reply(.success(["tab": tabId, "index": index]))
                return
            }
            let positionFlag: String
            let targetTab: TerminalCoreTabSnapshot
            if index == 0 {
                positionFlag = "-b"
                targetTab = remaining[0]
            } else {
                positionFlag = "-a"
                targetTab = remaining[min(index - 1, remaining.count - 1)]
            }
            guard let targetWindow = session.tmuxWindowIds[targetTab.id] else {
                reply(controlFailure("tab_not_found", "The destination tab does not exist."))
                return
            }
            replyTmuxCommand(
                session,
                command: "move-window -s @\(sourceWindow) \(positionFlag) -t @\(targetWindow)",
                result: ["tab": tabId, "index": index],
                reply: reply
            )
            return
        }
        guard let tabId = request.tab,
            let index = request.index,
            let snapshot = lastSnapshot,
            index < snapshot.tabs.count,
            snapshot.tabs.contains(where: { $0.id == tabId }),
            core.moveTab(tabId, to: index)
        else {
            reply(controlFailure("invalid_tab_index", "The tab or destination index is invalid."))
            return
        }
        syncFromCore()
        reply(.success(["tab": tabId, "index": index]))
    }

    func handleControlCloseTab(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if let session = tmuxSession {
            guard let tabId = request.tab,
                let snapshot = lastSnapshot,
                let tab = snapshot.tabs.first(where: { $0.id == tabId }),
                let windowId = session.tmuxWindowIds[tabId]
            else {
                reply(controlFailure("tab_not_found", "The requested tab does not exist."))
                return
            }
            guard snapshot.tabs.count > 1 else {
                reply(controlFailure("final_tab", "The final tab cannot be closed by automation."))
                return
            }
            replyTmuxCommand(
                session,
                command: "kill-window -t @\(windowId)",
                result: ["tab": tabId, "closedPanes": tab.panes],
                reply: reply
            )
            return
        }
        guard let tabId = request.tab,
            let snapshot = lastSnapshot,
            let tab = snapshot.tabs.first(where: { $0.id == tabId })
        else {
            reply(controlFailure("tab_not_found", "The requested tab does not exist."))
            return
        }
        guard snapshot.tabs.count > 1 else {
            reply(controlFailure("final_tab", "The final tab cannot be closed by automation."))
            return
        }
        for paneId in tab.panes {
            guard core.closePane(paneId) else {
                reply(controlFailure("core_error", "The tab could not be closed."))
                return
            }
            discardPaneState(paneId)
        }
        syncFromCore()
        reply(.success(["tab": tabId, "closedPanes": tab.panes]))
    }

    func handleControlSelectPane(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if request.pane == nativeArtifactSidebarPaneId,
            paneStore.runtimes[nativeArtifactSidebarPaneId] != nil,
            let tabId = lastSnapshot.flatMap({ snapshot in
                snapshot.tabs.first(where: { $0.index == snapshot.active_tab })?.id
            })
        {
            activePaneId = nativeArtifactSidebarPaneId
            terminalTextView.setActivePaneId(nativeArtifactSidebarPaneId)
            updateActiveFrame()
            focusTerminal()
            reply(.success(["tab": tabId, "pane": nativeArtifactSidebarPaneId]))
            return
        }
        if let session = tmuxSession {
            guard let paneId = request.pane,
                let tmuxPaneId = session.tmuxPaneIds[paneId]
            else {
                reply(controlFailure("pane_not_found", "The requested pane does not exist."))
                return
            }
            replyTmuxCommand(
                session,
                command: "select-pane -t %\(tmuxPaneId)",
                result: ["pane": paneId],
                reply: reply
            )
            return
        }
        guard let paneId = request.pane,
            let tab = lastSnapshot?.tabs.first(where: { $0.panes.contains(paneId) }),
            core.selectTab(tab.index),
            core.selectPane(paneId)
        else {
            reply(controlFailure("pane_not_found", "The requested pane does not exist."))
            return
        }
        syncFromCore()
        focusTerminal()
        reply(.success(["tab": tab.id, "pane": paneId]))
    }

    func handleControlClosePane(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        if request.pane == nativeArtifactSidebarPaneId,
            paneStore.runtimes[nativeArtifactSidebarPaneId] != nil,
            let tabId = lastSnapshot.flatMap({ snapshot in
                snapshot.tabs.first(where: { $0.index == snapshot.active_tab })?.id
            })
        {
            _ = closeArtifactSidebar()
            reply(
                .success([
                    "tab": tabId,
                    "pane": nativeArtifactSidebarPaneId,
                    "tabClosed": false,
                ]))
            return
        }
        if let session = tmuxSession {
            guard let paneId = request.pane,
                let snapshot = lastSnapshot,
                let tab = snapshot.tabs.first(where: { $0.panes.contains(paneId) }),
                let tmuxPaneId = session.tmuxPaneIds[paneId]
            else {
                reply(controlFailure("pane_not_found", "The requested pane does not exist."))
                return
            }
            guard snapshot.tabs.count > 1 || tab.panes.count > 1 else {
                reply(
                    controlFailure("final_pane", "The final pane cannot be closed by automation."))
                return
            }
            replyTmuxCommand(
                session,
                command: "kill-pane -t %\(tmuxPaneId)",
                result: ["tab": tab.id, "pane": paneId, "tabClosed": tab.panes.count == 1],
                reply: reply
            )
            return
        }
        guard let paneId = request.pane,
            let snapshot = lastSnapshot,
            let tab = snapshot.tabs.first(where: { $0.panes.contains(paneId) })
        else {
            reply(controlFailure("pane_not_found", "The requested pane does not exist."))
            return
        }
        guard snapshot.tabs.count > 1 || tab.panes.count > 1 else {
            reply(controlFailure("final_pane", "The final pane cannot be closed by automation."))
            return
        }
        guard core.closePane(paneId) else {
            reply(controlFailure("core_error", "The pane could not be closed."))
            return
        }
        discardPaneState(paneId)
        syncFromCore()
        reply(
            .success([
                "tab": tab.id,
                "pane": paneId,
                "tabClosed": tab.panes.count == 1,
            ]))
    }

    func handleControlRenameTab(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let tabId = request.tab,
            let title = request.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty,
            let tab = lastSnapshot?.tabs.first(where: { $0.id == tabId })
        else {
            reply(controlFailure("invalid_tab", "The tab or title is invalid."))
            return
        }
        if let session = tmuxSession,
            let windowId = session.tmuxWindowIds[tabId]
        {
            replyTmuxCommand(
                session,
                command: "rename-window -t @\(windowId) \(tmuxCommandArgument(title))",
                result: ["tab": tabId, "title": title],
                reply: reply
            )
            return
        }
        core.renameTab(tab.index, title: title)
        syncFromCore()
        reply(.success(["tab": tabId, "title": title]))
    }

    func handleControlSetTheme(
        _ request: NativeControlRequest,
        reply: @escaping NativeControlReply
    ) {
        guard let tabId = request.tab,
            let theme = request.theme,
            nativeThemeNames.contains(theme),
            let tab = lastSnapshot?.tabs.first(where: { $0.id == tabId })
        else {
            reply(controlFailure("invalid_theme", "The tab or theme is invalid."))
            return
        }
        core.setTheme(theme, tab: tab.index)
        syncFromCore()
        reply(.success(["tab": tabId, "theme": theme]))
    }

    func controlPane(_ paneId: Int) -> NativePane? {
        guard controlPaneExists(paneId) else {
            return nil
        }
        return terminalPane(for: paneId)
    }

    func controlPaneExists(_ paneId: Int) -> Bool {
        if paneId == nativeArtifactSidebarPaneId {
            return paneStore.runtimes[paneId] != nil
        }
        return lastSnapshot?.tabs.contains(where: { $0.panes.contains(paneId) }) == true
    }

    func validatedControlDirectory(_ requested: String?) -> String? {
        let value = requested ?? newPaneWorkingDirectory()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return nil
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    func controlFailure(_ code: String, _ message: String) -> Result<
        Any, NativeControlFailure
    > {
        .failure(NativeControlFailure(code: code, message: message))
    }

    func replyTmuxCommand(
        _ session: NativeTmuxSession,
        command: String,
        result: [String: Any],
        reply: @escaping NativeControlReply
    ) {
        guard session.gateway.tmuxCommand(command) else {
            reply(controlFailure("tmux_command_failed", "The tmux command could not be queued."))
            return
        }
        reply(.success(result))
    }

    func controlKeyData(_ key: String) -> Data? {
        let normalized = key.lowercased()
        let named: [String: [UInt8]] = [
            "enter": [13], "return": [13], "tab": [9], "escape": [27],
            "esc": [27], "backspace": [127], "space": [32],
            "up": [27, 91, 65], "down": [27, 91, 66],
            "right": [27, 91, 67], "left": [27, 91, 68],
            "home": [27, 91, 72], "end": [27, 91, 70],
            "delete": [27, 91, 51, 126], "pageup": [27, 91, 53, 126],
            "pagedown": [27, 91, 54, 126],
        ]
        if let bytes = named[normalized] {
            return Data(bytes)
        }
        if normalized.hasPrefix("ctrl+"),
            let scalar = normalized.dropFirst(5).unicodeScalars.first,
            normalized.dropFirst(5).unicodeScalars.count == 1,
            scalar.value >= 97,
            scalar.value <= 122
        {
            return Data([UInt8(scalar.value - 96)])
        }
        return key.count == 1 ? Data(key.utf8) : nil
    }

}

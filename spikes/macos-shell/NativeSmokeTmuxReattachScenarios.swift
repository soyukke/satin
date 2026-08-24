import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func applyTmuxLeaseHolderSmokeScenario(
            resultPath: String,
            sessionName: String,
            socketPath: String
        ) {
            let attachment = NativeTmuxAttachment(
                sessionName: sessionName,
                socketPath: socketPath
            )
            guard let validated = validatedTmuxAttachment(attachment) else {
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-lease-holder invalid-descriptor\n"
                )
                return
            }
            pendingTmuxReattach = validated
            schedulePendingTmuxReattach()
            waitForTmuxLeaseHolder(
                resultPath,
                attachment: validated,
                retries: 50
            )
        }

        func waitForTmuxLeaseHolder(
            _ resultPath: String,
            attachment: NativeTmuxAttachment,
            retries: Int
        ) {
            let ready =
                tmuxSession?.sessionName == attachment.sessionName
                && tmuxSession?.socketPath == attachment.socketPath
                && tmuxSession?.lease != nil
            guard ready else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxLeaseHolder(
                            resultPath,
                            attachment: attachment,
                            retries: retries - 1
                        )
                    }
                } else {
                    let gateway = activePaneId.flatMap {
                        paneStore.runtimes[$0] as? RustTerminalPane
                    }
                    let screen =
                        gateway?.controlScreenText()
                        .suffix(240)
                        .replacingOccurrences(of: "\n", with: "|") ?? "none"
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-lease-holder entry-timeout "
                            + "pending=\(pendingTmuxReattach != nil) "
                            + "inflight=\(tmuxReattachInFlight) "
                            + "deferred=\(tmuxReattachDeferred) "
                            + "attempt=\(tmuxReattachAttempt) "
                            + "commands=\(tmuxConnectionCommandHistory.count) "
                            + "prompt=\(gateway.map { satinRuntimeTmuxShellPromptState($0.handle) } ?? 0) "
                            + "foreground=\(gateway.map { satinRuntimeInteractiveShellOwnsForeground($0.handle) } ?? 0) "
                            + "screen=\(screen)\n"
                    )
                }
                return
            }
            try? "ready tmux-lease-holder lease=yes\n".write(
                toFile: resultPath,
                atomically: true,
                encoding: .utf8
            )
        }

        func applyTmuxLeaseBusySmokeScenario(
            resultPath: String,
            sessionName: String,
            socketPath: String
        ) {
            let attachment = NativeTmuxAttachment(
                sessionName: sessionName,
                socketPath: socketPath
            )
            guard let validated = validatedTmuxAttachment(attachment) else {
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-lease-busy invalid-descriptor\n"
                )
                return
            }
            pendingTmuxReattach = validated
            schedulePendingTmuxReattach()
            waitForTmuxLeaseBusy(
                resultPath,
                attachment: validated,
                retries: 50
            )
        }

        func waitForTmuxLeaseBusy(
            _ resultPath: String,
            attachment: NativeTmuxAttachment,
            retries: Int
        ) {
            let terminalText =
                activePaneId
                .flatMap { paneStore.runtimes[$0] as? RustTerminalPane }?
                .controlScreenText() ?? ""
            let savedAttachment = currentSessionState()?.tmuxAttachment
            let descriptorPreserved =
                savedAttachment?.sessionName == attachment.sessionName
                && savedAttachment?.socketPath == attachment.socketPath
            let rejected =
                tmuxSession == nil
                && tmuxReattachDeferred
                && terminalText.contains("already open in another Satin window")
                && descriptorPreserved
            guard rejected else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxLeaseBusy(
                            resultPath,
                            attachment: attachment,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-lease-busy rejected=no descriptor="
                            + "\(descriptorPreserved ? "yes" : "no")\n"
                    )
                }
                return
            }
            writeSessionSmokeResult(
                resultPath,
                result: "ok tmux-lease-busy rejected=yes waited=no descriptor=yes\n"
            )
        }

        func applyTmuxReattachSmokeScenario(
            resultPath: String,
            sessionName: String,
            socketPath: String,
            expectedContent: String
        ) {
            let attachment = NativeTmuxAttachment(
                sessionName: sessionName,
                socketPath: socketPath
            )
            guard let validated = validatedTmuxAttachment(attachment) else {
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-reattach invalid-descriptor\n")
                return
            }
            pendingTmuxReattach = validated
            schedulePendingTmuxReattach()
            waitForTmuxReattachEntry(
                resultPath,
                attachment: validated,
                expectedContent: expectedContent,
                retries: 40
            )
        }

        func applyTmuxRestartCheckpointSmokeScenario(
            resultPath: String,
            sessionName: String,
            socketPath: String,
            expectedContent: String
        ) {
            let attachment = NativeTmuxAttachment(
                sessionName: sessionName,
                socketPath: socketPath
            )
            guard let validated = validatedTmuxAttachment(attachment) else {
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-restart-checkpoint invalid-descriptor\n"
                )
                return
            }
            pendingTmuxReattach = validated
            schedulePendingTmuxReattach()
            waitForTmuxRestartSmoke(
                resultPath,
                stage: "checkpoint",
                attachment: validated,
                expectedContent: expectedContent,
                retries: 40
            )
        }

        func applyTmuxRestartRestoreSmokeScenario(
            resultPath: String,
            sessionName: String,
            socketPath: String,
            expectedContent: String
        ) {
            let attachment = NativeTmuxAttachment(
                sessionName: sessionName,
                socketPath: socketPath
            )
            guard let validated = validatedTmuxAttachment(attachment) else {
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-restart-restore invalid-descriptor\n"
                )
                return
            }
            waitForTmuxRestartSmoke(
                resultPath,
                stage: "restore",
                attachment: validated,
                expectedContent: expectedContent,
                retries: 40
            )
        }

        func waitForTmuxRestartSmoke(
            _ resultPath: String,
            stage: String,
            attachment: NativeTmuxAttachment,
            expectedContent: String,
            retries: Int
        ) {
            let sessionMatches =
                tmuxSession?.sessionName == attachment.sessionName
                && tmuxSession?.socketPath == attachment.socketPath
            let contentVisible = paneStore.runtimes.values.contains { pane in
                (pane as? RustTmuxPane)?.controlScreenText().contains(expectedContent) == true
            }
            let savedAttachment = currentSessionState()?.tmuxAttachment
            let descriptorSaved =
                savedAttachment?.sessionName == attachment.sessionName
                && savedAttachment?.socketPath == attachment.socketPath
                && savedAttachment?.executablePath.map {
                    ($0 as NSString).isAbsolutePath
                        && FileManager.default.isExecutableFile(atPath: $0)
                } == true
            guard sessionMatches, contentVisible, descriptorSaved else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxRestartSmoke(
                            resultPath,
                            stage: stage,
                            attachment: attachment,
                            expectedContent: expectedContent,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-restart-\(stage) attached="
                            + "\(sessionMatches ? "yes" : "no") content="
                            + "\(contentVisible ? "yes" : "no") descriptor="
                            + "\(descriptorSaved ? "yes" : "no")\n"
                    )
                }
                return
            }
            closeWindowAfterWritingSessionSmokeResult(
                resultPath,
                result: "ok tmux-restart-\(stage) attached=yes content=yes descriptor=yes "
                    + "window-close=yes\n"
            )
        }

        func saveLegacyTmuxRestartStateForSmoke() -> Bool {
            guard let state = currentSessionState(),
                let attachment = state.tmuxAttachment
            else {
                return false
            }
            let legacyState = NativeSessionState(
                schemaVersion: 3,
                activeTab: state.activeTab,
                tabs: state.tabs,
                tmuxAttachment: NativeTmuxAttachment(
                    sessionName: attachment.sessionName,
                    socketPath: attachment.socketPath
                )
            )
            guard let data = try? JSONEncoder().encode(legacyState) else {
                return false
            }
            UserDefaults.standard.set(data, forKey: NativePreferenceKey.sessionState)
            return sessionSchemaVersion(in: data) == 3
        }

        func waitForTmuxReattachEntry(
            _ resultPath: String,
            attachment: NativeTmuxAttachment,
            expectedContent: String,
            retries: Int
        ) {
            guard let session = tmuxSession else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxReattachEntry(
                            resultPath,
                            attachment: attachment,
                            expectedContent: expectedContent,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeSessionSmokeResult(
                        resultPath, result: "failed tmux-reattach entry-timeout\n")
                }
                return
            }
            let savedAttachment = currentSessionState()?.tmuxAttachment
            let savedExecutable = savedAttachment?.executablePath ?? ""
            let descriptorSaved =
                savedAttachment?.sessionName == attachment.sessionName
                && savedAttachment?.socketPath == attachment.socketPath
                && (savedExecutable as NSString).isAbsolutePath
                && FileManager.default.isExecutableFile(atPath: savedExecutable)
            guard session.sessionName == attachment.sessionName,
                session.socketPath == attachment.socketPath,
                descriptorSaved,
                sessionControlTitle().hasPrefix("tmux · ")
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxReattachEntry(
                            resultPath,
                            attachment: attachment,
                            expectedContent: expectedContent,
                            retries: retries - 1
                        )
                    }
                } else {
                    _ = session.gateway.tmuxCommand("detach-client")
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-reattach topology-or-descriptor\n"
                    )
                }
                return
            }
            let existingContentVisible = paneStore.runtimes.values.contains { pane in
                guard let tmuxPane = pane as? RustTmuxPane else {
                    return false
                }
                return tmuxPane.controlScreenText().contains(expectedContent)
            }
            guard existingContentVisible else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxReattachEntry(
                            resultPath,
                            attachment: attachment,
                            expectedContent: expectedContent,
                            retries: retries - 1
                        )
                    }
                } else {
                    _ = session.gateway.tmuxCommand("detach-client")
                    let detail = paneStore.runtimes.values.compactMap { pane in
                        (pane as? RustTmuxPane)?.controlScreenText()
                    }.joined(separator: " | ").prefix(800)
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-reattach existing-content=no detail=\(detail)\n"
                    )
                }
                return
            }
            guard let paneId = activePaneId,
                let pane = paneStore.runtimes[paneId] as? RustTmuxPane,
                let projectedCwd = paneStore.workingDirectories[paneId],
                nativeNeovimWorkingDirectory(
                    paneId: paneId,
                    terminal: pane,
                    requestedDirectory: nil
                ) == projectedCwd
            else {
                _ = session.gateway.tmuxCommand("detach-client")
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-reattach active-pane-or-cwd=no\n")
                return
            }
            let previousScreen = pane.controlScreenText()
            let initialFrames = metalView.skiaFrames()
            guard sendTmuxReattachControlD(pane) else {
                _ = tmuxSession?.gateway.tmuxCommand("detach-client")
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-reattach nvim-scroll-input=no\n")
                return
            }
            waitForTmuxReattachScroll(
                resultPath,
                attachment: attachment,
                pane: pane,
                initialFrames: initialFrames,
                previousScreen: previousScreen,
                remainingScrolls: 2,
                retries: 200
            )
        }

        func waitForTmuxReattachScroll(
            _ resultPath: String,
            attachment: NativeTmuxAttachment,
            pane: RustTmuxPane,
            initialFrames: Int,
            previousScreen: String,
            remainingScrolls: Int,
            retries: Int
        ) {
            let frames = metalView.skiaFrames()
            let position = abs(pane.rendererScrollPosition())
            let scrolled = pane.controlScreenText() != previousScreen
            guard scrolled, frames > initialFrames, position > maxTerminalBottomInputSmokePosition
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.waitForTmuxReattachScroll(
                            resultPath,
                            attachment: attachment,
                            pane: pane,
                            initialFrames: initialFrames,
                            previousScreen: previousScreen,
                            remainingScrolls: remainingScrolls,
                            retries: retries - 1
                        )
                    }
                } else {
                    _ = tmuxSession?.gateway.tmuxCommand("detach-client")
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-reattach nvim-scroll-start=no "
                            + "frames=\(frames - initialFrames) position=\(position)\n"
                    )
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self, weak pane] in
                guard let self, let pane else {
                    return
                }
                self.verifyTmuxReattachScrollProgress(
                    resultPath,
                    attachment: attachment,
                    pane: pane,
                    initialFrames: frames,
                    initialPosition: position,
                    remainingScrolls: remainingScrolls,
                    retries: 100
                )
            }
        }

        func verifyTmuxReattachScrollProgress(
            _ resultPath: String,
            attachment: NativeTmuxAttachment,
            pane: RustTmuxPane,
            initialFrames: Int,
            initialPosition: Double,
            remainingScrolls: Int,
            retries: Int
        ) {
            let frames = metalView.skiaFrames()
            let position = abs(pane.rendererScrollPosition())
            let initialFractional = abs(initialPosition.rounded() - initialPosition)
            let fractional = abs(position.rounded() - position)
            guard frames > initialFrames, position < initialPosition else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.verifyTmuxReattachScrollProgress(
                            resultPath,
                            attachment: attachment,
                            pane: pane,
                            initialFrames: initialFrames,
                            initialPosition: initialPosition,
                            remainingScrolls: remainingScrolls,
                            retries: retries - 1
                        )
                    }
                    return
                }
                _ = tmuxSession?.gateway.tmuxCommand("detach-client")
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-reattach nvim-scroll-progress=no "
                        + "frames=\(frames - initialFrames) "
                        + "position=\(initialPosition)->\(position) "
                        + "fractional=\(initialFractional)->\(fractional)\n"
                )
                return
            }
            if remainingScrolls > 0 {
                waitForTmuxReattachScrollIdle(
                    resultPath,
                    attachment: attachment,
                    pane: pane,
                    remainingScrolls: remainingScrolls,
                    retries: 120
                )
                return
            }
            pane.write(Data("\u{1b}:qa!\r".utf8))
            waitForTmuxReattachPrimaryRestore(
                resultPath,
                attachment: attachment,
                retries: 30
            )
        }

        func waitForTmuxReattachScrollIdle(
            _ resultPath: String,
            attachment: NativeTmuxAttachment,
            pane: RustTmuxPane,
            remainingScrolls: Int,
            retries: Int
        ) {
            let position = abs(pane.rendererScrollPosition())
            guard position <= maxTerminalBottomInputSmokePosition else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        [weak self, weak pane] in
                        guard let pane else {
                            return
                        }
                        self?.waitForTmuxReattachScrollIdle(
                            resultPath,
                            attachment: attachment,
                            pane: pane,
                            remainingScrolls: remainingScrolls,
                            retries: retries - 1
                        )
                    }
                } else {
                    _ = tmuxSession?.gateway.tmuxCommand("detach-client")
                    let windowVisible = view.window?.occlusionState.contains(.visible) == true
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-reattach nvim-scroll-idle=no "
                            + "position=\(position) frames=\(metalView.skiaFrames()) "
                            + "skia-pending=\(metalView.hasPendingSkiaFrame() ? "yes" : "no") "
                            + "\(metalView.frameRequestDiagnosticsSummary()) "
                            + "visible=\(windowVisible ? "yes" : "no") "
                            + "active=\(NSApp.isActive ? "yes" : "no")\n"
                    )
                }
                return
            }

            let previousScreen = pane.controlScreenText()
            let initialFrames = metalView.skiaFrames()
            guard sendTmuxReattachControlD(pane) else {
                _ = tmuxSession?.gateway.tmuxCommand("detach-client")
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-reattach nvim-scroll-input=no\n")
                return
            }
            waitForTmuxReattachScroll(
                resultPath,
                attachment: attachment,
                pane: pane,
                initialFrames: initialFrames,
                previousScreen: previousScreen,
                remainingScrolls: remainingScrolls - 1,
                retries: 200
            )
        }

        func sendTmuxReattachControlD(_ pane: RustTmuxPane) -> Bool {
            guard let paneId = activePaneId,
                paneStore.runtimes[paneId] === pane,
                let pressed = tmuxReattachControlDEvent(released: false),
                let released = tmuxReattachControlDEvent(released: true)
            else {
                return false
            }
            // NSTextInputContext is nondeterministic for synthetic key events. Route the
            // smoke key through the same active-pane callback used by keyDown, and require
            // the tmux runtime to confirm that it accepted the press.
            guard terminalTextView.routeKeyEvent(pressed, released: false) else {
                return false
            }
            terminalTextView.keyUp(with: released)
            return true
        }

        func tmuxReattachControlDEvent(released: Bool) -> NSEvent? {
            NSEvent.keyEvent(
                with: released ? .keyUp : .keyDown,
                location: .zero,
                modifierFlags: .control,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                characters: "\u{04}",
                charactersIgnoringModifiers: "d",
                isARepeat: false,
                keyCode: 2
            )
        }

        func waitForTmuxReattachPrimaryRestore(
            _ resultPath: String,
            attachment: NativeTmuxAttachment,
            retries: Int
        ) {
            let primaryVisible =
                activePaneId
                .flatMap { paneStore.runtimes[$0] as? RustTmuxPane }?
                .controlScreenText()
                .contains("SATIN_TMUX_REATTACH_PRIMARY_CONTENT") == true
            guard primaryVisible else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxReattachPrimaryRestore(
                            resultPath,
                            attachment: attachment,
                            retries: retries - 1
                        )
                    }
                } else {
                    _ = tmuxSession?.gateway.tmuxCommand("detach-client")
                    writeSessionSmokeResult(
                        resultPath, result: "failed tmux-reattach primary-restore=no\n")
                }
                return
            }
            _ = tmuxSession?.gateway.tmuxCommand("detach-client")
            waitForTmuxReattachDetach(resultPath, attachment: attachment, retries: 30)
        }

        func waitForTmuxReattachDetach(
            _ resultPath: String,
            attachment: NativeTmuxAttachment,
            retries: Int
        ) {
            guard tmuxSession == nil else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxReattachDetach(
                            resultPath,
                            attachment: attachment,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeSessionSmokeResult(
                        resultPath, result: "failed tmux-reattach detach-timeout\n")
                }
                return
            }
            let attachmentCleared = currentSessionState()?.tmuxAttachment == nil
            let sessionListed: Bool
            let discoveryDetail: String
            if let executable = resolvedTmuxExecutable,
                case let result = NativeTmuxSessionDiscovery.sessions(
                    executable: executable, socketPath: attachment.socketPath)
            {
                switch result {
                case .sessions(let sessions):
                    sessionListed = sessions.contains {
                        $0.name == attachment.sessionName && $0.socketPath == attachment.socketPath
                    }
                    discoveryDetail = sessions.map { "\($0.name):\($0.socketPath)" }.joined(
                        separator: ",")
                case .unavailable(let message):
                    sessionListed = false
                    discoveryDetail = message
                }
            } else {
                sessionListed = false
                discoveryDetail = "tmux executable unresolved"
            }
            let status = attachmentCleared && sessionListed ? "ok" : "failed"
            writeSessionSmokeResult(
                resultPath,
                result: "\(status) tmux-reattach attached=yes descriptor=yes alternate=yes "
                    + "primary-restored=yes nvim-cwd=yes nvim-split-scroll=3x "
                    + "local-list=\(sessionListed ? "yes" : "no") "
                    + "explicit-detach-clears=\(attachmentCleared ? "yes" : "no") "
                    + "discovery=\(discoveryDetail)\n"
            )
        }

        func applyMissingTmuxReattachSmokeScenario(
            resultPath: String,
            sessionName: String,
            socketPath: String
        ) {
            let attachment = NativeTmuxAttachment(
                sessionName: sessionName,
                socketPath: socketPath
            )
            guard let validated = validatedTmuxAttachment(attachment) else {
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-reattach-missing invalid-descriptor\n"
                )
                return
            }
            pendingTmuxReattach = validated
            schedulePendingTmuxReattach()
            waitForMissingTmuxReattach(resultPath, retries: 40)
        }

        func waitForMissingTmuxReattach(_ resultPath: String, retries: Int) {
            let terminalText =
                activePaneId
                .flatMap { paneStore.runtimes[$0] as? RustTerminalPane }?
                .controlScreenText() ?? ""
            let errorVisible = terminalText.contains("can't find session")
            let attachmentCleared = currentSessionState()?.tmuxAttachment == nil
            guard tmuxSession == nil, errorVisible, attachmentCleared else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForMissingTmuxReattach(resultPath, retries: retries - 1)
                    }
                } else {
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-reattach-missing error-visible="
                            + "\(errorVisible ? "yes" : "no")\n"
                    )
                }
                return
            }
            writeSessionSmokeResult(
                resultPath,
                result: "ok tmux-reattach-missing error-visible=yes shell-restored=yes\n"
            )
        }

    }
#endif

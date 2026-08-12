import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
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
                _ = session.gateway.tmuxCommand("detach-client")
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-reattach topology-or-descriptor\n"
                )
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
            guard let pane = activePaneId.flatMap({ paneStore.runtimes[$0] as? RustTmuxPane })
            else {
                _ = session.gateway.tmuxCommand("detach-client")
                writeSessionSmokeResult(resultPath, result: "failed tmux-reattach active-pane=no\n")
                return
            }
            let initialFrames = metalView.skiaFrames()
            guard pane.writeThroughTmux(Data([4])) else {
                _ = session.gateway.tmuxCommand("detach-client")
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-reattach nvim-scroll-input=no\n")
                return
            }
            waitForTmuxReattachScroll(
                resultPath,
                attachment: attachment,
                pane: pane,
                initialFrames: initialFrames,
                topMarker: expectedContent,
                retries: 40
            )
        }

        func waitForTmuxReattachScroll(
            _ resultPath: String,
            attachment: NativeTmuxAttachment,
            pane: RustTmuxPane,
            initialFrames: Int,
            topMarker: String,
            retries: Int
        ) {
            let frames = metalView.skiaFrames()
            let position = abs(pane.rendererScrollPosition())
            let scrolled = !pane.controlScreenText().contains(topMarker)
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
                            topMarker: topMarker,
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self, weak pane] in
                guard let self, let pane else {
                    return
                }
                self.verifyTmuxReattachScrollProgress(
                    resultPath,
                    attachment: attachment,
                    pane: pane,
                    initialFrames: frames,
                    initialPosition: position
                )
            }
        }

        func verifyTmuxReattachScrollProgress(
            _ resultPath: String,
            attachment: NativeTmuxAttachment,
            pane: RustTmuxPane,
            initialFrames: Int,
            initialPosition: Double
        ) {
            let frames = metalView.skiaFrames()
            let position = abs(pane.rendererScrollPosition())
            guard frames > initialFrames, position < initialPosition else {
                _ = tmuxSession?.gateway.tmuxCommand("detach-client")
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed tmux-reattach nvim-scroll-progress=no "
                        + "frames=\(frames - initialFrames) "
                        + "position=\(initialPosition)->\(position)\n"
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
                    + "primary-restored=yes nvim-scroll=yes "
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

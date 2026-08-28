import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func beginTmuxSmokePaneDrag(_ resultPath: String) {
            guard let tab = lastSnapshot?.tabs.first,
                tab.panes.count == 2,
                let sourcePaneId = activePaneId,
                let targetPaneId = tab.panes.first(where: { $0 != sourcePaneId }),
                let sourceFrame = terminalTextView.paneBounds[sourcePaneId],
                let targetFrame = terminalTextView.paneBounds[targetPaneId],
                let sourceRuntime = paneStore.runtimes[sourcePaneId],
                let targetRuntime = paneStore.runtimes[targetPaneId],
                let noChangePosition = NativePaneDropPosition.allCases.first(where: {
                    $0 != .center
                        && nativePaneEffectiveDropPosition(
                            in: tab.layout,
                            sourcePaneId: sourcePaneId,
                            targetPaneId: targetPaneId,
                            position: $0
                        ) == nil
                }),
                terminalTextView.paneDragHandlesReadyForSmoke()
            else {
                failTmuxPaneDrag(resultPath, phase: "ready")
                return
            }
            let runtimeIdentities = [
                sourcePaneId: ObjectIdentifier(sourceRuntime),
                targetPaneId: ObjectIdentifier(targetRuntime),
            ]
            guard
                terminalTextView.simulatePaneNoChangeDragForSmoke(
                    sourcePaneId: sourcePaneId,
                    targetPaneId: targetPaneId,
                    position: noChangePosition
                )
            else {
                failTmuxPaneDrag(resultPath, phase: "no-change-preview")
                return
            }
            waitForTmuxPaneDragNoChange(
                resultPath,
                sourcePaneId: sourcePaneId,
                targetPaneId: targetPaneId,
                noChangePosition: noChangePosition,
                originalSourceFrame: sourceFrame,
                originalTargetFrame: targetFrame,
                runtimeIdentities: runtimeIdentities,
                retries: 40
            )
        }

        private func waitForTmuxPaneDragNoChange(
            _ resultPath: String,
            sourcePaneId: Int,
            targetPaneId: Int,
            noChangePosition: NativePaneDropPosition,
            originalSourceFrame: NSRect,
            originalTargetFrame: NSRect,
            runtimeIdentities: [Int: ObjectIdentifier],
            retries: Int
        ) {
            drainTerminalPanes()
            let sourceFrame = terminalTextView.paneBounds[sourcePaneId]
            let targetFrame = terminalTextView.paneBounds[targetPaneId]
            let layout = lastSnapshot?.tabs.first(where: {
                $0.panes.contains(sourcePaneId) && $0.panes.contains(targetPaneId)
            })?.layout
            let unchanged =
                sourceFrame.map { tmuxPaneDragFramesMatch($0, originalSourceFrame) } == true
                && targetFrame.map { tmuxPaneDragFramesMatch($0, originalTargetFrame) } == true
                && layout.map {
                    nativePaneEffectiveDropPosition(
                        in: $0,
                        sourcePaneId: sourcePaneId,
                        targetPaneId: targetPaneId,
                        position: noChangePosition
                    ) == nil
                } == true
                && tmuxPaneDragRuntimeIdentities(Array(runtimeIdentities.keys))
                    == runtimeIdentities
                && terminalTextView.paneDragInteraction.settledForSmoke()
            guard unchanged else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTmuxPaneDragNoChange(
                            resultPath,
                            sourcePaneId: sourcePaneId,
                            targetPaneId: targetPaneId,
                            noChangePosition: noChangePosition,
                            originalSourceFrame: originalSourceFrame,
                            originalTargetFrame: originalTargetFrame,
                            runtimeIdentities: runtimeIdentities,
                            retries: retries - 1
                        )
                    }
                } else {
                    failTmuxPaneDrag(resultPath, phase: "no-change-layout")
                }
                return
            }
            guard
                terminalTextView.simulatePaneDragForSmoke(
                    sourcePaneId: sourcePaneId,
                    targetPaneId: targetPaneId,
                    position: .center
                )
            else {
                failTmuxPaneDrag(resultPath, phase: "center-command")
                return
            }
            waitForTmuxPaneDragCenter(
                resultPath,
                sourcePaneId: sourcePaneId,
                targetPaneId: targetPaneId,
                originalSourceFrame: originalSourceFrame,
                originalTargetFrame: originalTargetFrame,
                runtimeIdentities: runtimeIdentities,
                retries: 40
            )
        }

        private func waitForTmuxPaneDragCenter(
            _ resultPath: String,
            sourcePaneId: Int,
            targetPaneId: Int,
            originalSourceFrame: NSRect,
            originalTargetFrame: NSRect,
            runtimeIdentities: [Int: ObjectIdentifier],
            retries: Int
        ) {
            drainTerminalPanes()
            let sourceFrame = terminalTextView.paneBounds[sourcePaneId]
            let targetFrame = terminalTextView.paneBounds[targetPaneId]
            let ready =
                activePaneId == sourcePaneId
                && sourceFrame.map { tmuxPaneDragFramesMatch($0, originalTargetFrame) } == true
                && targetFrame.map { tmuxPaneDragFramesMatch($0, originalSourceFrame) } == true
                && tmuxPaneDragRuntimeIdentities(Array(runtimeIdentities.keys))
                    == runtimeIdentities
                && terminalTextView.paneDragInteraction.settledForSmoke()
            guard ready else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTmuxPaneDragCenter(
                            resultPath,
                            sourcePaneId: sourcePaneId,
                            targetPaneId: targetPaneId,
                            originalSourceFrame: originalSourceFrame,
                            originalTargetFrame: originalTargetFrame,
                            runtimeIdentities: runtimeIdentities,
                            retries: retries - 1
                        )
                    }
                } else {
                    failTmuxPaneDrag(resultPath, phase: "center-layout")
                }
                return
            }
            guard
                terminalTextView.simulatePaneDragForSmoke(
                    sourcePaneId: sourcePaneId,
                    targetPaneId: targetPaneId,
                    position: .bottom
                )
            else {
                failTmuxPaneDrag(resultPath, phase: "edge-command")
                return
            }
            waitForTmuxPaneDragEdge(
                resultPath,
                sourcePaneId: sourcePaneId,
                targetPaneId: targetPaneId,
                runtimeIdentities: runtimeIdentities,
                retries: 40
            )
        }

        private func waitForTmuxPaneDragEdge(
            _ resultPath: String,
            sourcePaneId: Int,
            targetPaneId: Int,
            runtimeIdentities: [Int: ObjectIdentifier],
            retries: Int
        ) {
            drainTerminalPanes()
            let sourceFrame = terminalTextView.paneBounds[sourcePaneId]
            let targetFrame = terminalTextView.paneBounds[targetPaneId]
            let ready =
                activePaneId == sourcePaneId
                && sourceFrame.map { source in
                    targetFrame.map { source.minY >= $0.maxY - 1 } == true
                } == true
                && tmuxPaneDragRuntimeIdentities(Array(runtimeIdentities.keys))
                    == runtimeIdentities
                && terminalTextView.paneDragInteraction.settledForSmoke()
            guard ready else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTmuxPaneDragEdge(
                            resultPath,
                            sourcePaneId: sourcePaneId,
                            targetPaneId: targetPaneId,
                            runtimeIdentities: runtimeIdentities,
                            retries: retries - 1
                        )
                    }
                } else {
                    failTmuxPaneDrag(resultPath, phase: "edge-layout")
                }
                return
            }
            continueTmuxSmokeAfterDividerResize(resultPath)
        }

        private func tmuxPaneDragRuntimeIdentities(_ paneIds: [Int])
            -> [Int: ObjectIdentifier]
        {
            paneIds.reduce(into: [:]) { identities, paneId in
                if let pane = paneStore.runtimes[paneId] {
                    identities[paneId] = ObjectIdentifier(pane)
                }
            }
        }

        private func tmuxPaneDragFramesMatch(_ first: NSRect, _ second: NSRect) -> Bool {
            abs(first.minX - second.minX) <= 1
                && abs(first.minY - second.minY) <= 1
                && abs(first.width - second.width) <= 1
                && abs(first.height - second.height) <= 1
        }

        private func failTmuxPaneDrag(_ resultPath: String, phase: String) {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            writeSessionSmokeResult(resultPath, result: "failed tmux-native pane-dnd=\(phase)\n")
        }
    }
#endif

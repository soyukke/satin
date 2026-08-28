import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func applyPaneDragSmokeScenario(resultPath: String) {
            guard tmuxSession == nil,
                let initial = core.snapshot(),
                let tab = initial.tabs.first(where: { $0.index == initial.active_tab }),
                tab.panes.count == 1
            else {
                writePaneDragSmokeFailure(resultPath, phase: "initial-layout")
                return
            }
            let sourcePaneId = tab.active_pane
            guard let middlePaneId = core.splitActive(axis: ffiSplitVertical) else {
                writePaneDragSmokeFailure(resultPath, phase: "split")
                return
            }
            _ = core.resizeSplit(
                firstPaneId: sourcePaneId,
                secondPaneId: middlePaneId,
                ratio: 0.36
            )
            syncFromCore()
            waitForPaneDragSmokeNoChangeReady(
                resultPath: resultPath,
                sourcePaneId: sourcePaneId,
                middlePaneId: middlePaneId,
                retries: 40
            )
        }

        private func waitForPaneDragSmokeNoChangeReady(
            resultPath: String,
            sourcePaneId: Int,
            middlePaneId: Int,
            retries: Int
        ) {
            drainTerminalPanes()
            view.layoutSubtreeIfNeeded()
            guard terminalTextView.paneDragHandlesReadyForSmoke(),
                let sourceFrame = terminalTextView.paneBounds[sourcePaneId],
                let middleFrame = terminalTextView.paneBounds[middlePaneId],
                paneStore.runtimes[sourcePaneId] != nil,
                paneStore.runtimes[middlePaneId] != nil
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForPaneDragSmokeNoChangeReady(
                            resultPath: resultPath,
                            sourcePaneId: sourcePaneId,
                            middlePaneId: middlePaneId,
                            retries: retries - 1
                        )
                    }
                } else {
                    writePaneDragSmokeFailure(resultPath, phase: "no-change-handles")
                }
                return
            }
            let runtimeIdentities = paneRuntimeIdentitiesForSmoke([
                sourcePaneId, middlePaneId,
            ])
            guard
                terminalTextView.simulatePaneNoChangeDragForSmoke(
                    sourcePaneId: sourcePaneId,
                    targetPaneId: middlePaneId,
                    position: .left
                )
            else {
                writePaneDragSmokeFailure(resultPath, phase: "no-change-preview")
                return
            }
            waitForPaneDragSmokeNoChange(
                resultPath: resultPath,
                sourcePaneId: sourcePaneId,
                middlePaneId: middlePaneId,
                originalSourceFrame: sourceFrame,
                originalMiddleFrame: middleFrame,
                runtimeIdentities: runtimeIdentities,
                retries: 40
            )
        }

        private func waitForPaneDragSmokeNoChange(
            resultPath: String,
            sourcePaneId: Int,
            middlePaneId: Int,
            originalSourceFrame: NSRect,
            originalMiddleFrame: NSRect,
            runtimeIdentities: [Int: ObjectIdentifier],
            retries: Int
        ) {
            drainTerminalPanes()
            let tab = core.snapshot()?.tabs.first
            let sourceFrame = terminalTextView.paneBounds[sourcePaneId]
            let middleFrame = terminalTextView.paneBounds[middlePaneId]
            let unchanged =
                tab?.panes == [sourcePaneId, middlePaneId]
                && tab?.layout.axis == "vertical"
                && tab?.layout.first?.pane_id == sourcePaneId
                && tab?.layout.second?.pane_id == middlePaneId
                && tab?.layout.ratio.map { abs($0 - 0.36) < 0.0001 } == true
                && sourceFrame.map { paneDragFramesMatch($0, originalSourceFrame) } == true
                && middleFrame.map { paneDragFramesMatch($0, originalMiddleFrame) } == true
                && paneRuntimeIdentitiesForSmoke(Array(runtimeIdentities.keys))
                    == runtimeIdentities
                && terminalTextView.paneDragInteraction.settledForSmoke()
            guard unchanged else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForPaneDragSmokeNoChange(
                            resultPath: resultPath,
                            sourcePaneId: sourcePaneId,
                            middlePaneId: middlePaneId,
                            originalSourceFrame: originalSourceFrame,
                            originalMiddleFrame: originalMiddleFrame,
                            runtimeIdentities: runtimeIdentities,
                            retries: retries - 1
                        )
                    }
                } else {
                    writePaneDragSmokeFailure(resultPath, phase: "no-change-layout")
                }
                return
            }
            guard core.selectPane(middlePaneId),
                let targetPaneId = core.splitActive(axis: ffiSplitVertical)
            else {
                writePaneDragSmokeFailure(resultPath, phase: "third-split")
                return
            }
            _ = core.resizeSplit(
                firstPaneId: middlePaneId,
                secondPaneId: targetPaneId,
                ratio: 0.62
            )
            syncFromCore()
            waitForPaneDragSmokeReady(
                resultPath: resultPath,
                sourcePaneId: sourcePaneId,
                middlePaneId: middlePaneId,
                targetPaneId: targetPaneId,
                retries: 40
            )
        }

        private func waitForPaneDragSmokeReady(
            resultPath: String,
            sourcePaneId: Int,
            middlePaneId: Int,
            targetPaneId: Int,
            retries: Int
        ) {
            drainTerminalPanes()
            view.layoutSubtreeIfNeeded()
            guard terminalTextView.paneDragHandlesReadyForSmoke(),
                let sourceFrame = terminalTextView.paneBounds[sourcePaneId],
                let middleFrame = terminalTextView.paneBounds[middlePaneId],
                let targetFrame = terminalTextView.paneBounds[targetPaneId],
                paneStore.runtimes[sourcePaneId] != nil,
                paneStore.runtimes[middlePaneId] != nil,
                paneStore.runtimes[targetPaneId] != nil
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForPaneDragSmokeReady(
                            resultPath: resultPath,
                            sourcePaneId: sourcePaneId,
                            middlePaneId: middlePaneId,
                            targetPaneId: targetPaneId,
                            retries: retries - 1
                        )
                    }
                } else {
                    writePaneDragSmokeFailure(resultPath, phase: "drag-handles")
                }
                return
            }
            let runtimeIdentities = paneRuntimeIdentitiesForSmoke([
                sourcePaneId, middlePaneId, targetPaneId,
            ])
            guard
                terminalTextView.simulatePaneNoChangeDragForSmoke(
                    sourcePaneId: middlePaneId,
                    targetPaneId: sourcePaneId,
                    position: .right
                )
            else {
                writePaneDragSmokeFailure(resultPath, phase: "nested-no-change-preview")
                return
            }
            waitForPaneDragSmokeNestedNoChange(
                resultPath: resultPath,
                sourcePaneId: sourcePaneId,
                middlePaneId: middlePaneId,
                targetPaneId: targetPaneId,
                originalSourceFrame: sourceFrame,
                originalMiddleFrame: middleFrame,
                originalTargetFrame: targetFrame,
                runtimeIdentities: runtimeIdentities,
                retries: 40
            )
        }

        private func waitForPaneDragSmokeNestedNoChange(
            resultPath: String,
            sourcePaneId: Int,
            middlePaneId: Int,
            targetPaneId: Int,
            originalSourceFrame: NSRect,
            originalMiddleFrame: NSRect,
            originalTargetFrame: NSRect,
            runtimeIdentities: [Int: ObjectIdentifier],
            retries: Int
        ) {
            drainTerminalPanes()
            let tab = core.snapshot()?.tabs.first
            let layout = tab?.layout
            let nested = layout?.second
            let unchanged =
                tab?.panes == [sourcePaneId, middlePaneId, targetPaneId]
                && layout?.axis == "vertical"
                && layout?.first?.pane_id == sourcePaneId
                && nested?.axis == "vertical"
                && nested?.first?.pane_id == middlePaneId
                && nested?.second?.pane_id == targetPaneId
                && terminalTextView.paneBounds[sourcePaneId].map {
                    paneDragFramesMatch($0, originalSourceFrame)
                } == true
                && terminalTextView.paneBounds[middlePaneId].map {
                    paneDragFramesMatch($0, originalMiddleFrame)
                } == true
                && terminalTextView.paneBounds[targetPaneId].map {
                    paneDragFramesMatch($0, originalTargetFrame)
                } == true
                && paneRuntimeIdentitiesForSmoke(Array(runtimeIdentities.keys))
                    == runtimeIdentities
                && terminalTextView.paneDragInteraction.settledForSmoke()
            guard unchanged else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForPaneDragSmokeNestedNoChange(
                            resultPath: resultPath,
                            sourcePaneId: sourcePaneId,
                            middlePaneId: middlePaneId,
                            targetPaneId: targetPaneId,
                            originalSourceFrame: originalSourceFrame,
                            originalMiddleFrame: originalMiddleFrame,
                            originalTargetFrame: originalTargetFrame,
                            runtimeIdentities: runtimeIdentities,
                            retries: retries - 1
                        )
                    }
                } else {
                    writePaneDragSmokeFailure(resultPath, phase: "nested-no-change-layout")
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
                writePaneDragSmokeFailure(resultPath, phase: "center-drop")
                return
            }
            waitForPaneDragSmokeCenter(
                resultPath: resultPath,
                sourcePaneId: sourcePaneId,
                middlePaneId: middlePaneId,
                targetPaneId: targetPaneId,
                originalSourceFrame: originalSourceFrame,
                originalTargetFrame: originalTargetFrame,
                runtimeIdentities: runtimeIdentities,
                retries: 40
            )
        }

        private func waitForPaneDragSmokeCenter(
            resultPath: String,
            sourcePaneId: Int,
            middlePaneId: Int,
            targetPaneId: Int,
            originalSourceFrame: NSRect,
            originalTargetFrame: NSRect,
            runtimeIdentities: [Int: ObjectIdentifier],
            retries: Int
        ) {
            drainTerminalPanes()
            let snapshot = core.snapshot()?.tabs.first
            let sourceFrame = terminalTextView.paneBounds[sourcePaneId]
            let targetFrame = terminalTextView.paneBounds[targetPaneId]
            let ready =
                snapshot?.active_pane == sourcePaneId
                && snapshot?.layout.first?.pane_id == targetPaneId
                && snapshot?.layout.second?.second?.pane_id == sourcePaneId
                && sourceFrame.map { paneDragFramesMatch($0, originalTargetFrame) } == true
                && targetFrame.map { paneDragFramesMatch($0, originalSourceFrame) } == true
                && paneRuntimeIdentitiesForSmoke(Array(runtimeIdentities.keys))
                    == runtimeIdentities
                && terminalTextView.paneDragInteraction.settledForSmoke()
            guard ready else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForPaneDragSmokeCenter(
                            resultPath: resultPath,
                            sourcePaneId: sourcePaneId,
                            middlePaneId: middlePaneId,
                            targetPaneId: targetPaneId,
                            originalSourceFrame: originalSourceFrame,
                            originalTargetFrame: originalTargetFrame,
                            runtimeIdentities: runtimeIdentities,
                            retries: retries - 1
                        )
                    }
                } else {
                    writePaneDragSmokeFailure(resultPath, phase: "center-layout")
                }
                return
            }
            guard
                terminalTextView.simulatePaneDragForSmoke(
                    sourcePaneId: sourcePaneId,
                    targetPaneId: middlePaneId,
                    position: .bottom
                )
            else {
                writePaneDragSmokeFailure(resultPath, phase: "edge-drop")
                return
            }
            waitForPaneDragSmokeEdge(
                resultPath: resultPath,
                sourcePaneId: sourcePaneId,
                middlePaneId: middlePaneId,
                targetPaneId: targetPaneId,
                runtimeIdentities: runtimeIdentities,
                retries: 40
            )
        }

        private func waitForPaneDragSmokeEdge(
            resultPath: String,
            sourcePaneId: Int,
            middlePaneId: Int,
            targetPaneId: Int,
            runtimeIdentities: [Int: ObjectIdentifier],
            retries: Int
        ) {
            drainTerminalPanes()
            let tab = core.snapshot()?.tabs.first
            let layout = tab?.layout
            let nested = layout?.second
            let sourceFrame = terminalTextView.paneBounds[sourcePaneId]
            let middleFrame = terminalTextView.paneBounds[middlePaneId]
            let ready =
                tab?.active_pane == sourcePaneId
                && tab?.panes == [targetPaneId, middlePaneId, sourcePaneId]
                && layout?.axis == "vertical"
                && layout?.first?.pane_id == targetPaneId
                && nested?.axis == "horizontal"
                && nested?.first?.pane_id == middlePaneId
                && nested?.second?.pane_id == sourcePaneId
                && sourceFrame.map { source in
                    middleFrame.map { source.minY >= $0.maxY - 1 } == true
                } == true
                && paneRuntimeIdentitiesForSmoke(Array(runtimeIdentities.keys))
                    == runtimeIdentities
                && terminalTextView.paneDragInteraction.settledForSmoke()
            guard ready else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForPaneDragSmokeEdge(
                            resultPath: resultPath,
                            sourcePaneId: sourcePaneId,
                            middlePaneId: middlePaneId,
                            targetPaneId: targetPaneId,
                            runtimeIdentities: runtimeIdentities,
                            retries: retries - 1
                        )
                    }
                } else {
                    writePaneDragSmokeFailure(resultPath, phase: "edge-layout")
                }
                return
            }
            guard
                terminalTextView.simulatePaneDragCancellationForSmoke(
                    sourcePaneId: sourcePaneId
                )
            else {
                writePaneDragSmokeFailure(resultPath, phase: "cancel-start")
                return
            }
            waitForPaneDragSmokeCancellation(
                resultPath: resultPath,
                sourcePaneId: sourcePaneId,
                middlePaneId: middlePaneId,
                targetPaneId: targetPaneId,
                runtimeIdentities: runtimeIdentities,
                retries: 40
            )
        }

        private func waitForPaneDragSmokeCancellation(
            resultPath: String,
            sourcePaneId: Int,
            middlePaneId: Int,
            targetPaneId: Int,
            runtimeIdentities: [Int: ObjectIdentifier],
            retries: Int
        ) {
            drainTerminalPanes()
            let tab = core.snapshot()?.tabs.first
            let layout = tab?.layout
            let nested = layout?.second
            let unchanged =
                tab?.active_pane == sourcePaneId
                && tab?.panes == [targetPaneId, middlePaneId, sourcePaneId]
                && layout?.first?.pane_id == targetPaneId
                && nested?.first?.pane_id == middlePaneId
                && nested?.second?.pane_id == sourcePaneId
                && paneRuntimeIdentitiesForSmoke(Array(runtimeIdentities.keys))
                    == runtimeIdentities
                && terminalTextView.paneDragInteraction.settledForSmoke()
            guard unchanged else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForPaneDragSmokeCancellation(
                            resultPath: resultPath,
                            sourcePaneId: sourcePaneId,
                            middlePaneId: middlePaneId,
                            targetPaneId: targetPaneId,
                            runtimeIdentities: runtimeIdentities,
                            retries: retries - 1
                        )
                    }
                } else {
                    writePaneDragSmokeFailure(resultPath, phase: "cancel-layout")
                }
                return
            }
            writeSessionSmokeResult(
                resultPath,
                result: "ok pane-dnd local=noop+center+edge handle=band preview=animated "
                    + "no-change-highlight=none no-change-adjacency=both "
                    + "runtime=retained layout=reparented "
                    + "cancel=noop fallback=none\n"
            )
        }

        private func paneRuntimeIdentitiesForSmoke(_ paneIds: [Int])
            -> [Int: ObjectIdentifier]
        {
            paneIds.reduce(into: [:]) { identities, paneId in
                if let pane = paneStore.runtimes[paneId] {
                    identities[paneId] = ObjectIdentifier(pane)
                }
            }
        }

        private func paneDragFramesMatch(_ first: NSRect, _ second: NSRect) -> Bool {
            abs(first.minX - second.minX) <= 1
                && abs(first.minY - second.minY) <= 1
                && abs(first.width - second.width) <= 1
                && abs(first.height - second.height) <= 1
        }

        private func writePaneDragSmokeFailure(_ resultPath: String, phase: String) {
            writeSessionSmokeResult(resultPath, result: "failed pane-dnd phase=\(phase)\n")
        }
    }
#endif

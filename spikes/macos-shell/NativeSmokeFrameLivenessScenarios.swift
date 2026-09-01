import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    private let frameLivenessIterations = 80
    private let frameLivenessRetries = 40

    extension TerminalShellViewController {
        func applyFrameLivenessSmokeScenario(resultPath: String) {
            core.newTab()
            syncFromCore()
            guard let snapshot = core.snapshot(), snapshot.tabs.count == 2 else {
                writeFrameLivenessFailure(
                    resultPath,
                    phase: "setup",
                    iteration: 0,
                    detail: "tabs=\(core.snapshot()?.tabs.count ?? 0)"
                )
                return
            }
            let paneIds = snapshot.tabs.map(\.active_pane)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.waitForFrameLivenessIdle(
                    resultPath,
                    paneIds: paneIds,
                    retries: frameLivenessRetries * 2
                )
            }
        }

        private func waitForFrameLivenessIdle(
            _ resultPath: String,
            paneIds: [Int],
            retries: Int
        ) {
            drainTerminalPanes()
            let revisions = metalView.frameRequestRevisionSnapshot()
            let idle =
                revisions.requested == revisions.rendered
                && metalView.pendingSkiaFrameDelayMs() == UInt64.max
            guard idle else {
                guard retries > 0 else {
                    writeFrameLivenessFailure(
                        resultPath,
                        phase: "idle",
                        iteration: 0,
                        detail: "delay=\(metalView.pendingSkiaFrameDelayMs())"
                    )
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                    self?.waitForFrameLivenessIdle(
                        resultPath,
                        paneIds: paneIds,
                        retries: retries - 1
                    )
                }
                return
            }
            beginHiddenPaneAnimationCheck(resultPath, paneIds: paneIds)
        }

        private func beginHiddenPaneAnimationCheck(
            _ resultPath: String,
            paneIds: [Int]
        ) {
            selectTab(0)
            metalView.resetSkiaFrameCount()
            metalView.resetPresentedFrameCount()
            terminalTextView.insertText(
                "printf 'SATIN_HIDDEN_SCROLL_%03d\\n' {1..240}\r",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            waitForVisiblePaneAnimation(
                resultPath,
                paneIds: paneIds,
                targetRevision: nil,
                retries: frameLivenessRetries * 2
            )
        }

        private func waitForVisiblePaneAnimation(
            _ resultPath: String,
            paneIds: [Int],
            targetRevision: UInt64?,
            retries: Int
        ) {
            drainTerminalPanes()
            let markerVisible =
                (terminalPane(for: paneIds[0]) as? RustTerminalPane)?
                .controlScreenText()
                .contains("SATIN_HIDDEN_SCROLL_240") == true
            let revisions = metalView.frameRequestRevisionSnapshot()
            let presented = metalView.presentedFrameSnapshot()
            let target = targetRevision ?? (markerVisible ? revisions.requested : nil)
            let animationRendered =
                markerVisible
                && target.map { presented.revision >= $0 } == true
                && presented.count > 0
                && metalView.skiaFrames() > 0
                && metalView.pendingSkiaFrameDelayMs() == 0
            guard animationRendered else {
                guard retries > 0 else {
                    writeFrameLivenessFailure(
                        resultPath,
                        phase: "visible-animation",
                        iteration: 0,
                        detail: "marker=\(markerVisible) "
                            + "delay=\(metalView.pendingSkiaFrameDelayMs())"
                    )
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                    self?.waitForVisiblePaneAnimation(
                        resultPath,
                        paneIds: paneIds,
                        targetRevision: target,
                        retries: retries - 1
                    )
                }
                return
            }

            selectTab(1)
            waitForHiddenPaneAnimationIdle(
                resultPath,
                paneIds: paneIds,
                retries: frameLivenessRetries * 2
            )
        }

        private func waitForHiddenPaneAnimationIdle(
            _ resultPath: String,
            paneIds: [Int],
            retries: Int
        ) {
            drainTerminalPanes()
            let revisions = metalView.frameRequestRevisionSnapshot()
            let presented = metalView.presentedFrameSnapshot()
            let idle =
                core.snapshot()?.active_tab == 1
                && activePaneId == paneIds[1]
                && revisions.requested == revisions.rendered
                && presented.revision >= revisions.requested
                && metalView.pendingSkiaFrameDelayMs() == UInt64.max
            guard idle else {
                guard retries > 0 else {
                    writeFrameLivenessFailure(
                        resultPath,
                        phase: "hidden-animation",
                        iteration: 0,
                        detail: "delay=\(metalView.pendingSkiaFrameDelayMs()) "
                            + "active=\(core.snapshot()?.active_tab ?? -1)"
                    )
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                    self?.waitForHiddenPaneAnimationIdle(
                        resultPath,
                        paneIds: paneIds,
                        retries: retries - 1
                    )
                }
                return
            }

            metalView.resetSkiaFrameCount()
            metalView.resetPresentedFrameCount()
            metalView.armFrameRequestInterleaveForSmoke()
            metalView.requestFrame()
            waitForInterleavedFrameRequest(
                resultPath,
                paneIds: paneIds,
                targetRevision: nil,
                retries: frameLivenessRetries
            )
        }

        private func waitForInterleavedFrameRequest(
            _ resultPath: String,
            paneIds: [Int],
            targetRevision: UInt64?,
            retries: Int
        ) {
            let target = targetRevision ?? metalView.interleavedFrameRequestRevisionForSmoke()
            let presented = metalView.presentedFrameSnapshot()
            let rendered =
                target.map { presented.revision >= $0 } == true
                && presented.count >= 2
                && metalView.skiaFrames() >= 2
            guard rendered else {
                guard retries > 0 else {
                    writeFrameLivenessFailure(
                        resultPath,
                        phase: "interleave",
                        iteration: 0,
                        detail: "revision=\(target.map { String($0) } ?? "none") "
                            + "frames=\(metalView.skiaFrames())"
                    )
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                    self?.waitForInterleavedFrameRequest(
                        resultPath,
                        paneIds: paneIds,
                        targetRevision: target,
                        retries: retries - 1
                    )
                }
                return
            }
            beginFrameLivenessIteration(
                resultPath,
                paneIds: paneIds,
                iteration: 0,
                presentedFrames: presented.count
            )
        }

        private func beginFrameLivenessIteration(
            _ resultPath: String,
            paneIds: [Int],
            iteration: Int,
            presentedFrames: Int
        ) {
            guard iteration < frameLivenessIterations else {
                let result =
                    "ok frame-liveness iterations=\(frameLivenessIterations) "
                    + "race=covered hidden-animation=idle tabs=presented input=presented "
                    + "frames=\(presentedFrames) "
                    + metalView.resizeDiagnosticsSummary() + "\n"
                writeSessionSmokeResult(resultPath, result: result)
                return
            }
            let tabIndex = iteration % paneIds.count
            let previousRevision = metalView.frameRequestRevisionSnapshot().requested
            metalView.resetSkiaFrameCount()
            metalView.resetPresentedFrameCount()
            selectTab(tabIndex)
            let targetRevision = metalView.frameRequestRevisionSnapshot().requested
            guard targetRevision > previousRevision else {
                writeFrameLivenessFailure(
                    resultPath,
                    phase: "tab-request",
                    iteration: iteration,
                    detail: "target=\(tabIndex) revision=\(targetRevision)"
                )
                return
            }
            waitForFrameLivenessTab(
                resultPath,
                paneIds: paneIds,
                iteration: iteration,
                tabIndex: tabIndex,
                targetRevision: targetRevision,
                presentedFrames: presentedFrames,
                retries: frameLivenessRetries
            )
        }

        private func waitForFrameLivenessTab(
            _ resultPath: String,
            paneIds: [Int],
            iteration: Int,
            tabIndex: Int,
            targetRevision: UInt64,
            presentedFrames: Int,
            retries: Int
        ) {
            drainTerminalPanes()
            let presented = metalView.presentedFrameSnapshot()
            let switched =
                core.snapshot()?.active_tab == tabIndex
                && activePaneId == paneIds[tabIndex]
                && metalView.skiaFrames() > 0
                && presented.count > 0
                && presented.revision >= targetRevision
            guard switched else {
                guard retries > 0 else {
                    writeFrameLivenessFailure(
                        resultPath,
                        phase: "tab",
                        iteration: iteration,
                        detail: "target=\(tabIndex) active=\(core.snapshot()?.active_tab ?? -1) "
                            + "frames=\(metalView.skiaFrames()) revision=\(targetRevision)"
                    )
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                    self?.waitForFrameLivenessTab(
                        resultPath,
                        paneIds: paneIds,
                        iteration: iteration,
                        tabIndex: tabIndex,
                        targetRevision: targetRevision,
                        presentedFrames: presentedFrames,
                        retries: retries - 1
                    )
                }
                return
            }

            let baselineFrames = presented.count
            let marker = "SATIN_FRAME_LIVENESS_\(iteration)"
            terminalTextView.insertText(
                "printf '\(marker)\\n'\r",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            waitForFrameLivenessInput(
                resultPath,
                paneIds: paneIds,
                iteration: iteration,
                marker: marker,
                baselineFrames: baselineFrames,
                targetRevision: nil,
                presentedFrames: presentedFrames,
                retries: frameLivenessRetries
            )
        }

        private func waitForFrameLivenessInput(
            _ resultPath: String,
            paneIds: [Int],
            iteration: Int,
            marker: String,
            baselineFrames: Int,
            targetRevision: UInt64?,
            presentedFrames: Int,
            retries: Int
        ) {
            drainTerminalPanes()
            let pane = terminalPane(for: paneIds[iteration % paneIds.count]) as? RustTerminalPane
            let markerVisible = pane?.controlScreenText().contains(marker) == true
            let revisions = metalView.frameRequestRevisionSnapshot()
            let presented = metalView.presentedFrameSnapshot()
            let expectedRevision = targetRevision ?? (markerVisible ? revisions.requested : nil)
            let newFramePresented = presented.count > baselineFrames
            let rendered =
                markerVisible && newFramePresented
                && expectedRevision.map { presented.revision >= $0 } == true
            guard rendered else {
                guard retries > 0 else {
                    writeFrameLivenessFailure(
                        resultPath,
                        phase: "input",
                        iteration: iteration,
                        detail: "marker=\(markerVisible ? "yes" : "no") "
                            + "frames=\(presented.count) baseline=\(baselineFrames) "
                            + "revision=\(expectedRevision.map { String($0) } ?? "none")"
                    )
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                    self?.waitForFrameLivenessInput(
                        resultPath,
                        paneIds: paneIds,
                        iteration: iteration,
                        marker: marker,
                        baselineFrames: baselineFrames,
                        targetRevision: expectedRevision,
                        presentedFrames: presentedFrames,
                        retries: retries - 1
                    )
                }
                return
            }
            beginFrameLivenessIteration(
                resultPath,
                paneIds: paneIds,
                iteration: iteration + 1,
                presentedFrames: presentedFrames + presented.count
            )
        }

        private func writeFrameLivenessFailure(
            _ resultPath: String,
            phase: String,
            iteration: Int,
            detail: String
        ) {
            let result =
                "failed frame-liveness phase=\(phase) iteration=\(iteration) \(detail) "
                + "\(metalView.frameRequestDiagnosticsSummary()) "
                + metalView.resizeDiagnosticsSummary() + "\n"
            writeSessionSmokeResult(resultPath, result: result)
        }
    }
#endif

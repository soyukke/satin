import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    private let frameLivenessIterations = 80
    private let frameLivenessRetries = 40
    // Presented counters advance from CAMetalDrawable presented handlers, so they
    // trail the render pass by a compositor round trip. A loaded CI host needs far
    // more than the render-revision budget before the counters catch up.
    private let frameLivenessPresentationRetries = 120
    private let frameLivenessAnimationRetries = 300
    private var frameLivenessPresentationDeferred = false

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
            frameLivenessPresentationDeferred = false
            let paneIds = snapshot.tabs.map(\.active_pane)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.waitForFrameLivenessIdle(
                    resultPath,
                    paneIds: paneIds,
                    retries: frameLivenessRetries * 2
                )
            }
        }

        // The drawable presented handler runs only where something composites the
        // window: an occluded window never is, and a host without a real display
        // defers the present indefinitely. Wait for presentation for the phase
        // budget, then accept the rendered revision and report the downgrade
        // instead of failing a renderer that did its work.
        private func framesReachedScreen(
            target: UInt64?,
            minimumFrames: Int,
            baselineFrames: Int = 0,
            acceptRenderedFallback: Bool = false
        ) -> Bool {
            guard let target else {
                return false
            }
            let presented = metalView.presentedFrameSnapshot()
            if presented.revision >= target,
                presented.count >= baselineFrames + minimumFrames
            {
                return true
            }
            guard acceptRenderedFallback || !windowComposited() else {
                return false
            }
            let rendered = metalView.frameRequestRevisionSnapshot().rendered >= target
            if rendered {
                frameLivenessPresentationDeferred = true
            }
            return rendered
        }

        private func windowComposited() -> Bool {
            view.window?.occlusionState.contains(.visible) == true
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
            metalView.resetScheduledAnimationFrameCount()
            terminalTextView.insertText(
                "printf 'SATIN_HIDDEN_SCROLL_%03d\\n' {1..240}\r",
                replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            waitForVisiblePaneAnimation(
                resultPath,
                paneIds: paneIds,
                targetRevision: nil,
                retries: frameLivenessAnimationRetries
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
            let target = targetRevision ?? (markerVisible ? revisions.requested : nil)
            // The animation settles before the presented counters catch up on a
            // loaded host, so count the animation frames the renderer scheduled
            // instead of requiring one to still be pending at this very poll.
            let animationFrames = metalView.scheduledAnimationFrames()
            let animationRendered =
                markerVisible
                && framesReachedScreen(
                    target: target,
                    minimumFrames: 1,
                    acceptRenderedFallback: retries == 0
                )
                && metalView.skiaFrames() > 0
                && animationFrames > 0
            guard animationRendered else {
                guard retries > 0 else {
                    writeFrameLivenessFailure(
                        resultPath,
                        phase: "visible-animation",
                        iteration: 0,
                        detail: "marker=\(markerVisible) "
                            + "animation-frames=\(animationFrames) "
                            + "visible=\(windowComposited() ? "yes" : "no") "
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
                retries: frameLivenessPresentationRetries
            )
        }

        private func waitForHiddenPaneAnimationIdle(
            _ resultPath: String,
            paneIds: [Int],
            retries: Int
        ) {
            drainTerminalPanes()
            let revisions = metalView.frameRequestRevisionSnapshot()
            let idle =
                core.snapshot()?.active_tab == 1
                && activePaneId == paneIds[1]
                && revisions.requested == revisions.rendered
                && framesReachedScreen(
                    target: revisions.requested,
                    minimumFrames: 0,
                    acceptRenderedFallback: retries == 0
                )
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
                retries: frameLivenessPresentationRetries
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
                framesReachedScreen(
                    target: target,
                    minimumFrames: 2,
                    acceptRenderedFallback: retries == 0
                )
                && metalView.skiaFrames() >= 2
            guard rendered else {
                guard retries > 0 else {
                    writeFrameLivenessFailure(
                        resultPath,
                        phase: "interleave",
                        iteration: 0,
                        detail: "revision=\(target.map { String($0) } ?? "none") "
                            + "visible=\(windowComposited() ? "yes" : "no") "
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
                    + "window=\(windowComposited() ? "composited" : "occluded") "
                    + "presentation=\(frameLivenessPresentationDeferred ? "deferred" : "presented") "
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
                retries: frameLivenessPresentationRetries
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
                && framesReachedScreen(
                    target: targetRevision,
                    minimumFrames: 1,
                    acceptRenderedFallback: retries == 0
                )
            guard switched else {
                guard retries > 0 else {
                    writeFrameLivenessFailure(
                        resultPath,
                        phase: "tab",
                        iteration: iteration,
                        detail: "target=\(tabIndex) active=\(core.snapshot()?.active_tab ?? -1) "
                            + "visible=\(windowComposited() ? "yes" : "no") "
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
                retries: frameLivenessPresentationRetries
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
            let rendered =
                markerVisible
                && framesReachedScreen(
                    target: expectedRevision,
                    minimumFrames: 1,
                    baselineFrames: baselineFrames,
                    acceptRenderedFallback: retries == 0
                )
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

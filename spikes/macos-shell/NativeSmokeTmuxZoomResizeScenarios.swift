import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func verifyTmuxSmokeFontZoom(
            baselineGrid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int)
        ) -> Bool {
            guard let session = tmuxSession,
                session.nativePaneIds.count == 2,
                let zoomedPaneId = activePaneId,
                let zoomInEvent = tmuxSmokeZoomEvent(increment: true),
                let zoomOutEvent = tmuxSmokeZoomEvent(increment: false)
            else {
                return false
            }
            let paneIds = Array(session.nativePaneIds.values)
            guard paneIds.contains(zoomedPaneId),
                let unchangedPaneId = paneIds.first(where: { $0 != zoomedPaneId })
            else {
                return false
            }
            let baselineSize = terminalTextView.fontSize(nil)
            guard paneIds.allSatisfy({ abs(terminalTextView.fontSize($0) - baselineSize) < 0.01 }),
                terminalTextView.handleCommandKey(zoomInEvent)
            else {
                return false
            }
            let zoomedGrid = tmuxClientGrid()
            guard abs(terminalTextView.fontSize(zoomedPaneId) - baselineSize - 1) < 0.01,
                abs(terminalTextView.fontSize(unchangedPaneId) - baselineSize) < 0.01,
                session.lastClientGrid?.cols == zoomedGrid.cols,
                session.lastClientGrid?.rows == zoomedGrid.rows,
                zoomedGrid.cols == baselineGrid.cols,
                zoomedGrid.rows == baselineGrid.rows,
                terminalTextView.handleCommandKey(zoomOutEvent)
            else {
                return false
            }
            let restoredGrid = tmuxClientGrid()
            return paneIds.allSatisfy({
                abs(terminalTextView.fontSize($0) - baselineSize) < 0.01
            })
                && restoredGrid.cols == baselineGrid.cols
                && restoredGrid.rows == baselineGrid.rows
                && session.lastClientGrid?.cols == restoredGrid.cols
                && session.lastClientGrid?.rows == restoredGrid.rows
        }

        func tmuxSmokeZoomEvent(increment: Bool) -> NSEvent? {
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: increment ? [.command, .shift] : .command,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: view.window?.windowNumber ?? 0,
                context: nil,
                characters: increment ? "+" : "-",
                charactersIgnoringModifiers: increment ? "=" : "-",
                isARepeat: false,
                keyCode: increment ? 24 : 27
            )
        }

        func tmuxZoomResizeSmokeOnly() -> Bool {
            ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_TMUX_SCOPE"]
                == "zoom-resize"
        }

        func beginTmuxZoomResizeSmoke(_ resultPath: String) {
            guard let window = view.window else {
                tmuxSession?.gateway.tmuxCommand("kill-session")
                writeSessionSmokeResult(
                    resultPath, result: "failed tmux-zoom-resize no-window\n")
                return
            }
            metalView.resetResizeDiagnostics()
            resetGeometryResizeDiagnostics()
            let sizes = (0...60).map { step in
                let progress = CGFloat(step) / 60
                return NSSize(
                    width: 780 + 340 * progress,
                    height: 480 + 280 * progress
                )
            }
            applyTerminalResizeSmokeSizes(sizes, to: window) { [weak self] in
                self?.waitForTmuxZoomResizeSmoke(resultPath, retries: 40)
            }
        }

        func waitForTmuxZoomResizeSmoke(_ resultPath: String, retries: Int) {
            let expected = tmuxClientGrid()
            let geometry = geometryResizeDiagnostics()
            let settled =
                lastSnapshot?.tabs.first?.panes.count == 2
                && tmuxSession?.lastClientGrid?.cols == expected.cols
                && tmuxSession?.lastClientGrid?.rows == expected.rows
                && metalView.drawableSizesMatchView()
                && geometry.requests > 1
                && geometry.applications < geometry.requests
            guard settled else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTmuxZoomResizeSmoke(resultPath, retries: retries - 1)
                    }
                } else {
                    tmuxSession?.gateway.tmuxCommand("kill-session")
                    writeSessionSmokeResult(
                        resultPath,
                        result: "failed tmux-zoom-resize settle-timeout "
                            + "geometry=\(geometry.applications)/\(geometry.requests) "
                            + "\(metalView.resizeDiagnosticsSummary())\n"
                    )
                }
                return
            }
            tmuxSession?.gateway.tmuxCommand("kill-session")
            waitForTmuxZoomResizeSmokeExit(
                resultPath,
                diagnostics: "geometry=\(geometry.applications)/\(geometry.requests) "
                    + metalView.resizeDiagnosticsSummary(),
                retries: 30
            )
        }

        func waitForTmuxZoomResizeSmokeExit(
            _ resultPath: String,
            diagnostics: String,
            retries: Int
        ) {
            guard tmuxSession == nil else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTmuxZoomResizeSmokeExit(
                            resultPath,
                            diagnostics: diagnostics,
                            retries: retries - 1
                        )
                    }
                } else {
                    writeSessionSmokeResult(
                        resultPath, result: "failed tmux-zoom-resize exit-timeout\n")
                }
                return
            }
            writeSessionSmokeResult(
                resultPath,
                result: "ok tmux-zoom-resize font-zoom=pane-local resize=responsive "
                    + "\(diagnostics)\n"
            )
        }
    }
#endif

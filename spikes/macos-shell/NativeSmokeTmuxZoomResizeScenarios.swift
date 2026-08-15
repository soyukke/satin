import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    struct TmuxSmokePaneSize: Equatable {
        let cols: Int
        let rows: Int
    }

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
            guard paneIds.contains(zoomedPaneId) else {
                return false
            }
            let baselineSize = terminalTextView.fontSize(nil)
            guard paneIds.allSatisfy({ abs(terminalTextView.fontSize($0) - baselineSize) < 0.01 }),
                terminalTextView.handleCommandKey(zoomInEvent)
            else {
                return false
            }
            let zoomedGrid = tmuxClientGrid()
            guard
                paneIds.allSatisfy({
                    abs(terminalTextView.fontSize($0) - baselineSize - 1) < 0.01
                }),
                session.lastClientGrid?.cols == zoomedGrid.cols,
                session.lastClientGrid?.rows == zoomedGrid.rows,
                zoomedGrid.cols <= baselineGrid.cols,
                zoomedGrid.rows <= baselineGrid.rows,
                zoomedGrid.cols != baselineGrid.cols || zoomedGrid.rows != baselineGrid.rows,
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

        func beginTmuxZoomReflowSmoke(
            _ resultPath: String,
            baselineGrid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int)
        ) {
            guard let session = tmuxSession,
                let snapshot = lastSnapshot,
                let tab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab }),
                let zoomInEvent = tmuxSmokeZoomEvent(increment: true)
            else {
                failTmuxZoomResizeSmoke(resultPath, reason: "zoom-setup")
                return
            }
            let nativePaneIds = tab.panes.filter { session.tmuxPaneIds[$0] != nil }
            let tmuxPaneIds = nativePaneIds.compactMap { session.tmuxPaneIds[$0] }
            let baselinePaneSizes = tmuxSmokePaneSizes(tmuxPaneIds)
            let baselineFontSize = nativePaneIds.first.map(terminalTextView.fontSize) ?? 0
            guard nativePaneIds.count == 2,
                baselinePaneSizes.count == tmuxPaneIds.count,
                nativePaneIds.allSatisfy({
                    abs(terminalTextView.fontSize($0) - baselineFontSize) < 0.01
                }),
                terminalTextView.handleCommandKey(zoomInEvent)
            else {
                failTmuxZoomResizeSmoke(resultPath, reason: "zoom-start")
                return
            }
            waitForTmuxZoomReflow(
                resultPath,
                nativePaneIds: nativePaneIds,
                tmuxPaneIds: tmuxPaneIds,
                baselineFontSize: baselineFontSize,
                baselineGrid: baselineGrid,
                baselinePaneSizes: baselinePaneSizes,
                retries: 40
            )
        }

        func waitForTmuxZoomReflow(
            _ resultPath: String,
            nativePaneIds: [Int],
            tmuxPaneIds: [UInt32],
            baselineFontSize: CGFloat,
            baselineGrid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
            baselinePaneSizes: [UInt32: TmuxSmokePaneSize],
            retries: Int
        ) {
            drainTerminalPanes()
            let zoomedGrid = tmuxClientGrid()
            let zoomedPaneSizes = tmuxSmokePaneSizes(tmuxPaneIds)
            let fontsChanged = nativePaneIds.allSatisfy {
                abs(terminalTextView.fontSize($0) - baselineFontSize - 1) < 0.01
            }
            let clientGridChanged =
                zoomedGrid.cols <= baselineGrid.cols
                && zoomedGrid.rows <= baselineGrid.rows
                && (zoomedGrid.cols != baselineGrid.cols || zoomedGrid.rows != baselineGrid.rows)
            let panesReflowed =
                zoomedPaneSizes.count == baselinePaneSizes.count
                && zoomedPaneSizes != baselinePaneSizes
                && tmuxPaneIds.allSatisfy { paneId in
                    guard let baseline = baselinePaneSizes[paneId],
                        let zoomed = zoomedPaneSizes[paneId]
                    else {
                        return false
                    }
                    return zoomed.cols <= baseline.cols && zoomed.rows <= baseline.rows
                }
            let settled =
                fontsChanged
                && clientGridChanged
                && panesReflowed
                && tmuxSession?.lastClientGrid?.cols == zoomedGrid.cols
                && tmuxSession?.lastClientGrid?.rows == zoomedGrid.rows
            guard settled else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTmuxZoomReflow(
                            resultPath,
                            nativePaneIds: nativePaneIds,
                            tmuxPaneIds: tmuxPaneIds,
                            baselineFontSize: baselineFontSize,
                            baselineGrid: baselineGrid,
                            baselinePaneSizes: baselinePaneSizes,
                            retries: retries - 1
                        )
                    }
                } else {
                    failTmuxZoomResizeSmoke(
                        resultPath,
                        reason: "zoom-reflow",
                        details: "client=\(zoomedGrid.cols)x\(zoomedGrid.rows) "
                            + "panes=\(tmuxSmokePaneSizesSummary(zoomedPaneSizes))"
                    )
                }
                return
            }
            let diagnostics =
                "zoom-client=\(baselineGrid.cols)x\(baselineGrid.rows)"
                + "->\(zoomedGrid.cols)x\(zoomedGrid.rows) "
                + "zoom-panes=\(tmuxSmokePaneSizesSummary(baselinePaneSizes))"
                + "->\(tmuxSmokePaneSizesSummary(zoomedPaneSizes))"
            beginTmuxZoomResizeSmoke(resultPath, zoomDiagnostics: diagnostics)
        }

        func tmuxSmokePaneSizes(_ paneIds: [UInt32]) -> [UInt32: TmuxSmokePaneSize] {
            guard let session = tmuxSession else {
                return [:]
            }
            return Dictionary(
                uniqueKeysWithValues: paneIds.compactMap { paneId in
                    session.latestPanes[paneId].map {
                        (paneId, TmuxSmokePaneSize(cols: Int($0.cols), rows: Int($0.rows)))
                    }
                }
            )
        }

        func tmuxSmokePaneSizesSummary(_ sizes: [UInt32: TmuxSmokePaneSize]) -> String {
            sizes.sorted { $0.key < $1.key }.map {
                "%\($0.key):\($0.value.cols)x\($0.value.rows)"
            }.joined(separator: ",")
        }

        func failTmuxZoomResizeSmoke(
            _ resultPath: String,
            reason: String,
            details: String = ""
        ) {
            tmuxSession?.gateway.tmuxCommand("kill-session")
            let suffix = details.isEmpty ? "" : " \(details)"
            writeSessionSmokeResult(
                resultPath, result: "failed tmux-zoom-resize reason=\(reason)\(suffix)\n")
        }

        func beginTmuxZoomResizeSmoke(
            _ resultPath: String,
            zoomDiagnostics: String
        ) {
            guard let window = view.window else {
                failTmuxZoomResizeSmoke(resultPath, reason: "no-window")
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
                self?.waitForTmuxZoomResizeSmoke(
                    resultPath,
                    zoomDiagnostics: zoomDiagnostics,
                    retries: 40
                )
            }
        }

        func waitForTmuxZoomResizeSmoke(
            _ resultPath: String,
            zoomDiagnostics: String,
            retries: Int
        ) {
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
                        self?.waitForTmuxZoomResizeSmoke(
                            resultPath,
                            zoomDiagnostics: zoomDiagnostics,
                            retries: retries - 1
                        )
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
                diagnostics: "\(zoomDiagnostics) "
                    + "geometry=\(geometry.applications)/\(geometry.requests) "
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
                result: "ok tmux-zoom-resize font-zoom=window-reflow resize=responsive "
                    + "\(diagnostics)\n"
            )
        }
    }
#endif

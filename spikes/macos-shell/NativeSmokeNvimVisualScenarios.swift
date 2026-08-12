import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func waitForNvimCursorMoveContent(_ resultPath: String, retries: Int) {
            guard terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker]) else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.waitForNvimCursorMoveContent(resultPath, retries: retries - 1)
                    }
                    return
                }
                writeNvimCursorMoveSmokeResult(
                    resultPath,
                    baselineScrollPosition: 0,
                    maxScrollPosition: terminalTextView.rendererMaxScrollPosition()
                )
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else {
                    return
                }
                runNvimCommandOrWrite(
                    "setlocal scrolloff=0 nosmoothscroll",
                    fallback: Data()
                )
                runNvimCommandOrWrite(
                    "normal! gg",
                    fallback: Data("\u{1b}gg".utf8)
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else {
                        return
                    }
                    clearSmokeScrollShift()
                    metalView.resetSkiaFrameCount()
                    let baseline = terminalTextView.rendererMaxScrollPosition()
                    writeToActivePane(Data("jjk".utf8))
                    sampleNvimCursorMoveScrollPosition(
                        resultPath,
                        retries: 20,
                        baselineScrollPosition: baseline,
                        maxScrollPosition: baseline
                    )
                }
            }
        }

        func waitForNvimFileTreeCursorMoveContent(_ resultPath: String, retries: Int) {
            guard let treeGrid = terminalTextView.rendererCursorParentInLeftSplit()
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.waitForNvimFileTreeCursorMoveContent(resultPath, retries: retries - 1)
                    }
                    return
                }
                writeNvimFileTreeCursorMoveSmokeResult(
                    resultPath,
                    cursorBefore: "none",
                    cursorParentGrid: nil,
                    populatedLinesBefore: 0,
                    baselineScrollPosition: 0,
                    maxScrollPosition: terminalTextView.rendererMaxScrollPosition()
                )
                return
            }

            runNvimCommandOrWrite(
                "normal! gg",
                fallback: Data("gg".utf8)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else {
                    return
                }
                clearSmokeScrollShift()
                metalView.resetSkiaFrameCount()
                let cursorBefore = terminalTextView.rendererModelCursorSummary()
                let populatedLinesBefore = terminalTextView.rendererPopulatedLineCount(
                    gridID: treeGrid
                )
                let baseline = terminalTextView.rendererMaxScrollPosition()
                waitForNvimFileTreeCursorMoveCaptureTrigger(
                    resultPath,
                    retries: 1_000,
                    cursorBefore: cursorBefore,
                    cursorParentGrid: treeGrid,
                    populatedLinesBefore: populatedLinesBefore,
                    baselineScrollPosition: baseline,
                    maxScrollPosition: baseline
                )
            }
        }

        func waitForNvimFileTreeCloseOpen(_ resultPath: String, retries: Int) {
            guard let treeGrid = terminalTextView.rendererCursorParentInLeftSplit(),
                let boundary = terminalTextView.rendererVisibleWindowRightEdge(gridID: treeGrid)
            else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.waitForNvimFileTreeCloseOpen(resultPath, retries: retries - 1)
                    }
                    return
                }
                writeNvimFileTreeCloseSmokeResult(resultPath, retries: 0)
                return
            }

            smokeState.nvimFileTreeCloseGrid = treeGrid
            smokeState.nvimFileTreeCloseBoundary = boundary
            smokeState.nvimFileTreeCloseBefore = terminalTextView.rendererModelWindowTextSummary()
            metalView.resetSkiaFrameCount()
            runNvimCommandOrWrite(nvimFileTreeCloseCommand(), fallback: Data())
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.writeNvimFileTreeCloseSmokeResult(resultPath, retries: 16)
            }
        }

        func writeNvimFileTreeCloseSmokeResult(_ resultPath: String, retries: Int) {
            let treeGrid = smokeState.nvimFileTreeCloseGrid
            let boundary = smokeState.nvimFileTreeCloseBoundary
            let treeVisible =
                treeGrid.map {
                    terminalTextView.rendererHasVisibleWindow(gridID: $0)
                } ?? true
            let occupied =
                boundary.map {
                    terminalTextView.rendererModelOccupiedCellCount(column: $0)
                } ?? -1
            let skiaFrames = metalView.skiaFrames()
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let cursorParent = terminalTextView.rendererCursorParentGridID()
            let ok =
                treeGrid != nil
                && boundary != nil
                && !treeVisible
                && cursorParent != treeGrid
                && occupied == 0
                && skiaFrames >= 1
                && hasModelFrames
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.writeNvimFileTreeCloseSmokeResult(resultPath, retries: retries - 1)
                }
                return
            }

            let geometry = terminalTextView.skiaGeometrySummary()
            let viewport = terminalTextView.skiaViewportSummary()
            let after = terminalTextView.rendererModelWindowTextSummary()
            let separator = terminalTextView.rendererModelRawTextStartSummary(
                label: "separator",
                text: "│"
            )
            let marker = terminalTextView.rendererModelTextStartSummary(
                label: "marker",
                text: "CLOSESMOKE"
            )
            let gridSummary = treeGrid.map(String.init) ?? "none"
            let boundarySummary = boundary.map(String.init) ?? "none"
            let cursorParentSummary = cursorParent.map(String.init) ?? "none"
            let treeVisibleSummary = treeVisible ? "yes" : "no"
            let modelFramesSummary = hasModelFrames ? "yes" : "no"
            let result =
                ok
                ? "ok file-tree-close grid=\(gridSummary) "
                    + "boundary=\(boundarySummary) occupied=\(occupied) "
                    + "tree-visible=no cursor-parent=\(cursorParentSummary) "
                    + "model-frames=yes skia-frames=\(skiaFrames) geometry=\(geometry) "
                    + "viewport=\(viewport) " + "marker=\(marker) separator=\(separator) "
                    + "before=\(smokeState.nvimFileTreeCloseBefore) after=\(after)\n"
                : "failed file-tree-close grid=\(gridSummary) "
                    + "boundary=\(boundarySummary) occupied=\(occupied) "
                    + "tree-visible=\(treeVisibleSummary) "
                    + "cursor-parent=\(cursorParentSummary) "
                    + "model-frames=\(modelFramesSummary) "
                    + "skia-frames=\(skiaFrames) geometry=\(geometry) " + "viewport=\(viewport) "
                    + "marker=\(marker) separator=\(separator) "
                    + "before=\(smokeState.nvimFileTreeCloseBefore) after=\(after)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

        func waitForNvimFileTreeCursorMoveCaptureTrigger(
            _ resultPath: String,
            retries: Int,
            cursorBefore: String,
            cursorParentGrid: Int,
            populatedLinesBefore: Int,
            baselineScrollPosition: Double,
            maxScrollPosition: Double
        ) {
            let environment = ProcessInfo.processInfo.environment
            guard let triggerPath = environment["SATIN_NATIVE_SMOKE_CONTINUE"],
                !triggerPath.isEmpty
            else {
                startNvimFileTreeCursorMoveSampling(
                    resultPath,
                    cursorBefore: cursorBefore,
                    cursorParentGrid: cursorParentGrid,
                    populatedLinesBefore: populatedLinesBefore,
                    baselineScrollPosition: baselineScrollPosition,
                    maxScrollPosition: maxScrollPosition
                )
                return
            }

            if let readyPath = environment["SATIN_NATIVE_SMOKE_BASELINE_READY"],
                !readyPath.isEmpty
            {
                try? "ready\n".write(toFile: readyPath, atomically: true, encoding: .utf8)
            }

            guard FileManager.default.fileExists(atPath: triggerPath) else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                        self?.waitForNvimFileTreeCursorMoveCaptureTrigger(
                            resultPath,
                            retries: retries - 1,
                            cursorBefore: cursorBefore,
                            cursorParentGrid: cursorParentGrid,
                            populatedLinesBefore: populatedLinesBefore,
                            baselineScrollPosition: baselineScrollPosition,
                            maxScrollPosition: maxScrollPosition
                        )
                    }
                    return
                }
                let result = "failed file-tree-cursor-move capture-trigger-timeout\n"
                try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }

            startNvimFileTreeCursorMoveSampling(
                resultPath,
                cursorBefore: cursorBefore,
                cursorParentGrid: cursorParentGrid,
                populatedLinesBefore: populatedLinesBefore,
                baselineScrollPosition: baselineScrollPosition,
                maxScrollPosition: maxScrollPosition
            )
        }

        func startNvimFileTreeCursorMoveSampling(
            _ resultPath: String,
            cursorBefore: String,
            cursorParentGrid: Int,
            populatedLinesBefore: Int,
            baselineScrollPosition: Double,
            maxScrollPosition: Double
        ) {
            writeToActivePane(Data("j".utf8))
            sampleNvimFileTreeCursorMoveScrollPosition(
                resultPath,
                retries: 20,
                cursorBefore: cursorBefore,
                cursorParentGrid: cursorParentGrid,
                populatedLinesBefore: populatedLinesBefore,
                baselineScrollPosition: baselineScrollPosition,
                maxScrollPosition: maxScrollPosition
            )
        }

        func sampleNvimFileTreeCursorMoveScrollPosition(
            _ resultPath: String,
            retries: Int,
            cursorBefore: String,
            cursorParentGrid: Int,
            populatedLinesBefore: Int,
            baselineScrollPosition: Double,
            maxScrollPosition: Double
        ) {
            let observed = max(
                maxScrollPosition,
                terminalTextView.rendererMaxScrollPosition()
            )
            guard retries > 0 else {
                writeNvimFileTreeCursorMoveSmokeResult(
                    resultPath,
                    cursorBefore: cursorBefore,
                    cursorParentGrid: cursorParentGrid,
                    populatedLinesBefore: populatedLinesBefore,
                    baselineScrollPosition: baselineScrollPosition,
                    maxScrollPosition: observed
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.sampleNvimFileTreeCursorMoveScrollPosition(
                    resultPath,
                    retries: retries - 1,
                    cursorBefore: cursorBefore,
                    cursorParentGrid: cursorParentGrid,
                    populatedLinesBefore: populatedLinesBefore,
                    baselineScrollPosition: baselineScrollPosition,
                    maxScrollPosition: observed
                )
            }
        }

        func writeNvimFileTreeCursorMoveSmokeResult(
            _ resultPath: String,
            cursorBefore: String,
            cursorParentGrid: Int?,
            populatedLinesBefore: Int,
            baselineScrollPosition: Double,
            maxScrollPosition: Double
        ) {
            let shift = consumeSmokeScrollShift()
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            let cursorAfter = terminalTextView.rendererModelCursorSummary()
            let parentAfter = terminalTextView.rendererCursorParentGridID()
            let hasTreeWindow =
                cursorParentGrid.map {
                    terminalTextView.rendererHasVisibleWindow(gridID: $0)
                } ?? false
            let populatedLinesAfter =
                cursorParentGrid.map {
                    terminalTextView.rendererPopulatedLineCount(gridID: $0)
                } ?? 0
            let lineCapacityAfter =
                cursorParentGrid.map {
                    terminalTextView.rendererLineCapacity(gridID: $0)
                } ?? 0
            let ok =
                shift == nil
                && cursorBefore != "none"
                && cursorAfter != cursorBefore
                && parentAfter == cursorParentGrid
                && lineCapacityAfter > 0
                && populatedLinesBefore == lineCapacityAfter
                && populatedLinesAfter == lineCapacityAfter
                && maxScrollPosition <= baselineScrollPosition + maxNvimCursorMoveSmokeGrowth
                && hasModelFrames
                && skiaFrames >= 2
                && hasTreeWindow
            let baseline = String(format: "%.3f", baselineScrollPosition)
            let peak = String(format: "%.3f", maxScrollPosition)
            let result =
                ok
                ? "ok file-tree-cursor-move cursor=\(cursorBefore)->\(cursorAfter) "
                    + "grid=\(cursorParentGrid.map(String.init) ?? "none") no-new-scroll "
                    + "tree-lines=\(populatedLinesBefore)/\(lineCapacityAfter)"
                    + "->\(populatedLinesAfter)/\(lineCapacityAfter) "
                    + "baseline=\(baseline) peak=\(peak) skia-frames=\(skiaFrames)\n"
                : "failed file-tree-cursor-move cursor=\(cursorBefore)->\(cursorAfter) "
                    + "grid=\(cursorParentGrid.map(String.init) ?? "none")->"
                    + "\(parentAfter.map(String.init) ?? "none") "
                    + "tree-lines=\(populatedLinesBefore)/\(lineCapacityAfter)"
                    + "->\(populatedLinesAfter)/\(lineCapacityAfter) "
                    + "baseline=\(baseline) peak=\(peak) "
                    + "scroll-hint=\(shift == nil ? "none" : "present") "
                    + "model-frames=\(hasModelFrames ? "yes" : "no") "
                    + "skia-frames=\(skiaFrames) tree-window=\(hasTreeWindow ? "yes" : "no") "
                    + "\(terminalTextView.rendererViewportSummary())\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

        func sampleNvimCursorMoveScrollPosition(
            _ resultPath: String,
            retries: Int,
            baselineScrollPosition: Double,
            maxScrollPosition: Double
        ) {
            let observed = max(
                maxScrollPosition,
                terminalTextView.rendererMaxScrollPosition()
            )
            guard retries > 0 else {
                writeNvimCursorMoveSmokeResult(
                    resultPath,
                    baselineScrollPosition: baselineScrollPosition,
                    maxScrollPosition: observed
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                self?.sampleNvimCursorMoveScrollPosition(
                    resultPath,
                    retries: retries - 1,
                    baselineScrollPosition: baselineScrollPosition,
                    maxScrollPosition: observed
                )
            }
        }

        func writeNvimCursorMoveSmokeResult(
            _ resultPath: String,
            baselineScrollPosition: Double,
            maxScrollPosition: Double
        ) {
            let shift = consumeSmokeScrollShift()
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            let hasReadyMarker = terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker])
            let ok =
                shift == nil
                && maxScrollPosition <= baselineScrollPosition + maxNvimCursorMoveSmokeGrowth
                && hasModelFrames
                && skiaFrames >= 2
                && hasReadyMarker
            let baseline = String(format: "%.3f", baselineScrollPosition)
            let peak = String(format: "%.3f", maxScrollPosition)
            let result =
                ok
                ? "ok cursor-move no-new-scroll baseline=\(baseline) peak=\(peak) "
                    + "skia-frames=\(skiaFrames)\n"
                : "failed cursor-move baseline=\(baseline) peak=\(peak) "
                    + "scroll-hint=\(shift == nil ? "none" : "present") "
                    + "model-frames=\(hasModelFrames ? "yes" : "no") "
                    + "skia-frames=\(skiaFrames) marker=\(hasReadyMarker ? "yes" : "no") "
                    + "\(terminalTextView.rendererViewportSummary()) "
                    + "text=\(terminalTextView.rendererTextSummary())\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func writeNvimShapedTextSmokeResult(_ resultPath: String, retries: Int) {
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            let expected = shapedTextSmokeLabels()
            let expectedText = expected.map(\.text)
            let missingText = terminalTextView.rendererModelMissingTexts(expectedText)
            let hasText = missingText.isEmpty
            let ok = hasModelFrames && skiaFrames > 0 && hasText
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.writeNvimShapedTextSmokeResult(resultPath, retries: retries - 1)
                }
                return
            }

            let rendererSummary =
                "model-frames=\(hasModelFrames ? "yes" : "no") "
                + "skia-frames=\(skiaFrames > 0 ? "yes" : "no") count=\(skiaFrames)"
            let missingSummary = missingText.isEmpty ? "none" : missingText.joined(separator: ",")
            let textSummary = "text=\(hasText ? "yes" : "no") missing=\(missingSummary)"
            let geometrySummary = "geometry=\(terminalTextView.skiaGeometrySummary())"
            let viewportSummary = "viewport=\(terminalTextView.skiaViewportSummary())"
            let cellSummary = "cells=\(terminalTextView.rendererModelCellSummary(expected))"
            let result =
                ok
                ? "ok shaped-text \(textSummary) \(rendererSummary) \(geometrySummary) "
                    + "\(viewportSummary) \(cellSummary)\n"
                : "failed shaped-text \(textSummary) \(rendererSummary) \(geometrySummary) "
                    + "\(viewportSummary) \(cellSummary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

        func shapedTextSmokeLabels() -> [(label: String, text: String)] {
            [
                ("jp1", "日"),
                ("jp2", "本"),
                ("jp3", "語"),
                ("nerd", "\u{e0b0}"),
                ("combining", "e\u{301}"),
                ("ambiguous", "Ω"),
            ]
        }

        func writeNvimSkiaSmokeResult(_ resultPath: String, retries: Int) {
            let marker = "SKIASMOKE"
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            let markerCount = terminalTextView.rendererModelTextOccurrences(marker)
            let markerCell = terminalTextView.rendererModelCellSummary([("marker", "S")])
            let ok = hasModelFrames && skiaFrames > 0 && markerCount == 1 && markerCell != "none"
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.writeNvimSkiaSmokeResult(resultPath, retries: retries - 1)
                }
                return
            }

            let summary = [
                "model-frames=\(hasModelFrames ? "yes" : "no")",
                "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
                "count=\(skiaFrames)",
                "text=\(markerCount)",
                "geometry=\(terminalTextView.skiaGeometrySummary())",
                "viewport=\(terminalTextView.skiaViewportSummary())",
                "marker-cell=\(markerCell)",
            ].joined(separator: " ")
            let result = ok ? "ok nvim-skia \(summary)\n" : "failed nvim-skia \(summary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

        func writeNvimImageSmokeResult(_ resultPath: String, retries: Int) {
            let imageCount =
                activePaneId
                .flatMap { terminalPane(for: $0)?.controlImageCount() } ?? 0
            let skiaFrames = metalView.skiaFrames()
            let ok = imageCount == 1 && skiaFrames > 0
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.writeNvimImageSmokeResult(resultPath, retries: retries - 1)
                }
                return
            }

            let summary = [
                "images=\(imageCount)",
                "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
                "count=\(skiaFrames)",
                "geometry=\(terminalTextView.skiaGeometrySummary())",
                "viewport=\(terminalTextView.skiaViewportSummary())",
            ].joined(separator: " ")
            let result = ok ? "ok nvim-image \(summary)\n" : "failed nvim-image \(summary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

        func writeNvimUiSurfacesSmokeResult(_ resultPath: String, retries: Int) {
            let counts = terminalTextView.rendererModelWindowKindCounts()
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            let rightSplitCount = terminalTextView.rendererModelTextOccurrences("RIGHTSPLIT")
            let rightSplitRaw = terminalTextView.rendererModelRawTextStartSummary(
                label: "right",
                text: "RIGHTSPLIT"
            )
            let floatCount = terminalTextView.rendererModelTextOccurrences("FLOATBOX")
            let floatCellSummary = terminalTextView.rendererModelRawScreenTextStartSummary(
                label: "float",
                text: "FLOATBOX"
            )
            let statusCount = terminalTextView.rendererModelTextOccurrences("STATUSLINE")
            let statusRaw = terminalTextView.rendererModelRawTextStartSummary(
                label: "status",
                text: "STATUSLINE"
            )
            let messageCount = terminalTextView.rendererModelTextOccurrences("MSGBOX")
            let blendCellCount = terminalTextView.rendererModelBlendCellCount(minBlend: 35)
            let blendCellSummary = terminalTextView.rendererModelBlendCellSummary(minBlend: 35)
            let hasSplit = (counts["normal"] ?? 0) >= 2 && rightSplitCount == 1
            let hasFloat = (counts["float"] ?? 0) >= 2 && floatCellSummary != "none"
            let hasFixedSurfaces = messageCount == 1
            let hasBlend = blendCellCount > 0 && blendCellSummary != "none"
            let hasMessageSelection =
                smokeState.nvimMessageSelection.contains("overlay=yes")
                && smokeState.nvimMessageSelection.contains("copied=yes")
            let ok =
                hasModelFrames && skiaFrames > 0 && hasSplit && hasFloat && hasFixedSurfaces
                && hasBlend
                && hasMessageSelection
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.writeNvimUiSurfacesSmokeResult(resultPath, retries: retries - 1)
                }
                return
            }

            let summary = [
                "model-frames=\(hasModelFrames ? "yes" : "no")",
                "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
                "count=\(skiaFrames)",
                "normal=\(counts["normal"] ?? 0)",
                "float=\(counts["float"] ?? 0)",
                "right=\(rightSplitCount)",
                "right-raw=\(rightSplitRaw)",
                "float-text=\(floatCount)",
                "float-cell=\(floatCellSummary)",
                "status=\(statusCount)",
                "status-raw=\(statusRaw)",
                "message=\(messageCount)",
                "message-selection=\(smokeState.nvimMessageSelection.replacingOccurrences(of: " ", with: ","))",
                "blend-cells=\(blendCellCount)",
                "geometry=\(terminalTextView.skiaGeometrySummary())",
                "viewport=\(terminalTextView.skiaViewportSummary())",
                "windows=\(terminalTextView.rendererModelWindowTextSummary(limit: 8))",
                "blend-cell=\(blendCellSummary)",
            ].joined(separator: " ")
            let result = ok ? "ok ui-surfaces \(summary)\n" : "failed ui-surfaces \(summary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

        func writeNvimPopupmenuSmokeResult(
            _ resultPath: String,
            retries: Int,
            settleFrames: Int = 12,
            pendingFrameCount: Int? = nil
        ) {
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            if let pendingFrameCount, skiaFrames < pendingFrameCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.writeNvimPopupmenuSmokeResult(
                        resultPath,
                        retries: retries,
                        settleFrames: settleFrames,
                        pendingFrameCount: pendingFrameCount
                    )
                }
                return
            }
            let popupCount = terminalTextView.rendererModelTextOccurrences("POPUPONE")
            let popupCellSummary = terminalTextView.rendererModelTextStartSummary(
                label: "popup",
                text: "POPUPONE"
            )
            let ok =
                hasModelFrames && skiaFrames > 0 && popupCount == 1 && popupCellSummary != "none"
            if ok && settleFrames > 0 {
                metalView.requestFrame()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.writeNvimPopupmenuSmokeResult(
                        resultPath,
                        retries: retries,
                        settleFrames: settleFrames - 1,
                        pendingFrameCount: skiaFrames + 1
                    )
                }
                return
            }
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.writeNvimPopupmenuSmokeResult(
                        resultPath,
                        retries: retries - 1,
                        settleFrames: settleFrames,
                        pendingFrameCount: nil
                    )
                }
                return
            }

            let summary = [
                "model-frames=\(hasModelFrames ? "yes" : "no")",
                "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
                "count=\(skiaFrames)",
                "popup=\(popupCount)",
                "geometry=\(terminalTextView.skiaGeometrySummary())",
                "viewport=\(terminalTextView.skiaViewportSummary())",
                "popup-cell=\(popupCellSummary)",
            ].joined(separator: " ")
            let result = ok ? "ok popupmenu \(summary)\n" : "failed popupmenu \(summary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

        func writeNvimFileTreeSmokeResult(
            _ resultPath: String,
            openedPath: String,
            treeLinesPath: String,
            cwdPath: String,
            retries: Int
        ) {
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            let opened =
                (try? String(contentsOfFile: openedPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let cwd =
                (try? String(contentsOfFile: cwdPath, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let appCwd = nativeWorkingDirectory()
            let treeLines = (try? String(contentsOfFile: treeLinesPath, encoding: .utf8)) ?? ""
            let treeHasCargo = treeLines.contains("Cargo.toml")
            let treeLineCount = treeLines.split(separator: "\n", omittingEmptySubsequences: false)
                .count
            let rawTarget = terminalTextView.rendererModelRawTextStartSummary(
                label: "cargo",
                text: "Cargo.toml"
            )
            let rawSrc = terminalTextView.rendererModelRawTextStartSummary(
                label: "src", text: "src")
            let rawReadme = terminalTextView.rendererModelRawTextStartSummary(
                label: "readme",
                text: "README.md"
            )
            let rawRepo = terminalTextView.rendererModelRawTextStartSummary(
                label: "repo",
                text: "satin"
            )
            let windows = terminalTextView.rendererModelWindowTextSummary()
            let hasTreeTarget = smokeState.nvimFileTreeTarget != "none"
            let ok = hasModelFrames && skiaFrames > 0 && hasTreeTarget && opened == "Cargo.toml"
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.writeNvimFileTreeSmokeResult(
                        resultPath,
                        openedPath: openedPath,
                        treeLinesPath: treeLinesPath,
                        cwdPath: cwdPath,
                        retries: retries - 1
                    )
                }
                return
            }

            let summary = [
                "model-frames=\(hasModelFrames ? "yes" : "no")",
                "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
                "count=\(skiaFrames)",
                "target=\(smokeState.nvimFileTreeTarget)",
                "tree-cargo=\(treeHasCargo ? "yes" : "no")",
                "tree-lines=\(treeLineCount)",
                "cwd=\(cwd.isEmpty ? "none" : cwd)",
                "app-cwd=\(appCwd)",
                "raw=\(rawTarget)",
                "src=\(rawSrc)",
                "readme=\(rawReadme)",
                "repo=\(rawRepo)",
                "windows=\(windows)",
                "opened=\(opened.isEmpty ? "none" : opened)",
            ].joined(separator: " ")
            let result = ok ? "ok file-tree \(summary)\n" : "failed file-tree \(summary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

        func writeNvimCursorSwitchSmokeResult(_ resultPath: String, retries: Int) {
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            let newTextCount = terminalTextView.rendererModelTextOccurrences("NEWTAB")
            let oldTextCount = terminalTextView.rendererModelTextOccurrences("OLDTAB")
            let cursor = terminalTextView.rendererModelCursorSummary()
            let ok =
                hasModelFrames && skiaFrames > 0 && newTextCount == 1 && oldTextCount == 0
                && cursor == "5:11"
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.writeNvimCursorSwitchSmokeResult(resultPath, retries: retries - 1)
                }
                return
            }

            let summary = [
                "model-frames=\(hasModelFrames ? "yes" : "no")",
                "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
                "count=\(skiaFrames)",
                "geometry=\(terminalTextView.skiaGeometrySummary())",
                "viewport=\(terminalTextView.skiaViewportSummary())",
                "old=17:59",
                "new=\(cursor)",
                "new-text=\(newTextCount)",
                "old-text=\(oldTextCount)",
            ].joined(separator: " ")
            let result = ok ? "ok cursor-switch \(summary)\n" : "failed cursor-switch \(summary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

        func writeNvimCursorShapeSmokeResult(_ resultPath: String, retries: Int) {
            writeNvimCursorDetailSmokeResult(
                resultPath,
                label: "cursor-shape",
                expected: "5:11:bar:25:0:0:0",
                expectedText: "CURSORSHAPE",
                retries: retries
            )
        }

        func writeNvimCursorBlinkSmokeResult(_ resultPath: String, retries: Int) {
            writeNvimCursorDetailSmokeResult(
                resultPath,
                label: "cursor-blink",
                expected: "5:11:bar:25:100:100:2000",
                expectedText: "CURSORBLINK",
                retries: retries,
                retryDelay: 0.15,
                requireSettledAnimation: false,
                settleFrames: 0
            )
        }

        func writeNvimCursorDetailSmokeResult(
            _ resultPath: String,
            label: String,
            expected: String,
            expectedText: String,
            retries: Int,
            retryDelay: TimeInterval = 0.25,
            requireSettledAnimation: Bool = true,
            settleFrames: Int = 12,
            pendingFrameCount: Int? = nil
        ) {
            let hasModelFrames = terminalTextView.hasRendererModelFrames()
            let skiaFrames = metalView.skiaFrames()
            if let pendingFrameCount, skiaFrames < pendingFrameCount {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.writeNvimCursorDetailSmokeResult(
                        resultPath,
                        label: label,
                        expected: expected,
                        expectedText: expectedText,
                        retries: retries,
                        retryDelay: retryDelay,
                        requireSettledAnimation: requireSettledAnimation,
                        settleFrames: settleFrames,
                        pendingFrameCount: pendingFrameCount
                    )
                }
                return
            }
            let cursor = terminalTextView.rendererModelCursorDetailSummary()
            let textCount = terminalTextView.rendererModelTextOccurrences(expectedText)
            let animationSettled = !requireSettledAnimation || !metalView.hasPendingSkiaFrame()
            let modelReady =
                hasModelFrames && skiaFrames > 0 && cursor == expected && textCount == 1
            if modelReady && animationSettled && settleFrames > 0 {
                metalView.requestFrame()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.writeNvimCursorDetailSmokeResult(
                        resultPath,
                        label: label,
                        expected: expected,
                        expectedText: expectedText,
                        retries: retries,
                        retryDelay: retryDelay,
                        requireSettledAnimation: requireSettledAnimation,
                        settleFrames: settleFrames - 1,
                        pendingFrameCount: skiaFrames + 1
                    )
                }
                return
            }
            let ok = modelReady && animationSettled
            if !ok, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                    self?.writeNvimCursorDetailSmokeResult(
                        resultPath,
                        label: label,
                        expected: expected,
                        expectedText: expectedText,
                        retries: retries - 1,
                        retryDelay: retryDelay,
                        requireSettledAnimation: requireSettledAnimation,
                        settleFrames: settleFrames,
                        pendingFrameCount: nil
                    )
                }
                return
            }

            let summary = [
                "model-frames=\(hasModelFrames ? "yes" : "no")",
                "skia-frames=\(skiaFrames > 0 ? "yes" : "no")",
                "count=\(skiaFrames)",
                "geometry=\(terminalTextView.skiaGeometrySummary())",
                "viewport=\(terminalTextView.skiaViewportSummary())",
                "cursor=\(cursor)",
                "text=\(textCount)",
                "animation-settled=\(animationSettled ? "yes" : "no")",
                "next-frame-delay-ms=\(metalView.pendingSkiaFrameDelayMs())",
            ].joined(separator: " ")
            let result = ok ? "ok \(label) \(summary)\n" : "failed \(label) \(summary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

    }
#endif

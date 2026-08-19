import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func applyNvimScrollVisualSmokeScenario(resultPath: String) {
            openNvimSmokeBuffer(
                path: "/tmp/satin-nvim-scroll-visual-smoke.txt",
                terminalCommand: "nvim -Nu NONE -n $tmp"
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else {
                    return
                }
                let sideLines = (1...60).map {
                    String(format: "'SIDE_FIXED_%02d'", $0)
                }.joined(separator: ",")
                runNvimCommandOrWrite(
                    "call setline(2, map(range(1, 300), "
                        + "'printf(\"SCROLL_%03d_\", v:val) . "
                        + "repeat(\"ABCDEFGHIJKLMNOPQRSTUVWXYZ\", 6)'))",
                    fallback: Data()
                )
                let command = [
                    "set laststatus=2 guicursor=a:block-blinkon0",
                    "setlocal scrolloff=0 nosmoothscroll",
                    "topleft vertical 24new",
                    "setlocal buftype=nofile bufhidden=wipe noswapfile",
                    "setlocal norelativenumber nonumber signcolumn=no",
                    "call setline(1, [\(sideLines)])",
                    "normal! gg",
                ].joined(separator: " | ")
                runNvimCommandOrWrite(command, fallback: Data())
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else {
                        return
                    }
                    runNvimCommandOrWrite(
                        "wincmd p | setlocal scrolloff=0 nosmoothscroll | normal! gg",
                        fallback: Data(":wincmd p\r".utf8)
                    )
                    waitForNvimScrollVisualReady(resultPath, retries: 40)
                }
            }
        }

        func waitForNvimScrollVisualReady(_ resultPath: String, retries: Int) {
            let windows = terminalTextView.rendererVisibleWindowScrollPositions()
            let hasMarker = terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker])
            let ready =
                hasMarker
                && windows.count >= 3
            guard ready else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForNvimScrollVisualReady(resultPath, retries: retries - 1)
                    }
                    return
                }
                let windowSummary = windows.map {
                    "\($0.gridID)@\($0.left):\(String(format: "%.3f", $0.position))"
                }.joined(separator: ",")
                writeNvimScrollVisualFailure(
                    resultPath,
                    reason: "setup-timeout marker=\(hasMarker ? "yes" : "no") "
                        + "windows=\(windowSummary)"
                )
                return
            }

            guard writeNvimScrollVisualMarker("SATIN_NATIVE_SMOKE_BASELINE_READY") else {
                writeNvimScrollVisualFailure(resultPath, reason: "baseline-marker-missing")
                return
            }
            waitForNvimScrollVisualTrigger(resultPath, stage: 1, retries: 1_000)
        }

        func waitForNvimScrollVisualTrigger(
            _ resultPath: String,
            stage: Int,
            retries: Int
        ) {
            let key =
                stage == 1
                ? "SATIN_NATIVE_SMOKE_CONTINUE"
                : "SATIN_NATIVE_SMOKE_CONTINUE_SECOND"
            guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else {
                writeNvimScrollVisualFailure(resultPath, reason: "trigger-path-missing-(stage)")
                return
            }
            guard FileManager.default.fileExists(atPath: path) else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                        self?.waitForNvimScrollVisualTrigger(
                            resultPath,
                            stage: stage,
                            retries: retries - 1
                        )
                    }
                    return
                }
                writeNvimScrollVisualFailure(resultPath, reason: "trigger-timeout-(stage)")
                return
            }

            clearSmokeScrollShift()
            metalView.resetSkiaFrameCount()
            sendNvimSmokeControlD()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if stage == 1 {
                    self?.finishFirstNvimScrollVisualPass(resultPath)
                } else {
                    self?.writeNvimScrollVisualResult(resultPath)
                }
            }
        }

        func finishFirstNvimScrollVisualPass(_ resultPath: String) {
            let shift = consumeSmokeScrollShift()
            smokeState.nvimScrollVisualFirstRows = shift?.rows
            smokeState.nvimScrollVisualFirstStartCol = shift?.startCol
            smokeState.nvimScrollVisualFirstFrames = metalView.skiaFrames()
            waitForNvimScrollVisualTrigger(resultPath, stage: 2, retries: 1_000)
        }

        func writeNvimScrollVisualResult(_ resultPath: String) {
            let secondShift = consumeSmokeScrollShift()
            let secondFrames = metalView.skiaFrames()
            let firstRows = smokeState.nvimScrollVisualFirstRows
            let firstStartCol = smokeState.nvimScrollVisualFirstStartCol
            let firstFrames = smokeState.nvimScrollVisualFirstFrames
            let secondRows = secondShift?.rows
            let secondStartCol = secondShift?.startCol
            let ok =
                firstRows.map { abs($0) > maxOutputScrollAnimationRows } ?? false
                && secondRows.map { abs($0) > maxOutputScrollAnimationRows } ?? false
                && (firstStartCol ?? 0) > 0
                && (secondStartCol ?? 0) > 0
                && firstFrames >= 8
                && secondFrames >= 8
            let prefix = ok ? "ok" : "failed"
            let result =
                [
                    prefix,
                    "nvim-scroll-visual",
                    "first-rows=\(firstRows.map(String.init) ?? "none")",
                    "first-col=\(firstStartCol.map(String.init) ?? "none")",
                    "first-frames=\(firstFrames)",
                    "second-rows=\(secondRows.map(String.init) ?? "none")",
                    "second-col=\(secondStartCol.map(String.init) ?? "none")",
                    "second-frames=\(secondFrames)",
                    "geometry=\(terminalTextView.skiaGeometrySummary())",
                    "viewport=\(terminalTextView.skiaViewportSummary())",
                ].joined(separator: " ") + "\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            if ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_KEEP_OPEN"] != "1" {
                NSApp.terminate(nil)
            }
        }

        func writeNvimScrollVisualFailure(_ resultPath: String, reason: String) {
            let result = "failed nvim-scroll-visual reason=\(reason)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func writeNvimScrollVisualMarker(_ environmentKey: String) -> Bool {
            guard let path = ProcessInfo.processInfo.environment[environmentKey], !path.isEmpty
            else {
                return false
            }
            do {
                try "ready\n".write(toFile: path, atomically: true, encoding: .utf8)
                return true
            } catch {
                return false
            }
        }
    }
#endif

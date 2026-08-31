import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func applyTerminalNvimCwdSmokeScenario(resultPath: String) {
            let cwd =
                ProcessInfo.processInfo.environment["SATIN_NATIVE_CWD_EXPECTED"]
                ?? "/tmp/satin-terminal-nvim-cwd"
            let cwdFile =
                ProcessInfo.processInfo.environment["SATIN_NATIVE_CWD_ACTUAL"]
                ?? "/tmp/satin-terminal-nvim-cwd.actual"
            let finderCwd = URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent("finder live cwd", isDirectory: true).path
            try? FileManager.default.createDirectory(
                atPath: finderCwd,
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(atPath: cwdFile)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else {
                    return
                }
                writeToActivePane(Data("cd \(shellQuote(cwd))\r".utf8))
                waitForTerminalCwdThenOpenNvim(
                    resultPath,
                    expected: cwd,
                    finderCwd: finderCwd,
                    actualFile: cwdFile,
                    retries: 30
                )
            }
        }

        func waitForTerminalCwdThenOpenNvim(
            _ resultPath: String,
            expected: String,
            finderCwd: String,
            actualFile: String,
            retries: Int
        ) {
            drainTerminalPanes()
            let paneId = activePaneId
            let terminalCwd = paneId.flatMap {
                (paneStore.runtimes[$0] as? RustTerminalPane)?.currentWorkingDirectory()
            }
            guard terminalCwd == expected else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForTerminalCwdThenOpenNvim(
                            resultPath,
                            expected: expected,
                            finderCwd: finderCwd,
                            actualFile: actualFile,
                            retries: retries - 1
                        )
                    }
                    return
                }
                let result =
                    "failed terminal-nvim-cwd terminal-cwd="
                    + "\(terminalCwd ?? "nil") expected=\(expected)\n"
                try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }
            openNativeNeovim(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runNvimCommandOrWrite(
                    "call writefile([getcwd()], '\(vimSingleQuote(actualFile))') | "
                        + "execute 'cd ' . fnameescape('\(vimSingleQuote(finderCwd))')",
                    fallback: Data()
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.writeTerminalNvimCwdSmokeResult(
                    resultPath,
                    expected: expected,
                    finderCwd: finderCwd,
                    actualFile: actualFile,
                    retries: 16
                )
            }
        }

        func applyTerminalNvimQuitSmokeScenario(resultPath: String) {
            openNativeNeovim(nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runNvimCommandOrWrite("qa!", fallback: Data())
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.waitForTerminalAfterNvimQuit(resultPath, retries: 20)
            }
        }

        func applyNvimScrollSmokeScenario(resultPath: String) {
            openNvimSmokeBuffer(
                path: "/tmp/satin-nvim-scroll-smoke.txt",
                terminalCommand: "nvim -Nu NONE -n $tmp"
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                guard let self else {
                    return
                }
                clearSmokeScrollShift()
                metalView.resetSkiaFrameCount()
                sendNvimSmokeControlD()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.75) { [weak self] in
                self?.runNvimCommandOrWrite(
                    "vsplit",
                    fallback: Data("\u{1b}:vsplit\r".utf8)
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.25) { [weak self] in
                guard let self else {
                    return
                }
                clearSmokeScrollShift()
                metalView.resetSkiaFrameCount()
                sendNvimSmokeControlD()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.75) { [weak self] in
                guard let self else {
                    return
                }
                clearSmokeScrollShift()
                metalView.resetSkiaFrameCount()
                sendNvimSmokeControlD()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.80) { [weak self] in
                self?.sendNvimSmokeControlD()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 6.30) { [weak self] in
                self?.writeNvimAnimationSmokeResult(
                    resultPath,
                    retries: 12,
                    requiresRetainedScroll: true
                )
            }
        }

        func applyNvimJumpSmokeScenario(resultPath: String) {
            openNvimSmokeBuffer(
                path: "/tmp/satin-nvim-jump-smoke.txt",
                terminalCommand: "nvim -Nu NONE -n $tmp"
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.waitForNvimSmokeContentThenJump(resultPath, retries: 24)
            }
        }

        func applyNvimSidePaneSmokeScenario(resultPath: String) {
            openNvimSmokeBuffer(
                path: "/tmp/satin-nvim-side-pane-smoke.txt",
                terminalCommand: "nvim -Nu NONE -n $tmp"
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else {
                    return
                }
                runNvimCommandOrWrite(
                    "topleft vertical 24new",
                    fallback: Data("\u{1b}:topleft vertical 24new\r".utf8)
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self else {
                    return
                }
                runNvimCommandOrWrite(
                    "wincmd l",
                    fallback: Data(":wincmd l\r".utf8)
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) { [weak self] in
                guard let self else {
                    return
                }
                clearSmokeScrollShift()
                metalView.resetSkiaFrameCount()
                sendNvimSmokeControlD()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.7) { [weak self] in
                self?.writeNvimSidePaneSmokeResult(resultPath, retries: 20)
            }
        }

        func applyNvimCommandLineSmokeScenario(resultPath: String) {
            openNvimSmokeBuffer(
                path: "/tmp/satin-nvim-commandline-smoke.txt",
                terminalCommand: "nvim -Nu NONE -n $tmp"
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self else {
                    return
                }
                clearSmokeScrollShift()
                writeToActivePane(Data("\u{1b}:qa".utf8))
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                self?.writeNvimNoScrollSmokeResult(resultPath, label: "commandline")
            }
        }

        func applyNvimCursorMoveSmokeScenario(resultPath: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else {
                    return
                }
                let command =
                    "enew! | call setline(1, ['\(nvimSmokeReadyMarker)'] + "
                    + "map(range(1, 9), '\"SATIN_STABLE_ROW_\" . "
                    + "printf(\"%02d\", v:val) . \"_ABCDEFGHIJKLMNOPQRSTUVWXYZ\"')) | "
                    + "setlocal scrolloff=0 nosmoothscroll | normal! gg"
                runNvimCommandOrWrite(command, fallback: Data())
                waitForNvimCursorMoveContent(resultPath, retries: 24)
            }
        }

        func applyNvimShapedTextSmokeScenario(resultPath: String) {
            openNvimShapedTextSmokeBuffer(
                path: "/tmp/satin-nvim-shaped-text-smoke.txt",
                terminalCommand: "nvim -Nu NONE -n $tmp"
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                self?.writeNvimShapedTextSmokeResult(resultPath, retries: 16)
            }
        }

        func applyNvimSkiaSmokeScenario(resultPath: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.configureNvimSkiaSmoke()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
                self?.writeNvimSkiaSmokeResult(resultPath, retries: 12)
            }
        }

        func applyNvimLayoutRedrawSmokeScenario(resultPath: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else {
                    return
                }
                _ = terminalTextView.setTerminalFont(
                    family: terminalTextView.terminalFontFamily,
                    size: defaultTerminalFontSize
                )
                resizeTerminalPanesToGrid()
                runNvimCommandOrWrite(
                    "enew! | call setline(1, ['\(nvimSmokeReadyMarker)', 'LAYOUT_REDRAW'])",
                    fallback: Data()
                )
                waitForNvimLayoutRedrawReady(resultPath, retries: 24)
            }
        }

        func applyNvimImageSmokeScenario(resultPath: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.configureNvimSkiaSmoke()
                self?.sendNvimImageSmokePlacement()
                self?.metalView.resetSkiaFrameCount()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
                self?.writeNvimImageSmokeResult(resultPath, retries: 12)
            }
        }

        func applyNvimUiSurfacesSmokeScenario(resultPath: String) {
            openNvimSmokeBuffer(
                path: "/tmp/satin-nvim-ui-surfaces-smoke.txt",
                terminalCommand: "nvim -Nu NONE -n $tmp"
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else {
                    return
                }
                runNvimCommandOrWrite("vnew", fallback: Data("\u{1b}:vnew\r".utf8))
                runNvimCommandOrWrite(
                    "call setline(1, 'RIGHTSPLIT')",
                    fallback: Data(":call setline(1, 'RIGHTSPLIT')\r".utf8)
                )
                runNvimCommandOrWrite(
                    nvimSmokeStatuslineCommand(),
                    fallback: Data(":set laststatus=2 statusline=STATUSLINE\r".utf8)
                )
                runNvimCommandOrWrite(
                    nvimFloatCommand(),
                    fallback: Data(":echo 'FLOATBOX'\r".utf8)
                )
                runNvimCommandOrWrite(
                    "echo 'MSGBOX'",
                    fallback: Data(":echo 'MSGBOX'\r".utf8)
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
                guard let self else {
                    return
                }
                runNvimCommandOrWrite(
                    nvimSmokeStatuslineCommand(),
                    fallback: Data(":set laststatus=2 statusline=STATUSLINE\r".utf8)
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.45) { [weak self] in
                self?.exerciseNvimMessageSelectionSmoke()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.7) { [weak self] in
                self?.writeNvimUiSurfacesSmokeResult(resultPath, retries: 12)
            }
        }

        func applyNvimPopupmenuSmokeScenario(resultPath: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.configureNvimPopupmenuSmoke()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                self?.writeNvimPopupmenuSmokeResult(resultPath, retries: 12)
            }
        }

        func applyNvimFileTreeSmokeScenario(resultPath: String) {
            let repoRoot =
                ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_REPO_ROOT"]
                ?? nativeWorkingDirectory()
            let openedPath = "/tmp/satin-nvim-file-tree-opened.txt"
            let treeLinesPath = "/tmp/satin-nvim-file-tree-lines.txt"
            let cwdPath = "/tmp/satin-nvim-file-tree-cwd.txt"
            try? FileManager.default.removeItem(atPath: openedPath)
            try? FileManager.default.removeItem(atPath: treeLinesPath)
            try? FileManager.default.removeItem(atPath: cwdPath)
            smokeState.nvimFileTreeTarget = "none"

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self else {
                    return
                }
                runNvimCommandOrWrite(
                    neovimChangeDirectoryCommand(repoRoot),
                    fallback: Data()
                )
                runNvimCommandOrWrite(
                    "call writefile([getcwd()], '\(vimSingleQuote(cwdPath))')",
                    fallback: Data()
                )
                runNvimCommandOrWrite(
                    nvimFileTreeOpenCommand(),
                    fallback: Data([0x10])
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
                self?.runNvimCommandOrWrite(
                    "call search('Cargo.toml')",
                    fallback: Data("/Cargo.toml\r".utf8)
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.runNvimCommandOrWrite(
                    "call writefile(getline(1, '$'), '\(vimSingleQuote(treeLinesPath))')",
                    fallback: Data()
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.3) { [weak self] in
                self?.clickNvimFileTreeSmokeTarget()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.7) { [weak self] in
                self?.writeToActivePane(Data([13]))
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.3) { [weak self] in
                self?.runNvimCommandOrWrite(
                    "call writefile([expand('%:t')], '\(vimSingleQuote(openedPath))')",
                    fallback: Data()
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.7) { [weak self] in
                self?.writeNvimFileTreeSmokeResult(
                    resultPath,
                    openedPath: openedPath,
                    treeLinesPath: treeLinesPath,
                    cwdPath: cwdPath,
                    retries: 12
                )
            }
        }

        func applyNvimFileTreeCursorMoveSmokeScenario(resultPath: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self else {
                    return
                }
                runNvimCommandOrWrite(
                    nvimFileTreeOpenCommand(),
                    fallback: Data([0x10])
                )
                waitForNvimFileTreeCursorMoveContent(resultPath, retries: 24)
            }
        }

        func applyNvimFileTreeCloseSmokeScenario(resultPath: String) {
            smokeState.nvimFileTreeCloseGrid = nil
            smokeState.nvimFileTreeCloseBoundary = nil
            smokeState.nvimFileTreeCloseBefore = "none"

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self else {
                    return
                }
                runNvimCommandOrWrite(
                    "enew! | setlocal nonumber norelativenumber signcolumn=no foldcolumn=0 | "
                        + "set laststatus=0 showtabline=0 | " + "call setline(1, ['CLOSESMOKE']) | "
                        + "lua vim.opt.fillchars:append({eob=' '})",
                    fallback: Data()
                )
                runNvimCommandOrWrite(
                    nvimFileTreeOpenCommand(),
                    fallback: Data([0x10])
                )
                waitForNvimFileTreeCloseOpen(resultPath, retries: 24)
            }
        }

        func applyNvimCursorSwitchSmokeScenario(resultPath: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.configureNvimCursorSmokeTab(
                    marker: "OLDTAB",
                    cursorRow: 17,
                    cursorCol: 59
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else {
                    return
                }
                core.newTab()
                syncFromCore()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                self?.configureNvimCursorSmokeTab(
                    marker: "NEWTAB",
                    cursorRow: 5,
                    cursorCol: 11
                )
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.8) { [weak self] in
                self?.writeNvimCursorSwitchSmokeResult(resultPath, retries: 12)
            }
        }

        func applyNvimCursorShapeSmokeScenario(resultPath: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.configureNvimCursorShapeSmoke()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.3) { [weak self] in
                self?.clearMarkedTextForVisualSmoke()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.7) { [weak self] in
                self?.writeNvimCursorShapeSmokeResult(resultPath, retries: 12)
            }
        }

        func applyNvimCursorNormalShapeSmokeScenario(resultPath: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.configureNvimCursorNormalShapeSmoke()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
                self?.writeNvimCursorDetailSmokeResult(
                    resultPath,
                    label: "cursor-normal-shape",
                    expected: "5:11:block:0:0:0:0",
                    expectedText: "CURSORNORMAL",
                    retries: 12
                )
            }
        }

        func applyNvimCursorReplaceShapeSmokeScenario(resultPath: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.configureNvimCursorReplaceShapeSmoke()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { [weak self] in
                self?.clearMarkedTextForVisualSmoke()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
                self?.writeNvimCursorDetailSmokeResult(
                    resultPath,
                    label: "cursor-replace-shape",
                    expected: "5:11:underline:20:0:0:0",
                    expectedText: "CURSORREPLACE",
                    retries: 12
                )
            }
        }

        func applyNvimCursorBlinkSmokeScenario(resultPath: String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                self?.configureNvimCursorBlinkSmoke()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) { [weak self] in
                self?.clearMarkedTextForVisualSmoke()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.7) { [weak self] in
                self?.writeNvimCursorBlinkSmokeResult(resultPath, retries: 8)
            }
        }

    }
#endif

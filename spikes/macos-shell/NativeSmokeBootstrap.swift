import AppKit
import CoreGraphics
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension SatinAppDelegate {
        func applySmokeScenarioIfNeeded(_ controller: TerminalShellViewController) {
            let environment = ProcessInfo.processInfo.environment
            switch environment["SATIN_NATIVE_SMOKE_SCENARIO"] {
            case "settings":
                settingsWindowController?.present()
            case "1":
                controller.applySmokeScenario(resultPath: environment["SATIN_NATIVE_SMOKE_RESULT"])
            case "terminal-bottom-input":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyTerminalBottomInputSmokeScenario(resultPath: path)
                }
            case "terminal-exit-closes-tab":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyTerminalExitClosesTabSmokeScenario(resultPath: path)
                }
            case "finder-editor":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyFinderEditorSmokeScenario(resultPath: path)
                }
            case "session-schema":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applySessionSchemaSmokeScenario(resultPath: path)
                }
            case "tmux-native":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyTmuxNativeSmokeScenario(resultPath: path)
                }
            case "tmux-reattach":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty,
                    let sessionName = environment["SATIN_NATIVE_SMOKE_TMUX_SESSION"],
                    let socketPath = environment["SATIN_NATIVE_SMOKE_TMUX_SOCKET"],
                    let expectedContent = environment["SATIN_NATIVE_SMOKE_TMUX_CONTENT"]
                {
                    controller.applyTmuxReattachSmokeScenario(
                        resultPath: path,
                        sessionName: sessionName,
                        socketPath: socketPath,
                        expectedContent: expectedContent
                    )
                }
            case "tmux-reattach-missing":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty,
                    let sessionName = environment["SATIN_NATIVE_SMOKE_TMUX_SESSION"],
                    let socketPath = environment["SATIN_NATIVE_SMOKE_TMUX_SOCKET"]
                {
                    controller.applyMissingTmuxReattachSmokeScenario(
                        resultPath: path,
                        sessionName: sessionName,
                        socketPath: socketPath
                    )
                }
            case "tmux-restart-checkpoint":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty,
                    let sessionName = environment["SATIN_NATIVE_SMOKE_TMUX_SESSION"],
                    let socketPath = environment["SATIN_NATIVE_SMOKE_TMUX_SOCKET"],
                    let expectedContent = environment["SATIN_NATIVE_SMOKE_TMUX_CONTENT"]
                {
                    controller.applyTmuxRestartCheckpointSmokeScenario(
                        resultPath: path,
                        sessionName: sessionName,
                        socketPath: socketPath,
                        expectedContent: expectedContent
                    )
                }
            case "tmux-restart-restore":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty,
                    let sessionName = environment["SATIN_NATIVE_SMOKE_TMUX_SESSION"],
                    let socketPath = environment["SATIN_NATIVE_SMOKE_TMUX_SOCKET"],
                    let expectedContent = environment["SATIN_NATIVE_SMOKE_TMUX_CONTENT"]
                {
                    controller.applyTmuxRestartRestoreSmokeScenario(
                        resultPath: path,
                        sessionName: sessionName,
                        socketPath: socketPath,
                        expectedContent: expectedContent
                    )
                }
            case "tab-bar-actions":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyTabBarActionsSmokeScenario(resultPath: path)
                }
            case "artifact-popover":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyArtifactPopoverSmokeScenario(resultPath: path)
                }
            case "home-cwd":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyHomeWorkingDirectorySmokeScenario(resultPath: path)
                }
            case "terminal-resize":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyTerminalResizeSmokeScenario(resultPath: path)
                }
            case "terminal-nvim-handoff":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyTerminalNvimHandoffSmokeScenario(resultPath: path)
                }
            case "shell-nvim-native":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyShellNvimNativeSmokeScenario(resultPath: path)
                }
            case "terminal-nvim-cwd":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyTerminalNvimCwdSmokeScenario(resultPath: path)
                }
            case "terminal-nvim-quit":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyTerminalNvimQuitSmokeScenario(resultPath: path)
                }
            case "nvim-scroll":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimScrollSmokeScenario(resultPath: path)
                }
            case "nvim-jump":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimJumpSmokeScenario(resultPath: path)
                }
            case "nvim-side-pane":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimSidePaneSmokeScenario(resultPath: path)
                }
            case "nvim-commandline":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimCommandLineSmokeScenario(resultPath: path)
                }
            case "nvim-cursor-move":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimCursorMoveSmokeScenario(resultPath: path)
                }
            case "nvim-shaped-text":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimShapedTextSmokeScenario(resultPath: path)
                }
            case "nvim-skia":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimSkiaSmokeScenario(resultPath: path)
                }
            case "nvim-layout-redraw":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimLayoutRedrawSmokeScenario(resultPath: path)
                }
            case "nvim-image":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimImageSmokeScenario(resultPath: path)
                }
            case "nvim-ui-surfaces":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimUiSurfacesSmokeScenario(resultPath: path)
                }
            case "nvim-popupmenu":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimPopupmenuSmokeScenario(resultPath: path)
                }
            case "nvim-file-tree":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimFileTreeSmokeScenario(resultPath: path)
                }
            case "nvim-file-tree-cursor-move":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimFileTreeCursorMoveSmokeScenario(resultPath: path)
                }
            case "nvim-file-tree-close":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimFileTreeCloseSmokeScenario(resultPath: path)
                }
            case "nvim-cursor-switch":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimCursorSwitchSmokeScenario(resultPath: path)
                }
            case "nvim-cursor-shape":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimCursorShapeSmokeScenario(resultPath: path)
                }
            case "nvim-cursor-normal-shape":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimCursorNormalShapeSmokeScenario(resultPath: path)
                }
            case "nvim-cursor-replace-shape":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimCursorReplaceShapeSmokeScenario(resultPath: path)
                }
            case "nvim-cursor-blink":
                if let path = environment["SATIN_NATIVE_SMOKE_RESULT"], !path.isEmpty {
                    controller.applyNvimCursorBlinkSmokeScenario(resultPath: path)
                }
            default:
                break
            }
        }

        func scheduleSmokeShotIfNeeded(_ window: NSWindow) {
            let environment = ProcessInfo.processInfo.environment
            guard let path = environment["SATIN_NATIVE_SMOKE_SHOT"], !path.isEmpty else {
                return
            }
            let targetWindow =
                environment["SATIN_NATIVE_SMOKE_SCENARIO"] == "settings"
                ? settingsWindowController?.window ?? window
                : window

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak targetWindow] in
                if let targetWindow {
                    self.writeSmokeShot(path: path, window: targetWindow)
                }
                NSApp.terminate(nil)
            }
        }

        func writeSmokeWindowIdIfNeeded(_ window: NSWindow) {
            let environment = ProcessInfo.processInfo.environment
            guard let path = environment["SATIN_NATIVE_SMOKE_WINDOW_ID"], !path.isEmpty else {
                return
            }
            let targetWindow =
                environment["SATIN_NATIVE_SMOKE_SCENARIO"] == "settings"
                ? settingsWindowController?.window ?? window
                : window
            writeSmokeWindowId(path: path, window: targetWindow, attempts: 20)
        }

        func writeSmokeWindowId(path: String, window: NSWindow, attempts: Int) {
            if window.windowNumber > 0 {
                try? "\(window.windowNumber)\n".write(
                    toFile: path,
                    atomically: true,
                    encoding: .utf8
                )
                return
            }
            if let windowId = cgWindowNumberForCurrentProcess() {
                try? "\(windowId)\n".write(
                    toFile: path,
                    atomically: true,
                    encoding: .utf8
                )
                return
            }
            guard attempts > 0 else {
                try? "\(window.windowNumber)\n".write(
                    toFile: path,
                    atomically: true,
                    encoding: .utf8
                )
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak window] in
                guard let window else {
                    return
                }
                self?.writeSmokeWindowId(path: path, window: window, attempts: attempts - 1)
            }
        }

        func cgWindowNumberForCurrentProcess() -> Int? {
            let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
            guard
                let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                    as? [[String: Any]]
            else {
                return nil
            }
            let pid = Int(ProcessInfo.processInfo.processIdentifier)
            return
                windows
                .filter { info in
                    cgWindowInt(info[kCGWindowOwnerPID as String]) == pid
                        && cgWindowInt(info[kCGWindowLayer as String]) == 0
                }
                .max { lhs, rhs in
                    cgWindowArea(lhs) < cgWindowArea(rhs)
                }
                .flatMap { cgWindowInt($0[kCGWindowNumber as String]) }
        }

        func cgWindowArea(_ info: [String: Any]) -> Double {
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else {
                return 0
            }
            let width = cgWindowBoundValue(bounds["Width"])
            let height = cgWindowBoundValue(bounds["Height"])
            return width * height
        }

        func cgWindowInt(_ value: Any?) -> Int? {
            switch value {
            case let value as Int:
                return value
            case let value as Int32:
                return Int(value)
            case let value as Int64:
                return Int(value)
            case let value as NSNumber:
                return value.intValue
            default:
                return nil
            }
        }

        func cgWindowBoundValue(_ value: Any?) -> Double {
            switch value {
            case let value as Double:
                return value
            case let value as CGFloat:
                return Double(value)
            case let value as NSNumber:
                return value.doubleValue
            default:
                return 0
            }
        }

        func writeSmokeShot(path: String, window: NSWindow) {
            guard let contentView = window.contentView else {
                return
            }
            contentView.setFrameSize(
                contentView.window?.contentLayoutRect.size ?? contentView.frame.size)
            contentView.layoutSubtreeIfNeeded()
            contentView.displayIfNeeded()
            let bounds = contentView.bounds
            guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                return
            }
            contentView.cacheDisplay(in: bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                return
            }
            try? data.write(to: URL(fileURLWithPath: path))
        }

    }
#endif

import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        /// Lays out two local tabs, the first split side by side, each pane
        /// in its own folder under `folder`, then makes the tmux session
        /// `sessionName` as a copy of them. RESULT says once it is attached;
        /// the script reads the windows from tmux.
        func applyTmuxCopyLocalSmokeScenario(
            resultPath: String,
            sessionName: String,
            folder: String,
            socketPath: String,
            executablePath: String
        ) {
            resolvedTmuxExecutable = NativeTmuxExecutable(
                path: executablePath, version: "smoke", source: .configured)
            lastTmuxSocketPath = socketPath
            func cd(_ name: String) {
                writeTextToActivePane("cd \(shellQuote("\(folder)/\(name)"))\r")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                cd("left")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self else { return }
                    self.splitVertical(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self else { return }
                        cd("right")
                        self.newTab(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                            guard let self else { return }
                            cd("second")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                [weak self] in
                                self?.createTmuxSession(named: sessionName, copyingLocalTabs: true)
                                self?.waitForTmuxCopyLocal(
                                    resultPath, sessionName: sessionName, retries: 100)
                            }
                        }
                    }
                }
            }
        }

        private func waitForTmuxCopyLocal(_ resultPath: String, sessionName: String, retries: Int) {
            let tabs = lastSnapshot?.tabs.count ?? 0
            if tmuxSession?.sessionName == sessionName, tabs == 2 {
                try? "ok tmux-copy-local tabs=\(tabs)\n".write(
                    toFile: resultPath, atomically: true, encoding: .utf8)
                return
            }
            guard retries > 0 else {
                let screen =
                    activePaneId.flatMap { paneStore.runtimes[$0]?.controlScreenText() } ?? ""
                FileHandle.standardError.write(
                    Data(
                        ("commands=\(tmuxConnectionCommandHistory)\n"
                            + "errors=\(tmuxSessionErrorHistory)\nscreen=\(screen)\n").utf8))
                try?
                    "failed tmux-copy-local session=\(tmuxSession?.sessionName ?? "none") tabs=\(tabs)\n"
                    .write(toFile: resultPath, atomically: true, encoding: .utf8)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.waitForTmuxCopyLocal(
                    resultPath, sessionName: sessionName, retries: retries - 1)
            }
        }
    }
#endif

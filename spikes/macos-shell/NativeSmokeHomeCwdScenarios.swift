import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func applyHomeWorkingDirectorySmokeScenario(resultPath: String) {
            waitForHomeWorkingDirectory(resultPath: resultPath, retries: 40)
        }

        private func waitForHomeWorkingDirectory(resultPath: String, retries: Int) {
            drainTerminalPanes()
            let expected = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            let actual = inheritedPaneWorkingDirectory()
            let processDirectory = FileManager.default.currentDirectoryPath
            let ready =
                settings.startupDirectory.isEmpty
                && processDirectory == "/"
                && actual == expected
            if !ready, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.waitForHomeWorkingDirectory(
                        resultPath: resultPath,
                        retries: retries - 1
                    )
                }
                return
            }
            writeSessionSmokeResult(
                resultPath,
                result: "\(ready ? "ok" : "failed") home-cwd startup=default "
                    + "process=\(processDirectory == "/" ? "root" : "other") "
                    + "pane=\(actual == expected ? "home" : "other")\n"
            )
        }
    }
#endif

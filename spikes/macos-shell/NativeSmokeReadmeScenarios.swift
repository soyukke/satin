import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func applyReadmeDemoScenario(resultPath: String) {
            waitForReadmeDemoReady(resultPath, retries: 100)
        }

        func waitForReadmeDemoReady(_ resultPath: String, retries: Int) {
            let ready =
                view.window != nil
                && artifactButton.superview != nil
                && workSwitcherButton.superview != nil
                && !controlSocketPath.isEmpty
            guard ready else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForReadmeDemoReady(resultPath, retries: retries - 1)
                    }
                } else {
                    writeReadmeDemoResult(
                        resultPath,
                        result: "failed readme-demo controls=unavailable\n"
                    )
                    NSApp.terminate(nil)
                }
                return
            }
            writeReadmeDemoResult(resultPath, result: "ok readme-demo ready=yes\n")
            waitForReadmeWorkSwitcherTrigger(resultPath, retries: 1_200)
            pollReadmeHandPlay(resultPath, retries: 2_400)
        }

        /// Plays the first attention card each time the recipe drops a `.play` file.
        func pollReadmeHandPlay(_ resultPath: String, retries: Int) {
            let trigger = "\(resultPath).play"
            if FileManager.default.fileExists(atPath: trigger) {
                try? FileManager.default.removeItem(atPath: trigger)
                jumpToWaitingAgent(nil)
            }
            for (suffix, action) in [
                ("select", { [weak self] in self?.advanceAttentionSelection() }),
                ("commit", { [weak self] in self?.commitAttentionSelection() }),
                ("binder", { [weak self] in self?.togglePageBinder(nil) }),
                ("deal", { [weak self] in self?.pageBinder?.toggleDeal() }),
                ("read", { [weak self] in self?.openFirstUnreadPageForSmoke() }),
                ("close", { [weak self] in self?.closePageReader() }),
                ("older", { [weak self] in self?.stepPageForSmoke(-1) }),
                ("mode", { [weak self] in self?.toggleAppearanceModeForSmoke() }),
                ("newer", { [weak self] in self?.stepPageForSmoke(1) }),
            ] where FileManager.default.fileExists(atPath: "\(resultPath).\(suffix)") {
                try? FileManager.default.removeItem(atPath: "\(resultPath).\(suffix)")
                action()
            }
            guard retries > 0 else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.pollReadmeHandPlay(resultPath, retries: retries - 1)
            }
        }

        func toggleAppearanceModeForSmoke() {
            settings.appearanceMode =
                appearanceMode == .paper
                ? NativeAppearanceMode.terminal.rawValue : NativeAppearanceMode.paper.rawValue
            applyAppearanceMode()
        }

        func stepPageForSmoke(_ step: Int) {
            if let page = pageReaderPage {
                openPage(page, version: UInt32(max(1, Int(pageReaderVersion) + step)))
            }
        }

        func openFirstUnreadPageForSmoke() {
            if let page = pageInbox.unread.first {
                openPage(page)
            }
        }

        func waitForReadmeWorkSwitcherTrigger(_ resultPath: String, retries: Int) {
            guard !smokeState.readmeWorkSwitcherOpened else {
                return
            }
            if FileManager.default.fileExists(atPath: "\(resultPath).work") {
                smokeState.readmeWorkSwitcherOpened = true
                showWorkSwitcher(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    let status = self?.workSwitcherPopover?.isShown == true ? "ok" : "failed"
                    self?.writeReadmeDemoResult(
                        "\(resultPath).work-open",
                        result: "\(status) readme-demo work-switcher=yes\n"
                    )
                }
                return
            }
            guard retries > 0 else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.waitForReadmeWorkSwitcherTrigger(resultPath, retries: retries - 1)
            }
        }

        func writeReadmeDemoResult(_ path: String, result: String) {
            try? result.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
#endif

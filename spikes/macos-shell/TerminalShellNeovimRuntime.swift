import AppKit
import Foundation

extension TerminalShellViewController {
    func scheduleNvimCommand(
        _ command: String,
        paneId: Int?,
        fallback: Data? = nil,
        delay: TimeInterval = nvimStartupCommandDelay
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let targetPaneId = paneId ?? self.activePaneId else {
                return
            }
            self.runNvimCommand(command, paneId: targetPaneId, fallback: fallback)
        }
    }

    func scheduleNvimDirectoryCorrection(paneId: Int, directory: String) {
        scheduleNvimCommand(
            neovimChangeDirectoryCommand(directory),
            paneId: paneId,
            delay: nvimStartupCwdCorrectionDelay
        )
    }

    func runNvimCommand(_ command: String, paneId: Int, fallback: Data?) {
        guard let pane = paneStore.runtimes[paneId] as? RustNeovimPane else {
            return
        }
        if pane.runCommand(command) {
            drainTerminalPanes()
        } else if let fallback {
            pane.write(fallback)
            drainTerminalPanes()
        }
    }
}

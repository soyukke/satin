import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func verifyPaneFinderActionForSmoke(paneId: Int, expectedCwd: String) -> Bool {
            view.layoutSubtreeIfNeeded()
            terminalTextView.refreshPaneChromeActionAvailability(paneId: paneId)
            guard let chrome = terminalTextView.paneChromeView(for: paneId),
                chrome.actionEnabledForSmoke(.openInFinder),
                chrome.finderPresentationReadyForSmoke()
            else {
                return false
            }

            let originalOpener = paneDirectoryOpener
            var openedURL: URL?
            paneDirectoryOpener = { url in
                openedURL = url
                return true
            }
            defer {
                paneDirectoryOpener = originalOpener
            }

            let activePaneBefore = activePaneId
            let paneIdsBefore = lastSnapshot?.tabs.map(\.panes)
            chrome.performForSmoke(.openInFinder)
            let finderMenuItem = terminalContextMenu(paneId: paneId).items.first {
                $0.action == #selector(openPaneDirectoryFromContextMenu(_:))
            }
            let expected = URL(fileURLWithPath: expectedCwd).standardizedFileURL.path
            return openedURL?.standardizedFileURL.path == expected
                && activePaneId == activePaneBefore
                && lastSnapshot?.tabs.map(\.panes) == paneIdsBefore
                && finderMenuItem?.representedObject as? Int == paneId
                && finderMenuItem?.isEnabled == true
        }

        func paneFinderRejectsInvalidDirectoryForSmoke(parentDirectory: String) -> Bool {
            guard tmuxSession == nil else {
                return true
            }
            let paneId = Int.min + 17
            let invalidDirectory = URL(fileURLWithPath: parentDirectory, isDirectory: true)
                .appendingPathComponent("removed-pane-cwd", isDirectory: true).path
            paneStore.workingDirectories[paneId] = invalidDirectory
            defer {
                paneStore.workingDirectories.removeValue(forKey: paneId)
            }
            return paneWorkingDirectory(paneId: paneId, logFailure: false) == nil
        }
    }
#endif

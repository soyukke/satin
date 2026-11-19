import AppKit

/// Worktrees made from a pane's header: one is created beside the pane's
/// repository and opened in a split, and closing the last pane that shows it
/// offers to delete it.
extension TerminalShellViewController {
    /// The Satin worktree a pane is in. It reads only the file system, so a
    /// header can ask whenever it updates.
    func paneWorktree(paneId: Int, current: Bool = false) -> NativeGitWorktree? {
        paneWorkingDirectory(paneId: paneId, logFailure: false, current: current)
            .flatMap(NativeGitWorktree.containing)
    }

    func paneCanCreateWorktree(paneId: Int) -> Bool {
        paneWorkingDirectory(paneId: paneId, logFailure: false)
            .map(NativeGitWorktree.isInsideCheckout) ?? false
    }

    /// Asks for a branch name, then makes and opens its worktree.
    func requestNewWorktree(paneId: Int) {
        guard let directory = paneWorkingDirectory(paneId: paneId, logFailure: true, current: true)
        else {
            presentPaneWorkingDirectoryError(title: "Could Not Create Worktree")
            return
        }
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "Branch name"
        let alert = NSAlert()
        alert.messageText = "New Worktree"
        alert.informativeText =
            "Satin creates a worktree for the branch next to the repository and opens it in a "
            + "new pane. A new branch starts from the pane’s current commit."
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        presentWorktreeAlert(alert) { [weak self] response in
            let branch = input.stringValue.trimmingCharacters(in: .whitespaces)
            guard let self, response == .alertFirstButtonReturn, !branch.isEmpty else {
                self?.focusTerminal()
                return
            }
            self.createWorktree(paneId: paneId, directory: directory, branch: branch) { _ in }
        }
    }

    /// Makes the worktree off the main thread, then opens it beside the pane;
    /// completion says whether it did.
    func createWorktree(
        paneId: Int,
        directory: String,
        branch: String,
        completion: @escaping (Bool) -> Void
    ) {
        let shellPath = settings.shellPath
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<NativeGitWorktree, NativeGit.Failure> =
                NativeTmuxExecutableResolver.locate("git", shellPath: shellPath)
                .map { NativeGit(executable: $0).createWorktree(from: directory, branch: branch) }
                ?? .failure(NativeGit.Failure(message: "Satin could not find git."))
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                switch result {
                case .success(let worktree):
                    NativeLog.lifecycleInfo("worktree_created pane=\(paneId) path=\(worktree.path)")
                    self.splitPane(paneId, axis: ffiSplitVertical, cwd: worktree.path)
                    self.focusTerminal()
                    completion(true)
                case .failure(let failure):
                    NativeLog.runtimeError(
                        "worktree_create_failed pane=\(paneId) reason=\(failure.message)")
                    self.presentWorktreeError(
                        title: "Could Not Create Worktree", detail: failure.message)
                    completion(false)
                }
            }
        }
    }

    /// The worktree that closing the pane leaves no pane showing.
    func worktreeClosedWithPane(_ paneId: Int) -> NativeGitWorktree? {
        guard let worktree = paneWorktree(paneId: paneId, current: true) else {
            return nil
        }
        let otherPaneIds: [Int] =
            if let session = tmuxSession {
                Array(session.tmuxPaneIds.keys)
            } else {
                lastSnapshot?.tabs.flatMap(\.panes) ?? []
            }
        let shownElsewhere = otherPaneIds.contains {
            $0 != paneId && paneWorktree(paneId: $0)?.path == worktree.path
        }
        return shownElsewhere ? nil : worktree
    }

    /// Asks before closing the last pane of a worktree, with a choice to
    /// delete it. A worktree with changes cannot be deleted from here.
    func confirmClosingWorktreePane(_ paneId: Int, worktree: NativeGitWorktree, busy: Bool) {
        let shellPath = settings.shellPath
        DispatchQueue.global(qos: .userInitiated).async {
            let hasChanges =
                NativeTmuxExecutableResolver.locate("git", shellPath: shellPath)
                .map { NativeGit(executable: $0).hasChanges(worktree) } ?? true
            DispatchQueue.main.async { [weak self] in
                self?.presentClosingWorktreePane(
                    paneId,
                    worktree: worktree,
                    busy: busy,
                    hasChanges: hasChanges
                )
            }
        }
    }

    private func presentClosingWorktreePane(
        _ paneId: Int,
        worktree: NativeGitWorktree,
        busy: Bool,
        hasChanges: Bool
    ) {
        let name = worktree.branch ?? URL(fileURLWithPath: worktree.path).lastPathComponent
        var detail =
            busy ? "A program is still running in this pane. Closing the pane ends it. " : ""
        detail += "No other pane shows the worktree for “\(name)”."
        if hasChanges {
            detail += " It has uncommitted changes, so it can’t be deleted."
        }
        let delete = NSButton(checkboxWithTitle: "Delete Worktree", target: nil, action: nil)
        delete.state = .off
        delete.isEnabled = !hasChanges
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close this pane?"
        alert.informativeText = detail
        alert.accessoryView = delete
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        presentWorktreeAlert(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else {
                self?.focusTerminal()
                return
            }
            self.closeWorktreePane(
                paneId,
                worktree: worktree,
                deleting: delete.isEnabled && delete.state == .on
            ) { _ in }
        }
    }

    /// Closes the pane, then deletes its worktree when asked; completion says
    /// whether the worktree is gone, or false when it was kept.
    func closeWorktreePane(
        _ paneId: Int,
        worktree: NativeGitWorktree,
        deleting: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard tmuxSession?.tmuxPaneIds[paneId] != nil || paneStore.runtimes[paneId] != nil else {
            completion(false)
            return
        }
        closePane(paneId)
        guard deleting else {
            completion(false)
            return
        }
        let shellPath = settings.shellPath
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, NativeGit.Failure> =
                NativeTmuxExecutableResolver.locate("git", shellPath: shellPath)
                .map { NativeGit(executable: $0).removeWorktree(worktree) }
                ?? .failure(NativeGit.Failure(message: "Satin could not find git."))
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success:
                    NativeLog.lifecycleInfo("worktree_deleted path=\(worktree.path)")
                    completion(true)
                case .failure(let failure):
                    NativeLog.runtimeError(
                        "worktree_delete_failed path=\(worktree.path) reason=\(failure.message)")
                    self?.presentWorktreeError(
                        title: "Could Not Delete Worktree", detail: failure.message)
                    completion(false)
                }
            }
        }
    }

    private func presentWorktreeError(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        presentWorktreeAlert(alert) { [weak self] _ in
            self?.focusTerminal()
        }
    }

    private func presentWorktreeAlert(
        _ alert: NSAlert,
        completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = view.window, window.isVisible {
            guard window.attachedSheet == nil else {
                return
            }
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

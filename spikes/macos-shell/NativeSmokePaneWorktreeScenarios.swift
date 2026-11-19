import Foundation

#if SATIN_SMOKE_SCENARIOS
    /// Whether a path names the same directory as expected once links resolve:
    /// a pane reports `/var/...` for git's `/private/var/...`.
    private func sameWorktreeSmokePath(_ expected: String) -> (String) -> Bool {
        let resolved = URL(fileURLWithPath: expected).resolvingSymlinksInPath().path
        return { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == resolved }
    }

    /// Makes a worktree from a pane's header in a scratch repository, opens it
    /// in a split, and deletes it as closing its last pane would.
    extension TerminalShellViewController {
        func applyPaneWorktreeSmokeScenario(resultPath: String, repository: String) {
            pollPaneWorktreeSmoke(resultPath: resultPath, phase: "startup", retries: 80) {
                [weak self] in
                guard let self, let paneId = self.activePaneId,
                    let pane = self.paneStore.runtimes[paneId] as? TerminalPane
                else {
                    return false
                }
                pane.write(Data("builtin cd -- \(shellQuote(repository))\r".utf8))
                return true
            } then: { [weak self] in
                self?.waitForPaneWorktreeSmokeRepository(
                    resultPath: resultPath, repository: repository)
            }
        }

        private func waitForPaneWorktreeSmokeRepository(resultPath: String, repository: String) {
            let paneId = activePaneId ?? -1
            pollPaneWorktreeSmoke(resultPath: resultPath, phase: "cd", retries: 120) {
                [weak self] in
                self?.paneWorkingDirectory(paneId: paneId, logFailure: false).map(
                    sameWorktreeSmokePath(repository)) == true
            } then: { [weak self] in
                self?.createPaneWorktreeForSmoke(
                    resultPath: resultPath, paneId: paneId, repository: repository)
            }
        }

        private func createPaneWorktreeForSmoke(resultPath: String, paneId: Int, repository: String)
        {
            terminalTextView.refreshPaneChromeActionAvailability(paneId: paneId)
            let chrome = terminalTextView.paneChromeView(for: paneId)
            guard chrome?.actionEnabledForSmoke(.newWorktree) == true,
                chrome?.worktreeBranchForSmoke() == nil,
                worktreeClosedWithPane(paneId) == nil
            else {
                writeSessionSmokeResult(
                    resultPath,
                    result: "failed pane-worktree phase=enabled "
                        + "enabled=\(chrome?.actionEnabledForSmoke(.newWorktree) == true)\n"
                )
                return
            }
            let branch = "smoke/branch"
            let expected = NativeGitWorktree.location(repository: repository, branch: branch)
            let panesBefore = Set(lastSnapshot?.tabs.flatMap(\.panes) ?? [])
            createWorktree(paneId: paneId, directory: repository, branch: branch) {
                [weak self] created in
                guard let self, created else {
                    self?.writeSessionSmokeResult(
                        resultPath, result: "failed pane-worktree phase=create\n")
                    return
                }
                var newPaneId: Int?
                self.pollPaneWorktreeSmoke(resultPath: resultPath, phase: "split", retries: 160) {
                    newPaneId =
                        Set(self.lastSnapshot?.tabs.flatMap(\.panes) ?? [])
                        .subtracting(panesBefore).first
                    guard let newPaneId else {
                        return false
                    }
                    self.terminalTextView.refreshPaneChromeActionAvailability(paneId: newPaneId)
                    return self.paneWorkingDirectory(paneId: newPaneId, logFailure: false)
                        .map(sameWorktreeSmokePath(expected)) == true
                        && self.terminalTextView.paneChromeView(for: newPaneId)?
                            .worktreeBranchForSmoke() == branch
                } then: {
                    guard let newPaneId else {
                        return
                    }
                    self.deletePaneWorktreeForSmoke(
                        resultPath: resultPath,
                        paneId: newPaneId,
                        repository: repository,
                        branch: branch
                    )
                }
            }
        }

        private func deletePaneWorktreeForSmoke(
            resultPath: String,
            paneId: Int,
            repository: String,
            branch: String
        ) {
            guard let worktree = worktreeClosedWithPane(paneId), worktree.branch == branch else {
                writeSessionSmokeResult(
                    resultPath, result: "failed pane-worktree phase=last-pane\n")
                return
            }
            closeWorktreePane(paneId, worktree: worktree, deleting: true) { [weak self] deleted in
                guard let self else {
                    return
                }
                let branchKept =
                    NativeTmuxExecutableResolver.locate("git", shellPath: "").flatMap {
                        NativeGit(executable: $0).run(
                            ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
                            in: repository,
                            timeout: 10
                        )
                    }?.status == 0
                let gone = !FileManager.default.fileExists(atPath: worktree.path)
                let paneClosed = self.lastSnapshot?.tabs.flatMap(\.panes).contains(paneId) == false
                let ok = deleted && gone && branchKept && paneClosed
                self.writeSessionSmokeResult(
                    resultPath,
                    result: "\(ok ? "ok" : "failed") pane-worktree enabled=yes created=yes "
                        + "split=yes badge=yes last-pane=yes "
                        + "deleted=\(deleted && gone ? "yes" : "no") "
                        + "pane-closed=\(paneClosed ? "yes" : "no") "
                        + "branch-kept=\(branchKept ? "yes" : "no")\n"
                )
            }
        }

        /// Runs step every 50 ms until it holds, then next; writes a failure
        /// naming phase when it never does.
        private func pollPaneWorktreeSmoke(
            resultPath: String,
            phase: String,
            retries: Int,
            step: @escaping () -> Bool,
            then next: @escaping () -> Void
        ) {
            drainTerminalPanes()
            if step() {
                next()
                return
            }
            guard retries > 0 else {
                writeSessionSmokeResult(resultPath, result: "failed pane-worktree phase=\(phase)\n")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.pollPaneWorktreeSmoke(
                    resultPath: resultPath,
                    phase: phase,
                    retries: retries - 1,
                    step: step,
                    then: next
                )
            }
        }
    }
#endif

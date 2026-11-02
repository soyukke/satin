import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        /// Prints what the items sidebar looks for, gives two tabs a state,
        /// then writes what both sidebars hold to RESULT. With
        /// SATIN_NATIVE_SMOKE_SIDEBAR_SNAPSHOT set, it also draws the window
        /// into that prefix's PNGs, open and folded, in both looks.
        func applySidebarsSmokeScenario(resultPath: String) {
            let lines = [
                "● Read(core/src/tmux/control.kizu)",
                "  ! satin page put design.md",
                "  The pull request is at https://github.com/example/satin/pull/207.",
                "> Windows sit on the left.",
                "> What each tab made sits on the right.",
                "error at TerminalShellTabs.swift:88:4",
                "Saved the shot to ./shots/sidebar.png.",
            ]
            // The shot is there, in a folder the pane goes to, so the row
            // leads to it.
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("satin-sidebars-\(getpid())")
            try? FileManager.default.createDirectory(
                at: folder.appendingPathComponent("shots"), withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: folder.appendingPathComponent("shots/sidebar.png").path, contents: Data())
            let quoted = lines.map { "'\($0)'" }.joined(separator: " ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.writeTextToActivePane(
                    "clear; cd '\(folder.path)'; printf '%s\\n' \(quoted)\r")
                if let pane = self.activePaneId {
                    self.paneStatuses.update(
                        paneId: pane, status: "waiting",
                        summary: "Wants to edit TerminalShellTabs.swift")
                }
                self.newTab(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    if let pane = self.activePaneId {
                        self.paneStatuses.update(
                            paneId: pane, status: "running", summary: "kizu test .")
                    }
                    self.selectTab(0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                        self?.finishSidebarsSmoke(resultPath)
                    }
                }
            }
        }

        private func finishSidebarsSmoke(_ resultPath: String) {
            scanSidebarScreens()
            let rows = windowsSidebar.rows
            let items = itemsSidebar.rowsForSmoke()
            let kinds = NativeSidebarItemKind.allCases.map { kind in
                "\(kind)=\(items.filter { $0.kind == kind }.count)"
            }.joined(separator: " ")
            let states = rows.map(\.state.title).joined(separator: ",")
            let shot = items.first { $0.text == "./shots/sidebar.png" }
            let leads =
                shot.flatMap(sidebarItemURL)?.resolvingSymlinksInPath().path.hasSuffix(
                    "satin-sidebars-\(getpid())/shots/sidebar.png") == true
            windowsSidebar.pressSessionsForSmoke()
            let sessions =
                sessionPopover?.contentViewController is TmuxSessionPopoverController
                ? "shown" : "missing"
            dismissSessionPopover()
            let result =
                "ok sidebars rows=\(rows.count) states=\(states) "
                + "items=\(items.count) \(kinds) tabbar=\(tabStripView.isHidden ? "hidden" : "shown")"
                + " hand=\(attentionHandView.isHidden ? "hidden" : "shown")"
                + " sessions=\(sessions) opens=\(leads ? "file" : "missing")\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            guard
                let prefix = ProcessInfo.processInfo.environment[
                    "SATIN_NATIVE_SMOKE_SIDEBAR_SNAPSHOT"]
            else {
                NSApp.terminate(nil)
                return
            }
            let steps: [(String, NativeSidebarMode, NativeSidebarMode, Bool)] = [
                ("open-datasheet", .open, .open, false),
                ("rail-datasheet", .rail, .rail, false),
                ("open-paper", .open, .open, true),
                ("rail-paper", .rail, .rail, true),
            ]
            snapshotSidebarsForSmoke(prefix, steps: steps[...])
        }

        private func snapshotSidebarsForSmoke(
            _ prefix: String,
            steps: ArraySlice<(String, NativeSidebarMode, NativeSidebarMode, Bool)>
        ) {
            guard let (name, left, right, paper) = steps.first else {
                try? Data().write(to: URL(fileURLWithPath: "\(prefix)-done"))
                NSApp.terminate(nil)
                return
            }
            if paper != (appearanceMode == .paper) {
                toggleAppearanceModeForSmoke()
            }
            windowsSidebarMode = left
            itemsSidebarMode = right
            applySidebarModes()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self else { return }
                self.writeWindowSnapshotForSmoke("\(prefix)-\(name).png")
                self.snapshotSidebarsForSmoke(prefix, steps: steps.dropFirst())
            }
        }
    }
#endif

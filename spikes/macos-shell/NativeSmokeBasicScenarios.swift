import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalShellViewController {
        func applySmokeScenario(resultPath: String?) {
            core.newTab()
            core.renameTab(1, title: "native smoke")
            core.setTheme("Harbor", tab: 1)
            _ = core.splitActive(axis: ffiSplitVertical)
            syncFromCore()
            writeToActivePane(
                Data(
                    ("printf 'native pty view ready: renderer text marker\\n"
                        + "native pty view ready: second text marker\\n'\r").utf8))
            guard let resultPath, !resultPath.isEmpty else {
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.writeNativeSmokeResult(resultPath, retries: 12)
            }
        }

        func applySessionSchemaSmokeScenario(resultPath: String) {
            _ = core.splitActive(axis: ffiSplitVertical)
            _ = core.splitActive(axis: ffiSplitHorizontal)
            _ = core.resizeSplit(firstPaneId: 1, secondPaneId: 2, ratio: 0.35)
            _ = core.resizeSplit(firstPaneId: 2, secondPaneId: 3, ratio: 0.65)
            syncFromCore()
            if let snapshot = lastSnapshot,
                let activeTab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab })
            {
                paneStore.tabTitles.markManual(tabId: activeTab.id)
            }
            guard let state = currentSessionState(),
                let data = try? JSONEncoder().encode(state),
                let decoded = decodeSessionState(data)
            else {
                writeSessionSmokeResult(resultPath, result: "failed session-schema encode\n")
                return
            }
            let legacy = LegacyNativeSessionState(
                activeTab: 0,
                tabs: [LegacyNativeSessionTab(title: "legacy", theme: "Graphite", cwd: "/tmp")]
            )
            let migrated = (try? JSONEncoder().encode(legacy)).flatMap(decodeSessionState)
            let attachment = NativeTmuxAttachment(
                sessionName: "persisted-session",
                socketPath: "/tmp/persisted-tmux.sock",
                executablePath: "/usr/bin/tmux"
            )
            let attachedState = NativeSessionState(
                schemaVersion: currentSessionSchemaVersion,
                activeTab: state.activeTab,
                tabs: state.tabs,
                tmuxAttachment: attachment
            )
            let attachedData = try? JSONEncoder().encode(attachedState)
            let attachedRoundTrip = attachedData.flatMap(decodeSessionState)
            let consumed = sessionStateWithoutTmuxAttachment(attachedState)
            var versionTwoObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            versionTwoObject?["schemaVersion"] = 2
            versionTwoObject?.removeValue(forKey: "tmuxAttachment")
            let versionTwoData = versionTwoObject.flatMap {
                try? JSONSerialization.data(withJSONObject: $0)
            }
            let versionTwoMigrated = versionTwoData.flatMap(decodeSessionState)
            var versionThreeObject = attachedData.flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }
            versionThreeObject?["schemaVersion"] = 3
            var versionThreeAttachment =
                versionThreeObject?["tmuxAttachment"] as? [String: Any]
            versionThreeAttachment?.removeValue(forKey: "executablePath")
            versionThreeObject?["tmuxAttachment"] = versionThreeAttachment
            let versionThreeData = versionThreeObject.flatMap {
                try? JSONSerialization.data(withJSONObject: $0)
            }
            let versionThreeMigrated = versionThreeData.flatMap(decodeSessionState)
            let versionThreeExpected = NativeTmuxAttachment(
                sessionName: attachment.sessionName,
                socketPath: attachment.socketPath
            )
            let corruptRejected = decodeSessionState(Data("{not-json".utf8)) == nil
            let futureData = Data("{\"schemaVersion\":999}".utf8)
            let futurePreserved = sessionSchemaVersion(in: futureData) == 999
            let counts = sessionPaneCounts(decoded.tabs[decoded.activeTab].layout)
            let ratiosRetained =
                decoded.tabs[decoded.activeTab].layout.ratio == 0.35
                && decoded.tabs[decoded.activeTab].layout.second?.ratio == 0.65
            let manualTitleRetained = decoded.tabs[decoded.activeTab].titleIsManual == true
            let ok =
                decoded.schemaVersion == currentSessionSchemaVersion
                && counts.leaves == 3
                && counts.splits == 2
                && counts.activeLeaves == 1
                && ratiosRetained
                && manualTitleRetained
                && migrated?.schemaVersion == currentSessionSchemaVersion
                && migrated?.tabs.first?.layout.kind == "leaf"
                && attachedRoundTrip?.tmuxAttachment == attachment
                && consumed.tmuxAttachment == nil
                && versionTwoMigrated?.schemaVersion == currentSessionSchemaVersion
                && versionTwoMigrated?.tmuxAttachment == nil
                && versionThreeMigrated?.tmuxAttachment == versionThreeExpected
                && validatedTmuxAttachment(attachment) == attachment
                && validatedTmuxAttachment(
                    NativeTmuxAttachment(sessionName: "invalid", socketPath: "relative.sock")
                ) == nil
                && corruptRejected
                && futurePreserved
            let status = ok ? "ok" : "failed"
            writeSessionSmokeResult(
                resultPath,
                result: "\(status) session-schema version=\(decoded.schemaVersion) "
                    + "leaves=\(counts.leaves) splits=\(counts.splits) active=\(counts.activeLeaves) "
                    + "ratios=\(ratiosRetained ? "retained" : "lost") "
                    + "manual-title=\(manualTitleRetained ? "retained" : "lost") "
                    + "migration=\(migrated == nil ? "failed" : "ok") "
                    + "reattach=\(attachedRoundTrip?.tmuxAttachment == attachment ? "ok" : "failed") "
                    + "consume-once=\(consumed.tmuxAttachment == nil ? "ok" : "failed") "
                    + "corruption=rejected future=preserved\n"
            )
        }

        func applyTabBarActionsSmokeScenario(resultPath: String) {
            waitForTabBarActionsSmokeScenario(resultPath: resultPath, retries: 20)
        }

        func waitForTabBarActionsSmokeScenario(resultPath: String, retries: Int) {
            view.layoutSubtreeIfNeeded()
            let initialChrome = activePaneId.flatMap(terminalTextView.paneChromeView)
            let controlsReady =
                sessionControlButton.superview != nil
                && artifactButton.superview != nil
                && workSwitcherButton.superview != nil
                && tabStripView.superview != nil
                && tabStripView.actionsReady()
                && terminalTextView.paneChromeViewsReady(expectedCount: 1)
                && initialChrome?.actionsReady() == true
            let shortcutsReady =
                mainMenuShortcutMatches(
                    command: .showWorkSwitcher,
                    shortcut: settings.shortcut(for: .showWorkSwitcher)
                )
                && mainMenuShortcutMatches(
                    command: .splitVertical,
                    shortcut: settings.shortcut(for: .splitVertical)
                )
                && mainMenuShortcutMatches(
                    command: .splitHorizontal,
                    shortcut: settings.shortcut(for: .splitHorizontal)
                )
            if !controlsReady || !shortcutsReady, retries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.waitForTabBarActionsSmokeScenario(
                        resultPath: resultPath,
                        retries: retries - 1
                    )
                }
                return
            }
            updateTabStripToolbarWidth()
            let compactChrome =
                view.window?.toolbarStyle == .unifiedCompact
                && terminalTextView.paneChromeViews.values.allSatisfy {
                    $0.frame.height <= nativePaneChromeHeight
                }
            let contentBelowChrome = metalView.frame.maxY <= view.safeAreaRect.maxY + 0.5
            let backdropSpansWindow = backdropView.frame.maxY >= view.bounds.maxY - 0.5
            let tabStripFrame = tabStripView.convert(tabStripView.bounds, to: nil)
            let artifactFrame = artifactButton.convert(artifactButton.bounds, to: nil)
            let workFrame = workSwitcherButton.convert(workSwitcherButton.bounds, to: nil)
            let sessionFrame = sessionControlButton.convert(sessionControlButton.bounds, to: nil)
            let windowContentFrame = view.convert(view.bounds, to: nil)
            let toolbarControlsAreTrailing =
                artifactFrame.minX > tabStripFrame.maxX
                && workFrame.minX > artifactFrame.minX
                && sessionFrame.minX > workFrame.minX
                && sessionFrame.maxX >= windowContentFrame.maxX - 32
            if controlsReady {
                newTabButton.performClick(nil)
                activePaneId.flatMap(terminalTextView.paneChromeView)?
                    .performForSmoke(.splitVertical)
                activePaneId.flatMap(terminalTextView.paneChromeView)?
                    .performForSmoke(.splitHorizontal)
            }
            guard let snapshot = core.snapshot(),
                let activeTab = snapshot.tabs.first(where: { $0.index == snapshot.active_tab })
            else {
                writeSessionSmokeResult(
                    resultPath, result: "failed tab-bar-actions snapshot=missing\n")
                return
            }
            let metrics = paneLayoutMetrics(activeTab.layout)
            let axes = metrics.axes.sorted()
            let paneChromeReady = terminalTextView.paneChromeViewsReady(expectedCount: 3)
            let contentClearsPaneChrome = terminalTextView.paneBounds.allSatisfy { paneId, bounds in
                guard let content = paneStore.visibleFrames[paneId] else {
                    return false
                }
                return content.minY >= bounds.minY + nativePaneChromeHeight - 0.5
                    && content.maxY <= bounds.maxY + 0.5
            }
            let dividersReady =
                terminalTextView.splitDividerCount(for: .vertical) == 1
                && terminalTextView.splitDividerCount(for: .horizontal) == 1
            let cursorsReady =
                terminalTextView.splitDividerUsesResizeCursor(for: .vertical)
                && terminalTextView.splitDividerUsesResizeCursor(for: .horizontal)
            let firstRootPaneId = firstPaneId(in: activeTab.layout)
            let firstWidthBefore = firstRootPaneId.flatMap { paneStore.visibleFrames[$0]?.width }
            let dividerDragged = terminalTextView.resizeFirstDividerForSmoke(
                axis: .vertical,
                ratio: 0.35
            )
            let firstWidthAfter = firstRootPaneId.flatMap { paneStore.visibleFrames[$0]?.width }
            let paneFrameUpdated =
                if let firstWidthBefore, let firstWidthAfter {
                    firstWidthAfter < firstWidthBefore - 10
                } else {
                    false
                }
            let resizedRatio = core.snapshot()?.tabs
                .first(where: { $0.index == snapshot.active_tab })?.layout.ratio
            let ratioUpdated = resizedRatio.map { abs($0 - 0.35) < 0.001 } ?? false
            let contextMenuReady = tabControl.contextMenuReadyForSmoke(segment: snapshot.active_tab)
            let renamePromptReady = NativeRenamePanel.smokeLayoutReady()
            let originalRenameHandler = tabControl.onRenameRequested
            var renameRequestedSegment: Int?
            tabControl.onRenameRequested = { segment in
                renameRequestedSegment = segment
            }
            tabControl.simulateDoubleClickForSmoke(segment: snapshot.active_tab)
            tabControl.onRenameRequested = originalRenameHandler
            let renamedTitle = "renamed by tab click"
            if let renameRequestedSegment {
                core.renameTab(renameRequestedSegment, title: renamedTitle)
                syncFromCore()
            }
            let renameReady =
                renameRequestedSegment == snapshot.active_tab
                && core.snapshot()?.tabs.first(where: {
                    $0.index == snapshot.active_tab
                })?.title == renamedTitle
                && tabControl.label(forSegment: snapshot.active_tab) == renamedTitle
            let orderBeforeDrag = core.snapshot()?.tabs.map(\.id)
            let moved = tabControl.simulateMoveForSmoke(
                from: snapshot.active_tab,
                to: 0
            )
            let movedSnapshot = core.snapshot()
            let movedOrderReady =
                moved
                && movedSnapshot?.active_tab == 0
                && movedSnapshot?.tabs.map(\.id) == orderBeforeDrag.map { Array($0.reversed()) }
            let restored = tabControl.simulateMoveForSmoke(from: 0, to: snapshot.active_tab)
            let dragReady =
                movedOrderReady
                && restored
                && core.snapshot()?.active_tab == snapshot.active_tab
                && core.snapshot()?.tabs.map(\.id) == orderBeforeDrag
            let tabVisualsReady = tabControl.visualGeometryReadyForSmoke(
                segment: snapshot.active_tab
            )
            let paneCloseTarget = activeTab.active_pane
            terminalTextView.paneChromeView(for: paneCloseTarget)?.performForSmoke(.close)
            let paneClosedSnapshot = core.snapshot()
            let paneCloseReady =
                paneClosedSnapshot?.tabs.first(where: { $0.index == snapshot.active_tab })
                .map { paneLayoutMetrics($0.layout).leaves == 2 } == true
                && terminalTextView.paneChromeView(for: paneCloseTarget) == nil
                && terminalTextView.paneChromeViewsReady(expectedCount: 2)
            let closeTarget = tabControl.closeButtonHitTargetForSmoke(segment: 0)
            let closeTargetHasMinimumWidth = (closeTarget?.width ?? 0) >= 20
            let closeTargetFitsHorizontally =
                closeTarget.map {
                    $0.minX >= tabControl.bounds.minX && $0.maxX <= tabControl.bounds.maxX
                } ?? false
            let closeTargetFitsVertically =
                closeTarget.map {
                    $0.minY >= tabControl.bounds.minY && $0.maxY <= tabControl.bounds.maxY
                } ?? false
            let closeTargetReady =
                closeTargetHasMinimumWidth
                && closeTargetFitsHorizontally
                && closeTargetFitsVertically
            let originalCloseHandler = tabControl.onCloseRequested
            let tabWidthBeforeClose = tabControl.frame.width
            var closeRequestedSegment: Int?
            tabControl.onCloseRequested = { segment in
                closeRequestedSegment = segment
                return true
            }
            _ = tabControl.simulateCloseForSmoke(segment: 0)
            tabControl.onCloseRequested = originalCloseHandler
            if let closeRequestedSegment {
                _ = closeTab(at: closeRequestedSegment)
            }
            let closedSnapshot = core.snapshot()
            let closeReady =
                closeTargetReady
                && closeRequestedSegment == 0
                && closedSnapshot?.tabs.count == 1
                && closedSnapshot?.active_tab == 0
                && closedSnapshot?.tabs.first?.title == renamedTitle
                && tabControl.segmentCount == 1
                && tabControl.label(forSegment: 0) == renamedTitle
                && tabControl.frame.width < tabWidthBeforeClose
            if let window = view.window, let contentView = window.contentView {
                window.setContentSize(
                    NSSize(
                        width: min(1_024, contentView.bounds.width),
                        height: contentView.bounds.height
                    )
                )
            }
            for _ in 0..<9 {
                newTabButton.performClick(nil)
            }
            view.layoutSubtreeIfNeeded()
            let manyTabStripFrame = tabStripView.convert(tabStripView.bounds, to: nil)
            let manyTabViewportFrame = tabStripView.visibleTabViewportFrameForSmoke()
            let manyArtifactFrame = artifactButton.convert(artifactButton.bounds, to: nil)
            let manyWorkFrame = workSwitcherButton.convert(workSwitcherButton.bounds, to: nil)
            let manySessionFrame = sessionControlButton.convert(
                sessionControlButton.bounds, to: nil)
            let manyWindowContentFrame = view.convert(view.bounds, to: nil)
            let manyTabCount = core.snapshot()?.tabs.count ?? 0
            let manyTabStripInsideWindow =
                manyTabStripFrame.width > 0
                && manyTabStripFrame.minX >= manyWindowContentFrame.minX - 0.5
                && manyTabStripFrame.maxX <= manyWindowContentFrame.maxX + 0.5
            let manyTabToolbarControlsAreTrailing =
                manyTabCount == 10
                && manyTabStripInsideWindow
                && manyArtifactFrame.minX > manyTabStripFrame.maxX
                && manyWorkFrame.minX > manyArtifactFrame.minX
                && manySessionFrame.minX > manyWorkFrame.minX
                && manySessionFrame.maxX >= manyWindowContentFrame.maxX - 32
            let manyTabOverflowReady =
                tabStripView.overflowLayoutReadyForSmoke(expectedSegments: 10)
                && tabOverflowMenuReadyForSmoke(expectedCount: 10)
                && manyTabViewportFrame.maxX <= manyTabStripFrame.maxX + 0.5
                && manyTabViewportFrame.maxX < manyArtifactFrame.minX
            let manyTabContinuationReady =
                tabStripView.continuationAffordancesReadyForSmoke()
            let adaptiveTabWidth = adaptiveTabWidthResultForSmoke()
            let ok =
                controlsReady
                && shortcutsReady
                && paneChromeReady
                && compactChrome
                && contentBelowChrome
                && contentClearsPaneChrome
                && backdropSpansWindow
                && toolbarControlsAreTrailing
                && snapshot.tabs.count == 2
                && snapshot.active_tab == 1
                && metrics.leaves == 3
                && metrics.splits == 2
                && axes == ["horizontal", "vertical"]
                && dividersReady
                && cursorsReady
                && dividerDragged
                && ratioUpdated
                && paneFrameUpdated
                && contextMenuReady
                && renamePromptReady
                && renameReady
                && dragReady
                && tabVisualsReady
                && paneCloseReady
                && closeReady
                && manyTabToolbarControlsAreTrailing
                && manyTabOverflowReady
                && manyTabContinuationReady
                && adaptiveTabWidth.ready
            let status = ok ? "ok" : "failed"
            writeSessionSmokeResult(
                resultPath,
                result: "\(status) tab-bar-actions controls=\(controlsReady ? "ready" : "invalid") "
                    + "shortcuts=\(shortcutsReady ? "ready" : "invalid") "
                    + "chrome=\(paneChromeReady ? "pane-local" : "missing") "
                    + "density=\(compactChrome ? "compact" : "regular") "
                    + "content=\(contentBelowChrome && contentClearsPaneChrome ? "safe" : "overlap") "
                    + "background=\(backdropSpansWindow ? "edge-to-edge" : "inset") "
                    + "toolbar=\(toolbarControlsAreTrailing ? "trailing" : "misplaced") "
                    + "toolbar-x=\(Int(tabStripFrame.maxX))/\(Int(artifactFrame.minX))/"
                    + "\(Int(workFrame.minX))/\(Int(sessionFrame.minX))/"
                    + "\(Int(sessionFrame.maxX))/\(Int(windowContentFrame.maxX)) "
                    + "many-tab-toolbar="
                    + "\(manyTabToolbarControlsAreTrailing ? "trailing" : "misplaced") "
                    + "many-tabs=\(manyTabCount) "
                    + "many-tab-window="
                    + "\(manyTabStripInsideWindow ? "inside" : "outside") "
                    + "overflow=\(manyTabOverflowReady ? "ready" : "invalid") "
                    + "continuation="
                    + "\(manyTabContinuationReady ? "bidirectional" : "invalid") "
                    + "many-tab-x=\(Int(manyTabStripFrame.maxX))/"
                    + "\(Int(manyArtifactFrame.minX))/\(Int(manyWorkFrame.minX))/"
                    + "\(Int(manySessionFrame.minX))/\(Int(manySessionFrame.maxX))/"
                    + "\(Int(manyWindowContentFrame.maxX)) "
                    + adaptiveTabWidth.summary + " "
                    + "tabs=\(snapshot.tabs.count) active=\(snapshot.active_tab) "
                    + "leaves=\(metrics.leaves) splits=\(metrics.splits) "
                    + "axes=\(axes.joined(separator: ",")) "
                    + "dividers=\(dividersReady ? "ready" : "missing") "
                    + "cursors=\(cursorsReady ? "resize" : "missing") "
                    + "ratio=\(ratioUpdated ? "updated" : "stale") "
                    + "frame=\(paneFrameUpdated ? "resized" : "stale") "
                    + "context=\(contextMenuReady ? "right-click" : "missing") "
                    + "prompt=\(renamePromptReady ? "icon-free" : "invalid") "
                    + "rename=\(renameReady ? "double-click" : "missing") "
                    + "tab-dnd=\(dragReady ? "reordered" : "missing") "
                    + "tab-visuals=\(tabVisualsReady ? "clear" : "invalid") "
                    + "new-tab=\(tabStripView.actionsReady() ? "tab-strip" : "missing") "
                    + "pane-close=\(paneCloseReady ? "x-button" : "missing") "
                    + "tab-close=\(closeReady ? "x-button" : "missing")\n"
            )
        }

        func mainMenuShortcutMatches(
            command: NativeCommandID,
            shortcut: NativeKeyShortcut
        ) -> Bool {
            guard let item = mainMenuItem(in: NSApp.mainMenu, command: command) else {
                return false
            }
            let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            let expected = shortcut.modifiers.intersection(.deviceIndependentFlagsMask)
            return item.keyEquivalent == shortcut.keyEquivalent && modifiers == expected
        }

        func mainMenuItem(in menu: NSMenu?, command: NativeCommandID) -> NSMenuItem? {
            guard let menu else {
                return nil
            }
            for item in menu.items {
                if item.identifier?.rawValue == command.rawValue {
                    return item
                }
                if let match = mainMenuItem(in: item.submenu, command: command) {
                    return match
                }
            }
            return nil
        }

        func applyHomeWorkingDirectorySmokeScenario(resultPath: String) {
            let expected = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            let actual = activeWorkingDirectory()
            let processDirectory = FileManager.default.currentDirectoryPath
            let ok =
                settings.startupDirectory.isEmpty
                && processDirectory == "/"
                && actual == expected
            let status = ok ? "ok" : "failed"
            writeSessionSmokeResult(
                resultPath,
                result: "\(status) home-cwd startup=default "
                    + "process=\(processDirectory == "/" ? "root" : "other") "
                    + "pane=\(actual == expected ? "home" : "other")\n"
            )
        }

        func applyTerminalResizeSmokeScenario(resultPath: String) {
            guard let window = view.window else {
                writeSessionSmokeResult(resultPath, result: "failed terminal-resize no-window\n")
                return
            }
            window.setContentSize(NSSize(width: 780, height: 480))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak window] in
                guard let self, let window else {
                    return
                }
                self.beginTerminalResizeSmoke(resultPath, window: window)
            }
        }

        func beginTerminalResizeSmoke(_ resultPath: String, window: NSWindow) {
            guard let siblingPaneId = activePaneId,
                let zoomedPaneId = core.splitActive(axis: ffiSplitVertical)
            else {
                writeSessionSmokeResult(resultPath, result: "failed terminal-resize split\n")
                return
            }
            syncFromCore()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak window] in
                guard let self, let window else {
                    return
                }
                self.runTerminalResizeSmoke(
                    resultPath,
                    window: window,
                    zoomedPaneId: zoomedPaneId,
                    siblingPaneId: siblingPaneId
                )
            }
        }

        func runTerminalResizeSmoke(
            _ resultPath: String,
            window: NSWindow,
            zoomedPaneId: Int,
            siblingPaneId: Int
        ) {
            let baselineFontSize = terminalTextView.terminalFontSize
            let baselineGrid = paneGridSize(zoomedPaneId)
            let siblingBaselineGrid = paneGridSize(siblingPaneId)
            guard activePaneId == zoomedPaneId,
                adjustTerminalZoom(by: 1)
            else {
                writeSessionSmokeResult(
                    resultPath, result: "failed terminal-resize local-zoom-setup\n")
                return
            }
            let initial = paneGridSize(zoomedPaneId)
            let siblingInitial = paneGridSize(siblingPaneId)
            let zoomIsShared =
                abs(terminalTextView.terminalFontSize - baselineFontSize - 1) < 0.01
            let zoomContractedGrid =
                initial.cols <= baselineGrid.cols
                && initial.rows <= baselineGrid.rows
                && (initial.cols != baselineGrid.cols || initial.rows != baselineGrid.rows)
                && siblingInitial.cols <= siblingBaselineGrid.cols
                && siblingInitial.rows <= siblingBaselineGrid.rows
                && (siblingInitial.cols != siblingBaselineGrid.cols
                    || siblingInitial.rows != siblingBaselineGrid.rows)
            metalView.resetResizeDiagnostics()
            resetGeometryResizeDiagnostics()
            let sizes = (0...60).map { step in
                let progress = CGFloat(step) / 60
                return NSSize(
                    width: 780 + 340 * progress,
                    height: 480 + 280 * progress
                )
            }
            applyTerminalResizeSmokeSizes(sizes, to: window) { [weak self] in
                self?.waitForTerminalResizeSmoke(
                    resultPath,
                    zoomedPaneId: zoomedPaneId,
                    siblingPaneId: siblingPaneId,
                    baselineFontSize: baselineFontSize,
                    baselineGrid: baselineGrid,
                    initialGrid: initial,
                    zoomIsShared: zoomIsShared,
                    zoomContractedGrid: zoomContractedGrid,
                    retries: 40
                )
            }
        }

        func waitForTerminalResizeSmoke(
            _ resultPath: String,
            zoomedPaneId: Int,
            siblingPaneId: Int,
            baselineFontSize: CGFloat,
            baselineGrid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
            initialGrid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
            zoomIsShared: Bool,
            zoomContractedGrid: Bool,
            retries: Int
        ) {
            drainTerminalPanes()
            let resized = paneGridSize(zoomedPaneId)
            let geometry = geometryResizeDiagnostics()
            let panesFit = [zoomedPaneId, siblingPaneId].allSatisfy { paneId in
                guard let frame = paneStore.visibleFrames[paneId] else {
                    return false
                }
                let grid = paneGridSize(paneId)
                let cell = terminalTextView.terminalCellSize()
                return CGFloat(grid.cols) * cell.width <= frame.width + 1.5
                    && CGFloat(grid.rows) * cell.height <= frame.height + 1.5
            }
            let settled =
                panesFit
                && resized.rows > initialGrid.rows
                && resized.cols > initialGrid.cols
                && paneStore.runtimes[zoomedPaneId] != nil
                && paneStore.runtimes[siblingPaneId] != nil
                && metalView.drawableSizesMatchView()
                && geometry.requests > 1
                && geometry.applications < geometry.requests
            guard settled else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.waitForTerminalResizeSmoke(
                            resultPath,
                            zoomedPaneId: zoomedPaneId,
                            siblingPaneId: siblingPaneId,
                            baselineFontSize: baselineFontSize,
                            baselineGrid: baselineGrid,
                            initialGrid: initialGrid,
                            zoomIsShared: zoomIsShared,
                            zoomContractedGrid: zoomContractedGrid,
                            retries: retries - 1
                        )
                    }
                    return
                }
                writeTerminalResizeSmokeResult(
                    resultPath,
                    passed: false,
                    panesFit: panesFit,
                    baselineGrid: baselineGrid,
                    initialGrid: initialGrid,
                    resizedGrid: resized,
                    geometry: geometry
                )
                return
            }
            let reset =
                resetTerminalZoom()
                && abs(terminalTextView.terminalFontSize - baselineFontSize) < 0.01
            writeTerminalResizeSmokeResult(
                resultPath,
                passed: zoomIsShared && zoomContractedGrid && reset,
                panesFit: panesFit,
                baselineGrid: baselineGrid,
                initialGrid: initialGrid,
                resizedGrid: resized,
                geometry: geometry
            )
        }

        func writeTerminalResizeSmokeResult(
            _ resultPath: String,
            passed: Bool,
            panesFit: Bool,
            baselineGrid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
            initialGrid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
            resizedGrid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
            geometry: (requests: Int, applications: Int)
        ) {
            let status = passed ? "ok" : "failed"
            writeSessionSmokeResult(
                resultPath,
                result: "\(status) terminal-resize matrix=local-terminal "
                    + "font-zoom=shared grid-fit=\(panesFit ? "yes" : "no") "
                    + "baseline=\(baselineGrid.cols)x\(baselineGrid.rows) "
                    + "zoomed=\(initialGrid.cols)x\(initialGrid.rows) "
                    + "to=\(resizedGrid.cols)x\(resizedGrid.rows) "
                    + "geometry=\(geometry.applications)/\(geometry.requests) "
                    + "\(metalView.resizeDiagnosticsSummary())\n"
            )
        }

        func applyTerminalResizeSmokeSizes(
            _ sizes: [NSSize],
            to window: NSWindow,
            index: Int = 0,
            completion: @escaping () -> Void
        ) {
            guard sizes.indices.contains(index) else {
                completion()
                return
            }
            window.setContentSize(sizes[index])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.004) { [weak self, weak window] in
                guard let self, let window else {
                    return
                }
                applyTerminalResizeSmokeSizes(
                    sizes,
                    to: window,
                    index: index + 1,
                    completion: completion
                )
            }
        }

        func sessionPaneCounts(
            _ pane: NativeSessionPane
        ) -> (leaves: Int, splits: Int, activeLeaves: Int) {
            if pane.kind == "leaf" {
                return (1, 0, pane.active ? 1 : 0)
            }
            let empty = (leaves: 0, splits: 0, activeLeaves: 0)
            let first = pane.first.map(sessionPaneCounts) ?? empty
            let second = pane.second.map(sessionPaneCounts) ?? empty
            return (
                first.leaves + second.leaves,
                first.splits + second.splits + 1,
                first.activeLeaves + second.activeLeaves
            )
        }

        func paneLayoutMetrics(
            _ pane: PaneLayoutSnapshot
        ) -> (leaves: Int, splits: Int, axes: Set<String>) {
            if pane.kind == "leaf" {
                return (1, 0, [])
            }
            let empty = (leaves: 0, splits: 0, axes: Set<String>())
            let first = pane.first.map(paneLayoutMetrics) ?? empty
            let second = pane.second.map(paneLayoutMetrics) ?? empty
            var axes = first.axes.union(second.axes)
            if let axis = pane.axis {
                axes.insert(axis)
            }
            return (
                first.leaves + second.leaves,
                first.splits + second.splits + 1,
                axes
            )
        }

        func writeSessionSmokeResult(_ path: String, result: String) {
            try? result.write(toFile: path, atomically: true, encoding: .utf8)
            if let shotPath = ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_SHOT"],
                !shotPath.isEmpty
            {
                return
            }
            NSApp.terminate(nil)
        }

        func closeWindowAfterWritingSessionSmokeResult(
            _ path: String,
            result: String
        ) {
            try? result.write(toFile: path, atomically: true, encoding: .utf8)
            guard let window = view.window else {
                NSApp.terminate(nil)
                return
            }
            window.performClose(nil)
        }

        func applyTerminalBottomInputSmokeScenario(resultPath: String) {
            let command = [
                "i=0",
                "while [ $i -lt 80 ]; do printf '\\n'; i=$((i + 1)); done",
            ].joined(separator: "; ")
            writeToActivePane(Data("\(command)\r".utf8))

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.waitForTerminalBottomInputIdleThenType(resultPath, retries: 24)
            }
        }

        func applyTerminalExitClosesTabSmokeScenario(resultPath: String) {
            core.newTab()
            syncFromCore()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.writeToActivePane(Data("exit\r".utf8))
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.writeTerminalExitClosesTabSmokeResult(resultPath, retries: 16)
            }
        }

        func applyTerminalNvimHandoffSmokeScenario(resultPath: String) {
            openNativeNeovim(nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runNvimCommandOrWrite(
                    "enew | call setline(1, 'HANDOFFNVIM') | call cursor(1, 1)",
                    fallback: Data()
                )
                self?.metalView.resetSkiaFrameCount()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                self?.writeTerminalNvimHandoffSmokeResult(resultPath, retries: 16)
            }
        }

        func applyShellNvimNativeSmokeScenario(resultPath: String) {
            let fixture = "/tmp/satin-shell-nvim-native-smoke.txt"
            let before = "/tmp/satin-shell-nvim-native-before.txt"
            let after = "/tmp/satin-shell-nvim-native-after.txt"
            let forwarded = "/tmp/satin-shell-nvim-native-environment.txt"
            writeSmokeLines(path: fixture)
            try? FileManager.default.removeItem(atPath: before)
            try? FileManager.default.removeItem(atPath: after)
            try? FileManager.default.removeItem(atPath: forwarded)
            let command = [
                "export SATIN_SHELL_CONTINUITY=preserved",
                "export SATIN_LAUNCH_ENVIRONMENT=forwarded",
                "printf '%s' \"$$\" > \(shellQuote(before))",
                "nvim -Nu NONE -n \(shellQuote(fixture))",
                "printf '%s:%s:%s' \"$$\" \"$SATIN_SHELL_CONTINUITY\" \"$?\" "
                    + "> \(shellQuote(after))",
            ].joined(separator: "; ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else {
                    return
                }
                writeToActivePane(Data("\(command)\r".utf8))
                waitForShellNvimNativeContent(
                    resultPath,
                    beforePath: before,
                    afterPath: after,
                    retries: 48
                )
            }
        }

        func waitForShellNvimNativeContent(
            _ resultPath: String,
            beforePath: String,
            afterPath: String,
            retries: Int
        ) {
            let ready =
                activePaneMode() == .neovim
                && terminalTextView.rendererModelContainsTexts([nvimSmokeReadyMarker])
            guard ready else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.waitForShellNvimNativeContent(
                            resultPath,
                            beforePath: beforePath,
                            afterPath: afterPath,
                            retries: retries - 1
                        )
                    }
                    return
                }
                writeShellNvimNativeSmokeFailure(resultPath, reason: "native-launch-timeout")
                return
            }
            guard let paneId = activePaneId,
                let suspended = paneStore.suspendedSessions[paneId]?.pane,
                tmuxConnectionGateway(paneId: paneId) === suspended
            else {
                writeShellNvimNativeSmokeFailure(resultPath, reason: "tmux-gateway-missing")
                return
            }
            runNvimCommandOrWrite(
                "call writefile([$SATIN_LAUNCH_ENVIRONMENT], "
                    + "'\(vimSingleQuote("/tmp/satin-shell-nvim-native-environment.txt"))')",
                fallback: Data()
            )
            runNvimCommandOrWrite(
                "topleft vertical 24new | terminal",
                fallback: Data()
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else {
                    return
                }
                runNvimCommandOrWrite("wincmd l", fallback: Data())
                clearSmokeScrollShift()
                metalView.resetSkiaFrameCount()
                writeToActivePane(Data([0x04]))
                waitForShellNvimNativeScroll(
                    resultPath,
                    beforePath: beforePath,
                    afterPath: afterPath,
                    retries: 24
                )
            }
        }

        func waitForShellNvimNativeScroll(
            _ resultPath: String,
            beforePath: String,
            afterPath: String,
            retries: Int
        ) {
            let shift = peekSmokeScrollShift()
            let skiaFrames = metalView.skiaFrames()
            let ok =
                shift.map { value in
                    abs(value.rows) > maxOutputScrollAnimationRows && (value.startCol ?? 0) > 0
                } ?? false
            guard ok && skiaFrames >= 2 else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForShellNvimNativeScroll(
                            resultPath,
                            beforePath: beforePath,
                            afterPath: afterPath,
                            retries: retries - 1
                        )
                    }
                    return
                }
                writeShellNvimNativeSmokeFailure(resultPath, reason: "split-scroll-missing")
                return
            }
            let summary = nvimAnimationSmokeSummary(
                shift,
                hasModelFrames: terminalTextView.hasRendererModelFrames(),
                skiaFrames: skiaFrames
            )
            runNvimCommandOrWrite("cquit! 7", fallback: Data())
            waitForShellNvimResume(
                resultPath,
                beforePath: beforePath,
                afterPath: afterPath,
                scrollSummary: summary,
                retries: 48
            )
        }

        func waitForShellNvimResume(
            _ resultPath: String,
            beforePath: String,
            afterPath: String,
            scrollSummary: String,
            retries: Int
        ) {
            let before = try? String(contentsOfFile: beforePath, encoding: .utf8)
            let after = try? String(contentsOfFile: afterPath, encoding: .utf8)
            let forwarded = try? String(
                contentsOfFile: "/tmp/satin-shell-nvim-native-environment.txt",
                encoding: .utf8
            )
            let resumed =
                activePaneMode() == .terminal
                && before.map { "\($0):preserved:7" } == after
                && forwarded == "forwarded\n"
            guard resumed else {
                if retries > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        self?.waitForShellNvimResume(
                            resultPath,
                            beforePath: beforePath,
                            afterPath: afterPath,
                            scrollSummary: scrollSummary,
                            retries: retries - 1
                        )
                    }
                    return
                }
                writeShellNvimNativeSmokeFailure(resultPath, reason: "shell-resume-timeout")
                return
            }
            let result =
                "ok shell-nvim-native terminal-split=yes same-shell=yes "
                + "environment=yes exit-status=yes tmux-gateway=yes \(scrollSummary)\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func writeShellNvimNativeSmokeFailure(_ resultPath: String, reason: String) {
            let result =
                "failed shell-nvim-native reason=\(reason) mode=\(activePaneMode()) "
                + "\(terminalTextView.rendererViewportSummary())\n"
            try? result.write(toFile: resultPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        func applyArtifactPopoverSmokeScenario(resultPath: String) {
            smokeState.artifactPopoverResultPath = resultPath
            smokeState.artifactPopoverOpenPath = "\(resultPath).open"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.artifactButton.superview != nil else {
                    self?.writeArtifactPopoverSmokeResult(
                        resultPath,
                        result: "failed artifact-popover button=unavailable\n"
                    )
                    return
                }
                self.artifactButton.performClick(nil)
            }
        }

        func waitForArtifactPopoverSmokeOpen(
            _ content: NativeArtifactsPopoverViewController,
            artifact: String,
            attempts: Int
        ) {
            guard let path = smokeState.artifactPopoverOpenPath, attempts > 0 else {
                return
            }
            if FileManager.default.fileExists(atPath: path) {
                smokeState.artifactPopoverOpenPath = nil
                _ = content.performSelectionForSmoke(artifact)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak content] in
                guard let self, let content else {
                    return
                }
                self.waitForArtifactPopoverSmokeOpen(
                    content,
                    artifact: artifact,
                    attempts: attempts - 1
                )
            }
        }

        func writeArtifactPopoverSmokeResult(_ path: String, result: String) {
            try? result.write(toFile: path, atomically: true, encoding: .utf8)
        }

    }
#endif

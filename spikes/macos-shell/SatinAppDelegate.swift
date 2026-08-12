import AppKit
import CoreGraphics
import Foundation

final class SatinAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow?
    private var shellController: TerminalShellViewController?
    private let settingsStore = NativeSettingsStore()
    private var settingsWindowController: NativeSettingsWindowController?
    private var controlServer: NativeControlServer?
    private let updateChecker = AppUpdateChecker()
    private let updateInstaller = AppUpdateInstaller()
    private var updateCheckID: UUID?
    private var updateTask: URLSessionDataTask?
    private var updateProgressAlert: NSAlert?
    private var pendingFinderPaths: [String] = []
    private var launchedForFinderEditor = false
    private var observesKeyWindow = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        sender.reply(toOpenOrPrint: routeFinderPaths(filenames) ? .success : .failure)
    }

    @objc func openFilesInEditor(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls =
            pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
        var paths = urls.map(\.path)
        if paths.isEmpty,
            let filenames = pasteboard.propertyList(
                forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
            ) as? [String]
        {
            paths = filenames
        }
        if paths.isEmpty, let text = pasteboard.string(forType: .string) {
            paths = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
        if !routeFinderPaths(paths) {
            error.pointee = "Satin could not open the selected items." as NSString
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NativeLog.started()
        var settings = settingsStore.load()
        let environment = ProcessInfo.processInfo.environment
        if let value = environment["SATIN_NATIVE_PERF_FONT_SIZE"],
            let fontSize = Double(value), fontSize.isFinite
        {
            settings.fontSize = min(max(fontSize, nativeMinimumFontSize), nativeMaximumFontSize)
        }
        if environment["SATIN_NATIVE_SMOKE_SCENARIO"] == "finder-editor" {
            let smokeEditor = environment["SATIN_NATIVE_SMOKE_FINDER_EDITOR"] ?? "nvim"
            settings.finderEditorCommand =
                NativeSettingsStore.isValidFinderEditorCommand(
                    smokeEditor
                ) ? smokeEditor : "nvim"
            let smokeShell = environment["SATIN_NATIVE_SMOKE_FINDER_SHELL"] ?? "/bin/bash"
            if NativeSettingsStore.isValidShellPath(smokeShell) {
                settings.shellPath = smokeShell
            }
        }
        let initialFinderLaunch = NativeFinderEditorLaunch(paths: pendingFinderPaths)
        launchedForFinderEditor = initialFinderLaunch != nil
        guard let core = RustCore(defaultTheme: settings.defaultTheme) else {
            presentFatalError(
                title: "Terminal Core Failed",
                message:
                    "The Rust terminal core could not be initialized. Check Console for details."
            )
            return
        }

        guard
            let controller = TerminalShellViewController(
                core: core,
                settings: settings,
                initialFinderLaunch: initialFinderLaunch
            )
        else {
            presentFatalError(
                title: "Metal Renderer Unavailable",
                message: "A Metal-capable GPU and the bundled Skia renderer are required."
            )
            return
        }
        let socketPath = NativeControlEnvironment.socketPath()
        guard let controlServer = NativeControlServer(socketPath: socketPath) else {
            presentFatalError(
                title: "Control Server Failed",
                message: "The owner-only Unix control socket could not be created."
            )
            return
        }
        controller.configureControl(
            socketPath: socketPath,
            cliPath: NativeControlEnvironment.cliPath(),
            nvimLauncherPath: NativeControlEnvironment.nvimLauncherPath(),
            zshIntegrationPath: NativeControlEnvironment.zshIntegrationPath()
        )
        controlServer.onRequest = { [weak controller] request, reply in
            controller?.handleControlRequest(request, reply: reply)
        }
        self.controlServer = controlServer
        let contentRect = NSRect(x: 0, y: 0, width: 1100, height: 720)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = nativeApplicationName
        NativePlatformAppearance.configureWindow(
            window,
            role: .terminal
        )
        window.tabbingMode = .preferred
        controller.view.frame = NSRect(origin: .zero, size: contentRect.size)
        window.contentViewController = controller
        window.toolbar = controller.toolbar()
        self.window = window
        self.shellController = controller
        if !observesKeyWindow {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyWindowDidChange(_:)),
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            observesKeyWindow = true
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        pendingFinderPaths.removeAll()
        let settingsController = NativeSettingsWindowController(store: settingsStore)
        settingsController.onChange = { [weak self] settings in
            self?.shellController?.applySettings(settings)
            self?.buildMainMenu()
        }
        self.settingsWindowController = settingsController

        buildMainMenu()
        applySmokeScenarioIfNeeded(controller)
        controller.focusTerminal()
        writeSmokeWindowIdIfNeeded(window)
        scheduleSmokeShotIfNeeded(window)
        scheduleAutomaticUpdateCheck()
    }

    private func presentFatalError(title: String, message: String) {
        NativeLog.runtimeError("fatal_error title=\(title) message=\(message)")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        let smokeScenario = ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_SCENARIO"]
        let restartSmoke =
            smokeScenario == "tmux-restart-checkpoint"
            || smokeScenario == "tmux-restart-restore"
        guard smokeScenario == nil || restartSmoke, !launchedForFinderEditor else {
            return
        }
        shellController?.saveSessionState()
        if smokeScenario == "tmux-restart-checkpoint",
            shellController?.saveLegacyTmuxRestartStateForSmoke() != true
        {
            NativeLog.sessionWarning("tmux_restart_smoke_legacy_state_failed")
        }
    }

    private func routeFinderPaths(_ paths: [String]) -> Bool {
        guard let launch = NativeFinderEditorLaunch(paths: paths) else {
            return false
        }
        if let shellController {
            return shellController.openFinderItems(launch)
        }
        pendingFinderPaths.append(contentsOf: launch.paths)
        return true
    }

    @objc func newTab(_ sender: Any?) {
        shellController?.newTab(sender)
    }

    @objc func splitVertical(_ sender: Any?) {
        shellController?.splitVertical(sender)
    }

    @objc func splitHorizontal(_ sender: Any?) {
        shellController?.splitHorizontal(sender)
    }

    @objc func renameActiveTab(_ sender: Any?) {
        shellController?.renameActiveTab(sender)
    }

    @objc func openNativeNeovim(_ sender: Any?) {
        shellController?.openNativeNeovim(sender)
    }

    @objc func closeActivePane(_ sender: Any?) {
        shellController?.closeActivePane(sender)
    }

    @objc private func keyWindowDidChange(_ notification: Notification) {
        buildMainMenu()
    }

    @objc func showSessionSwitcher(_ sender: Any?) {
        shellController?.showSessionSwitcher(sender)
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindowController?.present()
    }

    @objc func zoomIn(_ sender: Any?) {
        shellController?.zoomIn(sender)
    }

    @objc func zoomOut(_ sender: Any?) {
        shellController?.zoomOut(sender)
    }

    @objc func resetZoom(_ sender: Any?) {
        shellController?.resetZoom(sender)
    }

    @objc func selectTabFromShortcut(_ sender: NSMenuItem) {
        shellController?.selectTabFromShortcut(sender.tag)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard !nativeIsDevelopmentBuild else {
            return
        }
        beginUpdateCheck(interactive: true)
    }

    @objc func showAcknowledgements(_ sender: Any?) {
        guard
            let notices = Bundle.main.url(
                forResource: "THIRD_PARTY_NOTICES",
                withExtension: "md",
                subdirectory: "Legal"
            )
        else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([notices])
    }

    private func scheduleAutomaticUpdateCheck() {
        guard !nativeIsDevelopmentBuild,
            ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_SCENARIO"] == nil
        else {
            return
        }
        guard settingsStore.shouldAutomaticallyCheckForUpdates() else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.beginUpdateCheck(interactive: false)
        }
    }

    private func beginUpdateCheck(interactive: Bool) {
        guard
            let currentVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
        else {
            if interactive {
                presentUpdateError(AppUpdateError.invalidCurrentVersion)
            }
            return
        }

        if interactive {
            updateTask?.cancel()
        } else if updateTask != nil {
            return
        }

        let checkID = UUID()
        updateCheckID = checkID
        updateTask = updateChecker.check(currentVersion: currentVersion) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.updateCheckID == checkID else {
                    return
                }
                self.updateCheckID = nil
                self.updateTask = nil
                self.settingsStore.recordUpdateCheck()
                switch result {
                case .success(.current):
                    NativeLog.lifecycleInfo("update_check_current version=\(currentVersion)")
                    if interactive {
                        self.presentCurrentVersion(currentVersion)
                    }
                case .success(.available(let update)):
                    NativeLog.lifecycleInfo(
                        "update_available current=\(currentVersion) latest=\(update.version)"
                    )
                    self.presentAvailableUpdate(update, currentVersion: currentVersion)
                case .failure(let error):
                    NativeLog.lifecycleError(
                        "update_check_failed error=\(error.localizedDescription)"
                    )
                    if interactive {
                        self.presentUpdateError(error)
                    }
                }
            }
        }
    }

    private func presentAvailableUpdate(
        _ update: AvailableAppUpdate,
        currentVersion: String
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Satin \(update.version) is available"
        alert.informativeText = """
            You are running \(currentVersion). The update will be downloaded from GitHub, verified \
            with the embedded publisher key, installed, and restarted.
            """
        alert.addButton(withTitle: "Update and Restart")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            beginInstallingUpdate(update)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(update.releaseNotesURL)
        default:
            break
        }
    }

    private func beginInstallingUpdate(_ update: AvailableAppUpdate) {
        guard updateProgressAlert == nil, let window else {
            return
        }
        let progress = NSProgressIndicator(
            frame: NSRect(x: 0, y: 0, width: 320, height: 20)
        )
        progress.style = .bar
        progress.isIndeterminate = true
        progress.startAnimation(nil)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Installing Satin \(update.version)…"
        alert.informativeText = "Downloading and verifying the signed Apple Silicon update."
        alert.accessoryView = progress
        updateProgressAlert = alert
        alert.beginSheetModal(for: window)

        updateInstaller.prepare(update: update) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                window.endSheet(alert.window)
                self.updateProgressAlert = nil
                switch result {
                case .success(let prepared):
                    do {
                        try self.updateInstaller.launch(prepared)
                        NativeLog.lifecycleInfo(
                            "update_install_ready version=\(prepared.version)"
                        )
                        NSApp.terminate(nil)
                    } catch {
                        self.updateInstaller.discard(prepared)
                        NativeLog.lifecycleError(
                            "update_install_launch_failed error=\(error.localizedDescription)"
                        )
                        self.presentUpdateInstallError(error, update: update)
                    }
                case .failure(let error):
                    NativeLog.lifecycleError(
                        "update_install_failed error=\(error.localizedDescription)"
                    )
                    self.presentUpdateInstallError(error, update: update)
                }
            }
        }
    }

    private func presentUpdateInstallError(
        _ error: Error,
        update: AvailableAppUpdate
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Install Update"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Download Manually")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(update.downloadURL)
        }
    }

    private func presentCurrentVersion(_ currentVersion: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Satin is up to date"
        alert.informativeText = "Version \(currentVersion) is the latest available release."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentUpdateError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Check for Updates"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(sessionMenuItem())
        mainMenu.addItem(windowMenuItem())
        mainMenu.addItem(helpMenuItem())
        NSApp.mainMenu = mainMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        let requiresTerminalWindow =
            action == #selector(newTab(_:))
            || action == #selector(splitVertical(_:))
            || action == #selector(splitHorizontal(_:))
            || action == #selector(renameActiveTab(_:))
            || action == #selector(openNativeNeovim(_:))
            || action == #selector(closeActivePane(_:))
            || action == #selector(selectTabFromShortcut(_:))
            || action == #selector(showSessionSwitcher(_:))
            || action == #selector(zoomIn(_:))
            || action == #selector(zoomOut(_:))
            || action == #selector(resetZoom(_:))
        return !requiresTerminalWindow || NSApp.keyWindow === window
    }

    private func applySmokeScenarioIfNeeded(_ controller: TerminalShellViewController) {
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

    private func scheduleSmokeShotIfNeeded(_ window: NSWindow) {
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

    private func writeSmokeWindowIdIfNeeded(_ window: NSWindow) {
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

    private func writeSmokeWindowId(path: String, window: NSWindow, attempts: Int) {
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

    private func cgWindowNumberForCurrentProcess() -> Int? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
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

    private func cgWindowArea(_ info: [String: Any]) -> Double {
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else {
            return 0
        }
        let width = cgWindowBoundValue(bounds["Width"])
        let height = cgWindowBoundValue(bounds["Height"])
        return width * height
    }

    private func cgWindowInt(_ value: Any?) -> Int? {
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

    private func cgWindowBoundValue(_ value: Any?) -> Double {
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

    private func writeSmokeShot(path: String, window: NSWindow) {
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

    private func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(
            withTitle: "About \(nativeApplicationName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Quit \(nativeApplicationName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.submenu = menu
        return item
    }

    private func sessionMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Session")
        menu.addItem(
            targetedItem("Switch Terminal Session…", #selector(showSessionSwitcher(_:)), ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(commandItem("New Tab", #selector(newTab(_:)), .newTab))
        menu.addItem(commandItem("Split Vertical", #selector(splitVertical(_:)), .splitVertical))
        menu.addItem(
            commandItem("Split Horizontal", #selector(splitHorizontal(_:)), .splitHorizontal))
        menu.addItem(commandItem("Close Pane", #selector(closeActivePane(_:)), .closePane))
        menu.addItem(NSMenuItem.separator())
        for shortcutNumber in 1...9 {
            let title = shortcutNumber == 9 ? "Select Last Tab" : "Select Tab \(shortcutNumber)"
            let menuItem = targetedItem(
                title, #selector(selectTabFromShortcut(_:)), "\(shortcutNumber)")
            menuItem.tag = shortcutNumber
            menu.addItem(menuItem)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(commandItem("Rename Session", #selector(renameActiveTab(_:)), .renameSession))
        menu.addItem(
            commandItem(
                "Open Native Neovim",
                #selector(openNativeNeovim(_:)),
                .openNativeNeovim
            )
        )
        item.submenu = menu
        return item
    }

    private func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Find",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "f"
        )
        item.submenu = menu
        return item
    }

    private func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        menu.addItem(commandItem("Zoom In", #selector(zoomIn(_:)), .zoomIn))
        menu.addItem(commandItem("Zoom Out", #selector(zoomOut(_:)), .zoomOut))
        menu.addItem(commandItem("Actual Size", #selector(resetZoom(_:)), .actualSize))
        item.submenu = menu
        return item
    }

    private func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    private func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        if !nativeIsDevelopmentBuild {
            menu.addItem(
                commandItem(
                    "Check for Updates…",
                    #selector(checkForUpdates(_:)),
                    .checkForUpdates
                )
            )
            menu.addItem(NSMenuItem.separator())
        }
        let acknowledgements = NSMenuItem(
            title: "Acknowledgements…",
            action: #selector(showAcknowledgements(_:)),
            keyEquivalent: ""
        )
        acknowledgements.target = self
        menu.addItem(acknowledgements)
        item.submenu = menu
        return item
    }

    private func commandItem(
        _ title: String,
        _ action: Selector,
        _ command: NativeCommandID
    ) -> NSMenuItem {
        let shortcut = settingsStore.load().shortcut(for: command)
        let terminalOwnsShortcuts = terminalWindowOwnsCommandShortcuts()
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: terminalOwnsShortcuts ? shortcut.keyEquivalent : ""
        )
        item.target = self
        item.keyEquivalentModifierMask = terminalOwnsShortcuts ? shortcut.modifiers : []
        return item
    }

    private func targetedItem(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: terminalWindowOwnsCommandShortcuts() ? key : ""
        )
        item.target = self
        return item
    }

    private func terminalWindowOwnsCommandShortcuts() -> Bool {
        guard let window else {
            return false
        }
        guard let keyWindow = NSApp.keyWindow else {
            return window.isVisible
        }
        return keyWindow === window
    }
}

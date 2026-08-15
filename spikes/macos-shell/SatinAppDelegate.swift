import AppKit
import Foundation

final class SatinAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var shellController: TerminalShellViewController?
    private let settingsStore = NativeSettingsStore()
    var settingsWindowController: NativeSettingsWindowController?
    private var controlServer: NativeControlServer?
    private let updateChecker = AppUpdateChecker()
    private let updateInstaller = AppUpdateInstaller()
    private var updateCheckID: UUID?
    private var updateTask: URLSessionDataTask?
    private var updateProgressAlert: NSAlert?
    private var mainMenuController: NativeMainMenuController?
    private var pendingFinderPaths: [String] = []
    private var launchedForFinderEditor = false

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
            zshIntegrationPath: NativeControlEnvironment.zshIntegrationPath(),
            claudeSettingsPath: NativeControlEnvironment.claudeSettingsPath()
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
        pendingFinderPaths.removeAll()
        let settingsController = NativeSettingsWindowController(store: settingsStore)
        settingsController.onChange = { [weak self] settings in
            self?.shellController?.applySettings(settings)
            self?.mainMenuController?.refreshShortcuts(using: settings)
        }
        settingsController.onCheckForUpdates = { [weak self] in
            self?.requestInteractiveUpdateCheck()
        }
        self.settingsWindowController = settingsController

        let mainMenuController = NativeMainMenuController(
            application: NSApp,
            terminalWindow: window,
            settings: settings,
            includesUpdates: !nativeIsDevelopmentBuild,
            actionHandler: { [weak self] action in
                self?.performMainMenuAction(action)
            }
        )
        self.mainMenuController = mainMenuController
        mainMenuController.install(in: NSApp)

        let avoidsActivation = nativeApplicationAvoidsActivation(environment)
        if avoidsActivation {
            window.orderFront(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        #if SATIN_SMOKE_SCENARIOS
            applySmokeScenarioIfNeeded(controller)
        #endif
        if !avoidsActivation {
            controller.focusTerminal()
        }
        #if SATIN_SMOKE_SCENARIOS
            writeSmokeWindowIdIfNeeded(window)
            scheduleSmokeShotIfNeeded(window)
        #endif
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

    func applicationDidBecomeActive(_ notification: Notification) {
        shellController?.markActiveWorkSeen()
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if SATIN_SMOKE_SCENARIOS
            let smokeScenario = ProcessInfo.processInfo.environment["SATIN_NATIVE_SMOKE_SCENARIO"]
            let restartSmoke =
                smokeScenario == "tmux-restart-checkpoint"
                || smokeScenario == "tmux-restart-restore"
            guard smokeScenario == nil || restartSmoke else {
                return
            }
        #endif
        guard !launchedForFinderEditor else {
            return
        }
        shellController?.saveSessionState()
        #if SATIN_SMOKE_SCENARIOS
            if smokeScenario == "tmux-restart-checkpoint",
                shellController?.saveLegacyTmuxRestartStateForSmoke() != true
            {
                NativeLog.sessionWarning("tmux_restart_smoke_legacy_state_failed")
            }
        #endif
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

    private func performMainMenuAction(_ action: NativeMainMenuAction) {
        switch action {
        case .showSettings:
            settingsWindowController?.present()
        case .showWorkSwitcher:
            shellController?.showWorkSwitcher(nil)
        case .newTab:
            shellController?.newTab(nil)
        case .splitVertical:
            shellController?.splitVertical(nil)
        case .splitHorizontal:
            shellController?.splitHorizontal(nil)
        case .closePane:
            shellController?.closeActivePane(nil)
        case .focusPaneLeft:
            shellController?.focusPaneLeft(nil)
        case .focusPaneDown:
            shellController?.focusPaneDown(nil)
        case .focusPaneUp:
            shellController?.focusPaneUp(nil)
        case .focusPaneRight:
            shellController?.focusPaneRight(nil)
        case .showSessionSwitcher:
            shellController?.showSessionSwitcher(nil)
        case .selectTab(let number):
            shellController?.selectTabFromShortcut(number)
        case .renameSession:
            shellController?.renameActiveTab(nil)
        case .openNativeNeovim:
            shellController?.openNativeNeovim(nil)
        case .zoomIn:
            shellController?.zoomIn(nil)
        case .zoomOut:
            shellController?.zoomOut(nil)
        case .actualSize:
            shellController?.resetZoom(nil)
        case .checkForUpdates:
            requestInteractiveUpdateCheck()
        case .showAcknowledgements:
            showAcknowledgements()
        }
    }

    private func requestInteractiveUpdateCheck() {
        guard !nativeIsDevelopmentBuild else {
            return
        }
        beginUpdateCheck(interactive: true)
    }

    private func showAcknowledgements() {
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
                settingsWindowController?.setUpdateCheckInProgress(false)
                presentUpdateError(AppUpdateError.invalidCurrentVersion)
            }
            return
        }

        if interactive {
            updateTask?.cancel()
            settingsWindowController?.setUpdateCheckInProgress(true)
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
                if interactive {
                    self.settingsWindowController?.setUpdateCheckInProgress(false)
                }
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
}

import AppKit
import Foundation

final class SatinAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
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
        #if SATIN_SMOKE_SCENARIOS
            applySmokeScenarioIfNeeded(controller)
        #endif
        controller.focusTerminal()
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

    @objc func focusPaneLeft(_ sender: Any?) {
        shellController?.focusPaneLeft(sender)
    }

    @objc func focusPaneDown(_ sender: Any?) {
        shellController?.focusPaneDown(sender)
    }

    @objc func focusPaneUp(_ sender: Any?) {
        shellController?.focusPaneUp(sender)
    }

    @objc func focusPaneRight(_ sender: Any?) {
        shellController?.focusPaneRight(sender)
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
            || action == #selector(focusPaneLeft(_:))
            || action == #selector(focusPaneDown(_:))
            || action == #selector(focusPaneUp(_:))
            || action == #selector(focusPaneRight(_:))
            || action == #selector(selectTabFromShortcut(_:))
            || action == #selector(showSessionSwitcher(_:))
            || action == #selector(zoomIn(_:))
            || action == #selector(zoomOut(_:))
            || action == #selector(resetZoom(_:))
        return !requiresTerminalWindow || NSApp.keyWindow === window
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
        menu.addItem(commandItem("Focus Pane Left", #selector(focusPaneLeft(_:)), .focusPaneLeft))
        menu.addItem(commandItem("Focus Pane Down", #selector(focusPaneDown(_:)), .focusPaneDown))
        menu.addItem(commandItem("Focus Pane Up", #selector(focusPaneUp(_:)), .focusPaneUp))
        menu.addItem(
            commandItem("Focus Pane Right", #selector(focusPaneRight(_:)), .focusPaneRight))
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

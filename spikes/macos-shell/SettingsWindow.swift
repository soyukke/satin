import AppKit
import Foundation

final class NativeSettingsWindowController: NSWindowController, NSTextFieldDelegate {
    var onChange: ((NativeSettings) -> Void)?
    var onCheckForUpdates: (() -> Void)?

    private let store: NativeSettingsStore
    private let tabController: NSTabViewController
    private var settings: NativeSettings
    private var shortcutFields: [NativeCommandID: NSTextField] = [:]
    private let shortcutErrorLabel = NSTextField(labelWithString: "")
    private var fontPopup: NSPopUpButton?
    private var fontSizeField: NSTextField?
    private var themePopup: NSPopUpButton?
    private var optionAsAltButton: NSButton?
    private var notificationButton: NSButton?
    private var attentionHandButton: NSButton?
    private var animatedBackdropButton: NSButton?
    private var ambientSoundButton: NSButton?
    private var appearanceModePopup: NSPopUpButton?
    private var agentChimesButton: NSButton?
    private var sessionRestoreButton: NSButton?
    private var confirmBeforeQuitButton: NSButton?
    private var shellField: NSTextField?
    private var tmuxField: NSTextField?
    private var directoryField: NSTextField?
    private var finderEditorField: NSTextField?
    private let tmuxStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let terminalErrorLabel = NSTextField(labelWithString: "")
    private var automaticUpdatesButton: NSButton?
    private var updateIntervalPopup: NSPopUpButton?
    private var checkForUpdatesButton: NSButton?

    init(store: NativeSettingsStore) {
        self.store = store
        self.settings = store.load()
        let tabs = NSTabViewController()
        self.tabController = tabs
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 700, height: 480))
        window.isReleasedWhenClosed = false
        NativePlatformAppearance.configureWindow(
            window,
            role: .settings
        )
        super.init(window: window)
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab(title: "General", symbol: "gearshape", view: generalView()))
        tabs.addTabViewItem(tab(title: "Appearance", symbol: "paintbrush", view: appearanceView()))
        tabs.addTabViewItem(tab(title: "Terminal", symbol: "terminal", view: terminalView()))
        tabs.addTabViewItem(tab(title: "Keybindings", symbol: "keyboard", view: keybindingsView()))
        tabs.addTabViewItem(
            tab(title: "Updates", symbol: "arrow.triangle.2.circlepath", view: updatesView()))
        tabs.title = "\(nativeApplicationName) Settings"
        window.title = "\(nativeApplicationName) Settings"
        refreshControls()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        refreshControls()
        refreshTmuxStatus()
        if let requestedTab = ProcessInfo.processInfo.environment["SATIN_SETTINGS_TAB"],
            let index = ["general", "appearance", "terminal", "keybindings", "updates"]
                .firstIndex(of: requestedTab.lowercased())
        {
            tabController.selectedTabViewItemIndex = index
        }
        window?.center()
        if nativeApplicationAvoidsActivation(ProcessInfo.processInfo.environment) {
            window?.orderFront(nil)
        } else {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func booleanChanged(_ sender: NSButton) {
        settings.optionAsAlt = optionAsAltButton?.state == .on
        settings.notifications = notificationButton?.state == .on
        settings.attentionHand = attentionHandButton?.state == .on
        settings.animatedBackdrop = animatedBackdropButton?.state == .on
        settings.ambientSound = ambientSoundButton?.state == .on
        settings.agentChimes = agentChimesButton?.state == .on
        settings.sessionRestore = sessionRestoreButton?.state == .on
        settings.confirmBeforeQuit = confirmBeforeQuitButton?.state == .on
        settings.automaticUpdateChecks = automaticUpdatesButton?.state == .on
        updateIntervalPopup?.isEnabled = settings.automaticUpdateChecks
        commit()
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        settings.fontFamily =
            sender.titleOfSelectedItem == "Bundled Default"
            ? ""
            : sender.titleOfSelectedItem ?? ""
        commit()
    }

    @objc private func fontSizeChanged(_ sender: NSTextField) {
        settings.fontSize = min(
            max(sender.doubleValue, nativeMinimumFontSize),
            nativeMaximumFontSize
        )
        sender.doubleValue = settings.fontSize
        commit()
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        settings.defaultTheme = sender.titleOfSelectedItem ?? nativeThemeNames[0]
        commit()
    }

    @objc private func terminalPathChanged(_ sender: NSTextField) {
        let shellPath =
            shellField?.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
        let startupDirectory =
            directoryField?.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
        let tmuxExecutablePath =
            tmuxField?.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
        let finderEditorCommand =
            finderEditorField?.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
        guard NativeSettingsStore.isValidShellPath(shellPath) else {
            terminalErrorLabel.stringValue =
                "Shell must be an executable file at an absolute path."
            return
        }
        guard NativeSettingsStore.isValidStartupDirectory(startupDirectory) else {
            terminalErrorLabel.stringValue =
                "Startup directory must be an existing absolute directory."
            return
        }
        guard NativeSettingsStore.isValidTmuxExecutablePath(tmuxExecutablePath) else {
            terminalErrorLabel.stringValue =
                "tmux must be an executable file at an absolute path, or empty for Automatic."
            return
        }
        guard NativeSettingsStore.isValidFinderEditorCommand(finderEditorCommand) else {
            terminalErrorLabel.stringValue =
                "Finder editor must be a command name or an executable absolute path."
            return
        }
        terminalErrorLabel.stringValue = ""
        let tmuxResolutionChanged =
            settings.shellPath != shellPath
            || settings.tmuxExecutablePath != tmuxExecutablePath
        settings.shellPath = shellPath
        settings.tmuxExecutablePath = tmuxExecutablePath
        settings.startupDirectory = startupDirectory
        settings.finderEditorCommand = finderEditorCommand
        commit()
        if tmuxResolutionChanged {
            refreshTmuxStatus(force: true)
        }
    }

    @objc private func chooseDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(
            fileURLWithPath: settings.startupDirectory.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.path
                : settings.startupDirectory
        )
        guard panel.runModal() == .OK, let path = panel.url?.path else {
            return
        }
        settings.startupDirectory = path
        directoryField?.stringValue = path
        commit()
    }

    @objc private func chooseTmuxExecutable(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if !settings.tmuxExecutablePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: settings.tmuxExecutablePath)
                .deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let path = panel.url?.path,
            NativeSettingsStore.isValidTmuxExecutablePath(path)
        else {
            return
        }
        settings.tmuxExecutablePath = path
        tmuxField?.stringValue = path
        commit()
        refreshTmuxStatus(force: true)
    }

    @objc private func redetectTmux(_ sender: Any?) {
        refreshTmuxStatus(force: true)
    }

    @objc private func updateIntervalChanged(_ sender: NSPopUpButton) {
        settings.updateCheckIntervalHours =
            sender.selectedItem?.tag == 0
            ? 0
            : Double(sender.selectedItem?.tag ?? 24)
        commit()
    }

    @objc private func checkForUpdates(_ sender: NSButton) {
        onCheckForUpdates?()
    }

    func setUpdateCheckInProgress(_ isChecking: Bool) {
        checkForUpdatesButton?.title = isChecking ? "Checking…" : "Check for Updates…"
        checkForUpdatesButton?.isEnabled = !nativeIsDevelopmentBuild && !isChecking
    }

    @objc private func shortcutChanged(_ sender: NSTextField) {
        guard let identifier = sender.identifier?.rawValue,
            let command = NativeCommandID(rawValue: identifier)
        else {
            return
        }
        settings.keyBindings[command.rawValue] = sender.stringValue
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        _ = validateShortcuts()
        commitIfShortcutsValid()
    }

    @objc private func resetDefaults(_ sender: Any?) {
        settings = store.reset()
        refreshControls()
        refreshTmuxStatus(force: true)
        onChange?(settings)
    }

    private func generalView() -> NSView {
        let option = checkbox("Use Option as Alt", action: #selector(booleanChanged(_:)))
        let notifications = checkbox("Bell notifications", action: #selector(booleanChanged(_:)))
        let restore = checkbox(
            "Restore tabs and panes on launch", action: #selector(booleanChanged(_:)))
        let confirmBeforeQuit = checkbox(
            "Confirm before quitting Satin", action: #selector(booleanChanged(_:)))
        optionAsAltButton = option
        notificationButton = notifications
        sessionRestoreButton = restore
        confirmBeforeQuitButton = confirmBeforeQuit
        return sectionView(
            title: "General",
            description: "General terminal, session, and application behavior.",
            rows: [option, notifications, restore, confirmBeforeQuit],
            footer: resetButton()
        )
    }

    private func appearanceView() -> NSView {
        let fonts = NSPopUpButton()
        fonts.addItem(withTitle: "Bundled Default")
        for family in fixedPitchFontFamilies() {
            fonts.addItem(withTitle: family)
        }
        fonts.target = self
        fonts.action = #selector(fontChanged(_:))
        fontPopup = fonts

        let sizeField = NSTextField()
        sizeField.alignment = .right
        sizeField.target = self
        sizeField.action = #selector(fontSizeChanged(_:))
        sizeField.formatter = integerFormatter(
            minimum: nativeMinimumFontSize,
            maximum: nativeMaximumFontSize
        )
        fontSizeField = sizeField

        let stepper = NSStepper()
        stepper.minValue = nativeMinimumFontSize
        stepper.maxValue = nativeMaximumFontSize
        stepper.increment = 1
        stepper.target = self
        stepper.action = #selector(fontStepperChanged(_:))

        let sizeRow = NSStackView(views: [sizeField, stepper])
        sizeRow.orientation = .horizontal
        sizeRow.spacing = 8

        let modes = NSPopUpButton()
        modes.addItems(withTitles: NativeAppearanceMode.allCases.map(\.title))
        modes.target = self
        modes.action = #selector(appearanceModeChanged(_:))
        appearanceModePopup = modes

        let themes = NSPopUpButton()
        themes.addItems(withTitles: nativeThemeNames)
        themes.target = self
        themes.action = #selector(themeChanged(_:))
        themePopup = themes

        let attentionHand = checkbox(
            "Deal agents that need you as cards", action: #selector(booleanChanged(_:)))
        attentionHandButton = attentionHand
        let backdrop = checkbox(
            "Swirl paint under the panes (experimental)", action: #selector(booleanChanged(_:)))
        animatedBackdropButton = backdrop
        let ambient = checkbox(
            "Play soft pads while you work (experimental)", action: #selector(booleanChanged(_:)))
        ambientSoundButton = ambient
        let chimes = checkbox(
            "Chime when an agent waits, fails or finishes", action: #selector(booleanChanged(_:)))
        agentChimesButton = chimes
        return formView(
            title: "Appearance",
            description:
                "Font changes apply immediately. Theme updates the current tab and new tabs.",
            rows: [
                ("Mode", modes),
                ("Font", fonts),
                ("Font size", sizeRow),
                ("Theme", themes),
                ("Attention hand", attentionHand),
                ("Backdrop", backdrop),
                ("Ambient sound", ambient),
                ("Agent chimes", chimes),
            ]
        )
    }

    @objc private func appearanceModeChanged(_ sender: NSPopUpButton) {
        let index = max(0, sender.indexOfSelectedItem)
        settings.appearanceMode = NativeAppearanceMode.allCases[index].rawValue
        commit()
    }

    @objc private func fontStepperChanged(_ sender: NSStepper) {
        fontSizeField?.doubleValue = sender.doubleValue
        fontSizeChanged(fontSizeField ?? NSTextField())
    }

    private func terminalView() -> NSView {
        let shell = NSTextField()
        shell.placeholderString = "Login shell (for example /bin/zsh)"
        shell.target = self
        shell.action = #selector(terminalPathChanged(_:))
        shell.delegate = self
        shellField = shell

        let directory = NSTextField()
        directory.placeholderString = "User home directory"
        directory.target = self
        directory.action = #selector(terminalPathChanged(_:))
        directory.delegate = self
        directoryField = directory

        let choose = NSButton(
            title: "Choose…", target: self, action: #selector(chooseDirectory(_:)))
        let directoryRow = NSStackView(views: [directory, choose])
        directoryRow.orientation = .horizontal
        directoryRow.spacing = 8

        let finderEditor = NSTextField()
        finderEditor.placeholderString = "nvim"
        finderEditor.target = self
        finderEditor.action = #selector(terminalPathChanged(_:))
        finderEditor.delegate = self
        finderEditorField = finderEditor

        let tmux = NSTextField()
        tmux.placeholderString = "Automatic"
        tmux.target = self
        tmux.action = #selector(terminalPathChanged(_:))
        tmux.delegate = self
        tmuxField = tmux
        let chooseTmux = NSButton(
            title: "Choose…", target: self, action: #selector(chooseTmuxExecutable(_:)))
        let redetectTmux = NSButton(
            image: NSImage(
                systemSymbolName: "arrow.clockwise",
                accessibilityDescription: "Re-detect tmux"
            ) ?? NSImage(),
            target: self,
            action: #selector(redetectTmux(_:))
        )
        redetectTmux.toolTip = "Re-detect tmux"
        let tmuxRow = NSStackView(views: [tmux, chooseTmux, redetectTmux])
        tmuxRow.orientation = .horizontal
        tmuxRow.spacing = 8
        tmuxStatusLabel.textColor = .secondaryLabelColor
        tmuxStatusLabel.maximumNumberOfLines = 2
        terminalErrorLabel.textColor = .systemRed
        terminalErrorLabel.maximumNumberOfLines = 2
        return formView(
            title: "Terminal",
            description: "Shell and tool paths apply to new panes and tmux connections.",
            rows: [
                ("Shell", shell),
                ("Startup directory", directoryRow),
                ("Finder editor", finderEditor),
                ("tmux executable", tmuxRow),
                ("Detected tmux", tmuxStatusLabel),
            ],
            footer: terminalErrorLabel
        )
    }

    private func keybindingsView() -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        for command in NativeCommandID.allCases {
            let field = NSTextField()
            field.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
            field.placeholderString = command.defaultShortcut
            field.target = self
            field.action = #selector(shortcutChanged(_:))
            field.delegate = self
            shortcutFields[command] = field
            grid.addRow(with: [NSTextField(labelWithString: command.title), field])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 180
        shortcutErrorLabel.textColor = .systemRed
        shortcutErrorLabel.maximumNumberOfLines = 2
        let content = NSStackView(views: [grid, shortcutErrorLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        return sectionView(
            title: "Keybindings",
            description: "Use forms such as cmd+t or cmd+shift+d. Command is required.",
            rows: [content],
            footer: nil
        )
    }

    private func updatesView() -> NSView {
        let automatic = checkbox(
            "Automatically check for signed updates",
            action: #selector(booleanChanged(_:))
        )
        automaticUpdatesButton = automatic
        let interval = NSPopUpButton()
        interval.addItem(withTitle: "Every launch")
        interval.lastItem?.tag = 0
        interval.addItem(withTitle: "Daily")
        interval.lastItem?.tag = 24
        interval.addItem(withTitle: "Weekly")
        interval.lastItem?.tag = 168
        interval.target = self
        interval.action = #selector(updateIntervalChanged(_:))
        updateIntervalPopup = interval
        let channel = NSTextField(labelWithString: "Stable — publisher-signed GitHub Releases")
        channel.textColor = .secondaryLabelColor
        let checkNow = NSButton(
            title: "Check for Updates…",
            target: self,
            action: #selector(checkForUpdates(_:))
        )
        checkNow.bezelStyle = .rounded
        checkNow.isEnabled = !nativeIsDevelopmentBuild
        if nativeIsDevelopmentBuild {
            checkNow.toolTip = "Update checks are available in release builds."
        }
        checkForUpdatesButton = checkNow
        return formView(
            title: "Updates",
            description: "Update archives are verified with the embedded Ed25519 public key.",
            rows: [
                ("Automatic checks", automatic),
                ("Frequency", interval),
                ("Channel", channel),
                ("Manual check", checkNow),
            ]
        )
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }
        if field === shellField || field === tmuxField || field === directoryField
            || field === finderEditorField
        {
            terminalPathChanged(field)
        } else if field.identifier != nil {
            shortcutChanged(field)
        }
    }

    private func commit() {
        store.save(settings)
        onChange?(settings)
    }

    private func commitIfShortcutsValid() {
        guard validateShortcuts() else {
            return
        }
        commit()
    }

    @discardableResult
    private func validateShortcuts() -> Bool {
        var seen = Set<String>()
        let reserved = Set(
            nativeReservedShortcutValues.compactMap {
                NativeKeyShortcut.parse($0)?.identity
            }
        )
        for command in NativeCommandID.allCases {
            let value = settings.keyBindings[command.rawValue] ?? command.defaultShortcut
            guard let shortcut = NativeKeyShortcut.parse(value) else {
                shortcutErrorLabel.stringValue =
                    "\(command.title): enter a valid shortcut such as cmd+shift+d."
                return false
            }
            guard !reserved.contains(shortcut.identity) else {
                shortcutErrorLabel.stringValue =
                    "\(command.title): that shortcut is reserved by a standard app command."
                return false
            }
            guard seen.insert(shortcut.identity).inserted else {
                shortcutErrorLabel.stringValue = "Each command must have a unique shortcut."
                return false
            }
        }
        shortcutErrorLabel.stringValue = ""
        return true
    }

    private func refreshControls() {
        settings = store.load()
        optionAsAltButton?.state = settings.optionAsAlt ? .on : .off
        notificationButton?.state = settings.notifications ? .on : .off
        attentionHandButton?.state = settings.attentionHand ? .on : .off
        animatedBackdropButton?.state = settings.animatedBackdrop ? .on : .off
        ambientSoundButton?.state = settings.ambientSound ? .on : .off
        appearanceModePopup?.selectItem(
            at: NativeAppearanceMode.allCases.firstIndex {
                $0.rawValue == settings.appearanceMode
            } ?? 0)
        agentChimesButton?.state = settings.agentChimes ? .on : .off
        sessionRestoreButton?.state = settings.sessionRestore ? .on : .off
        confirmBeforeQuitButton?.state = settings.confirmBeforeQuit ? .on : .off
        fontPopup?.selectItem(
            withTitle: settings.fontFamily.isEmpty ? "Bundled Default" : settings.fontFamily
        )
        fontSizeField?.doubleValue = settings.fontSize
        themePopup?.selectItem(withTitle: settings.defaultTheme)
        shellField?.stringValue = settings.shellPath
        tmuxField?.stringValue = settings.tmuxExecutablePath
        directoryField?.stringValue = settings.startupDirectory
        finderEditorField?.stringValue = settings.finderEditorCommand
        terminalErrorLabel.stringValue = ""
        automaticUpdatesButton?.state = settings.automaticUpdateChecks ? .on : .off
        updateIntervalPopup?.selectItem(
            withTag: Int(settings.updateCheckIntervalHours)
        )
        updateIntervalPopup?.isEnabled = settings.automaticUpdateChecks
        for command in NativeCommandID.allCases {
            shortcutFields[command]?.stringValue =
                settings.keyBindings[command.rawValue] ?? command.defaultShortcut
        }
        _ = validateShortcuts()
    }

    private func refreshTmuxStatus(force: Bool = false) {
        let configuredPath = settings.tmuxExecutablePath
        let shellPath = settings.shellPath
        tmuxStatusLabel.stringValue = "Detecting…"
        tmuxStatusLabel.textColor = .secondaryLabelColor
        NativeTmuxExecutableResolver.shared.resolve(
            configuredPath: configuredPath,
            shellPath: shellPath,
            force: force
        ) { [weak self] resolution in
            guard let self,
                self.settings.tmuxExecutablePath == configuredPath,
                self.settings.shellPath == shellPath
            else {
                return
            }
            switch resolution {
            case .available(let executable):
                self.tmuxStatusLabel.stringValue =
                    "tmux \(executable.version) · \(executable.source.label)\n\(executable.path)"
                self.tmuxStatusLabel.textColor = .secondaryLabelColor
            case .unavailable(let message):
                self.tmuxStatusLabel.stringValue = message
                self.tmuxStatusLabel.textColor = .systemRed
            }
        }
    }

    private func tab(title: String, symbol: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(viewController: NSViewController())
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.viewController?.view = view
        return item
    }

    private func sectionView(
        title: String,
        description: String,
        rows: [NSView],
        footer: NSView?
    ) -> NSView {
        let stack = baseStack(title: title, description: description)
        for row in rows {
            stack.addArrangedSubview(row)
        }
        if let footer {
            stack.addArrangedSubview(footer)
        }
        return padded(stack)
    }

    private func formView(
        title: String,
        description: String,
        rows: [(String, NSView)],
        footer: NSView? = nil
    ) -> NSView {
        let stack = baseStack(title: title, description: description)
        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 18
        for (label, control) in rows {
            grid.addRow(with: [NSTextField(labelWithString: label), control])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        stack.addArrangedSubview(grid)
        if let footer {
            stack.addArrangedSubview(footer)
        }
        return padded(stack)
    }

    private func baseStack(title: String, description: String) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: description)
        detail.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        return stack
    }

    private func padded(_ content: NSView) -> NSView {
        let view = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
        ])
        return view
    }

    private func checkbox(_ title: String, action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }

    private func resetButton() -> NSButton {
        let button = NSButton(
            title: "Restore Defaults",
            target: self,
            action: #selector(resetDefaults(_:))
        )
        button.bezelStyle = .rounded
        return button
    }

    private func integerFormatter(minimum: Double, maximum: Double) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = NSNumber(value: minimum)
        formatter.maximum = NSNumber(value: maximum)
        formatter.allowsFloats = false
        return formatter
    }

    private func fixedPitchFontFamilies() -> [String] {
        let manager = NSFontManager.shared
        return manager.availableFontFamilies
            .filter { family in
                guard
                    let font = manager.font(
                        withFamily: family,
                        traits: [],
                        weight: 5,
                        size: nativeDefaultFontSize
                    )
                else {
                    return false
                }
                return manager.traits(of: font).contains(.fixedPitchFontMask)
            }
            .sorted()
    }
}

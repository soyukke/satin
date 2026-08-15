import AppKit
import Foundation

let nativeThemeNames = ["Graphite", "Juniper", "Harbor", "Rose", "Paper"]
let nativeDefaultFontSize = 15.0
let nativeMinimumFontSize = 9.0
let nativeMaximumFontSize = 32.0

enum NativePreferenceKey {
    static let fontFamily = "terminalFontFamily"
    static let fontSize = "terminalFontSize"
    static let optionAsAlt = "optionAsAlt"
    static let notifications = "bellNotifications"
    static let sessionRestore = "restoreSession"
    static let sessionState = "sessionState"
    static let defaultTheme = "defaultTheme"
    static let shellPath = "shellPath"
    static let tmuxExecutablePath = "tmuxExecutablePath"
    static let startupDirectory = "startupDirectory"
    static let finderEditorCommand = "finderEditorCommand"
    static let automaticUpdateChecks = "automaticUpdateChecks"
    static let updateCheckIntervalHours = "updateCheckIntervalHours"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let keyBindings = "keyBindings"
    static let legacyMigration = "didMigrateNeovideTabsDefaultsV1"

    static let migratedKeys = [
        fontFamily,
        fontSize,
        optionAsAlt,
        notifications,
        sessionRestore,
        sessionState,
        defaultTheme,
        shellPath,
        tmuxExecutablePath,
        startupDirectory,
        finderEditorCommand,
        automaticUpdateChecks,
        updateCheckIntervalHours,
        lastUpdateCheck,
        keyBindings,
    ]
}

struct NativeSettings: Equatable {
    var fontFamily: String
    var fontSize: Double
    var optionAsAlt: Bool
    var notifications: Bool
    var sessionRestore: Bool
    var defaultTheme: String
    var shellPath: String
    var tmuxExecutablePath: String
    var startupDirectory: String
    var finderEditorCommand: String
    var automaticUpdateChecks: Bool
    var updateCheckIntervalHours: Double
    var keyBindings: [String: String]

    func shortcut(for command: NativeCommandID) -> NativeKeyShortcut {
        let value = keyBindings[command.rawValue] ?? command.defaultShortcut
        guard
            let shortcut = NativeKeyShortcut.parse(value)
                ?? NativeKeyShortcut.parse(command.defaultShortcut)
        else {
            preconditionFailure("invalid built-in shortcut for \(command.rawValue)")
        }
        return shortcut
    }
}

final class NativeSettingsStore {
    private static let legacyBundleIdentifier = "dev.soyukke.neovide-tabs"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: NativePreferenceKey.legacyMigration) else {
            return
        }
        if let legacyValues = defaults.persistentDomain(
            forName: legacyBundleIdentifier
        ) {
            migrateLegacyValues(legacyValues, into: defaults)
        }
        defaults.set(true, forKey: NativePreferenceKey.legacyMigration)
    }

    func load() -> NativeSettings {
        NativeSettings(
            fontFamily: validFontFamily(
                defaults.string(forKey: NativePreferenceKey.fontFamily) ?? ""
            ),
            fontSize: boundedFontSize(
                defaults.object(forKey: NativePreferenceKey.fontSize) as? Double
                    ?? nativeDefaultFontSize
            ),
            optionAsAlt: preferredBool(NativePreferenceKey.optionAsAlt, defaultValue: true),
            notifications: preferredBool(
                NativePreferenceKey.notifications,
                defaultValue: true
            ),
            sessionRestore: preferredBool(
                NativePreferenceKey.sessionRestore,
                defaultValue: true
            ),
            defaultTheme: validTheme(
                defaults.string(forKey: NativePreferenceKey.defaultTheme) ?? nativeThemeNames[0]
            ),
            shellPath: validShellPath(
                defaults.string(forKey: NativePreferenceKey.shellPath) ?? ""
            ),
            tmuxExecutablePath: validTmuxExecutablePath(
                defaults.string(forKey: NativePreferenceKey.tmuxExecutablePath) ?? ""
            ),
            startupDirectory: validStartupDirectory(
                defaults.string(forKey: NativePreferenceKey.startupDirectory) ?? ""
            ),
            finderEditorCommand: validFinderEditorCommand(
                defaults.string(forKey: NativePreferenceKey.finderEditorCommand) ?? "nvim"
            ),
            automaticUpdateChecks: preferredBool(
                NativePreferenceKey.automaticUpdateChecks,
                defaultValue: true
            ),
            updateCheckIntervalHours: validUpdateInterval(
                defaults.object(forKey: NativePreferenceKey.updateCheckIntervalHours) as? Double
                    ?? 24
            ),
            keyBindings: validKeyBindings(storedKeyBindings())
        )
    }

    func save(_ settings: NativeSettings) {
        defaults.set(
            validFontFamily(settings.fontFamily),
            forKey: NativePreferenceKey.fontFamily
        )
        defaults.set(boundedFontSize(settings.fontSize), forKey: NativePreferenceKey.fontSize)
        defaults.set(settings.optionAsAlt, forKey: NativePreferenceKey.optionAsAlt)
        defaults.set(settings.notifications, forKey: NativePreferenceKey.notifications)
        defaults.set(settings.sessionRestore, forKey: NativePreferenceKey.sessionRestore)
        defaults.set(validTheme(settings.defaultTheme), forKey: NativePreferenceKey.defaultTheme)
        defaults.set(validShellPath(settings.shellPath), forKey: NativePreferenceKey.shellPath)
        defaults.set(
            validTmuxExecutablePath(settings.tmuxExecutablePath),
            forKey: NativePreferenceKey.tmuxExecutablePath
        )
        defaults.set(
            validStartupDirectory(settings.startupDirectory),
            forKey: NativePreferenceKey.startupDirectory
        )
        defaults.set(
            validFinderEditorCommand(settings.finderEditorCommand),
            forKey: NativePreferenceKey.finderEditorCommand
        )
        defaults.set(
            settings.automaticUpdateChecks,
            forKey: NativePreferenceKey.automaticUpdateChecks
        )
        defaults.set(
            validUpdateInterval(settings.updateCheckIntervalHours),
            forKey: NativePreferenceKey.updateCheckIntervalHours
        )
        defaults.set(
            validKeyBindings(settings.keyBindings),
            forKey: NativePreferenceKey.keyBindings
        )
        if !settings.sessionRestore {
            defaults.removeObject(forKey: NativePreferenceKey.sessionState)
        }
    }

    func reset() -> NativeSettings {
        let persistentKeys = [
            NativePreferenceKey.fontFamily,
            NativePreferenceKey.fontSize,
            NativePreferenceKey.optionAsAlt,
            NativePreferenceKey.notifications,
            NativePreferenceKey.sessionRestore,
            NativePreferenceKey.defaultTheme,
            NativePreferenceKey.shellPath,
            NativePreferenceKey.tmuxExecutablePath,
            NativePreferenceKey.startupDirectory,
            NativePreferenceKey.finderEditorCommand,
            NativePreferenceKey.automaticUpdateChecks,
            NativePreferenceKey.updateCheckIntervalHours,
            NativePreferenceKey.keyBindings,
        ]
        for key in persistentKeys {
            defaults.removeObject(forKey: key)
        }
        return load()
    }

    func shouldAutomaticallyCheckForUpdates(now: Date = Date()) -> Bool {
        let settings = load()
        guard settings.automaticUpdateChecks else {
            return false
        }
        guard settings.updateCheckIntervalHours > 0,
            let lastCheck = defaults.object(
                forKey: NativePreferenceKey.lastUpdateCheck
            ) as? Date
        else {
            return true
        }
        return now.timeIntervalSince(lastCheck)
            >= settings.updateCheckIntervalHours * 60 * 60
    }

    func recordUpdateCheck(at date: Date = Date()) {
        defaults.set(date, forKey: NativePreferenceKey.lastUpdateCheck)
    }

    static func migrateLegacyValues(
        _ legacyValues: [String: Any],
        into defaults: UserDefaults
    ) {
        for key in NativePreferenceKey.migratedKeys
        where defaults.object(forKey: key) == nil {
            guard let value = legacyValues[key] else {
                continue
            }
            defaults.set(value, forKey: key)
        }
    }

    private func preferredBool(_ key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    private func storedKeyBindings() -> [String: String] {
        guard
            let stored = defaults.dictionary(
                forKey: NativePreferenceKey.keyBindings
            ) as? [String: String]
        else {
            return defaultKeyBindings()
        }
        return defaultKeyBindings().merging(stored) { _, saved in saved }
    }

    func defaultKeyBindings() -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: NativeCommandID.allCases.map {
                ($0.rawValue, $0.defaultShortcut)
            }
        )
    }

    private func boundedFontSize(_ value: Double) -> Double {
        min(max(value, nativeMinimumFontSize), nativeMaximumFontSize)
    }

    private func validTheme(_ value: String) -> String {
        nativeThemeNames.contains(value) ? value : nativeThemeNames[0]
    }

    private func validFontFamily(_ value: String) -> String {
        guard !value.isEmpty else {
            return ""
        }
        return NSFontManager.shared.availableFontFamilies.contains(value) ? value : ""
    }

    private func validShellPath(_ value: String) -> String {
        Self.isValidShellPath(value) ? value : ""
    }

    private func validTmuxExecutablePath(_ value: String) -> String {
        Self.isValidTmuxExecutablePath(value) ? value : ""
    }

    private func validStartupDirectory(_ value: String) -> String {
        Self.isValidStartupDirectory(value) ? value : ""
    }

    private func validFinderEditorCommand(_ value: String) -> String {
        Self.isValidFinderEditorCommand(value) ? value : "nvim"
    }

    private func validKeyBindings(_ values: [String: String]) -> [String: String] {
        var seen = Set<String>()
        let reserved = Set(
            nativeReservedShortcutValues.compactMap {
                NativeKeyShortcut.parse($0)?.identity
            }
        )
        var normalized: [String: String] = [:]
        for command in NativeCommandID.allCases {
            let value =
                values[command.rawValue]?
                .lowercased()
                .replacingOccurrences(of: " ", with: "")
                ?? command.defaultShortcut
            guard let shortcut = NativeKeyShortcut.parse(value),
                !reserved.contains(shortcut.identity),
                seen.insert(shortcut.identity).inserted
            else {
                return defaultKeyBindings()
            }
            normalized[command.rawValue] = value
        }
        return normalized
    }

    private func validUpdateInterval(_ value: Double) -> Double {
        [0.0, 24.0, 168.0].contains(value) ? value : 24
    }

}

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
    private var sessionRestoreButton: NSButton?
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
        settings.sessionRestore = sessionRestoreButton?.state == .on
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
        optionAsAltButton = option
        notificationButton = notifications
        sessionRestoreButton = restore
        return sectionView(
            title: "General",
            description: "Changes to input and notifications apply to running terminal panes.",
            rows: [option, notifications, restore],
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

        let themes = NSPopUpButton()
        themes.addItems(withTitles: nativeThemeNames)
        themes.target = self
        themes.action = #selector(themeChanged(_:))
        themePopup = themes
        return formView(
            title: "Appearance",
            description:
                "Font changes apply immediately. Theme updates the current tab and new tabs.",
            rows: [
                ("Font", fonts),
                ("Font size", sizeRow),
                ("Theme", themes),
            ]
        )
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
        sessionRestoreButton?.state = settings.sessionRestore ? .on : .off
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

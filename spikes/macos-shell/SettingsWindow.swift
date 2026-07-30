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
    static let startupDirectory = "startupDirectory"
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
        startupDirectory,
        automaticUpdateChecks,
        updateCheckIntervalHours,
        lastUpdateCheck,
        keyBindings,
    ]
}

enum NativeCommandID: String, CaseIterable {
    case newTab
    case splitVertical
    case splitHorizontal
    case closePane
    case renameSession
    case openNativeNeovim
    case zoomIn
    case zoomOut
    case actualSize
    case checkForUpdates

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .splitVertical: "Split Vertical"
        case .splitHorizontal: "Split Horizontal"
        case .closePane: "Close Pane"
        case .renameSession: "Rename Session"
        case .openNativeNeovim: "Open Native Neovim"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .checkForUpdates: "Check for Updates"
        }
    }

    var defaultShortcut: String {
        switch self {
        case .newTab: "cmd+t"
        case .splitVertical: "cmd+d"
        case .splitHorizontal: "cmd+shift+d"
        case .closePane: "cmd+w"
        case .renameSession: "cmd+r"
        case .openNativeNeovim: "cmd+n"
        case .zoomIn: "cmd+="
        case .zoomOut: "cmd+-"
        case .actualSize: "cmd+0"
        case .checkForUpdates: "cmd+u"
        }
    }
}

struct NativeKeyShortcut: Equatable {
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags

    static func parse(_ value: String) -> NativeKeyShortcut? {
        let parts = value
            .lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map(String.init)
        guard let key = parts.last, key.count == 1, !key.isEmpty else {
            return nil
        }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command":
                modifiers.insert(.command)
            case "shift":
                modifiers.insert(.shift)
            case "option", "alt":
                modifiers.insert(.option)
            case "control", "ctrl":
                modifiers.insert(.control)
            default:
                return nil
            }
        }
        guard modifiers.contains(.command) else {
            return nil
        }
        return NativeKeyShortcut(keyEquivalent: key, modifiers: modifiers)
    }

    var identity: String {
        "\(modifiers.rawValue):\(keyEquivalent)"
    }
}

private let nativeReservedShortcutValues = [
    "cmd+,", "cmd+q", "cmd+c", "cmd+v", "cmd+a", "cmd+f",
    "cmd+1", "cmd+2", "cmd+3", "cmd+4", "cmd+5",
    "cmd+6", "cmd+7", "cmd+8", "cmd+9",
]

struct NativeSettings: Equatable {
    var fontFamily: String
    var fontSize: Double
    var optionAsAlt: Bool
    var notifications: Bool
    var sessionRestore: Bool
    var defaultTheme: String
    var shellPath: String
    var startupDirectory: String
    var automaticUpdateChecks: Bool
    var updateCheckIntervalHours: Double
    var keyBindings: [String: String]

    func shortcut(for command: NativeCommandID) -> NativeKeyShortcut {
        let value = keyBindings[command.rawValue] ?? command.defaultShortcut
        return NativeKeyShortcut.parse(value)
            ?? NativeKeyShortcut.parse(command.defaultShortcut)!
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
            startupDirectory: validStartupDirectory(
                defaults.string(forKey: NativePreferenceKey.startupDirectory) ?? ""
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
            validStartupDirectory(settings.startupDirectory),
            forKey: NativePreferenceKey.startupDirectory
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
            NativePreferenceKey.startupDirectory,
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

    static func runSelfTests() -> Bool {
        let suiteName = "dev.soyukke.satin.settings-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return false
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let migrationSuiteName = "dev.soyukke.satin.migration-test.\(UUID().uuidString)"
        guard let migrationDefaults = UserDefaults(suiteName: migrationSuiteName) else {
            return false
        }
        defer {
            migrationDefaults.removePersistentDomain(forName: migrationSuiteName)
        }
        let migratedSession = Data("legacy-session".utf8)
        migrationDefaults.set(17.0, forKey: NativePreferenceKey.fontSize)
        migrateLegacyValues(
            [
                NativePreferenceKey.fontSize: 22.0,
                NativePreferenceKey.defaultTheme: "Rose",
                NativePreferenceKey.sessionState: migratedSession,
            ],
            into: migrationDefaults
        )
        guard migrationDefaults.double(forKey: NativePreferenceKey.fontSize) == 17.0,
              migrationDefaults.string(forKey: NativePreferenceKey.defaultTheme) == "Rose",
              migrationDefaults.data(forKey: NativePreferenceKey.sessionState) == migratedSession
        else {
            return false
        }
        let store = NativeSettingsStore(defaults: defaults)
        let initial = store.load()
        guard initial.optionAsAlt,
              initial.notifications,
              initial.sessionRestore,
              initial.automaticUpdateChecks,
              initial.defaultTheme == "Graphite",
              initial.fontSize == nativeDefaultFontSize,
              NativeCommandID.allCases.allSatisfy({
                  NativeKeyShortcut.parse($0.defaultShortcut) != nil
              })
        else {
            return false
        }
        var changed = initial
        changed.fontFamily = "Menlo"
        changed.fontSize = 19
        changed.defaultTheme = "Harbor"
        changed.automaticUpdateChecks = false
        changed.keyBindings[NativeCommandID.newTab.rawValue] = "cmd+shift+t"
        store.save(changed)
        guard store.load() == changed,
              !store.shouldAutomaticallyCheckForUpdates()
        else {
            return false
        }
        defaults.set("/not/a/real/shell", forKey: NativePreferenceKey.shellPath)
        defaults.set("/not/a/real/directory", forKey: NativePreferenceKey.startupDirectory)
        defaults.set(
            [
                NativeCommandID.newTab.rawValue: "cmd+q",
                NativeCommandID.splitVertical.rawValue: "cmd+q",
            ],
            forKey: NativePreferenceKey.keyBindings
        )
        let repaired = store.load()
        guard repaired.shellPath.isEmpty,
              repaired.startupDirectory.isEmpty,
              repaired.keyBindings == store.defaultKeyBindings()
        else {
            return false
        }
        _ = store.reset()
        return store.load() == initial
    }

    private static func migrateLegacyValues(
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
        guard let stored = defaults.dictionary(
            forKey: NativePreferenceKey.keyBindings
        ) as? [String: String] else {
            return defaultKeyBindings()
        }
        return defaultKeyBindings().merging(stored) { _, saved in saved }
    }

    fileprivate func defaultKeyBindings() -> [String: String] {
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

    private func validStartupDirectory(_ value: String) -> String {
        Self.isValidStartupDirectory(value) ? value : ""
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
            let value = values[command.rawValue]?
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

    static func isValidShellPath(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return true
        }
        return (value as NSString).isAbsolutePath
            && FileManager.default.isExecutableFile(atPath: value)
    }

    static func isValidStartupDirectory(_ value: String) -> Bool {
        guard !value.isEmpty, (value as NSString).isAbsolutePath else {
            return value.isEmpty
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

final class NativeSettingsWindowController: NSWindowController, NSTextFieldDelegate {
    var onChange: ((NativeSettings) -> Void)?

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
    private var directoryField: NSTextField?
    private let terminalErrorLabel = NSTextField(labelWithString: "")
    private var automaticUpdatesButton: NSButton?
    private var updateIntervalPopup: NSPopUpButton?

    init(store: NativeSettingsStore) {
        self.store = store
        self.settings = store.load()
        let tabs = NSTabViewController()
        self.tabController = tabs
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 700, height: 480))
        window.isReleasedWhenClosed = false
        super.init(window: window)
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab(title: "General", symbol: "gearshape", view: generalView()))
        tabs.addTabViewItem(tab(title: "Appearance", symbol: "paintbrush", view: appearanceView()))
        tabs.addTabViewItem(tab(title: "Terminal", symbol: "terminal", view: terminalView()))
        tabs.addTabViewItem(tab(title: "Keybindings", symbol: "keyboard", view: keybindingsView()))
        tabs.addTabViewItem(tab(title: "Updates", symbol: "arrow.triangle.2.circlepath", view: updatesView()))
        tabs.title = "Satin Settings"
        window.title = "Satin Settings"
        refreshControls()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        refreshControls()
        if let requestedTab = ProcessInfo.processInfo.environment["SATIN_SETTINGS_TAB"],
           let index = ["general", "appearance", "terminal", "keybindings", "updates"]
           .firstIndex(of: requestedTab.lowercased()) {
            tabController.selectedTabViewItemIndex = index
        }
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        settings.fontFamily = sender.titleOfSelectedItem == "Bundled Default"
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
        let shellPath = shellField?.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        let startupDirectory = directoryField?.stringValue.trimmingCharacters(
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
        terminalErrorLabel.stringValue = ""
        settings.shellPath = shellPath
        settings.startupDirectory = startupDirectory
        commit()
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

    @objc private func updateIntervalChanged(_ sender: NSPopUpButton) {
        settings.updateCheckIntervalHours = sender.selectedItem?.tag == 0
            ? 0
            : Double(sender.selectedItem?.tag ?? 24)
        commit()
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
        onChange?(settings)
    }

    private func generalView() -> NSView {
        let option = checkbox("Use Option as Alt", action: #selector(booleanChanged(_:)))
        let notifications = checkbox("Bell notifications", action: #selector(booleanChanged(_:)))
        let restore = checkbox("Restore tabs and panes on launch", action: #selector(booleanChanged(_:)))
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
            description: "Font changes apply immediately. The default theme is used for new tabs.",
            rows: [
                ("Font", fonts),
                ("Font size", sizeRow),
                ("Default theme", themes),
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
        directory.placeholderString = "Inherit current directory"
        directory.target = self
        directory.action = #selector(terminalPathChanged(_:))
        directory.delegate = self
        directoryField = directory

        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseDirectory(_:)))
        let directoryRow = NSStackView(views: [directory, choose])
        directoryRow.orientation = .horizontal
        directoryRow.spacing = 8
        terminalErrorLabel.textColor = .systemRed
        terminalErrorLabel.maximumNumberOfLines = 2
        return formView(
            title: "Terminal",
            description: "Shell and startup directory changes apply to newly created panes.",
            rows: [
                ("Shell", shell),
                ("Startup directory", directoryRow),
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
        return formView(
            title: "Updates",
            description: "Update archives are verified with the embedded Ed25519 public key.",
            rows: [
                ("Automatic checks", automatic),
                ("Frequency", interval),
                ("Channel", channel),
            ]
        )
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else {
            return
        }
        if field === shellField || field === directoryField {
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
        directoryField?.stringValue = settings.startupDirectory
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
                guard let font = manager.font(
                    withFamily: family,
                    traits: [],
                    weight: 5,
                    size: nativeDefaultFontSize
                ) else {
                    return false
                }
                return manager.traits(of: font).contains(.fixedPitchFontMask)
            }
            .sorted()
    }
}

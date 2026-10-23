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
    static let confirmBeforeQuit = "confirmBeforeQuit"
    static let confirmBeforeClosingBusyTab = "confirmBeforeClosingBusyTab"
    static let sessionState = "sessionState"
    static let tmuxRestorePlan = "tmuxRestorePlan"
    static let defaultTheme = "defaultTheme"
    static let attentionHand = "attentionHand"
    static let animatedBackdrop = "animatedBackdrop"
    static let ambientSound = "ambientSound"
    static let appearanceMode = "appearanceMode"
    static let agentChimes = "agentChimes"
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
        confirmBeforeQuit,
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
    var confirmBeforeQuit: Bool
    var confirmBeforeClosingBusyTab: Bool
    var defaultTheme: String
    var attentionHand: Bool
    var animatedBackdrop: Bool
    var ambientSound: Bool
    var appearanceMode: String
    var agentChimes: Bool
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
            confirmBeforeQuit: preferredBool(
                NativePreferenceKey.confirmBeforeQuit,
                defaultValue: true
            ),
            confirmBeforeClosingBusyTab: preferredBool(
                NativePreferenceKey.confirmBeforeClosingBusyTab,
                defaultValue: true
            ),
            defaultTheme: validTheme(
                defaults.string(forKey: NativePreferenceKey.defaultTheme) ?? nativeThemeNames[0]
            ),
            attentionHand: preferredBool(NativePreferenceKey.attentionHand, defaultValue: false),
            animatedBackdrop: preferredBool(
                NativePreferenceKey.animatedBackdrop, defaultValue: false),
            ambientSound: preferredBool(NativePreferenceKey.ambientSound, defaultValue: false),
            appearanceMode: NativeAppearanceMode(
                rawValue: defaults.string(forKey: NativePreferenceKey.appearanceMode) ?? ""
            )?.rawValue ?? NativeAppearanceMode.terminal.rawValue,
            agentChimes: preferredBool(NativePreferenceKey.agentChimes, defaultValue: false),
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
        defaults.set(settings.confirmBeforeQuit, forKey: NativePreferenceKey.confirmBeforeQuit)
        defaults.set(
            settings.confirmBeforeClosingBusyTab,
            forKey: NativePreferenceKey.confirmBeforeClosingBusyTab
        )
        defaults.set(validTheme(settings.defaultTheme), forKey: NativePreferenceKey.defaultTheme)
        defaults.set(settings.attentionHand, forKey: NativePreferenceKey.attentionHand)
        defaults.set(settings.animatedBackdrop, forKey: NativePreferenceKey.animatedBackdrop)
        defaults.set(settings.ambientSound, forKey: NativePreferenceKey.ambientSound)
        defaults.set(settings.appearanceMode, forKey: NativePreferenceKey.appearanceMode)
        defaults.set(settings.agentChimes, forKey: NativePreferenceKey.agentChimes)
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
            NativePreferenceKey.confirmBeforeQuit,
            NativePreferenceKey.confirmBeforeClosingBusyTab,
            NativePreferenceKey.defaultTheme,
            NativePreferenceKey.attentionHand,
            NativePreferenceKey.animatedBackdrop,
            NativePreferenceKey.ambientSound,
            NativePreferenceKey.appearanceMode,
            NativePreferenceKey.agentChimes,
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

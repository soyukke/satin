import Foundation

extension NativeSettingsStore {
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
            initial.confirmBeforeQuit,
            initial.automaticUpdateChecks,
            initial.defaultTheme == "Graphite",
            initial.finderEditorCommand == "nvim",
            initial.tmuxExecutablePath.isEmpty,
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
        changed.finderEditorCommand = "vim"
        changed.tmuxExecutablePath = "/usr/bin/true"
        changed.confirmBeforeQuit = false
        changed.automaticUpdateChecks = false
        changed.keyBindings[NativeCommandID.newTab.rawValue] = "cmd+shift+t"
        store.save(changed)
        guard store.load() == changed,
            !store.shouldAutomaticallyCheckForUpdates()
        else {
            return false
        }
        defaults.set("/not/a/real/shell", forKey: NativePreferenceKey.shellPath)
        defaults.set(
            "/not/a/real/tmux",
            forKey: NativePreferenceKey.tmuxExecutablePath
        )
        defaults.set("/not/a/real/directory", forKey: NativePreferenceKey.startupDirectory)
        defaults.set("nvim --clean", forKey: NativePreferenceKey.finderEditorCommand)
        defaults.set(
            [
                NativeCommandID.newTab.rawValue: "cmd+q",
                NativeCommandID.splitVertical.rawValue: "cmd+q",
            ],
            forKey: NativePreferenceKey.keyBindings
        )
        let repaired = store.load()
        guard repaired.shellPath.isEmpty,
            repaired.tmuxExecutablePath.isEmpty,
            repaired.startupDirectory.isEmpty,
            repaired.finderEditorCommand == "nvim",
            repaired.keyBindings == store.defaultKeyBindings()
        else {
            return false
        }
        _ = store.reset()
        return store.load() == initial
    }
}

import Foundation

private let applePressAndHoldPreferenceKey = "ApplePressAndHoldEnabled"

private func registerNativeApplicationDefaults(_ defaults: UserDefaults) {
    // Let held character keys reach terminal views instead of opening accent selection.
    defaults.register(defaults: [applePressAndHoldPreferenceKey: false])
}

func prepareNativeApplicationDefaults() {
    registerNativeApplicationDefaults(.standard)
    NativeSettingsStore.migrateLegacyDefaultsIfNeeded()
}

func runNativeApplicationDefaultsSelfTests() -> Bool {
    let suiteName = "dev.soyukke.satin.application-defaults-test.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        return false
    }
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }

    registerNativeApplicationDefaults(defaults)
    return defaults.object(forKey: applePressAndHoldPreferenceKey) as? Bool == false
        && NativeSettingsStore.runSelfTests()
}

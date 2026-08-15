import AppKit
import Darwin
import Foundation

func nativeApplicationAvoidsActivation(_ environment: [String: String]) -> Bool {
    #if SATIN_SMOKE_SCENARIOS
        environment["SATIN_NATIVE_SMOKE_SCENARIO"] != nil
            && environment["SATIN_NATIVE_SMOKE_ALLOW_ACTIVATION"] != "1"
    #else
        false
    #endif
}

func runNativeApplicationActivationSelfTests() -> Bool {
    #if SATIN_SMOKE_SCENARIOS
        nativeApplicationAvoidsActivation(["SATIN_NATIVE_SMOKE_SCENARIO": "nvim-scroll"])
            && !nativeApplicationAvoidsActivation([:])
            && !nativeApplicationAvoidsActivation([
                "SATIN_NATIVE_SMOKE_SCENARIO": "nvim-scroll",
                "SATIN_NATIVE_SMOKE_ALLOW_ACTIVATION": "1",
            ])
    #else
        !nativeApplicationAvoidsActivation(["SATIN_NATIVE_SMOKE_SCENARIO": "nvim-scroll"])
    #endif
}

@main
struct SatinApplication {
    private static func failDiagnostic(_ message: String) -> Never {
        fputs("\(message)\n", stderr)
        exit(EXIT_FAILURE)
    }

    static func main() {
        if let releaseRoot = ProcessInfo.processInfo.environment[
            "SATIN_UPDATE_VERIFY_INSTALLABLE_RELEASE_ROOT"
        ] {
            let root = URL(fileURLWithPath: releaseRoot, isDirectory: true)
            if !AppUpdateInstaller.verifyInstallableRelease(at: root) {
                failDiagnostic("installable release verification failed")
            }
            print("installable release verification passed")
            return
        }
        if let releaseRoot = ProcessInfo.processInfo.environment[
            "SATIN_UPDATE_VERIFY_RELEASE_ROOT"
        ] {
            let root = URL(fileURLWithPath: releaseRoot, isDirectory: true)
            if !AppUpdateInstaller.verifyRelease(at: root) {
                failDiagnostic("signed release verification failed")
            }
            print("signed release verification passed")
            return
        }
        if ProcessInfo.processInfo.environment["SATIN_UPDATE_SELF_TEST"] == "1" {
            if !AppUpdateChecker.runSelfTests()
                || !AppUpdateInstaller.runSelfTests()
                || !runNativeApplicationDefaultsSelfTests()
                || !NativeTmuxExecutableResolver.runSelfTests()
                || !NativeFinderEditorLaunch.runSelfTests()
                || !RustCore.runSelfTests()
                || !runNativeApplicationActivationSelfTests()
                || !runNativeFrameSchedulingSelfTests()
                || !runNativeTmuxSplitCommandSelfTests()
                || !runTerminalTextInputSelfTests()
                || !NativeMainMenuController.runSelfTests()
                || !runNativeAgentActivitySelfTests()
                || !runNativeWorkSwitcherSelfTests()
            {
                failDiagnostic("update self-test failed")
            }
            print("update self-test passed")
            return
        }
        if let currentVersion = ProcessInfo.processInfo.environment[
            "SATIN_UPDATE_LIVE_CHECK_VERSION"
        ] {
            let expected =
                ProcessInfo.processInfo.environment[
                    "SATIN_UPDATE_LIVE_CHECK_EXPECTED"
                ] ?? "current"
            if !AppUpdateChecker.runLiveSmoke(
                currentVersion: currentVersion,
                expected: expected
            ) {
                failDiagnostic("update live smoke failed")
            }
            return
        }

        prepareNativeApplicationDefaults()
        let app = NSApplication.shared
        let delegate = SatinAppDelegate()
        app.delegate = delegate
        let avoidsActivation = nativeApplicationAvoidsActivation(
            ProcessInfo.processInfo.environment
        )
        app.setActivationPolicy(avoidsActivation ? .accessory : .regular)
        app.run()
    }
}

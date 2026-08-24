private let deterministicFrameSmokeScenarios: Set<String> = [
    "nvim-layout-redraw",
    "terminal-resize",
    // The reattach host deliberately runs as a non-activating accessory app.
    // Drive its spring deterministically even when macOS fully occludes it.
    "tmux-reattach",
]

func nativeSmokeUsesDeterministicFrames(_ scenario: String?) -> Bool {
    guard let scenario else {
        return false
    }
    return scenario.hasPrefix("nvim-cursor-")
        || deterministicFrameSmokeScenarios.contains(scenario)
}

func runNativeFrameSchedulingSelfTests() -> Bool {
    [
        "nvim-cursor-move",
        "nvim-layout-redraw",
        "terminal-resize",
        "tmux-reattach",
    ].allSatisfy(nativeSmokeUsesDeterministicFrames)
        && !nativeSmokeUsesDeterministicFrames(nil)
        && !nativeSmokeUsesDeterministicFrames("nvim-jump")
        && !nativeSmokeUsesDeterministicFrames("nvim-scroll")
        && !nativeSmokeUsesDeterministicFrames("nvim-side-pane")
        && !nativeSmokeUsesDeterministicFrames("tmux-reattach-missing")
}

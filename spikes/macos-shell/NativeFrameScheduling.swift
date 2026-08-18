private let deterministicFrameSmokeScenarios: Set<String> = [
    "nvim-layout-redraw",
    "terminal-resize",
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
    ].allSatisfy(nativeSmokeUsesDeterministicFrames)
        && !nativeSmokeUsesDeterministicFrames(nil)
        && !nativeSmokeUsesDeterministicFrames("nvim-jump")
        && !nativeSmokeUsesDeterministicFrames("nvim-scroll")
        && !nativeSmokeUsesDeterministicFrames("nvim-side-pane")
        && !nativeSmokeUsesDeterministicFrames("tmux-reattach")
        && !nativeSmokeUsesDeterministicFrames("tmux-reattach-missing")
}

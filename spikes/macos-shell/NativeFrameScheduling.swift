private let deterministicFrameSmokeScenarios: Set<String> = [
    "nvim-jump",
    "nvim-layout-redraw",
    "nvim-scroll",
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
        "nvim-jump",
        "nvim-layout-redraw",
        "nvim-scroll",
        "tmux-reattach",
    ].allSatisfy(nativeSmokeUsesDeterministicFrames)
        && !nativeSmokeUsesDeterministicFrames(nil)
        && !nativeSmokeUsesDeterministicFrames("tmux-reattach-missing")
}

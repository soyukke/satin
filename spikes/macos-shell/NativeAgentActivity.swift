import Foundation

enum NativeAgentTitlePhase: Equatable {
    case other
    case running
    case waiting
}

enum NativeAgentKind: Equatable {
    case codex
    case claude
}

struct NativeAgentTitleTransition: Equatable {
    let status: String
    let summary: String
}

final class NativeAgentTitleTracker {
    private struct State {
        var phase = NativeAgentTitlePhase.other
        var ready = true
        var startupCandidate = false
        var agent: NativeAgentKind?
    }

    private var states: [Int: State] = [:]

    func beginSession(paneId: Int, agent: NativeAgentKind? = nil) {
        var state = State()
        state.ready = false
        state.agent = agent
        states[paneId] = state
    }

    func isClaudeSession(paneId: Int) -> Bool {
        states[paneId]?.agent == .claude
    }

    func update(
        paneId: Int,
        title: String
    ) -> NativeAgentTitleTransition? {
        var state = states[paneId] ?? State()
        let previous = state.phase
        let next = nativeAgentTitlePhase(title)
        if next == .running, !state.ready {
            state.phase = next
            state.startupCandidate = true
            states[paneId] = state
            return nil
        }
        if next == .waiting {
            state.ready = true
            state.startupCandidate = false
        }
        if next == .other, state.startupCandidate {
            state.phase = next
            state.ready = true
            state.startupCandidate = false
            states[paneId] = state
            return nil
        }
        state.phase = next
        states[paneId] = state
        guard previous != next else {
            return nil
        }
        switch next {
        case .running:
            return NativeAgentTitleTransition(
                status: "running",
                summary: "Agent working"
            )
        case .waiting:
            return NativeAgentTitleTransition(
                status: "waiting",
                summary: "Agent needs approval"
            )
        case .other where previous == .running || previous == .waiting:
            return NativeAgentTitleTransition(
                status: "done",
                summary: "Agent turn ended"
            )
        case .other:
            return nil
        }
    }

    func remove(paneId: Int) {
        states.removeValue(forKey: paneId)
    }
}

final class NativeTabTitleCoordinator {
    private var manuallyNamedTabIds: Set<Int> = []

    func markManual(tabId: Int) {
        manuallyNamedTabIds.insert(tabId)
    }

    func restore(tabId: Int, isManual: Bool) {
        if isManual {
            manuallyNamedTabIds.insert(tabId)
        } else {
            manuallyNamedTabIds.remove(tabId)
        }
    }

    func remove(tabId: Int) {
        manuallyNamedTabIds.remove(tabId)
    }

    func isManual(tabId: Int) -> Bool {
        manuallyNamedTabIds.contains(tabId)
    }

    func automaticTitle(
        tabId: Int,
        rawTitle: String,
        claudeSession: Bool
    ) -> String? {
        guard !isManual(tabId: tabId) else {
            return nil
        }
        return nativeAutomaticTabTitle(rawTitle, claudeSession: claudeSession)
    }
}

func nativeAutomaticTabTitle(_ rawTitle: String, claudeSession: Bool) -> String? {
    var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let waitingPrefix = "[ ! ] Action Required |"
    if title.hasPrefix(waitingPrefix) {
        title = String(title.dropFirst(waitingPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let first = title.unicodeScalars.first,
        (0x2800...0x28FF).contains(first.value) || first == "✳"
    {
        title = String(title.unicodeScalars.dropFirst())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !title.isEmpty else {
        return nil
    }
    if nativeClaudeVersionTitle(title) || claudeSession && nativeSemanticVersion(title) {
        return "Claude Code"
    }
    return title
}

private func nativeClaudeVersionTitle(_ title: String) -> Bool {
    let lowercased = title.lowercased()
    for prefix in ["claude code", "claude"] where lowercased.hasPrefix(prefix) {
        var suffix = String(title.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        suffix = suffix.trimmingCharacters(in: CharacterSet(charactersIn: ":-–—·()[]"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if suffix.first?.lowercased() == "v" {
            suffix.removeFirst()
        }
        return nativeSemanticVersion(suffix)
    }
    return false
}

private func nativeSemanticVersion(_ value: String) -> Bool {
    let withoutBuild =
        value.split(
            separator: "+", maxSplits: 1, omittingEmptySubsequences: false
        ).first ?? ""
    let core =
        withoutBuild.split(
            separator: "-", maxSplits: 1, omittingEmptySubsequences: false
        ).first ?? ""
    let components = core.split(separator: ".", omittingEmptySubsequences: false)
    return components.count >= 2
        && components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy(\.isNumber)
        }
}

private func nativeAgentTitlePhase(_ title: String) -> NativeAgentTitlePhase {
    if title.hasPrefix("[ ! ] Action Required |") {
        return .waiting
    }
    guard let first = title.unicodeScalars.first,
        (0x2800...0x28FF).contains(first.value),
        title.unicodeScalars.dropFirst().first.map(CharacterSet.whitespaces.contains) == true
    else {
        return .other
    }
    return .running
}

func runNativeAgentActivitySelfTests() -> Bool {
    let startup = NativeAgentTitleTracker()
    startup.beginSession(paneId: 9, agent: .codex)
    guard startup.update(paneId: 9, title: "satin") == nil,
        startup.update(paneId: 9, title: "⠹ satin") == nil,
        startup.update(paneId: 9, title: "satin") == nil,
        startup.update(paneId: 9, title: "⠹ satin")?.status == "running",
        startup.update(paneId: 9, title: "satin")?.status == "done"
    else {
        return false
    }

    let resumed = NativeAgentTitleTracker()
    guard resumed.update(paneId: 10, title: "satin") == nil,
        resumed.update(paneId: 10, title: "⠹ satin")?.status == "running",
        resumed.update(paneId: 10, title: "satin")?.status == "done"
    else {
        return false
    }

    startup.beginSession(paneId: 9, agent: .codex)
    guard startup.update(paneId: 9, title: "⠹ satin") == nil,
        startup.update(paneId: 9, title: "satin") == nil
    else {
        return false
    }

    let tracker = NativeAgentTitleTracker()
    guard tracker.update(paneId: 1, title: "satin") == nil,
        tracker.update(paneId: 1, title: "⠹ satin")?.status == "running",
        tracker.update(paneId: 1, title: "⠴ satin") == nil,
        tracker.update(
            paneId: 1,
            title: "[ ! ] Action Required | satin"
        )?.status == "waiting",
        tracker.update(paneId: 1, title: "satin")?.status == "done"
    else {
        return false
    }

    guard tracker.update(paneId: 2, title: "✳ Claude Code") == nil,
        tracker.update(paneId: 2, title: "⠂ Claude Code")?.status == "running",
        tracker.update(paneId: 2, title: "⠐ Claude Code") == nil,
        tracker.update(paneId: 2, title: "✳ Claude Code")?.status == "done"
    else {
        return false
    }

    tracker.remove(paneId: 2)
    let titlesReady =
        nativeAutomaticTabTitle("⠹ satin", claudeSession: false) == "satin"
        && nativeAutomaticTabTitle("✳ Claude Code", claudeSession: true) == "Claude Code"
        && nativeAutomaticTabTitle(
            "[ ! ] Action Required | satin", claudeSession: false) == "satin"
        && nativeAutomaticTabTitle("Claude Code v2.1.237", claudeSession: false)
            == "Claude Code"
        && nativeAutomaticTabTitle("Claude 2.1.237", claudeSession: false) == "Claude Code"
        && nativeAutomaticTabTitle("2.1.237", claudeSession: true) == "Claude Code"
        && nativeAutomaticTabTitle("2.1.237", claudeSession: false) == "2.1.237"
        && nativeAutomaticTabTitle("Claude Code · satin", claudeSession: true)
            == "Claude Code · satin"
    let tabTitles = NativeTabTitleCoordinator()
    let automaticBeforeRename =
        tabTitles.automaticTitle(
            tabId: 41,
            rawTitle: "⠹ satin",
            claudeSession: false
        ) == "satin"
    tabTitles.markManual(tabId: 41)
    let manualRenameProtected =
        tabTitles.automaticTitle(
            tabId: 41,
            rawTitle: "⠴ Claude Code v2.1.237",
            claudeSession: true
        ) == nil && tabTitles.isManual(tabId: 41)
    tabTitles.remove(tabId: 41)
    let automaticAfterRemoval =
        tabTitles.automaticTitle(
            tabId: 41,
            rawTitle: "⠹ satin",
            claudeSession: false
        ) == "satin"
    let separatedActivity = NativeAgentTitleTracker()
    let separatedTitles = NativeTabTitleCoordinator()
    _ = separatedActivity.update(paneId: 42, title: "renamed")
    separatedTitles.markManual(tabId: 42)
    let manualTitleKeepsActivity =
        separatedActivity.update(paneId: 42, title: "⠹ renamed")?.status == "running"
        && separatedTitles.automaticTitle(
            tabId: 42,
            rawTitle: "⠹ renamed",
            claudeSession: false
        ) == nil
    return tracker.update(paneId: 2, title: "✳ Claude Code") == nil
        && tracker.update(paneId: 3, title: "prefix ⠹ title") == nil
        && titlesReady
        && automaticBeforeRename
        && manualRenameProtected
        && automaticAfterRemoval
        && manualTitleKeepsActivity
}

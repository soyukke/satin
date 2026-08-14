import Foundation

enum NativeAgentTitlePhase: Equatable {
    case other
    case running
    case waiting
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
    }

    private var states: [Int: State] = [:]

    func beginSession(paneId: Int) {
        var state = State()
        state.ready = false
        states[paneId] = state
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
    startup.beginSession(paneId: 9)
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

    startup.beginSession(paneId: 9)
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
    return tracker.update(paneId: 2, title: "✳ Claude Code") == nil
        && tracker.update(paneId: 3, title: "prefix ⠹ title") == nil
}

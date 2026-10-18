import Foundation

/// What a pane's shell is doing, as its prompt marks tell: a command running,
/// or one that finished while nobody watched. A command that is over at once,
/// one that took the whole screen, as an editor does, or one interrupted is
/// left unmarked.
struct NativeShellCommandStatus: Equatable {
    enum Phase: Equatable {
        case running
        case finished(exitStatus: Int64)
    }

    let phase: Phase
    /// When the command started.
    let startedAt: Date
    /// Whether the user has seen it finish; only an unseen result is marked.
    var seen: Bool

    var failed: Bool {
        if case .finished(let exitStatus) = phase {
            return exitStatus != 0
        }
        return false
    }
}

/// A command that just finished, worth a flourish on its tab.
struct NativeShellCommandFinish: Equatable {
    let paneId: Int
    let failed: Bool
}

final class NativeShellCommandStore {
    /// A command shows as running once it has run this long.
    static let runningDelay: TimeInterval = 1
    /// A finished command is marked only when it ran at least this long.
    static let lingerThreshold: TimeInterval = 3

    private struct Counts: Equatable {
        var started: UInt64
        var finished: UInt64
    }

    private var counts: [Int: Counts] = [:]
    private var statuses: [Int: NativeShellCommandStatus] = [:]
    /// Panes whose running command took the whole screen.
    private var fullScreen = Set<Int>()

    func status(for paneId: Int) -> NativeShellCommandStatus? {
        statuses[paneId]
    }

    /// Reads a pane's mark counts. Returns the finish worth a flourish, if
    /// the command that ended now ran long enough to be one.
    func observe(
        paneId: Int, started: UInt64, finished: UInt64, lastExit: Int64,
        fullScreen screenTaken: Bool, visible: Bool, now: Date = Date()
    ) -> (changed: Bool, finish: NativeShellCommandFinish?) {
        let current = Counts(started: started, finished: finished)
        guard let previous = counts[paneId] else {
            counts[paneId] = current
            return (false, nil)
        }
        if screenTaken, statuses[paneId]?.phase == .running {
            fullScreen.insert(paneId)
        }
        guard previous != current else {
            return (false, nil)
        }
        counts[paneId] = current
        // A shell that started over counts from zero again.
        if started < previous.started || finished < previous.finished {
            return (statuses.removeValue(forKey: paneId) != nil, nil)
        }
        let before = statuses[paneId]
        let newStarts = started - previous.started
        let newFinishes = finished - previous.finished
        var finish: NativeShellCommandFinish?
        if newFinishes > 0 {
            let startedAt = before?.phase == .running ? before?.startedAt ?? now : now
            let lingered = now.timeIntervalSince(startedAt) >= Self.lingerThreshold
            let tookScreen = fullScreen.remove(paneId) != nil
            // Interrupting a command is the user's own doing, not news.
            if lingered, !tookScreen, lastExit != 130 {
                let status = NativeShellCommandStatus(
                    phase: .finished(exitStatus: lastExit), startedAt: startedAt, seen: visible)
                statuses[paneId] = status
                finish = NativeShellCommandFinish(paneId: paneId, failed: status.failed)
            } else {
                statuses.removeValue(forKey: paneId)
            }
        }
        // Counted by what changed, so a start whose finish was never
        // marked does not leave the pane running for good.
        if newStarts > newFinishes {
            statuses[paneId] = NativeShellCommandStatus(
                phase: .running, startedAt: now, seen: true)
            fullScreen.remove(paneId)
        }
        return (statuses[paneId] != before, finish)
    }

    /// The badge a pane's command earns now.
    func badge(for paneId: Int, now: Date = Date()) -> NativeTabStatusBadge? {
        guard let status = statuses[paneId] else {
            return nil
        }
        switch status.phase {
        case .running:
            let settled = now.timeIntervalSince(status.startedAt) >= Self.runningDelay
            return settled && !fullScreen.contains(paneId) ? .running : nil
        case .finished:
            if status.seen {
                return nil
            }
            return status.failed ? .failed : .done
        }
    }

    /// When a running command next earns its badge, if one is still to come.
    func nextBadgeChange(now: Date = Date()) -> Date? {
        statuses.values.compactMap { status -> Date? in
            guard status.phase == .running else {
                return nil
            }
            let due = status.startedAt.addingTimeInterval(Self.runningDelay)
            return due > now ? due : nil
        }.min()
    }

    @discardableResult
    func markSeen(paneId: Int) -> Bool {
        guard var status = statuses[paneId], !status.seen else {
            return false
        }
        status.seen = true
        statuses[paneId] = status
        return true
    }

    func remove(paneId: Int) {
        counts.removeValue(forKey: paneId)
        statuses.removeValue(forKey: paneId)
        fullScreen.remove(paneId)
    }
}

func runNativeShellCommandStatusSelfTests() -> Bool {
    let store = NativeShellCommandStore()
    let start = Date(timeIntervalSince1970: 1000)
    func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
    func observe(
        _ started: UInt64, _ finished: UInt64, exit: Int64 = 0, _ seconds: TimeInterval,
        visible: Bool = false, fullScreen: Bool = false
    ) -> NativeShellCommandFinish? {
        store.observe(
            paneId: 1, started: started, finished: finished, lastExit: exit,
            fullScreen: fullScreen, visible: visible, now: at(seconds)
        ).finish
    }
    // The first look only learns the counts.
    _ = observe(4, 4, 0)
    guard store.status(for: 1) == nil else { return false }

    // A quick command never shows.
    _ = observe(5, 4, 0)
    guard store.badge(for: 1, now: at(0.5)) == nil,
        store.nextBadgeChange(now: at(0.5)) == at(1),
        observe(5, 5, 0.6) == nil, store.status(for: 1) == nil
    else { return false }

    // A long one runs, then finishes unseen, and is marked until seen.
    _ = observe(6, 5, 10)
    guard store.badge(for: 1, now: at(11.5)) == .running,
        observe(6, 6, exit: 2, 20) == NativeShellCommandFinish(paneId: 1, failed: true),
        store.badge(for: 1, now: at(21)) == .failed,
        store.markSeen(paneId: 1), store.badge(for: 1, now: at(22)) == nil
    else { return false }

    // A finish watched happen still flourishes but leaves no mark.
    _ = observe(7, 6, 30)
    guard observe(7, 7, 40, visible: true) == NativeShellCommandFinish(paneId: 1, failed: false),
        store.badge(for: 1, now: at(41)) == nil
    else { return false }

    // An editor that took the screen is neither running nor finished.
    _ = observe(8, 7, 50)
    _ = observe(8, 7, 51, fullScreen: true)
    guard store.badge(for: 1, now: at(60)) == nil, observe(8, 8, 70) == nil,
        store.status(for: 1) == nil
    else { return false }

    // Ctrl-C is neither a failure nor news.
    _ = observe(9, 8, 80)
    guard observe(9, 9, exit: 130, 90) == nil, store.status(for: 1) == nil else { return false }

    // A start whose finish went unmarked does not keep the pane running.
    _ = observe(11, 9, 92)
    guard observe(11, 10, 95) != nil, store.badge(for: 1, now: at(96)) == .done else {
        return false
    }

    // A new shell counts from zero.
    _ = observe(1, 0, 100)
    return store.status(for: 1) == nil
}

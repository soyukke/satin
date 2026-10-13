import Foundation

/// A tab as the attention hand and Jump to Waiting Agent read it.
struct NativeAttentionTab: Equatable {
    let id: Int
    let index: Int
    let title: String
    let activePane: Int
    let panes: [Int]

    init(id: Int, index: Int, title: String, activePane: Int, panes: [Int]) {
        self.id = id
        self.index = index
        self.title = title
        self.activePane = activePane
        self.panes = panes
    }

    init(_ tab: TerminalCoreTabSnapshot) {
        self.init(
            id: tab.id,
            index: tab.index,
            title: tab.title,
            activePane: tab.active_pane,
            panes: tab.panes
        )
    }
}

struct NativeAttentionPane: Equatable {
    let tabId: Int
    let paneId: Int
    let since: Date
}

/// Picks the pane Jump to Waiting Agent focuses: the longest-waiting pane, or
/// the next one after the focused pane so repeated presses visit every pane.
func nativeNextAttentionPane(
    _ candidates: [NativeAttentionPane],
    activePaneId: Int?
) -> NativeAttentionPane? {
    let ordered = candidates.sorted {
        ($0.since, $0.paneId) < ($1.since, $1.paneId)
    }
    guard let current = ordered.firstIndex(where: { $0.paneId == activePaneId }) else {
        return ordered.first
    }
    return ordered[(current + 1) % ordered.count]
}

func nativeElapsedText(since: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(since)))
    let hours = seconds / 3600
    let minutes = seconds / 60 % 60
    let remainder = seconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
    return String(format: "%02d:%02d", minutes, remainder)
}

enum NativeHandCardKind: Int, Equatable {
    // Lower raw values are dealt first.
    case waiting = 0
    case failed = 1
    case done = 2

    init?(status: String, unread: Bool) {
        switch status {
        case "waiting": self = .waiting
        case "failed", "blocked": self = .failed
        case "done" where unread: self = .done
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .waiting: "WAITING"
        case .failed: "FAILED"
        case .done: "CLEAR"
        }
    }

    var glyph: String {
        switch self {
        case .waiting: "!"
        case .failed: "×"
        case .done: "✓"
        }
    }
}

/// One pane that needs the user, shown as a card.
struct NativeHandCard: Equatable {
    let tabId: Int
    let paneId: Int
    let title: String
    let kind: NativeHandCardKind
    let summary: String
    let since: Date
    /// The status revision the card was dealt for, so its art is read once.
    let revision: UInt64
}

/// The cards in reach, most urgent first, and how many more wait in the deck.
struct NativeAttentionHand: Equatable {
    static let limit = 5

    let cards: [NativeHandCard]
    let deckCount: Int
    /// Panes still at work. They are no cards, but the strip counts them.
    let runningCount: Int

    static let empty = NativeAttentionHand(cards: [], deckCount: 0, runningCount: 0)
}

/// Deals one card per pane that needs the user. The pane the user is looking
/// at is in play, not in the hand, so playing a card removes it.
func nativeAttentionHand(
    tabs: [NativeAttentionTab],
    status: (Int) -> NativePaneControlStatus?,
    isUnread: (Int) -> Bool,
    visiblePaneId: Int?
) -> NativeAttentionHand {
    let cards = tabs.flatMap { tab in
        tab.panes.compactMap { paneId -> NativeHandCard? in
            guard paneId != visiblePaneId,
                let paneStatus = status(paneId),
                let kind = NativeHandCardKind(
                    status: paneStatus.status, unread: isUnread(paneId))
            else {
                return nil
            }
            return NativeHandCard(
                tabId: tab.id,
                paneId: paneId,
                title: tab.title,
                kind: kind,
                summary: nativeWorkSingleLine(paneStatus.summary, limit: 120),
                since: paneStatus.updatedAt,
                revision: paneStatus.revision
            )
        }
    }.sorted {
        ($0.kind.rawValue, $0.since, $0.paneId) < ($1.kind.rawValue, $1.since, $1.paneId)
    }
    let running = tabs.reduce(0) { count, tab in
        count + tab.panes.filter { status($0)?.status == "running" }.count
    }
    return NativeAttentionHand(
        cards: Array(cards.prefix(NativeAttentionHand.limit)),
        deckCount: max(0, cards.count - NativeAttentionHand.limit),
        runningCount: running
    )
}

/// How long a card has waited, as the gauge on its lower edge reads it.
enum NativeHandWait {
    static let fullSeconds: TimeInterval = 180
    static let hotSeconds: TimeInterval = 120

    static func fraction(since: Date, now: Date) -> Double {
        min(1, max(0, now.timeIntervalSince(since) / fullSeconds))
    }

    static func isHot(since: Date, now: Date) -> Bool {
        now.timeIntervalSince(since) >= hotSeconds
    }
}

/// The cards played since the application started. Nothing is saved.
struct NativeHandRun: Equatable {
    static let comboWindow: TimeInterval = 8

    private(set) var played = 0
    private(set) var bestCombo = 0
    private var combo = 0
    private var lastPlay: Date?

    mutating func play(now: Date) {
        if let lastPlay, now.timeIntervalSince(lastPlay) < Self.comboWindow {
            combo += 1
        } else {
            combo = 1
        }
        lastPlay = now
        played += 1
        bestCombo = max(bestCombo, combo)
    }

    /// The running combo, or zero once the window since the last play closed.
    func combo(now: Date) -> Int {
        guard let lastPlay, now.timeIntervalSince(lastPlay) < Self.comboWindow else {
            return 0
        }
        return combo
    }
}

/// The last lines of a pane's screen, as the picture on its card.
func nativeHandArtLines(_ screenText: String, count: Int, width: Int) -> [String] {
    let lines = screenText.split(separator: "\n", omittingEmptySubsequences: false)
        .map { line in
            var text = String(line)
            while text.last?.isWhitespace == true {
                text.removeLast()
            }
            return text
        }
        .filter { !$0.isEmpty }
    return lines.suffix(count).map { String($0.prefix(width)) }
}

func runNativeAttentionHandSelfTests() -> Bool {
    let base = Date(timeIntervalSince1970: 1_000)
    func status(_ name: String, _ revision: UInt64, after seconds: TimeInterval)
        -> NativePaneControlStatus
    {
        NativePaneControlStatus(
            status: name, summary: " \(name)\n summary ", revision: revision,
            updatedAt: base.addingTimeInterval(seconds))
    }
    let statuses: [Int: NativePaneControlStatus] = [
        10: status("running", 1, after: 0),
        11: status("waiting", 2, after: 40),
        20: status("done", 3, after: 5),
        21: status("failed", 4, after: 90),
        30: status("waiting", 5, after: 10),
        31: status("done", 6, after: 0),
        32: status("blocked", 7, after: 20),
    ]
    let tabs = [
        NativeAttentionTab(id: 1, index: 0, title: "api", activePane: 10, panes: [10, 11]),
        NativeAttentionTab(id: 2, index: 1, title: "web", activePane: 20, panes: [20, 21]),
        NativeAttentionTab(id: 3, index: 2, title: "docs", activePane: 30, panes: [30, 31, 32]),
    ]
    let hand = nativeAttentionHand(
        tabs: tabs,
        status: { statuses[$0] },
        isUnread: { $0 == 20 },
        visiblePaneId: nil
    )
    // Waiting first, oldest first; then failures; a read completion is no card.
    guard hand.cards.map(\.paneId) == [30, 11, 32, 21, 20],
        hand.deckCount == 0,
        hand.runningCount == 1,
        hand.cards[0].title == "docs",
        hand.cards[0].summary == "waiting summary",
        hand.cards[2].kind == .failed,
        hand.cards[4].kind == .done
    else {
        return false
    }
    let inPlay = nativeAttentionHand(
        tabs: tabs,
        status: { statuses[$0] },
        isUnread: { _ in true },
        visiblePaneId: 30
    )
    guard inPlay.cards.map(\.paneId) == [11, 32, 21, 31, 20] else {
        return false
    }
    let crowded = nativeAttentionHand(
        tabs: [
            NativeAttentionTab(id: 1, index: 0, title: "all", activePane: 1, panes: Array(1...7))
        ],
        status: { status("waiting", UInt64($0), after: TimeInterval($0)) },
        isUnread: { _ in false },
        visiblePaneId: nil
    )
    guard crowded.cards.map(\.paneId) == [1, 2, 3, 4, 5], crowded.deckCount == 2 else {
        return false
    }

    guard NativeHandWait.fraction(since: base, now: base.addingTimeInterval(90)) == 0.5,
        NativeHandWait.fraction(since: base, now: base.addingTimeInterval(900)) == 1,
        NativeHandWait.fraction(since: base, now: base.addingTimeInterval(-5)) == 0,
        !NativeHandWait.isHot(since: base, now: base.addingTimeInterval(119)),
        NativeHandWait.isHot(since: base, now: base.addingTimeInterval(120))
    else {
        return false
    }

    let attention = [
        NativeAttentionPane(tabId: 2, paneId: 21, since: base.addingTimeInterval(30)),
        NativeAttentionPane(tabId: 1, paneId: 11, since: base),
        NativeAttentionPane(tabId: 3, paneId: 31, since: base.addingTimeInterval(60)),
    ]
    guard nativeNextAttentionPane(attention, activePaneId: nil)?.paneId == 11,
        nativeNextAttentionPane(attention, activePaneId: 99)?.paneId == 11,
        nativeNextAttentionPane(attention, activePaneId: 11)?.paneId == 21,
        nativeNextAttentionPane(attention, activePaneId: 31)?.paneId == 11,
        nativeNextAttentionPane(Array(attention.prefix(1)), activePaneId: 21)?.paneId == 21,
        nativeNextAttentionPane([], activePaneId: 11) == nil,
        nativeElapsedText(since: base, now: base.addingTimeInterval(401)) == "06:41",
        nativeElapsedText(since: base, now: base.addingTimeInterval(3_725)) == "1:02:05",
        nativeElapsedText(since: base, now: base.addingTimeInterval(-5)) == "00:00"
    else {
        return false
    }

    var run = NativeHandRun()
    run.play(now: base)
    run.play(now: base.addingTimeInterval(3))
    run.play(now: base.addingTimeInterval(6))
    guard run.combo(now: base.addingTimeInterval(7)) == 3,
        run.combo(now: base.addingTimeInterval(20)) == 0
    else {
        return false
    }
    run.play(now: base.addingTimeInterval(30))
    guard run.played == 4, run.bestCombo == 3, run.combo(now: base.addingTimeInterval(31)) == 1
    else {
        return false
    }

    return nativeHandArtLines("one  \n\n  two\nthree is long\n   \n", count: 2, width: 8)
        == ["  two", "three is"]
}

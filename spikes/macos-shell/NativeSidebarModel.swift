import AppKit

/// How a sidebar sits beside the panes: open with its cards, folded to a
/// rail, or gone.
enum NativeSidebarMode: String {
    case open
    case rail
    case off
}

/// What a tab is doing, as its card in the windows sidebar shows it. Higher
/// raw values want the user more.
enum NativeWindowState: Int, Equatable {
    case idle = 0
    case running = 1
    case clear = 2
    case failed = 3
    case waiting = 4

    init(badge: NativeTabStatusBadge?) {
        switch badge {
        case .waiting: self = .waiting
        case .failed: self = .failed
        case .done: self = .clear
        case .running: self = .running
        case nil: self = .idle
        }
    }

    var title: String {
        switch self {
        case .waiting: "WAITING"
        case .failed: "FAILED"
        case .clear: "CLEAR"
        case .running: "RUNNING"
        case .idle: "IDLE"
        }
    }

    var glyph: String {
        switch self {
        case .waiting: "!"
        case .failed: "×"
        case .clear: "✓"
        case .running: "›"
        case .idle: "·"
        }
    }

    /// The card kind of the hand the state shares its color with.
    var handKind: NativeHandCardKind? {
        switch self {
        case .waiting: .waiting
        case .failed: .failed
        case .clear: .done
        case .running, .idle: nil
        }
    }
}

/// One tab as a card in the windows sidebar.
/// The headings the windows sidebar sorts its cards under, most urgent
/// first.
enum NativeWindowGroup: Int, CaseIterable, Equatable {
    case needsYou
    case running
    case done
    case idle

    init(_ state: NativeWindowState) {
        switch state {
        case .waiting, .failed: self = .needsYou
        case .running: self = .running
        case .clear: self = .done
        case .idle: self = .idle
        }
    }

    var title: String {
        switch self {
        case .needsYou: "NEEDS YOU"
        case .running: "RUNNING"
        case .done: "DONE"
        case .idle: "IDLE"
        }
    }
}

/// The rows under their headings, leaving out empty ones. What needs you
/// reads as the hand deals it: waiting before failed, the longest first;
/// the rest keep their tabs' order.
func nativeWindowGroups(_ rows: [NativeWindowRow]) -> [(NativeWindowGroup, [NativeWindowRow])] {
    NativeWindowGroup.allCases.compactMap { group in
        var members = rows.filter { NativeWindowGroup($0.state) == group }
        if group == .needsYou {
            members.sort {
                ($0.state == .waiting ? 0 : 1, $0.since ?? .distantFuture, $0.index)
                    < ($1.state == .waiting ? 0 : 1, $1.since ?? .distantFuture, $1.index)
            }
        }
        return members.isEmpty ? nil : (group, members)
    }
}

struct NativeWindowRow: Equatable {
    let tabId: Int
    let index: Int
    let title: String
    let state: NativeWindowState
    /// The line printed under the title: what the agent said, or the last
    /// line on the tab's screen.
    let line: String
    /// When the state began, for the clock and the gauge.
    let since: Date?
    let isCurrent: Bool
    /// Whether ⌘J plays this tab's card next.
    let isNext: Bool
    /// The digit that goes with ⌘ to select this tab, if one does.
    var shortcut: Int? = nil
}

/// The digit that goes with ⌘ to select a tab, as the menu has them: ⌘1 to
/// ⌘8 by the tab's place, and ⌘9 for the last tab however many there are.
func nativeTabShortcut(index: Int, count: Int) -> Int? {
    if index < 8 {
        return index + 1
    }
    return index == count - 1 ? 9 : nil
}

/// Deals one card per tab. A tab's state is the most urgent of its panes',
/// and the pane that set it says what the card prints.
func nativeWindowRows(
    tabs: [NativeAttentionTab],
    activeTabIndex: Int,
    status: (Int) -> NativePaneControlStatus?,
    isUnread: (Int) -> Bool,
    shellBadge: (Int) -> NativeTabStatusBadge?,
    screenLine: (Int) -> String?,
    nextPaneId: Int?
) -> [NativeWindowRow] {
    tabs.sorted { $0.index < $1.index }.map { tab in
        var best: (badge: NativeTabStatusBadge, paneId: Int, since: Date?)?
        for paneId in tab.panes {
            let paneStatus = status(paneId)
            let agent = paneStatus.flatMap { paneStatus in
                nativeTabStatusBadge(for: [(paneStatus.status, isUnread(paneId))])
            }
            let candidates: [(NativeTabStatusBadge, Date?)] = [
                agent.map { ($0, paneStatus?.updatedAt) },
                shellBadge(paneId).map { ($0, nil) },
            ].compactMap { $0 }
            for (badge, since) in candidates {
                guard let current = best else {
                    best = (badge, paneId, since)
                    continue
                }
                let older = (since ?? .distantFuture) < (current.since ?? .distantFuture)
                if badge.rawValue > current.badge.rawValue
                    || (badge == current.badge && older)
                {
                    best = (badge, paneId, since)
                }
            }
        }
        let state = NativeWindowState(badge: best?.badge)
        let summary = best.flatMap { best in
            status(best.paneId).map { nativeWorkSingleLine($0.summary, limit: 120) }
        }
        let line =
            summary.flatMap { $0.isEmpty ? nil : $0 }
            ?? screenLine(best?.paneId ?? tab.activePane) ?? ""
        return NativeWindowRow(
            tabId: tab.id,
            index: tab.index,
            title: tab.title,
            state: state,
            line: line,
            since: state == .idle ? nil : best?.since,
            isCurrent: tab.index == activeTabIndex,
            isNext: nextPaneId.map { tab.panes.contains($0) } ?? false,
            shortcut: nativeTabShortcut(index: tab.index, count: tabs.count)
        )
    }
}

/// What the items sidebar gathers from a pane's screen.
enum NativeSidebarItemKind: Int, CaseIterable, Equatable {
    case command
    case quote
    case link
    case file

    var glyph: String {
        switch self {
        case .command: "!"
        case .quote: ">"
        case .link: "↗"
        case .file: "±"
        }
    }
}

/// One thing worth copying, already cleaned: a command without its `!` or
/// `$`, a quote without its `>` and joined into a paragraph.
struct NativeSidebarItem: Equatable {
    let kind: NativeSidebarItemKind
    /// What a click copies.
    let text: String
    /// A word on where it came from: "edited", "line 88", "3 lines".
    let detail: String
}

private enum NativeSidebarPatterns {
    static let url = regex(#"https?://[^\s<>"'`│┃]+"#)
    static let codeCommand = regex(#"`[!$] ([^`]+)`"#)
    /// A tool call's header, `● Update(path)`, with the tool's name and
    /// what it was given.
    static let toolHeader = regex(#"^\s*[●⏺] ([A-Z][A-Za-z]*)\(([^)]*)"#)
    static let editingTools: Set<String> = ["Update", "Edit", "MultiEdit", "Write", "Create"]
    static let fileLine = regex(
        #"(?<![\w/.~-])((?:~|\.{1,2})?/?[\w.-]+(?:/[\w.-]+)*\.[A-Za-z][A-Za-z0-9]{0,7}):(\d+)(?::\d+)?(?![\w/])"#
    )
    /// A path on its own, such as where a screenshot was saved: it needs a
    /// slash, so a bare `design.md` in prose stays out.
    static let path = regex(
        #"(?<![\w/.~:-])(?:~|\.{1,2})?/?[\w.-]+(?:/[\w.-]+)*\.[A-Za-z][A-Za-z0-9]{0,7}(?!\.?[\w/:-])"#
    )

    /// A path's end once its extension is there.
    static let extensionEnd = regex(#"\.[A-Za-z][A-Za-z0-9]{0,7}$"#)

    /// The patterns are constants; a typo in one fails the self-test.
    static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }
}

private func nativeSidebarMatches(_ regex: NSRegularExpression?, in text: String)
    -> [NSTextCheckingResult]
{
    regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
}

/// A screen line with the frame an agent's box draws around it taken off,
/// and whether there was one.
func nativeSidebarCleanLine(_ raw: String) -> (text: String, boxed: Bool) {
    var text = raw
    while text.last?.isWhitespace == true {
        text.removeLast()
    }
    var boxed = false
    let borders: Set<Character> = ["│", "┃"]
    let leading = text.drop { $0 == " " }
    if let first = leading.first, borders.contains(first) {
        text = String(leading.dropFirst())
        if text.first == " " {
            text.removeFirst()
        }
        boxed = true
        if let last = text.last, borders.contains(last) {
            text.removeLast()
        }
        while text.last?.isWhitespace == true {
            text.removeLast()
        }
    }
    var trimmed = text.drop { $0 == " " }
    if trimmed.first == "⎿" {
        trimmed = trimmed.dropFirst().drop { $0 == " " }
        text = String(trimmed)
    }
    return (text, boxed)
}

/// How long a window has been in its state, to the minute: a card's age
/// should not tick.
func nativeSidebarAgeText(since: Date, now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(since))) / 60
    switch minutes {
    case 0: return "now"
    case ..<60: return "\(minutes)m"
    case ..<1_440: return "\(minutes / 60)h"
    default: return "\(minutes / 1_440)d"
    }
}

/// How many cells a row takes: CJK text and emoji take two each.
func nativeSidebarCells(_ text: some StringProtocol) -> Int {
    let wide: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
        0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
        0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD,
    ]
    return text.reduce(0) { cells, character in
        let value = character.unicodeScalars.first?.value ?? 0
        return cells + (wide.contains { $0.contains(value) } ? 2 : 1)
    }
}

/// Whether `row` ends inside a path that goes on in `next`. An agent wraps
/// its own lines a few cells short of the pane's width, and breaks a path
/// too long for one row wherever the row ends. So the row has to reach
/// that far, end in a piece of a path that has no extension yet, and be
/// followed by more of one. A link is left alone: the words after it
/// would join it as easily as its own end.
func nativeSidebarBreaksPath(_ row: String, next: String, columns: Int) -> Bool {
    func inPath(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "/._~-".contains(character)
    }
    let cells = nativeSidebarCells(row)
    guard columns > 0, cells < columns, cells >= columns - 8 else {
        return false
    }
    let content = row.drop { $0 == " " }
    let piece = String(content.reversed().prefix(while: inPath).reversed())
    guard piece.contains("/"), content.dropLast(piece.count).last != ":",
        let head = next.first(where: { $0 != " " }), inPath(head)
    else {
        return false
    }
    return nativeSidebarMatches(NativeSidebarPatterns.extensionEnd, in: piece).isEmpty
}

/// The screen's rows with each wrapped row joined to the next. A row the
/// terminal wrapped is as wide as the pane and goes on below, unless a
/// box edge or rule fills it; wide characters keep such a row short of the
/// count, so those stay apart. A path an agent broke where its own, shorter
/// line ended is joined too, without the next row's indent.
func nativeSidebarUnwrap(_ screen: String, columns: Int) -> [String] {
    func boxDrawing(_ character: Character?) -> Bool {
        character?.unicodeScalars.first.map { (0x2500...0x257F).contains($0.value) } == true
    }
    var lines: [String] = []
    var previous: String?
    for raw in screen.split(separator: "\n", omittingEmptySubsequences: false) {
        let row = String(raw)
        let wrapped =
            previous.map { columns > 0 && $0.count >= columns && !boxDrawing($0.last) } == true
        if wrapped, !boxDrawing(row.first), let last = lines.popLast() {
            lines.append(last + row)
        } else if let previous, let last = lines.last,
            nativeSidebarBreaksPath(previous, next: row, columns: columns)
        {
            lines[lines.count - 1] = last + row.drop { $0 == " " }
        } else {
            lines.append(row)
        }
        previous = row
    }
    return lines
}

/// Finds what a screen offers to copy, in the order it reads. With the
/// pane's columns, a line the terminal wrapped reads whole.
func nativeSidebarItems(screen: String, columns: Int = 0) -> [NativeSidebarItem] {
    var items: [NativeSidebarItem] = []
    var seen = Set<String>()
    func add(_ kind: NativeSidebarItemKind, _ text: String, _ detail: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 400,
            seen.insert("\(kind.rawValue)\u{0}\(text)").inserted
        else {
            return
        }
        items.append(NativeSidebarItem(kind: kind, text: text, detail: detail))
    }

    var quote: [String] = []
    func flushQuote() {
        defer { quote.removeAll() }
        let body = quote.joined(separator: " ")
            .replacingOccurrences(of: " \n\n ", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let count = quote.filter { $0 != "\n\n" }.count
        add(.quote, body, count == 1 ? "1 line" : "\(count) lines")
    }

    // An agent's tool calls are not offered: what it ran and read sits
    // under a `⎿` and the lines indented below it, and a call's header
    // reads `● Name(…)`. Only the files a call edited come from those.
    var inToolOutput = false
    for raw in nativeSidebarUnwrap(screen, columns: columns) {
        let (line, boxed) = nativeSidebarCleanLine(raw)
        let body = line.drop { $0 == " " }
        let indent = raw.prefix { $0 == " " }.count
        if raw.dropFirst(indent).first == "⎿" {
            inToolOutput = true
        } else if !body.isEmpty, indent < 4 {
            inToolOutput = false
        }
        let header = nativeSidebarMatches(NativeSidebarPatterns.toolHeader, in: line).first
        if inToolOutput || header != nil, !quote.isEmpty {
            flushQuote()
        }
        if inToolOutput {
            for match in nativeSidebarMatches(NativeSidebarPatterns.url, in: line) {
                if let found = Range(match.range, in: line) {
                    let url = nativeSidebarTrimURL(String(line[found]))
                    add(.link, url, URL(string: url)?.host ?? "link")
                }
            }
            continue
        }
        if let header {
            if let action = Range(header.range(at: 1), in: line),
                let path = Range(header.range(at: 2), in: line),
                NativeSidebarPatterns.editingTools.contains(String(line[action]))
            {
                add(.file, String(line[path]), "edited")
            }
            continue
        }

        if !boxed, body.first == ">", body.count == 1 || body.dropFirst().first == " " {
            let content = body.dropFirst().trimmingCharacters(in: .whitespaces)
            quote.append(content.isEmpty ? "\n\n" : content)
            continue
        }
        if !quote.isEmpty {
            flushQuote()
        }

        if let mark = body.first, mark == "!" || mark == "$", body.dropFirst().first == " " {
            add(.command, String(body.dropFirst(2)), mark == "!" ? "run it" : "command")
        }
        for match in nativeSidebarMatches(NativeSidebarPatterns.codeCommand, in: line) {
            if let command = Range(match.range(at: 1), in: line) {
                add(.command, String(line[command]), "run it")
            }
        }

        var rest = line
        for match in nativeSidebarMatches(NativeSidebarPatterns.url, in: line).reversed() {
            guard let found = Range(match.range, in: line) else {
                continue
            }
            let url = nativeSidebarTrimURL(String(line[found]))
            add(.link, url, URL(string: url)?.host ?? "link")
            rest.replaceSubrange(found, with: " ")
        }
        for match in nativeSidebarMatches(NativeSidebarPatterns.fileLine, in: rest) {
            guard let whole = Range(match.range, in: rest),
                let number = Range(match.range(at: 2), in: rest)
            else {
                continue
            }
            add(.file, String(rest[whole]), "line \(rest[number])")
        }
        for match in nativeSidebarMatches(NativeSidebarPatterns.path, in: rest) {
            guard let whole = Range(match.range, in: rest), rest[whole].contains("/") else {
                continue
            }
            add(.file, String(rest[whole]), "path")
        }
    }
    if !quote.isEmpty {
        flushQuote()
    }
    return items
}

/// A URL without the punctuation that ends the sentence around it.
func nativeSidebarTrimURL(_ url: String) -> String {
    var url = url
    while let last = url.last {
        if ".,;:!?'\"]}".contains(last) {
            url.removeLast()
        } else if last == ")", url.filter({ $0 == "(" }).count < url.filter({ $0 == ")" }).count {
            url.removeLast()
        } else {
            break
        }
    }
    return url
}

/// The items every pane has shown, kept after they scroll away. Each pane
/// keeps its newest, a few dozen of each kind.
final class NativeSidebarItemStore {
    struct Entry: Equatable {
        let item: NativeSidebarItem
        let paneId: Int
        /// Rises with every item found, so later lines read as newer.
        let order: Int
    }

    static let perKind = 30

    private var entries: [Int: [Entry]] = [:]
    private var screens: [Int: Int] = [:]
    private var counter = 0

    /// Reads a pane's screen; returns whether anything new turned up.
    @discardableResult
    func scan(paneId: Int, screen: String, columns: Int = 0) -> Bool {
        let hash = screen.hashValue
        guard screens[paneId] != hash else {
            return false
        }
        screens[paneId] = hash
        var known = entries[paneId] ?? []
        var changed = false
        for item in nativeSidebarItems(screen: screen, columns: columns)
        where !known.contains(where: { $0.item == item }) {
            counter += 1
            known.append(Entry(item: item, paneId: paneId, order: counter))
            changed = true
        }
        guard changed else {
            return false
        }
        var kept: [Entry] = []
        for kind in NativeSidebarItemKind.allCases {
            kept += known.filter { $0.item.kind == kind }
                .sorted { $0.order > $1.order }
                .prefix(Self.perKind)
        }
        entries[paneId] = kept
        return true
    }

    /// The items of the given panes, or of every pane, newest first.
    func items(panes: Set<Int>?) -> [NativeSidebarItemKind: [Entry]] {
        var result: [NativeSidebarItemKind: [Entry]] = [:]
        var seen = Set<String>()
        let all = entries.filter { panes?.contains($0.key) ?? true }.values.flatMap { $0 }
        for entry in all.sorted(by: { $0.order > $1.order }) {
            let key = "\(entry.item.kind.rawValue)\u{0}\(entry.item.text)"
            guard seen.insert(key).inserted else {
                continue
            }
            result[entry.item.kind, default: []].append(entry)
        }
        return result
    }

    /// The panes that showed an item, the latest first: a relative path
    /// reads against one of their folders.
    func panes(showing item: NativeSidebarItem) -> [Int] {
        entries.values.flatMap { $0 }.filter { $0.item == item }
            .sorted { $0.order > $1.order }.map(\.paneId)
    }

    /// Lets go of panes that closed.
    func keep(panes: Set<Int>) {
        entries = entries.filter { panes.contains($0.key) }
        screens = screens.filter { panes.contains($0.key) }
    }
}

/// Whether ⌘ is held with no other modifier, as a tab's shortcut is pressed.
func nativeHoldsOnlyCommand(_ flags: NSEvent.ModifierFlags) -> Bool {
    flags.intersection([.command, .shift, .option, .control]) == .command
}

func runNativeSidebarModelSelfTests() -> Bool {
    let screen = """
        ● I added the sidebar. To see it with a page, run:

          ! satin page put design.md --name "Sidebar design"

          Or type `! gcloud auth login` in the prompt.
          The pull request is at https://github.com/example/satin/pull/207.
          (see https://en.wikipedia.org/wiki/Card_(game))

        > Windows sit on the left, sorted by what needs you.
        > What each window made sits on the right.
        >
        > A second paragraph.

        ● Update(spikes/macos-shell/TerminalShellTabs.swift)
          ⎿  Added 42 lines
        ● Read(core/src/tmux/control.kizu)
        ● Bash(cat ./scripts/run.sh | grep users)
          ⎿  $ cp notes/a.txt ./out/visits.txt
             ! not a command for the user
             see ./out/visits.txt:3 and https://github.com/example/satin/pull/9
        ● Bash(git log --oneline -- ./scripts/run.s…
        error at TerminalShellTabs.swift:88:4 and ./scripts/build.sh:12
        Saved the shot to ~/Desktop/shot.png. See design.md and 1.5/2.0 too.
        $ just fmt && just precommit
        ╭──────────────────────────────╮
        │ > what the user is typing     │
        │ ! kizu test cli               │
        ╰──────────────────────────────╯
        at 12:30 the build ran
        """
    let items = nativeSidebarItems(screen: screen)
    let expected: [NativeSidebarItem] = [
        .init(
            kind: .command, text: "satin page put design.md --name \"Sidebar design\"",
            detail: "run it"),
        .init(kind: .command, text: "gcloud auth login", detail: "run it"),
        .init(
            kind: .link, text: "https://github.com/example/satin/pull/207",
            detail: "github.com"),
        .init(
            kind: .link, text: "https://en.wikipedia.org/wiki/Card_(game)",
            detail: "en.wikipedia.org"),
        .init(
            kind: .quote,
            text: "Windows sit on the left, sorted by what needs you. "
                + "What each window made sits on the right.\n\nA second paragraph.",
            detail: "3 lines"),
        .init(
            kind: .file, text: "spikes/macos-shell/TerminalShellTabs.swift", detail: "edited"),
        .init(
            kind: .link, text: "https://github.com/example/satin/pull/9", detail: "github.com"),
        .init(kind: .file, text: "TerminalShellTabs.swift:88:4", detail: "line 88"),
        .init(kind: .file, text: "./scripts/build.sh:12", detail: "line 12"),
        .init(kind: .file, text: "~/Desktop/shot.png", detail: "path"),
        .init(kind: .command, text: "just fmt && just precommit", detail: "command"),
        .init(kind: .command, text: "kizu test cli", detail: "run it"),
    ]
    guard items == expected else {
        return false
    }
    guard nativeSidebarTrimURL("https://a.dev/x).") == "https://a.dev/x",
        nativeSidebarCleanLine("  │ ! ls │  ") == ("! ls", true),
        nativeSidebarCleanLine("  ⎿  done") == ("done", false)
    else {
        return false
    }
    let wrapped = "> Count visits per\n user.\nsee https://a.dev/doc\ns/visits\n╭────╮\n│ hi │"
    guard
        nativeSidebarItems(screen: wrapped, columns: 18) == [
            .init(kind: .quote, text: "Count visits per user.", detail: "1 line"),
            .init(kind: .link, text: "https://a.dev/docs/visits", detail: "a.dev"),
        ],
        nativeSidebarUnwrap("──────\nnext\nabcdef\n│ x", columns: 6)
            == ["──────", "next", "abcdef", "│ x"],
        nativeSidebarUnwrap("abc\ndef", columns: 0) == ["abc", "def"],
        // An agent's own wrap, short of the pane's 40 columns: a path alone
        // on its rows, one after a bullet, and one with wide characters.
        nativeSidebarUnwrap("/tmp/visits/2026-11/users/alice-0\n1/report.png\nnext", columns: 40)
            == ["/tmp/visits/2026-11/users/alice-01/report.png", "next"],
        nativeSidebarItems(
            screen: "  - saved to ~/visits/2026-11/users/al\n    ice/report.png now", columns: 40)
            == [
                .init(kind: .file, text: "~/visits/2026-11/users/alice/report.png", detail: "path")
            ],
        nativeSidebarUnwrap("/tmp/訪問記録/2026-11/users/alice-0\n1/集計.png", columns: 40)
            == ["/tmp/訪問記録/2026-11/users/alice-01/集計.png"],
        // A whole path, a link, a short row and prose are not joined on.
        nativeSidebarUnwrap("/tmp/visits/2026-11/users/alice.png\n/tmp/b.png", columns: 40)
            == ["/tmp/visits/2026-11/users/alice.png", "/tmp/b.png"],
        nativeSidebarUnwrap("see https://a.dev/docs/visits/users\nfor more", columns: 40)
            == ["see https://a.dev/docs/visits/users", "for more"],
        nativeSidebarUnwrap("in /tmp/visits\nalice", columns: 40) == ["in /tmp/visits", "alice"],
        nativeSidebarUnwrap("alice counted the visits and slept\nwell", columns: 40)
            == ["alice counted the visits and slept", "well"],
        nativeSidebarAgeText(
            since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 59))
            == "now",
        nativeSidebarAgeText(
            since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 245))
            == "4m",
        nativeSidebarAgeText(
            since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 7_300))
            == "2h",
        nativeSidebarAgeText(
            since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 90_000))
            == "1d"
    else {
        return false
    }

    let store = NativeSidebarItemStore()
    guard store.scan(paneId: 1, screen: "$ make\n"),
        !store.scan(paneId: 1, screen: "$ make\n"),
        store.scan(paneId: 1, screen: "$ make\n$ make test\n"),
        store.scan(paneId: 2, screen: "https://b.dev\n$ make\n")
    else {
        return false
    }
    let all = store.items(panes: nil)
    let one = store.items(panes: [1])
    guard all[.command]?.map(\.item.text) == ["make", "make test"],
        all[.command]?.first?.paneId == 2,
        all[.link]?.map(\.item.text) == ["https://b.dev"],
        one[.command]?.map(\.item.text) == ["make test", "make"],
        one[.link] == nil,
        store.panes(showing: .init(kind: .command, text: "make", detail: "command")) == [2, 1]
    else {
        return false
    }
    let press = { (kind: NativeSidebarItemKind, x: CGFloat, option: Bool) in
        NativeItemRowView.action(kind: kind, x: x, width: 276, option: option)
    }
    guard press(.file, 40, false) == .open, press(.link, 200, false) == .open,
        press(.file, 260, false) == .copy, press(.link, 40, true) == .paste,
        press(.command, 40, false) == .copy, press(.quote, 260, true) == .paste
    else {
        return false
    }
    store.keep(panes: [2])
    guard store.items(panes: nil)[.command]?.map(\.item.text) == ["make"] else {
        return false
    }

    let base = Date(timeIntervalSince1970: 1_000)
    let statuses: [Int: NativePaneControlStatus] = [
        11: NativePaneControlStatus(
            status: "waiting", summary: "Wants to edit\n a file", revision: 1, updatedAt: base),
        21: NativePaneControlStatus(
            status: "running", summary: "", revision: 2, updatedAt: base),
        22: NativePaneControlStatus(
            status: "failed", summary: "", revision: 3, updatedAt: base.addingTimeInterval(5)),
    ]
    let tabs = [
        NativeAttentionTab(id: 7, index: 1, title: "web", activePane: 21, panes: [21, 22]),
        NativeAttentionTab(id: 5, index: 0, title: "api", activePane: 10, panes: [10, 11]),
        NativeAttentionTab(id: 9, index: 2, title: "logs", activePane: 30, panes: [30]),
    ]
    let rows = nativeWindowRows(
        tabs: tabs,
        activeTabIndex: 1,
        status: { statuses[$0] },
        isUnread: { _ in false },
        shellBadge: { $0 == 30 ? .running : nil },
        screenLine: { "screen of \($0)" },
        nextPaneId: 11
    )
    let earlier = NativeWindowRow(
        tabId: 3, index: 3, title: "worker", state: .waiting, line: "",
        since: base.addingTimeInterval(-10), isCurrent: false, isNext: false)
    let groups = nativeWindowGroups(rows + [earlier])
    guard groups.map(\.0) == [.needsYou, .running],
        groups[0].1.map(\.title) == ["worker", "api", "web"],
        groups[1].1.map(\.title) == ["logs"]
    else {
        return false
    }
    guard nativeTabShortcut(index: 0, count: 3) == 1,
        nativeTabShortcut(index: 7, count: 12) == 8,
        nativeTabShortcut(index: 8, count: 9) == 9,
        nativeTabShortcut(index: 8, count: 12) == nil,
        nativeTabShortcut(index: 11, count: 12) == 9,
        rows.map(\.shortcut) == [1, 2, 3],
        nativeHoldsOnlyCommand([.command, .capsLock]),
        !nativeHoldsOnlyCommand([.command, .shift]),
        !nativeHoldsOnlyCommand([])
    else {
        return false
    }
    return rows.map(\.title) == ["api", "web", "logs"]
        && rows.map(\.state) == [.waiting, .failed, .running]
        && rows[0].line == "Wants to edit a file"
        && rows[0].since == base
        && rows[0].isNext && !rows[1].isNext
        && rows[1].line == "screen of 22"
        && rows[1].isCurrent
        && rows[2].line == "screen of 30"
        && rows[2].since == nil
        && NativeWindowState(badge: nil) == .idle
}

import AppKit
import Foundation

struct NativePartyTab: Equatable {
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

/// One party frame per tab. The frame targets the pane whose agent state wins the
/// tab badge, so selecting it focuses the agent pane instead of the tab's last pane.
struct NativePartyMember: Equatable {
    let tabId: Int
    let tabIndex: Int
    let title: String
    let badge: NativeTabStatusBadge?
    let summary: String
    let statusSince: Date?
    let targetPaneId: Int
    let active: Bool

    var statusTitle: String {
        switch badge {
        case .running: "RUNNING"
        case .waiting: "WAITING"
        case .failed: "FAILED"
        case .done: "CLEAR"
        case nil: "IDLE"
        }
    }

    var initials: String {
        let letters = title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let prefix = String(String.UnicodeScalarView(letters.prefix(2)))
        return prefix.isEmpty ? "?" : prefix.uppercased()
    }

    var showsElapsedTime: Bool {
        badge == .running || badge == .waiting
    }
}

func nativePartyMembers(
    tabs: [NativePartyTab],
    activeTabIndex: Int,
    status: (Int) -> NativePaneControlStatus?,
    isUnread: (Int) -> Bool
) -> [NativePartyMember] {
    tabs.map { tab in
        var target: (paneId: Int, badge: NativeTabStatusBadge)?
        for paneId in tab.panes {
            guard let paneStatus = status(paneId),
                let badge = nativeTabStatusBadge(
                    for: [(status: paneStatus.status, unread: isUnread(paneId))]
                )
            else {
                continue
            }
            if target.map({ badge.rawValue > $0.badge.rawValue }) ?? true {
                target = (paneId, badge)
            }
        }
        let targetPaneId = target?.paneId ?? tab.activePane
        let targetStatus = status(targetPaneId)
        return NativePartyMember(
            tabId: tab.id,
            tabIndex: tab.index,
            title: tab.title,
            badge: target?.badge,
            summary: nativeWorkSingleLine(targetStatus?.summary ?? "", limit: 120),
            statusSince: target == nil ? nil : targetStatus?.updatedAt,
            targetPaneId: targetPaneId,
            active: tab.index == activeTabIndex
        )
    }
}

func nativePartyElapsedText(since: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(since)))
    let hours = seconds / 3600
    let minutes = seconds / 60 % 60
    let remainder = seconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
    return String(format: "%02d:%02d", minutes, remainder)
}

private func nativePartyStatusColor(_ badge: NativeTabStatusBadge?) -> NSColor {
    switch badge {
    case .running: .systemTeal
    case .waiting: .systemOrange
    case .failed: .systemRed
    case .done: .systemGreen
    case nil: .tertiaryLabelColor
    }
}

final class NativePartyFramesView: NSView {
    static let width: CGFloat = 232

    var onSelect: ((NativePartyMember) -> Void)?

    private let backgroundView = NSVisualEffectView(frame: .zero)
    private let separator = NSBox(frame: .zero)
    private let headerLabel = NSTextField(labelWithString: "PARTY")
    private let countLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView(frame: .zero)
    private var frameViews: [NativePartyFrameView] = []
    private var refreshTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isHidden: Bool {
        didSet {
            updateRefreshTimer()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRefreshTimer()
    }

    func update(_ members: [NativePartyMember]) {
        while frameViews.count < members.count {
            let frameView = NativePartyFrameView(frame: .zero)
            frameView.onSelect = { [weak self] member in
                self?.onSelect?(member)
            }
            frameViews.append(frameView)
            stack.addArrangedSubview(frameView)
            frameView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        while frameViews.count > members.count {
            frameViews.removeLast().removeFromSuperview()
        }
        let now = Date()
        for (frameView, member) in zip(frameViews, members) {
            frameView.update(member, now: now)
        }
        countLabel.stringValue = "\(members.count)"
        updateRefreshTimer()
    }

    private func configure() {
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.material = .sidebar
        backgroundView.blendingMode = .withinWindow
        backgroundView.state = .followsWindowActiveState
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        for label in [headerLabel, countLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = .systemFont(ofSize: 10, weight: .semibold)
            label.textColor = .secondaryLabelColor
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent party")

        addSubview(backgroundView)
        addSubview(separator)
        addSubview(headerLabel)
        addSubview(countLabel)
        addSubview(stack)
        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            countLabel.firstBaselineAnchor.constraint(equalTo: headerLabel.firstBaselineAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    private func updateRefreshTimer() {
        let needsTimer =
            window != nil && !isHidden
            && frameViews.contains { $0.member?.showsElapsedTime == true }
        guard needsTimer != (refreshTimer != nil) else {
            return
        }
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard needsTimer else {
            return
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            let now = Date()
            for frameView in self?.frameViews ?? [] {
                frameView.refreshElapsed(now: now)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }
}

private final class NativePartyFrameView: NSView {
    private enum Metrics {
        static let portraitSize: CGFloat = 36
        static let barHeight: CGFloat = 5
    }

    var onSelect: ((NativePartyMember) -> Void)?
    private(set) var member: NativePartyMember?

    private let portraitView = NSView(frame: .zero)
    private let initialsLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let barView = NSView(frame: .zero)
    private let summaryLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return
        }
        select()
    }

    override func accessibilityPerformPress() -> Bool {
        select()
        return member != nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func update(_ member: NativePartyMember, now: Date) {
        self.member = member
        initialsLabel.stringValue = member.initials
        titleLabel.stringValue = member.title
        summaryLabel.stringValue =
            member.summary.isEmpty ? (member.active ? "Current tab" : " ") : member.summary
        refreshElapsed(now: now)
        setAccessibilityLabel("\(member.title), \(member.statusTitle.lowercased())")
        setAccessibilityHelp(member.summary.isEmpty ? nil : member.summary)
        applyColors()
    }

    func refreshElapsed(now: Date) {
        guard let member else {
            return
        }
        if member.showsElapsedTime, let since = member.statusSince {
            statusLabel.stringValue =
                "\(member.statusTitle) \(nativePartyElapsedText(since: since, now: now))"
        } else {
            statusLabel.stringValue = member.statusTitle
        }
    }

    private func select() {
        guard let member else {
            return
        }
        onSelect?(member)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1.5
        portraitView.translatesAutoresizingMaskIntoConstraints = false
        portraitView.wantsLayer = true
        portraitView.layer?.cornerRadius = 6
        portraitView.layer?.borderWidth = 2
        initialsLabel.translatesAutoresizingMaskIntoConstraints = false
        initialsLabel.font = .systemFont(ofSize: 13, weight: .bold)
        initialsLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        barView.translatesAutoresizingMaskIntoConstraints = false
        barView.wantsLayer = true
        barView.layer?.cornerRadius = Metrics.barHeight / 2
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        portraitView.addSubview(initialsLabel)
        for subview in [portraitView, titleLabel, statusLabel, barView, summaryLabel] {
            addSubview(subview)
        }
        let textLeading = portraitView.trailingAnchor
        NSLayoutConstraint.activate([
            portraitView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            portraitView.centerYAnchor.constraint(equalTo: centerYAnchor),
            portraitView.widthAnchor.constraint(equalToConstant: Metrics.portraitSize),
            portraitView.heightAnchor.constraint(equalToConstant: Metrics.portraitSize),
            initialsLabel.centerXAnchor.constraint(equalTo: portraitView.centerXAnchor),
            initialsLabel.centerYAnchor.constraint(equalTo: portraitView.centerYAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: textLeading, constant: 9),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: statusLabel.leadingAnchor,
                constant: -6
            ),
            statusLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            barView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            barView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            barView.heightAnchor.constraint(equalToConstant: Metrics.barHeight),
            summaryLabel.topAnchor.constraint(equalTo: barView.bottomAnchor, constant: 4),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            summaryLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    private func applyColors() {
        guard let member else {
            return
        }
        let statusColor = nativePartyStatusColor(member.badge)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background =
                member.badge == .waiting
                ? NSColor.systemOrange.withAlphaComponent(0.16)
                : NSColor.labelColor.withAlphaComponent(member.active ? 0.1 : 0.04)
            layer?.backgroundColor = background.cgColor
            layer?.borderColor =
                (member.active
                ? NSColor.labelColor.withAlphaComponent(0.55)
                : NSColor.clear).cgColor
            portraitView.layer?.backgroundColor = statusColor.withAlphaComponent(0.18).cgColor
            portraitView.layer?.borderColor = statusColor.cgColor
            barView.layer?.backgroundColor =
                (member.badge == nil
                ? NSColor.labelColor.withAlphaComponent(0.12)
                : statusColor).cgColor
        }
        initialsLabel.textColor = member.badge == nil ? .secondaryLabelColor : statusColor
        statusLabel.textColor = member.badge == nil ? .tertiaryLabelColor : statusColor
    }
}

func runNativePartyFramesSelfTests() -> Bool {
    let base = Date(timeIntervalSince1970: 1_000)
    let statuses: [Int: NativePaneControlStatus] = [
        10: NativePaneControlStatus(
            status: "running", summary: "Claude Code working", revision: 1, updatedAt: base),
        11: NativePaneControlStatus(
            status: "waiting", summary: "Claude Code needs approval", revision: 2,
            updatedAt: base),
        20: NativePaneControlStatus(
            status: "done", summary: "Claude Code finished", revision: 3, updatedAt: base),
        30: NativePaneControlStatus(
            status: "done", summary: "Claude Code finished", revision: 4, updatedAt: base),
    ]
    let tabs = [
        NativePartyTab(id: 1, index: 0, title: "api-server", activePane: 12, panes: [10, 11, 12]),
        NativePartyTab(id: 2, index: 1, title: "web", activePane: 21, panes: [20, 21]),
        NativePartyTab(id: 3, index: 2, title: "docs", activePane: 31, panes: [30, 31]),
    ]
    let members = nativePartyMembers(
        tabs: tabs,
        activeTabIndex: 1,
        status: { statuses[$0] },
        isUnread: { $0 == 20 }
    )
    guard members.count == 3,
        members[0].badge == .waiting,
        members[0].targetPaneId == 11,
        members[0].summary == "Claude Code needs approval",
        members[0].statusSince == base,
        members[0].initials == "AP",
        !members[0].active,
        members[1].badge == .done,
        members[1].targetPaneId == 20,
        members[1].active,
        members[1].statusTitle == "CLEAR",
        !members[1].showsElapsedTime,
        // Read completions fall back to the tab's own focus target.
        members[2].badge == nil,
        members[2].targetPaneId == 31,
        members[2].statusSince == nil,
        members[2].statusTitle == "IDLE"
    else {
        return false
    }
    guard nativePartyElapsedText(since: base, now: base.addingTimeInterval(401)) == "06:41",
        nativePartyElapsedText(since: base, now: base.addingTimeInterval(3_725)) == "1:02:05",
        nativePartyElapsedText(since: base, now: base.addingTimeInterval(-5)) == "00:00",
        NativePartyMember(
            tabId: 0, tabIndex: 0, title: "~/", badge: nil, summary: "", statusSince: nil,
            targetPaneId: 0, active: false
        ).initials == "?"
    else {
        return false
    }

    let view = NativePartyFramesView(frame: NSRect(x: 0, y: 0, width: 232, height: 400))
    var selected: NativePartyMember?
    view.onSelect = { selected = $0 }
    view.update(members)
    view.update(Array(members.prefix(2)))
    let frames = view.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews ?? []
    guard frames.count == 2,
        frames[0].accessibilityPerformPress(),
        selected?.targetPaneId == 11
    else {
        return false
    }
    return true
}

import Foundation

/// The core takes a workspace whole or not at all, so one tmux window caught
/// mid-change, such as a pane split or moved a moment before its layout
/// arrives, would hold every tab on its old state. This checks each window
/// as the core does before the workspace is applied. What can be mended is
/// mended: a split ratio past the core's bounds is clamped, and an active
/// pane missing from the layout gives way to the layout's first pane. A
/// window that cannot be mended keeps the tab it had, or is left out until a
/// later snapshot brings it whole. Each repair is named in `notes`.
struct NativeTmuxWorkspaceRepair {
    static let minRatio = 0.05
    static let maxRatio = 0.95

    let workspace: TerminalCoreSnapshot?
    let notes: [String]

    init(_ workspace: TerminalCoreSnapshot, previous: TerminalCoreSnapshot?) {
        var notes = [String]()
        var taken = Set<Int>()
        var tabIds = Set<Int>()
        var tabs = [TerminalCoreTabSnapshot]()
        let known = Set(workspace.tabs.flatMap(\.panes))
        let activeId =
            workspace.tabs.indices.contains(workspace.active_tab)
            ? workspace.tabs[workspace.active_tab].id : nil
        for tab in workspace.tabs {
            guard tabIds.insert(tab.id).inserted else {
                notes.append("tab=\(tab.id) reason=duplicate_tab")
                continue
            }
            var reason = ""
            if let mended = Self.mend(tab, taken: taken, reason: &reason) {
                if !reason.isEmpty {
                    notes.append("tab=\(tab.id) mended=\(reason)")
                }
                taken.formUnion(mended.panes)
                tabs.append(mended)
                continue
            }
            var unused = ""
            if let old = previous?.tabs.first(where: { $0.id == tab.id }),
                Set(old.panes).isSubset(of: known),
                let kept = Self.mend(old, taken: taken, reason: &unused)
            {
                notes.append("tab=\(tab.id) reason=\(reason) kept=previous")
                taken.formUnion(kept.panes)
                tabs.append(kept)
            } else {
                notes.append("tab=\(tab.id) reason=\(reason) kept=none")
            }
        }
        let numbered = tabs.enumerated().map { index, tab in
            TerminalCoreTabSnapshot(
                id: tab.id, index: index, title: tab.title, active_pane: tab.active_pane,
                theme: tab.theme, panes: tab.panes, layout: tab.layout)
        }
        self.workspace =
            numbered.isEmpty
            ? nil
            : TerminalCoreSnapshot(
                active_tab: numbered.firstIndex { $0.id == activeId } ?? 0, tabs: numbered)
        self.notes = notes
    }

    /// The tab as the core will take it, or nil with `reason` set.
    private static func mend(
        _ tab: TerminalCoreTabSnapshot, taken: Set<Int>, reason: inout String
    ) -> TerminalCoreTabSnapshot? {
        var leaves = [Int]()
        var clamped = false
        guard let layout = mend(tab.layout, leaves: &leaves, clamped: &clamped) else {
            reason = "bad_layout"
            return nil
        }
        guard Set(leaves).count == leaves.count else {
            reason = "pane_twice"
            return nil
        }
        if let shared = leaves.first(where: taken.contains) {
            reason = "pane_in_other_tab_\(shared)"
            return nil
        }
        var mended = [String]()
        if clamped {
            mended.append("ratio")
        }
        var active = tab.active_pane
        if !leaves.contains(active) {
            active = leaves[0]
            mended.append("active_pane")
        }
        if Set(tab.panes) != Set(leaves) {
            mended.append("panes")
        }
        reason = mended.joined(separator: ",")
        return TerminalCoreTabSnapshot(
            id: tab.id, index: tab.index, title: tab.title, active_pane: active,
            theme: tab.theme, panes: leaves, layout: layout)
    }

    private static func mend(
        _ layout: PaneLayoutSnapshot, leaves: inout [Int], clamped: inout Bool
    ) -> PaneLayoutSnapshot? {
        if layout.kind == "leaf" {
            guard let pane = layout.pane_id else {
                return nil
            }
            leaves.append(pane)
            return layout
        }
        guard layout.kind == "split",
            let axis = layout.axis, axis == "horizontal" || axis == "vertical",
            let first = layout.first, let second = layout.second
        else {
            return nil
        }
        var ratio = layout.ratio ?? 0.5
        guard ratio.isFinite else {
            return nil
        }
        if ratio < minRatio || ratio > maxRatio {
            ratio = min(max(ratio, minRatio), maxRatio)
            clamped = true
        }
        guard let left = mend(first, leaves: &leaves, clamped: &clamped),
            let right = mend(second, leaves: &leaves, clamped: &clamped)
        else {
            return nil
        }
        return PaneLayoutSnapshot(
            kind: "split", axis: axis, ratio: ratio, first: left, second: right)
    }
}

func runNativeTmuxWorkspaceRepairSelfTests() -> Bool {
    func leaf(_ pane: Int) -> PaneLayoutSnapshot {
        PaneLayoutSnapshot(kind: "leaf", paneId: pane)
    }
    func split(_ ratio: Double, _ first: Int, _ second: Int) -> PaneLayoutSnapshot {
        PaneLayoutSnapshot(
            kind: "split", axis: "vertical", ratio: ratio, first: leaf(first),
            second: leaf(second))
    }
    func tab(_ id: Int, active: Int, panes: [Int], _ layout: PaneLayoutSnapshot)
        -> TerminalCoreTabSnapshot
    {
        TerminalCoreTabSnapshot(
            id: id, index: 0, title: "t\(id)", active_pane: active, theme: "", panes: panes,
            layout: layout)
    }
    // A thin pane's ratio is clamped; an active pane not yet in the layout
    // gives way to the first one.
    let mended = NativeTmuxWorkspaceRepair(
        TerminalCoreSnapshot(
            active_tab: 1,
            tabs: [
                tab(1, active: 1, panes: [1, 2], split(0.01, 1, 2)),
                tab(2, active: 9, panes: [3], leaf(3)),
            ]),
        previous: nil)
    guard let workspace = mended.workspace, workspace.tabs.count == 2,
        workspace.active_tab == 1, workspace.tabs[0].layout.ratio == 0.05,
        workspace.tabs[1].active_pane == 3, mended.notes.count == 2
    else {
        return false
    }
    // A pane caught in two windows: the second keeps its previous tab, and
    // the rest still apply.
    let previous = TerminalCoreSnapshot(
        active_tab: 0,
        tabs: [
            tab(1, active: 1, panes: [1], leaf(1)),
            tab(2, active: 4, panes: [4], leaf(4)),
        ])
    let moved = NativeTmuxWorkspaceRepair(
        TerminalCoreSnapshot(
            active_tab: 0,
            tabs: [
                tab(1, active: 1, panes: [1, 4], split(0.5, 1, 4)),
                tab(2, active: 4, panes: [4], leaf(4)),
                tab(3, active: 5, panes: [5], leaf(5)),
            ]),
        previous: previous)
    guard let kept = moved.workspace, kept.tabs.map(\.id) == [1, 3],
        kept.tabs.map(\.index) == [0, 1]
    else {
        return false
    }
    // Nothing whole is nothing to apply.
    let broken = NativeTmuxWorkspaceRepair(
        TerminalCoreSnapshot(
            active_tab: 0,
            tabs: [tab(1, active: 1, panes: [1], PaneLayoutSnapshot(kind: "split"))]),
        previous: nil)
    return broken.workspace == nil && broken.notes == ["tab=1 reason=bad_layout kept=none"]
}

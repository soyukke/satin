import AppKit

struct NativePaneSiblingRelation: Equatable {
    let axis: String
    let sourceIsFirst: Bool
}

func nativePaneDirectSiblingRelation(
    in layout: PaneLayoutSnapshot,
    sourcePaneId: Int,
    targetPaneId: Int
) -> NativePaneSiblingRelation? {
    guard layout.kind == "split",
        let axis = layout.axis,
        let first = layout.first,
        let second = layout.second
    else {
        return nil
    }
    if first.pane_id == sourcePaneId, second.pane_id == targetPaneId {
        return NativePaneSiblingRelation(axis: axis, sourceIsFirst: true)
    }
    if first.pane_id == targetPaneId, second.pane_id == sourcePaneId {
        return NativePaneSiblingRelation(axis: axis, sourceIsFirst: false)
    }
    return nativePaneDirectSiblingRelation(
        in: first,
        sourcePaneId: sourcePaneId,
        targetPaneId: targetPaneId
    )
        ?? nativePaneDirectSiblingRelation(
            in: second,
            sourcePaneId: sourcePaneId,
            targetPaneId: targetPaneId
        )
}

func nativePaneEffectiveDropPosition(
    in layout: PaneLayoutSnapshot,
    sourcePaneId: Int,
    targetPaneId: Int,
    position: NativePaneDropPosition
) -> NativePaneDropPosition? {
    guard sourcePaneId != targetPaneId,
        nativePaneLayoutContains(layout, paneId: sourcePaneId),
        nativePaneLayoutContains(layout, paneId: targetPaneId)
    else {
        return nil
    }
    guard let contract = position.directSiblingContract,
        let relation = nativePaneDirectSiblingRelation(
            in: layout,
            sourcePaneId: sourcePaneId,
            targetPaneId: targetPaneId
        ),
        relation.axis == contract.axis
    else {
        return position
    }
    return relation.sourceIsFirst == contract.before ? nil : .center
}

private func nativePaneLayoutContains(_ layout: PaneLayoutSnapshot, paneId: Int) -> Bool {
    if layout.pane_id == paneId {
        return true
    }
    return layout.first.map { nativePaneLayoutContains($0, paneId: paneId) } == true
        || layout.second.map { nativePaneLayoutContains($0, paneId: paneId) } == true
}

func nativeTmuxPaneMoveCommand(
    sourcePaneId: UInt32,
    targetPaneId: UInt32,
    position: NativePaneDropPosition
) -> String {
    let source = "-s %\(sourcePaneId)"
    let target = "-t %\(targetPaneId)"
    switch position {
    case .center:
        return "swap-pane -d \(source) \(target)"
    case .left:
        return "join-pane -h -b \(source) \(target)"
    case .right:
        return "join-pane -h \(source) \(target)"
    case .top:
        return "join-pane -v -b \(source) \(target)"
    case .bottom:
        return "join-pane -v \(source) \(target)"
    }
}

func runNativePaneDragSelfTests() -> Bool {
    let siblingLayout = PaneLayoutSnapshot(
        kind: "split",
        axis: "vertical",
        first: PaneLayoutSnapshot(kind: "leaf", paneId: 7),
        second: PaneLayoutSnapshot(kind: "leaf", paneId: 9)
    )
    return runNativePaneDragGeometrySelfTests()
        && nativePaneDirectSiblingRelation(
            in: siblingLayout,
            sourcePaneId: 7,
            targetPaneId: 9
        ) == NativePaneSiblingRelation(axis: "vertical", sourceIsFirst: true)
        && nativePaneEffectiveDropPosition(
            in: siblingLayout,
            sourcePaneId: 7,
            targetPaneId: 9,
            position: .left
        ) == nil
        && nativePaneEffectiveDropPosition(
            in: siblingLayout,
            sourcePaneId: 7,
            targetPaneId: 9,
            position: .right
        ) == .center
        && nativePaneEffectiveDropPosition(
            in: siblingLayout,
            sourcePaneId: 9,
            targetPaneId: 7,
            position: .right
        ) == nil
        && nativePaneEffectiveDropPosition(
            in: siblingLayout,
            sourcePaneId: 7,
            targetPaneId: 9,
            position: .top
        ) == .top
        && nativePaneEffectiveDropPosition(
            in: siblingLayout,
            sourcePaneId: 99,
            targetPaneId: 9,
            position: .center
        ) == nil
        && nativeTmuxPaneMoveCommand(sourcePaneId: 7, targetPaneId: 9, position: .center)
            == "swap-pane -d -s %7 -t %9"
        && nativeTmuxPaneMoveCommand(sourcePaneId: 7, targetPaneId: 9, position: .left)
            == "join-pane -h -b -s %7 -t %9"
        && nativeTmuxPaneMoveCommand(sourcePaneId: 7, targetPaneId: 9, position: .right)
            == "join-pane -h -s %7 -t %9"
        && nativeTmuxPaneMoveCommand(sourcePaneId: 7, targetPaneId: 9, position: .top)
            == "join-pane -v -b -s %7 -t %9"
        && nativeTmuxPaneMoveCommand(sourcePaneId: 7, targetPaneId: 9, position: .bottom)
            == "join-pane -v -s %7 -t %9"
}

extension TerminalShellViewController {
    func paneDropChangesLayout(
        _ sourcePaneId: Int,
        relativeTo targetPaneId: Int,
        position: NativePaneDropPosition
    ) -> Bool {
        guard sourcePaneId != nativeArtifactSidebarPaneId,
            targetPaneId != nativeArtifactSidebarPaneId,
            let tab = lastSnapshot?.tabs.first(where: {
                $0.panes.contains(sourcePaneId) && $0.panes.contains(targetPaneId)
            })
        else {
            return false
        }
        return nativePaneEffectiveDropPosition(
            in: tab.layout,
            sourcePaneId: sourcePaneId,
            targetPaneId: targetPaneId,
            position: position
        ) != nil
    }

    @discardableResult
    func movePane(
        _ sourcePaneId: Int,
        relativeTo targetPaneId: Int,
        position: NativePaneDropPosition
    ) -> Bool {
        guard sourcePaneId != nativeArtifactSidebarPaneId,
            targetPaneId != nativeArtifactSidebarPaneId,
            let tab = lastSnapshot?.tabs.first(where: {
                $0.panes.contains(sourcePaneId) && $0.panes.contains(targetPaneId)
            }),
            let effectivePosition = nativePaneEffectiveDropPosition(
                in: tab.layout,
                sourcePaneId: sourcePaneId,
                targetPaneId: targetPaneId,
                position: position
            )
        else {
            return false
        }
        if let session = tmuxSession {
            guard let sourceTmuxPaneId = session.tmuxPaneIds[sourcePaneId],
                let targetTmuxPaneId = session.tmuxPaneIds[targetPaneId]
            else {
                presentTmuxSessionError("Satin could not resolve the tmux panes to move.")
                return false
            }
            let command = nativeTmuxPaneMoveCommand(
                sourcePaneId: sourceTmuxPaneId,
                targetPaneId: targetTmuxPaneId,
                position: effectivePosition
            )
            guard session.gateway.tmuxCommand(command) else {
                presentTmuxSessionError("Satin could not move the tmux pane.")
                return false
            }
            focusTerminal()
            return true
        }
        guard
            core.movePane(
                sourcePaneId,
                relativeTo: targetPaneId,
                position: effectivePosition
            )
        else {
            NativeLog.runtimeError(
                "pane_move_failed source=\(sourcePaneId) target=\(targetPaneId) "
                    + "position=\(position.rawValue)"
            )
            return false
        }
        syncFromCore()
        saveSessionState()
        focusTerminal()
        return true
    }
}

extension NativePaneDropPosition {
    fileprivate var directSiblingContract: (axis: String, before: Bool)? {
        switch self {
        case .center:
            nil
        case .left:
            ("vertical", true)
        case .right:
            ("vertical", false)
        case .top:
            ("horizontal", true)
        case .bottom:
            ("horizontal", false)
        }
    }
}

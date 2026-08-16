import AppKit

struct NativePaneGridCapacity: Equatable {
    let rows: Int
    let cols: Int
}

func tmuxClientGridCapacity(
    layout: PaneLayoutSnapshot,
    leafCapacities: [Int: NativePaneGridCapacity]
) -> NativePaneGridCapacity? {
    if layout.kind == "leaf" {
        return layout.pane_id.flatMap { leafCapacities[$0] }
    }
    guard let axis = layout.axis,
        let first = layout.first.flatMap({
            tmuxClientGridCapacity(layout: $0, leafCapacities: leafCapacities)
        }),
        let second = layout.second.flatMap({
            tmuxClientGridCapacity(layout: $0, leafCapacities: leafCapacities)
        })
    else {
        return nil
    }
    switch axis {
    case "vertical":
        return NativePaneGridCapacity(
            rows: min(first.rows, second.rows),
            cols: first.cols + second.cols + 1
        )
    case "horizontal":
        return NativePaneGridCapacity(
            rows: first.rows + second.rows + 1,
            cols: min(first.cols, second.cols)
        )
    default:
        return nil
    }
}

func paneFrameRequirements(
    layout: PaneLayoutSnapshot,
    leafRequirements: [Int: NSSize]
) -> [ObjectIdentifier: NSSize] {
    var requirements: [ObjectIdentifier: NSSize] = [:]

    func collect(_ node: PaneLayoutSnapshot) -> NSSize? {
        let requirement: NSSize
        if node.kind == "leaf" {
            guard let paneId = node.pane_id, let leaf = leafRequirements[paneId] else {
                return nil
            }
            requirement = leaf
        } else {
            guard let axis = node.axis,
                let first = node.first.flatMap(collect),
                let second = node.second.flatMap(collect)
            else {
                return nil
            }
            switch axis {
            case "vertical":
                requirement = NSSize(
                    width: first.width + second.width,
                    height: max(first.height, second.height)
                )
            case "horizontal":
                requirement = NSSize(
                    width: max(first.width, second.width),
                    height: first.height + second.height
                )
            default:
                return nil
            }
        }
        requirements[ObjectIdentifier(node)] = requirement
        return requirement
    }

    _ = collect(layout)
    return requirements
}

func paneSplitRatio(
    layoutRatio: Double?,
    axis: String,
    available: CGFloat,
    firstRequirement: NSSize?,
    secondRequirement: NSSize?
) -> CGFloat {
    let ratio = CGFloat(min(max(layoutRatio ?? 0.5, 0.05), 0.95))
    guard let firstRequirement, let secondRequirement, available > 0 else {
        return ratio
    }
    let first: CGFloat
    let second: CGFloat
    switch axis {
    case "vertical":
        first = firstRequirement.width
        second = secondRequirement.width
    case "horizontal":
        first = firstRequirement.height
        second = secondRequirement.height
    default:
        return ratio
    }
    let required = first + second
    guard required > 0 else {
        return ratio
    }

    // tmux ratios describe cell areas, while native leaf bounds also contain a
    // fixed header. Reserve the reported grids and headers before distributing
    // spare points by the tmux ratio.
    let firstExtent =
        if required <= available {
            first + (available - required) * ratio
        } else {
            available * first / required
        }
    return min(max(firstExtent / available, 0), 1)
}

func runNativePaneGeometrySelfTests() -> Bool {
    let layout = PaneLayoutSnapshot(
        kind: "split",
        axis: "horizontal",
        first: PaneLayoutSnapshot(
            kind: "split",
            axis: "vertical",
            first: PaneLayoutSnapshot(kind: "leaf", paneId: 1),
            second: PaneLayoutSnapshot(kind: "leaf", paneId: 2)
        ),
        second: PaneLayoutSnapshot(kind: "leaf", paneId: 3)
    )
    let capacity = tmuxClientGridCapacity(
        layout: layout,
        leafCapacities: [
            1: NativePaneGridCapacity(rows: 20, cols: 40),
            2: NativePaneGridCapacity(rows: 18, cols: 30),
            3: NativePaneGridCapacity(rows: 25, cols: 60),
        ]
    )
    let requirements = paneFrameRequirements(
        layout: layout,
        leafRequirements: [
            1: NSSize(width: 400, height: 200),
            2: NSSize(width: 300, height: 180),
            3: NSSize(width: 600, height: 250),
        ]
    )
    guard capacity == NativePaneGridCapacity(rows: 44, cols: 60),
        let firstLayout = layout.first,
        let secondLayout = layout.second,
        let first = requirements[ObjectIdentifier(firstLayout)],
        let second = requirements[ObjectIdentifier(secondLayout)],
        requirements[ObjectIdentifier(layout)] == NSSize(width: 700, height: 450)
    else {
        return false
    }
    let fittedRatio = paneSplitRatio(
        layoutRatio: 0.25,
        axis: "horizontal",
        available: 500,
        firstRequirement: first,
        secondRequirement: second
    )
    let compressedRatio = paneSplitRatio(
        layoutRatio: 0.25,
        axis: "horizontal",
        available: 360,
        firstRequirement: first,
        secondRequirement: second
    )
    return abs(fittedRatio - 0.425) < 0.001
        && abs(compressedRatio - (200.0 / 450.0)) < 0.001
}

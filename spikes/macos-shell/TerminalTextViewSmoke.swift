import AppKit
import Foundation

#if SATIN_SMOKE_SCENARIOS
    extension TerminalTextView {
        func markedTextOriginForSmoke() -> NSPoint {
            compositionOrigin()
        }

        func hasRendererModelFrames() -> Bool {
            rendererModelFrameCount > 0
        }

        func rendererContentRowCount() -> Int {
            guard let rendererModelSnapshot else {
                return 0
            }
            return contentRowCount(rendererModelRows(rendererModelSnapshot))
        }

        func rendererMaxScrollPosition() -> Double {
            rendererModelSnapshot?.windows
                .map { abs($0.scroll_position) }
                .max() ?? 0
        }

        func rendererVisibleWindowScrollPositions() -> [(
            gridID: Int, left: Int, position: Double
        )] {
            rendererModelSnapshot?.windows
                .filter { !$0.hidden && $0.width > 0 && $0.height > 0 }
                .map { ($0.grid_id, $0.left, abs($0.scroll_position)) }
                .sorted { $0.gridID < $1.gridID } ?? []
        }

        func rendererCursorParentGridID() -> Int? {
            rendererModelSnapshot?.cursor_parent_grid_id
        }

        func rendererHasVisibleWindow(gridID: Int) -> Bool {
            rendererModelSnapshot?.windows.contains {
                $0.grid_id == gridID && !$0.hidden && $0.width > 0 && $0.height > 0
            } ?? false
        }

        func rendererVisibleWindowRightEdge(gridID: Int) -> Int? {
            rendererModelSnapshot?.windows.first {
                $0.grid_id == gridID && !$0.hidden && $0.width > 0 && $0.height > 0
            }.map { $0.left + $0.width }
        }

        func rendererRootGridSize() -> (cols: Int, rows: Int)? {
            rendererModelSnapshot?.windows.first {
                $0.grid_id == 1 && !$0.hidden && $0.width > 0 && $0.height > 0
            }.map { ($0.width, $0.height) }
        }

        func rendererModelOccupiedCellCount(column: Int) -> Int {
            guard let rendererModelSnapshot, column >= 0 else {
                return 0
            }
            return rendererModelRows(rendererModelSnapshot).reduce(0) { count, row in
                guard row.indices.contains(column) else {
                    return count
                }
                let cell = row[column]
                let hasText = !cell.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                return count + ((hasText || cell.bg != nil) ? 1 : 0)
            }
        }

        func rendererPopulatedLineCount(gridID: Int) -> Int {
            rendererModelSnapshot?.windows
                .first { $0.grid_id == gridID }?
                .lines
                .compactMap { $0 }
                .count ?? 0
        }

        func rendererLineCapacity(gridID: Int) -> Int {
            rendererModelSnapshot?.windows
                .first { $0.grid_id == gridID }?
                .lines
                .count ?? 0
        }

        func rendererCursorParentInLeftSplit() -> Int? {
            guard let model = rendererModelSnapshot,
                let parentGrid = model.cursor_parent_grid_id,
                parentGrid > 1,
                let parent = model.windows.first(where: {
                    $0.grid_id == parentGrid && !$0.hidden && $0.width > 0 && $0.height > 0
                }),
                parent.left == 0,
                model.windows.contains(where: {
                    $0.grid_id > 1
                        && $0.grid_id != parentGrid
                        && !$0.hidden
                        && $0.width > 0
                        && $0.height > 0
                        && $0.left > parent.left
                })
            else {
                return nil
            }
            return parentGrid
        }

        func rendererViewportSummary() -> String {
            guard let rendererModelSnapshot else {
                return "none"
            }
            let windows = rendererModelSnapshot.windows
                .filter { !$0.hidden }
                .map { window in
                    "\(window.grid_id):\(window.width)x\(window.height)"
                        + "@\(String(format: "%.3f", window.scroll_position))"
                }
                .joined(separator: ",")
            let cursor =
                rendererModelSnapshot.cursor
                .map { "\($0.x),\($0.y)" } ?? "none"
            return "windows=\(windows.isEmpty ? "none" : windows) cursor=\(cursor)"
        }

        func rendererTextSummary() -> String {
            guard let rendererModelSnapshot else {
                return "none"
            }
            let rows = rendererModelRows(rendererModelSnapshot)
                .map { row in row.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(4)
            return rows.isEmpty ? "none" : rows.joined(separator: "|")
        }

        func rendererModelContainsTexts(_ needles: [String]) -> Bool {
            rendererModelMissingTexts(needles).isEmpty
        }

        func rendererModelMissingTexts(_ needles: [String]) -> [String] {
            guard let rendererModelSnapshot else {
                return needles
            }
            let rows = rendererModelRows(rendererModelSnapshot)
            let cellTexts = rows.flatMap { row in row.map(\.text) }
            let rowText =
                rows
                .map { row in row.map(\.text).joined() }
                .joined(separator: "\n")
            return needles.filter { needle in
                !cellTexts.contains(needle) && !rowText.contains(needle)
            }
        }

        func rendererModelCellSummary(_ labels: [(label: String, text: String)]) -> String {
            let cells = labels.compactMap { label, text in
                rendererModelCellPosition(text).map { row, col in
                    "\(label):\(row):\(col)"
                }
            }
            return cells.isEmpty ? "none" : cells.joined(separator: ",")
        }

        func rendererModelTextStartSummary(label: String, text: String) -> String {
            guard let position = rendererModelTextStartPosition(text) else {
                return "none"
            }
            return "\(label):\(position.row):\(position.col)"
        }

        func rendererModelRawTextStartSummary(label: String, text: String) -> String {
            guard let rendererModelSnapshot else {
                return "none"
            }
            for window in rendererModelSnapshot.windows {
                for (rowIndex, line) in window.lines.enumerated() {
                    guard let line,
                        let range = line.text.range(of: text)
                    else {
                        continue
                    }
                    let col = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
                    return
                        "\(label):\(window.grid_id):\(rowIndex):\(col):\(window.hidden ? "hidden" : "visible")"
                }
            }
            return "none"
        }

        func rendererModelRawScreenTextStartSummary(label: String, text: String) -> String {
            guard let rendererModelSnapshot else {
                return "none"
            }
            for window in rendererModelSnapshot.windows where !window.hidden {
                for (rowIndex, line) in window.lines.enumerated() {
                    guard let line,
                        let range = line.text.range(of: text)
                    else {
                        continue
                    }
                    let col = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
                    return "\(label):\(window.top + rowIndex):\(window.left + col)"
                }
            }
            return "none"
        }

        func rendererModelWindowTextSummary(limit: Int = 4) -> String {
            guard let rendererModelSnapshot else {
                return "none"
            }
            let summaries = rendererModelSnapshot.windows.prefix(limit).map { window in
                let text =
                    window.lines.compactMap { line in
                        line?.text.trimmingCharacters(in: .whitespaces)
                    }
                    .first { !$0.isEmpty } ?? "-"
                let clipped = text.count > 24 ? String(text.prefix(24)) : text
                return "\(window.grid_id):\(window.width)x\(window.height)"
                    + "@\(window.left),\(window.top):\(window.hidden ? "h" : "v"):\(clipped)"
            }
            return summaries.isEmpty ? "none" : summaries.joined(separator: ",")
        }

        func skiaGeometrySummary() -> String {
            let geometry = skiaRenderGeometry()
            return [
                geometry.originX,
                geometry.originY,
                geometry.cellWidth,
                geometry.cellHeight,
            ]
            .map {
                String(
                    format: "%.4f",
                    locale: Locale(identifier: "en_US_POSIX"),
                    Double($0)
                )
            }
            .joined(separator: ":")
        }

        func skiaViewportSummary() -> String {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
            return [
                Int((bounds.width * scale).rounded()),
                Int((bounds.height * scale).rounded()),
            ]
            .map(String.init)
            .joined(separator: ":")
        }

        func rendererModelCellPosition(_ needle: String) -> (row: Int, col: Int)? {
            guard let rendererModelSnapshot else {
                return nil
            }
            let rows = rendererModelRows(rendererModelSnapshot)
            for (rowIndex, row) in rows.enumerated() {
                for (colIndex, cell) in row.enumerated()
                where cell.text == needle || cell.text.contains(needle) {
                    return (rowIndex, colIndex)
                }
            }
            return nil
        }

        func rendererModelTextStartPosition(_ needle: String) -> (row: Int, col: Int)? {
            guard let rendererModelSnapshot else {
                return nil
            }
            let rows = rendererModelRows(rendererModelSnapshot)
            for (rowIndex, row) in rows.enumerated() {
                let text = rowPlainText(row)
                guard let range = text.range(of: needle) else {
                    continue
                }
                return (rowIndex, text.distance(from: text.startIndex, to: range.lowerBound))
            }
            return nil
        }

        func rendererModelTextOccurrences(_ needle: String) -> Int {
            guard let rendererModelSnapshot else {
                return 0
            }
            return rendererModelRows(rendererModelSnapshot).reduce(0) { count, row in
                count + rowPlainText(row).components(separatedBy: needle).count - 1
            }
        }

        func rendererModelBlendCellCount(minBlend: UInt8) -> Int {
            guard let rendererModelSnapshot else {
                return 0
            }
            return rendererModelRows(rendererModelSnapshot).reduce(0) { count, row in
                count + row.filter { $0.bg != nil && $0.blend >= minBlend }.count
            }
        }

        func rendererModelBlendCellSummary(minBlend: UInt8) -> String {
            guard let rendererModelSnapshot else {
                return "none"
            }
            let rows = rendererModelRows(rendererModelSnapshot)
            for (rowIndex, row) in rows.enumerated() {
                for (colIndex, cell) in row.enumerated()
                where cell.bg != nil && cell.blend >= minBlend
                    && cell.text.trimmingCharacters(in: .whitespaces).isEmpty
                {
                    guard let bg = cell.bg else {
                        continue
                    }
                    return [
                        rowIndex,
                        colIndex,
                        Int(cell.blend),
                        Int(bg.r),
                        Int(bg.g),
                        Int(bg.b),
                        Int(rendererModelSnapshot.background.r),
                        Int(rendererModelSnapshot.background.g),
                        Int(rendererModelSnapshot.background.b),
                    ]
                    .map(String.init)
                    .joined(separator: ":")
                }
            }
            return "none"
        }

        func rendererModelWindowKindCounts() -> [String: Int] {
            guard let rendererModelSnapshot else {
                return [:]
            }
            return rendererModelSnapshot.windows.reduce(into: [:]) { counts, window in
                guard !window.hidden else {
                    return
                }
                counts[window.window_kind, default: 0] += 1
            }
        }

        func rendererModelMessageSelectionSummary() -> String {
            guard let selection = rendererModelSnapshot?.message_selection else {
                return "none"
            }
            return [
                selection.grid_id,
                selection.start.row,
                selection.start.col,
                selection.end.row,
                selection.end.col,
            ].map(String.init).joined(separator: ":")
        }

        func rendererModelCursorSummary() -> String {
            guard let cursor = rendererModelSnapshot?.cursor else {
                return "none"
            }
            return "\(cursor.y):\(cursor.x)"
        }

        func rendererModelCursorDetailSummary() -> String {
            guard let cursor = rendererModelSnapshot?.cursor else {
                return "none"
            }
            return [
                String(cursor.y),
                String(cursor.x),
                cursor.style,
                String(cursor.cell_percentage),
                String(cursor.blinkwait_ms),
                String(cursor.blinkon_ms),
                String(cursor.blinkoff_ms),
            ]
            .joined(separator: ":")
        }

    }
#endif

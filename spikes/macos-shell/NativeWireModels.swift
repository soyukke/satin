import Foundation

struct NativeSessionState: Codable {
    let schemaVersion: Int
    let activeTab: Int
    let tabs: [NativeSessionTab]
    let tmuxAttachment: NativeTmuxAttachment?

    init(
        schemaVersion: Int,
        activeTab: Int,
        tabs: [NativeSessionTab],
        tmuxAttachment: NativeTmuxAttachment? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.activeTab = activeTab
        self.tabs = tabs
        self.tmuxAttachment = tmuxAttachment
    }
}

struct NativeTmuxAttachment: Codable, Equatable {
    let sessionName: String
    let socketPath: String
    let executablePath: String?

    init(sessionName: String, socketPath: String, executablePath: String? = nil) {
        self.sessionName = sessionName
        self.socketPath = socketPath
        self.executablePath = executablePath
    }
}

struct NativeTmuxSessionDescriptor: Equatable {
    let name: String
    let windowCount: Int
    let socketPath: String
}

struct NativeSessionTab: Codable {
    let title: String
    let theme: String
    let layout: NativeSessionPane
    let titleIsManual: Bool?

    init(
        title: String,
        theme: String,
        layout: NativeSessionPane,
        titleIsManual: Bool? = nil
    ) {
        self.title = title
        self.theme = theme
        self.layout = layout
        self.titleIsManual = titleIsManual
    }
}

final class NativeSessionPane: Codable {
    let kind: String
    let axis: String?
    let ratio: Double?
    let paneMode: String?
    let cwd: String
    let active: Bool
    let first: NativeSessionPane?
    let second: NativeSessionPane?

    init(
        kind: String,
        axis: String? = nil,
        ratio: Double? = nil,
        paneMode: String? = nil,
        cwd: String = "",
        active: Bool = false,
        first: NativeSessionPane? = nil,
        second: NativeSessionPane? = nil
    ) {
        self.kind = kind
        self.axis = axis
        self.ratio = ratio
        self.paneMode = paneMode
        self.cwd = cwd
        self.active = active
        self.first = first
        self.second = second
    }
}

struct LegacyNativeSessionState: Codable {
    let activeTab: Int
    let tabs: [LegacyNativeSessionTab]
}

struct LegacyNativeSessionTab: Codable {
    let title: String
    let theme: String
    let cwd: String
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct TerminalCoreSnapshot: Codable {
    let active_tab: Int
    let tabs: [TerminalCoreTabSnapshot]
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct TerminalCoreTabSnapshot: Codable {
    let id: Int
    let index: Int
    let title: String
    let active_pane: Int
    let theme: String
    let panes: [Int]
    let layout: PaneLayoutSnapshot
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
final class PaneLayoutSnapshot: Codable {
    let kind: String
    let pane_id: Int?
    let axis: String?
    let ratio: Double?
    let first: PaneLayoutSnapshot?
    let second: PaneLayoutSnapshot?

    init(
        kind: String,
        paneId: Int? = nil,
        axis: String? = nil,
        ratio: Double? = nil,
        first: PaneLayoutSnapshot? = nil,
        second: PaneLayoutSnapshot? = nil
    ) {
        self.kind = kind
        self.pane_id = paneId
        self.axis = axis
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct TmuxControlEvent: Decodable {
    let kind: String
    let pane_id: UInt32?
    let data: [UInt8]?
    let rows: Int?
    let region_top: UInt16?
    let region_bottom: UInt16?
    let region_left: UInt16?
    let region_right: UInt16?
    let snapshot: TmuxSnapshot?
    let sessions: [TmuxSessionSummary]?
    let session_error: String?
    let reason: String?
    let message: String?
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct TmuxSessionSummary: Decodable {
    let name: String
    let window_count: Int
    let socket_path: String
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct TmuxSnapshot: Decodable {
    let session_id: UInt32
    let session_name: String
    let socket_path: String
    let server_pid: UInt32
    let active_window_id: UInt32
    let windows: [TmuxWindowSnapshot]
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct TmuxWindowSnapshot: Decodable {
    let window_id: UInt32
    let index: UInt32
    let name: String
    let active_pane_id: UInt32
    let zoomed: Bool
    let layout: TmuxLayoutSnapshot
    let panes: [TmuxPaneSnapshot]
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct TmuxPaneSnapshot: Decodable {
    let pane_id: UInt32
    let index: UInt32
    let active: Bool
    let current_path: String
    let cols: UInt16
    let rows: UInt16
    let cursor_x: UInt16
    let cursor_y: UInt16
    let cursor_visible: Bool
    let origin_mode: Bool
    let scroll_region_upper: UInt16
    let current_command: String
    let title: String
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
final class TmuxLayoutSnapshot: Decodable {
    let kind: String
    let pane_id: UInt32?
    let axis: String?
    let ratio: Double?
    let first: TmuxLayoutSnapshot?
    let second: TmuxLayoutSnapshot?
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct NeovideRendererModelSnapshot: Decodable {
    let background: TerminalColorSnapshot
    let cursor: TerminalCursorSnapshot?
    let cursor_parent_grid_id: Int?
    let message_selection: NeovideMessageSelectionSnapshot?
    let scrollbar: ScrollbarSnapshot?
    let scroll_hint: FrameScrollHint?
    let windows: [NeovideRenderedWindowSnapshot]
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct NeovideUiStateSnapshot: Decodable {
    let cursor: TerminalCursorSnapshot?
    let scroll_hint: FrameScrollHint?
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct NeovideMessageSelectionSnapshot: Decodable {
    let grid_id: Int
    let start: NeovideGridPositionSnapshot
    let end: NeovideGridPositionSnapshot
}

struct NeovideGridPositionSnapshot: Decodable {
    let row: Int
    let col: Int
}

struct ScrollbarSnapshot: Decodable {
    let top: UInt64
    let visible: UInt64
    let total: UInt64
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct NeovideRenderedWindowSnapshot: Decodable {
    let grid_id: Int
    let top: Int
    let left: Int
    let width: Int
    let height: Int
    let window_kind: String
    let zindex: Int
    let compindex: Int
    let hidden: Bool
    let scroll_position: Double
    let lines: [NeovideLineSnapshot?]
}

struct NeovideLineSnapshot: Decodable {
    let text: String
    let cells: [TerminalCellSnapshot]
}

struct TerminalCellSnapshot: Decodable {
    let text: String
    let bg: TerminalColorSnapshot?
    let blend: UInt8
}

struct TerminalColorSnapshot: Decodable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct TerminalCursorSnapshot: Decodable {
    let x: UInt16
    let y: UInt16
    let style: String
    let cell_percentage: UInt8
    let blinkwait_ms: UInt64
    let blinkon_ms: UInt64
    let blinkoff_ms: UInt64
}

// Properties mirror Rust's serialized schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct FrameScrollHint: Decodable {
    let start_row: Int
    let end_row: Int
    let start_col: Int?
    let end_col: Int?
    let rows: Int

    var outputShift: OutputScrollShift {
        OutputScrollShift(
            startRow: start_row,
            endRow: end_row,
            rows: rows,
            startCol: start_col,
            endCol: end_col
        )
    }
}

struct OutputScrollShift {
    let startRow: Int
    let endRow: Int
    let startCol: Int?
    let endCol: Int?
    let rows: Int

    init(startRow: Int, endRow: Int, rows: Int, startCol: Int? = nil, endCol: Int? = nil) {
        self.startRow = startRow
        self.endRow = endRow
        self.startCol = startCol
        self.endCol = endCol
        self.rows = rows
    }
}

// Properties mirror the Rust terminal spawn schema and intentionally use snake_case.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct NativeTerminalSpawnConfiguration: Encodable {
    let cwd: String?
    let shell: String?
    let environment: [String: String]
    let startup_command: [String]
    let direct_startup: Bool
}

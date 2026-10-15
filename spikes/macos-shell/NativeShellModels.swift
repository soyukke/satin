import AppKit
import Foundation

struct NativeTmuxScrollMetadata {
    let rows: Int
    let regionTop: UInt16?
    let regionBottom: UInt16?
    let regionLeft: UInt16?
    let regionRight: UInt16?
}

protocol TerminalContextMenuProvider: AnyObject {
    func terminalContextMenu(tabIndex: Int?) -> NSMenu
}

enum NativePaneDirection: UInt32 {
    case left = 0
    case right = 1
    case up = 2
    case down = 3
}

enum NativePaneDropPosition: UInt32, CaseIterable {
    case center = 0
    case left = 1
    case right = 2
    case top = 3
    case bottom = 4
}

final class NativeSuspendedTerminalSession {
    let pane: TerminalPane
    let completion: NativeControlReply?

    init(pane: TerminalPane, completion: NativeControlReply?) {
        self.pane = pane
        self.completion = completion
    }
}

private let tmuxNativePaneIdBase = 1_000_000_000
private let tmuxNativeTabIdBase = 1_500_000_000
let nativeArtifactSidebarPaneId = 9_000_000_000_000_000

final class NativeTmuxSession {
    let gatewayPaneId: Int
    let gateway: TerminalPane
    let savedWorkspace: TerminalCoreSnapshot
    var nativePaneIds: [UInt32: Int] = [:]
    var tmuxPaneIds: [Int: UInt32] = [:]
    var nativeTabIds: [UInt32: Int] = [:]
    var tmuxWindowIds: [Int: UInt32] = [:]
    var bufferedOutput: [UInt32: Data] = [:]
    var bufferedHydration: [UInt32: Data] = [:]
    var bufferedScrollMetadata: [UInt32: [NativeTmuxScrollMetadata]] = [:]
    var latestPanes: [UInt32: TmuxPaneSnapshot] = [:]
    var requestedClientGrid: NativePaneGridCapacity?
    var clientResizeThrottleWorkItem: DispatchWorkItem?
    #if SATIN_SMOKE_SCENARIOS
        var clientResizeRequestCount = 0
    #endif
    var sessionName = "tmux"
    var sessionID: UInt32 = 0
    var socketPath = ""
    var executablePath = ""
    var serverPid: UInt32 = 0
    var lease: NativeTmuxSessionLease?
    var activeWindowZoomed = false

    init(gatewayPaneId: Int, gateway: TerminalPane, savedWorkspace: TerminalCoreSnapshot) {
        self.gatewayPaneId = gatewayPaneId
        self.gateway = gateway
        self.savedWorkspace = savedWorkspace
    }

    deinit {
        clientResizeThrottleWorkItem?.cancel()
    }

    func nativePaneId(_ paneId: UInt32) -> Int {
        tmuxNativePaneIdBase + Int(paneId)
    }

    func nativeTabId(_ windowId: UInt32) -> Int {
        tmuxNativeTabIdBase + Int(windowId)
    }
}

enum SatinToolbarItemIdentifier {
    static let tabs = NSToolbarItem.Identifier("dev.soyukke.satin.toolbar.tabs")
    static let artifacts = NSToolbarItem.Identifier("dev.soyukke.satin.toolbar.artifacts")
    static let workSwitcher = NSToolbarItem.Identifier("dev.soyukke.satin.toolbar.work-switcher")
    static let controls = NSToolbarItem.Identifier("dev.soyukke.satin.toolbar.controls")
}

struct NativeArtifactListItem: Decodable {
    let id: String
    let title: String
    let kind: String
    let version: UInt32
    let updatedAtMs: UInt64
    let preview: String

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case version
        case updatedAtMs = "updated_at_ms"
        case preview
    }
}

struct NativeArtifactCLIResult: Decodable {
    let artifacts: [NativeArtifactListItem]
}

struct NativeArtifactCLIResponse: Decodable {
    let ok: Bool
    let result: NativeArtifactCLIResult?
}

struct NativeStoredArtifactVersion: Decodable {
    let version: UInt32
}

struct NativeStoredArtifactMetadata: Decodable {
    let id: String
    let versions: [NativeStoredArtifactVersion]
}

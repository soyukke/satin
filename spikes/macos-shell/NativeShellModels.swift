import AppKit
import Foundation

protocol TerminalContextMenuProvider: AnyObject {
    func terminalContextMenu(tabIndex: Int?) -> NSMenu
}

enum NativePaneDirection: UInt32 {
    case left = 0
    case right = 1
    case up = 2
    case down = 3
}

final class NativeSuspendedTerminalSession {
    let pane: RustTerminalPane
    let completion: NativeControlReply?

    init(pane: RustTerminalPane, completion: NativeControlReply?) {
        self.pane = pane
        self.completion = completion
    }
}

private let tmuxNativePaneIdBase = 1_000_000_000
private let tmuxNativeTabIdBase = 1_500_000_000
let nativeArtifactSidebarPaneId = 9_000_000_000_000_000

final class NativeTmuxSession {
    let gatewayPaneId: Int
    let gateway: RustTerminalPane
    let savedWorkspace: TerminalCoreSnapshot
    var nativePaneIds: [UInt32: Int] = [:]
    var tmuxPaneIds: [Int: UInt32] = [:]
    var nativeTabIds: [UInt32: Int] = [:]
    var tmuxWindowIds: [Int: UInt32] = [:]
    var bufferedOutput: [UInt32: Data] = [:]
    var latestPanes: [UInt32: TmuxPaneSnapshot] = [:]
    var lastClientGrid: (cols: Int, rows: Int)?
    var sessionName = "tmux"
    var socketPath = ""
    var executablePath = ""
    var serverPid: UInt32 = 0
    var activeWindowZoomed = false

    init(gatewayPaneId: Int, gateway: RustTerminalPane, savedWorkspace: TerminalCoreSnapshot) {
        self.gatewayPaneId = gatewayPaneId
        self.gateway = gateway
        self.savedWorkspace = savedWorkspace
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

final class NativeArtifactsPopoverViewController: NSViewController {
    private let artifacts: [NativeArtifactListItem]
    var onSelect: ((String) -> Void)?

    init(artifacts: [NativeArtifactListItem]) {
        self.artifacts = artifacts
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let width: CGFloat = 380
        let headerHeight: CGFloat = 42
        let rowHeight: CGFloat = 64
        let emptyHeight: CGFloat = 58
        let contentHeight =
            headerHeight
            + (artifacts.isEmpty ? emptyHeight : rowHeight * CGFloat(artifacts.count))
            + 10
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let header = NSTextField(labelWithString: "Recent Artifacts")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .labelColor
        header.frame = NSRect(x: 16, y: contentHeight - 31, width: width - 32, height: 18)
        container.addSubview(header)

        if artifacts.isEmpty {
            let empty = NSTextField(labelWithString: "No artifacts yet")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.alignment = .center
            empty.frame = NSRect(x: 16, y: 18, width: width - 32, height: 20)
            container.addSubview(empty)
        } else {
            var y = contentHeight - headerHeight - rowHeight
            for (index, artifact) in artifacts.enumerated() {
                let button = artifactButton(artifact, index: index)
                button.frame = NSRect(x: 10, y: y, width: width - 20, height: rowHeight - 4)
                container.addSubview(button)
                y -= rowHeight
            }
        }
        view = container
    }

    private func artifactButton(_ artifact: NativeArtifactListItem, index: Int) -> NSButton {
        let button = NSButton(frame: .zero)
        button.tag = index
        button.target = self
        button.action = #selector(selectArtifact(_:))
        button.bezelStyle = .regularSquare
        button.alignment = .left
        button.focusRingType = .none
        button.setAccessibilityLabel("Open \(artifact.title), version \(artifact.version)")

        let title = NSMutableAttributedString(
            string: artifact.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        let detail =
            "\n\(artifact.kind) · v\(artifact.version) · \(relativeTime(artifact.updatedAtMs))"
        title.append(
            NSAttributedString(
                string: detail,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(0.62),
                ]
            )
        )
        if !artifact.preview.isEmpty {
            title.append(
                NSAttributedString(
                    string: "\n\(artifact.preview)",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.labelColor.withAlphaComponent(0.78),
                    ]
                )
            )
        }
        button.attributedTitle = title
        button.cell?.wraps = false
        button.cell?.lineBreakMode = .byTruncatingTail
        return button
    }

    @objc private func selectArtifact(_ sender: NSButton) {
        guard artifacts.indices.contains(sender.tag) else {
            return
        }
        onSelect?(artifacts[sender.tag].id)
    }

    @discardableResult
    func performSelectionForSmoke(_ id: String) -> Bool {
        guard let artifact = artifacts.first(where: { $0.id == id }) else {
            return false
        }
        onSelect?(artifact.id)
        return true
    }

    private func relativeTime(_ milliseconds: UInt64) -> String {
        let updated = TimeInterval(milliseconds) / 1_000
        let elapsed = max(0, Date().timeIntervalSince1970 - updated)
        if elapsed < 60 {
            return "now"
        }
        if elapsed < 3_600 {
            return "\(Int(elapsed / 60))m"
        }
        if elapsed < 86_400 {
            return "\(Int(elapsed / 3_600))h"
        }
        return "\(Int(elapsed / 86_400))d"
    }
}

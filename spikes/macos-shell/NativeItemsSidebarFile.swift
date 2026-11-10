import AppKit

/// A file the items sidebar shows in place rather than handing to its app:
/// Markdown drawn as a page, and plain text as it is.
struct NativeSidebarFile: Equatable {
    /// Larger files go to their app.
    static let sizeLimit = 2_000_000
    private static let markdown: Set<String> = ["md", "markdown"]
    private static let text: Set<String> = ["txt", "text"]

    let url: URL
    /// When the file was last written, to draw it again once it changes.
    let modified: Date

    /// The file at `url` as the sidebar would show it; nil for any other
    /// kind of file, a folder, or one too large.
    init?(_ url: URL) {
        let kind = url.pathExtension.lowercased()
        guard url.isFileURL, Self.markdown.contains(kind) || Self.text.contains(kind),
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            ]),
            values.isRegularFile == true, (values.fileSize ?? 0) <= Self.sizeLimit
        else {
            return nil
        }
        self.url = url
        modified = values.contentModificationDate ?? .distantPast
    }

    var plain: Bool {
        Self.text.contains(url.pathExtension.lowercased())
    }

    /// Names the file as written at one moment.
    var key: String {
        "\(url.path)@\(Int(modified.timeIntervalSince1970 * 1000))"
    }

    /// The path with the home folder as `~`.
    var shortPath: String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

/// The strip along the items sidebar's inner edge that drags it wider or
/// narrower. A double-click gives the sidebar its own width back.
final class NativeSidebarResizeGrip: NSView {
    static let width: CGFloat = 7

    /// The width the drag asks for, and whether the drag has ended.
    var onDrag: ((CGFloat, Bool) -> Void)?
    var onReset: (() -> Void)?
    private var start: (x: CGFloat, width: CGFloat)?
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Resize the Items Sidebar")
        toolTip = "Drag to resize · double-click to reset"
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The width a drag from `start` to the pointer at `x` asks for: the
    /// sidebar is on the right, so a drag to the left widens it.
    static func width(start: (x: CGFloat, width: CGFloat), x: CGFloat) -> CGFloat {
        start.width + start.x - x
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering || start != nil else {
            return
        }
        NativePageStyle.violet.withAlphaComponent(0.7).setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            start = nil
            onReset?()
            return
        }
        start = (event.locationInWindow.x, superview?.bounds.width ?? 0)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else {
            return
        }
        onDrag?(Self.width(start: start, x: event.locationInWindow.x), false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else {
            return
        }
        self.start = nil
        needsDisplay = true
        onDrag?(Self.width(start: start, x: event.locationInWindow.x), true)
    }
}

/// The width the items sidebar takes, open: what was asked for, no narrower
/// than its rows read at and no wider than leaves the panes `panes` of
/// `room`.
func nativeItemsSidebarWidth(wanted: CGFloat, room: CGFloat, panes: CGFloat = 320) -> CGFloat {
    let least = NativeItemsSidebarView.minWidth
    return max(least, min(wanted, max(least, room - panes)))
}

func runNativeSidebarFileSelfTests() -> Bool {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("satin-sidebar-file-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func write(_ name: String, _ bytes: Int) -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data(count: bytes))
        return url
    }
    let page = NativeSidebarFile(write("plan.md", 12))
    let text = NativeSidebarFile(write("notes.TXT", 12))
    guard let page, let text, !page.plain, text.plain, page.key != text.key,
        NativeSidebarFile(write("shot.png", 12)) == nil,
        NativeSidebarFile(write("huge.md", NativeSidebarFile.sizeLimit + 1)) == nil,
        NativeSidebarFile(folder) == nil,
        NativeSidebarFile(folder.appendingPathComponent("missing.md")) == nil,
        NativeSidebarFile(URL(string: "https://example.com/readme.md") ?? folder) == nil
    else {
        return false
    }
    // A drag on the grip of a sidebar 300 wide, 60 to the left: every step
    // asks for the wider width, and the last one says the drag ended.
    let sidebar = NativeItemsSidebarView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
    var asked: [(CGFloat, Bool)] = []
    var reset = 0
    sidebar.onResize = { asked.append(($0, $1)) }
    sidebar.onResetWidth = { reset += 1 }
    func mouse(_ type: NSEvent.EventType, x: CGFloat, clicks: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: 200), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
    }
    guard let grip = sidebar.subviews.compactMap({ $0 as? NativeSidebarResizeGrip }).first,
        let down = mouse(.leftMouseDown, x: 900), let drag = mouse(.leftMouseDragged, x: 870),
        let up = mouse(.leftMouseUp, x: 840),
        let double = mouse(.leftMouseDown, x: 900, clicks: 2)
    else {
        return false
    }
    grip.mouseDown(with: down)
    grip.mouseDragged(with: drag)
    grip.mouseUp(with: up)
    grip.mouseDown(with: double)
    grip.mouseUp(with: up)
    guard asked.map(\.0) == [330, 360], asked.map(\.1) == [false, true], reset == 1 else {
        return false
    }
    return NativeSidebarResizeGrip.width(start: (x: 900, width: 300), x: 840) == 360
        && NativeSidebarResizeGrip.width(start: (x: 900, width: 300), x: 960) == 240
        && nativeItemsSidebarWidth(wanted: 420, room: 1200) == 420
        && nativeItemsSidebarWidth(wanted: 900, room: 1200) == 880
        && nativeItemsSidebarWidth(wanted: 100, room: 1200) == NativeItemsSidebarView.minWidth
        && nativeItemsSidebarWidth(wanted: 420, room: 300) == NativeItemsSidebarView.minWidth
}

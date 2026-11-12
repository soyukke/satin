import AppKit

/// A file the items sidebar shows in place rather than handing to its app:
/// Markdown drawn as a page, an image as it is, and any other file that
/// reads as text, such as source code, as that text.
struct NativeSidebarFile: Equatable {
    /// Larger files go to their app.
    static let sizeLimit = 2_000_000
    static let imageSizeLimit = 20_000_000
    private static let markdown: Set<String> = ["md", "markdown"]
    private static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg"]

    let url: URL
    /// When the file was last written, to draw it again once it changes.
    let modified: Date
    let form: NativePageForm

    /// The file at `url` as the sidebar would show it; nil for a folder, a
    /// file too large, or one that is neither an image nor text.
    init?(_ url: URL) {
        guard url.isFileURL,
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            ]),
            values.isRegularFile == true
        else {
            return nil
        }
        let kind = url.pathExtension.lowercased()
        let size = values.fileSize ?? 0
        if Self.images.contains(kind) {
            guard size <= Self.imageSizeLimit else { return nil }
            form = .image
        } else {
            guard size <= Self.sizeLimit else { return nil }
            if Self.markdown.contains(kind) {
                form = .markdown
            } else if Self.readsAsText(url) {
                form = .text
            } else {
                return nil
            }
        }
        self.url = url
        modified = values.contentModificationDate ?? .distantPast
    }

    /// Whether the file's first bytes are text.
    private static func readsAsText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        return nativeSidebarIsText((try? handle.read(upToCount: 8192)) ?? Data())
    }

    /// Whether the file has been written since it was read here.
    var changed: Bool {
        let now = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return now?.contentModificationDate != modified
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

/// Whether the bytes a file starts with read as UTF-8 text: none of them is
/// NUL, and all decode but a character the sample cut off at its end.
func nativeSidebarIsText(_ head: Data) -> Bool {
    guard !head.contains(0) else {
        return false
    }
    return (0...3).contains { cut in
        cut <= head.count && String(data: head.dropLast(cut), encoding: .utf8) != nil
    }
}

/// The strip along a sidebar's inner edge that drags it wider or narrower,
/// down to its rail and back out of it. A double-click gives the sidebar
/// its own width back.
final class NativeSidebarResizeGrip: NSView {
    static let width: CGFloat = 7

    /// Whether the sidebar is the one on the left, whose inner edge is its
    /// right one.
    private let onLeft: Bool

    /// The width the drag asks for, and whether the drag has ended.
    var onDrag: ((CGFloat, Bool) -> Void)?
    var onReset: (() -> Void)?
    private var start: (x: CGFloat, width: CGFloat)?
    private var hovering = false
    private var hoverArea: NSTrackingArea?

    init(onLeft: Bool, label: String) {
        self.onLeft = onLeft
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(label)
        toolTip = "Drag to resize or fold · double-click to reset"
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The width a drag from `start` to the pointer at `x` asks for: a drag
    /// away from the window's edge the sidebar is on widens it.
    static func width(
        start: (x: CGFloat, width: CGFloat), x: CGFloat, onLeft: Bool = false
    ) -> CGFloat {
        start.width + (onLeft ? x - start.x : start.x - x)
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
        NSRect(x: onLeft ? bounds.width - 2 : 0, y: 0, width: 2, height: bounds.height).fill()
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
        onDrag?(Self.width(start: start, x: event.locationInWindow.x, onLeft: onLeft), false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else {
            return
        }
        self.start = nil
        needsDisplay = true
        onDrag?(Self.width(start: start, x: event.locationInWindow.x, onLeft: onLeft), true)
    }
}

/// The width the items sidebar takes, open: what was asked for, no narrower
/// than its rows read at and no wider than leaves the panes `panes` of
/// `room`.
func nativeItemsSidebarWidth(wanted: CGFloat, room: CGFloat, panes: CGFloat = 320) -> CGFloat {
    nativeSidebarWidth(
        wanted: wanted, least: NativeItemsSidebarView.minWidth, room: room, panes: panes)
}

func runNativeSidebarFileSelfTests() -> Bool {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("satin-sidebar-file-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    func write(_ name: String, _ bytes: Int, _ byte: UInt8 = 0x61) -> URL {
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(
            atPath: url.path, contents: Data(repeating: byte, count: bytes))
        return url
    }
    let page = NativeSidebarFile(write("plan.md", 12))
    let text = NativeSidebarFile(write("notes.TXT", 12))
    let source = NativeSidebarFile(write("Visits.java", 12))
    let image = NativeSidebarFile(write("shot.JPG", 12, 0))
    guard let page, let text, let source, let image,
        page.form == .markdown, text.form == .text, source.form == .text, image.form == .image,
        page.key != text.key, !page.changed,
        // A file with no extension is read by what is in it.
        NativeSidebarFile(write("Makefile", 12))?.form == .text,
        NativeSidebarFile(write("visits.bin", 12, 0)) == nil,
        NativeSidebarFile(write("huge.md", NativeSidebarFile.sizeLimit + 1)) == nil,
        NativeSidebarFile(write("huge.java", NativeSidebarFile.sizeLimit + 1)) == nil,
        NativeSidebarFile(write("large.png", NativeSidebarFile.sizeLimit + 1, 0))?.form == .image,
        nativeSidebarIsText(Data()), nativeSidebarIsText(Data("訪問 visits".utf8)),
        // A character cut off where the sample ends is still text.
        nativeSidebarIsText(Data("visits 訪問".utf8).dropLast(2)),
        !nativeSidebarIsText(Data([0x76, 0xFF, 0xFE, 0x76, 0x76, 0x76])),
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
    // The windows sidebar is on the left: a drag to the right widens it, and
    // one most of the way to the left edge asks for less than its rail.
    let windows = NativeWindowsSidebarView(frame: NSRect(x: 0, y: 0, width: 264, height: 400))
    var wanted: [CGFloat] = []
    windows.onResize = { width, _ in wanted.append(width) }
    guard let edge = windows.subviews.compactMap({ $0 as? NativeSidebarResizeGrip }).first,
        let press = mouse(.leftMouseDown, x: 262), let wider = mouse(.leftMouseDragged, x: 300),
        let narrower = mouse(.leftMouseUp, x: 40)
    else {
        return false
    }
    edge.mouseDown(with: press)
    edge.mouseDragged(with: wider)
    edge.mouseUp(with: narrower)
    guard wanted == [302, 42] else {
        return false
    }
    return NativeSidebarResizeGrip.width(start: (x: 900, width: 300), x: 840) == 360
        && NativeSidebarResizeGrip.width(start: (x: 900, width: 300), x: 960) == 240
        && NativeSidebarResizeGrip.width(start: (x: 264, width: 264), x: 300, onLeft: true) == 300
        && NativeSidebarResizeGrip.width(start: (x: 264, width: 264), x: 90, onLeft: true) == 90
        && nativeItemsSidebarWidth(wanted: 420, room: 1200) == 420
        && nativeItemsSidebarWidth(wanted: 900, room: 1200) == 880
        && nativeItemsSidebarWidth(wanted: 100, room: 1200) == NativeItemsSidebarView.minWidth
        && nativeItemsSidebarWidth(wanted: 420, room: 300) == NativeItemsSidebarView.minWidth
}

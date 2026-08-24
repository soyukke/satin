import AppKit
import Darwin
import Foundation

struct SkiaRenderGeometry {
    let originX: Float
    let originY: Float
    let contentWidth: Float
    let contentHeight: Float
    let cellWidth: Float
    let cellHeight: Float
}

protocol NativePane: AnyObject {
    var kind: NativePaneMode { get }

    func resize(grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int))
    func write(_ data: Data)
    func drain() -> Bool
    func isExited() -> Bool
    func wakeupFD() -> Int32
    func renderHandle() -> UnsafeMutableRawPointer?
    func controlScreenText() -> String
    func controlImageCount() -> Int
}

struct NativeFinderEditorLaunch {
    let paths: [String]
    let workingDirectory: String

    init?(paths: [String]) {
        var seen = Set<String>()
        var normalized: [String] = []
        var totalBytes = 0
        for path in paths {
            guard (path as NSString).isAbsolutePath else {
                continue
            }
            let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: resolved),
                resolved.unicodeScalars.allSatisfy({
                    !CharacterSet.controlCharacters.contains($0)
                }),
                seen.insert(resolved).inserted
            else {
                continue
            }
            guard normalized.count < 254 else {
                return nil
            }
            totalBytes += resolved.utf8.count
            guard totalBytes <= 12 * 1_024 else {
                return nil
            }
            normalized.append(resolved)
        }
        guard let first = normalized.first else {
            return nil
        }
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: first, isDirectory: &isDirectory)
        self.paths = normalized
        self.workingDirectory =
            isDirectory.boolValue
            ? first
            : URL(fileURLWithPath: first).deletingLastPathComponent().path
    }

    func startupCommand(editor: String) -> [String] {
        [editor, "--"] + paths
    }

    static func runSelfTests() -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("satin-finder-launch-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("file with spaces.txt")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("finder launch".utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: root) }
            guard let launch = Self(paths: [file.path, file.path]) else {
                return false
            }
            return launch.paths == [file.path]
                && launch.workingDirectory == root.path
                && launch.startupCommand(editor: "nvim") == ["nvim", "--", file.path]
                && Self(paths: [root.path])?.workingDirectory == root.path
                && Self(paths: ["relative.txt"]) == nil
        } catch {
            return false
        }
    }
}

struct NativeNeovimLaunchConfiguration: Encodable {
    let cwd: String?
    let executable: String?
    let arguments: [String]
    let environment: [String: String]
}

struct NativeMouseInput {
    let button: String
    let action: String
    let modifier: String
    let grid: Int64
    let row: Int64
    let col: Int64
    var surfaceX: Float = 0
    var surfaceY: Float = 0
    var cellWidth: UInt32 = 1
    var cellHeight: UInt32 = 1
}

enum NativeTerminalSelectionEvent {
    case press(NativeMouseInput)
    case drag(NativeMouseInput, rectangular: Bool)
    case release(NativeMouseInput)
    case autoscroll(NativeMouseInput, rectangular: Bool)
    case cancel
}

enum NativeMouseHandling: Equatable {
    case unhandled
    case handled
    case messageSelection
}

enum NativePaneMode: Equatable {
    case terminal
    case neovim

    static func current() -> Self {
        ProcessInfo.processInfo.environment["SATIN_NATIVE_PANE"] == "nvim" ? .neovim : .terminal
    }

    init(sessionValue: String?) {
        self = sessionValue == "neovim" ? .neovim : .terminal
    }

    var sessionValue: String {
        switch self {
        case .terminal:
            "terminal"
        case .neovim:
            "neovim"
        }
    }
}

class RustTerminalPane: NativePane {
    let kind = NativePaneMode.terminal
    let handle: UnsafeMutableRawPointer
    private let repeatedReturnGate = TerminalReturnRepeatGate()

    init?(
        grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
        cwd: String? = nil,
        shell: String? = nil,
        environment: [String: String] = [:],
        startupCommand: [String] = [],
        directStartup: Bool = false
    ) {
        let configuration = NativeTerminalSpawnConfiguration(
            cwd: cwd,
            shell: shell?.isEmpty == false ? shell : nil,
            environment: environment,
            startup_command: startupCommand,
            direct_startup: directStartup
        )
        guard let data = try? JSONEncoder().encode(configuration),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let handle = json.withCString { value in
            satinRuntimeCreateConfig(
                clampedUInt16(grid.rows),
                clampedUInt16(grid.cols),
                clampedUInt16(grid.widthPixels),
                clampedUInt16(grid.heightPixels),
                value
            )
        }
        guard let handle else {
            NativeLog.runtimeError("terminal_runtime_create_failed")
            return nil
        }
        self.handle = handle
    }

    fileprivate init(externalHandle: UnsafeMutableRawPointer) {
        self.handle = externalHandle
    }

    deinit {
        satinRuntimeDestroy(handle)
    }

    func resize(grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int)) {
        _ = satinRuntimeResize(
            handle,
            clampedUInt16(grid.rows),
            clampedUInt16(grid.cols),
            clampedUInt16(grid.widthPixels),
            clampedUInt16(grid.heightPixels)
        )
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            _ = satinRuntimeWrite(handle, base, buffer.count)
        }
    }

    func key(_ event: NSEvent, released: Bool) -> Bool {
        let isReturn = terminalReturnKeyCodes.contains(event.keyCode)
        let promptState = satinRuntimeTmuxShellPromptState(handle)
        let managesShellRepeat = isReturn && managesRepeatedReturn(promptState: promptState)
        return repeatedReturnGate.handle(
            event,
            released: released,
            isReturn: isReturn,
            managesRepeat: managesShellRepeat,
            currentPromptGeneration: satinRuntimeTmuxPromptGeneration(handle)
        ) { [weak self] event, released in
            self?.forwardKey(event, released: released) ?? false
        }
    }

    func managesRepeatedReturn(promptState: UInt8) -> Bool {
        isAwaitingRepeatedReturnPrompt
            || canReleaseRepeatedReturn(promptState: promptState)
    }

    func canReleaseRepeatedReturn(promptState: UInt8) -> Bool {
        promptState != 0
            && satinRuntimeInteractiveShellOwnsForeground(handle) != 0
    }

    func forwardKey(_ event: NSEvent, released: Bool) -> Bool {
        let text = terminalKeyText(event)
        let unshifted = event.charactersIgnoringModifiers ?? ""
        let textData = text.map { Data($0.utf8) }
        let unshiftedData = Data(unshifted.utf8)
        return unshiftedData.withUnsafeBytes { unshiftedBuffer in
            let unshiftedBase = unshiftedBuffer.bindMemory(to: UInt8.self).baseAddress
            if let textData {
                return textData.withUnsafeBytes { textBuffer in
                    satinRuntimeKey(
                        handle,
                        event.keyCode,
                        terminalModifierMask(event.modifierFlags),
                        textBuffer.bindMemory(to: UInt8.self).baseAddress,
                        textBuffer.count,
                        unshiftedBase,
                        unshiftedBuffer.count,
                        event.isARepeat ? 1 : 0,
                        released ? 1 : 0
                    ) != 0
                }
            }
            return satinRuntimeKey(
                handle,
                event.keyCode,
                terminalModifierMask(event.modifierFlags),
                nil,
                0,
                unshiftedBase,
                unshiftedBuffer.count,
                event.isARepeat ? 1 : 0,
                released ? 1 : 0
            ) != 0
        }
    }

    func writeText(_ text: String) {
        withUtf8(text) { bytes, count in
            _ = satinRuntimeText(handle, bytes, count)
        }
    }

    func paste(_ text: String) {
        withUtf8(text) { bytes, count in
            _ = satinRuntimePaste(handle, bytes, count)
        }
    }

    func mouse(_ input: NativeMouseInput) -> Bool {
        satinRuntimeMouse(
            handle,
            terminalMouseAction(input.action),
            terminalMouseButton(input.button, action: input.action),
            terminalModifierMask(input.modifier),
            input.surfaceX,
            input.surfaceY,
            input.cellWidth,
            input.cellHeight
        ) != 0
    }

    func isMouseTracking() -> Bool {
        satinRuntimeMouseTracking(handle) != 0
    }

    func focus(_ focused: Bool) {
        if !focused {
            resetRepeatedReturnBackpressure()
        }
        _ = satinRuntimeFocus(handle, focused ? 1 : 0)
    }

    func selectAll() {
        _ = satinRuntimeSelectAll(handle)
    }

    func clearSelection() {
        _ = satinRuntimeClearSelection(handle)
    }

    func selectedText() -> String? {
        ownedRustString(satinRuntimeSelectedText(handle))
    }

    func hyperlink(row: Int, col: Int) -> String? {
        ownedRustString(
            satinRuntimeHyperlink(
                handle,
                UInt32(max(0, row)),
                clampedUInt16(col + 1) - 1
            )
        )
    }

    func title() -> String? {
        ownedRustString(satinRuntimeTitle(handle))
    }

    func takeBellCount() -> UInt64 {
        satinRuntimeTakeBellCount(handle)
    }

    func find(_ query: String, backwards: Bool) -> Bool {
        query.withCString { value in
            satinRuntimeFind(handle, value, backwards ? 1 : 0) != 0
        }
    }

    func setOptionAsAlt(_ enabled: Bool) {
        _ = satinRuntimeSetOptionAsAlt(handle, enabled ? 1 : 0)
    }

    @discardableResult
    func drain() -> Bool {
        let changed = satinRuntimeDrain(handle) != 0
        if changed {
            forwardPendingReturnAtReadyPrompt()
        }
        return changed
    }

    var isAwaitingRepeatedReturnPrompt: Bool {
        repeatedReturnGate.isAwaitingPrompt
    }

    func forwardPendingReturnAtReadyPrompt() {
        let promptState = satinRuntimeTmuxShellPromptState(handle)
        let promptGeneration = satinRuntimeTmuxPromptGeneration(handle)
        let semanticPromptSeen = satinRuntimeTmuxSemanticPromptSeen(handle) != 0
        repeatedReturnGate.forwardPendingIfReady(
            managesRepeat: canReleaseRepeatedReturn(promptState: promptState),
            currentPromptGeneration: promptGeneration,
            fallbackPromptReady: !semanticPromptSeen && promptState == 2
        ) { [weak self] event in
            _ = self?.key(event, released: false)
        }
    }

    func resetRepeatedReturnBackpressure() {
        repeatedReturnGate.reset(
            promptGeneration: satinRuntimeTmuxPromptGeneration(handle)
        )
    }

    func isExited() -> Bool {
        satinRuntimeExited(handle) != 0
    }

    func wakeupFD() -> Int32 {
        satinRuntimeWakeupFd(handle)
    }

    func currentWorkingDirectory() -> String? {
        guard let pointer = satinRuntimeCwd(handle) else {
            return nil
        }
        defer {
            satinStringFree(pointer)
        }

        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
    }

    func scroll(rows: Int) -> Int {
        satinRuntimeScroll(handle, rows)
    }

    func rendererScrollPosition() -> Double {
        Double(satinRuntimeRendererScrollPosition(handle))
    }

    func cursorPosition() -> (x: Int, y: Int)? {
        let packed = satinRuntimeCursorPosition(handle)
        guard packed != UInt32.max else {
            return nil
        }
        return (Int(packed & 0xffff), Int(packed >> 16))
    }

    func renderHandle() -> UnsafeMutableRawPointer? {
        handle
    }

    func controlScreenText() -> String {
        ownedRustString(satinRuntimeScreenText(handle)) ?? ""
    }

    func controlImageCount() -> Int {
        satinRuntimeKittyPlacementCount(handle)
    }

    func takeTmuxEvent() -> TmuxControlEvent? {
        guard let pointer = satinRuntimeTakeTmuxEventJson(handle) else {
            return nil
        }
        defer { satinStringFree(pointer) }
        return try? JSONDecoder().decode(
            TmuxControlEvent.self, from: Data(String(cString: pointer).utf8))
    }

    @discardableResult
    func tmuxCommand(_ command: String) -> Bool {
        command.withCString { value in
            satinRuntimeTmuxCommand(handle, value) != 0
        }
    }

}

final class RustTmuxPane: RustTerminalPane {
    let tmuxPaneId: UInt32
    private weak var gateway: RustTerminalPane?
    private var currentShellCommand: String?
    private var shellOwnsPane = false
    private var semanticPromptOwnsPane = false

    init?(
        grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
        paneId: UInt32,
        gateway: RustTerminalPane
    ) {
        guard
            let handle = satinRuntimeCreateExternal(
                clampedUInt16(grid.rows),
                clampedUInt16(grid.cols),
                clampedUInt16(grid.widthPixels),
                clampedUInt16(grid.heightPixels)
            )
        else {
            return nil
        }
        self.tmuxPaneId = paneId
        self.gateway = gateway
        super.init(externalHandle: handle)
    }

    override func write(_ data: Data) {
        _ = writeThroughTmux(data)
    }

    @discardableResult
    func writeThroughTmux(_ data: Data) -> Bool {
        guard let gateway else {
            return false
        }
        let sent = data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return satinRuntimeTmuxWrite(
                gateway.handle,
                handle,
                tmuxPaneId,
                base,
                buffer.count
            ) != 0
        }
        if sent, data.contains(10) || data.contains(13) {
            semanticPromptOwnsPane = false
        }
        return sent
    }

    override func writeText(_ text: String) {
        write(Data(text.utf8))
    }

    func syncCursor(_ snapshot: TmuxPaneSnapshot) {
        let absoluteRow = Int(snapshot.cursor_y)
        let row =
            snapshot.origin_mode
            ? max(0, absoluteRow - Int(snapshot.scroll_region_upper))
            : absoluteRow
        let visibility = snapshot.cursor_visible ? "h" : "l"
        let column = Int(snapshot.cursor_x)
        _ = feed(Data("\u{1b}[\(row + 1);\(column + 1)H\u{1b}[?25\(visibility)".utf8))
    }

    func setCurrentCommand(_ command: String) {
        let commandIsShell = tmuxCommandIsShell(command)
        if commandIsShell {
            if currentShellCommand != command {
                currentShellCommand = command
                _ = satinRuntimeTmuxResetPromptTracking(handle)
                resetRepeatedReturnBackpressure()
                semanticPromptOwnsPane = false
            }
            shellOwnsPane = true
            return
        }
        if isAwaitingRepeatedReturnPrompt {
            return
        }
        shellOwnsPane = false
        semanticPromptOwnsPane = false
        resetRepeatedReturnBackpressure()
    }

    override func canReleaseRepeatedReturn(promptState: UInt8) -> Bool {
        promptState != 0 && (shellOwnsPane || semanticPromptOwnsPane)
    }

    override func forwardKey(_ event: NSEvent, released: Bool) -> Bool {
        guard let gateway else {
            return false
        }
        let textData = terminalKeyText(event).map { Data($0.utf8) }
        let unshiftedData = Data((event.charactersIgnoringModifiers ?? "").utf8)
        let sent = unshiftedData.withUnsafeBytes { unshiftedBuffer in
            let unshifted = unshiftedBuffer.bindMemory(to: UInt8.self).baseAddress
            if let textData {
                return textData.withUnsafeBytes { textBuffer in
                    satinRuntimeTmuxKey(
                        gateway.handle,
                        handle,
                        tmuxPaneId,
                        event.keyCode,
                        terminalModifierMask(event.modifierFlags),
                        textBuffer.bindMemory(to: UInt8.self).baseAddress,
                        textBuffer.count,
                        unshifted,
                        unshiftedBuffer.count,
                        event.isARepeat ? 1 : 0,
                        released ? 1 : 0
                    ) != 0
                }
            }
            return satinRuntimeTmuxKey(
                gateway.handle,
                handle,
                tmuxPaneId,
                event.keyCode,
                terminalModifierMask(event.modifierFlags),
                nil,
                0,
                unshifted,
                unshiftedBuffer.count,
                event.isARepeat ? 1 : 0,
                released ? 1 : 0
            ) != 0
        }
        if sent, !released, terminalReturnKeyCodes.contains(event.keyCode) {
            semanticPromptOwnsPane = false
        }
        return sent
    }

    override func paste(_ text: String) {
        _ = pasteThroughTmux(text)
    }

    @discardableResult
    func pasteThroughTmux(_ text: String) -> Bool {
        guard let gateway else {
            return false
        }
        let sent = withUtf8(text) { bytes, count in
            satinRuntimeTmuxPaste(
                gateway.handle,
                handle,
                tmuxPaneId,
                bytes,
                count
            ) != 0
        }
        if sent, text.contains("\n") || text.contains("\r") {
            semanticPromptOwnsPane = false
        }
        return sent
    }

    override func mouse(_ input: NativeMouseInput) -> Bool {
        guard let gateway else {
            return false
        }
        return satinRuntimeTmuxMouse(
            gateway.handle,
            handle,
            tmuxPaneId,
            terminalMouseAction(input.action),
            terminalMouseButton(input.button, action: input.action),
            terminalModifierMask(input.modifier),
            input.surfaceX,
            input.surfaceY,
            input.cellWidth,
            input.cellHeight
        ) != 0
    }

    override func focus(_ focused: Bool) {
        guard let gateway else {
            return
        }
        if !focused {
            resetRepeatedReturnBackpressure()
        }
        _ = satinRuntimeTmuxFocus(
            gateway.handle,
            handle,
            tmuxPaneId,
            focused ? 1 : 0
        )
    }

    @discardableResult
    func feed(_ data: Data) -> Bool {
        guard gateway != nil else {
            return false
        }
        let previousPromptGeneration = satinRuntimeTmuxPromptGeneration(handle)
        let fed = data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return false
            }
            return satinRuntimeTmuxFeedPane(
                handle,
                base,
                buffer.count
            ) != 0
        }
        if fed {
            if satinRuntimeTmuxPromptGeneration(handle) != previousPromptGeneration {
                semanticPromptOwnsPane = true
                shellOwnsPane = true
            }
            forwardPendingReturnAtReadyPrompt()
        }
        return fed
    }

}

final class RustNeovimPane: NativePane {
    let kind = NativePaneMode.neovim
    private let handle: UnsafeMutableRawPointer

    init?(
        grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int),
        cwd: String? = nil,
        executable: String? = nil,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) {
        let configuration = NativeNeovimLaunchConfiguration(
            cwd: cwd,
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        guard let data = try? JSONEncoder().encode(configuration),
            let json = String(data: data, encoding: .utf8)
        else {
            NativeLog.runtimeError("neovim_launch_configuration_encode_failed")
            return nil
        }
        let handle = json.withCString { value in
            satinNvimCreateWithConfig(
                clampedUInt16(grid.rows),
                clampedUInt16(grid.cols),
                clampedUInt16(grid.widthPixels),
                clampedUInt16(grid.heightPixels),
                value
            )
        }
        guard let handle = handle else {
            NativeLog.runtimeError("neovim_runtime_create_failed")
            return nil
        }
        self.handle = handle
    }

    deinit {
        satinNvimDestroy(handle)
    }

    func resize(grid: (rows: Int, cols: Int, widthPixels: Int, heightPixels: Int)) {
        _ = satinNvimResize(
            handle,
            clampedUInt16(grid.rows),
            clampedUInt16(grid.cols),
            clampedUInt16(grid.widthPixels),
            clampedUInt16(grid.heightPixels)
        )
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            _ = satinNvimInput(handle, base, buffer.count)
        }
    }

    func mouse(_ input: NativeMouseInput) -> NativeMouseHandling {
        let result = input.button.withCString { button in
            input.action.withCString { action in
                input.modifier.withCString { modifier in
                    satinNvimMouse(
                        handle,
                        button,
                        action,
                        modifier,
                        input.grid,
                        input.row,
                        input.col
                    )
                }
            }
        }
        switch result {
        case 2:
            return .messageSelection
        case 1:
            return .handled
        default:
            return .unhandled
        }
    }

    func takeMessageSelectionText() -> String? {
        ownedRustString(satinNvimTakeMessageSelectionText(handle))
    }

    func runCommand(_ command: String) -> Bool {
        command.withCString { value in
            satinNvimCommand(handle, value) != 0
        }
    }

    @discardableResult
    func drain() -> Bool {
        satinNvimDrain(handle) != 0
    }

    func isExited() -> Bool {
        satinNvimExited(handle) != 0
    }

    func exitCode() -> Int {
        let code = satinNvimExitCode(handle)
        return code == Int32.min ? 1 : Int(code)
    }

    func wakeupFD() -> Int32 {
        satinNvimWakeupFd(handle)
    }

    func rendererModel() -> NeovideRendererModelSnapshot? {
        decode(satinNvimRendererModelJson(handle), as: NeovideRendererModelSnapshot.self)
    }

    func uiState() -> NeovideUiStateSnapshot? {
        decode(satinNvimUiStateJson(handle), as: NeovideUiStateSnapshot.self)
    }

    func renderHandle() -> UnsafeMutableRawPointer? {
        handle
    }

    func controlScreenText() -> String {
        guard let model = rendererModel() else {
            return ""
        }
        return model.windows
            .filter { !$0.hidden }
            .sorted { ($0.zindex, $0.grid_id) < ($1.zindex, $1.grid_id) }
            .flatMap { window in window.lines.compactMap { $0?.text } }
            .joined(separator: "\n")
    }

    func controlImageCount() -> Int {
        satinNvimKittyPlacementCount(handle)
    }

    private func decode<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, as type: T.Type)
        -> T?
    {
        guard let pointer else {
            return nil
        }
        defer {
            satinStringFree(pointer)
        }

        let json = String(cString: pointer)
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            NativeLog.runtimeError("neovim_snapshot_decode_failed error=\(error)")
            return nil
        }
    }
}

func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

func tmuxCommandArgument(_ value: String) -> String {
    let octal = value.utf8.map { String(format: "\\%03o", Int($0)) }.joined()
    return "\"\(octal)\""
}

func isLocalTmuxEndpoint(socketPath: String, serverPid: UInt32) -> Bool {
    guard serverPid > 0 else {
        return false
    }
    var status = stat()
    guard lstat(socketPath, &status) == 0,
        status.st_mode & S_IFMT == S_IFSOCK
    else {
        return false
    }
    if kill(pid_t(serverPid), 0) == 0 {
        return true
    }
    return errno == EPERM
}

func vimSingleQuote(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
}

private func terminalMouseAction(_ action: String) -> UInt32 {
    switch action {
    case "release":
        return 1
    case "drag":
        return 2
    default:
        return 0
    }
}

private func terminalMouseButton(_ button: String, action: String) -> Int32 {
    switch button {
    case "left":
        return 0
    case "right":
        return 1
    case "middle":
        return 2
    case "wheel":
        return action == "up" ? 3 : 4
    default:
        return -1
    }
}

private func withUtf8<Result>(
    _ text: String,
    _ body: (UnsafePointer<UInt8>?, Int) -> Result
) -> Result {
    let data = Data(text.utf8)
    return data.withUnsafeBytes { buffer in
        body(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
    }
}

private func ownedRustString(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
    guard let pointer else {
        return nil
    }
    defer {
        satinStringFree(pointer)
    }
    return String(cString: pointer)
}

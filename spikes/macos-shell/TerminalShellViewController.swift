import AppKit
import CoreGraphics
import Darwin
import Foundation
import MetalKit
import OSLog
import QuartzCore

let nativeApplicationName =
    Bundle.main.object(
        forInfoDictionaryKey: "CFBundleDisplayName"
    ) as? String ?? "Satin"
let nativeApplicationDataDirectoryName =
    Bundle.main.object(
        forInfoDictionaryKey: "SatinDataDirectoryName"
    ) as? String ?? "Satin"
let nativeIsDevelopmentBuild =
    Bundle.main.object(
        forInfoDictionaryKey: "SatinDevelopmentBuild"
    ) as? Bool ?? false

enum NativeLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dev.soyukke.satin"
    private static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    private static let runtime = Logger(subsystem: subsystem, category: "runtime")
    private static let session = Logger(subsystem: subsystem, category: "session")

    static func started() {
        lifecycle.info("application_started")
    }

    static func lifecycleError(_ message: String) {
        lifecycle.error("\(message, privacy: .public)")
    }

    static func lifecycleInfo(_ message: String) {
        lifecycle.info("\(message, privacy: .public)")
    }

    static func runtimeError(_ message: String) {
        runtime.error("\(message, privacy: .public)")
    }

    static func sessionWarning(_ message: String) {
        session.warning("\(message, privacy: .public)")
    }
}

let ffiSplitVertical: UInt32 = 0
let ffiSplitHorizontal: UInt32 = 1
let defaultTerminalFontSize = CGFloat(nativeDefaultFontSize)
let minTerminalFontSize = CGFloat(nativeMinimumFontSize)
let maxTerminalFontSize = CGFloat(nativeMaximumFontSize)
let maxOutputScrollAnimationRows = 12
let maxTerminalBottomInputSmokePosition = 0.1
let maxNvimCursorMoveSmokeGrowth = 0.001
let nvimStartupCommandDelay: TimeInterval = 0.4
let nvimStartupCwdCorrectionDelay: TimeInterval = 1.0
let nvimSmokeReadyMarker = "NVSMOKE_READY"
let nvimJumpBaselineDelay: TimeInterval = 0.5
let currentSessionSchemaVersion = 4

enum NativePaneDividerAxis: String {
    case vertical
    case horizontal

    var cursor: NSCursor {
        switch self {
        case .vertical:
            .resizeLeftRight
        case .horizontal:
            .resizeUpDown
        }
    }
}

struct NativePaneDivider {
    private static let hitWidth: CGFloat = 10
    private static let indicatorWidth: CGFloat = 2
    private static let minimumPaneLength: CGFloat = 80

    let axis: NativePaneDividerAxis
    let containerRect: NSRect
    let firstPaneId: Int
    let secondPaneId: Int
    var ratio: CGFloat

    var hitRect: NSRect {
        dividerRect(width: Self.hitWidth)
    }

    var indicatorRect: NSRect {
        dividerRect(width: Self.indicatorWidth)
    }

    func ratio(at point: NSPoint) -> CGFloat {
        let length = axis == .vertical ? containerRect.width : containerRect.height
        guard length > 0 else {
            return ratio
        }
        let offset =
            axis == .vertical
            ? point.x - containerRect.minX
            : point.y - containerRect.minY
        let minimumRatio = min(0.45, max(0.05, Self.minimumPaneLength / length))
        return min(max(offset / length, minimumRatio), 1 - minimumRatio)
    }

    func cellDelta(
        from previousRatio: CGFloat,
        to nextRatio: CGFloat,
        cellSize: NSSize
    ) -> Int {
        let length = axis == .vertical ? containerRect.width : containerRect.height
        let cellLength = axis == .vertical ? cellSize.width : cellSize.height
        guard length > 0, cellLength > 0 else {
            return 0
        }
        return Int((((nextRatio - previousRatio) * length) / cellLength).rounded(.towardZero))
    }

    func ratio(
        afterCellDelta delta: Int,
        from previousRatio: CGFloat,
        cellSize: NSSize
    ) -> CGFloat {
        let length = axis == .vertical ? containerRect.width : containerRect.height
        let cellLength = axis == .vertical ? cellSize.width : cellSize.height
        guard length > 0, cellLength > 0 else {
            return previousRatio
        }
        return previousRatio + CGFloat(delta) * cellLength / length
    }

    private func dividerRect(width: CGFloat) -> NSRect {
        if axis == .vertical {
            return NSRect(
                x: containerRect.minX + floor(containerRect.width * ratio) - width / 2,
                y: containerRect.minY,
                width: width,
                height: containerRect.height
            )
        }
        return NSRect(
            x: containerRect.minX,
            y: containerRect.minY + floor(containerRect.height * ratio) - width / 2,
            width: containerRect.width,
            height: width
        )
    }
}

func terminalInputData(for event: NSEvent) -> Data? {
    switch event.keyCode {
    case 36, 76:
        return Data([13])
    case 48:
        return Data([9])
    case 51:
        return Data([127])
    case 53:
        return Data([27])
    case 123:
        return Data("\u{1B}[D".utf8)
    case 124:
        return Data("\u{1B}[C".utf8)
    case 125:
        return Data("\u{1B}[B".utf8)
    case 126:
        return Data("\u{1B}[A".utf8)
    case 115:
        return Data("\u{1B}[H".utf8)
    case 119:
        return Data("\u{1B}[F".utf8)
    case 116:
        return Data("\u{1B}[5~".utf8)
    case 121:
        return Data("\u{1B}[6~".utf8)
    case 117:
        return Data("\u{1B}[3~".utf8)
    default:
        return textInputData(for: event)
    }
}

func terminalKeyText(_ event: NSEvent) -> String? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let text =
        flags.contains(.control) || flags.contains(.option) || flags.contains(.command)
        ? event.charactersIgnoringModifiers
        : event.characters
    guard let text, !text.isEmpty,
        text.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0xF700...0xF8FF).contains(Int(scalar.value))
        })
    else {
        return nil
    }
    return text
}

let terminalReturnKeyCodes: Set<UInt16> = [36, 76]

let tmuxShellCommandNames: Set<String> = {
    var names = Set<String>()
    if let contents = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) {
        for line in contents.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.hasPrefix("#") else {
                continue
            }
            names.insert((value as NSString).lastPathComponent)
        }
    }
    if let loginShell = ProcessInfo.processInfo.environment["SHELL"] {
        names.insert((loginShell as NSString).lastPathComponent)
    }
    return names
}()

func tmuxCommandIsShell(_ command: String) -> Bool {
    let name = (command as NSString).lastPathComponent
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return tmuxShellCommandNames.contains(name)
}

func terminalModifierMask(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var mask: UInt32 = 0
    if flags.contains(.shift) {
        mask |= 1 << 0
    }
    if flags.contains(.control) {
        mask |= 1 << 1
    }
    if flags.contains(.option) {
        mask |= 1 << 2
    }
    if flags.contains(.command) {
        mask |= 1 << 3
    }
    if flags.contains(.capsLock) {
        mask |= 1 << 4
    }
    if flags.contains(.numericPad) {
        mask |= 1 << 5
    }
    return mask
}

func terminalModifierMask(_ value: String) -> UInt32 {
    var mask: UInt32 = 0
    if value.contains("S") {
        mask |= 1 << 0
    }
    if value.contains("C") {
        mask |= 1 << 1
    }
    if value.contains("A") {
        mask |= 1 << 2
    }
    if value.contains("D") {
        mask |= 1 << 3
    }
    return mask
}

func preferredBool(_ key: String, defaultValue: Bool) -> Bool {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: key) != nil else {
        return defaultValue
    }
    return defaults.bool(forKey: key)
}

func textInputData(for event: NSEvent) -> Data? {
    if event.modifierFlags.contains(.control),
        let byte = controlByte(for: event)
    {
        return Data([byte])
    }
    guard let characters = event.characters, !characters.isEmpty else {
        return nil
    }
    return Data(characters.utf8)
}

func controlByte(for event: NSEvent) -> UInt8? {
    guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
        return nil
    }
    let value = scalar.value
    if (65...90).contains(value) {
        return UInt8(value - 64)
    }
    if (97...122).contains(value) {
        return UInt8(value - 96)
    }
    return nil
}

func clampedUInt16(_ value: Int) -> UInt16 {
    UInt16(min(max(value, 1), Int(UInt16.max)))
}

func configuredTerminalFont(family: String, size: CGFloat) -> NSFont {
    let family = family.trimmingCharacters(in: .whitespacesAndNewlines)
    if !family.isEmpty,
        let font = NSFontManager.shared.font(
            withFamily: family,
            traits: [],
            weight: 5,
            size: size
        )
    {
        return font
    }
    return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

final class TerminalShellViewController: NSViewController, NSTabViewDelegate,
    TerminalContextMenuProvider, NSToolbarDelegate
{
    let core: RustCore
    var settings: NativeSettings
    let tabControl = NativeTabControl(frame: .zero)
    let newTabButton = NativeHoverIconButton(symbolName: "plus", title: "New Tab")
    let artifactButton = NativeHoverIconButton(
        symbolName: "doc.on.doc",
        title: "Recent Artifacts"
    )
    let workSwitcherButton = NativeHoverIconButton(
        symbolName: "square.grid.2x2",
        title: "Work Switcher (⌘P)",
        supportsBadge: true
    )
    let sessionControlButton = NSButton(frame: .zero)
    let backdropView = NativeTerminalBackdropView(frame: .zero)
    let metalView: TerminalMetalView
    let terminalTextView = TerminalTextView(frame: .zero)
    let defaultPaneMode = NativePaneMode.current()
    #if SATIN_SMOKE_SCENARIOS
        let capturesNvimRendererModels: Bool = {
            let environment = ProcessInfo.processInfo.environment
            return environment["SATIN_NATIVE_SMOKE_SCENARIO"] != nil
                && environment["SATIN_NATIVE_SMOKE_CAPTURE_RENDERER_MODEL"] != "0"
        }()
        let smokeState = NativeSmokeState()
    #else
        let capturesNvimRendererModels = false
    #endif
    let paneStore = NativePaneStore()
    var tmuxSession: NativeTmuxSession?
    var resolvedTmuxExecutable: NativeTmuxExecutable?
    var pendingTmuxExecutable: NativeTmuxExecutable?
    var lastTmuxSocketPath: String?
    var pendingTmuxReattach: NativeTmuxAttachment?
    var sessionPopover: NSPopover?
    var lastSearchQuery = ""
    var optionAsAltEnabled: Bool
    var notificationsEnabled: Bool
    var pendingPaneWorkingDirectory: String?
    var pendingPaneStartupCommand: [String]?
    var pendingPaneDirectStartup = false
    var pendingPaneMode: NativePaneMode?
    let initialFinderLaunch: NativeFinderEditorLaunch?
    var activePaneId: Int?
    var lastSnapshot: TerminalCoreSnapshot?
    var lastNvimModelScrollShift: OutputScrollShift?
    private var hasStartedPaneRuntime = false
    var syncingTabs = false
    var controlSocketPath = ""
    var controlCliPath = ""
    var nvimLauncherPath = ""
    var zshIntegrationPath = ""
    var claudeSettingsPath = ""
    var artifactsPopover: NSPopover?
    var artifactsPopoverPaneId: Int?
    let paneStatuses = NativePaneStatusStore()
    let workAttentionStore = NativeWorkAttentionStore()
    var workSwitcherPopover: NSPopover?
    var workSwitcherController: NativeWorkSwitcherViewController?
    lazy var tabStripView = NativeTabStripView(
        tabControl: tabControl,
        newTabButton: newTabButton
    )
    lazy var nativeToolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: "dev.soyukke.satin.toolbar.main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false
        return toolbar
    }()

    init?(
        core: RustCore,
        settings: NativeSettings,
        initialFinderLaunch: NativeFinderEditorLaunch? = nil
    ) {
        guard TerminalMetalView.isAvailable() else {
            NativeLog.runtimeError("metal_renderer_create_failed")
            return nil
        }
        self.core = core
        self.settings = settings
        self.initialFinderLaunch = initialFinderLaunch
        self.optionAsAltEnabled = settings.optionAsAlt
        self.notificationsEnabled = settings.notifications
        self.metalView = TerminalMetalView(frame: .zero)
        super.init(nibName: nil, bundle: nil)
        self.paneStatuses.onChange = { [weak self] paneId, status in
            self?.paneStatusDidChange(paneId: paneId, status: status)
        }
        configureTabControl()
        configureToolbarControls()
        self.metalView.contextMenuProvider = self
        self.terminalTextView.onPaneSelected = { [weak self] paneId in
            self?.selectPane(paneId)
        }
        self.terminalTextView.onPaneChromeAction = { [weak self] action, paneId, sourceView in
            self?.performPaneChromeAction(action, paneId: paneId, sourceView: sourceView)
        }
        self.terminalTextView.onSplitResize = {
            [weak self] firstPaneId, secondPaneId, axis, ratio, cellDelta in
            self?.resizeSplit(
                firstPaneId: firstPaneId,
                secondPaneId: secondPaneId,
                axis: axis,
                ratio: ratio,
                cellDelta: cellDelta
            )
        }
        self.terminalTextView.onSelectionClearRequested = { [weak self] paneId in
            self?.clearTerminalSelection(paneId: paneId)
        }
        self.terminalTextView.onFocusChanged = { [weak self] focused in
            self?.setTerminalFocus(focused)
        }
        self.terminalTextView.onContextMenuRequested = { [weak self] tabIndex, event, view in
            guard let menu = self?.terminalContextMenu(tabIndex: tabIndex) else {
                return
            }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
        self.terminalTextView.onGeometryChanged = { [weak self] in
            self?.resizeTerminalPanesToGrid()
        }
        self.terminalTextView.onInput = { [weak self] data in
            self?.writeToActivePane(data)
        }
        self.terminalTextView.onKeyEvent = { [weak self] event, released in
            self?.sendKeyToActivePane(event, released: released) ?? false
        }
        self.terminalTextView.onTextInput = { [weak self] text in
            self?.writeTextToActivePane(text)
        }
        self.terminalTextView.onMouseInput = { [weak self] input in
            self?.sendMouseInputToActivePane(input) ?? .unhandled
        }
        self.terminalTextView.onMouseTrackingRequested = { [weak self] in
            self?.activePaneUsesMouseTracking() ?? false
        }
        self.terminalTextView.onSelectionEvent = { [weak self] event in
            self?.handleTerminalSelection(event) ?? false
        }
        self.terminalTextView.onHyperlinkRequested = { [weak self] position in
            self?.openTerminalHyperlink(position) ?? false
        }
        self.terminalTextView.onCopyRequested = { [weak self] in
            self?.copySelection() ?? false
        }
        self.terminalTextView.onPasteRequested = { [weak self] in
            self?.pasteClipboard() ?? false
        }
        self.terminalTextView.onSelectAllRequested = { [weak self] in
            self?.selectAllTerminalText() ?? false
        }
        self.terminalTextView.onFindRequested = { [weak self] in
            self?.findInScrollback() ?? false
        }
        self.terminalTextView.onScroll = { [weak self] rows in
            self?.scrollActivePane(deltaRows: rows)
        }
        self.terminalTextView.onZoomIn = { [weak self] in
            self?.zoomIn(nil)
        }
        self.terminalTextView.onZoomOut = { [weak self] in
            self?.zoomOut(nil)
        }
        self.terminalTextView.onResetZoom = { [weak self] in
            self?.resetZoom(nil)
        }
        self.terminalTextView.onPaneZoomChanged = { [weak self] paneId in
            self?.resizePaneForZoom(paneId)
        }
        self.metalView.renderProvider = { [weak self] texture, renderer in
            self?.renderActiveMetalFrame(texture: texture, renderer: renderer) ?? false
        }
        _ = self.terminalTextView.setTerminalFont(
            family: settings.fontFamily,
            size: CGFloat(settings.fontSize)
        )
        self.metalView.setFontFamily(settings.fontFamily)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        for source in paneStore.wakeupSources.values {
            source.cancel()
        }
        for source in paneStore.suspendedWakeupSources.values {
            source.cancel()
        }
        for pane in paneStore.runtimes.values {
            metalView.forgetRuntime(pane.renderHandle())
        }
    }

    override func loadView() {
        view = NSView()
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        metalView.translatesAutoresizingMaskIntoConstraints = false
        configureTerminalTextView()
        view.addSubview(backdropView)
        view.addSubview(metalView)
        metalView.addSubview(terminalTextView)

        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            metalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            metalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            terminalTextView.topAnchor.constraint(equalTo: metalView.topAnchor),
            terminalTextView.leadingAnchor.constraint(equalTo: metalView.leadingAnchor),
            terminalTextView.trailingAnchor.constraint(equalTo: metalView.trailingAnchor),
            terminalTextView.bottomAnchor.constraint(equalTo: metalView.bottomAnchor),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        startPaneRuntimeIfReady()
    }

    private func startPaneRuntimeIfReady() {
        let grid = terminalTextView.terminalGridSize()
        guard !hasStartedPaneRuntime,
            view.window != nil,
            grid.rows > 1,
            grid.cols > 1
        else {
            return
        }
        hasStartedPaneRuntime = true
        if let initialFinderLaunch {
            prepareFinderEditorLaunch(initialFinderLaunch)
        } else {
            restoreSessionIfNeeded()
        }
        syncFromCore()
        schedulePendingTmuxReattach()
    }

    func openFinderItems(_ launch: NativeFinderEditorLaunch) -> Bool {
        prepareFinderEditorLaunch(launch)
        core.newTab()
        syncFromCore()
        guard let activePaneId, let pane = paneStore.runtimes[activePaneId] else {
            return false
        }
        return pane.kind == .terminal
    }

    func focusTerminal() {
        view.window?.makeFirstResponder(terminalTextView)
        markActiveWorkSeen()
    }

    func toolbar() -> NSToolbar {
        nativeToolbar
    }

    func configureControl(
        socketPath: String,
        cliPath: String,
        nvimLauncherPath: String,
        zshIntegrationPath: String,
        claudeSettingsPath: String
    ) {
        controlSocketPath = socketPath
        controlCliPath = cliPath
        self.nvimLauncherPath = nvimLauncherPath
        self.zshIntegrationPath = zshIntegrationPath
        self.claudeSettingsPath = claudeSettingsPath
    }

    func applySettings(_ settings: NativeSettings) {
        let previous = self.settings
        self.settings = settings
        if previous.shellPath != settings.shellPath
            || previous.tmuxExecutablePath != settings.tmuxExecutablePath
        {
            resolvedTmuxExecutable = nil
        }
        optionAsAltEnabled = settings.optionAsAlt
        notificationsEnabled = settings.notifications
        for pane in paneStore.runtimes.values {
            (pane as? RustTerminalPane)?.setOptionAsAlt(settings.optionAsAlt)
        }
        if previous.fontFamily != settings.fontFamily
            || previous.fontSize != settings.fontSize
        {
            _ = terminalTextView.setTerminalFont(
                family: settings.fontFamily,
                size: CGFloat(settings.fontSize)
            )
            metalView.setFontFamily(settings.fontFamily)
            resizeTerminalPanesToGrid()
        }
        if previous.defaultTheme != settings.defaultTheme {
            if core.applyThemePreference(settings.defaultTheme) {
                syncFromCore()
            }
        }
    }

}

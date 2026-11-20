import AppKit

/// The three looks Satin can wear: the terminal's own dark one, a clean high-contrast
/// light mode, and paper, where the panes are cream stock printed in violet and teal ink.
enum NativeAppearanceMode: String, CaseIterable {
    case terminal
    case light
    case paper

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .light: "Light"
        case .paper: "Paper"
        }
    }

    /// True when the mode uses a light surface and macOS `.aqua` chrome.
    var isLightSurface: Bool {
        self != .terminal
    }

    var nsAppearanceName: NSAppearance.Name {
        isLightSurface ? .aqua : .darkAqua
    }
}

private func buildPanePalette(
    foreground: [UInt8],
    background: [UInt8],
    cursor: [UInt8],
    ansi: [[UInt8]]
) -> [UInt8] {
    var bytes = foreground + background + cursor
    for color in ansi {
        bytes += color
    }
    let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
    for red in levels {
        for green in levels {
            for blue in levels {
                bytes += [red, green, blue]
            }
        }
    }
    // The grey ramp runs from ink to background, so its ends stay readable.
    for step in 0..<24 {
        let mix = Double(step) / 23
        bytes += (0..<3).map { channel in
            UInt8(
                (Double(foreground[channel]) * (1 - mix) + Double(background[channel]) * mix)
                    .rounded())
        }
    }
    return bytes
}

/// Clean light mode's colors: charcoal ink on crisp off-white stock, with every
/// ANSI color tuned to read at 4.5:1 or higher.
let nativeLightPaneColors: [UInt8] = buildPanePalette(
    foreground: [24, 28, 36],
    background: [250, 251, 253],
    cursor: [37, 99, 235],
    ansi: [
        [24, 28, 36], [207, 34, 46], [17, 118, 56], [154, 91, 0],
        [9, 105, 218], [130, 80, 223], [14, 116, 144], [87, 96, 106],
        [101, 109, 118], [164, 14, 38], [22, 128, 61], [128, 74, 0],
        [29, 78, 216], [102, 57, 186], [15, 118, 110], [36, 41, 47],
    ]
)

/// Paper's colors, laid out as the core's default colors are: foreground,
/// background and cursor, then the 256-color palette.
let nativePaperPaneColors: [UInt8] = buildPanePalette(
    foreground: [43, 34, 51],
    background: [241, 232, 212],
    cursor: [91, 63, 184],
    // Inks dark enough to read on cream; "white" stays an ink too, since
    // programs print ordinary text in it.
    ansi: [
        [43, 34, 51], [176, 42, 67], [31, 122, 82], [150, 92, 12],
        [46, 90, 168], [91, 63, 184], [31, 111, 111], [110, 98, 79],
        [125, 112, 91], [194, 54, 79], [38, 138, 94], [176, 108, 14],
        [58, 108, 196], [106, 75, 196], [31, 138, 138], [61, 51, 70],
    ]
)

extension TerminalShellViewController {
    var appearanceMode: NativeAppearanceMode {
        NativeAppearanceMode(rawValue: settings.appearanceMode) ?? .terminal
    }

    /// The colors new panes draw with: empty for the terminal's own dark palette,
    /// or the light / paper palette otherwise.
    var paneThemeColors: [UInt8] {
        switch appearanceMode {
        case .terminal: []
        case .light: nativeLightPaneColors
        case .paper: nativePaperPaneColors
        }
    }

    /// Puts every part of the window in the current mode: the panes, the
    /// window's controls, the backdrop and the pages.
    func applyAppearanceMode() {
        let mode = appearanceMode
        NativePageStyle.mode = mode
        for runtime in paneStore.runtimes.values {
            (runtime as? TerminalPane)?.setThemeColors(paneThemeColors)
        }
        view.window?.appearance = NSAppearance(named: mode.nsAppearanceName)
        metalView.setBackdropAppearance(mode)
        backdropView.needsDisplay = true
        terminalTextView.refreshAppearance()
        tabControl.needsDisplay = true
        tabControl.fuseView.refreshLook()
        tabControl.signalView.refreshLook()
        attentionHandView.applyLook()
        pageHandView.refreshLook()
        windowsSidebar.refreshLook()
        itemsSidebar.refreshLook()
        pageReaderChrome?.needsDisplay = true
        pageReaderDocument?.refreshLook()
        sparePageDocument?.refreshLook()
        if let binder = pageBinder {
            binder.show(pages: pageInbox.pages, unread: pageInbox.unread)
        }
        drainTerminalPanes()
        metalView.requestFrame()
    }
}

func runNativePaperModeSelfTests() -> Bool {
    func luminance(_ colors: [UInt8], _ index: Int) -> Double {
        let channels = (0..<3).map { channel -> Double in
            let value = Double(colors[index * 3 + channel]) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
    func contrast(_ colors: [UInt8], _ first: Int, _ second: Int) -> Double {
        let (a, b) = (luminance(colors, first), luminance(colors, second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    let paper = nativePaperPaneColors
    let light = nativeLightPaneColors
    let lightAnsiReadable = (0..<16).allSatisfy { ansiIndex in
        contrast(light, 3 + ansiIndex, 1) >= 4.5
    }

    let previousMode = NativePageStyle.mode
    defer { NativePageStyle.mode = previousMode }
    NativePageStyle.mode = .light
    let lightSurfaceDistinctFromPaper =
        !NativePageStyle.paper
        && NativePageStyle.isLight
        && NativePageStyle.isLightSurface
        && NativePageStyle.surface != NativePageStyle.rgb(251, 245, 231)
    NativePageStyle.mode = .paper
    let paperStillMatches =
        NativePageStyle.paper && !NativePageStyle.isLight
        && NativePageStyle.isLightSurface
    NativePageStyle.mode = .terminal
    let terminalStillMatches =
        !NativePageStyle.paper && !NativePageStyle.isLight
        && !NativePageStyle.isLightSurface

    return paper.count == 777
        && contrast(paper, 0, 1) >= 7
        && contrast(paper, 3 + 1, 1) >= 4.5
        && contrast(paper, 3 + 7, 1) >= 4.5
        && light.count == 777
        && contrast(light, 0, 1) >= 12
        && lightAnsiReadable
        && NativeAppearanceMode(rawValue: "terminal") == .terminal
        && NativeAppearanceMode(rawValue: "light") == .light
        && NativeAppearanceMode(rawValue: "paper") == .paper
        && NativeAppearanceMode.allCases == [.terminal, .light, .paper]
        && NativeAppearanceMode.terminal.nsAppearanceName == .darkAqua
        && NativeAppearanceMode.light.nsAppearanceName == .aqua
        && NativeAppearanceMode.paper.nsAppearanceName == .aqua
        && lightSurfaceDistinctFromPaper
        && paperStillMatches
        && terminalStillMatches
}

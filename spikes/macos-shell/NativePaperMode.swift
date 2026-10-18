import AppKit

/// The two looks Satin can wear: the terminal's own dark one, and paper,
/// where the panes are cream stock printed in violet and teal ink.
enum NativeAppearanceMode: String, CaseIterable {
    case terminal
    case paper

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .paper: "Paper"
        }
    }
}

/// Paper's colors, laid out as the core's default colors are: foreground,
/// background and cursor, then the 256-color palette.
let nativePaperPaneColors: [UInt8] = {
    let ink: [UInt8] = [43, 34, 51]
    let paper: [UInt8] = [241, 232, 212]
    let cursor: [UInt8] = [91, 63, 184]
    // Inks dark enough to read on cream; "white" stays an ink too, since
    // programs print ordinary text in it.
    let ansi: [[UInt8]] = [
        [43, 34, 51], [176, 42, 67], [31, 122, 82], [150, 92, 12],
        [46, 90, 168], [91, 63, 184], [31, 111, 111], [110, 98, 79],
        [125, 112, 91], [194, 54, 79], [38, 138, 94], [176, 108, 14],
        [58, 108, 196], [106, 75, 196], [31, 138, 138], [61, 51, 70],
    ]
    var bytes = ink + paper + cursor
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
    // The grey ramp runs from ink to paper, so its ends stay readable.
    for step in 0..<24 {
        let mix = Double(step) / 23
        bytes += (0..<3).map { channel in
            UInt8((Double(ink[channel]) * (1 - mix) + Double(paper[channel]) * mix).rounded())
        }
    }
    return bytes
}()

extension TerminalShellViewController {
    var appearanceMode: NativeAppearanceMode {
        NativeAppearanceMode(rawValue: settings.appearanceMode) ?? .terminal
    }

    /// The colors new panes draw with: paper's, or empty for the terminal's
    /// own.
    var paneThemeColors: [UInt8] {
        appearanceMode == .paper ? nativePaperPaneColors : []
    }

    /// Puts every part of the window in the current mode: the panes, the
    /// window's controls, the backdrop and the pages.
    func applyAppearanceMode() {
        let paper = appearanceMode == .paper
        NativePageStyle.paper = paper
        for runtime in paneStore.runtimes.values {
            (runtime as? TerminalPane)?.setThemeColors(paneThemeColors)
        }
        view.window?.appearance = NSAppearance(named: paper ? .aqua : .darkAqua)
        metalView.setBackdropPaper(paper)
        backdropView.needsDisplay = true
        terminalTextView.needsDisplay = true
        tabControl.needsDisplay = true
        tabControl.fuseView.refreshLook()
        tabControl.signalView.refreshLook()
        attentionHandView.applyLook()
        pageHandView.refreshLook()
        pageReaderChrome?.needsDisplay = true
        pageReaderDocument?.refreshLook()
        if let binder = pageBinder {
            binder.show(pages: pageInbox.pages, unread: pageInbox.unread)
        }
        drainTerminalPanes()
        metalView.requestFrame()
    }
}

func runNativePaperModeSelfTests() -> Bool {
    let colors = nativePaperPaneColors
    // Ink on paper, and paper's red on paper, both read at 4.5:1 or more.
    func luminance(_ index: Int) -> Double {
        let channels = (0..<3).map { channel -> Double in
            let value = Double(colors[index * 3 + channel]) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
    func contrast(_ first: Int, _ second: Int) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    return colors.count == 777 && contrast(0, 1) >= 7 && contrast(3 + 1, 1) >= 4.5
        && contrast(3 + 7, 1) >= 4.5
        && NativeAppearanceMode(rawValue: "paper") == .paper
}

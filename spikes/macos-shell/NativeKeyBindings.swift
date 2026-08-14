import AppKit

enum NativeCommandID: String, CaseIterable {
    case showWorkSwitcher
    case newTab
    case splitVertical
    case splitHorizontal
    case closePane
    case focusPaneLeft
    case focusPaneDown
    case focusPaneUp
    case focusPaneRight
    case renameSession
    case openNativeNeovim
    case zoomIn
    case zoomOut
    case actualSize
    case checkForUpdates

    var title: String {
        switch self {
        case .showWorkSwitcher: "Work Switcher"
        case .newTab: "New Tab"
        case .splitVertical: "Split Vertical"
        case .splitHorizontal: "Split Horizontal"
        case .closePane: "Close Pane"
        case .focusPaneLeft: "Focus Pane Left"
        case .focusPaneDown: "Focus Pane Down"
        case .focusPaneUp: "Focus Pane Up"
        case .focusPaneRight: "Focus Pane Right"
        case .renameSession: "Rename Session"
        case .openNativeNeovim: "Open Native Neovim"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        case .checkForUpdates: "Check for Updates"
        }
    }

    var defaultShortcut: String {
        switch self {
        case .showWorkSwitcher: "cmd+p"
        case .newTab: "cmd+t"
        case .splitVertical: "cmd+d"
        case .splitHorizontal: "cmd+shift+d"
        case .closePane: "cmd+w"
        case .focusPaneLeft: "cmd+control+h"
        case .focusPaneDown: "cmd+control+j"
        case .focusPaneUp: "cmd+control+k"
        case .focusPaneRight: "cmd+control+l"
        case .renameSession: "cmd+r"
        case .openNativeNeovim: "cmd+n"
        case .zoomIn: "cmd+="
        case .zoomOut: "cmd+-"
        case .actualSize: "cmd+0"
        case .checkForUpdates: "cmd+u"
        }
    }
}

struct NativeKeyShortcut: Equatable {
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags

    static func parse(_ value: String) -> NativeKeyShortcut? {
        let parts =
            value
            .lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map(String.init)
        guard let key = parts.last, key.count == 1, !key.isEmpty else {
            return nil
        }
        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command":
                modifiers.insert(.command)
            case "shift":
                modifiers.insert(.shift)
            case "option", "alt":
                modifiers.insert(.option)
            case "control", "ctrl":
                modifiers.insert(.control)
            default:
                return nil
            }
        }
        guard modifiers.contains(.command) else {
            return nil
        }
        return NativeKeyShortcut(keyEquivalent: key, modifiers: modifiers)
    }

    var identity: String {
        "\(modifiers.rawValue):\(keyEquivalent)"
    }
}

let nativeReservedShortcutValues = [
    "cmd+,", "cmd+q", "cmd+c", "cmd+v", "cmd+a", "cmd+f",
    "cmd+1", "cmd+2", "cmd+3", "cmd+4", "cmd+5",
    "cmd+6", "cmd+7", "cmd+8", "cmd+9",
]

import AppKit

enum NativeMainMenuAction: Equatable {
    case showSettings
    case showWorkSwitcher
    case newTab
    case splitVertical
    case splitHorizontal
    case closePane
    case focusPaneLeft
    case focusPaneDown
    case focusPaneUp
    case focusPaneRight
    case showSessionSwitcher
    case selectTab(Int)
    case renameSession
    case openNativeNeovim
    case zoomIn
    case zoomOut
    case actualSize
    case checkForUpdates
    case showAcknowledgements

    fileprivate var requiresTerminalWindow: Bool {
        switch self {
        case .showSettings, .checkForUpdates, .showAcknowledgements:
            false
        default:
            true
        }
    }
}

private final class NativeMainMenuActionBox: NSObject {
    let action: NativeMainMenuAction

    init(_ action: NativeMainMenuAction) {
        self.action = action
    }
}

final class NativeMainMenuController: NSObject, NSMenuItemValidation {
    private let actionHandler: (NativeMainMenuAction) -> Void
    private let terminalOwnsCommands: () -> Bool
    private let includesUpdates: Bool
    private let mainMenu = NSMenu()
    private var windowMenu: NSMenu?
    private var commandItems: [NativeCommandID: NSMenuItem] = [:]

    convenience init(
        application: NSApplication,
        terminalWindow: NSWindow,
        settings: NativeSettings,
        includesUpdates: Bool,
        actionHandler: @escaping (NativeMainMenuAction) -> Void
    ) {
        self.init(
            settings: settings,
            includesUpdates: includesUpdates,
            terminalOwnsCommands: { [weak application, weak terminalWindow] in
                application?.keyWindow === terminalWindow
            },
            actionHandler: actionHandler
        )
    }

    private init(
        settings: NativeSettings,
        includesUpdates: Bool,
        terminalOwnsCommands: @escaping () -> Bool,
        actionHandler: @escaping (NativeMainMenuAction) -> Void
    ) {
        self.actionHandler = actionHandler
        self.terminalOwnsCommands = terminalOwnsCommands
        self.includesUpdates = includesUpdates
        super.init()
        buildMainMenu(settings: settings)
    }

    func install(in application: NSApplication) {
        application.mainMenu = mainMenu
        application.windowsMenu = windowMenu
    }

    func refreshShortcuts(using settings: NativeSettings) {
        for (command, item) in commandItems {
            let shortcut = settings.shortcut(for: command)
            item.keyEquivalent = shortcut.keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard
            let action = (menuItem.representedObject as? NativeMainMenuActionBox)?.action
        else {
            return true
        }
        return !action.requiresTerminalWindow || terminalOwnsCommands()
    }

    private func buildMainMenu(settings: NativeSettings) {
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem(settings: settings))
        mainMenu.addItem(sessionMenuItem(settings: settings))
        mainMenu.addItem(windowMenuItem())
        mainMenu.addItem(helpMenuItem(settings: settings))
    }

    private func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(
            withTitle: "About \(nativeApplicationName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            targetedItem(
                "Settings…",
                menuAction: .showSettings,
                keyEquivalent: ",",
                modifiers: [.command]
            )
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Quit \(nativeApplicationName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.submenu = menu
        return item
    }

    private func sessionMenuItem(settings: NativeSettings) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Session")
        addCommandItems(
            [(.showWorkSwitcher, .showWorkSwitcher)],
            to: menu,
            settings: settings
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            targetedItem(
                "Switch Terminal Session…",
                menuAction: .showSessionSwitcher
            )
        )
        menu.addItem(NSMenuItem.separator())
        addCommandItems(
            [
                (.newTab, .newTab),
                (.splitVertical, .splitVertical),
                (.splitHorizontal, .splitHorizontal),
                (.closePane, .closePane),
            ],
            to: menu,
            settings: settings
        )
        menu.addItem(NSMenuItem.separator())
        addCommandItems(
            [
                (.focusPaneLeft, .focusPaneLeft),
                (.focusPaneDown, .focusPaneDown),
                (.focusPaneUp, .focusPaneUp),
                (.focusPaneRight, .focusPaneRight),
            ],
            to: menu,
            settings: settings
        )
        menu.addItem(NSMenuItem.separator())
        for shortcutNumber in 1...9 {
            let title = shortcutNumber == 9 ? "Select Last Tab" : "Select Tab \(shortcutNumber)"
            menu.addItem(
                targetedItem(
                    title,
                    menuAction: .selectTab(shortcutNumber),
                    keyEquivalent: "\(shortcutNumber)",
                    modifiers: [.command]
                )
            )
        }
        menu.addItem(NSMenuItem.separator())
        addCommandItems(
            [
                (.renameSession, .renameSession),
                (.openNativeNeovim, .openNativeNeovim),
            ],
            to: menu,
            settings: settings
        )
        item.submenu = menu
        return item
    }

    private func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            withTitle: "Find",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "f"
        )
        item.submenu = menu
        return item
    }

    private func viewMenuItem(settings: NativeSettings) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")
        addCommandItems(
            [
                (.zoomIn, .zoomIn),
                (.zoomOut, .zoomOut),
                (.actualSize, .actualSize),
            ],
            to: menu,
            settings: settings
        )
        item.submenu = menu
        return item
    }

    private func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        item.submenu = menu
        windowMenu = menu
        return item
    }

    private func helpMenuItem(settings: NativeSettings) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        if includesUpdates {
            menu.addItem(
                commandItem(
                    .checkForUpdates,
                    menuAction: .checkForUpdates,
                    settings: settings,
                    title: "Check for Updates…"
                )
            )
            menu.addItem(NSMenuItem.separator())
        }
        menu.addItem(
            targetedItem(
                "Acknowledgements…",
                menuAction: .showAcknowledgements
            )
        )
        item.submenu = menu
        return item
    }

    private func addCommandItems(
        _ commands: [(NativeCommandID, NativeMainMenuAction)],
        to menu: NSMenu,
        settings: NativeSettings
    ) {
        for (command, action) in commands {
            menu.addItem(
                commandItem(command, menuAction: action, settings: settings)
            )
        }
    }

    private func commandItem(
        _ command: NativeCommandID,
        menuAction: NativeMainMenuAction,
        settings: NativeSettings,
        title: String? = nil
    ) -> NSMenuItem {
        let shortcut = settings.shortcut(for: command)
        let item = targetedItem(
            title ?? command.title,
            menuAction: menuAction,
            keyEquivalent: shortcut.keyEquivalent,
            modifiers: shortcut.modifiers
        )
        item.identifier = NSUserInterfaceItemIdentifier(command.rawValue)
        commandItems[command] = item
        return item
    }

    private func targetedItem(
        _ title: String,
        menuAction: NativeMainMenuAction,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(performAction(_:)),
            keyEquivalent: keyEquivalent
        )
        item.target = self
        item.representedObject = NativeMainMenuActionBox(menuAction)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard
            let action = (sender.representedObject as? NativeMainMenuActionBox)?.action
        else {
            return
        }
        actionHandler(action)
    }

    static func runSelfTests() -> Bool {
        final class FocusProbe {
            enum Role: CaseIterable {
                case terminal
                case settings
                case updateAlert
            }

            var role = Role.terminal
        }

        let suiteName = "dev.soyukke.satin.main-menu-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return false
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let focus = FocusProbe()
        var actions: [NativeMainMenuAction] = []
        var settings = NativeSettingsStore(defaults: defaults).load()
        let controller = NativeMainMenuController(
            settings: settings,
            includesUpdates: true,
            terminalOwnsCommands: { focus.role == .terminal },
            actionHandler: { actions.append($0) }
        )
        guard controller.mainMenu.items.count == 6,
            controller.commandItems.count == NativeCommandID.allCases.count,
            let workSwitcherItem = controller.commandItems[.showWorkSwitcher],
            let newTabItem = controller.commandItems[.newTab],
            let updateItem = controller.commandItems[.checkForUpdates]
        else {
            return false
        }
        let mainMenuIdentity = ObjectIdentifier(controller.mainMenu)
        let newTabIdentity = ObjectIdentifier(newTabItem)

        for role in FocusProbe.Role.allCases {
            focus.role = role
            newTabItem.menu?.update()
            updateItem.menu?.update()
            let terminalExpected = role == .terminal
            guard newTabItem.isEnabled == terminalExpected,
                updateItem.isEnabled,
                ObjectIdentifier(controller.mainMenu) == mainMenuIdentity,
                ObjectIdentifier(newTabItem) == newTabIdentity
            else {
                return false
            }
        }

        settings.keyBindings[NativeCommandID.newTab.rawValue] = "cmd+shift+t"
        controller.refreshShortcuts(using: settings)
        guard ObjectIdentifier(controller.mainMenu) == mainMenuIdentity,
            ObjectIdentifier(newTabItem) == newTabIdentity,
            newTabItem.identifier?.rawValue == NativeCommandID.newTab.rawValue,
            newTabItem.keyEquivalent == "t",
            newTabItem.keyEquivalentModifierMask == [.command, .shift]
        else {
            return false
        }

        controller.performAction(newTabItem)
        controller.performAction(workSwitcherItem)
        let tabItem = NSMenuItem()
        tabItem.representedObject = NativeMainMenuActionBox(.selectTab(7))
        controller.performAction(tabItem)
        return actions == [.newTab, .showWorkSwitcher, .selectTab(7)]
    }
}

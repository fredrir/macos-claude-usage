import AppKit

/// An accessory app draws no menu bar, but AppKit still routes key equivalents through the
/// main menu — without one, ⌘W never reaches the Settings window.
enum AppMainMenu {
    static func make() -> NSMenu {
        let close = NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        close.keyEquivalentModifierMask = .command

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(close)

        let fileItem = NSMenuItem()
        fileItem.submenu = fileMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(fileItem)
        return mainMenu
    }
}

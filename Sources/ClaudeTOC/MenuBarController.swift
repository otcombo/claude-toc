import AppKit

@MainActor
class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private weak var sessionManager: TOCSessionManager?

    func setup(sessionManager: TOCSessionManager) {
        self.sessionManager = sessionManager
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: "Claude TOC")
            button.image?.isTemplate = true
        }
        updateMenu()
    }

    func updateMenu() {
        let menu = NSMenu()

        // Close All TOC
        let closeAll = NSMenuItem(title: "Close All TOC", action: #selector(closeAllTOC), keyEquivalent: "w")
        closeAll.target = self
        menu.addItem(closeAll)

        menu.addItem(.separator())

        // Session list
        if let sessions = sessionManager?.activeSessions, !sessions.isEmpty {
            for session in sessions {
                let item = NSMenuItem(title: session.menuTitle, action: #selector(sessionClicked(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = session.id
                // Bullet indicator for visible panels
                if session.panel != nil {
                    item.state = .on
                }
                menu.addItem(item)
            }
        } else {
            let empty = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())

        // Settings
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // Quit
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @objc private func closeAllTOC() {
        sessionManager?.closeAll()
        updateMenu()
    }

    @objc private func sessionClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        sessionManager?.focusSession(id: id)
    }

    @objc private func openSettings() {
        // TODO: settings panel
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

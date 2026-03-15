import AppKit
@preconcurrency import UserNotifications

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

        // Permissions submenu
        let permissionsItem = NSMenuItem(title: "Permissions", action: nil, keyEquivalent: "")
        let permissionsMenu = NSMenu()

        // Accessibility permission
        let axTrusted = AXIsProcessTrusted()
        if axTrusted {
            let axItem = NSMenuItem(title: "Accessibility: Granted", action: nil, keyEquivalent: "")
            axItem.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            axItem.image?.isTemplate = true
            permissionsMenu.addItem(axItem)
        } else {
            let axItem = NSMenuItem(title: "Accessibility: Not Granted", action: #selector(openAccessibilitySettings), keyEquivalent: "")
            axItem.target = self
            axItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            axItem.image?.isTemplate = true
            permissionsMenu.addItem(axItem)

            let axHint = NSMenuItem(title: "  Toggle off → on after each rebuild", action: nil, keyEquivalent: "")
            axHint.isEnabled = false
            permissionsMenu.addItem(axHint)
        }

        // Notification permission
        let notifPlaceholder = NSMenuItem(title: "Notifications: Checking…", action: nil, keyEquivalent: "")
        permissionsMenu.addItem(notifPlaceholder)

        nonisolated(unsafe) let notifItemRef = notifPlaceholder
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if granted {
                        notifItemRef.title = "Notifications: Granted"
                        notifItemRef.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
                        notifItemRef.image?.isTemplate = true
                    } else {
                        notifItemRef.title = "Notifications: Not Granted"
                        notifItemRef.action = #selector(self.openNotificationSettings)
                        notifItemRef.target = self
                        notifItemRef.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
                        notifItemRef.image?.isTemplate = true
                    }
                }
            }
        }

        permissionsItem.submenu = permissionsMenu
        menu.addItem(permissionsItem)

        menu.addItem(.separator())

        // Quit
        let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    // MARK: - Actions

    @objc private func closeAllTOC() {
        sessionManager?.closeAll()
        updateMenu()
    }

    @objc private func sessionClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        sessionManager?.focusSession(id: id)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openNotificationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

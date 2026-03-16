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
            let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            button.image = NSImage(systemSymbolName: "list.dash", accessibilityDescription: "TOC for Claude Code")?.withSymbolConfiguration(config)
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
                let sessionItem = NSMenuItem(title: session.menuTitle, action: nil, keyEquivalent: "")
                let submenu = NSMenu()

                let hasTOC = session.tocResult.map { !$0.headings.isEmpty } ?? false
                let panelVisible = session.panel != nil

                if hasTOC {
                    if panelVisible {
                        let hide = NSMenuItem(title: "Hide TOC", action: #selector(hideSessionClicked(_:)), keyEquivalent: "")
                        hide.target = self
                        hide.representedObject = session.id
                        submenu.addItem(hide)
                    } else {
                        let show = NSMenuItem(title: "Show TOC", action: #selector(showSessionClicked(_:)), keyEquivalent: "")
                        show.target = self
                        show.representedObject = session.id
                        submenu.addItem(show)
                    }
                }

                let focus = NSMenuItem(title: "Focus Terminal", action: #selector(sessionClicked(_:)), keyEquivalent: "")
                focus.target = self
                focus.representedObject = session.id
                submenu.addItem(focus)

                submenu.addItem(.separator())

                let remove = NSMenuItem(title: "Remove", action: #selector(removeSessionClicked(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = session.id
                submenu.addItem(remove)

                sessionItem.submenu = submenu
                if panelVisible {
                    sessionItem.state = .on
                }
                menu.addItem(sessionItem)
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

    @objc private func hideSessionClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        sessionManager?.hideSession(id: id)
    }

    @objc private func showSessionClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        sessionManager?.reshowSession(id: id)
    }

    @objc private func removeSessionClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        sessionManager?.removeSession(id: id)
        updateMenu()
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

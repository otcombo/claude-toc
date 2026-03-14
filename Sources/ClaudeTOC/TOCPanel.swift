import AppKit
import SwiftUI
@preconcurrency import UserNotifications

/// A floating panel that doesn't steal focus from the terminal
class TOCPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isFloatingPanel = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.isOpaque = false
        self.backgroundColor = .clear
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.animationBehavior = .utilityWindow
        self.hidesOnDeactivate = false
    }
}

/// Represents one Claude Code session with its TOC panel
@MainActor
class TOCSession {
    let id: String               // transcript filename (UUID)
    let transcriptPath: String
    let projectName: String?
    let tocResult: TOCResult?
    let terminalType: TerminalType
    let terminalApp: NSRunningApplication?
    var panel: TOCPanel?

    init(id: String, transcriptPath: String, projectName: String?, tocResult: TOCResult?,
         terminalType: TerminalType, terminalApp: NSRunningApplication?) {
        self.id = id
        self.transcriptPath = transcriptPath
        self.projectName = projectName
        self.tocResult = tocResult
        self.terminalType = terminalType
        self.terminalApp = terminalApp
    }

    var menuTitle: String {
        var title = projectName ?? "Session"
        if let q = tocResult?.lastUserQuery {
            let trimmed = q.replacingOccurrences(of: "\n", with: " ")
            let maxLen = 30
            if trimmed.count > maxLen {
                title += " — \"\(trimmed.prefix(maxLen))…\""
            } else {
                title += " — \"\(trimmed)\""
            }
        }
        return title
    }
}

/// Manages multiple TOC sessions (one per Claude Code window)
@MainActor
class TOCSessionManager {
    private var sessions: [String: TOCSession] = [:]
    var onSessionsChanged: (() -> Void)?

    var activeSessions: [TOCSession] {
        Array(sessions.values).sorted { $0.id < $1.id }
    }

    func addSession(transcriptPath: String, hookPid: Int32?) {
        let sessionId = URL(fileURLWithPath: transcriptPath).deletingPathExtension().lastPathComponent
        let projectName = Self.extractProjectName(from: transcriptPath)

        log("SessionManager: adding session \(sessionId), project: \(projectName ?? "unknown")")

        // Detect terminal
        let (terminalType, terminalApp) = TerminalAdapter.detectTerminal(hookPid: hookPid)
        let termColumns = TerminalAdapter.estimateColumns(app: terminalApp)

        let tocResult = TOCParser.parse(transcriptPath: transcriptPath, terminalColumns: termColumns)

        log("SessionManager: headings=\(tocResult?.headings.count ?? 0), query: \(tocResult?.lastUserQuery?.prefix(40) ?? "nil")")

        // Close existing panel for this session
        sessions[sessionId]?.panel?.close()

        let session = TOCSession(
            id: sessionId, transcriptPath: transcriptPath, projectName: projectName,
            tocResult: tocResult, terminalType: terminalType, terminalApp: terminalApp
        )

        // Show TOC panel only if there are headings
        if let toc = tocResult, !toc.headings.isEmpty {
            showPanel(for: session)
        }

        sessions[sessionId] = session
        log("SessionManager: session \(sessionId) active, total sessions: \(sessions.count)")

        // Always send notification
        sendNotification(for: session)

        onSessionsChanged?()
    }

    func closeAll() {
        for session in sessions.values {
            session.panel?.close()
            session.panel = nil
        }
        sessions.removeAll()
        onSessionsChanged?()
    }

    func closeSession(id: String) {
        sessions[id]?.panel?.close()
        sessions.removeValue(forKey: id)
        onSessionsChanged?()
    }

    func focusSession(id: String) {
        guard let session = sessions[id] else { return }
        if let panel = session.panel {
            panel.orderFrontRegardless()
        }
        // Also activate the terminal
        session.terminalApp?.activate()
    }

    // MARK: - Panel creation

    private func showPanel(for session: TOCSession) {
        guard let tocResult = session.tocResult else { return }
        let rowHeight: CGFloat = 28
        let headerHeight: CGFloat = 40
        let contentHeight = min(CGFloat(tocResult.headings.count) * rowHeight + headerHeight, 400)
        let panelWidth: CGFloat = 260

        let panelOrigin = findTerminalTopRight(
            terminalApp: session.terminalApp, panelWidth: panelWidth, panelHeight: contentHeight)
        let panelRect = NSRect(x: panelOrigin.x, y: panelOrigin.y, width: panelWidth, height: contentHeight)

        let newPanel = TOCPanel(contentRect: panelRect)
        let sessionId = session.id

        let hostingView = NSHostingView(rootView: TOCView(
            headings: tocResult.headings,
            totalLines: tocResult.totalLines,
            onHeadingClick: { [weak self] heading in
                self?.handleHeadingClick(heading, sessionId: sessionId)
            },
            onDismiss: { [weak self] in
                self?.closeSession(id: sessionId)
            }
        ))

        newPanel.contentView = hostingView
        newPanel.orderFrontRegardless()
        session.panel = newPanel
    }

    private func handleHeadingClick(_ heading: TOCHeading, sessionId: String) {
        guard let session = sessions[sessionId],
              let tocResult = session.tocResult,
              let termApp = session.terminalApp else { return }
        TerminalAdapter.jumpToHeading(
            heading: heading,
            responseTerminalLines: tocResult.estimatedTerminalLines,
            app: termApp
        )
    }

    // MARK: - Notification

    private func sendNotification(for session: TOCSession) {
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationClickHandler.shared

        // Title: Claude responded "user query"
        let querySnippet: String
        if let q = session.tocResult?.lastUserQuery {
            let maxLen = 40
            let trimmed = q.replacingOccurrences(of: "\n", with: " ")
            if trimmed.count <= maxLen {
                querySnippet = " \"\(trimmed)\""
            } else {
                querySnippet = " \"\(trimmed.prefix(maxLen))…\""
            }
        } else {
            querySnippet = ""
        }
        let notifTitle = "Claude responded\(querySnippet)"
        let notifBody = session.tocResult?.responsePreview ?? "New response"

        log("sendNotification: requesting authorization...")
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            log("sendNotification: authorization granted=\(granted), error=\(error?.localizedDescription ?? "nil")")
            if granted {
                let content = UNMutableNotificationContent()
                content.title = notifTitle
                content.body = notifBody
                if let bundleID = session.terminalApp?.bundleIdentifier {
                    content.userInfo = ["terminalBundleID": bundleID]
                }
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                center.add(request) { addError in
                    log("sendNotification: add result error=\(addError?.localizedDescription ?? "nil")")
                }
            } else {
                // Fallback to osascript when UNUserNotification is not authorized
                let escapedTitle = notifTitle.replacingOccurrences(of: "\"", with: "\\\"")
                let escapedBody = notifBody.replacingOccurrences(of: "\"", with: "\\\"")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""]
                try? process.run()
                log("sendNotification: used osascript fallback")
            }
        }
    }

    // MARK: - Positioning

    private func findTerminalTopRight(terminalApp: NSRunningApplication?, panelWidth: CGFloat, panelHeight: CGFloat) -> NSPoint {
        guard let termApp = terminalApp else {
            return fallbackPosition(panelWidth: panelWidth, panelHeight: panelHeight)
        }

        let pid = termApp.processIdentifier
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let cgX = bounds["X"], let cgY = bounds["Y"],
                  let cgW = bounds["Width"], let cgH = bounds["Height"],
                  cgW > 100, cgH > 100 else {
                continue
            }

            let primaryHeight = NSScreen.screens[0].frame.height
            let termRightNS = cgX + cgW
            let termTopNS = primaryHeight - cgY

            var panelX = termRightNS - panelWidth - 16
            var panelY = termTopNS - panelHeight - 16

            let termCenterCG = CGPoint(x: cgX + cgW / 2, y: cgY + cgH / 2)
            for screen in NSScreen.screens {
                let screenCGY = primaryHeight - screen.frame.maxY
                let screenCGRect = CGRect(x: screen.frame.minX, y: screenCGY, width: screen.frame.width, height: screen.frame.height)
                if screenCGRect.contains(termCenterCG) {
                    let vf = screen.visibleFrame
                    panelX = min(max(panelX, vf.minX + 8), vf.maxX - panelWidth - 8)
                    panelY = min(max(panelY, vf.minY + 8), vf.maxY - panelHeight - 8)
                    break
                }
            }
            return NSPoint(x: panelX, y: panelY)
        }

        return fallbackPosition(panelWidth: panelWidth, panelHeight: panelHeight)
    }

    private func fallbackPosition(panelWidth: CGFloat, panelHeight: CGFloat) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        return NSPoint(x: vf.maxX - panelWidth - 20, y: vf.maxY - panelHeight - 20)
    }

    // MARK: - Helpers

    static func extractProjectName(from path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent().lastPathComponent
        guard dir.hasPrefix("-") || dir.contains("-") else { return nil }
        let segments = dir.split(separator: "-").map(String.init)
        guard let last = segments.last, !last.isEmpty else { return nil }
        return last
    }
}

/// Handles notification click → activate the correct terminal window
class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationClickHandler()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let bundleID = userInfo["terminalBundleID"] as? String,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}


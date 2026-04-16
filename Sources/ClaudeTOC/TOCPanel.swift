import AppKit
import SwiftUI
@preconcurrency import UserNotifications

/// A floating panel that doesn't steal focus from the terminal
class TOCHostingView<Content: View>: NSHostingView<Content> {
    private var cursorTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = cursorTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.pointingHand.push()
        super.mouseEntered(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.pointingHand.set()
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
        super.mouseExited(with: event)
    }
}

class TOCPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isFloatingPanel = true
        self.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        self.isOpaque = false
        self.backgroundColor = .clear
        self.isMovableByWindowBackground = false
        self.animationBehavior = .utilityWindow
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = true
    }
}

/// Get CGWindowID from an AXUIElement (private but stable API)
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

func windowIDFromAXElement(_ element: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
    return wid
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
    let terminalRows: Int?           // actual terminal rows from tty (for scroll calculation)
    var axWindow: AXUIElement?       // the specific terminal window at hook time
    var windowID: CGWindowID?        // stable window identifier for matching
    var panel: TOCPanel?
    var isPanelDismissed = false

    init(id: String, transcriptPath: String, projectName: String?, tocResult: TOCResult?,
         terminalType: TerminalType, terminalApp: NSRunningApplication?,
         terminalRows: Int? = nil, axWindow: AXUIElement? = nil, windowID: CGWindowID? = nil) {
        self.id = id
        self.transcriptPath = transcriptPath
        self.projectName = projectName
        self.tocResult = tocResult
        self.terminalType = terminalType
        self.terminalApp = terminalApp
        self.terminalRows = terminalRows
        self.axWindow = axWindow
        self.windowID = windowID
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
    private var pendingSessionLoads: [String: Task<Void, Never>] = [:]
    private var sessionLoadTokens: [String: UUID] = [:]
    var onSessionsChanged: (() -> Void)?
    var windowObserver: WindowObserver?
    private var notificationAuthorized = false

    /// Request notification authorization once at startup
    func requestNotificationAuthorization() {
        let center = UNUserNotificationCenter.current()
        NotificationClickHandler.shared.sessionManager = self
        center.delegate = NotificationClickHandler.shared
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            log("Notification authorization: granted=\(granted), error=\(error?.localizedDescription ?? "nil")")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.notificationAuthorized = granted
                }
            }
        }
    }

    var activeSessions: [TOCSession] {
        Array(sessions.values).sorted { $0.id < $1.id }
    }

    func addSession(transcriptPath: String, hookPid: Int32?, terminalBundleId: String? = nil, terminalColumns: Int? = nil, terminalRows: Int? = nil, tty: String? = nil, windowId: UInt32? = nil) {
        let sessionId = URL(fileURLWithPath: transcriptPath).deletingPathExtension().lastPathComponent
        let projectName = Self.extractProjectName(from: transcriptPath)

        log("SessionManager: adding session \(sessionId), project: \(projectName ?? "unknown"), tty: \(tty ?? "nil"), windowId: \(windowId.map(String.init) ?? "nil")")

        // Detect terminal — prefer bundle ID from hook if available
        let (terminalType, terminalApp) = TerminalAdapter.detectTerminal(hookPid: hookPid, bundleId: terminalBundleId)
        let termColumns = terminalColumns ?? TerminalAdapter.estimateColumns(app: terminalApp)

        // Match window: prefer hook-provided windowId, fall back to focused window
        var axWindow: AXUIElement?
        var windowID: CGWindowID?
        if let termApp = terminalApp {
            // Use window ID passed from hook (resolved via osascript in Terminal's context)
            if let wid = windowId {
                windowID = CGWindowID(wid)
                axWindow = findAXWindowByID(CGWindowID(wid), app: termApp)
                if axWindow != nil {
                    log("SessionManager: hook windowId=\(wid) matched AX window")
                } else {
                    log("SessionManager: hook windowId=\(wid) — no AX match, will use ID only")
                }
            }

            // Fallback: use focused window
            if windowID == nil {
                axWindow = WindowObserver.getFocusedWindow(of: termApp)
                if let ax = axWindow {
                    windowID = windowIDFromAXElement(ax)
                }
                log("SessionManager: fallback focused windowID=\(windowID.map(String.init) ?? "nil")")
            }

            // Register AXObserver for this terminal app (idempotent)
            windowObserver?.registerAXObserver(for: termApp)
        }

        // Remove existing session entirely so updateVisiblePanels() won't
        // recreate a panel with stale headings while the new data loads
        if let oldSession = sessions.removeValue(forKey: sessionId) {
            oldSession.panel?.orderOut(nil)
            oldSession.panel?.close()
            oldSession.panel = nil
        }
        onSessionsChanged?()

        pendingSessionLoads[sessionId]?.cancel()
        let loadToken = UUID()
        sessionLoadTokens[sessionId] = loadToken

        let loadTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                Task { @MainActor [weak self] in
                    guard let self = self,
                          self.sessionLoadTokens[sessionId] == loadToken else { return }
                    self.pendingSessionLoads.removeValue(forKey: sessionId)
                    self.sessionLoadTokens.removeValue(forKey: sessionId)
                }
            }

            var latestSnapshot: TranscriptParseSnapshot?
            for attempt in 0...5 {
                if Task.isCancelled { return }

                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(500))
                }

                let snapshot = await self.loadSnapshot(
                    transcriptPath: transcriptPath,
                    terminalColumns: termColumns
                )
                latestSnapshot = snapshot

                let ready = snapshot?.endsWithAssistant == true
                let headingCount = snapshot?.tocResult?.headings.count ?? 0
                log("SessionManager: retry \(attempt), headings=\(headingCount), ready=\(ready)")

                if ready {
                    await MainActor.run {
                        guard self.sessionLoadTokens[sessionId] == loadToken else { return }
                        self.finalizeSession(
                            sessionId: sessionId, transcriptPath: transcriptPath,
                            projectName: projectName, tocResult: snapshot?.tocResult,
                            terminalType: terminalType, terminalApp: terminalApp,
                            terminalRows: terminalRows, axWindow: axWindow, windowID: windowID
                        )
                    }
                    return
                }
            }

            if Task.isCancelled { return }

            log("SessionManager: retry timeout, using available data")
            await MainActor.run {
                guard self.sessionLoadTokens[sessionId] == loadToken else { return }
                self.finalizeSession(
                    sessionId: sessionId, transcriptPath: transcriptPath,
                    projectName: projectName, tocResult: latestSnapshot?.tocResult,
                    terminalType: terminalType, terminalApp: terminalApp,
                    terminalRows: terminalRows, axWindow: axWindow, windowID: windowID
                )
            }
        }

        pendingSessionLoads[sessionId] = loadTask
    }

    private func finalizeSession(
        sessionId: String, transcriptPath: String, projectName: String?,
        tocResult: TOCResult?, terminalType: TerminalType,
        terminalApp: NSRunningApplication?, terminalRows: Int? = nil,
        axWindow: AXUIElement?, windowID: CGWindowID?
    ) {
        // Close existing panel for this session
        sessions[sessionId]?.panel?.orderOut(nil)
        sessions[sessionId]?.panel?.close()
        sessions[sessionId]?.panel = nil

        let session = TOCSession(
            id: sessionId, transcriptPath: transcriptPath, projectName: projectName,
            tocResult: tocResult, terminalType: terminalType, terminalApp: terminalApp,
            terminalRows: terminalRows, axWindow: axWindow, windowID: windowID
        )

        sessions[sessionId] = session
        log("SessionManager: session \(sessionId) finalized, windowID=\(windowID.map(String.init) ?? "nil"), headings=\(tocResult?.headings.count ?? 0), total sessions: \(sessions.count)")

        // Only send notification if the terminal is not in the foreground
        let terminalIsActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == session.terminalApp?.processIdentifier
        let hasHeadings = tocResult?.headings.isEmpty == false

        if hasHeadings && terminalIsActive {
            showPanel(for: session)
            updateVisiblePanels()
        } else if !terminalIsActive {
            sendNotification(for: session)
        } else {
            log("SessionManager: skipping notification — terminal is active")
        }

        onSessionsChanged?()
    }

    private func loadSnapshot(transcriptPath: String, terminalColumns: Int) async -> TranscriptParseSnapshot? {
        await Task.detached(priority: .userInitiated) {
            TOCParser.parseSnapshot(transcriptPath: transcriptPath, terminalColumns: terminalColumns)
        }.value
    }

    /// Find an AXUIElement window by its CGWindowID
    private func findAXWindowByID(_ targetWID: CGWindowID, app: NSRunningApplication) -> AXUIElement? {
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }

        for window in windows {
            if let wid = windowIDFromAXElement(window), wid == targetWID {
                return window
            }
        }
        return nil
    }

    func closeAll() {
        for task in pendingSessionLoads.values {
            task.cancel()
        }
        pendingSessionLoads.removeAll()
        sessionLoadTokens.removeAll()
        for session in sessions.values {
            session.panel?.close()
            session.panel = nil
        }
        sessions.removeAll()
        onSessionsChanged?()
    }

    /// Hide the TOC panel but keep the session alive so it can be re-shown
    func hideSession(id: String) {
        guard let session = sessions[id] else { return }
        session.isPanelDismissed = true
        session.panel?.orderOut(nil)
        session.panel?.close()
        session.panel = nil
        log("SessionManager: hidden session \(id)")
        onSessionsChanged?()
    }

    /// Remove the session entirely (from menu bar "Remove" action)
    func removeSession(id: String) {
        pendingSessionLoads[id]?.cancel()
        pendingSessionLoads.removeValue(forKey: id)
        sessionLoadTokens.removeValue(forKey: id)

        let removedSession = sessions[id]
        removedSession?.panel?.close()
        sessions.removeValue(forKey: id)

        // Unregister AXObserver if no more sessions for this terminal app
        if let pid = removedSession?.terminalApp?.processIdentifier {
            let hasOtherSessions = sessions.values.contains { $0.terminalApp?.processIdentifier == pid }
            if !hasOtherSessions {
                windowObserver?.unregisterAXObserver(for: pid)
            }
        }
        onSessionsChanged?()
    }

    /// Re-show a hidden session's TOC panel
    func reshowSession(id: String) {
        guard let session = sessions[id], session.panel == nil,
              let tocResult = session.tocResult, !tocResult.headings.isEmpty else { return }
        session.isPanelDismissed = false
        showPanel(for: session)
        log("SessionManager: re-shown session \(id)")
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

    // MARK: - Visibility management

    /// Show/hide panels based on which terminal window is currently focused
    func updateVisiblePanels() {
        guard let activeApp = NSWorkspace.shared.frontmostApplication else {
            hideAllPanels()
            return
        }

        let activeAppPid = activeApp.processIdentifier

        // Check if the active app is a terminal that has sessions
        let sessionsForActiveApp = sessions.values.filter {
            $0.terminalApp?.processIdentifier == activeAppPid
        }

        if sessionsForActiveApp.isEmpty {
            // Active app is not a terminal with sessions — hide all
            hideAllPanels()
            return
        }

        // Get the focused window of the active terminal app and its stable ID
        let focusedAXWindow = WindowObserver.getFocusedWindow(of: activeApp)
        let focusedWID: CGWindowID? = focusedAXWindow.flatMap { windowIDFromAXElement($0) }

        log("updateVisiblePanels: activeApp=\(activeApp.bundleIdentifier ?? "?") pid=\(activeAppPid), focusedWID=\(focusedWID.map(String.init) ?? "nil"), focusedAX=\(focusedAXWindow != nil)")

        for session in sessions.values {
            if session.terminalApp?.processIdentifier == activeAppPid {
                // This session belongs to the active app — match by CGWindowID
                log("  session \(session.id.prefix(8)): sessionWID=\(session.windowID.map(String.init) ?? "nil"), axWindow=\(session.axWindow != nil)")
                if let sessionWID = session.windowID, let currentWID = focusedWID {
                    if sessionWID == currentWID {
                        log("  → MATCH, showing")
                        // Update axWindow reference in case it went stale
                        session.axWindow = focusedAXWindow
                        if session.tocResult?.headings.isEmpty == false, !session.isPanelDismissed {
                            repositionAndShow(session)
                        } else {
                            session.panel?.orderOut(nil)
                        }
                    } else {
                        log("  → MISMATCH (\(sessionWID) != \(currentWID)), hiding")
                        session.panel?.orderOut(nil)
                    }
                } else if focusedWID == nil {
                    // Can't determine focused window — show all as fallback
                    log("  → focusedWID nil, fallback show")
                    if session.tocResult?.headings.isEmpty == false, !session.isPanelDismissed {
                        repositionAndShow(session)
                    } else {
                        session.panel?.orderOut(nil)
                    }
                } else {
                    // Session has no windowID but we know the focused window — hide it
                    log("  → session has no WID, hiding")
                    session.panel?.orderOut(nil)
                }
            } else {
                session.panel?.orderOut(nil)
            }
        }
        onSessionsChanged?()
    }

    /// Reposition currently visible panels (e.g. after window move)
    func repositionVisiblePanels() {
        for session in sessions.values {
            guard let panel = session.panel, panel.isVisible else { continue }
            repositionAndShow(session)
        }
    }

    /// Reposition with animation (e.g. after window resize/zoom)
    func repositionVisiblePanelsAnimated() {
        for session in sessions.values {
            guard let panel = session.panel, panel.isVisible else { continue }
            repositionAndShow(session, animate: true)
        }
    }

    private func hideAllPanels() {
        for session in sessions.values {
            session.panel?.orderOut(nil)
        }
    }

    private func repositionAndShow(_ session: TOCSession, animate: Bool = false) {
        guard let panel = ensurePanel(for: session) else { return }
        let panelW = panel.frame.width
        let panelH = panel.frame.height

        let origin: NSPoint
        if let axWindow = session.axWindow,
           let windowFrame = axWindowFrame(axWindow) {
            origin = panelOriginFromWindowFrame(windowFrame, panelWidth: panelW, panelHeight: panelH)
        } else {
            origin = findTerminalTopRight(session: session, panelWidth: panelW, panelHeight: panelH)
        }

        if panel.isVisible {
            if animate {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.3
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrameOrigin(origin)
                }
            } else {
                panel.setFrameOrigin(origin)
            }
        } else {
            panel.setFrameOrigin(origin)
            panel.orderFrontRegardless()
        }
    }

    private func axWindowFrame(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = axValue(from: posRef, type: .cgPoint),
              let sizeValue = axValue(from: sizeRef, type: .cgSize) else {
            return nil
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: pos, size: size)
    }

    private func panelOriginFromWindowFrame(_ windowFrame: CGRect, panelWidth: CGFloat, panelHeight: CGFloat) -> NSPoint {
        let primaryHeight = (NSScreen.screens.first ?? NSScreen.main)?.frame.height ?? 0
        let titleBarHeight: CGFloat = 28
        let termRightNS = windowFrame.maxX
        let termTopNS = primaryHeight - windowFrame.minY

        var panelX = termRightNS - panelWidth - 16
        var panelY = termTopNS - panelHeight - titleBarHeight - 16

        let termCenterCG = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
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

    // MARK: - Panel creation

    @discardableResult
    private func ensurePanel(for session: TOCSession) -> TOCPanel? {
        if let panel = session.panel {
            return panel
        }

        guard let tocResult = session.tocResult, !tocResult.headings.isEmpty else { return nil }
        let sessionId = session.id

        let hostingView = TOCHostingView(rootView: TOCView(
            headings: tocResult.headings,
            totalLines: tocResult.totalLines,
            onHeadingClick: { [weak self] heading in
                self?.handleHeadingClick(heading, sessionId: sessionId)
            },
            onDismiss: { [weak self] in
                self?.hideSession(id: sessionId)
            }
        ))

        // Let SwiftUI determine the intrinsic size
        let fittingSize = hostingView.fittingSize
        let panelWidth = fittingSize.width
        let panelHeight = fittingSize.height

        let panelOrigin = findTerminalTopRight(session: session, panelWidth: panelWidth, panelHeight: panelHeight)
        let panelRect = NSRect(x: panelOrigin.x, y: panelOrigin.y, width: panelWidth, height: panelHeight)

        let newPanel = TOCPanel(contentRect: panelRect)
        newPanel.contentView = hostingView
        session.panel = newPanel
        return newPanel
    }

    private func showPanel(for session: TOCSession) {
        guard ensurePanel(for: session) != nil else { return }
        repositionAndShow(session)
    }

    private func handleHeadingClick(_ heading: TOCHeading, sessionId: String) {
        guard let session = sessions[sessionId],
              let tocResult = session.tocResult,
              let termApp = session.terminalApp else { return }
        TerminalAdapter.jumpToHeading(
            heading: heading,
            responseTerminalLines: tocResult.estimatedTerminalLines,
            app: termApp,
            terminalType: session.terminalType,
            terminalRows: session.terminalRows
        )
    }

    /// Activate the terminal and scroll to the first line of the response
    func scrollToResponseStart(sessionId: String) {
        guard let session = sessions[sessionId],
              let tocResult = session.tocResult,
              let termApp = session.terminalApp else { return }
        // Create a synthetic heading at line 0 (start of response)
        let startHeading = TOCHeading(level: 1, title: "", lineInResponse: 0, estimatedTerminalLine: 0)
        TerminalAdapter.jumpToHeading(
            heading: startHeading,
            responseTerminalLines: tocResult.estimatedTerminalLines,
            app: termApp,
            terminalType: session.terminalType,
            terminalRows: session.terminalRows
        )
    }

    // MARK: - Notification

    private func sendNotification(for session: TOCSession) {
        // Title: one line, keep it short (max ~30 display columns including "Re: " prefix)
        let notifTitle: String
        if let q = session.tocResult?.lastUserQuery {
            let trimmed = q.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            // "Re: " takes 4 columns, leave 26 for the query text
            notifTitle = "Re: \(TOCParser.truncateToDisplayWidth(trimmed, maxWidth: 26))"
        } else {
            notifTitle = "Claude responded"
        }
        // Body: up to 2 lines of response preview
        let notifBody = session.tocResult?.responsePreview ?? ""

        if notificationAuthorized {
            let content = UNMutableNotificationContent()
            content.title = notifTitle
            content.body = notifBody
            content.userInfo = [
                "sessionId": session.id,
                "terminalBundleID": session.terminalApp?.bundleIdentifier ?? "",
            ]
            let center = UNUserNotificationCenter.current()
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

    // MARK: - Positioning

    private func findTerminalTopRight(session: TOCSession, panelWidth: CGFloat, panelHeight: CGFloat) -> NSPoint {
        guard let termApp = session.terminalApp else {
            return fallbackPosition(panelWidth: panelWidth, panelHeight: panelHeight)
        }

        if let windowFrame = cgWindowFrame(windowID: session.windowID, pid: termApp.processIdentifier) {
            return panelOriginFromWindowFrame(windowFrame, panelWidth: panelWidth, panelHeight: panelHeight)
        }

        return fallbackPosition(panelWidth: panelWidth, panelHeight: panelHeight)
    }

    private func fallbackPosition(panelWidth: CGFloat, panelHeight: CGFloat) -> NSPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSPoint(x: 20, y: 20)
        }
        let vf = screen.visibleFrame
        return NSPoint(x: vf.maxX - panelWidth - 20, y: vf.maxY - panelHeight - 20)
    }

    private func cgWindowFrame(windowID: CGWindowID?, pid: pid_t) -> CGRect? {
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

            if let targetWindowID = windowID,
               let windowNumber = windowInfo[kCGWindowNumber as String] as? UInt32,
               CGWindowID(windowNumber) != targetWindowID {
                continue
            }

            return CGRect(x: cgX, y: cgY, width: cgW, height: cgH)
        }

        return nil
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

private func axValue(from ref: CFTypeRef?, type: AXValueType) -> AXValue? {
    guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
    let value = unsafeDowncast(ref, to: AXValue.self)
    return AXValueGetType(value) == type ? value : nil
}

/// Handles notification click → activate the correct terminal window and scroll to response
class NotificationClickHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationClickHandler()
    weak var sessionManager: TOCSessionManager?

    private var pendingScrollSessionId: String?
    private var activationObserver: NSObjectProtocol?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // Handle update notification
        if userInfo["action"] as? String == "showUpdateWindow" {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Updater.shared.showUpdateWindow()
                }
            }
            completionHandler()
            return
        }

        let sessionId = userInfo["sessionId"] as? String

        // Activate terminal window
        if let bundleID = userInfo["terminalBundleID"] as? String, !bundleID.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            // Wait for the terminal to actually become frontmost before scrolling
            if let sid = sessionId {
                pendingScrollSessionId = sid
                // Remove any previous observer
                if let obs = activationObserver {
                    NSWorkspace.shared.notificationCenter.removeObserver(obs)
                }
                activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil, queue: .main
                ) { [weak self] notification in
                    guard let self = self,
                          let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          app.bundleIdentifier == bundleID,
                          let sid = self.pendingScrollSessionId else { return }
                    // Terminal is now active — scroll
                    MainActor.assumeIsolated {
                        self.sessionManager?.scrollToResponseStart(sessionId: sid)
                    }
                    self.pendingScrollSessionId = nil
                    if let obs = self.activationObserver {
                        NSWorkspace.shared.notificationCenter.removeObserver(obs)
                        self.activationObserver = nil
                    }
                }
            }
            NSWorkspace.shared.openApplication(at: appURL, configuration: .init())
        } else if let sid = sessionId {
            // Terminal already active or unknown — scroll directly
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.sessionManager?.scrollToResponseStart(sessionId: sid)
                }
            }
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

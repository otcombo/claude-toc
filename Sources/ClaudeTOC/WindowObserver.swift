import AppKit
import Foundation

/// Observes terminal window focus, Space changes, and window move/resize
/// to show/hide/reposition TOC panels for the correct session.
@MainActor
class WindowObserver {
    weak var sessionManager: TOCSessionManager?
    private var axObservers: [pid_t: AXObserver] = [:]
    private var axRunLoopSources: [pid_t: CFRunLoopSource] = [:]
    private var trackedWindows: [pid_t: AXUIElement] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var lastKnownWindowFrames: [String: CGRect] = [:]
    private var axTrusted = false
    /// Prevent premature deallocation while AXObserver callbacks hold a raw pointer to self.
    /// Incremented on first registerAXObserver, decremented when all observers are removed.
    private var retainedSelf: Unmanaged<WindowObserver>?

    func start() {
        axTrusted = AXIsProcessTrusted()
        log("WindowObserver: AXIsProcessTrusted=\(axTrusted)")

        let nc = NSWorkspace.shared.notificationCenter

        let activateToken = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            log("WindowObserver: app activated — \(app.bundleIdentifier ?? "unknown") pid=\(app.processIdentifier)")
            MainActor.assumeIsolated {
                self?.handleAppOrSpaceChange()
            }
        }
        workspaceObservers.append(activateToken)

        let spaceToken = nc.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            log("WindowObserver: space changed")
            MainActor.assumeIsolated {
                self?.handleAppOrSpaceChange()
            }
        }
        workspaceObservers.append(spaceToken)

        // CGWindowList polling fallback for move/resize when AX is unavailable
        startPolling()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()

        for (pid, observer) in axObservers {
            let axApp = AXUIElementCreateApplication(pid)
            AXObserverRemoveNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString)
            if let window = trackedWindows[pid] {
                AXObserverRemoveNotification(observer, window, kAXWindowMovedNotification as CFString)
                AXObserverRemoveNotification(observer, window, kAXWindowResizedNotification as CFString)
            }
            if let source = axRunLoopSources[pid] {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            }
        }
        axObservers.removeAll()
        axRunLoopSources.removeAll()
        trackedWindows.removeAll()

        // Release the safety retain now that all callbacks are removed
        if let retained = retainedSelf {
            retained.release()
            retainedSelf = nil
        }
    }

    // MARK: - AXObserver per terminal app

    func registerAXObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier

        // Re-check AX trust (user might have granted since launch)
        if !axTrusted {
            axTrusted = AXIsProcessTrusted()
            if axTrusted {
                log("WindowObserver: AX permission now granted")
            }
        }

        guard axTrusted, axObservers[pid] == nil else { return }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axCallback, &observer)
        guard result == .success, let observer = observer else {
            log("WindowObserver: failed to create AXObserver for pid \(pid), error=\(result.rawValue)")
            return
        }

        let axApp = AXUIElementCreateApplication(pid)

        // Retain self while any AXObserver holds a raw pointer to us
        if retainedSelf == nil {
            retainedSelf = Unmanaged.passRetained(self)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, refcon)
        let runLoopSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        axObservers[pid] = observer
        axRunLoopSources[pid] = runLoopSource

        trackFocusedWindow(for: pid, observer: observer)
        log("WindowObserver: registered AXObserver for \(app.bundleIdentifier ?? "?") pid=\(pid)")
    }

    func unregisterAXObserver(for pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        let axApp = AXUIElementCreateApplication(pid)
        AXObserverRemoveNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString)
        untrackWindow(for: pid, observer: observer)
        if let source = axRunLoopSources.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        lastKnownWindowFrames.removeValue(forKey: "pid:\(pid)")
        log("WindowObserver: unregistered AXObserver for pid \(pid)")

        // Release the safety retain when no more AXObservers hold our pointer
        if axObservers.isEmpty, let retained = retainedSelf {
            retained.release()
            retainedSelf = nil
        }
    }

    // MARK: - Window-level move/resize tracking (AX)

    private func trackFocusedWindow(for pid: pid_t, observer: AXObserver) {
        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success else {
            log("WindowObserver: trackFocusedWindow — no focused window for pid \(pid)")
            return
        }
        guard let window = axElement(from: windowRef) else {
            log("WindowObserver: focused window had unexpected type for pid \(pid)")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        untrackWindow(for: pid, observer: observer)

        let moveResult = AXObserverAddNotification(observer, window, kAXWindowMovedNotification as CFString, refcon)
        let resizeResult = AXObserverAddNotification(observer, window, kAXWindowResizedNotification as CFString, refcon)
        trackedWindows[pid] = window
        log("WindowObserver: tracking move/resize for pid \(pid), move=\(moveResult == .success), resize=\(resizeResult == .success)")
    }

    private func untrackWindow(for pid: pid_t, observer: AXObserver) {
        guard let oldWindow = trackedWindows.removeValue(forKey: pid) else { return }
        AXObserverRemoveNotification(observer, oldWindow, kAXWindowMovedNotification as CFString)
        AXObserverRemoveNotification(observer, oldWindow, kAXWindowResizedNotification as CFString)
    }

    // MARK: - CGWindowList polling fallback

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollWindowPositions()
            }
        }
    }

    private func pollWindowPositions() {
        guard let sm = sessionManager else { return }

        // Only poll for sessions that have visible panels
        let visibleSessions = sm.activeSessions.filter { $0.panel?.isVisible == true }
        guard !visibleSessions.isEmpty else { return }

        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        for session in visibleSessions {
            guard let termApp = session.terminalApp else { continue }
            let pid = termApp.processIdentifier
            let frameKey = session.windowID.map { "wid:\($0)" } ?? "pid:\(pid)"

            for windowInfo in windowList {
                guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                      ownerPID == pid,
                      matchesWindow(sessionWindowID: session.windowID, windowInfo: windowInfo),
                      let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = bounds["X"], let y = bounds["Y"],
                      let w = bounds["Width"], let h = bounds["Height"],
                      w > 100, h > 100 else { continue }

                let frame = CGRect(x: x, y: y, width: w, height: h)
                if let lastFrame = lastKnownWindowFrames[frameKey], lastFrame == frame {
                    break  // No change
                }

                // Window moved or resized
                lastKnownWindowFrames[frameKey] = frame
                sm.repositionVisiblePanels()
                break
            }
        }
    }

    // MARK: - Core visibility logic

    private func handleAppOrSpaceChange() {
        if let activeApp = NSWorkspace.shared.frontmostApplication {
            let pid = activeApp.processIdentifier
            if let observer = axObservers[pid] {
                trackFocusedWindow(for: pid, observer: observer)
            }
        }
        sessionManager?.updateVisiblePanels()
    }

    fileprivate func handleAXNotificationByName(_ name: String) {
        if name == kAXFocusedWindowChangedNotification as String {
            log("WindowObserver: AX focused window changed")
            if let activeApp = NSWorkspace.shared.frontmostApplication {
                let pid = activeApp.processIdentifier
                if let observer = axObservers[pid] {
                    trackFocusedWindow(for: pid, observer: observer)
                }
            }
            sessionManager?.updateVisiblePanels()
        } else if name == kAXWindowMovedNotification as String {
            sessionManager?.repositionVisiblePanels()
        } else if name == kAXWindowResizedNotification as String {
            sessionManager?.repositionVisiblePanelsAnimated()
        }
    }

    // MARK: - Helpers

    static func getFocusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success else {
            return nil
        }
        return axElement(from: windowRef)
    }

    private func matchesWindow(sessionWindowID: CGWindowID?, windowInfo: [String: Any]) -> Bool {
        guard let sessionWindowID = sessionWindowID else { return true }
        guard let windowNumber = windowInfo[kCGWindowNumber as String] as? UInt32 else {
            return false
        }
        return CGWindowID(windowNumber) == sessionWindowID
    }
}

// MARK: - AXObserver C callback

private func axCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let windowObserver = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
    let notifName = notification as String

    let deliver = {
        MainActor.assumeIsolated {
            windowObserver.handleAXNotificationByName(notifName)
        }
    }

    if Thread.isMainThread {
        deliver()
    } else {
        Task { @MainActor in
            windowObserver.handleAXNotificationByName(notifName)
        }
    }
}

private func axElement(from ref: CFTypeRef?) -> AXUIElement? {
    guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(ref, to: AXUIElement.self)
}

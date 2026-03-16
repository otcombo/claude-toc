import AppKit
import Foundation

/// Persistent log file handle — opened once, reused for all writes.
/// Truncated on launch if over 1 MB (simple log rotation).
private let logHandle: FileHandle? = {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("claude-toc.log")
    let fm = FileManager.default

    // Simple rotation: truncate if over 1 MB
    if let attrs = try? fm.attributesOfItem(atPath: path),
       let size = attrs[.size] as? UInt64, size > 1_048_576 {
        try? fm.removeItem(atPath: path)
    }

    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
    handle.seekToEndOfFile()
    return handle
}()

func log(_ msg: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(msg)\n"
    fputs(line, stderr)
    if let data = line.data(using: .utf8) {
        logHandle?.write(data)
    }
}

enum TerminalType: String, Sendable {
    case kitty = "net.kovidgoyal.kitty"
    case iterm2 = "com.googlecode.iterm2"
    case terminalApp = "com.apple.Terminal"
    case warp = "dev.warp.Warp-Stable"
    case alacritty = "org.alacritty"
    case termius = "com.termius-dmg.mac"
    case unknown = "unknown"
}

@MainActor
enum TerminalAdapter {

    static func detectTerminal(hookPid: Int32? = nil, bundleId providedBundleId: String? = nil) -> (TerminalType, NSRunningApplication?) {
        let knownBundleIds: [String: TerminalType] = [
            "net.kovidgoyal.kitty": .kitty,
            "com.googlecode.iterm2": .iterm2,
            "com.apple.Terminal": .terminalApp,
            "dev.warp.Warp-Stable": .warp,
            "org.alacritty": .alacritty,
            "com.termius-dmg.mac": .termius,
        ]

        let runningApps = NSWorkspace.shared.runningApplications

        // Prefer terminal bundle ID passed from hook (via $TERM_PROGRAM etc.)
        if let bid = providedBundleId {
            let termType = knownBundleIds[bid] ?? .unknown
            if let app = runningApps.first(where: { $0.bundleIdentifier == bid }) {
                log("detectTerminal: using provided bundleId \(bid)")
                return (termType, app)
            }
            log("detectTerminal: provided bundleId \(bid) not found in running apps")
        }

        // Fallback: walk process tree from hook PID
        var pidToApp: [Int32: NSRunningApplication] = [:]
        for app in runningApps {
            pidToApp[app.processIdentifier] = app
        }

        if let startPid = hookPid {
            log("detectTerminal: walking process tree from pid \(startPid)")
            var currentPid = startPid
            var visited = Set<Int32>()
            while currentPid > 1 && !visited.contains(currentPid) {
                visited.insert(currentPid)
                log("  checking pid \(currentPid)")
                if let app = pidToApp[currentPid],
                   let bundleId = app.bundleIdentifier,
                   let termType = knownBundleIds[bundleId] {
                    log("  → found terminal: \(bundleId) at pid \(currentPid)")
                    return (termType, app)
                }
                currentPid = getParentPid(currentPid)
            }
            log("detectTerminal: no terminal found in process tree")
        }

        for app in runningApps {
            if let bundleId = app.bundleIdentifier,
               let termType = knownBundleIds[bundleId],
               app.isActive || app.ownsMenuBar {
                log("detectTerminal: fallback found active terminal \(bundleId)")
                return (termType, app)
            }
        }

        for app in runningApps {
            if let bundleId = app.bundleIdentifier,
               let termType = knownBundleIds[bundleId] {
                log("detectTerminal: fallback found running terminal \(bundleId)")
                return (termType, app)
            }
        }

        log("detectTerminal: no known terminal found")
        return (.unknown, nil)
    }

    private static func getParentPid(_ pid: Int32) -> Int32 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, 4, &info, &size, nil, 0)
        if result == 0 {
            return info.kp_eproc.e_ppid
        }
        return 0
    }

    static func estimateColumns(app: NSRunningApplication?) -> Int {
        guard let app = app else { return 80 }
        let pid = app.processIdentifier
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = bounds["Width"],
                  w > 100 else { continue }
            let effectiveWidth = w - 40
            let columns = Int(effectiveWidth / 7.2)
            log("estimateColumns: windowWidth=\(w), columns=\(columns)")
            return max(40, min(columns, 200))
        }
        return 80
    }

    static func activateTerminal(_ app: NSRunningApplication) {
        log("activateTerminal: \(app.bundleIdentifier ?? "unknown") pid=\(app.processIdentifier)")
        let result = app.activate()
        log("activateTerminal result: \(result)")
    }

    /// Jump to heading by scrolling the terminal via Accessibility API
    static func jumpToHeading(
        heading: TOCHeading,
        responseTerminalLines: Int,
        app: NSRunningApplication
    ) {
        let pid = app.processIdentifier
        log("jumpToHeading: '\(heading.title)' estLine=\(heading.estimatedTerminalLine) responseLines=\(responseTerminalLines) pid=\(pid)")

        // Activate terminal
        activateTerminal(app)

        // Walk AX hierarchy: App → Window → ... → ScrollArea → TextArea + ScrollBar
        let axApp = AXUIElementCreateApplication(pid)

        // Get focused window (or fall back to first window)
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) != .success {
            log("jumpToHeading: failed to get focused window, trying windows list")
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement],
                  let firstWindow = windows.first else {
                log("jumpToHeading: no windows found")
                return
            }
            windowRef = firstWindow
        }
        let window = windowRef as! AXUIElement

        // Find the AXScrollArea recursively
        guard let scrollArea = findAXElement(in: window, role: kAXScrollAreaRole as String) else {
            log("jumpToHeading: no AXScrollArea found")
            return
        }

        // Get the AXTextArea inside the scroll area
        guard let textArea = findAXElement(in: scrollArea, role: kAXTextAreaRole as String) else {
            log("jumpToHeading: no AXTextArea found")
            return
        }

        // Get cursor line number (≈ total lines, since Claude just finished responding)
        var cursorLineRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(textArea, kAXInsertionPointLineNumberAttribute as CFString, &cursorLineRef) == .success,
              let cursorLine = (cursorLineRef as? NSNumber)?.intValue else {
            log("jumpToHeading: failed to get AXInsertionPointLineNumber")
            return
        }
        log("jumpToHeading: cursorLine (total lines) = \(cursorLine)")

        // Get visible character range to determine visible rows
        var visRangeRef: CFTypeRef?
        var visibleRows = 40 // fallback
        if AXUIElementCopyAttributeValue(textArea, kAXVisibleCharacterRangeAttribute as CFString, &visRangeRef) == .success {
            let visRange = visRangeRef as! AXValue
            var cfRange = CFRange(location: 0, length: 0)
            AXValueGetValue(visRange, .cfRange, &cfRange)
            log("jumpToHeading: visibleCharRange location=\(cfRange.location) length=\(cfRange.length)")

            // Use parameterized attribute to get line number for start and end of visible range
            let startIndex = cfRange.location
            let endIndex = cfRange.location + cfRange.length - 1

            var startLineRef: CFTypeRef?
            var endLineRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(textArea, kAXLineForIndexParameterizedAttribute as CFString, NSNumber(value: startIndex) as CFTypeRef, &startLineRef) == .success,
               AXUIElementCopyParameterizedAttributeValue(textArea, kAXLineForIndexParameterizedAttribute as CFString, NSNumber(value: max(0, endIndex)) as CFTypeRef, &endLineRef) == .success,
               let startLine = (startLineRef as? NSNumber)?.intValue,
               let endLine = (endLineRef as? NSNumber)?.intValue {
                visibleRows = max(endLine - startLine, 1)
                log("jumpToHeading: visibleRows = \(visibleRows) (lines \(startLine)...\(endLine))")
            }
        }

        // Calculate target absolute line by detecting Claude UI chrome dynamically.
        // After Claude responds, the terminal shows separator lines (─────) below the
        // response. We search backwards from the cursor to find the first separator,
        // which marks the boundary between response content and Claude's prompt UI.
        let claudeUIChrome = detectChromeLines(textArea: textArea, cursorLine: cursorLine)
        let responseEndLine = cursorLine - claudeUIChrome
        let headingAbsLine = responseEndLine - responseTerminalLines + heading.estimatedTerminalLine
        log("jumpToHeading: responseEndLine=\(responseEndLine) headingAbsLine=\(headingAbsLine)")

        // Scroll bar value: proportion of scroll position
        // value = firstVisibleLine / (totalLines - visibleRows)
        // We want heading at top of viewport, so firstVisibleLine = headingAbsLine
        let maxScrollLine = cursorLine - visibleRows
        guard maxScrollLine > 0 else {
            log("jumpToHeading: content fits in viewport, no scroll needed")
            return
        }

        let scrollValue = Float(max(0, headingAbsLine)) / Float(maxScrollLine)
        let clampedValue = min(max(scrollValue, 0.0), 1.0)
        log("jumpToHeading: scrollValue = \(headingAbsLine) / \(maxScrollLine) = \(scrollValue) → clamped \(clampedValue)")

        // Get the vertical scroll bar
        var scrollBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(scrollArea, kAXVerticalScrollBarAttribute as CFString, &scrollBarRef) == .success else {
            log("jumpToHeading: no vertical scroll bar found")
            return
        }
        let scrollBar = scrollBarRef as! AXUIElement

        // Set the scroll position
        let result = AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, NSNumber(value: clampedValue) as CFTypeRef)
        log("jumpToHeading: set scroll bar to \(clampedValue), result = \(result == .success ? "success" : "failed (\(result.rawValue))")")
    }

    // MARK: - Chrome detection

    /// Detect the number of UI chrome lines between the response end and cursor
    /// by scanning backwards from the cursor looking for the separator (─) pattern.
    /// Falls back to 4 if detection fails.
    private static func detectChromeLines(textArea: AXUIElement, cursorLine: Int) -> Int {
        let fallback = 4
        // Scan the last ~10 lines before cursor looking for separator characters
        let scanStart = max(0, cursorLine - 10)
        for lineNum in stride(from: cursorLine, through: scanStart, by: -1) {
            // Get the character range for this line
            var rangeRef: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                textArea,
                kAXRangeForLineParameterizedAttribute as CFString,
                NSNumber(value: lineNum) as CFTypeRef,
                &rangeRef
            ) == .success else { continue }

            let axRange = rangeRef as! AXValue
            var cfRange = CFRange(location: 0, length: 0)
            AXValueGetValue(axRange, .cfRange, &cfRange)

            guard cfRange.length > 0 else { continue }

            // Get the text content of this line
            let rangeValue = AXValueCreate(.cfRange, &cfRange)!
            var textRef: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                textArea,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue as CFTypeRef,
                &textRef
            ) == .success,
                  let lineText = textRef as? String else { continue }

            // Claude's separator is a line of box-drawing characters (─ U+2500)
            let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 3 && trimmed.allSatisfy({ $0 == "─" || $0 == "━" || $0 == "—" || $0 == "-" }) {
                let chrome = cursorLine - lineNum
                log("detectChromeLines: found separator at line \(lineNum), chrome=\(chrome)")
                return chrome
            }
        }

        log("detectChromeLines: no separator found, using fallback=\(fallback)")
        return fallback
    }

    // MARK: - AX helpers

    /// Recursively find an AXUIElement with the given role
    private static func findAXElement(in element: AXUIElement, role targetRole: String, depth: Int = 0) -> AXUIElement? {
        guard depth < 10 else { return nil }

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String, role == targetRole {
            return element
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let found = findAXElement(in: child, role: targetRole, depth: depth + 1) {
                return found
            }
        }
        return nil
    }
}

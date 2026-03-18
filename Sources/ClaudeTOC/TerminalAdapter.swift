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
    case ghostty = "com.mitchellh.ghostty"
    case wezterm = "com.github.wez.wezterm"
    case wave = "dev.commandline.waveterm"
    case rio = "com.raphaelamorim.rio"
    case tabby = "org.tabby"
    case cursor = "com.todesktop.230313mzl4w4u92"
    case hyper = "co.zeit.hyper"
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
            "com.mitchellh.ghostty": .ghostty,
            "com.github.wez.wezterm": .wezterm,
            "dev.commandline.waveterm": .wave,
            "com.raphaelamorim.rio": .rio,
            "org.tabby": .tabby,
            "com.todesktop.230313mzl4w4u92": .cursor,
            "co.zeit.hyper": .hyper,
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

    /// Scroll tier for each terminal type
    enum ScrollTier {
        case axScrollBar    // Tier A: native AX scroll bar (Terminal.app, iTerm2)
        case cliIPC         // Tier B: terminal CLI/IPC (Kitty, WezTerm)
        case keySimulation  // Tier C: CGEvent keyboard simulation (all others)
    }

    static func scrollTier(for terminalType: TerminalType) -> ScrollTier {
        switch terminalType {
        case .terminalApp, .iterm2:
            return .axScrollBar
        case .kitty, .wezterm:
            return .cliIPC
        case .ghostty, .alacritty, .warp, .rio, .cursor, .tabby, .hyper, .wave, .termius, .unknown:
            return .keySimulation
        }
    }

    /// Jump to heading — dispatches to the appropriate scroll method based on terminal type
    static func jumpToHeading(
        heading: TOCHeading,
        responseTerminalLines: Int,
        app: NSRunningApplication,
        terminalType: TerminalType = .unknown
    ) {
        let pid = app.processIdentifier
        let tier = scrollTier(for: terminalType)
        log("jumpToHeading: '\(heading.title)' estLine=\(heading.estimatedTerminalLine) responseLines=\(responseTerminalLines) pid=\(pid) tier=\(tier) terminal=\(terminalType.rawValue)")

        activateTerminal(app)

        switch tier {
        case .axScrollBar:
            jumpViaAXScrollBar(heading: heading, responseTerminalLines: responseTerminalLines, pid: pid)
        case .cliIPC:
            jumpViaCLI(heading: heading, responseTerminalLines: responseTerminalLines, terminalType: terminalType)
        case .keySimulation:
            jumpViaKeySimulation(heading: heading, responseTerminalLines: responseTerminalLines, pid: pid)
        }
    }

    // MARK: - Tier A: AX Text Search + ScrollBar

    private static func jumpViaAXScrollBar(heading: TOCHeading, responseTerminalLines: Int, pid: Int32) {
        let axApp = AXUIElementCreateApplication(pid)

        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) != .success {
            log("tierA: failed to get focused window, trying windows list")
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement],
                  let firstWindow = windows.first else {
                log("tierA: no windows found")
                return
            }
            windowRef = firstWindow
        }
        let window = windowRef as! AXUIElement

        guard let scrollArea = findAXElement(in: window, role: kAXScrollAreaRole as String) else {
            log("tierA: no AXScrollArea found")
            return
        }

        guard let textArea = findAXElement(in: scrollArea, role: kAXTextAreaRole as String) else {
            log("tierA: no AXTextArea found")
            return
        }

        // Get full buffer text via AXValue
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(textArea, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String, !fullText.isEmpty else {
            log("tierA: failed to get AXValue (full text)")
            return
        }
        log("tierA: fullText length = \(fullText.count) chars")

        // Search for heading in terminal buffer
        let targetLine = findHeadingLine(heading: heading, fullText: fullText, textArea: textArea)
        guard let targetLine = targetLine else {
            log("tierA: heading not found in buffer, aborting")
            return
        }
        log("tierA: targetLine = \(targetLine)")

        // Get total lines (cursor line ≈ last line in buffer)
        var cursorLineRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(textArea, kAXInsertionPointLineNumberAttribute as CFString, &cursorLineRef) == .success,
              let totalLines = (cursorLineRef as? NSNumber)?.intValue else {
            log("tierA: failed to get AXInsertionPointLineNumber")
            return
        }

        // Get visible rows
        var visibleRows = 40
        var visRangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(textArea, kAXVisibleCharacterRangeAttribute as CFString, &visRangeRef) == .success {
            let visRange = visRangeRef as! AXValue
            var cfRange = CFRange(location: 0, length: 0)
            AXValueGetValue(visRange, .cfRange, &cfRange)

            var startLineRef: CFTypeRef?
            var endLineRef: CFTypeRef?
            let endIndex = max(0, cfRange.location + cfRange.length - 1)
            if AXUIElementCopyParameterizedAttributeValue(textArea, kAXLineForIndexParameterizedAttribute as CFString, NSNumber(value: cfRange.location) as CFTypeRef, &startLineRef) == .success,
               AXUIElementCopyParameterizedAttributeValue(textArea, kAXLineForIndexParameterizedAttribute as CFString, NSNumber(value: endIndex) as CFTypeRef, &endLineRef) == .success,
               let startLine = (startLineRef as? NSNumber)?.intValue,
               let endLine = (endLineRef as? NSNumber)?.intValue {
                visibleRows = max(endLine - startLine, 1)
                log("tierA: visibleRows = \(visibleRows)")
            }
        }

        let maxScrollLine = totalLines - visibleRows
        guard maxScrollLine > 0 else {
            log("tierA: content fits in viewport, no scroll needed")
            return
        }

        // Offset by 1 line so the heading appears near the top with just the blank line above
        let scrollValue = Float(max(0, targetLine - 1)) / Float(maxScrollLine)
        let clampedValue = min(max(scrollValue, 0.0), 1.0)
        log("tierA: scrollValue = \(targetLine) / \(maxScrollLine) = \(clampedValue)")

        var scrollBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(scrollArea, kAXVerticalScrollBarAttribute as CFString, &scrollBarRef) == .success else {
            log("tierA: no vertical scroll bar found")
            return
        }
        let scrollBar = scrollBarRef as! AXUIElement

        let result = AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, NSNumber(value: clampedValue) as CFTypeRef)
        log("tierA: set scroll bar to \(clampedValue), result = \(result == .success ? "success" : "failed (\(result.rawValue))")")
    }

    /// Search for a heading in the AX text buffer and return its exact line number.
    /// Strategy: search for "\n## Title\n" pattern (with markdown prefix) backwards from end.
    /// Falls back to plain title search if markdown pattern not found.
    private static func findHeadingLine(heading: TOCHeading, fullText: String, textArea: AXUIElement) -> Int? {
        // Special case: empty title means "scroll to response start"
        // Find the last separator line (───) which marks the boundary before the response
        if heading.title.isEmpty {
            return findResponseStart(fullText: fullText, textArea: textArea)
        }

        let hashPrefix = String(repeating: "#", count: heading.level)

        // Strategy 1: Search for markdown heading pattern "\n## Title\n"
        let mdPattern = "\n\(hashPrefix) \(heading.title)\n"
        if let range = fullText.range(of: mdPattern, options: .backwards) {
            // +1 to skip the leading \n, point to the # character
            let charOffset = fullText.distance(from: fullText.startIndex, to: range.lowerBound) + 1
            return axLineForCharIndex(charOffset, textArea: textArea)
        }

        // Strategy 2: Try without trailing newline (heading at very end)
        let mdPatternNoTrail = "\n\(hashPrefix) \(heading.title)"
        if let range = fullText.range(of: mdPatternNoTrail, options: .backwards) {
            let charOffset = fullText.distance(from: fullText.startIndex, to: range.lowerBound) + 1
            return axLineForCharIndex(charOffset, textArea: textArea)
        }

        // Strategy 3: Plain title search (last resort, less precise)
        // Only use if title is distinctive enough (>= 6 chars)
        if heading.title.count >= 6 {
            if let range = fullText.range(of: heading.title, options: .backwards) {
                let charOffset = fullText.distance(from: fullText.startIndex, to: range.lowerBound)
                log("tierA/findHeading: fell back to plain text search for '\(heading.title)'")
                return axLineForCharIndex(charOffset, textArea: textArea)
            }
        }

        log("tierA/findHeading: '\(heading.title)' not found in buffer")
        return nil
    }

    /// Find the start of the current response by locating the last separator (───) before the response.
    /// Returns the line number just after the separator block.
    private static func findResponseStart(fullText: String, textArea: AXUIElement) -> Int? {
        // Search backwards for a line of separator characters (─)
        // The separator appears as a line of ─ characters between messages
        // We want the second-to-last separator (the one before the current response)
        // since the last separator is after the response
        var searchEnd = fullText.endIndex
        var separatorCount = 0

        while searchEnd > fullText.startIndex {
            let searchRange = fullText.startIndex..<searchEnd
            // Look for a run of ─ characters (at least 10)
            guard let range = fullText.range(of: "──────────", options: .backwards, range: searchRange) else {
                break
            }

            separatorCount += 1
            if separatorCount == 2 {
                // Found the separator before the current response
                // Skip past the separator line to the response content
                // Find the next newline after the separator
                let afterSep = range.upperBound
                if let nlRange = fullText.range(of: "\n", range: afterSep..<fullText.endIndex) {
                    let charOffset = fullText.distance(from: fullText.startIndex, to: nlRange.upperBound)
                    log("tierA/findResponseStart: found separator, response starts at char \(charOffset)")
                    return axLineForCharIndex(charOffset, textArea: textArea)
                }
            }
            searchEnd = range.lowerBound
        }

        // If only one separator found (first message), use it
        if separatorCount == 1 {
            // Re-search for the first (only) separator
            if let range = fullText.range(of: "──────────", options: .backwards) {
                let afterSep = range.upperBound
                if let nlRange = fullText.range(of: "\n", range: afterSep..<fullText.endIndex) {
                    let charOffset = fullText.distance(from: fullText.startIndex, to: nlRange.upperBound)
                    return axLineForCharIndex(charOffset, textArea: textArea)
                }
            }
        }

        log("tierA/findResponseStart: no separator found")
        return nil
    }

    /// Convert a character index to an AX line number
    private static func axLineForCharIndex(_ charIndex: Int, textArea: AXUIElement) -> Int? {
        var lineRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            textArea,
            kAXLineForIndexParameterizedAttribute as CFString,
            NSNumber(value: charIndex) as CFTypeRef,
            &lineRef
        ) == .success,
              let line = (lineRef as? NSNumber)?.intValue else {
            return nil
        }
        return line
    }

    // MARK: - Tier B: CLI/IPC (Text Search)

    private static func jumpViaCLI(heading: TOCHeading, responseTerminalLines: Int, terminalType: TerminalType) {
        switch terminalType {
        case .kitty:
            jumpViaKitty(heading: heading, responseTerminalLines: responseTerminalLines)
        case .wezterm:
            jumpViaWezTerm(heading: heading, responseTerminalLines: responseTerminalLines)
        default:
            log("tierB: unsupported terminal \(terminalType.rawValue)")
        }
    }

    /// Get full terminal text via CLI, search for heading, return lines-from-bottom.
    /// Falls back to estimation if text retrieval or search fails.
    private static func cliTextSearchLinesFromBottom(heading: TOCHeading, responseTerminalLines: Int, getText: () -> String?) -> Int {
        if let fullText = getText(), !fullText.isEmpty {
            let searchPattern: String
            if heading.title.isEmpty {
                // "scroll to response start" — find the second-to-last separator
                searchPattern = "──────────"
            } else {
                let hashPrefix = String(repeating: "#", count: heading.level)
                searchPattern = "\n\(hashPrefix) \(heading.title)\n"
            }

            if let range = fullText.range(of: searchPattern, options: .backwards) {
                let textAfterMatch = fullText[range.lowerBound...]
                let linesFromBottom = textAfterMatch.components(separatedBy: "\n").count - 1
                // +1 offset so heading appears near the top with just the blank line above
                let adjusted = max(0, linesFromBottom + 1)
                log("tierB/textSearch: found '\(heading.title)' at \(linesFromBottom) lines from bottom → \(adjusted)")
                return adjusted
            }
            log("tierB/textSearch: pattern not found, falling back to estimation")
        } else {
            log("tierB/textSearch: failed to get text, falling back to estimation")
        }

        // Fallback: old estimation method
        let linesFromBottom = responseTerminalLines - heading.estimatedTerminalLine + 4
        log("tierB/textSearch: fallback linesFromBottom=\(linesFromBottom)")
        return linesFromBottom
    }

    /// Run a CLI command and capture stdout
    private static func runCLI(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func jumpViaKitty(heading: TOCHeading, responseTerminalLines: Int) {
        let scrollUpLines = cliTextSearchLinesFromBottom(
            heading: heading,
            responseTerminalLines: responseTerminalLines,
            getText: { runCLI(["kitten", "@", "get-text", "--extent", "all"]) }
        )

        // Scroll to bottom, then scroll up exact lines
        let scrollToEnd = Process()
        scrollToEnd.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        scrollToEnd.arguments = ["kitten", "@", "scroll-window", "end"]
        try? scrollToEnd.run()
        scrollToEnd.waitUntilExit()

        let scrollUp = Process()
        scrollUp.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        scrollUp.arguments = ["kitten", "@", "scroll-window", "\(scrollUpLines)-"]
        try? scrollUp.run()
        scrollUp.waitUntilExit()
        log("tierB/kitty: scrolled to end then up \(scrollUpLines) lines, exit=\(scrollUp.terminationStatus)")
    }

    private static func jumpViaWezTerm(heading: TOCHeading, responseTerminalLines: Int) {
        let scrollUpLines = cliTextSearchLinesFromBottom(
            heading: heading,
            responseTerminalLines: responseTerminalLines,
            getText: { runCLI(["wezterm", "cli", "get-text", "--start-line", "-9999", "--end-line", "9999"]) }
        )

        // Scroll to bottom first
        let scrollToEnd = Process()
        scrollToEnd.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        scrollToEnd.arguments = ["wezterm", "cli", "send-text", "--no-paste", "\u{1b}[F"]
        try? scrollToEnd.run()
        scrollToEnd.waitUntilExit()

        // PageUp to approximate position
        let viewportRows = 40
        let pageUps = max(1, (scrollUpLines + viewportRows / 2) / viewportRows)
        for i in 0..<pageUps {
            let pageUp = Process()
            pageUp.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            pageUp.arguments = ["wezterm", "cli", "send-text", "--no-paste", "\u{1b}[5~"]
            try? pageUp.run()
            pageUp.waitUntilExit()
            if i < pageUps - 1 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        log("tierB/wezterm: sent \(pageUps) PageUp sequences for \(scrollUpLines) lines")
    }

    // MARK: - Tier C: CGEvent Key Simulation

    private static func jumpViaKeySimulation(heading: TOCHeading, responseTerminalLines: Int, pid: Int32) {
        let linesFromBottom = responseTerminalLines - heading.estimatedTerminalLine
        let chromeLines = 4
        let scrollUpLines = linesFromBottom + chromeLines

        // Estimate visible rows from window height
        let visibleRows = estimateVisibleRows(pid: pid)

        // Step 1: Scroll to bottom with Cmd+End
        sendKeyEvent(keyCode: 0x77, flags: .maskCommand, pid: pid) // End key
        Thread.sleep(forTimeInterval: 0.1)

        // Step 2: Send Shift+PageUp to scroll up
        let pageUps = max(1, (scrollUpLines + visibleRows / 2) / visibleRows)
        log("tierC: scrollUpLines=\(scrollUpLines) visibleRows=\(visibleRows) pageUps=\(pageUps)")

        for i in 0..<pageUps {
            sendKeyEvent(keyCode: 0x74, flags: .maskShift, pid: pid) // PageUp
            if i < pageUps - 1 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        log("tierC: sent Cmd+End then \(pageUps)× Shift+PageUp")
    }

    private static func sendKeyEvent(keyCode: UInt16, flags: CGEventFlags, pid: Int32) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            log("sendKeyEvent: failed to create CGEvent")
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }

    /// Estimate visible rows from the terminal window height
    private static func estimateVisibleRows(pid: Int32) -> Int {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let h = bounds["Height"],
                  h > 100 else { continue }
            // Subtract title bar (~28px), estimate ~14px per row (monospace line height)
            let rows = Int((h - 28) / 14)
            return max(10, min(rows, 100))
        }
        return 40
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

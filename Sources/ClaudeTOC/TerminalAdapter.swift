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

    /// Jump to heading — auto-detects the best scroll method at runtime.
    /// Tries AX scroll bar first (most precise), then CLI/IPC, then key simulation (fallback).
    static func jumpToHeading(
        heading: TOCHeading,
        responseTerminalLines: Int,
        app: NSRunningApplication,
        terminalType: TerminalType = .unknown,
        terminalRows: Int? = nil
    ) {
        let pid = app.processIdentifier
        log("jumpToHeading: '\(heading.title)' estLine=\(heading.estimatedTerminalLine) responseLines=\(responseTerminalLines) pid=\(pid) terminal=\(terminalType.rawValue) rows=\(terminalRows.map(String.init) ?? "nil")")

        activateTerminal(app)

        // Tier A: try AX scroll bar (works for Terminal.app, iTerm2, Ghostty, and any terminal with AX support)
        if jumpViaAXScrollBar(heading: heading, responseTerminalLines: responseTerminalLines, pid: pid, terminalRows: terminalRows) {
            log("jumpToHeading: succeeded via AX scroll bar")
            return
        }

        // Tier B: try CLI/IPC for terminals that support it
        if jumpViaCLI(heading: heading, responseTerminalLines: responseTerminalLines, terminalType: terminalType) {
            log("jumpToHeading: succeeded via CLI/IPC")
            return
        }

        // Tier C: keyboard simulation fallback
        log("jumpToHeading: falling back to key simulation")
        jumpViaKeySimulation(heading: heading, responseTerminalLines: responseTerminalLines, pid: pid)
    }

    // MARK: - Tier A: AX Text Search + ScrollBar

    /// Returns true if AX scroll succeeded, false if AX elements not available (caller should try next tier).
    @discardableResult
    private static func jumpViaAXScrollBar(heading: TOCHeading, responseTerminalLines: Int, pid: Int32, terminalRows: Int? = nil) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)

        var windowRef: CFTypeRef?
        // Try to get focused window, with brief retry for terminals that need time after activation
        for attempt in 0..<3 {
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success {
                break
            }
            var windowsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement],
               let firstWindow = windows.first {
                windowRef = firstWindow
                break
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        guard let windowRef = windowRef else {
            log("tierA: no windows found after retries")
            return false
        }
        let window = windowRef as! AXUIElement

        guard let scrollArea = findAXElement(in: window, role: kAXScrollAreaRole as String) else {
            log("tierA: no AXScrollArea found")
            return false
        }

        guard let textArea = findAXElement(in: scrollArea, role: kAXTextAreaRole as String) else {
            log("tierA: no AXTextArea found")
            return false
        }

        // Get full buffer text via AXValue
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(textArea, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String, !fullText.isEmpty else {
            log("tierA: failed to get AXValue (full text)")
            return false
        }
        log("tierA: fullText length = \(fullText.count) chars")

        // Search for heading in terminal buffer
        guard let targetLine = findHeadingLine(heading: heading, fullText: fullText, textArea: textArea) else {
            log("tierA: heading not found in buffer")
            return false
        }
        log("tierA: targetLine = \(targetLine)")

        // Get total lines: try AXInsertionPointLineNumber first, fall back to AXLineForIndex on last char
        var totalLines: Int?
        var cursorLineRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(textArea, kAXInsertionPointLineNumberAttribute as CFString, &cursorLineRef) == .success,
           let line = (cursorLineRef as? NSNumber)?.intValue {
            totalLines = line
        } else {
            let lastCharIndex = max(0, fullText.count - 1)
            if let line = axLineForCharIndex(lastCharIndex, textArea: textArea) {
                totalLines = line
                log("tierA: used AXLineForIndex fallback for totalLines = \(line)")
            }
        }
        guard let totalLines = totalLines else {
            log("tierA: failed to determine total lines")
            return false
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

        // Fallback chain when AXVisibleCharacterRange covers the entire buffer (e.g. iTerm2, Ghostty)
        if visibleRows >= totalLines {
            log("tierA: visibleRows(\(visibleRows)) >= totalLines(\(totalLines)), trying fallbacks")
            if let computed = computeVisibleRowsFromBounds(textArea: textArea, scrollArea: scrollArea) {
                visibleRows = computed
                log("tierA: AXBounds fallback visibleRows = \(visibleRows)")
            } else if let computed = computeVisibleRowsFromKnob(scrollArea: scrollArea, totalLines: totalLines) {
                visibleRows = computed
                log("tierA: knob proportion visibleRows = \(visibleRows)")
            } else if let rows = terminalRows {
                visibleRows = rows
                log("tierA: using hook-provided terminalRows = \(visibleRows)")
            } else {
                visibleRows = estimateVisibleRows(pid: pid)
                log("tierA: window estimate visibleRows = \(visibleRows)")
            }
        }

        let maxScrollLine = totalLines - visibleRows
        guard maxScrollLine > 0 else {
            log("tierA: content fits in viewport, no scroll needed")
            return true  // AX worked, just nothing to scroll
        }

        // Offset by 1 line so the heading appears near the top with just the blank line above
        let scrollValue = Float(max(0, targetLine - 1)) / Float(maxScrollLine)
        let clampedValue = min(max(scrollValue, 0.0), 1.0)
        log("tierA: scrollValue = \(targetLine) / \(maxScrollLine) = \(clampedValue)")

        var scrollBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(scrollArea, kAXVerticalScrollBarAttribute as CFString, &scrollBarRef) == .success else {
            log("tierA: no vertical scroll bar found")
            return false
        }
        let scrollBar = scrollBarRef as! AXUIElement

        let result = AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, NSNumber(value: clampedValue) as CFTypeRef)
        log("tierA: set scroll bar to \(clampedValue), result = \(result == .success ? "success" : "failed (\(result.rawValue))")")
        return result == .success
    }

    /// Search for a heading in the AX text buffer and return its exact line number.
    /// Terminal AX buffers contain rendered text without markdown markers (no # prefixes),
    /// so we search for the title text directly within the current response region.
    ///
    /// iTerm2 AX quirk: AXValue inserts spaces between CJK characters (cell-grid rendering),
    /// e.g. "地图的谎言" becomes "地 图 的 谎 言". When direct search fails, we fall back to
    /// stripped-space matching with an index mapping back to the original text offsets.
    private static func findHeadingLine(heading: TOCHeading, fullText: String, textArea: AXUIElement) -> Int? {
        // Special case: empty title means "scroll to response start"
        if heading.title.isEmpty {
            return findResponseStart(fullText: fullText, textArea: textArea)
        }

        // Search backwards for the title, preferring matches that occupy a standalone line
        // (heading lines have only whitespace around the title on the same line,
        //  while body text has other characters adjacent to it)
        if let charOffset = findStandaloneMatch(needle: heading.title, in: fullText) {
            log("tierA/findHeading: found '\(heading.title)' at char \(charOffset)")
            return axLineForCharIndex(charOffset, textArea: textArea)
        }

        // Fallback: strip spaces and re-search (handles iTerm2 CJK spacing)
        if let charOffset = strippedSpaceSearch(needle: heading.title, haystack: fullText) {
            log("tierA/findHeading: found '\(heading.title)' via stripped-space fallback at char \(charOffset)")
            return axLineForCharIndex(charOffset, textArea: textArea)
        }

        log("tierA/findHeading: '\(heading.title)' not found in buffer")
        return nil
    }

    /// Search for `needle` in `haystack` by stripping all spaces from both, then mapping
    /// the match position back to the original haystack's character offset.
    private static func strippedSpaceSearch(needle: String, haystack: String) -> Int? {
        let needleStripped = needle.replacingOccurrences(of: " ", with: "")
        guard !needleStripped.isEmpty else { return nil }

        // Build stripped haystack + index mapping (stripped index → original char offset)
        var strippedChars: [Character] = []
        var indexMap: [Int] = []  // strippedChars[i] came from haystack offset indexMap[i]
        var offset = 0
        for ch in haystack {
            if ch != " " {
                strippedChars.append(ch)
                indexMap.append(offset)
            }
            offset += 1
        }

        let strippedHaystack = String(strippedChars)
        guard let range = strippedHaystack.range(of: needleStripped, options: .backwards) else {
            return nil
        }

        let strippedIndex = strippedHaystack.distance(from: strippedHaystack.startIndex, to: range.lowerBound)
        return indexMap[strippedIndex]
    }

    /// Find `needle` in `text` searching backwards, preferring matches on standalone lines.
    /// A "standalone line" means the line contains only whitespace + the needle + whitespace.
    /// Falls back to the last plain occurrence if no standalone match is found.
    private static func findStandaloneMatch(needle: String, in text: String) -> Int? {
        var lastPlainOffset: Int?
        var searchEnd = text.endIndex

        while searchEnd > text.startIndex {
            let searchRange = text.startIndex..<searchEnd
            guard let range = text.range(of: needle, options: .backwards, range: searchRange) else {
                break
            }

            let matchOffset = text.distance(from: text.startIndex, to: range.lowerBound)

            // Check if this match is on a standalone line:
            // everything between the previous \n and next \n should be whitespace + needle + whitespace
            let lineStart = text[text.startIndex..<range.lowerBound].lastIndex(of: "\n")
                .map { text.index(after: $0) } ?? text.startIndex
            let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex

            let before = text[lineStart..<range.lowerBound]
            let after = text[range.upperBound..<lineEnd]

            let isStandalone = before.allSatisfy { isHeadingDecoration($0) } && after.allSatisfy { isHeadingDecoration($0) }

            if isStandalone {
                log("tierA/findStandalone: '\(needle)' standalone at offset \(matchOffset)")
                return matchOffset
            }

            // Remember as fallback
            if lastPlainOffset == nil {
                lastPlainOffset = matchOffset
            }

            searchEnd = range.lowerBound
        }

        if let offset = lastPlainOffset {
            log("tierA/findStandalone: '\(needle)' no standalone found, using last plain match at \(offset)")
        }
        return lastPlainOffset
    }

    /// Check if a character is heading decoration (whitespace or terminal markers like ⏺, ●, •, etc.)
    /// Used to distinguish heading lines from body text — headings have only decorations around the title.
    private static func isHeadingDecoration(_ ch: Character) -> Bool {
        if ch.isWhitespace { return true }
        // Common terminal heading markers/bullets
        let markers: Set<Character> = ["⏺", "●", "•", "◆", "▸", "▪", "○", "◇", "■", "⏵"]
        return markers.contains(ch)
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

    /// Returns true if CLI/IPC scroll was attempted (terminal supports it), false otherwise.
    @discardableResult
    private static func jumpViaCLI(heading: TOCHeading, responseTerminalLines: Int, terminalType: TerminalType) -> Bool {
        switch terminalType {
        case .kitty:
            jumpViaKitty(heading: heading, responseTerminalLines: responseTerminalLines)
            return true
        case .wezterm:
            jumpViaWezTerm(heading: heading, responseTerminalLines: responseTerminalLines)
            return true
        default:
            return false
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
                searchPattern = heading.title
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

    /// Compute visible rows from scroll bar knob proportion.
    /// In NSScrollView, knob proportion = viewport_rows / total_rows.
    /// We read the AXValueIndicator height vs scroll bar height to derive this ratio.
    private static func computeVisibleRowsFromKnob(scrollArea: AXUIElement, totalLines: Int) -> Int? {
        var scrollBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(scrollArea, kAXVerticalScrollBarAttribute as CFString, &scrollBarRef) == .success else {
            return nil
        }
        let scrollBar = scrollBarRef as! AXUIElement

        // Get scroll bar height
        var barSizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(scrollBar, kAXSizeAttribute as CFString, &barSizeRef) == .success else {
            return nil
        }
        var barSize = CGSize.zero
        AXValueGetValue(barSizeRef as! AXValue, .cgSize, &barSize)
        guard barSize.height > 0 else { return nil }

        // Find AXValueIndicator child (the knob)
        var childRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(scrollBar, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
               (roleRef as? String) == "AXValueIndicator" {
                var knobSizeRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &knobSizeRef) == .success else {
                    continue
                }
                var knobSize = CGSize.zero
                AXValueGetValue(knobSizeRef as! AXValue, .cgSize, &knobSize)
                guard knobSize.height > 0 else { continue }

                let proportion = Double(knobSize.height) / Double(barSize.height)
                let rows = Int(round(Double(totalLines) * proportion))
                log("tierA/knobFallback: knobH=\(knobSize.height) barH=\(barSize.height) proportion=\(proportion) → rows=\(rows)")
                return max(1, rows)
            }
        }

        return nil
    }

    /// Compute visible rows using AXBoundsForRange to get precise line height.
    /// Works when AXVisibleCharacterRange is unreliable (e.g. iTerm2/Ghostty report entire buffer).
    /// Tries AXRangeForLine first, falls back to comparing bounds of two known lines via AXLineForIndex.
    private static func computeVisibleRowsFromBounds(textArea: AXUIElement, scrollArea: AXUIElement) -> Int? {
        var lineHeight: CGFloat = 0

        // Method 1: Use AXRangeForLine to get ranges for line 0 and line 1
        var range0Ref: CFTypeRef?
        var range1Ref: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(textArea, kAXRangeForLineParameterizedAttribute as CFString, NSNumber(value: 0) as CFTypeRef, &range0Ref) == .success,
           AXUIElementCopyParameterizedAttributeValue(textArea, kAXRangeForLineParameterizedAttribute as CFString, NSNumber(value: 1) as CFTypeRef, &range1Ref) == .success {
            var bounds0Ref: CFTypeRef?
            var bounds1Ref: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(textArea, kAXBoundsForRangeParameterizedAttribute as CFString, range0Ref! as CFTypeRef, &bounds0Ref) == .success,
               AXUIElementCopyParameterizedAttributeValue(textArea, kAXBoundsForRangeParameterizedAttribute as CFString, range1Ref! as CFTypeRef, &bounds1Ref) == .success {
                var rect0 = CGRect.zero
                var rect1 = CGRect.zero
                AXValueGetValue(bounds0Ref as! AXValue, .cgRect, &rect0)
                AXValueGetValue(bounds1Ref as! AXValue, .cgRect, &rect1)
                lineHeight = abs(rect1.origin.y - rect0.origin.y)
            }
        }

        // Method 2: If AXRangeForLine failed, use AXBoundsForRange on single-char ranges
        // from two different lines (char 0 on line 0, find a char on line 1 via AXLineForIndex)
        if lineHeight <= 0 {
            log("tierA/boundsFallback: AXRangeForLine unavailable, trying single-char bounds")
            // Find a character on line 1 by scanning forward from char 0
            var line1Start: Int?
            var charNums: CFTypeRef?
            if AXUIElementCopyAttributeValue(textArea, kAXNumberOfCharactersAttribute as CFString, &charNums) == .success,
               let totalChars = (charNums as? NSNumber)?.intValue {
                for i in 1..<min(totalChars, 500) {
                    var lineRef: CFTypeRef?
                    if AXUIElementCopyParameterizedAttributeValue(textArea, kAXLineForIndexParameterizedAttribute as CFString, NSNumber(value: i) as CFTypeRef, &lineRef) == .success,
                       let line = (lineRef as? NSNumber)?.intValue, line >= 1 {
                        line1Start = i
                        break
                    }
                }
            }
            guard let char1 = line1Start else {
                log("tierA/boundsFallback: couldn't find char on line 1")
                return nil
            }
            // Get bounds for char 0 and char on line 1
            var cfRange0 = CFRange(location: 0, length: 1)
            var cfRange1 = CFRange(location: char1, length: 1)
            let axRange0: AXValue? = AXValueCreate(.cfRange, &cfRange0)
            let axRange1: AXValue? = AXValueCreate(.cfRange, &cfRange1)
            var b0Ref: CFTypeRef?
            var b1Ref: CFTypeRef?
            if let r0 = axRange0, let r1 = axRange1,
               AXUIElementCopyParameterizedAttributeValue(textArea, kAXBoundsForRangeParameterizedAttribute as CFString, r0 as CFTypeRef, &b0Ref) == .success,
               AXUIElementCopyParameterizedAttributeValue(textArea, kAXBoundsForRangeParameterizedAttribute as CFString, r1 as CFTypeRef, &b1Ref) == .success {
                var rect0 = CGRect.zero
                var rect1 = CGRect.zero
                AXValueGetValue(b0Ref as! AXValue, .cgRect, &rect0)
                AXValueGetValue(b1Ref as! AXValue, .cgRect, &rect1)
                lineHeight = abs(rect1.origin.y - rect0.origin.y)
            }
        }

        guard lineHeight > 0 else {
            log("tierA/boundsFallback: lineHeight is 0")
            return nil
        }

        // Get scrollArea height
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(scrollArea, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            log("tierA/boundsFallback: failed to get scrollArea size")
            return nil
        }
        var size = CGSize.zero
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)

        let rows = Int(size.height / lineHeight)
        log("tierA/boundsFallback: lineHeight=\(lineHeight) scrollAreaHeight=\(size.height) → rows=\(rows)")
        return max(1, rows)
    }

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

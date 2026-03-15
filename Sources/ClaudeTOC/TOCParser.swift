import Foundation

struct TOCHeading: Sendable {
    let level: Int
    let title: String
    let lineInResponse: Int       // markdown line number
    let estimatedTerminalLine: Int // estimated terminal rendered line
}

struct TOCResult: Sendable {
    let headings: [TOCHeading]
    let totalLines: Int               // markdown lines
    let estimatedTerminalLines: Int   // estimated rendered terminal lines
    let rawText: String
    let lastUserQuery: String?        // the user message that triggered this response
    let responsePreview: String?      // first ~60 chars of assistant response
}

enum TOCParser {
    static func parse(transcriptPath: String, terminalColumns: Int = 80) -> TOCResult? {
        guard let data = FileManager.default.contents(atPath: transcriptPath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Parse all entries to find user query + assistant response
        struct Entry {
            let type: String
            let text: String
        }
        var entries: [Entry] = []
        for line in lines {
            guard let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = json["type"] as? String,
                  (type == "user" || type == "assistant"),
                  let message = json["message"] as? [String: Any] else {
                continue
            }

            var textParts: [String] = []
            if let contentArray = message["content"] as? [[String: Any]] {
                // Array format: [{"type": "text", "text": "..."}]
                for block in contentArray {
                    if let blockType = block["type"] as? String,
                       blockType == "text",
                       let text = block["text"] as? String {
                        textParts.append(text)
                    }
                }
            } else if let contentStr = message["content"] as? String, !contentStr.isEmpty {
                // String format (common for user messages)
                textParts.append(contentStr)
            }

            if !textParts.isEmpty {
                entries.append(Entry(type: type, text: textParts.joined(separator: "\n")))
            }
        }

        // 1. Always find the LATEST user query and assistant response (for notification)
        var lastUserQuery: String?
        var latestAssistantText: String?
        for i in stride(from: entries.count - 1, through: 0, by: -1) {
            if entries[i].type == "assistant" && latestAssistantText == nil {
                latestAssistantText = entries[i].text
            }
            if entries[i].type == "user" && lastUserQuery == nil {
                lastUserQuery = entries[i].text
            }
            if lastUserQuery != nil && latestAssistantText != nil { break }
        }

        // 2. Only use the LATEST assistant message for TOC (never show stale headings)
        let tocText = latestAssistantText ?? ""
        guard !tocText.isEmpty else { return nil }

        // Extract markdown headings from the heading-bearing assistant text
        let textLines = tocText.components(separatedBy: "\n")
        var headings: [TOCHeading] = []
        var insideCodeBlock = false
        var currentTerminalLine = 0

        let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,3})\s+(.+)$"#)

        for (index, textLine) in textLines.enumerated() {
            let termLineForThisRow = currentTerminalLine

            // Track code block boundaries
            if textLine.hasPrefix("```") {
                insideCodeBlock = !insideCodeBlock
                currentTerminalLine += 1
                continue
            }

            // Estimate how many terminal lines this markdown line takes
            let renderedLines = estimateRenderedLines(textLine, columns: terminalColumns)
            currentTerminalLine += renderedLines

            guard !insideCodeBlock else { continue }

            let range = NSRange(textLine.startIndex..<textLine.endIndex, in: textLine)
            if let match = headingPattern.firstMatch(in: textLine, range: range) {
                let hashRange = Range(match.range(at: 1), in: textLine)!
                let titleRange = Range(match.range(at: 2), in: textLine)!
                let level = textLine[hashRange].count
                let title = stripMarkdownFormatting(String(textLine[titleRange]).trimmingCharacters(in: .whitespaces))
                headings.append(TOCHeading(
                    level: level,
                    title: title,
                    lineInResponse: index,
                    estimatedTerminalLine: termLineForThisRow
                ))
            }
        }

        // Build response preview from the LATEST assistant response (not the heading one)
        let previewLines = (latestAssistantText ?? tocText).components(separatedBy: "\n")
        let previewLine = previewLines.first { line in
            !line.isEmpty && !line.hasPrefix("#") && !line.hasPrefix("```")
        }
        let responsePreview: String? = previewLine.map { line in
            let maxLen = 60
            if line.count <= maxLen { return line }
            return String(line.prefix(maxLen)) + "…"
        }

        return TOCResult(
            headings: headings,
            totalLines: textLines.count,
            estimatedTerminalLines: currentTerminalLine,
            rawText: tocText,
            lastUserQuery: lastUserQuery,
            responsePreview: responsePreview
        )
    }

    /// Strip markdown inline formatting characters that terminals render without
    static func stripMarkdownFormatting(_ text: String) -> String {
        var result = text
        // Remove backticks (inline code)
        result = result.replacingOccurrences(of: "`", with: "")
        // Remove bold/italic markers (**, *, __, _) but not inside words
        // Remove ** and __ first (bold), then * and _ (italic)
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        // For single * and _, only remove at word boundaries (leading/trailing)
        // Simple approach: remove remaining * and _ that are likely formatting
        let singleMarkerPattern = try! NSRegularExpression(pattern: #"(?<!\w)[*_]|[*_](?!\w)"#)
        let range = NSRange(result.startIndex..<result.endIndex, in: result)
        result = singleMarkerPattern.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        return result
    }

    /// Estimate how many terminal lines a single markdown line occupies
    private static func estimateRenderedLines(_ line: String, columns: Int) -> Int {
        if line.isEmpty { return 1 } // empty line still takes 1 row

        // Calculate display width (CJK characters = 2 columns, others = 1)
        var displayWidth = 0
        for scalar in line.unicodeScalars {
            let v = scalar.value
            // CJK Unified Ideographs, CJK symbols, fullwidth forms, etc.
            if (v >= 0x2E80 && v <= 0x9FFF) ||
               (v >= 0xF900 && v <= 0xFAFF) ||
               (v >= 0xFE30 && v <= 0xFE4F) ||
               (v >= 0xFF00 && v <= 0xFF60) ||
               (v >= 0x20000 && v <= 0x2FA1F) {
                displayWidth += 2
            } else {
                displayWidth += 1
            }
        }

        return max(1, Int(ceil(Double(displayWidth) / Double(columns))))
    }
}

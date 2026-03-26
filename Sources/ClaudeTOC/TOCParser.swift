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

struct TranscriptParseSnapshot: Sendable {
    let tocResult: TOCResult?
    let endsWithAssistant: Bool
}

enum TOCParser {
    static func parseSnapshot(transcriptPath: String, terminalColumns: Int = 80) -> TranscriptParseSnapshot? {
        guard let data = FileManager.default.contents(atPath: transcriptPath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: "\n")
        var lastUserQuery: String?
        var assistantTexts: [String] = []
        var latestEntryType: String?

        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            let line = lines[i]
            guard !line.isEmpty,
                  let jsonData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let type = json["type"] as? String,
                  let message = json["message"] as? [String: Any] else {
                continue
            }

            if latestEntryType == nil {
                latestEntryType = type
            }

            if type == "assistant" && lastUserQuery == nil {
                // Still in the current turn — collect all text blocks
                if let text = Self.extractText(from: message) {
                    assistantTexts.insert(text, at: 0)
                }
            } else if type == "user" {
                lastUserQuery = Self.extractText(from: message)
                break
            }
        }

        let endsWithAssistant = latestEntryType == "assistant"
        guard endsWithAssistant else {
            return TranscriptParseSnapshot(tocResult: nil, endsWithAssistant: false)
        }

        let tocText = assistantTexts.isEmpty ? "" : assistantTexts.joined(separator: "\n")
        guard !tocText.isEmpty else {
            return TranscriptParseSnapshot(tocResult: nil, endsWithAssistant: true)
        }

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

        // Build response preview: up to 2 meaningful lines, each capped at 40 display columns
        // (CJK chars count as 2 columns to fit macOS notification banner width)
        let allPreviewLines = tocText.components(separatedBy: "\n")
        var previewCollected: [String] = []
        for pLine in allPreviewLines {
            guard previewCollected.count < 2 else { break }
            let trimmed = pLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("```") { continue }
            previewCollected.append(truncateToDisplayWidth(trimmed, maxWidth: 40))
        }
        let responsePreview: String? = previewCollected.isEmpty ? nil : previewCollected.joined(separator: "\n")

        let tocResult = TOCResult(
            headings: headings,
            totalLines: textLines.count,
            estimatedTerminalLines: currentTerminalLine,
            rawText: tocText,
            lastUserQuery: lastUserQuery,
            responsePreview: responsePreview
        )
        return TranscriptParseSnapshot(tocResult: tocResult, endsWithAssistant: true)
    }

    static func parse(transcriptPath: String, terminalColumns: Int = 80) -> TOCResult? {
        parseSnapshot(transcriptPath: transcriptPath, terminalColumns: terminalColumns)?.tocResult
    }

    /// Extract text content from a transcript message object
    private static func extractText(from message: [String: Any]) -> String? {
        var textParts: [String] = []
        if let contentArray = message["content"] as? [[String: Any]] {
            for block in contentArray {
                if let blockType = block["type"] as? String,
                   blockType == "text",
                   let text = block["text"] as? String {
                    textParts.append(text)
                }
            }
        } else if let contentStr = message["content"] as? String, !contentStr.isEmpty {
            textParts.append(contentStr)
        }
        return textParts.isEmpty ? nil : textParts.joined(separator: "\n")
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

    /// Truncate a string to fit within a given display width (CJK = 2 columns each).
    /// Returns the truncated string with "…" appended if truncation occurred.
    static func truncateToDisplayWidth(_ text: String, maxWidth: Int) -> String {
        var width = 0
        var endIndex = text.endIndex
        for (i, scalar) in zip(text.indices, text.unicodeScalars) {
            let charWidth = isCJK(scalar) ? 2 : 1
            if width + charWidth > maxWidth {
                endIndex = i
                break
            }
            width += charWidth
        }
        if endIndex == text.endIndex {
            return text
        }
        return String(text[text.startIndex..<endIndex]) + "…"
    }

    /// Check if a Unicode scalar is a CJK wide character
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 0x2E80 && v <= 0x9FFF) ||
               (v >= 0xF900 && v <= 0xFAFF) ||
               (v >= 0xFE30 && v <= 0xFE4F) ||
               (v >= 0xFF00 && v <= 0xFF60) ||
               (v >= 0x20000 && v <= 0x2FA1F)
    }

    /// Estimate how many terminal lines a single markdown line occupies
    private static func estimateRenderedLines(_ line: String, columns: Int) -> Int {
        if line.isEmpty { return 1 } // empty line still takes 1 row

        // Calculate display width (CJK characters = 2 columns, others = 1)
        var displayWidth = 0
        for scalar in line.unicodeScalars {
            displayWidth += isCJK(scalar) ? 2 : 1
        }

        return max(1, Int(ceil(Double(displayWidth) / Double(columns))))
    }
}

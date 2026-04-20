import Foundation
import Testing
@testable import ClaudeTOC

struct TOCParserTests {
    @Test
    func parseSnapshotUsesLatestAssistantText() throws {
        let transcriptURL = try makeTranscript(lines: [
            jsonLine(type: "user", message: ["content": [["type": "text", "text": "old question"]]]),
            jsonLine(type: "assistant", message: ["content": [["type": "text", "text": "# Old Heading\nOld body"]]]),
            jsonLine(type: "user", message: ["content": [["type": "text", "text": "new question"]]]),
            jsonLine(type: "assistant", message: ["content": [["type": "text", "text": "# New Heading\nFresh body"]]])
        ])

        let snapshot = try #require(TOCParser.parseSnapshot(transcriptPath: transcriptURL.path, terminalColumns: 80))
        #expect(snapshot.endsWithAssistant)
        #expect(snapshot.tocResult?.headings.map(\.title) == ["New Heading"])
        #expect(snapshot.tocResult?.lastUserQuery == "new question")
    }

    @Test
    func parseSnapshotDoesNotReuseOlderAssistantWhenLatestHasNoText() throws {
        let transcriptURL = try makeTranscript(lines: [
            jsonLine(type: "user", message: ["content": [["type": "text", "text": "old question"]]]),
            jsonLine(type: "assistant", message: ["content": [["type": "text", "text": "# Old Heading\nOld body"]]]),
            jsonLine(type: "user", message: ["content": [["type": "text", "text": "tool question"]]]),
            jsonLine(type: "assistant", message: ["content": [["type": "tool_use", "name": "search", "input": ["query": "abc"]]]])
        ])

        let snapshot = try #require(TOCParser.parseSnapshot(transcriptPath: transcriptURL.path, terminalColumns: 80))
        #expect(snapshot.endsWithAssistant)
        #expect(snapshot.tocResult == nil)
    }

    @Test
    func parseSnapshotReportsNotReadyWhenTranscriptEndsWithUser() throws {
        let transcriptURL = try makeTranscript(lines: [
            jsonLine(type: "user", message: ["content": [["type": "text", "text": "question in flight"]]])
        ])

        let snapshot = try #require(TOCParser.parseSnapshot(transcriptPath: transcriptURL.path, terminalColumns: 80))
        #expect(snapshot.endsWithAssistant == false)
        #expect(snapshot.tocResult == nil)
    }

    private func makeTranscript(lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func jsonLine(type: String, message: [String: Any]) -> String {
        let payload: [String: Any] = ["type": type, "message": message]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

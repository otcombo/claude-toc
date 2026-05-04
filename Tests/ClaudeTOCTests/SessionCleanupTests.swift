import CoreGraphics
import Foundation
import Testing
@testable import ClaudeTOC

@MainActor
struct SessionCleanupTests {
    @Test
    func removesSessionWhenClaudePidDies() throws {
        let manager = TOCSessionManager()

        // Spawn a real process to act as our "Claude" PID
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["100"]
        try process.run()
        let pid = process.processIdentifier

        let transcriptURL = makeTranscript()
        defer { try? FileManager.default.removeItem(at: transcriptURL) }

        let session = TOCSession(
            id: "pid-test", transcriptPath: transcriptURL.path,
            projectName: nil, tocResult: nil,
            terminalType: .unknown, terminalApp: nil,
            claudePid: pid,
            createdAt: Date(timeIntervalSinceNow: -10)
        )
        manager._testInsertSession(session)

        // PID still alive → no removal
        manager.cleanupStaleSessions()
        #expect(manager.activeSessions.count == 1, "session should remain while Claude pid is alive")

        // Kill the fake Claude — cleanup should drop the session
        process.terminate()
        process.waitUntilExit()
        manager.cleanupStaleSessions()
        #expect(manager.activeSessions.isEmpty, "session should be removed once Claude pid is gone")
    }

    @Test
    func removesSessionWhenTranscriptDeleted() throws {
        let manager = TOCSessionManager()
        let transcriptURL = makeTranscript()

        let session = TOCSession(
            id: "transcript-test", transcriptPath: transcriptURL.path,
            projectName: nil, tocResult: nil,
            terminalType: .unknown, terminalApp: nil,
            createdAt: Date(timeIntervalSinceNow: -10)
        )
        manager._testInsertSession(session)

        manager.cleanupStaleSessions()
        #expect(manager.activeSessions.count == 1)

        try FileManager.default.removeItem(at: transcriptURL)
        manager.cleanupStaleSessions()
        #expect(manager.activeSessions.isEmpty, "session should be removed when transcript file disappears")
    }

    @Test
    func removesSessionWhenWindowClosed() throws {
        let manager = TOCSessionManager()
        let transcriptURL = makeTranscript()
        defer { try? FileManager.default.removeItem(at: transcriptURL) }

        // Use a windowID that's almost certainly not in CGWindowList
        let bogusWindowID: CGWindowID = 0xFFFFFFFE
        let session = TOCSession(
            id: "window-test", transcriptPath: transcriptURL.path,
            projectName: nil, tocResult: nil,
            terminalType: .unknown, terminalApp: nil,
            windowID: bogusWindowID,
            createdAt: Date(timeIntervalSinceNow: -10)
        )
        manager._testInsertSession(session)

        manager.cleanupStaleSessions()
        #expect(manager.activeSessions.isEmpty, "session should be removed when its window is gone")
    }

    @Test
    func respectsGracePeriod() throws {
        let manager = TOCSessionManager()
        // Transcript path that's already missing — would normally trigger cleanup
        let session = TOCSession(
            id: "grace-test",
            transcriptPath: "/tmp/nonexistent-\(UUID().uuidString).jsonl",
            projectName: nil, tocResult: nil,
            terminalType: .unknown, terminalApp: nil
            // createdAt defaults to now, so within the 2 s grace period
        )
        manager._testInsertSession(session)

        manager.cleanupStaleSessions()
        #expect(manager.activeSessions.count == 1, "freshly-created session should be skipped by grace period")
    }

    @Test
    func leavesHealthySessionAlone() throws {
        let manager = TOCSessionManager()
        let transcriptURL = makeTranscript()
        defer { try? FileManager.default.removeItem(at: transcriptURL) }

        let session = TOCSession(
            id: "healthy-test", transcriptPath: transcriptURL.path,
            projectName: nil, tocResult: nil,
            terminalType: .unknown, terminalApp: nil,
            // No claudePid, no windowID, no terminalApp — only transcript check applies
            createdAt: Date(timeIntervalSinceNow: -10)
        )
        manager._testInsertSession(session)

        manager.cleanupStaleSessions()
        #expect(manager.activeSessions.count == 1, "session with valid transcript and no other signals should survive")
    }

    private func makeTranscript() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        try! "{}".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

import AppKit
import Foundation

class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = TOCWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        var transcriptPath: String?
        var hookPid: Int32?

        let args = Array(CommandLine.arguments.dropFirst())
        var positional: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "--hook-pid", i + 1 < args.count {
                hookPid = Int32(args[i + 1])
                i += 2
            } else {
                positional.append(args[i])
                i += 1
            }
        }

        if let first = positional.first {
            transcriptPath = first
        } else {
            let stdinData = FileHandle.standardInput.readDataToEndOfFile()
            if !stdinData.isEmpty,
               let json = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any],
               let path = json["transcript_path"] as? String {
                transcriptPath = path
            }
        }

        guard let path = transcriptPath else {
            fputs("Usage: claude-toc <transcript-path> [--hook-pid PID]\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }

        // Detect terminal first so we can estimate column width
        let (terminalType, terminalApp) = TerminalAdapter.detectTerminal(hookPid: hookPid)
        log("Detected terminal: \(terminalType.rawValue), pid: \(terminalApp?.processIdentifier ?? -1)")

        let termColumns = TerminalAdapter.estimateColumns(app: terminalApp)
        log("Estimated terminal columns: \(termColumns)")

        guard let tocResult = TOCParser.parse(transcriptPath: path, terminalColumns: termColumns) else {
            fputs("Failed to parse transcript.\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }

        if tocResult.headings.isEmpty {
            log("No headings found, exiting.")
            NSApplication.shared.terminate(nil)
            return
        }

        log("Found \(tocResult.headings.count) headings, \(tocResult.totalLines) md lines -> \(tocResult.estimatedTerminalLines) terminal lines")

        controller.show(tocResult: tocResult, terminalType: terminalType, terminalApp: terminalApp)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

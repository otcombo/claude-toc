import AppKit
import Foundation

// Parse args before NSApplication starts
var transcriptPath: String?
var hookPid: Int32?
var terminalBundleId: String?
var terminalColumns: Int?

let cliArgs = Array(CommandLine.arguments.dropFirst())
var positional: [String] = []
var argIdx = 0
while argIdx < cliArgs.count {
    if cliArgs[argIdx] == "--hook-pid", argIdx + 1 < cliArgs.count {
        hookPid = Int32(cliArgs[argIdx + 1])
        argIdx += 2
    } else if cliArgs[argIdx] == "--terminal-bundle-id", argIdx + 1 < cliArgs.count {
        terminalBundleId = cliArgs[argIdx + 1]
        argIdx += 2
    } else if cliArgs[argIdx] == "--terminal-columns", argIdx + 1 < cliArgs.count {
        terminalColumns = Int(cliArgs[argIdx + 1])
        argIdx += 2
    } else {
        positional.append(cliArgs[argIdx])
        argIdx += 1
    }
}

if let first = positional.first {
    transcriptPath = first
}

// Try sending to a running instance BEFORE starting NSApplication
if let path = transcriptPath {
    let msg = IPCMessage(transcriptPath: path, hookPid: hookPid, terminalBundleId: terminalBundleId, terminalColumns: terminalColumns)
    if SocketClient.send(message: msg) {
        // Successfully sent to running instance — just exit
        exit(0)
    }
}

// We are the main instance
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let sessionManager = TOCSessionManager()
    let menuBar = MenuBarController()
    let windowObserver = WindowObserver()
    var socketServer: SocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("Starting as main instance")

        // Request notification authorization once at startup
        sessionManager.requestNotificationAuthorization()

        // Wire up window observer for panel visibility management
        windowObserver.sessionManager = sessionManager
        sessionManager.windowObserver = windowObserver
        windowObserver.start()

        sessionManager.onSessionsChanged = { [weak self] in
            self?.menuBar.updateMenu()
        }
        menuBar.setup(sessionManager: sessionManager)

        socketServer = SocketServer { [weak self] msg in
            DispatchQueue.main.async {
                self?.sessionManager.addSession(transcriptPath: msg.transcriptPath, hookPid: msg.hookPid, terminalBundleId: msg.terminalBundleId, terminalColumns: msg.terminalColumns)
            }
        }
        socketServer?.start()

        // Handle the initial transcript that started us
        if let path = transcriptPath {
            sessionManager.addSession(transcriptPath: path, hookPid: hookPid, terminalBundleId: terminalBundleId, terminalColumns: terminalColumns)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

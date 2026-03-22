import AppKit
import Foundation
import SwiftUI

// Parse args before NSApplication starts
var transcriptPath: String?
var hookPid: Int32?
var terminalBundleId: String?
var terminalColumns: Int?
var terminalRows: Int?
var hookTty: String?
var hookWindowId: UInt32?

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
    } else if cliArgs[argIdx] == "--terminal-rows", argIdx + 1 < cliArgs.count {
        terminalRows = Int(cliArgs[argIdx + 1])
        argIdx += 2
    } else if cliArgs[argIdx] == "--tty", argIdx + 1 < cliArgs.count {
        hookTty = cliArgs[argIdx + 1]
        argIdx += 2
    } else if cliArgs[argIdx] == "--window-id", argIdx + 1 < cliArgs.count {
        hookWindowId = UInt32(cliArgs[argIdx + 1])
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
    let msg = IPCMessage(transcriptPath: path, hookPid: hookPid, terminalBundleId: terminalBundleId, terminalColumns: terminalColumns, terminalRows: terminalRows, tty: hookTty, windowId: hookWindowId)
    if SocketClient.send(message: msg) {
        // Successfully sent to running instance — just exit
        exit(0)
    }

    // Socket failed — check if another instance is running (Apple-standard approach).
    // This handles the race where another instance just launched but its socket isn't ready yet.
    let bundleId = Bundle.main.bundleIdentifier ?? "com.otcombo.claudetoc"
    let myPid = ProcessInfo.processInfo.processIdentifier
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        .filter { $0.processIdentifier != myPid }

    if !others.isEmpty {
        // Another instance exists but socket isn't ready — retry a few times
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.2)
            if SocketClient.send(message: msg) {
                exit(0)
            }
        }
        // Still can't connect — the other instance may be stuck; log and exit
        FileHandle.standardError.write(Data("Another ClaudeTOC instance (pid \(others[0].processIdentifier)) is running but not responding. Exiting.\n".utf8))
        exit(1)
    }

    // No running instance and we were invoked with a transcript path (i.e. from hook).
    // Don't auto-launch — user must open the app explicitly.
    exit(0)
}

// We are the main instance
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let sessionManager = TOCSessionManager()
    let menuBar = MenuBarController()
    let windowObserver = WindowObserver()
    var socketServer: SocketServer?
    var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("Starting as main instance")

        // Register with Launch Services so the system indexes our app icon
        // (fixes notification icon for LSUIElement apps running outside /Applications)
        LSRegisterURL(Bundle.main.bundleURL as CFURL, true)

        // Explicitly load app icon from bundle
        if let iconURL = Bundle.main.url(forResource: "appicon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        // Show onboarding if accessibility not granted
        if !AXIsProcessTrusted() {
            showOnboarding()
            return
        }

        startNormally()
    }

    func showOnboarding() {
        let onboardingView = OnboardingView {
            // This is called if we ever need a non-relaunch completion path
        }

        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.setContentSize(NSSize(width: 520, height: 450))
        window.center()
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.makeKeyAndOrderFront(nil)

        // Bring app to front for onboarding
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        onboardingWindow = window
    }

    func startNormally() {
        // Silently install Claude Code Stop hook
        installClaudeHookIfNeeded()

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

        // Start auto-updater (daily check + menu refresh on status change)
        Updater.shared.onStatusChanged = { [weak self] in
            self?.menuBar.updateMenu()
        }
        Updater.shared.startPeriodicCheck()

        socketServer = SocketServer { [weak self] msg in
            DispatchQueue.main.async {
                self?.sessionManager.addSession(transcriptPath: msg.transcriptPath, hookPid: msg.hookPid, terminalBundleId: msg.terminalBundleId, terminalColumns: msg.terminalColumns, terminalRows: msg.terminalRows, tty: msg.tty, windowId: msg.windowId)
            }
        }
        socketServer?.start()

        // Handle the initial transcript that started us
        if let path = transcriptPath {
            sessionManager.addSession(transcriptPath: path, hookPid: hookPid, terminalBundleId: terminalBundleId, terminalColumns: terminalColumns, terminalRows: terminalRows, tty: hookTty, windowId: hookWindowId)
        }
    }

    /// Install Claude Code Stop hook into ~/.claude/settings.json
    private func installClaudeHookIfNeeded() {
        guard let hookScript = Bundle.main.url(forResource: "hook", withExtension: "sh") else {
            log("hook.sh not found in bundle")
            return
        }
        let hookPath = hookScript.path

        let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        let settingsURL = claudeDir.appendingPathComponent("settings.json")

        // Read existing settings or start fresh
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        // Check existing Stop hooks — update stale path or skip if already correct
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var stopHooks = hooks["Stop"] as? [[String: Any]] ?? []
        var found = false

        // Shell-quote the path so spaces in .app names don't break execution
        let quotedHookPath = "'\(hookPath)'"

        for i in stopHooks.indices {
            guard var innerHooks = stopHooks[i]["hooks"] as? [[String: Any]] else { continue }
            for j in innerHooks.indices {
                guard let cmd = innerHooks[j]["command"] as? String else { continue }
                if cmd == quotedHookPath {
                    return // already installed with correct path
                }
                // Recognize our hook by filename pattern (hook.sh inside a ClaudeTOC/TOC app bundle or old project path)
                if cmd.contains("hook.sh") && (cmd.contains("ClaudeTOC") || cmd.contains("TOC for Claude Code") || cmd.contains("claude-toc")) {
                    innerHooks[j]["command"] = quotedHookPath
                    stopHooks[i]["hooks"] = innerHooks
                    found = true
                }
            }
        }

        if !found {
            // Append new entry
            let hookEntry: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": quotedHookPath,
                    "async": true
                ]]
            ]
            stopHooks.append(hookEntry)
        }

        hooks["Stop"] = stopHooks
        settings["hooks"] = hooks

        // Write back
        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settingsURL, options: .atomic)
            log("Installed Claude Code Stop hook: \(hookPath)")
        } catch {
            log("Failed to install hook: \(error)")
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Hold a strong reference — NSApplication.delegate is weak and would otherwise let AppDelegate
// (and its MenuBarController/statusItem) get deallocated by ARC.
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) {
    app.run()
}

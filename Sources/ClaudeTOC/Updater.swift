import AppKit
import Foundation
import SwiftUI

/// Self-updater via GitHub Releases.
/// Checks `otcombo/claude-toc` for a newer tag, downloads the zip asset,
/// replaces the running .app bundle and relaunches.
@MainActor
class Updater {
    static let shared = Updater()

    private let repo = "otcombo/claude-toc"
    private let assetName = "TOC.for.Claude.Code.app.zip"
    private var checkTimer: Timer?
    private(set) var latestVersion: String?
    private(set) var isChecking = false
    private(set) var isUpdating = false
    private var checkFailed = false

    private var updateWindow: NSWindow?
    private let viewState = UpdateViewState()

    var onStatusChanged: (() -> Void)?

    /// Current app version from Info.plist CFBundleShortVersionString
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    /// Whether an update is available
    var updateAvailable: Bool {
        guard let remote = latestVersion else { return false }
        return isNewer(remote: remote, local: currentVersion)
    }

    // MARK: - Window

    func showUpdateWindow() {
        if let existing = updateWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        syncViewState()

        let hostingView = NSHostingView(rootView: UpdateView(state: viewState))
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = hostingView
        window.isMovableByWindowBackground = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.level = .floating

        NSApp.activate(ignoringOtherApps: true)

        updateWindow = window

        // Trigger a check when the window opens
        checkForUpdate(silent: false)
    }

    private func syncViewState() {
        viewState.currentVersion = currentVersion
        viewState.latestVersion = latestVersion
        viewState.isChecking = isChecking
        viewState.isUpdating = isUpdating
        viewState.updateAvailable = updateAvailable
        viewState.checkFailed = checkFailed
    }

    // MARK: - Periodic check

    func startPeriodicCheck() {
        // Check once at launch (after a short delay so the app settles)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                self.checkForUpdate(silent: true)
            }
        }
        // Then every 24 hours
        checkTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForUpdate(silent: true)
            }
        }
    }

    // MARK: - Check

    func checkForUpdate(silent: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        checkFailed = false
        onStatusChanged?()
        syncViewState()

        let urlStr = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlStr) else {
            isChecking = false
            checkFailed = true
            onStatusChanged?()
            syncViewState()
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }
                    self.isChecking = false

                    guard let data = data,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let tagName = json["tag_name"] as? String else {
                        log("Updater: failed to fetch latest release: \(error?.localizedDescription ?? "parse error")")
                        self.checkFailed = true
                        self.onStatusChanged?()
                        self.syncViewState()
                        return
                    }

                    let remote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                    self.latestVersion = remote
                    self.checkFailed = false
                    log("Updater: current=\(self.currentVersion) latest=\(remote)")

                    self.onStatusChanged?()
                    self.syncViewState()
                }
            }
        }.resume()
    }

    // MARK: - Update

    func performUpdate() {
        guard let remote = latestVersion, updateAvailable else { return }
        isUpdating = true
        onStatusChanged?()
        syncViewState()

        let tag = "v\(remote)"
        let downloadURL = "https://github.com/\(repo)/releases/download/\(tag)/\(assetName)"
        guard let url = URL(string: downloadURL) else {
            log("Updater: bad download URL")
            isUpdating = false
            onStatusChanged?()
            syncViewState()
            return
        }

        log("Updater: downloading \(downloadURL)")

        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self = self else { return }

                    guard let tempURL = tempURL, error == nil else {
                        log("Updater: download failed: \(error?.localizedDescription ?? "unknown")")
                        self.isUpdating = false
                        self.onStatusChanged?()
                        self.syncViewState()
                        return
                    }

                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                        log("Updater: download returned HTTP \(httpResponse.statusCode)")
                        self.isUpdating = false
                        self.onStatusChanged?()
                        self.syncViewState()
                        return
                    }

                    self.installAndRelaunch(zipURL: tempURL)
                }
            }
        }.resume()
    }

    // MARK: - Install

    private func installAndRelaunch(zipURL: URL) {
        guard let appBundle = Bundle.main.bundlePath as String?,
              appBundle.hasSuffix(".app") else {
            log("Updater: not running from .app bundle, cannot update")
            isUpdating = false
            onStatusChanged?()
            syncViewState()
            return
        }

        let appURL = URL(fileURLWithPath: appBundle)
        let parentDir = appURL.deletingLastPathComponent()
        let appName = appURL.lastPathComponent

        let extractDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude-toc-update-\(UUID().uuidString)")

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", zipURL.path, "-d", extractDir.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice

        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch {
            log("Updater: unzip failed: \(error)")
            isUpdating = false
            onStatusChanged?()
            syncViewState()
            return
        }

        guard unzip.terminationStatus == 0 else {
            log("Updater: unzip exit code \(unzip.terminationStatus)")
            isUpdating = false
            onStatusChanged?()
            syncViewState()
            return
        }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil),
              let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
            log("Updater: no .app found in zip")
            isUpdating = false
            onStatusChanged?()
            syncViewState()
            return
        }

        let destApp = parentDir.appendingPathComponent(appName)
        let script = """
        #!/bin/bash
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do
            sleep 0.2
        done
        rm -rf "\(destApp.path)"
        mv "\(newApp.path)" "\(destApp.path)"
        rm -rf "\(extractDir.path)"
        open "\(destApp.path)"
        """

        let scriptPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude-toc-update.sh")
        try? script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = [scriptPath.path]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try? launcher.run()

        log("Updater: launched update script, quitting app")
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Helpers

    private func isNewer(remote: String, local: String) -> Bool {
        let rParts = remote.split(separator: ".").compactMap { Int($0) }
        let lParts = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(rParts.count, lParts.count) {
            let r = i < rParts.count ? rParts[i] : 0
            let l = i < lParts.count ? lParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }
}

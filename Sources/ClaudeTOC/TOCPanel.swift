import AppKit
import SwiftUI

/// A floating panel that doesn't steal focus from the terminal
class TOCPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isFloatingPanel = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.isOpaque = false
        self.backgroundColor = .clear
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.animationBehavior = .utilityWindow
        self.hidesOnDeactivate = false
    }
}

@MainActor
class TOCWindowController {
    private var panel: TOCPanel?
    private var tocResult: TOCResult?
    private var terminalType: TerminalType = .unknown
    private var terminalApp: NSRunningApplication?

    func show(tocResult: TOCResult, terminalType: TerminalType, terminalApp: NSRunningApplication?) {
        self.tocResult = tocResult
        self.terminalType = terminalType
        self.terminalApp = terminalApp

        panel?.close()

        guard !tocResult.headings.isEmpty else {
            log("show: no headings, skipping")
            return
        }

        let rowHeight: CGFloat = 28
        let headerHeight: CGFloat = 40
        let contentHeight = min(CGFloat(tocResult.headings.count) * rowHeight + headerHeight, 400)
        let panelWidth: CGFloat = 260

        // Find terminal window position via CGWindowList
        let panelOrigin = findTerminalTopRight(terminalApp: terminalApp, panelWidth: panelWidth, panelHeight: contentHeight)

        let panelRect = NSRect(x: panelOrigin.x, y: panelOrigin.y, width: panelWidth, height: contentHeight)
        log("show: panelRect = \(panelRect)")

        let newPanel = TOCPanel(contentRect: panelRect)

        let hostingView = NSHostingView(rootView: TOCView(
            headings: tocResult.headings,
            totalLines: tocResult.totalLines,
            onHeadingClick: { [weak self] heading in
                self?.handleHeadingClick(heading)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        ))

        newPanel.contentView = hostingView
        newPanel.orderFrontRegardless()

        self.panel = newPanel

        sendNotification(
            title: "Claude responded",
            body: "\(tocResult.headings.count) sections"
        )
    }

    func dismiss() {
        panel?.close()
        panel = nil
        NSApplication.shared.terminate(nil)
    }

    private func handleHeadingClick(_ heading: TOCHeading) {
        log("handleHeadingClick: '\(heading.title)' level=\(heading.level)")
        guard let termApp = terminalApp,
              let toc = tocResult else {
            log("handleHeadingClick: missing terminalApp or tocResult")
            return
        }

        TerminalAdapter.jumpToHeading(
            heading: heading,
            responseTerminalLines: toc.estimatedTerminalLines,
            app: termApp
        )
    }

    /// Find the top-right corner of the terminal window and return NSWindow origin for our panel
    private func findTerminalTopRight(terminalApp: NSRunningApplication?, panelWidth: CGFloat, panelHeight: CGFloat) -> NSPoint {
        guard let termApp = terminalApp else {
            log("findTerminalTopRight: no terminal app, using main screen")
            return fallbackPosition(panelWidth: panelWidth, panelHeight: panelHeight)
        }

        let pid = termApp.processIdentifier
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? Int32,
                  ownerPID == pid,
                  let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let cgX = bounds["X"], let cgY = bounds["Y"],
                  let cgW = bounds["Width"], let cgH = bounds["Height"],
                  cgW > 100, cgH > 100 else { // skip tiny windows (menus, etc)
                continue
            }

            log("findTerminalTopRight: terminal CG bounds x=\(cgX) y=\(cgY) w=\(cgW) h=\(cgH)")

            // Log all screens for debugging
            for (i, screen) in NSScreen.screens.enumerated() {
                log("  screen[\(i)]: frame=\(screen.frame) visibleFrame=\(screen.visibleFrame)")
            }

            // CG coordinates: top-left origin, Y increases downward
            // NS coordinates: bottom-left origin, Y increases upward
            // Primary screen (screens[0]) origin is top-left = NS bottom-left
            let primaryHeight = NSScreen.screens[0].frame.height

            // Terminal top-right in CG: (cgX + cgW, cgY)
            // Convert to NS: y_ns = primaryHeight - y_cg
            let termRightNS = cgX + cgW
            let termTopNS = primaryHeight - cgY

            // Panel goes at top-right of terminal, inset 16px
            var panelX = termRightNS - panelWidth - 16
            var panelY = termTopNS - panelHeight - 16

            log("findTerminalTopRight: initial NS origin x=\(panelX) y=\(panelY)")

            // Find the screen this terminal is on and clamp
            let termCenterCG = CGPoint(x: cgX + cgW / 2, y: cgY + cgH / 2)
            for screen in NSScreen.screens {
                let screenCGY = primaryHeight - screen.frame.maxY
                let screenCGRect = CGRect(x: screen.frame.minX, y: screenCGY, width: screen.frame.width, height: screen.frame.height)
                if screenCGRect.contains(termCenterCG) {
                    let vf = screen.visibleFrame
                    panelX = min(max(panelX, vf.minX + 8), vf.maxX - panelWidth - 8)
                    panelY = min(max(panelY, vf.minY + 8), vf.maxY - panelHeight - 8)
                    log("findTerminalTopRight: clamped to screen visibleFrame=\(vf), final x=\(panelX) y=\(panelY)")
                    break
                }
            }

            return NSPoint(x: panelX, y: panelY)
        }

        log("findTerminalTopRight: no terminal window found, using fallback")
        return fallbackPosition(panelWidth: panelWidth, panelHeight: panelHeight)
    }

    private func fallbackPosition(panelWidth: CGFloat, panelHeight: CGFloat) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        return NSPoint(x: vf.maxX - panelWidth - 20, y: vf.maxY - panelHeight - 20)
    }

    private func sendNotification(title: String, body: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", """
            display notification "\(body)" with title "\(title)"
        """]
        try? process.run()
    }
}

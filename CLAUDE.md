# Claude TOC

macOS menu bar app that displays a floating table of contents panel for Claude Code responses in terminal emulators.

## What It Does

When Claude Code finishes a response, a Stop hook triggers `hook.sh` which sends the transcript path and terminal metadata to the running app via Unix socket IPC. The app parses the JSONL transcript, extracts markdown headings from the latest assistant message, and shows a floating TOC panel anchored to the terminal window. Clicking a heading scrolls the terminal to that location via the Accessibility API.

## Architecture

```
hook.sh (Stop hook)
  → ClaudeTOC binary (IPC client mode → sends message → exits)
    → Running ClaudeTOC.app (IPC server → SessionManager)
      → TOCParser: parses JSONL transcript, extracts headings
      → TerminalAdapter: detects terminal, jumps to heading via AX API
      → WindowObserver: tracks window focus/move/resize, manages panel visibility
      → TOCPanel + TOCView: floating SwiftUI panel with clickable headings
      → MenuBarController: status bar menu for session management
```

## Key Concepts

- **Session**: One Claude Code conversation in a specific terminal window. Identified by transcript file, tracks terminal window reference, TOC panel, and parsed headings.
- **Single Instance**: First launch starts the app with IPC server. Subsequent invocations (from hooks) send IPC messages to the running instance and exit.
- **Window Matching**: Uses `CGWindowID` for stable window identification. Falls back to AX hierarchy walk and focused window detection.
- **Panel Visibility**: Panels auto-show/hide based on terminal focus. Tracked via AXObserver (per-terminal-app) + CGWindowList polling fallback.

## Source Files

| File | Purpose |
|------|---------|
| `main.swift` | Entry point, single-instance coordination, IPC client |
| `TOCPanel.swift` | TOCSession model, TOCSessionManager (core orchestration), NSPanel creation |
| `TOCView.swift` | SwiftUI view for heading list rendering |
| `TOCParser.swift` | JSONL transcript parsing, markdown heading extraction, terminal line estimation |
| `TerminalAdapter.swift` | Terminal detection (6 emulators), AX-based scroll/jump |
| `WindowObserver.swift` | AXObserver + CGWindowList polling for window tracking |
| `MenuBarController.swift` | NSStatusBar menu UI |
| `OnboardingView.swift` | Accessibility permission onboarding flow |
| `SocketIPC.swift` | Unix domain socket IPC server/client |

## Build & Run

```bash
./build.sh              # Developer ID signed, fast
./build.sh --notarize   # + Apple notarization (Gatekeeper bypass), slow
```

- Swift 6.2, SPM, targets macOS 13+, Apple Silicon only (arm64)
- `build.sh` compiles release, packages .app in /tmp (to avoid xattr), signs with Developer ID, creates styled DMG + ZIP
- Requires Accessibility permission (prompted on first launch)

### Release checklist

```bash
# 1. Update version in Info.plist (both CFBundleVersion and CFBundleShortVersionString)
# 2. Build
./build.sh
# 3. Verify ZIP signature (critical — broken signature = auto-update fails silently)
TMPDIR_V=$(mktemp -d) && unzip -q build/TOC.for.Claude.Code.app.zip -d "$TMPDIR_V" && \
  codesign --verify --deep --strict "$TMPDIR_V/TOC for Claude Code.app" && echo "ZIP OK" ; rm -rf "$TMPDIR_V"
# 4. Release
gh release create v{version} "build/TOC for Claude Code.dmg" "build/TOC.for.Claude.Code.app.zip" --title "v{version}" --notes "..."
# 5. Verify ZIP asset exists (auto-update depends on exact filename)
gh release view v{version} --json assets -q '.assets[].name' | grep -q TOC.for.Claude.Code.app.zip
```

### Build pitfalls

- **xattr / resource forks break codesign**: macOS `build/` directory inherits `com.apple.provenance` xattr. Files copied from it (via `cp -R` or `ditto`) carry `._` resource forks that invalidate signatures after unzip. The ZIP must be built from a clean staging dir (rsync --exclude '._*', xattr -cr, COPYFILE_DISABLE=1 ditto --norsrc). This is already handled in `build.sh` — do NOT simplify the ZIP packaging step.
- **Sign before move**: codesign must happen in /tmp staging, not after `mv` to `build/`. The `mv` operation causes macOS to apply xattr to the destination.
- **Auto-update asset name**: `Updater.swift` hardcodes `TOC.for.Claude.Code.app.zip` (dot-separated). The DMG uses spaces (`TOC for Claude Code.dmg`). Do not change either name — old versions depend on the exact ZIP filename.

## Hook Integration

`hook.sh` is a Claude Code Stop hook. It:
1. Reads transcript path from stdin JSON (via `plutil`)
2. Detects terminal bundle ID from env vars (TERM_PROGRAM, KITTY_PID, etc.)
3. Gets TTY, terminal columns, window ID
4. Invokes ClaudeTOC binary which sends IPC to running instance

Supported terminals: Terminal.app, iTerm2, Kitty, Warp, Alacritty, Termius, Ghostty, WezTerm, Wave Terminal, Rio, Tabby, Cursor, Hyper.

## Conventions

- UI text is in Chinese (简体中文)
- `Test/` folder contains test files, not production code
- Logs written to `/tmp/claude-toc.log` with 1MB rotation
- IPC socket in user-isolated temp directory

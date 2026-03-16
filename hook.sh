#!/bin/bash
# Claude Code Stop hook — launches TOC panel after Claude finishes responding

PROJECT_DIR="${HOME}/Documents/Playgrounds/claude-toc"
CLAUDE_TOC_BIN="${PROJECT_DIR}/build/ClaudeTOC.app/Contents/MacOS/ClaudeTOC"

# Fallback to debug build if .app not found
if [ ! -f "$CLAUDE_TOC_BIN" ]; then
    CLAUDE_TOC_BIN="${PROJECT_DIR}/.build/arm64-apple-macosx/debug/ClaudeTOC"
fi

# Read stdin to a temp file
STDIN_TMP=$(mktemp)
cat > "$STDIN_TMP"

# Parse transcript_path — use plutil (macOS built-in), no python3 dependency
TRANSCRIPT_PATH=$(plutil -extract transcript_path raw "$STDIN_TMP" 2>/dev/null)
rm -f "$STDIN_TMP"

[ -z "$TRANSCRIPT_PATH" ] && exit 0

CALLER_PID=$PPID

# Detect terminal bundle ID from environment variables
TERMINAL_BUNDLE_ID=""
case "${TERM_PROGRAM:-}" in
    iTerm.app)    TERMINAL_BUNDLE_ID="com.googlecode.iterm2" ;;
    Apple_Terminal) TERMINAL_BUNDLE_ID="com.apple.Terminal" ;;
    WarpTerminal) TERMINAL_BUNDLE_ID="dev.warp.Warp-Stable" ;;
    tmux)
        # Inside tmux, check the outer terminal
        if [ -n "${ITERM_SESSION_ID:-}" ]; then
            TERMINAL_BUNDLE_ID="com.googlecode.iterm2"
        fi
        ;;
esac
# Kitty sets its own env var
if [ -n "${KITTY_PID:-}" ]; then
    TERMINAL_BUNDLE_ID="net.kovidgoyal.kitty"
fi
# Alacritty detection
if [ "${TERM:-}" = "alacritty" ]; then
    TERMINAL_BUNDLE_ID="org.alacritty"
fi

# Get actual terminal columns (much more accurate than pixel estimation)
TERM_COLS=$(tput cols 2>/dev/null || echo "")

# Build command args
ARGS=("$TRANSCRIPT_PATH" --hook-pid "$CALLER_PID")
[ -n "$TERMINAL_BUNDLE_ID" ] && ARGS+=(--terminal-bundle-id "$TERMINAL_BUNDLE_ID")
[ -n "$TERM_COLS" ] && ARGS+=(--terminal-columns "$TERM_COLS")

# Binary handles singleton: sends to running instance or starts new one
"$CLAUDE_TOC_BIN" "${ARGS[@]}" >/dev/null 2>&1 &
disown

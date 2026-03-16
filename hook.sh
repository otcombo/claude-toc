#!/bin/bash
# Claude Code Stop hook — launches TOC panel after Claude finishes responding

PROJECT_DIR="${HOME}/Documents/Playgrounds/claude-toc"
CLAUDE_TOC_BIN="${PROJECT_DIR}/build/TOC for Claude Code.app/Contents/MacOS/ClaudeTOC"

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
# Termius detection — walk up process tree looking for Termius or todesktop
if [ -z "$TERMINAL_BUNDLE_ID" ]; then
    _PID=$CALLER_PID
    for _ in 1 2 3 4 5 6; do
        _PID=$(ps -o ppid= -p $_PID 2>/dev/null | tr -d ' ')
        [ -z "$_PID" ] || [ "$_PID" = "1" ] || [ "$_PID" = "0" ] && break
        _CMD=$(ps -o command= -p $_PID 2>/dev/null)
        if echo "$_CMD" | grep -q "Termius"; then
            TERMINAL_BUNDLE_ID="com.termius-dmg.mac"
            break
        fi
    done
fi

# Get actual terminal columns (much more accurate than pixel estimation)
TERM_COLS=$(tput cols 2>/dev/null || echo "")

# Get TTY device for window matching (use parent's tty since our stdin is a pipe)
HOOK_TTY=$(ps -o tty= -p $CALLER_PID 2>/dev/null | tr -d ' ')

# Resolve TTY → Terminal.app window ID via AppleScript (hook runs in Terminal's context, has permission)
WINDOW_ID=""
if [ -n "$HOOK_TTY" ] && [ "$TERMINAL_BUNDLE_ID" = "com.apple.Terminal" ]; then
    WINDOW_ID=$(osascript -e "
        tell application \"Terminal\"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is \"/dev/$HOOK_TTY\" then
                        return id of w
                    end if
                end repeat
            end repeat
        end tell
    " 2>/dev/null)
fi

# Build command args
ARGS=("$TRANSCRIPT_PATH" --hook-pid "$CALLER_PID")
[ -n "$TERMINAL_BUNDLE_ID" ] && ARGS+=(--terminal-bundle-id "$TERMINAL_BUNDLE_ID")
[ -n "$TERM_COLS" ] && ARGS+=(--terminal-columns "$TERM_COLS")
[ -n "$HOOK_TTY" ] && ARGS+=(--tty "$HOOK_TTY")
[ -n "$WINDOW_ID" ] && ARGS+=(--window-id "$WINDOW_ID")

# Only send to an already-running instance — don't launch the app.
# The user must open ClaudeTOC.app explicitly for TOC + notifications.
"$CLAUDE_TOC_BIN" "${ARGS[@]}" >/dev/null 2>&1

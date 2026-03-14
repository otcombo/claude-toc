#!/bin/bash
# Claude Code Stop hook — launches TOC panel after Claude finishes responding

CLAUDE_TOC_BIN="${HOME}/Applications/ClaudeTOC.app/Contents/MacOS/ClaudeTOC"

# Fallback to debug build if .app not found
if [ ! -f "$CLAUDE_TOC_BIN" ]; then
    CLAUDE_TOC_BIN="${HOME}/Documents/Playgrounds/claude-toc/.build/arm64-apple-macosx/debug/ClaudeTOC"
fi

# Read stdin to a temp file
STDIN_TMP=$(mktemp)
cat > "$STDIN_TMP"

TRANSCRIPT_PATH=$(python3 -c "import json,sys; print(json.load(open('$STDIN_TMP'))['transcript_path'])" 2>/dev/null)
rm -f "$STDIN_TMP"

[ -z "$TRANSCRIPT_PATH" ] && exit 0

CALLER_PID=$PPID

# Binary handles singleton: sends to running instance or starts new one
"$CLAUDE_TOC_BIN" "$TRANSCRIPT_PATH" --hook-pid $CALLER_PID >/dev/null 2>&1 &
disown

#!/bin/bash
# Claude Code Stop hook — launches TOC panel after Claude finishes responding

CLAUDE_TOC_BIN="${HOME}/Projects/claude-toc/.build/arm64-apple-macosx/debug/ClaudeTOC"

# Read stdin to a temp file
STDIN_TMP=$(mktemp)
cat > "$STDIN_TMP"

TRANSCRIPT_PATH=$(python3 -c "import json,sys; print(json.load(open('$STDIN_TMP'))['transcript_path'])" 2>/dev/null)

if [ -z "$TRANSCRIPT_PATH" ]; then
    rm -f "$STDIN_TMP"
    exit 0
fi

# Pass PPID — the shell that Claude Code used to invoke this hook.
# That shell's parent chain leads to the terminal app.
# We can't use $$ because hook.sh exits before ClaudeTOC walks the tree.
CALLER_PID=$PPID

pkill -f "ClaudeTOC" 2>/dev/null
cat "$STDIN_TMP" | "$CLAUDE_TOC_BIN" --hook-pid $CALLER_PID &

rm -f "$STDIN_TMP"

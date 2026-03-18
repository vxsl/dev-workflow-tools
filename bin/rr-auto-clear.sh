#!/usr/bin/env bash
# Auto-clear helper for rr.sh refresh summary
# Waits 2.5s then sends F9 to trigger normal reload

set -euo pipefail

sleep 2.5

AUTO_CLEAR_FAILED=false

# Try tmux first (most reliable if in tmux)
if command -v tmux &>/dev/null && [ -n "${TMUX:-}" ]; then
    tmux send-keys -t "${TMUX_PANE}" F9
    exit 0
fi

# Try osascript on macOS (built-in)
if [[ "$OSTYPE" == "darwin"* ]] && command -v osascript &>/dev/null; then
    # F9 key code is 101
    osascript -e 'tell application "System Events" to key code 101' 2>/dev/null && exit 0
    AUTO_CLEAR_FAILED=true
fi

# Try xdotool on Linux with X11
if command -v xdotool &>/dev/null && [ -n "${DISPLAY:-}" ]; then
    WINDOW_ID=$(xdotool getwindowfocus 2>/dev/null)
    if [ -n "$WINDOW_ID" ]; then
        xdotool key --window "$WINDOW_ID" F9 2>/dev/null && exit 0
    fi
    AUTO_CLEAR_FAILED=true
fi

# Fallback: No auto-clear available
# Write a message that the main script can detect and display
if [ "$AUTO_CLEAR_FAILED" = "true" ]; then
    echo "AUTO_CLEAR_FAILED" > ~/.cache/rr/auto_clear_status 2>/dev/null || true
fi
exit 1

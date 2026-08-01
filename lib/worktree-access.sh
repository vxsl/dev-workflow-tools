#!/usr/bin/env bash
# worktree-access - the shared "which worktree did I last go to" log.
#
# rr and fzedit both answer "show me my worktrees, most recent first", and they used
# to answer it differently: rr from its own navigation log, fzedit from the mtime of
# each worktree's .git/index. Those disagree constantly -- index mtime moves when a
# background `git status` touches it, and does NOT move when you simply go and read
# code somewhere. So the two tools offered you different "most recent" worktrees, and
# neither reflected the switches you made in the other.
#
# One log, written by whoever switches. Format is rr's, unchanged, so an existing log
# keeps working: "<epoch>\t<worktree path>", one line per worktree, rewritten in place
# rather than appended to (the file stays as long as your worktree list, not as long
# as your history).

WTA_LOG="${WTA_LOG:-$HOME/.cache/rr/worktree_access.log}"

# Record that a worktree was navigated to.
wta_record() {
    local wt_path="$1" ts
    [ -n "$wt_path" ] || return 0
    ts=$(date +%s)
    mkdir -p "$(dirname "$WTA_LOG")" 2>/dev/null || return 0
    if [ -f "$WTA_LOG" ]; then
        # Drop any previous entry for this path, then append the new one, so the file
        # holds exactly one line per worktree.
        grep -v "	$wt_path\$" "$WTA_LOG" > "$WTA_LOG.tmp" 2>/dev/null || true
        printf '%s\t%s\n' "$ts" "$wt_path" >> "$WTA_LOG.tmp"
        mv "$WTA_LOG.tmp" "$WTA_LOG"
    else
        printf '%s\t%s\n' "$ts" "$wt_path" > "$WTA_LOG"
    fi
}

# Last navigation time for a worktree, or nothing if it has never been visited.
wta_time() {
    local wt_path="$1"
    [ -f "$WTA_LOG" ] || return 0
    grep "	$wt_path\$" "$WTA_LOG" 2>/dev/null | tail -1 | cut -f1
}

# The whole log as "<epoch>\t<path>", for a caller that wants to rank a list in one
# pass rather than calling wta_time once per worktree.
wta_all() {
    [ -f "$WTA_LOG" ] || return 0
    cat "$WTA_LOG" 2>/dev/null
}

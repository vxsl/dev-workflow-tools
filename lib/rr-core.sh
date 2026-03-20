#!/usr/bin/env bash
# rr-core.sh — Extracted testable functions from rr.sh
# Sourced by both rr.sh and the test suite.

# Compute the sort timestamp for a worktree path.
# Returns the maximum of: navigation log time, HEAD mtime, or now (if PWD matches).
# Globals read: WORKTREE_NAV_TIMES (associative array), PWD
# Args: $1 = wt_path
# Output: unix timestamp (integer) on stdout
compute_worktree_timestamp() {
    local wt_path="$1"
    local ts=0

    # If we're currently in this worktree, use NOW
    if [ "$PWD" = "$wt_path" ] || [[ "$PWD" == "$wt_path/"* ]]; then
        date +%s
        return
    fi

    # Check navigation log (pre-loaded into associative array)
    local nav_ts="${WORKTREE_NAV_TIMES[$wt_path]:-0}"
    [ "$nav_ts" -gt "$ts" ] && ts=$nav_ts

    # Check HEAD mtime (git operations update this)
    local gitdir
    gitdir=$(get_worktree_gitdir "$wt_path")
    if [ -n "$gitdir" ] && [ -f "$gitdir/HEAD" ]; then
        local head_mtime
        head_mtime=$(stat -c %Y "$gitdir/HEAD" 2>/dev/null || stat -f %m "$gitdir/HEAD" 2>/dev/null)
        [ -n "$head_mtime" ] && [ "$head_mtime" -gt "$ts" ] && ts=$head_mtime
    fi

    echo "$ts"
}

# Parse reflog for recent branch checkouts.
# Args: $1 = reflog_git_dir (e.g. "--git-dir=/path" or ""), $2 = max entries to scan
# Output: TSV lines "branch\tunix_time" (deduplicated, in reflog order)
parse_reflog_branches() {
    local reflog_git_dir="$1"
    local scan_count="$2"

    git $reflog_git_dir reflog -n "$scan_count" --date=unix 2>/dev/null \
        | grep 'checkout: moving' \
        | sed -E 's/^[a-f0-9]+ HEAD@\{([0-9]+)\}: checkout: moving from .* to ([^ ]+).*$/\2\t\1/' \
        | awk -F'\t' '!seen[$1]++ { print }'
}

# Extract unix timestamp from a time_info field like "checked:1770827880"
# Args: $1 = time_info string
# Output: integer timestamp (0 if not parseable)
compute_sort_key() {
    local time_info="$1"
    if [[ "$time_info" =~ :([0-9]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "0"
    fi
}

# Truncate string with ellipsis if longer than max_length
# Args: $1 = string, $2 = max_length
# Output: truncated string
truncate_str() {
    local str="$1"
    local max_length="$2"
    if [ ${#str} -gt "$max_length" ]; then
        echo "${str:0:$((max_length-3))}..."
    else
        echo "$str"
    fi
}

# Get the eponymous branch name for a worktree path (inferred from directory name)
# e.g. /path/ul.UB-6506 -> UB-6506, /path/my-feature -> my-feature
# Args: $1 = worktree path
# Output: branch name
# Get the actual git directory for a worktree (resolves .git file to actual gitdir)
# Args: $1 = worktree path
# Output: path to git directory
get_worktree_gitdir() {
    local wt_path="$1"
    if [ -f "$wt_path/.git" ]; then
        grep '^gitdir:' "$wt_path/.git" 2>/dev/null | cut -d' ' -f2
    elif [ -d "$wt_path/.git" ]; then
        echo "$wt_path/.git"
    fi
}

get_eponymous_branch_pure() {
    local wt_path="$1"
    local wt_basename
    wt_basename=$(basename "$wt_path")
    if [[ "$wt_basename" =~ \.([^.]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$wt_basename"
    fi
}

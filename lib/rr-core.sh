#!/usr/bin/env bash
# rr-core.sh — Extracted testable functions from rr.sh
# Sourced by both rr.sh and the test suite.

# "Is this the branch I asked for" is also asked by fzedit's header and by the p10k
# prompt segment, and all three have to answer it the same way — see the header of
# worktree-mismatch.sh. Self-locating so the test suite and rr.sh both get it.
source "$(dirname "${BASH_SOURCE[0]}")/worktree-mismatch.sh"
# Likewise "which worktree is this": one palette, shared with the prompt and fzedit.
source "$(dirname "${BASH_SOURCE[0]}")/worktree-colour.sh"

# The ⊙ indicator for a worktree row, as a filled block in that worktree's own colour —
# the same block the p10k prompt segment and fzedit's header draw, so a checkout is
# recognisable on sight in all three places rather than in one of them.
#
# EXACTLY 4 visual columns, as before: only SGR codes are added, never characters. rr
# aligns the whole table by hand against that number (wt_visual_width), so a block that
# was one column wider would shear every row below it.
#
# Sets WT_INDICATOR_DISPLAY rather than printing, because this runs once per row on a path
# that goes out of its way to avoid subshells — the $(printf ...) it replaces was a fork
# per row.
#
# Also sets WT_BRANCH_SGR: the escape that extends the block back across the branch name
# itself, so the whole cell is one segment rather than a coloured pip next to plain text.
# Empty when there is no colour, and the callers put it AFTER whatever foreground they
# were going to use, so a row with no worktree keeps exactly the colour it had.
#
# $1 = worktree path, $2 = non-empty if a different branch is checked out, $3 = non-empty
# if the worktree is dirty.
render_wt_indicator() {
    local wt_path="$1" mismatch="$2" dirty="$3"
    local off=$'\033[0m' warn=$'\033[38;5;214m' flat=$'\033[38;5;250m'
    worktree_colour_key "$wt_path"
    wtc_colour "$WTC_KEY"
    WT_BRANCH_SGR=""

    if [ -z "$WTC_COLOUR" ]; then
        # No worktree name, so this is the primary checkout — which the prompt segment
        # also leaves untinted. "No block" means "you are on the main checkout", and it
        # has to keep meaning that everywhere.
        if   [ -n "$mismatch" ]; then WT_INDICATOR_DISPLAY=" ${warn}⊙≠${off} "
        elif [ -n "$dirty" ];    then WT_INDICATOR_DISPLAY=" ${flat}⊙${warn} !${off}"
        else                          WT_INDICATOR_DISPLAY=" ${flat}⊙${off}  "
        fi
        return
    fi

    local block=$'\033[48;5;'"$WTC_COLOUR"$'m\033[30m'
    WT_BRANCH_SGR="$block"
    if   [ -n "$mismatch" ]; then WT_INDICATOR_DISPLAY="${block} ⊙≠${off} "
    elif [ -n "$dirty" ];    then WT_INDICATOR_DISPLAY="${block} ⊙ ${off}${warn}!${off}"
    else                          WT_INDICATOR_DISPLAY="${block} ⊙ ${off} "
    fi
}

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

# The branch git has parked while a worktree is mid-rebase, or nothing.
#
# `git worktree list --porcelain` reports a rebasing worktree as `detached` with no branch
# line at all, because HEAD genuinely is a bare sha. Taking that at face value loses the
# branch at the worst possible moment: everything downstream falls back to inferring one
# from the directory name, which for a namespaced branch is not the branch. A worktree for
# `hotfix/fix-the-thing` lives at `repo.hotfix/fix-the-thing` (see create-wt), so the
# basename is `fix-the-thing` and the `hotfix/` is simply gone -- and navigating there
# reported a worktree mismatch against a branch that does not exist.
#
# rebase-{merge,apply}/head-name is where git keeps the real branch. NB in the worktree's
# OWN gitdir: `$wt/.git` is a *file* in a linked worktree, not a directory, so the
# `$wt/.git/rebase-merge/...` this replaces could never match for any worktree except the
# primary one -- which is the last place a rebase needs recovering from.
worktree_parked_branch() {
    local wt_path="$1" gitdir head_name=""
    gitdir=$(get_worktree_gitdir "$wt_path")
    [ -n "$gitdir" ] || return 1
    if [ -f "$gitdir/rebase-merge/head-name" ]; then
        head_name=$(< "$gitdir/rebase-merge/head-name")
    elif [ -f "$gitdir/rebase-apply/head-name" ]; then
        head_name=$(< "$gitdir/rebase-apply/head-name")
    fi
    [ -n "$head_name" ] || return 1
    printf '%s\n' "${head_name#refs/heads/}"
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

# Decide whether the worktree-mismatch prompt should be skipped for a worktree
# whose HEAD is detached (rev-parse --abbrev-ref HEAD returned "HEAD").
# Detached HEAD is usually transient state, not a real mismatch:
#   - mid-rebase/bisect of the expected branch (a checkout would wreck it)
#   - parked on an ancestor commit of the expected branch (inspecting history)
# A rebase of a DIFFERENT branch, or detachment at a non-ancestor commit, is
# still a genuine mismatch and should prompt.
# Args: $1 = worktree path, $2 = expected branch
# Output: skip reason on stdout ("rebase" or "ancestor") when skipping
# Returns: 0 = skip the prompt, 1 = show it
detached_mismatch_skip_reason() {
    local wt_path="$1"
    local branch="$2"

    # Rebase in progress — check which branch is being rebased
    local head_name
    head_name=$(worktree_parked_branch "$wt_path")
    if [ -n "$head_name" ]; then
        # Not an exact comparison: the branch we were asked for often comes from a
        # worktree directory name, which abbreviates it (repo.UB-6709 holding
        # UB-6709-add-custom-trimet-layer). Comparing exactly reported a mismatch
        # against the very branch being rebased, and then showed "Actual HEAD" as the
        # evidence -- which is not a branch anyone has ever checked out on purpose.
        if wtm_same_branch "${head_name}" "$branch"; then
            echo "rebase"
            return 0
        fi
        # A namespaced branch is named by PATH, not by basename: hotfix/fix-x lives at
        # repo.hotfix/fix-x (see create-wt), so an eponymous name derived from the
        # basename has lost the "hotfix/" and no prefix rule can put it back. The path
        # can -- if the directory is literally named after the branch being rebased, that
        # branch is what this worktree is for.
        #
        # Only when $branch is that basename-derived alias, though. Any other name we
        # were handed -- a displaced ticket id, say -- is a real question about what this
        # worktree is busy with, and deserves the prompt.
        if [ "$branch" = "$(get_eponymous_branch_pure "$wt_path")" ]; then
            case "$wt_path" in *".$head_name") echo "rebase"; return 0 ;; esac
        fi
        return 1
    fi

    local git_dir
    git_dir=$(git -C "$wt_path" rev-parse --absolute-git-dir 2>/dev/null)
    [ -z "$git_dir" ] && return 1

    # Detached at an ancestor of the expected branch (includes the tip itself,
    # and typical bisect positions)
    if git -C "$wt_path" merge-base --is-ancestor HEAD "refs/heads/$branch" 2>/dev/null; then
        echo "ancestor"
        return 0
    fi

    return 1
}

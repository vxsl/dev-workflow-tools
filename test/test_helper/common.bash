#!/usr/bin/env bash
# Common test helpers for rr.sh BATS tests

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Source the extracted core functions
source "$REPO_ROOT/lib/rr-core.sh"

# Create a temp directory for each test
setup_temp_dir() {
    TEST_TMPDIR=$(mktemp -d)
    export TEST_TMPDIR
}

teardown_temp_dir() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# Create a bare git repo that can have worktrees added
# Sets: TEST_GIT_REPO (main repo path), GIT_ROOT
setup_git_repo() {
    setup_temp_dir
    TEST_GIT_REPO="$TEST_TMPDIR/main-repo"
    mkdir -p "$TEST_GIT_REPO"
    cd "$TEST_GIT_REPO"
    git init -q -b main
    git commit -q --allow-empty -m "initial commit"
    export GIT_ROOT="$TEST_GIT_REPO"
    export TEST_GIT_REPO
}

# Create a branch with a controlled commit timestamp
# Args: $1 = branch name, $2 = unix timestamp for the commit
create_branch_at_time() {
    local branch="$1"
    local ts="$2"
    cd "$TEST_GIT_REPO"
    git checkout -q -b "$branch" 2>/dev/null || git checkout -q "$branch"
    GIT_COMMITTER_DATE="$ts +0000" GIT_AUTHOR_DATE="$ts +0000" \
        git commit -q --allow-empty -m "commit on $branch"
    git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null
}

# Create a worktree for a branch
# Args: $1 = branch name, $2 = optional worktree path (defaults to TEST_TMPDIR/repo.$branch)
create_worktree() {
    local branch="$1"
    local wt_path="${2:-$TEST_TMPDIR/repo.$branch}"
    cd "$TEST_GIT_REPO"
    git worktree add -q "$wt_path" "$branch" 2>/dev/null
    echo "$wt_path"
}

# Create a worktree with a title-suffixed directory name (simulating JIRA title in path)
# e.g., branch "TEST-100" at path "repo.TEST-100-fix-the-widget"
# Args: $1 = branch name, $2 = title suffix
create_worktree_with_title() {
    local branch="$1"
    local title_suffix="$2"
    local wt_path="$TEST_TMPDIR/repo.${branch}-${title_suffix}"
    create_worktree "$branch" "$wt_path"
}

# Create a synthetic WORKTREE_ACCESS_LOG
# Args: pairs of "timestamp worktree_path"
# Usage: create_access_log 1770000300 /path/wt1 1770000100 /path/wt2
create_access_log() {
    local log_file="$TEST_TMPDIR/worktree_access.log"
    > "$log_file"
    while [ $# -ge 2 ]; do
        printf '%s\t%s\n' "$1" "$2" >> "$log_file"
        shift 2
    done
    export WORKTREE_ACCESS_LOG="$log_file"
    echo "$log_file"
}

# Load WORKTREE_NAV_TIMES from an access log file
# Must be called after create_access_log
load_nav_times() {
    declare -gA WORKTREE_NAV_TIMES=()
    if [ -f "$WORKTREE_ACCESS_LOG" ]; then
        while IFS=$'\t' read -r ts wt_path; do
            [ -n "$ts" ] && [ -n "$wt_path" ] && WORKTREE_NAV_TIMES["$wt_path"]="$ts"
        done < "$WORKTREE_ACCESS_LOG"
    fi
}

# Create synthetic JIRA cache files
# Args: file path, then pairs of "ticket value"
# Usage: create_jira_cache "$tmpdir/jira_cache" "PROJ-123" "My Title" "PROJ-456" "Other Title"
create_jira_cache() {
    local cache_file="$1"
    shift
    > "$cache_file"
    while [ $# -ge 2 ]; do
        echo "$1:$2" >> "$cache_file"
        shift 2
    done
}

# Simulate reflog checkout entries by doing actual checkouts with controlled timestamps
# Args: pairs of "branch_name unix_timestamp" (in chronological order, earliest first)
# The reflog will show these in reverse chronological order (most recent first)
simulate_checkouts() {
    cd "$TEST_GIT_REPO"
    while [ $# -ge 2 ]; do
        local branch="$1"
        local ts="$2"
        # Checkout the branch — this creates a reflog entry
        GIT_COMMITTER_DATE="$ts +0000" git checkout -q "$branch" 2>/dev/null
        shift 2
    done
    git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null
}

# Extract just branch names (field 7) from TSV output, in order
# Input: TSV data on stdin (rr.sh format, 11 fields)
# Output: branch names, one per line, in the order they appear
extract_branch_order() {
    awk -F'\t' '{ print $7 }'
}

# Extract sort timestamps from TSV output
# Input: TSV data on stdin (rr.sh format, field 5 = time_info like "checked:NNNN")
# Output: timestamps, one per line
extract_timestamps() {
    awk -F'\t' '{
        split($5, a, ":")
        n = length(a)
        if (n >= 2 && a[n] ~ /^[0-9]+$/) print a[n]
        else print "0"
    }'
}

# Verify that a list of values is in strictly descending order
# Input: values on stdin, one per line
# Returns: 0 if descending, 1 if not (with diagnostic on stderr)
assert_descending_order() {
    local prev=""
    local line_num=0
    while IFS= read -r val; do
        line_num=$((line_num + 1))
        if [ -n "$prev" ] && [ "$val" -gt "$prev" ]; then
            echo "NOT DESCENDING at line $line_num: $val > $prev" >&2
            return 1
        fi
        prev="$val"
    done
    return 0
}

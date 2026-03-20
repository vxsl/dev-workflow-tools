#!/usr/bin/env bats
# Tests for displaced branch detection — when a worktree has a different branch
# checked out (e.g., oneshot left a hotfix behind), the original ticket's branch
# should still appear in rr and be navigable.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Setup: create a repo with a worktree that has a mismatched branch
setup_displaced_worktree() {
    setup_git_repo
    export JIRA_PROJECT="TEST"

    # Create the ticket branch
    create_branch_at_time "TEST-100" "1770000000"

    # Create worktree with a title-suffixed path (like real rr would)
    local wt_path="$TEST_TMPDIR/repo.TEST-100-fix-the-widget"
    cd "$TEST_GIT_REPO"
    git worktree add -q "$wt_path" "TEST-100" 2>/dev/null
    export WT_PATH="$wt_path"

    # Now check out a DIFFERENT branch in that worktree (simulating oneshot)
    cd "$TEST_GIT_REPO"
    git checkout -q -b "hotfix/some-urgent-fix" 2>/dev/null
    git commit -q --allow-empty -m "hotfix commit"
    git checkout -q main
    # Switch the worktree to the hotfix branch
    git -C "$wt_path" checkout "hotfix/some-urgent-fix" 2>/dev/null

    cd "$TEST_GIT_REPO"
}

# Source get_eponymous_branch + build_worktree_map into the current shell
load_worktree_map_functions() {
    # get_eponymous_branch is defined in rr.sh
    eval "$(sed -n '/^get_eponymous_branch()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    # build_worktree_map is defined in rr.sh — extract the whole function
    # WORKTREE_BRANCH must be declared before build_worktree_map populates it
    declare -gA WORKTREE_BRANCH=()
    eval "$(sed -n '/^build_worktree_map()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
}

teardown() {
    teardown_temp_dir
}

# --- build_worktree_map with displaced branches ---

@test "build_worktree_map: maps displaced ticket ID to worktree" {
    setup_displaced_worktree

    declare -A WORKTREE_MAP=()
    declare -a DISPLACED_BRANCHES=()
    load_worktree_map_functions

    cd "$TEST_GIT_REPO"
    export GIT_ROOT="$TEST_GIT_REPO"
    build_worktree_map

    # The actual branch (hotfix) should map to the worktree
    [[ "${WORKTREE_MAP[hotfix/some-urgent-fix]}" = "$WT_PATH" ]]

    # The eponymous branch (TEST-100-fix-the-widget) should map to the worktree
    [[ "${WORKTREE_MAP[TEST-100-fix-the-widget]}" = "$WT_PATH" ]]

    # The displaced ticket ID (TEST-100) should ALSO map to the worktree
    [[ "${WORKTREE_MAP[TEST-100]}" = "$WT_PATH" ]]
}

@test "build_worktree_map: no extra displaced mapping when branch matches (title-suffixed dir)" {
    setup_git_repo
    export JIRA_PROJECT="TEST"

    # Create branch and worktree where eponymous starts with actual (normal case)
    create_branch_at_time "TEST-200" "1770000000"
    local wt_path="$TEST_TMPDIR/repo.TEST-200-some-feature"
    cd "$TEST_GIT_REPO"
    git worktree add -q "$wt_path" "TEST-200" 2>/dev/null

    declare -A WORKTREE_MAP=()
    declare -a DISPLACED_BRANCHES=()
    load_worktree_map_functions

    cd "$TEST_GIT_REPO"
    export GIT_ROOT="$TEST_GIT_REPO"
    build_worktree_map

    # Actual branch maps to worktree
    [[ "${WORKTREE_MAP[TEST-200]}" = "$wt_path" ]]

    # Eponymous branch also maps
    [[ "${WORKTREE_MAP[TEST-200-some-feature]}" = "$wt_path" ]]

    # No extra displaced mapping needed — TEST-200 is already the actual branch
}

@test "build_worktree_map: no displaced mapping when ticket branch does not exist" {
    setup_git_repo
    export JIRA_PROJECT="TEST"

    # Create a worktree with a branch that has no matching ticket branch
    cd "$TEST_GIT_REPO"
    git checkout -q -b "feature/unrelated" 2>/dev/null
    git commit -q --allow-empty -m "feature commit"
    git checkout -q main

    # Create worktree dir named for TEST-300 but check out feature/unrelated
    # Note: TEST-300 branch does NOT exist
    local wt_path="$TEST_TMPDIR/repo.TEST-300-does-not-exist"
    git worktree add -q "$wt_path" "feature/unrelated" 2>/dev/null

    declare -A WORKTREE_MAP=()
    declare -a DISPLACED_BRANCHES=()
    load_worktree_map_functions

    cd "$TEST_GIT_REPO"
    export GIT_ROOT="$TEST_GIT_REPO"
    build_worktree_map

    # feature/unrelated maps to worktree
    [[ "${WORKTREE_MAP[feature/unrelated]}" = "$wt_path" ]]

    # Eponymous maps to worktree
    [[ "${WORKTREE_MAP[TEST-300-does-not-exist]}" = "$wt_path" ]]

    # TEST-300 does NOT map because refs/heads/TEST-300 doesn't exist
    [[ -z "${WORKTREE_MAP[TEST-300]:-}" ]]
}

# --- DISPLACED_BRANCHES tracking in generate_worktree_data ---

@test "generate_worktree_data: populates DISPLACED_BRANCHES for mismatched worktrees" {
    setup_displaced_worktree

    # Source required functions
    eval "$(sed -n '/^get_eponymous_branch()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    eval "$(sed -n '/^get_worktree_path()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    eval "$(sed -n '/^get_worktree_navigation_time()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    source "$REPO_ROOT/lib/rr-core.sh"

    truncate() {
        local str=$1 max_length=$2
        if [ ${#str} -gt $max_length ]; then
            echo "${str:0:$((max_length-3))}..."
        else
            echo "$str"
        fi
    }
    export -f truncate

    cd "$TEST_GIT_REPO"
    export GIT_ROOT="$TEST_GIT_REPO"
    export JIRA_PROJECT="TEST"
    export BRANCH_MAX_LENGTH=40

    declare -A WORKTREE_MAP=()
    declare -A WORKTREE_BRANCH=()
    declare -a DISPLACED_BRANCHES=()
    declare -A WORKTREE_NAV_TIMES=()
    declare -A JIRA_TITLE_CACHE=()
    declare -A JIRA_STATUS_CACHE=()
    declare -A JIRA_ASSIGNEE_CACHE=()

    # Build map first
    eval "$(sed -n '/^build_worktree_map()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    build_worktree_map

    # Extract and run generate_worktree_data
    eval "$(sed -n '/^generate_worktree_data()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    generate_worktree_data "" > /dev/null 2>&1

    # DISPLACED_BRANCHES should contain TEST-100
    local found=false
    for b in "${DISPLACED_BRANCHES[@]}"; do
        [ "$b" = "TEST-100" ] && found=true
    done
    [ "$found" = true ]
}

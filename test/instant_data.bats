#!/usr/bin/env bats
# Tests for generate_instant_data — verifies Phase 1 produces correct sort order.

load test_helper/common

# Source enough of rr.sh to test generate_instant_data in isolation.
setup() {
    # REPO_ROOT is set by common.bash (before any cd)
    local repo_root="$REPO_ROOT"

    setup_git_repo

    export JIRA_PROJECT="TEST"
    export JIRA_DOMAIN="test.atlassian.net"
    export CACHE_DIR="$TEST_TMPDIR/cache"
    export WORKTREE_ACCESS_LOG="$TEST_TMPDIR/worktree_access.log"
    mkdir -p "$CACHE_DIR"

    BRANCH_MAX_LENGTH=23

    source "$repo_root/lib/rr-core.sh"

    truncate() {
        local str=$1
        local max_length=$2
        if [ ${#str} -gt $max_length ]; then
            echo "${str:0:$((max_length-3))}..."
        else
            echo "$str"
        fi
    }
    export -f truncate

    declare -gA JIRA_TITLE_CACHE=()
    declare -gA JIRA_STATUS_CACHE=()
    declare -gA JIRA_ASSIGNEE_CACHE=()

    # Define get_eponymous_branch (called by generate_instant_data, defined in rr.sh)
    get_eponymous_branch() {
        get_eponymous_branch_pure "$@"
    }
    export -f get_eponymous_branch

    # Extract generate_instant_data from rr.sh
    eval "$(sed -n '/^generate_instant_data()/,/^}/p' "$repo_root/bin/rr.sh")"
}

teardown() {
    teardown_temp_dir
}

@test "generate_instant_data: worktrees appear sorted by timestamp" {
    create_branch_at_time "TEST-100" "1770000000"
    create_branch_at_time "TEST-200" "1770000000"
    create_branch_at_time "TEST-300" "1770000000"

    local wt1=$(create_worktree "TEST-100")
    local wt2=$(create_worktree "TEST-200")
    local wt3=$(create_worktree "TEST-300")

    # Backdate HEAD files so nav log controls ordering
    local gd1; gd1=$(get_worktree_gitdir "$wt1")
    local gd2; gd2=$(get_worktree_gitdir "$wt2")
    local gd3; gd3=$(get_worktree_gitdir "$wt3")
    touch -d "@1770000000" "$gd1/HEAD" "$gd2/HEAD" "$gd3/HEAD"

    # Set access times: TEST-300 most recent, TEST-100 middle, TEST-200 oldest
    create_access_log \
        1770000200 "$wt1" \
        1770000100 "$wt2" \
        1770000300 "$wt3"

    # Load preloads (simulating rr.sh startup)
    declare -gA WORKTREE_NAV_TIMES=()
    while IFS=$'\t' read -r ts path; do
        [ -n "$ts" ] && [ -n "$path" ] && WORKTREE_NAV_TIMES["$path"]="$ts"
    done < "$WORKTREE_ACCESS_LOG"

    declare -gA VALID_BRANCH_REFS=()
    while IFS= read -r ref; do
        VALID_BRANCH_REFS["$ref"]=1
    done < <(cd "$TEST_GIT_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/)

    # Build WORKTREE_MAP
    declare -gA WORKTREE_MAP=()
    WORKTREE_MAP["TEST-100"]="$wt1"
    WORKTREE_MAP["TEST-200"]="$wt2"
    WORKTREE_MAP["TEST-300"]="$wt3"

    cd "$TEST_GIT_REPO"
    local claimed_file="$TEST_TMPDIR/claimed"

    local output
    output=$(generate_instant_data "$claimed_file")

    # Extract branch order (field 7 = full branch name)
    local branch_order
    branch_order=$(echo "$output" | awk -F'\t' '{ print $7 }')

    local first=$(echo "$branch_order" | sed -n '1p')
    local second=$(echo "$branch_order" | sed -n '2p')
    local third=$(echo "$branch_order" | sed -n '3p')

    # Expected order: TEST-300 (ts=300), TEST-100 (ts=200), TEST-200 (ts=100)
    [ "$first" = "TEST-300" ]
    [ "$second" = "TEST-100" ]
    [ "$third" = "TEST-200" ]
}

@test "generate_instant_data: reflog branches included and sorted" {
    create_branch_at_time "TEST-10" "1770000000"
    create_branch_at_time "TEST-20" "1770000000"
    create_branch_at_time "TEST-30" "1770000000"

    cd "$TEST_GIT_REPO"
    git checkout -q TEST-10
    git checkout -q TEST-20
    git checkout -q TEST-30
    git checkout -q main 2>/dev/null || git checkout -q master

    # No worktrees, no access log
    declare -gA WORKTREE_NAV_TIMES=()
    declare -gA WORKTREE_MAP=()
    declare -gA VALID_BRANCH_REFS=()
    while IFS= read -r ref; do
        VALID_BRANCH_REFS["$ref"]=1
    done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

    local claimed_file="$TEST_TMPDIR/claimed"
    local output
    output=$(generate_instant_data "$claimed_file")

    # Should contain the reflog branches (excluding main/master)
    local branch_order
    branch_order=$(echo "$output" | awk -F'\t' '{ print $7 }' | grep -v '^main$' | grep -v '^master$')

    local first=$(echo "$branch_order" | sed -n '1p')
    local second=$(echo "$branch_order" | sed -n '2p')
    local third=$(echo "$branch_order" | sed -n '3p')

    # All three branches should appear (order may vary when timestamps are identical)
    local count=$(echo "$branch_order" | wc -l)
    [ "$count" -eq 3 ]
    echo "$branch_order" | grep -q "TEST-10"
    echo "$branch_order" | grep -q "TEST-20"
    echo "$branch_order" | grep -q "TEST-30"

    # Timestamps should be non-increasing (descending or equal)
    echo "$output" | extract_timestamps | {
        prev=""
        while IFS= read -r val; do
            if [ -n "$prev" ] && [ "$val" -gt "$prev" ]; then
                echo "NOT DESCENDING: $val > $prev" >&2
                exit 1
            fi
            prev="$val"
        done
    }
}

@test "generate_instant_data: worktrees and reflog branches interleaved by timestamp" {
    create_branch_at_time "TEST-WT" "1770000000"
    create_branch_at_time "TEST-REF" "1770000000"

    local wt=$(create_worktree "TEST-WT")

    # Backdate worktree HEAD
    local gd; gd=$(get_worktree_gitdir "$wt")
    touch -d "@1770000000" "$gd/HEAD"

    # Worktree access time: relatively old
    create_access_log 1770000100 "$wt"

    # Checkout reflog branch very recently
    cd "$TEST_GIT_REPO"
    git checkout -q TEST-REF
    git checkout -q main 2>/dev/null || git checkout -q master

    # Load preloads
    declare -gA WORKTREE_NAV_TIMES=()
    while IFS=$'\t' read -r ts path; do
        [ -n "$ts" ] && [ -n "$path" ] && WORKTREE_NAV_TIMES["$path"]="$ts"
    done < "$WORKTREE_ACCESS_LOG"

    declare -gA WORKTREE_MAP=()
    WORKTREE_MAP["TEST-WT"]="$wt"

    declare -gA VALID_BRANCH_REFS=()
    while IFS= read -r ref; do
        VALID_BRANCH_REFS["$ref"]=1
    done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

    local claimed_file="$TEST_TMPDIR/claimed"
    local output
    output=$(generate_instant_data "$claimed_file")

    # Extract timestamps for each entry
    local branches_with_ts
    branches_with_ts=$(echo "$output" | awk -F'\t' '{
        branch = $7
        split($5, a, ":")
        n = length(a)
        ts = (n >= 2 && a[n] ~ /^[0-9]+$/) ? a[n] : 0
        print ts "\t" branch
    }')

    # The reflog branch (TEST-REF) was checked out "just now" (much more recent than 1770000100)
    local ts_wt=$(echo "$branches_with_ts" | grep 'TEST-WT' | cut -f1)
    local ts_ref=$(echo "$branches_with_ts" | grep 'TEST-REF' | cut -f1)

    # Reflog branch should have a much higher timestamp than worktree
    [ "$ts_ref" -gt "$ts_wt" ]

    # And it should appear first in output
    local first_branch
    first_branch=$(echo "$output" | head -1 | awk -F'\t' '{ print $7 }')
    [[ "$first_branch" == "TEST-REF" || "$first_branch" == "main" || "$first_branch" == "master" ]]
}

@test "generate_instant_data: timestamps are strictly descending" {
    create_branch_at_time "TEST-A" "1770000000"
    create_branch_at_time "TEST-B" "1770000000"
    create_branch_at_time "TEST-C" "1770000000"
    create_branch_at_time "TEST-D" "1770000000"

    local wt_a=$(create_worktree "TEST-A")
    local wt_b=$(create_worktree "TEST-B")

    local gd_a; gd_a=$(get_worktree_gitdir "$wt_a")
    local gd_b; gd_b=$(get_worktree_gitdir "$wt_b")
    touch -d "@1770000000" "$gd_a/HEAD" "$gd_b/HEAD"

    create_access_log \
        1770000400 "$wt_a" \
        1770000200 "$wt_b"

    cd "$TEST_GIT_REPO"
    git checkout -q TEST-C
    git checkout -q TEST-D
    git checkout -q main 2>/dev/null || git checkout -q master

    declare -gA WORKTREE_NAV_TIMES=()
    while IFS=$'\t' read -r ts path; do
        [ -n "$ts" ] && [ -n "$path" ] && WORKTREE_NAV_TIMES["$path"]="$ts"
    done < "$WORKTREE_ACCESS_LOG"

    declare -gA WORKTREE_MAP=()
    WORKTREE_MAP["TEST-A"]="$wt_a"
    WORKTREE_MAP["TEST-B"]="$wt_b"

    declare -gA VALID_BRANCH_REFS=()
    while IFS= read -r ref; do
        VALID_BRANCH_REFS["$ref"]=1
    done < <(git for-each-ref --format='%(refname:short)' refs/heads/)

    local claimed_file="$TEST_TMPDIR/claimed"
    local output
    output=$(generate_instant_data "$claimed_file")

    # Extract timestamps and verify descending order
    echo "$output" | extract_timestamps | assert_descending_order
}

@test "generate_instant_data: TSV fields are not shifted by empty values" {
    # Regression test: IFS=$'\t' read collapses consecutive empty tabs,
    # causing field misalignment. Phase 1 must use space placeholders.
    create_branch_at_time "TEST-FLD" "1770000000"
    local wt=$(create_worktree "TEST-FLD")

    # Set a nav timestamp so the worktree is included (ts>0 required)
    create_access_log 1770000500 "$wt"

    declare -gA WORKTREE_NAV_TIMES=()
    while IFS=$'\t' read -r ts path; do
        [ -n "$ts" ] && [ -n "$path" ] && WORKTREE_NAV_TIMES["$path"]="$ts"
    done < "$WORKTREE_ACCESS_LOG"

    declare -gA WORKTREE_MAP=()
    WORKTREE_MAP["TEST-FLD"]="$wt"

    declare -gA VALID_BRANCH_REFS=()
    while IFS= read -r ref; do
        VALID_BRANCH_REFS["$ref"]=1
    done < <(cd "$TEST_GIT_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/)

    cd "$TEST_GIT_REPO"
    local claimed_file="$TEST_TMPDIR/claimed"
    local output
    output=$(generate_instant_data "$claimed_file")

    # Parse the TSV output the same way the format loop does
    local full_branch="" assignee="" wt_indicator=""
    echo "$output" | while IFS=$'\t' read -r _branch _title _status _author _time_info _commit_info full_branch assignee wt_indicator wt_path wt_status; do
        # full_branch (field 7) must be the branch name, not a path or "<UNASSIGNED>"
        if [ "$full_branch" = "TEST-FLD" ]; then
            # wt_indicator (field 9) must be "WT", not something else
            [ "$wt_indicator" = "WT" ] || { echo "wt_indicator=[$wt_indicator] expected [WT]" >&2; exit 1; }
            # wt_path (field 10) must start with / (a path)
            [[ "$wt_path" == /* ]] || { echo "wt_path=[$wt_path] expected a path" >&2; exit 1; }
            exit 0
        fi
    done
    # If we get here without finding the branch, fail
    echo "$output" | grep -q "TEST-FLD"
}

@test "compute_worktree_timestamp: returns 0 when path is unreadable" {
    # Verifies the ts=0 guard condition: no nav log + unreadable .git = ts=0
    setup_git_repo
    create_branch_at_time "TEST-GHOST" "1770000000"
    local wt=$(create_worktree "TEST-GHOST")

    # Remove .git file so HEAD lookup fails
    rm -f "$wt/.git"

    # No nav log entry
    declare -gA WORKTREE_NAV_TIMES=()

    local ts
    ts=$(compute_worktree_timestamp "$wt")
    [ "$ts" -eq 0 ]

    teardown_temp_dir
}

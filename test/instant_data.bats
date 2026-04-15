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
    declare -gA AUTO_WORKTREES=()

    # Define get_eponymous_branch (called by generate_instant_data, defined in rr.sh)
    get_eponymous_branch() {
        get_eponymous_branch_pure "$@"
    }
    export -f get_eponymous_branch

    # Define resolve_current_branch (called by generate_instant_data, defined in rr.sh)
    eval "$(sed -n '/^resolve_current_branch()/,/^}/p' "$repo_root/bin/rr.sh")"

    # WORKTREE_BRANCH: authoritative worktree path -> actual branch map
    # (populated by build_worktree_map in rr.sh; tests populate it per-test)
    declare -gA WORKTREE_BRANCH=()

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

    # Build WORKTREE_MAP and WORKTREE_BRANCH
    declare -gA WORKTREE_MAP=()
    WORKTREE_MAP["TEST-100"]="$wt1"
    WORKTREE_MAP["TEST-200"]="$wt2"
    WORKTREE_MAP["TEST-300"]="$wt3"
    WORKTREE_BRANCH["$wt1"]="TEST-100"
    WORKTREE_BRANCH["$wt2"]="TEST-200"
    WORKTREE_BRANCH["$wt3"]="TEST-300"

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
    WORKTREE_BRANCH["$wt"]="TEST-WT"

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
    WORKTREE_BRANCH["$wt_a"]="TEST-A"
    WORKTREE_BRANCH["$wt_b"]="TEST-B"

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
    WORKTREE_BRANCH["$wt"]="TEST-FLD"

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

@test "generate_instant_data: title-suffixed worktree uses actual branch name" {
    # Regression test: when worktree dir is "repo.UB-123-fix-the-widget" but
    # the branch is "UB-123", display and field7 must show "UB-123", not the
    # directory-derived eponymous name "UB-123-fix-the-widget".
    create_branch_at_time "TEST-500" "1770000000"
    local wt=$(create_worktree_with_title "TEST-500" "fix-the-widget")

    create_access_log 1770000500 "$wt"

    declare -gA WORKTREE_NAV_TIMES=()
    while IFS=$'\t' read -r ts path; do
        [ -n "$ts" ] && [ -n "$path" ] && WORKTREE_NAV_TIMES["$path"]="$ts"
    done < "$WORKTREE_ACCESS_LOG"

    declare -gA WORKTREE_MAP=()
    WORKTREE_MAP["TEST-500"]="$wt"
    # Eponymous key also mapped (as build_worktree_map does)
    WORKTREE_MAP["TEST-500-fix-the-widget"]="$wt"
    WORKTREE_BRANCH["$wt"]="TEST-500"

    declare -gA VALID_BRANCH_REFS=()
    while IFS= read -r ref; do
        VALID_BRANCH_REFS["$ref"]=1
    done < <(cd "$TEST_GIT_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/)

    cd "$TEST_GIT_REPO"
    local claimed_file="$TEST_TMPDIR/claimed"
    local output
    output=$(generate_instant_data "$claimed_file")

    # Field 7 (full branch name) must be the actual branch, not the directory name
    local field7_values
    field7_values=$(echo "$output" | awk -F'\t' '{ print $7 }')
    echo "$field7_values" | grep -q "TEST-500"

    # Must NOT contain the eponymous directory-derived name as a separate entry
    local count
    count=$(echo "$field7_values" | grep -c "TEST-500" || true)
    [ "$count" -eq 1 ]

    # The directory-derived name should not appear in field 7
    ! echo "$field7_values" | grep -q "TEST-500-fix-the-widget"
}

@test "generate_instant_data: title-suffixed worktree claims actual branch to prevent duplicates" {
    # Regression test: a worktree at "repo.TEST-600-some-title" with branch
    # "TEST-600" must claim "TEST-600" so generate_branch_data doesn't emit
    # a duplicate row for it.
    create_branch_at_time "TEST-600" "1770000000"
    local wt=$(create_worktree_with_title "TEST-600" "some-title")

    create_access_log 1770000600 "$wt"

    declare -gA WORKTREE_NAV_TIMES=()
    while IFS=$'\t' read -r ts path; do
        [ -n "$ts" ] && [ -n "$path" ] && WORKTREE_NAV_TIMES["$path"]="$ts"
    done < "$WORKTREE_ACCESS_LOG"

    declare -gA WORKTREE_MAP=()
    WORKTREE_MAP["TEST-600"]="$wt"
    WORKTREE_MAP["TEST-600-some-title"]="$wt"
    WORKTREE_BRANCH["$wt"]="TEST-600"

    declare -gA VALID_BRANCH_REFS=()
    while IFS= read -r ref; do
        VALID_BRANCH_REFS["$ref"]=1
    done < <(cd "$TEST_GIT_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/)

    cd "$TEST_GIT_REPO"
    local claimed_file="$TEST_TMPDIR/claimed"
    generate_instant_data "$claimed_file" > /dev/null

    # The claimed file must contain the actual branch name
    grep -q "TEST-600" "$claimed_file"
}

@test "generate_instant_data: main branch (GIT_ROOT) uses nav log timestamp" {
    # Regression test: main's worktree is GIT_ROOT. When the user navigates to
    # main via rr, record_worktree_access writes to the nav log. Phase 1 must
    # use that nav log timestamp (not just the reflog) so main's "checked" time
    # updates on each rr navigation.
    create_branch_at_time "TEST-700" "1770000000"
    create_branch_at_time "TEST-701" "1770000000"
    local wt=$(create_worktree "TEST-700")

    # Backdate ALL HEAD files so nav log controls ordering
    local gd; gd=$(get_worktree_gitdir "$wt")
    touch -d "@1770000000" "$gd/HEAD"
    touch -d "@1770000000" "$GIT_ROOT/.git/HEAD"

    # Give TEST-700 a recent nav time, but give main an even more recent one
    create_access_log \
        1770000100 "$wt" \
        1770000500 "$GIT_ROOT"

    declare -gA WORKTREE_NAV_TIMES=()
    while IFS=$'\t' read -r ts path; do
        [ -n "$ts" ] && [ -n "$path" ] && WORKTREE_NAV_TIMES["$path"]="$ts"
    done < "$WORKTREE_ACCESS_LOG"

    declare -gA WORKTREE_MAP=()
    WORKTREE_MAP["main"]="$GIT_ROOT"
    WORKTREE_MAP["TEST-700"]="$wt"
    WORKTREE_BRANCH["$GIT_ROOT"]="main"
    WORKTREE_BRANCH["$wt"]="TEST-700"

    declare -gA VALID_BRANCH_REFS=()
    while IFS= read -r ref; do
        VALID_BRANCH_REFS["$ref"]=1
    done < <(cd "$TEST_GIT_REPO" && git for-each-ref --format='%(refname:short)' refs/heads/)

    # We're on main (from create_branch_at_time teardown) but need to not be.
    # Can't checkout TEST-700 (it has a worktree), so use detached HEAD.
    cd "$TEST_GIT_REPO"
    git checkout -q --detach HEAD
    # Re-backdate HEAD after checkout (checkout touches it)
    touch -d "@1770000000" "$GIT_ROOT/.git/HEAD"
    # cd away from GIT_ROOT to avoid PWD boost
    cd "$TEST_TMPDIR"

    local claimed_file="$TEST_TMPDIR/claimed"
    local output
    output=$(generate_instant_data "$claimed_file" 2>/dev/null)

    # main should appear and sort BEFORE TEST-700 (nav time 500 > 100)
    local branches
    branches=$(echo "$output" | awk -F'\t' '{ print $7 }')
    echo "$branches" | grep -q "main"

    local main_line test700_line
    main_line=$(echo "$branches" | grep -n "^main$" | head -1 | cut -d: -f1)
    test700_line=$(echo "$branches" | grep -n "^TEST-700$" | head -1 | cut -d: -f1)
    [ "$main_line" -lt "$test700_line" ]

    # Verify main's timestamp comes from nav log (1770000500)
    local main_ts
    main_ts=$(echo "$output" | grep "main" | awk -F'\t' '{ split($5, a, ":"); print a[2] }')
    [ "$main_ts" = "1770000500" ]

    # --- Simulate navigating to main again (record_worktree_access updates nav log) ---
    # Inline what record_worktree_access does: update the access log with current time
    local new_ts
    new_ts=$(date +%s)
    grep -v "	$GIT_ROOT$" "$WORKTREE_ACCESS_LOG" > "$WORKTREE_ACCESS_LOG.tmp" 2>/dev/null || true
    printf '%s\t%s\n' "$new_ts" "$GIT_ROOT" >> "$WORKTREE_ACCESS_LOG.tmp"
    mv "$WORKTREE_ACCESS_LOG.tmp" "$WORKTREE_ACCESS_LOG"
    # Re-backdate HEAD so nav log stays in control
    touch -d "@1770000000" "$GIT_ROOT/.git/HEAD"

    # Reload nav times (as rr.sh does on startup)
    declare -gA WORKTREE_NAV_TIMES=()
    while IFS=$'\t' read -r ts path; do
        [ -n "$ts" ] && [ -n "$path" ] && WORKTREE_NAV_TIMES["$path"]="$ts"
    done < "$WORKTREE_ACCESS_LOG"

    local output2
    output2=$(generate_instant_data "$TEST_TMPDIR/claimed2" 2>/dev/null)

    # main's timestamp must have increased (record_worktree_access wrote "now")
    local main_ts2
    main_ts2=$(echo "$output2" | grep "main" | awk -F'\t' '{ split($5, a, ":"); print a[2] }')
    [ "$main_ts2" -gt "$main_ts" ]
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

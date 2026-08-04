#!/usr/bin/env bats

load test_helper/common

# --- truncate_str ---

@test "truncate_str: short string unchanged" {
    result=$(truncate_str "hello" 10)
    [ "$result" = "hello" ]
}

@test "truncate_str: exact length unchanged" {
    result=$(truncate_str "hello" 5)
    [ "$result" = "hello" ]
}

@test "truncate_str: long string gets ellipsis" {
    result=$(truncate_str "hello world" 8)
    [ "$result" = "hello..." ]
}

@test "truncate_str: very short max" {
    result=$(truncate_str "abcdef" 4)
    [ "$result" = "a..." ]
}

# --- get_eponymous_branch_pure ---

@test "eponymous branch: dot prefix extracts suffix" {
    result=$(get_eponymous_branch_pure "/path/to/ul.UB-6506")
    [ "$result" = "UB-6506" ]
}

@test "eponymous branch: no dot returns basename" {
    result=$(get_eponymous_branch_pure "/path/to/my-feature")
    [ "$result" = "my-feature" ]
}

@test "eponymous branch: multiple dots extracts last segment" {
    result=$(get_eponymous_branch_pure "/path/to/repo.sub.UB-1234")
    [ "$result" = "UB-1234" ]
}

# --- compute_sort_key ---

@test "compute_sort_key: checked timestamp" {
    result=$(compute_sort_key "checked:1770827880")
    [ "$result" = "1770827880" ]
}

@test "compute_sort_key: updated timestamp" {
    result=$(compute_sort_key "updated:1770000300")
    [ "$result" = "1770000300" ]
}

@test "compute_sort_key: empty string returns 0" {
    result=$(compute_sort_key "")
    [ "$result" = "0" ]
}

@test "compute_sort_key: non-numeric returns 0" {
    result=$(compute_sort_key "invalid")
    [ "$result" = "0" ]
}

# --- compute_worktree_timestamp ---

@test "compute_worktree_timestamp: uses nav log time" {
    setup_git_repo
    local wt_path="$TEST_TMPDIR/repo.WK-1"
    create_branch_at_time "WK-1" "1770000000"
    create_worktree "WK-1" "$wt_path"
    create_access_log 1770000300 "$wt_path"
    load_nav_times

    # get_worktree_gitdir must be available (from rr-core.sh or define stub)
    source "$REPO_ROOT/lib/rr-core.sh"

    # Need get_worktree_gitdir — it's in rr.sh, also extracted to rr-core.sh? No, define stub here
    get_worktree_gitdir() {
        local wt_path="$1"
        if [ -f "$wt_path/.git" ]; then
            grep '^gitdir:' "$wt_path/.git" 2>/dev/null | cut -d' ' -f2
        elif [ -d "$wt_path/.git" ]; then
            echo "$wt_path/.git"
        fi
    }
    export -f get_worktree_gitdir

    result=$(compute_worktree_timestamp "$wt_path")
    # Nav log time (1770000300) should be >= what we get, but HEAD mtime
    # might be newer since we just created the worktree. At minimum, result >= nav_time.
    [ "$result" -ge 1770000300 ]

    teardown_temp_dir
}

@test "compute_worktree_timestamp: PWD match returns now" {
    setup_git_repo
    local wt_path="$TEST_TMPDIR/repo.WK-2"
    create_branch_at_time "WK-2" "1770000000"
    create_worktree "WK-2" "$wt_path"
    create_access_log 1770000100 "$wt_path"
    load_nav_times

    get_worktree_gitdir() {
        local wt_path="$1"
        if [ -f "$wt_path/.git" ]; then
            grep '^gitdir:' "$wt_path/.git" 2>/dev/null | cut -d' ' -f2
        elif [ -d "$wt_path/.git" ]; then
            echo "$wt_path/.git"
        fi
    }
    export -f get_worktree_gitdir

    local before=$(date +%s)
    # Use PWD override since bats restricts cd
    PWD="$wt_path" result=$(compute_worktree_timestamp "$wt_path")
    local after=$(date +%s)

    # Should be approximately "now"
    [ "$result" -ge "$before" ]
    [ "$result" -le "$after" ]

    teardown_temp_dir
}

# --- parse_reflog_branches ---

@test "parse_reflog_branches: returns branches in checkout order" {
    setup_git_repo
    create_branch_at_time "branch-A" "1770000000"
    create_branch_at_time "branch-B" "1770000000"
    create_branch_at_time "branch-C" "1770000000"

    # Simulate checkouts: A first, then B, then C (C is most recent)
    cd "$TEST_GIT_REPO"
    git checkout -q branch-A
    git checkout -q branch-B
    git checkout -q branch-C
    git checkout -q main 2>/dev/null || git checkout -q master

    # parse_reflog_branches returns most recent first (reflog order)
    result=$(parse_reflog_branches "" 200)
    first_branch=$(echo "$result" | head -1 | cut -f1)

    # Most recent checkout target before "main" was branch-C,
    # but the reflog shows "moving to main" as most recent.
    # The second entry should be branch-C
    main_or_master=$(echo "$result" | head -1 | cut -f1)
    second_branch=$(echo "$result" | sed -n '2p' | cut -f1)

    [[ "$main_or_master" == "main" || "$main_or_master" == "master" ]]
    [ "$second_branch" = "branch-C" ]

    teardown_temp_dir
}

# --- worktree_colour_key / render_wt_indicator ---
#
# The ⊙ badge is a filled block in the worktree's own colour, and the block runs across the
# branch name as well, so the cell reads as one segment the way a p10k prompt does. Two
# things about it are load-bearing rather than cosmetic:
#
#   * the colour must be the one the p10k prompt segment and fzedit give the same
#     checkout, which means the same key and the same palette (lib/worktree-colour.sh);
#   * the badge must stay EXACTLY 4 visual columns, because rr aligns the whole table by
#     hand against that number and one extra column shears every row below it.

setup_wt_for_badge() {
    setup_git_repo
    cd "$TEST_GIT_REPO"
    echo x > f.txt
    git add f.txt
    git -c user.email=t@t -c user.name=t commit -q -m init
    git branch TEST-1
    WT="$TEST_TMPDIR/repo.TEST-1"
    git worktree add -q "$WT" TEST-1
}

visual_len() { printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g' | wc -m; }

@test "worktree_colour_key: git's own name for a linked worktree" {
    setup_wt_for_badge
    run worktree_colour_key "$WT"
    [ "$status" -eq 0 ]
    worktree_colour_key "$WT"
    [ "$WTC_KEY" = "repo.TEST-1" ]
    teardown_temp_dir
}

# The primary checkout has a .git DIRECTORY and no name under worktrees/, so it has no key
# and therefore no colour — which is what makes "no block" mean "you are on main".
@test "worktree_colour_key: nothing for the primary checkout" {
    setup_wt_for_badge
    worktree_colour_key "$TEST_GIT_REPO"
    [ -z "$WTC_KEY" ]
    teardown_temp_dir
}

@test "render_wt_indicator: a filled block in the worktree's own colour" {
    setup_wt_for_badge
    worktree_colour_key "$WT"
    wtc_colour "$WTC_KEY"
    want="$WTC_COLOUR"
    [ -n "$want" ]

    render_wt_indicator "$WT" "" ""
    [[ "$WT_INDICATOR_DISPLAY" == *$'\033'"[48;5;${want}m"$'\033'"[30m"* ]] \
        || { echo "badge: $WT_INDICATOR_DISPLAY"; return 1; }
    # and the same block is handed back for the branch name, so the cell is one segment
    [ "$WT_BRANCH_SGR" = $'\033'"[48;5;${want}m"$'\033'"[30m" ]
    teardown_temp_dir
}

@test "render_wt_indicator: the primary checkout gets no block and no branch tint" {
    setup_wt_for_badge
    render_wt_indicator "$TEST_GIT_REPO" "" ""
    [[ "$WT_INDICATOR_DISPLAY" != *"48;5;"* ]] || { echo "badge: $WT_INDICATOR_DISPLAY"; return 1; }
    [ -z "$WT_BRANCH_SGR" ]
    teardown_temp_dir
}

@test "render_wt_indicator: still exactly 4 visual columns in every state" {
    setup_wt_for_badge
    for args in ":" ":dirty" "other-branch:"; do
        mismatch="${args%%:*}"; dirty="${args#*:}"
        [ "$mismatch" = ":" ] && mismatch=""
        render_wt_indicator "$WT" "$mismatch" "$dirty"
        n=$(visual_len "$WT_INDICATOR_DISPLAY")
        [ "$n" -eq 4 ] || { echo "[$args] width $n: $WT_INDICATOR_DISPLAY"; return 1; }
        # and the primary's flat fallback has to match it column for column
        render_wt_indicator "$TEST_GIT_REPO" "$mismatch" "$dirty"
        n=$(visual_len "$WT_INDICATOR_DISPLAY")
        [ "$n" -eq 4 ] || { echo "[$args primary] width $n: $WT_INDICATOR_DISPLAY"; return 1; }
    done
    teardown_temp_dir
}

@test "render_wt_indicator: dirty flags itself, a displaced branch says so" {
    setup_wt_for_badge
    render_wt_indicator "$WT" "" dirty
    [[ "$WT_INDICATOR_DISPLAY" == *"!"* ]]
    render_wt_indicator "$WT" other-branch ""
    [[ "$WT_INDICATOR_DISPLAY" == *"⊙≠"* ]]
    teardown_temp_dir
}

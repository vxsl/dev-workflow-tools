#!/usr/bin/env bats
# Tests for ticket-bot auto-worktree demotion:
#   - load_auto_worktrees reads ticket-solve state files and populates the
#     AUTO_WORKTREES set only for slack_context=true entries.
#   - is_worktree_demoted correctly combines AUTO_WORKTREES + WORKTREE_NAV_TIMES.
#   - generate_worktree_data routes demoted rows into AUTO_WORKTREE_ROWS
#     (bottom-tier stream) instead of the sorted _collected_rows output.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_git_repo

    export JIRA_PROJECT="TEST"
    export TICKET_SOLVE_STATE_DIR="$TEST_TMPDIR/state"
    mkdir -p "$TICKET_SOLVE_STATE_DIR"

    # Pull in the helpers defined in rr.sh
    eval "$(sed -n '/^load_auto_worktrees()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    eval "$(sed -n '/^is_worktree_demoted()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"

    declare -gA AUTO_WORKTREES=()
    declare -gA WORKTREE_NAV_TIMES=()
}

teardown() {
    teardown_temp_dir
}

write_state() {
    local name="$1" worktree="$2" slack_context="$3"
    cat > "$TICKET_SOLVE_STATE_DIR/${name}.json" <<EOF
{
  "ticket": "${name}",
  "worktree": "${worktree}",
  "slack_context": ${slack_context}
}
EOF
}

# --- load_auto_worktrees ---

@test "load_auto_worktrees: picks up slack_context=true worktrees" {
    local wt="$TEST_TMPDIR/repo.slack-123"
    mkdir -p "$wt"
    write_state "hotfix_foo" "$wt" true

    load_auto_worktrees

    [ "${AUTO_WORKTREES[$wt]}" = "1" ]
}

@test "load_auto_worktrees: ignores slack_context=false worktrees" {
    local wt="$TEST_TMPDIR/repo.TEST-42"
    mkdir -p "$wt"
    write_state "TEST-42" "$wt" false

    load_auto_worktrees

    [ -z "${AUTO_WORKTREES[$wt]:-}" ]
}

@test "load_auto_worktrees: skips state files whose worktree directory is gone" {
    local wt="$TEST_TMPDIR/repo.missing"
    # Intentionally no mkdir
    write_state "hotfix_gone" "$wt" true

    load_auto_worktrees

    [ -z "${AUTO_WORKTREES[$wt]:-}" ]
}

@test "load_auto_worktrees: no-op when state dir does not exist" {
    rm -rf "$TICKET_SOLVE_STATE_DIR"

    run load_auto_worktrees
    [ "$status" -eq 0 ]
    [ "${#AUTO_WORKTREES[@]}" -eq 0 ]
}

# --- is_worktree_demoted ---

@test "is_worktree_demoted: auto + no nav → demoted" {
    local wt="/tmp/fake/wt"
    AUTO_WORKTREES["$wt"]=1

    run is_worktree_demoted "$wt"
    [ "$status" -eq 0 ]
}

@test "is_worktree_demoted: auto + nav → NOT demoted" {
    local wt="/tmp/fake/wt"
    AUTO_WORKTREES["$wt"]=1
    WORKTREE_NAV_TIMES["$wt"]="1770000000"

    run is_worktree_demoted "$wt"
    [ "$status" -ne 0 ]
}

@test "is_worktree_demoted: non-auto → NOT demoted" {
    local wt="/tmp/fake/wt"

    run is_worktree_demoted "$wt"
    [ "$status" -ne 0 ]
}

# --- generate_worktree_data routing ---

@test "generate_worktree_data: demoted row goes to AUTO_WORKTREE_ROWS not stdout" {
    # Prepare two branches + worktrees: TEST-10 is a normal ticket worktree,
    # hotfix/slack-flow is the auto (demoted) one.
    create_branch_at_time "TEST-10" "1770000000"
    cd "$TEST_GIT_REPO"
    git checkout -q -b "hotfix/slack-flow"
    git commit -q --allow-empty -m "hotfix seed"
    git checkout -q main

    local wt_normal="$TEST_TMPDIR/repo.TEST-10"
    local wt_auto="$TEST_TMPDIR/repo.slack-123"
    git -C "$TEST_GIT_REPO" worktree add -q "$wt_normal" "TEST-10"
    git -C "$TEST_GIT_REPO" worktree add -q "$wt_auto" "hotfix/slack-flow"

    # Mark the auto worktree via state file
    write_state "hotfix_slack-flow" "$wt_auto" true

    # Shared globals expected by generate_worktree_data
    export GIT_ROOT="$TEST_GIT_REPO"
    export BRANCH_MAX_LENGTH=40
    declare -gA JIRA_TITLE_CACHE=()
    declare -gA JIRA_STATUS_CACHE=()
    declare -gA JIRA_ASSIGNEE_CACHE=()
    declare -ga DISPLACED_BRANCHES=()
    AUTO_WT_ROWS_FILE="$TEST_TMPDIR/auto_rows"
    : > "$AUTO_WT_ROWS_FILE"
    export AUTO_WT_ROWS_FILE

    # Helpers required by generate_worktree_data
    eval "$(sed -n '/^get_eponymous_branch()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    eval "$(sed -n '/^get_worktree_path()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    eval "$(sed -n '/^get_worktree_navigation_time()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    truncate() {
        local s=$1 m=$2
        if [ ${#s} -gt $m ]; then echo "${s:0:$((m-3))}..."; else echo "$s"; fi
    }
    export -f truncate

    # Populate AUTO_WORKTREES from the state file we just wrote
    load_auto_worktrees

    # Extract + run generate_worktree_data
    eval "$(sed -n '/^generate_worktree_data()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"

    local stdout_rows
    stdout_rows=$(generate_worktree_data "" 2>/dev/null)

    # Normal worktree emitted to stdout; auto worktree routed to AUTO_WT_ROWS_FILE
    echo "$stdout_rows" | grep -q "TEST-10"
    ! echo "$stdout_rows" | grep -q "hotfix/slack-flow"

    grep -q "hotfix/slack-flow" "$AUTO_WT_ROWS_FILE"
    # Demoted row carries the WT_AUTO indicator (field 9)
    awk -F'\t' '$9 == "WT_AUTO"' "$AUTO_WT_ROWS_FILE" | grep -q "hotfix/slack-flow"
}

@test "generate_worktree_data: nav-log entry promotes auto worktree back to normal stream" {
    cd "$TEST_GIT_REPO"
    git checkout -q -b "hotfix/slack-flow"
    git commit -q --allow-empty -m "hotfix seed"
    git checkout -q main

    local wt_auto="$TEST_TMPDIR/repo.slack-123"
    git -C "$TEST_GIT_REPO" worktree add -q "$wt_auto" "hotfix/slack-flow"

    write_state "hotfix_slack-flow" "$wt_auto" true

    # User has navigated via rr → nav log entry present
    WORKTREE_NAV_TIMES["$wt_auto"]="1770000500"

    export GIT_ROOT="$TEST_GIT_REPO"
    export BRANCH_MAX_LENGTH=40
    declare -gA JIRA_TITLE_CACHE=()
    declare -gA JIRA_STATUS_CACHE=()
    declare -gA JIRA_ASSIGNEE_CACHE=()
    declare -ga DISPLACED_BRANCHES=()
    AUTO_WT_ROWS_FILE="$TEST_TMPDIR/auto_rows"
    : > "$AUTO_WT_ROWS_FILE"
    export AUTO_WT_ROWS_FILE

    eval "$(sed -n '/^get_eponymous_branch()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    eval "$(sed -n '/^get_worktree_path()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    eval "$(sed -n '/^get_worktree_navigation_time()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    truncate() {
        local s=$1 m=$2
        if [ ${#s} -gt $m ]; then echo "${s:0:$((m-3))}..."; else echo "$s"; fi
    }
    export -f truncate

    load_auto_worktrees

    eval "$(sed -n '/^generate_worktree_data()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    local stdout_rows
    stdout_rows=$(generate_worktree_data "" 2>/dev/null)

    # Should appear in the normal stream, not the auto bucket
    echo "$stdout_rows" | grep -q "hotfix/slack-flow"
    ! grep -q "hotfix/slack-flow" "$AUTO_WT_ROWS_FILE" 2>/dev/null
}

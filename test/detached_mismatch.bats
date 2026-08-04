#!/usr/bin/env bats
# Tests for detached_mismatch_skip_reason — the worktree-mismatch prompt is
# skipped when a worktree's detached HEAD is transient state (mid-rebase of the
# expected branch, or parked on an ancestor commit) rather than a real mismatch.

load test_helper/common

teardown() {
    teardown_temp_dir
}

# Repo with content commits so rebases can conflict:
#   main:     add file -> main change
#   TEST-100: add file -> branch change   (worktree at WT_PATH)
setup_conflicting_branches() {
    setup_git_repo
    cd "$TEST_GIT_REPO"
    echo base > file.txt
    git add file.txt
    git commit -q -m "add file"

    git checkout -q -b TEST-100
    echo branch-change > file.txt
    git commit -qam "branch change"

    git checkout -q main
    echo main-change > file.txt
    git commit -qam "main change"

    WT_PATH="$TEST_TMPDIR/repo.TEST-100"
    git worktree add -q "$WT_PATH" TEST-100
}

@test "skip (rebase): worktree mid-rebase of the expected branch" {
    setup_conflicting_branches

    # Rebase conflicts and stops, leaving the worktree mid-rebase
    run git -C "$WT_PATH" rebase main
    [ "$status" -ne 0 ]
    [ "$(git -C "$WT_PATH" rev-parse --abbrev-ref HEAD)" = "HEAD" ]

    run detached_mismatch_skip_reason "$WT_PATH" "TEST-100"
    [ "$status" -eq 0 ]
    [ "$output" = "rebase" ]
}

@test "no skip: worktree mid-rebase of a DIFFERENT branch" {
    setup_conflicting_branches

    # Put a different branch in TEST-100's worktree and leave it mid-rebase
    cd "$TEST_GIT_REPO"
    git checkout -q -b other main~1
    echo other-change > file.txt
    git commit -qam "other change"
    git checkout -q main
    git -C "$WT_PATH" checkout -q other
    run git -C "$WT_PATH" rebase main
    [ "$status" -ne 0 ]

    run detached_mismatch_skip_reason "$WT_PATH" "TEST-100"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "skip (ancestor): detached at an ancestor commit of the expected branch" {
    setup_conflicting_branches
    git -C "$WT_PATH" commit -q --allow-empty -m "tip commit"
    git -C "$WT_PATH" checkout -q --detach HEAD~1

    run detached_mismatch_skip_reason "$WT_PATH" "TEST-100"
    [ "$status" -eq 0 ]
    [ "$output" = "ancestor" ]
}

@test "skip (ancestor): detached at the branch tip itself" {
    setup_conflicting_branches
    git -C "$WT_PATH" checkout -q --detach

    run detached_mismatch_skip_reason "$WT_PATH" "TEST-100"
    [ "$status" -eq 0 ]
    [ "$output" = "ancestor" ]
}

@test "no skip: detached at a commit NOT in the expected branch's history" {
    setup_conflicting_branches
    # main's tip ("main change") is not an ancestor of TEST-100
    git -C "$WT_PATH" checkout -q --detach main

    run detached_mismatch_skip_reason "$WT_PATH" "TEST-100"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "no skip: expected branch does not exist" {
    setup_conflicting_branches
    git -C "$WT_PATH" checkout -q --detach

    run detached_mismatch_skip_reason "$WT_PATH" "NOPE-999"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# --------------------------------------------------------------------------
# The branch git parks mid-rebase
# --------------------------------------------------------------------------
#
# `git worktree list --porcelain` calls a rebasing worktree `detached` with no branch line
# — HEAD genuinely is a bare sha. Everything downstream then guesses a branch from the
# directory name, and the guess is wrong in two common shapes: the directory abbreviates
# the branch (repo.UB-6709 for UB-6709-add-thing), or the branch is namespaced and the
# directory is nested (repo.hotfix/fix-x for hotfix/fix-x, whose basename has lost the
# "hotfix/" entirely). Both showed up as a worktree-mismatch prompt reporting `Actual
# HEAD` — evidence about a branch nobody has ever checked out on purpose.

# The regression that made all of it reachable: rebase state lives in the worktree's own
# gitdir, and `$wt/.git` is a FILE in a linked worktree. The old lookup tested
# `$wt/.git/rebase-merge/head-name`, which cannot exist for any worktree but the primary.
@test "worktree_parked_branch finds the branch inside a LINKED worktree" {
    setup_conflicting_branches
    [ -f "$WT_PATH/.git" ]   # a file, not a directory — the whole point
    run git -C "$WT_PATH" rebase main
    [ "$status" -ne 0 ]

    run worktree_parked_branch "$WT_PATH"
    [ "$status" -eq 0 ]
    [ "$output" = "TEST-100" ]
}

@test "worktree_parked_branch says nothing when no rebase is in flight" {
    setup_conflicting_branches
    run worktree_parked_branch "$WT_PATH"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# create-wt names a worktree after the ticket while the branch keeps its full name, so the
# two agree only by prefix. Comparing exactly meant the alarm fired against the very
# branch being rebased.
@test "skip (rebase): the directory name abbreviates the branch being rebased" {
    setup_conflicting_branches
    cd "$TEST_GIT_REPO"
    git branch -m TEST-100 TEST-100-add-the-thing
    run git -C "$WT_PATH" rebase main
    [ "$status" -ne 0 ]

    # the row hands us the directory-derived "TEST-100"; the parked branch is longer
    run detached_mismatch_skip_reason "$WT_PATH" "TEST-100"
    [ "$status" -eq 0 ]
    [ "$output" = "rebase" ]
}

# A namespaced branch is named by path: hotfix/fix-x lives at repo.hotfix/fix-x, so the
# basename is "fix-x" and no prefix rule can reconcile it with "hotfix/fix-x". The path
# can, and only when the name we were handed is that basename.
@test "skip (rebase): a nested worktree named after the namespaced branch it is rebasing" {
    setup_conflicting_branches
    cd "$TEST_GIT_REPO"
    git checkout -q -b hotfix/fix-x main~1
    echo hotfix-change > file.txt
    git commit -qam "hotfix change"
    git checkout -q main
    local nested="$TEST_TMPDIR/repo.hotfix/fix-x"
    git worktree add -q "$nested" hotfix/fix-x
    run git -C "$nested" rebase main
    [ "$status" -ne 0 ]

    run detached_mismatch_skip_reason "$nested" "hotfix/fix-x"
    [ "$status" -eq 0 ]
    [ "$output" = "rebase" ]

    # and by the basename-derived alias, which is what a worktree row used to carry
    run detached_mismatch_skip_reason "$nested" "fix-x"
    [ "$status" -eq 0 ]
    [ "$output" = "rebase" ]
}

# The path escape hatch above must not swallow the real question. Being handed some other
# name that resolved to this worktree — a displaced ticket id, say — and finding it busy
# rebasing something else is exactly what the prompt is for.
# build_worktree_map lives in rr.sh; pull it into this shell the way the displaced-branch
# suite does. Worth testing here rather than through the whole picker: the map is what
# get_worktree_path answers from, so a worktree missing from it is one rr believes does not
# exist — and it offers to create a second one.
load_build_worktree_map() {
    local rr
    rr="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/bin/rr.sh"
    eval "$(sed -n '/^get_eponymous_branch()/,/^}/p' "$rr")"
    declare -gA WORKTREE_MAP=() WORKTREE_BRANCH=()
    declare -ga DISPLACED_BRANCHES=()
    eval "$(sed -n '/^build_worktree_map()/,/^}/p' "$rr")"
}

# Asserted on the REAL branch, not the directory-derived one: the old lookup fell through
# to the directory name, which is right often enough to hide the bug and wrong exactly when
# it matters. Here the branch is longer than the directory, so a fallback cannot fake it.
@test "build_worktree_map still finds the branch of a worktree that is mid-rebase" {
    setup_conflicting_branches
    cd "$TEST_GIT_REPO"
    git branch -m TEST-100 TEST-100-add-the-thing
    run git -C "$WT_PATH" rebase main
    [ "$status" -ne 0 ]

    cd "$TEST_GIT_REPO"
    export GIT_ROOT="$TEST_GIT_REPO" JIRA_PROJECT_REGEX="TEST"
    load_build_worktree_map
    build_worktree_map

    [ "${WORKTREE_BRANCH[$WT_PATH]}" = "TEST-100-add-the-thing" ] \
        || { echo "branch: ${WORKTREE_BRANCH[$WT_PATH]:-<none>}"; return 1; }
    [ "${WORKTREE_MAP[TEST-100-add-the-thing]}" = "$WT_PATH" ] \
        || { echo "unmapped under its real branch"; return 1; }
    # and the directory-derived alias keeps working, since that is what rows carry
    [ "${WORKTREE_MAP[TEST-100]}" = "$WT_PATH" ]
}

# The other half of the same recovery: the row rr shows you, and whose branch field is what
# gets handed to the mismatch check when you pick it. Same harness the displaced-branch
# suite uses for this function.
load_worktree_data_functions() {
    local rr
    rr="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/bin/rr.sh"
    eval "$(sed -n '/^get_eponymous_branch()/,/^}/p' "$rr")"
    eval "$(sed -n '/^get_worktree_path()/,/^}/p' "$rr")"
    eval "$(sed -n '/^get_worktree_navigation_time()/,/^}/p' "$rr")"
    truncate() {
        local str=$1 max_length=$2
        if [ ${#str} -gt "$max_length" ]; then echo "${str:0:$((max_length-3))}..."; else echo "$str"; fi
    }
    declare -gA WORKTREE_MAP=() WORKTREE_BRANCH=() WORKTREE_NAV_TIMES=()
    declare -gA JIRA_TITLE_CACHE=() JIRA_STATUS_CACHE=() JIRA_ASSIGNEE_CACHE=()
    declare -ga DISPLACED_BRANCHES=()
    eval "$(sed -n '/^build_worktree_map()/,/^}/p' "$rr")"
    eval "$(sed -n '/^generate_worktree_data()/,/^}/p' "$rr")"
}

@test "the worktree row carries the parked branch, not a guess from the directory name" {
    setup_conflicting_branches
    cd "$TEST_GIT_REPO"
    git branch -m TEST-100 TEST-100-add-the-thing
    run git -C "$WT_PATH" rebase main
    [ "$status" -ne 0 ]

    cd "$TEST_GIT_REPO"
    export GIT_ROOT="$TEST_GIT_REPO" JIRA_PROJECT="TEST" JIRA_PROJECT_REGEX="TEST"
    export BRANCH_MAX_LENGTH=60
    load_worktree_data_functions
    build_worktree_map
    rows=$(generate_worktree_data "" 2>/dev/null)

    # field 7 is the branch the row offers; field 10 is the worktree it belongs to
    got=$(printf '%s\n' "$rows" | awk -F'\t' -v p="$WT_PATH" '$10 == p { print $7 }')
    [ "$got" = "TEST-100-add-the-thing" ] || { echo "row branch: [$got]"; return 1; }
}

@test "no skip: a nested worktree rebasing its own branch, asked about a different one" {
    setup_conflicting_branches
    cd "$TEST_GIT_REPO"
    git checkout -q -b hotfix/fix-x main~1
    echo hotfix-change > file.txt
    git commit -qam "hotfix change"
    git checkout -q main
    local nested="$TEST_TMPDIR/repo.hotfix/fix-x"
    git worktree add -q "$nested" hotfix/fix-x
    run git -C "$nested" rebase main
    [ "$status" -ne 0 ]

    run detached_mismatch_skip_reason "$nested" "TEST-100"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

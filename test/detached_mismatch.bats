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

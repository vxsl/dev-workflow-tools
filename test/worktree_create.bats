#!/usr/bin/env bats
# Tests for worktree/branch creation — verifying that existing remote branches
# are tracked rather than creating new branches from main.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Setup: create a main repo + a bare "remote" so we can test origin/* refs
setup_repos() {
    setup_temp_dir

    # Create bare repo to act as remote
    BARE_REPO="$TEST_TMPDIR/remote.git"
    git init -q --bare "$BARE_REPO"

    # Clone it to get a main repo with origin
    TEST_GIT_REPO="$TEST_TMPDIR/main-repo"
    git clone -q "$BARE_REPO" "$TEST_GIT_REPO"
    cd "$TEST_GIT_REPO"
    git checkout -q -b main 2>/dev/null || true
    git commit -q --allow-empty -m "initial commit"
    git push -q origin main 2>/dev/null
    git remote set-head origin main 2>/dev/null

    export GIT_ROOT="$TEST_GIT_REPO"
    export TEST_GIT_REPO
    export BARE_REPO
}

# Push a branch to the remote with a commit ahead of main
push_remote_branch() {
    local branch="$1"
    cd "$TEST_GIT_REPO"
    git checkout -q -b "$branch"
    git commit -q --allow-empty -m "work on $branch"
    git push -q origin "$branch"
    git checkout -q main
    git branch -q -D "$branch"
}

# ============================================================================
# create_ticket_worktree logic tests
# ============================================================================

@test "ticket worktree: tracks existing remote branch instead of branching from main" {
    setup_repos
    push_remote_branch "TEST-100"

    local remote_commit
    remote_commit=$(cd "$TEST_GIT_REPO" && git rev-parse origin/TEST-100)
    local main_commit
    main_commit=$(cd "$TEST_GIT_REPO" && git rev-parse origin/main)
    [ "$remote_commit" != "$main_commit" ]

    cd "$TEST_GIT_REPO"
    local wt_path="$TEST_TMPDIR/repo.TEST-100"

    # Replicate the core logic from create_ticket_worktree
    if git show-ref --verify --quiet "refs/remotes/origin/TEST-100"; then
        git worktree add --track -b "TEST-100" "$wt_path" "origin/TEST-100" 2>&1
    else
        git worktree add -b "TEST-100" "$wt_path" "origin/main" 2>&1
    fi

    local wt_commit
    wt_commit=$(git -C "$wt_path" rev-parse HEAD)
    [ "$wt_commit" = "$remote_commit" ]

    # Verify upstream is set to origin/TEST-100
    local upstream
    upstream=$(git -C "$wt_path" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "none")
    [ "$upstream" = "origin/TEST-100" ]

    teardown_temp_dir
}

@test "ticket worktree: creates from main when no remote branch exists" {
    setup_repos

    local main_commit
    main_commit=$(cd "$TEST_GIT_REPO" && git rev-parse origin/main)

    cd "$TEST_GIT_REPO"
    local wt_path="$TEST_TMPDIR/repo.TEST-200"

    if git show-ref --verify --quiet "refs/remotes/origin/TEST-200"; then
        git worktree add --track -b "TEST-200" "$wt_path" "origin/TEST-200" 2>&1
    else
        git worktree add -b "TEST-200" "$wt_path" "origin/main" 2>&1
    fi

    local wt_commit
    wt_commit=$(git -C "$wt_path" rev-parse HEAD)
    [ "$wt_commit" = "$main_commit" ]

    teardown_temp_dir
}

@test "ticket worktree: remote branch with multiple commits ahead of main" {
    setup_repos

    cd "$TEST_GIT_REPO"
    git checkout -q -b "PROJ-600"
    git commit -q --allow-empty -m "commit 1"
    git commit -q --allow-empty -m "commit 2"
    git commit -q --allow-empty -m "commit 3"
    git push -q origin "PROJ-600"
    local remote_commit
    remote_commit=$(git rev-parse HEAD)
    git checkout -q main
    git branch -q -D "PROJ-600"

    local wt_path="$TEST_TMPDIR/repo.PROJ-600"

    if git show-ref --verify --quiet "refs/remotes/origin/PROJ-600"; then
        git worktree add --track -b "PROJ-600" "$wt_path" "origin/PROJ-600" 2>&1
    else
        git worktree add -b "PROJ-600" "$wt_path" "main" 2>&1
    fi

    local wt_commit
    wt_commit=$(git -C "$wt_path" rev-parse HEAD)
    [ "$wt_commit" = "$remote_commit" ]

    local count
    count=$(git -C "$wt_path" rev-list --count main..HEAD)
    [ "$count" -eq 3 ]

    teardown_temp_dir
}

# ============================================================================
# Source code structure tests — ensure single codepath
# ============================================================================

@test "rr.sh: create_ticket_worktree function checks for remote before creating from main" {
    local block
    block=$(sed -n '/^create_ticket_worktree()/,/^}/p' "$REPO_ROOT/bin/rr.sh")
    echo "$block" | grep -q 'show-ref.*verify.*quiet.*refs/remotes/origin/\$ticket_id'
}

@test "rr.sh: both TICKET handlers use create_ticket_worktree (no inline worktree add)" {
    # F2 handler
    local f2_block
    f2_block=$(sed -n '/Handle branchless ticket/,/^        fi$/p' "$REPO_ROOT/bin/rr.sh")
    echo "$f2_block" | grep -q 'create_ticket_worktree'
    ! echo "$f2_block" | grep -q 'git worktree add -b'

    # Enter handler
    local enter_block
    enter_block=$(sed -n '/field7.*TICKET/,/field7.*REMOTE/p' "$REPO_ROOT/bin/rr.sh")
    echo "$enter_block" | grep -q 'create_ticket_worktree'
    ! echo "$enter_block" | grep -q 'git worktree add -b'
}

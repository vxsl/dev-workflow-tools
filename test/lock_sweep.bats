#!/usr/bin/env bats
# Tests for wt-gc's abandoned index.lock sweep.
#
# git removes .git/index.lock on SIGTERM but not on SIGKILL, so a killed process group
# holding git strands one. From then on every status call in that worktree recomputes the
# stat cache, cannot take the lock, and discards the result -- so the worktree re-hashes
# every tracked byte on every call and nothing ever reports it. These tests pin the three
# judgements the sweep has to get right (too young, not empty, actually abandoned) and the
# two properties of the shipped units that no other test would notice going wrong.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WT_GC="$REPO_ROOT/bin/wt-gc"

# A main repo plus two linked worktrees, under a REPOS_DIR the sweep can be pointed at.
setup() {
    setup_temp_dir
    REPOS="$TEST_TMPDIR/repos"
    mkdir -p "$REPOS"
    git init -q "$REPOS/repo"
    git -C "$REPOS/repo" config user.email t@example.com
    git -C "$REPOS/repo" config user.name "T"
    echo hi > "$REPOS/repo/a.txt"
    git -C "$REPOS/repo" add -A
    git -C "$REPOS/repo" commit -qm init
    git -C "$REPOS/repo" worktree add -q "$REPOS/repo.wt" -b wt
    WT_LOCK="$REPOS/repo/.git/worktrees/repo.wt/index.lock"
    MAIN_LOCK="$REPOS/repo/.git/index.lock"
}

teardown() { teardown_temp_dir; }

# An abandoned lock is empty and old. Both, not either.
strand_lock() {
    : > "$1"
    touch -d "$2" "$1"
}

@test "sweep clears an old empty lock under --apply" {
    strand_lock "$WT_LOCK" "2 days ago"
    run "$WT_GC" --repos "$REPOS" --locks-only --apply
    [ "$status" -eq 0 ]
    [ ! -f "$WT_LOCK" ]
}

@test "sweep leaves everything alone without --apply" {
    strand_lock "$WT_LOCK" "2 days ago"
    run "$WT_GC" --repos "$REPOS" --locks-only
    [ "$status" -eq 0 ]
    [ -f "$WT_LOCK" ]
    [[ "$output" == *"would clear"* ]]
}

@test "sweep keeps a lock younger than the age window" {
    : > "$WT_LOCK"
    run "$WT_GC" --repos "$REPOS" --locks-only --apply
    [ "$status" -eq 0 ]
    [ -f "$WT_LOCK" ]
}

@test "--lock-age narrows the window" {
    : > "$WT_LOCK"
    touch -d "10 minutes ago" "$WT_LOCK"
    run "$WT_GC" --repos "$REPOS" --locks-only --apply --lock-age 5
    [ "$status" -eq 0 ]
    [ ! -f "$WT_LOCK" ]
}

# A non-empty lock is a half-written index, which is a different and worse failure than an
# abandoned placeholder. Deleting it would destroy the only evidence.
@test "sweep keeps a stale but non-empty lock" {
    printf 'partial index bytes' > "$MAIN_LOCK"
    touch -d "3 days ago" "$MAIN_LOCK"
    run "$WT_GC" --repos "$REPOS" --locks-only --apply
    [ "$status" -eq 0 ]
    [ -f "$MAIN_LOCK" ]
    [[ "$output" == *"not an empty placeholder"* ]]
}

@test "sweep finds locks in the main repo as well as linked worktrees" {
    strand_lock "$MAIN_LOCK" "2 days ago"
    run "$WT_GC" --repos "$REPOS" --locks-only --apply
    [ "$status" -eq 0 ]
    [ ! -f "$MAIN_LOCK" ]
}

# Removing the lock only unblocks the write; the point is that a refresh then persists, so
# the next status call does not re-hash. Assert the index was actually rewritten.
@test "sweep refreshes the index it unblocked" {
    strand_lock "$WT_LOCK" "2 days ago"
    local idx="$REPOS/repo/.git/worktrees/repo.wt/index"
    touch -d "2 days ago" "$idx"
    local before
    before=$(stat -c %Y "$idx")
    run "$WT_GC" --repos "$REPOS" --locks-only --apply
    [ "$status" -eq 0 ]
    [ "$(stat -c %Y "$idx")" -gt "$before" ]
}

@test "--no-locks skips the sweep entirely" {
    strand_lock "$WT_LOCK" "2 days ago"
    run "$WT_GC" --repos "$REPOS" --no-locks --days 9999
    [ "$status" -eq 0 ]
    [ -f "$WT_LOCK" ]
}

# The timer must never be the destructive half of wt-gc. Plain --apply rm -rf's stale
# target/ and node_modules/ trees; running that unattended on a schedule is a different
# decision than sweeping lock files, and nobody should be able to acquire it by accident.
@test "shipped service runs the sweep only, never a bare --apply" {
    local svc="$REPO_ROOT/systemd/dev-workflow-lock-sweep.service"
    [ -f "$svc" ]
    run grep -E '^ExecStart=' "$svc"
    [ "$status" -eq 0 ]
    [[ "$output" == *"--locks-only"* ]]
    [[ "$output" != *"--free-target"* ]]
}

# The lesson of the work-arcs unit rot: a shipped unit names a literal path, and that path
# is the one thing --install-timer does not rewrite for a hand-copied unit.
@test "shipped units name a path that exists and is executable" {
    local unit path
    for unit in "$REPO_ROOT"/systemd/*.service; do
        while IFS= read -r path; do
            path="${path/\%h/$HOME}"
            [ -x "$path" ] || {
                echo "not executable: $path (named by $unit)"
                return 1
            }
        done < <(grep -oE '%h[^ ]*' "$unit" | sort -u)
    done
}

@test "shipped timer catches up after the machine sleeps" {
    run grep -qx 'Persistent=true' "$REPO_ROOT/systemd/dev-workflow-lock-sweep.timer"
    [ "$status" -eq 0 ]
}

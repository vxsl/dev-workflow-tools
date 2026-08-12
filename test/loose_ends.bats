#!/usr/bin/env bats

# Tests for loose-ends, the work-arc anomaly reporter.
#
# The behaviours worth pinning down are the ones that make it usable rather than
# the ones that make it correct: that it stays silent on a clean repo, that a
# dismissed finding comes back the moment the work behind it changes, and that a
# report with many findings prints every class instead of dying partway through.
# Each of the last three tests covers a bug this tool actually shipped with.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    LOOSE_ENDS="$REPO_ROOT/bin/loose-ends"
    TEST_TMPDIR=$(mktemp -d)

    export HOME="$TEST_TMPDIR/home"
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$HOME" "$XDG_STATE_HOME"

    # An empty projects dir means no session index, which is the honest default
    # for a synthetic repo. Tests that care add transcripts themselves.
    export LOOSE_ENDS_PROJECTS="$TEST_TMPDIR/projects"
    mkdir -p "$LOOSE_ENDS_PROJECTS"

    REPOS="$TEST_TMPDIR/repos"
    REPO="$REPOS/proj"
    mkdir -p "$REPO"
    git init -q -b main "$REPO"
    git -C "$REPO" config user.email test@test
    git -C "$REPO" config user.name test
    git -C "$REPO" commit -q --allow-empty -m initial

    git init -q --bare "$TEST_TMPDIR/remote.git"
    git -C "$REPO" remote add origin "$TEST_TMPDIR/remote.git"
    git -C "$REPO" push -q origin main
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

run_le() { run "$LOOSE_ENDS" --repos "$REPOS" --no-mr --days 0 "$@"; }

# Put a commit on a branch without pushing it.
unpushed_branch() {
    local br="$1" n="${2:-1}"
    git -C "$REPO" checkout -q -b "$br" main
    for i in $(seq 1 "$n"); do
        git -C "$REPO" commit -q --allow-empty -m "$br work $i"
    done
    git -C "$REPO" checkout -q main
}

# A transcript is only ever scanned for its gitBranch field, so one line with the
# field in it is a faithful stand-in for a real session.
fake_session() {
    local branch="$1" id="${2:-aaaaaaaa-0000-0000-0000-000000000000}"
    mkdir -p "$LOOSE_ENDS_PROJECTS/-proj"
    printf '{"type":"user","gitBranch":"%s","cwd":"/x"}\n' "$branch" \
        >"$LOOSE_ENDS_PROJECTS/-proj/$id.jsonl"
}

@test "silent on a repo with nothing outstanding" {
    run_le
    [ "$status" -eq 0 ]
    [[ "$output" == *"No loose ends"* ]]
}

@test "reports unpushed commits with their count" {
    unpushed_branch feature 3
    run_le
    [ "$status" -eq 0 ]
    [[ "$output" == *"feature has 3 unpushed commit(s)"* ]]
}

@test "a branch a session worked on outranks one it did not" {
    unpushed_branch untouched 5
    unpushed_branch session-backed 1
    fake_session session-backed

    run_le
    [ "$status" -eq 0 ]
    # Despite having fewer commits, the session-backed branch sorts first.
    line_backed=$(printf '%s\n' "$output" | grep -n 'session-backed' | cut -d: -f1)
    line_untouched=$(printf '%s\n' "$output" | grep -n 'untouched' | cut -d: -f1)
    [ -n "$line_backed" ] && [ -n "$line_untouched" ]
    [ "$line_backed" -lt "$line_untouched" ]
}

@test "two branches at the same tip are reported as duplicates" {
    unpushed_branch original 1
    git -C "$REPO" branch copy original
    run_le
    [[ "$output" == *"same tip"* ]]
    [[ "$output" == *"original"* && "$output" == *"copy"* ]]
}

@test "local main behind origin/main is reported" {
    git -C "$REPO" commit -q --allow-empty -m upstream-work
    git -C "$REPO" push -q origin main
    git -C "$REPO" reset -q --hard HEAD~1
    run_le
    [[ "$output" == *"behind origin/main"* ]]
}

@test "the days threshold excludes work touched recently" {
    unpushed_branch fresh 1
    run "$LOOSE_ENDS" --repos "$REPOS" --no-mr --days 7
    [ "$status" -eq 0 ]
    [[ "$output" == *"No loose ends"* ]]
}

@test "worktrees of one repo are reported once, not once each" {
    unpushed_branch shared 2
    git -C "$REPO" worktree add -q "$REPOS/proj.wt" shared 2>/dev/null || \
        git -C "$REPO" worktree add "$REPOS/proj.wt" shared
    run_le
    [ "$status" -eq 0 ]
    count=$(printf '%s\n' "$output" | grep -c 'shared has 2 unpushed' || true)
    [ "$count" -eq 1 ]
}

# --- regressions ------------------------------------------------------------

@test "a stash taken on main is not called stranded" {
    # main is always an ancestor of origin/main, so testing it for "merged"
    # once flagged every stash on main as stranded work.
    echo change >"$REPO/file.rs"
    git -C "$REPO" add file.rs
    git -C "$REPO" stash -q
    run_le
    [[ "$output" != *"branch merged"* ]]
    [[ "$output" != *"branch gone"* ]]
}

@test "dismissed findings stay quiet but return when the work changes" {
    unpushed_branch feature 1

    run_le
    [[ "$output" == *"feature has 1 unpushed"* ]]

    run_le --dismiss
    [ "$status" -eq 0 ]

    run_le
    [[ "$output" != *"feature has 1 unpushed"* ]]

    # A new commit changes both the tip sha and the count, so the fingerprint
    # no longer matches what was dismissed.
    git -C "$REPO" checkout -q feature
    git -C "$REPO" commit -q --allow-empty -m "more work"
    git -C "$REPO" checkout -q main

    run_le
    [[ "$output" == *"feature has 2 unpushed"* ]]
}

@test "every class prints even when one is capped" {
    # Reporting used to pipe awk into head, and the SIGPIPE that caused tripped
    # pipefail and killed the report before the later classes were printed.
    for i in $(seq 1 12); do unpushed_branch "br$i" 1; done
    git -C "$REPO" branch dupe br1

    run_le --limit 3
    [ "$status" -eq 0 ]
    [[ "$output" == *"unpushed ("* ]]
    [[ "$output" == *"more (--all)"* ]]
    [[ "$output" == *"dup-tip ("* ]]      # a class after the capped one
    [[ "$output" == *"loose end(s), threshold"* ]]   # and the summary line
}

@test "--dismiss leaves withheld findings alone" {
    for i in $(seq 1 6); do unpushed_branch "br$i" 1; done

    run_le --limit 2 --dismiss
    [[ "$output" == *"Dismissed 2 shown finding(s)"* ]]
    [[ "$output" == *"withheld finding(s) left alone"* ]]

    # The four it held back are still reportable.
    run_le --limit 10
    count=$(printf '%s\n' "$output" | grep -c 'unpushed commit(s)' || true)
    [ "$count" -eq 4 ]
}

@test "--forget clears dismissals" {
    unpushed_branch feature 1
    run_le --dismiss
    run_le
    [[ "$output" != *"feature has 1 unpushed"* ]]

    run "$LOOSE_ENDS" --forget
    [ "$status" -eq 0 ]

    run_le
    [[ "$output" == *"feature has 1 unpushed"* ]]
}

@test "an unreadable MR list degrades to a notice, not a crash" {
    unpushed_branch feature 1
    STUB="$TEST_TMPDIR/stubs"; mkdir -p "$STUB"
    printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB/glab"
    chmod +x "$STUB/glab"

    PATH="$STUB:$PATH" run "$LOOSE_ENDS" --repos "$REPOS" --days 0
    [ "$status" -eq 0 ]
    [[ "$output" == *"MR checks skipped"* ]]
    [[ "$output" == *"feature has 1 unpushed"* ]]
}

#!/usr/bin/env bats

# Tests for oneshot --from-commit.
#
# When the whole change is one already-made commit, its subject and body are the
# title/description pair the ticket and MR would otherwise prompt for. These
# tests assert on what the MR actually received (the argv glab was handed), not
# on script output, and on the guard that refuses the flag when "a single
# commit" isn't what's in front of it.
#
# The ticket-creation half can't be driven here: create-jira-ticket reads its
# summary from /dev/tty and opens $EDITOR, neither of which exists under bats.
# The hotfix path exercises the same extraction end to end without a ticket.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    TEST_TMPDIR=$(mktemp -d)
    TITLE_LOG="$TEST_TMPDIR/mr-title"
    DESC_LOG="$TEST_TMPDIR/mr-description"

    # Isolate caches/state (oneshot writes under $HOME/.cache).
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"

    STUB_BIN="$TEST_TMPDIR/stubs"
    mkdir -p "$STUB_BIN"
    export PATH="$STUB_BIN:$PATH"

    GIT_REPO="$TEST_TMPDIR/repo"
    mkdir -p "$GIT_REPO"
    git init -q -b main "$GIT_REPO"
    git -C "$GIT_REPO" config user.email test@test
    git -C "$GIT_REPO" config user.name test
    git -C "$GIT_REPO" commit -q --allow-empty -m "initial"
    # Publish the base commit for real: "unpublished" is measured against
    # refs/remotes/origin, so an empty remote would make every commit count and
    # the single-commit case would be unreachable.
    git init -q --bare "$TEST_TMPDIR/remote.git"
    git -C "$GIT_REPO" remote add origin "$TEST_TMPDIR/remote.git"
    git -C "$GIT_REPO" push -q origin main
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# git stub that short-circuits `git push` and delegates everything else to real git.
stub_git_push() {
    local real_git
    real_git=$(command -v git)
    cat > "$STUB_BIN/git" <<EOF
#!/usr/bin/env bash
[ "\$1" = "push" ] && exit 0
exec "$real_git" "\$@"
EOF
    chmod +x "$STUB_BIN/git"
}

# glab stub: records the title and description `mr create` was given, each to its
# own file so a multi-line description survives intact, then reports success.
stub_glab() {
    cat > "$STUB_BIN/glab" <<EOF
#!/usr/bin/env bash
[ "\$1" = "auth" ] && exit 0
if [ "\$1" = "mr" ] && [ "\$2" = "list" ]; then echo '[]'; exit 0; fi
if [ "\$1" = "mr" ] && [ "\$2" = "create" ]; then
    while [ \$# -gt 0 ]; do
        case "\$1" in
            --title) printf '%s' "\$2" > "$TITLE_LOG"; shift 2 ;;
            --description) printf '%s' "\$2" > "$DESC_LOG"; shift 2 ;;
            *) shift ;;
        esac
    done
    echo "https://gitlab.example.com/g/p/-/merge_requests/1"
    exit 0
fi
exit 1
EOF
    chmod +x "$STUB_BIN/glab"
}

# A finished, described change: subject line, prose body, machine trailers.
commit_the_change() {
    echo change > "$GIT_REPO/file.txt"
    git -C "$GIT_REPO" add file.txt
    git -C "$GIT_REPO" commit -q -F - <<'MSG'
Generate metadata for parameterized views from their stored schema

Symptom: parameterized views returned an empty column list.

Cause: the schema was never stored alongside the view.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Session-Id: abc123
MSG
}

@test "oneshot --from-commit: MR title is the commit subject" {
    stub_git_push
    stub_glab
    commit_the_change
    cd "$GIT_REPO"
    run "$REPO_ROOT/bin/oneshot" --hotfix --from-commit
    [ "$status" -eq 0 ]
    [ -f "$TITLE_LOG" ]
    [ "$(cat "$TITLE_LOG")" = "Generate metadata for parameterized views from their stored schema" ]
}

@test "oneshot --from-commit: MR description is the commit body" {
    stub_git_push
    stub_glab
    commit_the_change
    cd "$GIT_REPO"
    run "$REPO_ROOT/bin/oneshot" --hotfix --from-commit
    [ "$status" -eq 0 ]
    [ -f "$DESC_LOG" ]
    [[ "$(cat "$DESC_LOG")" == *"Symptom: parameterized views returned an empty column list."* ]]
    [[ "$(cat "$DESC_LOG")" == *"Cause: the schema was never stored alongside the view."* ]]
}

@test "oneshot --from-commit: trailers stay out of the MR description" {
    stub_git_push
    stub_glab
    commit_the_change
    cd "$GIT_REPO"
    run "$REPO_ROOT/bin/oneshot" --hotfix --from-commit
    [ "$status" -eq 0 ]
    # Co-Authored-By/Session-Id describe how the commit was made, not the change.
    [[ "$(cat "$DESC_LOG")" != *"Co-Authored-By"* ]]
    [[ "$(cat "$DESC_LOG")" != *"Session-Id"* ]]
}

@test "oneshot --from-commit: 'Cause:' prose survives the trailer strip" {
    stub_git_push
    stub_glab
    echo change > "$GIT_REPO/file.txt"
    git -C "$GIT_REPO" add file.txt
    # No trailers, and the body's last paragraph is a lone "Token: value" line —
    # git's generic trailer rule would eat it. It's the point of the description.
    git -C "$GIT_REPO" commit -q -F - <<'MSG'
Cache the token lookup per request

Cause: the memo key included the request object.
MSG
    cd "$GIT_REPO"
    run "$REPO_ROOT/bin/oneshot" --hotfix --from-commit
    [ "$status" -eq 0 ]
    [ "$(cat "$DESC_LOG")" = "Cause: the memo key included the request object." ]
}

@test "oneshot --from-commit: refuses when there is more than one commit" {
    stub_git_push
    stub_glab
    commit_the_change
    git -C "$GIT_REPO" commit -q --allow-empty -m "second"
    cd "$GIT_REPO"
    run "$REPO_ROOT/bin/oneshot" --hotfix --from-commit
    [ "$status" -eq 1 ]
    [[ "$output" == *"--from-commit needs exactly one unpublished commit"* ]]
    # Nothing was branched or published on the way out.
    [ ! -f "$TITLE_LOG" ]
}

@test "oneshot --from-commit: refuses when changes are still staged" {
    stub_git_push
    stub_glab
    commit_the_change
    echo more > "$GIT_REPO/other.txt"
    git -C "$GIT_REPO" add other.txt
    cd "$GIT_REPO"
    run "$REPO_ROOT/bin/oneshot" --hotfix --from-commit
    [ "$status" -eq 1 ]
    [[ "$output" == *"--from-commit needs exactly one unpublished commit"* ]]
    [ ! -f "$TITLE_LOG" ]
}

#!/usr/bin/env bash
# Helpers for the fzedit BATS suite.
#
# Deliberately does NOT load test_helper/common, which sources lib/rr-core.sh —
# fzedit shares nothing with rr and we want these tests hermetic.
#
# Every test runs against a throwaway $HOME so that fzedit's state (scope pin, mode,
# history) and its $HOME-relative display logic can't touch the real one, and a fake
# tmux so worktree inference is deterministic rather than depending on whatever panes
# happen to be open.

FZEDIT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FZEDIT="$FZEDIT_REPO_ROOT/bin/fzedit"

fz() { "$FZEDIT" "$@"; }

setup_fzedit_env() {
    TEST_TMPDIR=$(mktemp -d)
    export TEST_TMPDIR

    # Hermetic HOME: state dir, history file, tilde-collapsing and the $HOME scope
    # fallback all key off it.
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"

    export TEST_TMUX_PANES="$TEST_TMPDIR/tmux_panes"
    : > "$TEST_TMUX_PANES"

    # Fake tmux, honouring the session filter fzedit passes so we can prove it
    # ignores its own scratchpad session.
    mkdir -p "$TEST_TMPDIR/fakebin"
    cat > "$TEST_TMPDIR/fakebin/tmux" <<'FAKE'
#!/usr/bin/env bash
filter=""
for a in "$@"; do
    case "$a" in *session_name*) filter="$a" ;; esac
done
[ -f "$TEST_TMUX_PANES" ] || exit 0
while IFS=$'\t' read -r activity session path; do
    [ -n "$activity" ] || continue
    if [ -n "$filter" ] && [[ "$filter" == *",${session}}"* ]]; then
        continue
    fi
    printf '%s %s\n' "$activity" "$path"
done < "$TEST_TMUX_PANES"
FAKE
    chmod +x "$TEST_TMPDIR/fakebin/tmux"
    export PATH="$TEST_TMPDIR/fakebin:$PATH"

    # Somewhere neutral, so $PWD never accidentally resolves the scope.
    cd "$TEST_TMPDIR"
}

teardown_fzedit_env() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# Register a tmux pane for scope inference. Args: activity, session, path
add_tmux_pane() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$TEST_TMUX_PANES"
}

git_q() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}"; }

# A main repo plus linked worktrees, mirroring the shape of the real ul checkout:
#   $MAIN            on branch main
#   $WT_FEATURE      repo.feature       (branch feature)
#   $WT_NESTED       repo.nested/deep   (branch deep) — nested, basename collides
#   $WT_DETACHED     repo.detached      (detached HEAD)
setup_repo_with_worktrees() {
    MAIN="$TEST_TMPDIR/repos/repo"
    mkdir -p "$MAIN"
    git -C "$MAIN" init -q -b main
    mkdir -p "$MAIN/src"
    echo 'const a = 1;' > "$MAIN/src/app.ts"
    echo 'readme' > "$MAIN/README.md"
    git_q "$MAIN" add -A
    git_q "$MAIN" commit -q -m initial

    git_q "$MAIN" branch feature
    git_q "$MAIN" branch deep

    WT_FEATURE="$TEST_TMPDIR/repos/repo.feature"
    WT_NESTED="$TEST_TMPDIR/repos/repo.nested/deep"
    WT_DETACHED="$TEST_TMPDIR/repos/repo.detached"
    git_q "$MAIN" worktree add -q "$WT_FEATURE" feature
    git_q "$MAIN" worktree add -q "$WT_NESTED" deep
    git_q "$MAIN" worktree add -q --detach "$WT_DETACHED" main

    export MAIN WT_FEATURE WT_NESTED WT_DETACHED
}

pin_scope() {
    mkdir -p "$HOME/.cache/fzedit"
    printf '%s' "$1" > "$HOME/.cache/fzedit/scope"
}

set_mode() {
    mkdir -p "$HOME/.cache/fzedit"
    printf '%s' "$1" > "$HOME/.cache/fzedit/mode"
}

# Strip ANSI so assertions read cleanly.
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

rows_of_type() { fz --generate-list | awk -F'\t' -v t="$1" '$1 == t'; }

# Displayed (third) column, ANSI stripped.
display_col() { cut -f3- | plain; }

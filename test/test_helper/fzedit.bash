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

    # Pin the instance id: state is per-instance now, and TMUX_PANE would otherwise
    # be inherited from whatever tmux the suite happens to run under.
    export FZEDIT_INSTANCE=test

    # Never let the suite press xmonad's scratchpad key on the real desktop.
    export FZEDIT_NO_PAD=1

    export TEST_TMUX_PANES="$TEST_TMPDIR/tmux_panes"
    : > "$TEST_TMUX_PANES"
    export TEST_TMUX_SESSIONS="$TEST_TMPDIR/tmux_sessions"
    : > "$TEST_TMUX_SESSIONS"

    # Fake tmux, honouring the session filter fzedit passes so we can prove it
    # ignores its own scratchpad session.
    mkdir -p "$TEST_TMPDIR/fakebin"
    cat > "$TEST_TMPDIR/fakebin/tmux" <<'FAKE'
#!/usr/bin/env bash
# Fake tmux. Dispatches on the subcommand so tests can distinguish "no session" from
# "session exists" -- a fake that exits 0 for everything makes those tests vacuous.
sub="$1"; shift
case "$sub" in
    list-panes)
        filter=""
        for a in "$@"; do case "$a" in *session_name*) filter="$a" ;; esac; done
        [ -f "$TEST_TMUX_PANES" ] || exit 0
        while IFS=$'\t' read -r activity session path; do
            [ -n "$activity" ] || continue
            if [ -n "$filter" ] && [[ "$filter" == *",${session}}"* ]]; then continue; fi
            if [ "${1:-}" = "-a" ] && [[ " $* " == *"pane_id"* ]]; then
                printf '%%%s\n' "$activity"
            else
                printf '%s %s\n' "$activity" "$path"
            fi
        done < "$TEST_TMUX_PANES"
        ;;
    has-session)
        want=""; for a in "$@"; do [ "$a" = "-t" ] || want="$a"; done
        # must propagate failure: the trailing `exit 0` below would otherwise make
        # every has-session look successful, which makes the tab tests vacuous.
        grep -qx "$want" "$TEST_TMUX_SESSIONS" 2>/dev/null || exit 1
        ;;
    new-window)
        printf '%s\n' "$*" >> "$TEST_TMPDIR/tmux_new_windows"
        ;;
    display-message)
        [ -f "$TEST_TMUX_SESSIONS" ] && head -1 "$TEST_TMUX_SESSIONS"
        ;;
    list-windows)
        printf 'one\n'
        ;;
    *)  : ;;
esac
exit 0
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

# The fixture above lives NEXT TO the fake $HOME, not inside it, so the home rung's
# $HOME sweep never sees it. That is fine for every scoped rung, but the whole point
# of the home rung is what it does and doesn't sweep out of $HOME -- so those tests
# need a repo that is genuinely underneath it.
#
#   $H_MAIN      ~/work/repos/proj          (branch main)
#   $H_SIBLING   ~/work/repos/proj.sibling  (branch side)
# plus ~/notes.md, which is under $HOME but in no repo at all.
setup_repo_under_home() {
    H_MAIN="$HOME/work/repos/proj"
    H_SIBLING="$HOME/work/repos/proj.sibling"
    mkdir -p "$H_MAIN/src"
    git -C "$H_MAIN" init -q -b main
    echo 'shared' > "$H_MAIN/src/shared.ts"
    echo 'only in main' > "$H_MAIN/src/main-only.ts"
    git_q "$H_MAIN" add -A
    git_q "$H_MAIN" commit -q -m initial
    git_q "$H_MAIN" worktree add -q "$H_SIBLING" -b side
    echo 'only in the sibling' > "$H_SIBLING/src/sibling-only.ts"
    echo 'notes' > "$HOME/notes.md"
    export H_MAIN H_SIBLING
}

pin_scope() {
    mkdir -p "$HOME/.cache/fzedit"
    printf '%s' "$1" > "$HOME/.cache/fzedit/scope-$FZEDIT_INSTANCE"
}

set_mode() {
    mkdir -p "$HOME/.cache/fzedit"
    printf '%s' "$1" > "$HOME/.cache/fzedit/mode-$FZEDIT_INSTANCE"
}

# Strip ANSI so assertions read cleanly.
plain() { sed 's/\x1b\[[0-9;]*m//g'; }

rows_of_type() { fz --generate-list | awk -F'\t' -v t="$1" '$1 == t'; }

# Displayed (third) column, ANSI stripped.
display_col() { cut -f3- | plain; }

# Pretend a tmux session exists (used for the tab tests).
add_tmux_session() { printf '%s\n' "$1" >> "$TEST_TMUX_SESSIONS"; }

# A tmux that answers #{window_end_flag} with $1, so --next-tab's two branches are both
# reachable, and records which branch it took. Everything else lands in $TEST_TMPDIR/
# tmux_calls verbatim: sync_tab_chrome sends its options as one ';'-separated command
# list, so there is one invocation to inspect rather than one per option.
fake_tmux_tabs() {
    local end="$1"
    add_tmux_session fzpad
    cat > "$TEST_TMPDIR/fakebin/tmux" <<FAKE
#!/usr/bin/env bash
case "\$1" in
    display-message) echo $end ;;
    has-session)     exit 0 ;;
    next-window)     shift; echo "\$*" > "$TEST_TMPDIR/nexted" ;;
    new-window)      shift; echo "\$*" >> "$TEST_TMPDIR/tmux_new_windows" ;;
    *)               echo "\$*" >> "$TEST_TMPDIR/tmux_calls" ;;
esac
exit 0
FAKE
    chmod +x "$TEST_TMPDIR/fakebin/tmux"
}

#!/usr/bin/env bats
# End-to-end tests for fzedit.
#
# Each @test here corresponds to something that was actually wrong at some point,
# or to an invariant the fzf bindings silently depend on. In particular:
#   * rows must be exactly 3 tab-separated fields, because fzf is configured with
#     --with-nth=3.. and every binding indexes {1}/{2}. A row with the wrong shape
#     doesn't error, it just opens the wrong thing.
#   * file listings must be scoped to one worktree — unscoped this was 2M rows.
#   * git status must be parsed from -z output, or a rename emits a phantom row and
#     any path containing a space breaks.

load test_helper/fzedit

make_conflict() {
    git_q "$MAIN" checkout -q -b conflict-a main
    echo 'const a = "a";' > "$MAIN/src/app.ts"
    git_q "$MAIN" commit -qam a
    git_q "$MAIN" checkout -q -b conflict-b main
    echo 'const a = "b";' > "$MAIN/src/app.ts"
    git_q "$MAIN" commit -qam b
    git_q "$MAIN" merge conflict-a >/dev/null 2>&1 || true
}

setup() {
    setup_fzedit_env
    setup_repo_with_worktrees
}

teardown() {
    teardown_fzedit_env
}

# --------------------------------------------------------------------------
# Row shape — what every fzf binding depends on
# --------------------------------------------------------------------------

@test "every row is exactly three tab-separated fields" {
    pin_scope "$WT_FEATURE"
    echo dirty >> "$WT_FEATURE/src/app.ts"
    for mode in changed files home; do
        set_mode "$mode"
        out="$(fz --generate-list | awk -F'\t' '{print NF}' | sort -u)"
        [ "$out" = "3" ] || { echo "mode $mode: field counts: $out"; return 1; }
    done
}

@test "row type column is only ever f or w" {
    pin_scope "$WT_FEATURE"
    set_mode files
    out="$(fz --generate-list | cut -f1 | sort -u | tr '\n' ' ')"
    [ "$out" = "f w " ]
}

@test "field 2 is always an existing absolute path" {
    pin_scope "$WT_FEATURE"
    set_mode files
    while IFS=$'\t' read -r _type path _disp; do
        [[ "$path" = /* ]] || { echo "not absolute: $path"; return 1; }
        [ -e "$path" ] || { echo "does not exist: $path"; return 1; }
    done < <(fz --generate-list)
}

# --------------------------------------------------------------------------
# Scoping — the reason fzedit was unusable as a primary editor
# --------------------------------------------------------------------------

@test "files mode is scoped: a sibling worktree's files are absent" {
    echo 'unique-to-feature' > "$WT_FEATURE/src/only-here.ts"
    echo 'unique-to-nested'  > "$WT_NESTED/src/nested-only.ts"
    pin_scope "$WT_FEATURE"
    set_mode files

    out="$(rows_of_type f | cut -f2)"
    [[ "$out" == *"only-here.ts"* ]]
    [[ "$out" != *"nested-only.ts"* ]]
}

@test "the same filename in two worktrees yields one row, not two" {
    pin_scope "$WT_FEATURE"
    set_mode files
    out="$(rows_of_type f | cut -f2 | grep -c '/src/app\.ts$')"
    [ "$out" = "1" ]
}

# --------------------------------------------------------------------------
# Scope resolution
# --------------------------------------------------------------------------

@test "scope: an explicit pin wins" {
    add_tmux_pane 999 work "$WT_NESTED"
    pin_scope "$WT_FEATURE"
    out="$(fz --header | plain)"
    [[ "$out" == *"repo.feature"* ]]
}

@test "scope: falls back to the most recently active tmux pane" {
    add_tmux_pane 100 work "$WT_FEATURE"
    add_tmux_pane 900 work "$WT_NESTED"
    out="$(fz --header | plain)"
    [[ "$out" == *"deep"* ]]
    [[ "$out" != *"repo.feature"* ]]
}

@test "scope: ignores panes belonging to the fileedit scratchpad itself" {
    add_tmux_pane 900 fileedit "$WT_NESTED"
    add_tmux_pane 100 work     "$WT_FEATURE"
    out="$(fz --header | plain)"
    [[ "$out" == *"repo.feature"* ]]
}

@test "scope: a pane outside any git repo is skipped" {
    mkdir -p "$TEST_TMPDIR/not-a-repo"
    add_tmux_pane 900 work "$TEST_TMPDIR/not-a-repo"
    add_tmux_pane 100 work "$WT_FEATURE"
    out="$(fz --header | plain)"
    [[ "$out" == *"repo.feature"* ]]
}

@test "scope: with nothing to infer, says so instead of guessing" {
    out="$(fz --header | plain)"
    [[ "$out" == *"no worktree detected"* ]]
}

# --------------------------------------------------------------------------
# The rung ladder — conflicts ⊂ changed ⊂ files ⊂ home
#
# These sets are nested, not independent toggles, so they are one axis: TAB widens,
# S-TAB narrows, and the starting rung is chosen automatically.
# --------------------------------------------------------------------------

@test "auto rung: conflicts when the tree is conflicted" {
    make_conflict
    pin_scope "$MAIN"
    out="$(fz --header | plain)"
    [[ "$out" == *"[conflicts (1)]"* ]]
}

@test "auto rung: changed when dirty but not conflicted" {
    echo dirty >> "$WT_FEATURE/src/app.ts"
    pin_scope "$WT_FEATURE"
    out="$(fz --header | plain)"
    [[ "$out" == *"[changed (1)]"* ]]
}

@test "auto rung: files when the tree is clean" {
    pin_scope "$WT_FEATURE"
    out="$(fz --header | plain)"
    [[ "$out" == *"[files]"* ]]
}

@test "auto rung: home when there is no repo at all" {
    out="$(fz --header | plain)"
    [[ "$out" == *"no worktree detected"* ]]
    [[ "$out" == *"[home]"* ]]
}

@test "TAB widens one rung at a time" {
    echo dirty >> "$WT_FEATURE/src/app.ts"
    pin_scope "$WT_FEATURE"
    [[ "$(fz --header | plain)" == *"[changed (1)]"* ]]
    fz --widen
    [[ "$(fz --header | plain)" == *"[files]"* ]]
    fz --widen
    [[ "$(fz --header | plain)" == *"[home]"* ]]
}

@test "S-TAB narrows one rung at a time" {
    pin_scope "$WT_FEATURE"
    set_mode home
    fz --narrow
    [[ "$(fz --header | plain)" == *"[files]"* ]]
    fz --narrow
    [[ "$(fz --header | plain)" == *"[changed"* ]]
}

@test "widening clamps at the widest rung rather than wrapping" {
    pin_scope "$WT_FEATURE"
    for _ in 1 2 3 4 5 6; do fz --widen; done
    [[ "$(fz --header | plain)" == *"[home]"* ]]
}

@test "narrowing clamps at the narrowest rung rather than wrapping" {
    pin_scope "$WT_FEATURE"
    for _ in 1 2 3 4 5 6; do fz --narrow; done
    [[ "$(fz --header | plain)" == *"[conflicts"* ]]
}

@test "the header shows the whole ladder, not just the current rung" {
    pin_scope "$WT_FEATURE"
    out="$(fz --header | plain)"
    for rung in conflicts changed files home; do
        [[ "$out" == *"$rung"* ]] || { echo "ladder missing $rung: $out"; return 1; }
    done
}

@test "outside a repo the rung is forced to home even if one was set" {
    set_mode changed
    out="$(fz --header | plain)"
    [[ "$out" == *"[home]"* ]]
}

@test "a fresh launch resets the rung instead of inheriting a stale one" {
    # Landing in a rung chosen days ago is the confusing part of a persisted mode.
    pin_scope "$WT_FEATURE"
    set_mode home
    real_fzf="$(command -v fzf)" || skip "fzf not installed"
    printf '#!/bin/bash\nexec %s "$@" --version\n' "$real_fzf" > "$TEST_TMPDIR/fakebin/fzfwrap"
    chmod +x "$TEST_TMPDIR/fakebin/fzfwrap"
    FZP_FZF="$TEST_TMPDIR/fakebin/fzfwrap" "$FZEDIT" --one-shot >/dev/null 2>&1
    [ ! -s "$HOME/.cache/fzedit/mode" ]
}

# --------------------------------------------------------------------------
# changed mode — git status parsing
# --------------------------------------------------------------------------

@test "changed mode lists modified, staged and untracked files" {
    echo modified >> "$WT_FEATURE/src/app.ts"
    echo staged   >  "$WT_FEATURE/src/staged.ts"
    echo untracked > "$WT_FEATURE/src/untracked.ts"
    git_q "$WT_FEATURE" add src/staged.ts
    pin_scope "$WT_FEATURE"
    set_mode changed

    out="$(rows_of_type f | cut -f2)"
    [[ "$out" == *"app.ts"* ]]
    [[ "$out" == *"staged.ts"* ]]
    [[ "$out" == *"untracked.ts"* ]]
}

@test "changed mode ignores files that are not dirty" {
    echo modified >> "$WT_FEATURE/src/app.ts"
    pin_scope "$WT_FEATURE"
    set_mode changed
    out="$(rows_of_type f | cut -f2 | grep -c README.md || true)"
    [ "$out" = "0" ]
}

@test "changed mode survives a path containing spaces" {
    echo hi > "$WT_FEATURE/src/a file with spaces.ts"
    pin_scope "$WT_FEATURE"
    set_mode changed

    out="$(rows_of_type f | cut -f2)"
    [[ "$out" == *"a file with spaces.ts"* ]]
    # Still one well-formed row, not split on the spaces
    [ "$(rows_of_type f | wc -l)" = "1" ]
}

@test "changed mode does not emit a phantom row for a rename" {
    git_q "$WT_FEATURE" mv src/app.ts src/renamed.ts
    pin_scope "$WT_FEATURE"
    set_mode changed

    # -z emits "R<new>\0<old>\0"; consuming only the first field would leave the
    # old path dangling as its own bogus row.
    out="$(rows_of_type f | cut -f2)"
    [[ "$out" == *"renamed.ts"* ]]
    [ "$(rows_of_type f | wc -l)" = "1" ]
}

@test "changed mode skips deleted files (nothing to open)" {
    git_q "$WT_FEATURE" rm -q src/app.ts
    pin_scope "$WT_FEATURE"
    set_mode changed
    [ "$(rows_of_type f | wc -l)" = "0" ]
}

# --------------------------------------------------------------------------
# conflicts mode
# --------------------------------------------------------------------------

@test "conflicts mode lists only unmerged files" {
    make_conflict
    echo untracked > "$MAIN/src/noise.ts"
    pin_scope "$MAIN"
    set_mode conflicts

    out="$(rows_of_type f | cut -f2)"
    [[ "$out" == *"app.ts"* ]]
    [[ "$out" != *"noise.ts"* ]]
}

@test "preview of a conflicted file reports the marker line" {
    make_conflict
    out="$(fz --preview f "$MAIN/src/app.ts" | plain)"
    [[ "$out" == *"conflict at line"* ]]
}

# --------------------------------------------------------------------------
# Worktrees as first-class rows
# --------------------------------------------------------------------------

@test "worktree rows appear in every mode" {
    echo dirty >> "$WT_FEATURE/src/app.ts"
    pin_scope "$WT_FEATURE"
    for mode in changed files; do
        set_mode "$mode"
        [ "$(rows_of_type w | wc -l)" -ge 4 ]
    done
}

@test "worktree rows rank after file rows" {
    echo dirty >> "$WT_FEATURE/src/app.ts"
    pin_scope "$WT_FEATURE"
    set_mode changed
    out="$(fz --generate-list | cut -f1 | uniq | tr '\n' ' ')"
    [ "$out" = "f w " ]
}

@test "a nested worktree keeps the prefix that disambiguates it" {
    pin_scope "$WT_FEATURE"
    set_mode files
    out="$(rows_of_type w | display_col | grep deep)"
    # basename alone would be the ambiguous "deep"
    [[ "$out" == *"repo.nested/deep"* ]]
}

@test "a detached worktree shows a short sha, not 40 characters" {
    pin_scope "$WT_FEATURE"
    set_mode files
    out="$(rows_of_type w | display_col | grep detached)"
    [[ "$out" == *"detached"* ]]
    # the 40-char sha would blow the row width
    ! [[ "$out" =~ [0-9a-f]{40} ]]
}

@test "worktree rows carry the branch name" {
    pin_scope "$WT_FEATURE"
    set_mode files
    out="$(rows_of_type w | display_col)"
    [[ "$out" == *"feature"* ]]
    [[ "$out" == *"main"* ]]
}

@test "worktree preview shows repo status rather than file contents" {
    echo dirty >> "$WT_FEATURE/src/app.ts"
    out="$(fz --preview w "$WT_FEATURE" | plain)"
    [[ "$out" == *"app.ts"* ]]
    [[ "$out" == *"feature"* ]]
}

# --------------------------------------------------------------------------
# enter dispatch
# --------------------------------------------------------------------------

@test "--open on a worktree row re-scopes instead of opening an editor" {
    pin_scope "$WT_FEATURE"
    set_mode files
    fz --open w "$WT_NESTED"
    [ "$(cat "$HOME/.cache/fzedit/scope")" = "$WT_NESTED" ]
    # mode is reset so the new worktree gets its own auto-default
    [ ! -s "$HOME/.cache/fzedit/mode" ]
}

@test "--open on a file row records history" {
    FZEDIT_EDITOR=true fz --open f "$WT_FEATURE/src/app.ts"
    run grep -c "src/app.ts" "$HOME/.fzedit_history"
    [ "$output" -ge 1 ]
}

@test "--rootof resolves the repo root, not the file's directory" {
    # git-conflict.nvim only activates when getcwd()/.git exists, so this has to be
    # the worktree root or conflict mappings never appear.
    run fz --rootof "$WT_FEATURE/src/app.ts"
    [ "$output" = "$WT_FEATURE" ]
}

@test "--rootof falls back to the directory for a file outside any repo" {
    mkdir -p "$TEST_TMPDIR/loose"
    touch "$TEST_TMPDIR/loose/x.txt"
    run fz --rootof "$TEST_TMPDIR/loose/x.txt"
    [ "$output" = "$TEST_TMPDIR/loose" ]
}

@test "history is capped so it cannot grow without bound" {
    for i in $(seq 1 260); do echo "/seed/f$i"; done > "$HOME/.fzedit_history"
    fz --record "$WT_FEATURE/src/app.ts"
    [ "$(wc -l < "$HOME/.fzedit_history")" -le 200 ]
}

# --------------------------------------------------------------------------
# fzf accepts the bindings we build
# --------------------------------------------------------------------------

@test "fzf accepts every binding in every mode" {
    # fzf validates --bind before it needs a terminal, so appending --version makes
    # it either print a version or reject a malformed binding.
    local real_fzf
    real_fzf="$(command -v fzf)"
    [ -n "$real_fzf" ] || skip "fzf not installed"
    printf '#!/bin/bash\nexec %s "$@" --version\n' "$real_fzf" > "$TEST_TMPDIR/fakebin/fzfwrap"
    chmod +x "$TEST_TMPDIR/fakebin/fzfwrap"

    # The binding set is static, so validating it once is enough — a launch resets
    # the rung anyway, so looping over rungs here would prove nothing.
    pin_scope "$WT_FEATURE"
    run env FZP_FZF="$TEST_TMPDIR/fakebin/fzfwrap" "$FZEDIT" --one-shot
    # NB: `[[ ... ]] && { ...; }` would make this test fail whenever the condition
    # is false, since that compound exits 1. Use if/fi.
    if [ "$status" -ne 0 ]; then echo "exited $status: $output"; return 1; fi
    if [[ "$output" == *"unsupported key"* || "$output" == *"invalid"* ]]; then
        echo "rejected: $output"; return 1
    fi
}

@test "the ladder keys are actually bound" {
    real_fzf="$(command -v fzf)" || skip "fzf not installed"
    # Echo the argv fzf would receive so we can assert on the bindings themselves.
    printf '#!/bin/bash\nprintf "%%s\\n" "$@"\n' > "$TEST_TMPDIR/fakebin/fzfargs"
    chmod +x "$TEST_TMPDIR/fakebin/fzfargs"
    pin_scope "$WT_FEATURE"

    out="$(FZP_FZF="$TEST_TMPDIR/fakebin/fzfargs" "$FZEDIT" --one-shot 2>&1)"
    [[ "$out" == *"tab:execute-silent"*"--widen"* ]]
    [[ "$out" == *"btab:execute-silent"*"--narrow"* ]]
    # xmonad grabs Alt-w for NSP_slack, so the worktree browse must not be on M-w.
    [[ "$out" == *"ctrl-t:execute"*"--pick-worktree"* ]]
    [[ "$out" != *"alt-w:"* ]]
    [[ "$out" == *"enter:execute"*"--open"* ]]
    # the retired per-rung letter keys must not linger
    [[ "$out" != *"ctrl-g:"* ]]
    [[ "$out" != *"ctrl-x:"* ]]
}

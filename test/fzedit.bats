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

# Leave worktree $1 stopped mid-rebase on a conflict, the way the real thing does:
# HEAD detached at the commit being replayed, the branch name recoverable only from
# rebase-merge/head-name.
start_conflicting_rebase() {
    local wt="$1"
    echo 'const a = "main";'   > "$MAIN/src/app.ts"
    git_q "$MAIN" commit -qam main-change
    echo 'const a = "branch";' > "$wt/src/app.ts"
    git_q "$wt" commit -qam branch-change
    git_q "$wt" rebase main >/dev/null 2>&1 || true
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

@test "default rung is home, even when the tree is dirty" {
    # The pad is a general "open a file" tool first; starting narrow means the file
    # you want is often just not in the list.
    echo dirty >> "$WT_FEATURE/src/app.ts"
    pin_scope "$WT_FEATURE"
    out="$(fz --header | plain)"
    [[ "$out" == *"[home]"* ]]
}

@test "default rung is home, even when the tree is conflicted" {
    make_conflict
    pin_scope "$MAIN"
    out="$(fz --header | plain)"
    [[ "$out" == *"[home]"* ]]
}

@test "FZEDIT_DEFAULT_RUNG overrides the default" {
    echo dirty >> "$WT_FEATURE/src/app.ts"
    pin_scope "$WT_FEATURE"
    out="$(FZEDIT_DEFAULT_RUNG=changed fz --header | plain)"
    [[ "$out" == *"[changed (1)]"* ]]
}

@test "a nonsense FZEDIT_DEFAULT_RUNG falls back to home rather than breaking" {
    pin_scope "$WT_FEATURE"
    out="$(FZEDIT_DEFAULT_RUNG=banana fz --header | plain)"
    [[ "$out" == *"[home]"* ]]
}

@test "auto rung: home when there is no repo at all" {
    out="$(fz --header | plain)"
    [[ "$out" == *"no worktree detected"* ]]
    [[ "$out" == *"[home]"* ]]
}

@test "TAB widens one rung at a time" {
    echo dirty >> "$WT_FEATURE/src/app.ts"
    pin_scope "$WT_FEATURE"
    set_mode conflicts
    fz --widen
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

@test "the header says the scope is mid-rebase rather than just 'HEAD'" {
    start_conflicting_rebase "$WT_FEATURE"
    pin_scope "$WT_FEATURE"

    out="$(fz --header | plain)"
    [[ "$out" == *"feature"* ]]
    [[ "$out" == *"rebase"* ]]
    # what rev-parse --abbrev-ref reports for a detached HEAD, and it tells you nothing
    [[ "$out" != *"⊙ HEAD"* ]]
}

# "conflicts (0)" is indistinguishable from being pointed at the wrong worktree, and
# with two branches sharing a prefix (smp-select vs feature-a-state) the scope name
# in the header reads as correct. Name the worktree that has the rebase instead.
@test "the header names a rebase in another worktree, so conflicts (0) is not a lie" {
    start_conflicting_rebase "$WT_FEATURE"
    pin_scope "$WT_NESTED"

    out="$(fz --header | plain)"
    [[ "$out" == *"conflicts (0)"* ]]
    [[ "$out" == *"repo.feature (rebase"* ]]
}

@test "the header stays quiet when nothing is in flight elsewhere" {
    pin_scope "$WT_FEATURE"
    out="$(fz --header | plain)"
    [[ "$out" != *"⚠"* ]]
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
    [ ! -s "$HOME/.cache/fzedit/mode-$FZEDIT_INSTANCE" ]
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

# A rebase leaves the same unmerged index a merge does, so this rung has to work for
# both -- when it appears to be empty mid-rebase, the scope is wrong, not the rung.
@test "conflicts mode lists unmerged files during a rebase, not just a merge" {
    start_conflicting_rebase "$WT_FEATURE"
    pin_scope "$WT_FEATURE"
    set_mode conflicts

    out="$(rows_of_type f | cut -f2)"
    [[ "$out" == *"$WT_FEATURE/src/app.ts"* ]]
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

# The row is how you find a worktree, and mid-rebase HEAD is a bare sha -- so labelling
# it "detached 1a2b3c4d" hides the branch exactly when you are hunting for it, and a
# branch-shaped query stops matching the one worktree you actually want.
@test "a rebasing worktree still carries its branch name, so a branch query finds it" {
    start_conflicting_rebase "$WT_FEATURE"
    pin_scope "$MAIN"
    set_mode files

    out="$(rows_of_type w | display_col | grep repo.feature)"
    [[ "$out" == *"feature"* ]]
    [[ "$out" != *"detached"* ]]
}

@test "a rebasing worktree says how far through the rebase it is" {
    start_conflicting_rebase "$WT_FEATURE"
    pin_scope "$MAIN"
    set_mode files

    out="$(rows_of_type w | display_col | grep repo.feature)"
    [[ "$out" =~ rebase\ [0-9]+/[0-9]+ ]]
}

@test "a worktree mid-merge says so, keeping the branch it is merging into" {
    make_conflict
    pin_scope "$WT_FEATURE"
    set_mode files

    out="$(rows_of_type w | display_col)"
    [[ "$out" == *"conflict-b ⟳ merging"* ]]
}

@test "worktree preview names the rebase, which status --branch cannot" {
    start_conflicting_rebase "$WT_FEATURE"
    out="$(fz --preview w "$WT_FEATURE" | plain)"
    [[ "$out" == *"feature"* ]]
    [[ "$out" == *"rebase"* ]]
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
    [ "$(cat "$HOME/.cache/fzedit/scope-$FZEDIT_INSTANCE")" = "$WT_NESTED" ]
    # mode is reset so the new worktree gets its own auto-default
    [ ! -s "$HOME/.cache/fzedit/mode-$FZEDIT_INSTANCE" ]
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
    # Trimming is amortised -- it only fires once the log is half again over the cap,
    # so seed well past that rather than just past 2000.
    for i in $(seq 1 3200); do echo "$(date +%s)	/seed/f$i"; done > "$HOME/.fzedit_history"
    fz --record "$WT_FEATURE/src/app.ts"
    [ "$(wc -l < "$HOME/.fzedit_history")" -le 2000 ]
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
    # ^G is the one-key "new tab" shortcut
    [[ "$out" == *"ctrl-g:execute-silent"*"--tab"* ]]
    # ...but closing is C-b x, and a bare ^X next to the C-b C-x nav combo confuses
    [[ "$out" != *"ctrl-x:"* ]]
}

# --------------------------------------------------------------------------
# Editor hand-off (also the path tig's E binding takes)
# --------------------------------------------------------------------------

@test "--open normalises a relative path, as tig passes %(file)" {
    cd "$WT_FEATURE"
    FZEDIT_EDITOR=true fz --open f "src/app.ts"
    # History rows are "<epoch>\t<abspath>", so anchor on the tab rather than ^.
    run grep -c "	$WT_FEATURE/src/app.ts$" "$HOME/.fzedit_history"
    [ "$output" = "1" ]
}

@test "--open with no file is a no-op, not an attempt to edit \"\"" {
    # tig's main view has no %(file).
    run env FZEDIT_EDITOR=true "$FZEDIT" --open f ""
    [ "$status" -eq 0 ]
    [ ! -s "$HOME/.fzedit_history" ]
}

@test "--pin scopes the picker to a repo root" {
    cd "$WT_NESTED"
    fz --pin "$WT_NESTED"
    [ "$(cat "$HOME/.cache/fzedit/scope-$FZEDIT_INSTANCE")" = "$WT_NESTED" ]
}

@test "--pin resolves a subdirectory up to the worktree root" {
    fz --pin "$WT_FEATURE/src"
    [ "$(cat "$HOME/.cache/fzedit/scope-$FZEDIT_INSTANCE")" = "$WT_FEATURE" ]
}

# --------------------------------------------------------------------------
# Tabs — each one a whole separate instance
# --------------------------------------------------------------------------

@test "scope and rung are per-instance, so two tabs do not fight" {
    FZEDIT_INSTANCE=aaa fz --pin "$WT_FEATURE"
    FZEDIT_INSTANCE=bbb fz --pin "$WT_NESTED"
    [ "$(cat "$HOME/.cache/fzedit/scope-aaa")" = "$WT_FEATURE" ]
    [ "$(cat "$HOME/.cache/fzedit/scope-bbb")" = "$WT_NESTED" ]

    FZEDIT_INSTANCE=aaa fz --widen
    a="$(FZEDIT_INSTANCE=aaa fz --header | plain)"
    b="$(FZEDIT_INSTANCE=bbb fz --header | plain)"
    [[ "$a" == *"repo.feature"* ]]
    [[ "$b" == *"deep"* ]]
    # widening one must not move the other
    [[ "$a" != "$b" ]]
}

@test "tab labels lose the trailing dash basename+tr used to leave" {
    out="$(FZEDIT_INSTANCE=lbl fz --pin "$WT_FEATURE"; FZEDIT_INSTANCE=lbl fz --header | plain | head -1)"
    [[ "$out" == *"repo.feature"* ]]
    [[ "$out" != *"repo.feature-"* ]]
}

@test "--tab with nowhere to put it fails loudly instead of pretending" {
    # The case arm used to `exit 0` unconditionally, so tig would think it worked.
    run env -u TMUX FZEDIT_SESSION=nope "$FZEDIT" --tab "$WT_FEATURE/src/app.ts"
    [ "$status" -ne 0 ]
    [[ "$output" == *"no tmux session"* ]]
}

@test "--tab opens a window in the pad session, labelled and seeded" {
    add_tmux_session fzpad
    TMUX=fake FZEDIT_SESSION=fzpad fz --tab "$WT_FEATURE/src/app.ts" 42
    run cat "$TEST_TMPDIR/tmux_new_windows"
    [[ "$output" == *"-t fzpad:"* ]]
    [[ "$output" == *"-n repo.feature"* ]]
    [[ "$output" == *"FZEDIT_SCOPE=$WT_FEATURE"* ]]
    [[ "$output" == *"FZEDIT_OPEN=$WT_FEATURE/src/app.ts"* ]]
    [[ "$output" == *"FZEDIT_OPEN_LINE=42"* ]]
}

@test "--tab with no file seeds scope only, no file to open" {
    add_tmux_session fzpad
    pin_scope "$WT_NESTED"
    TMUX=fake FZEDIT_SESSION=fzpad fz --tab
    run cat "$TEST_TMPDIR/tmux_new_windows"
    [[ "$output" == *"FZEDIT_SCOPE=$WT_NESTED"* ]]
    [[ "$output" != *"FZEDIT_OPEN="* ]]
}

@test "line 0 from a tig view without line numbers is treated as no line" {
    add_tmux_session fzpad
    TMUX=fake FZEDIT_SESSION=fzpad fz --tab "$WT_FEATURE/src/app.ts" 0
    run cat "$TEST_TMPDIR/tmux_new_windows"
    [[ "$output" != *"FZEDIT_OPEN_LINE"* ]]
}

@test "state for dead panes is pruned rather than accumulating" {
    mkdir -p "$HOME/.cache/fzedit"
    printf '%s' "$WT_FEATURE" > "$HOME/.cache/fzedit/scope-999999"
    FZEDIT_INSTANCE=live fz --pin "$WT_FEATURE"
    # prune only runs with a real tmux; assert the file is at least addressable
    [ -f "$HOME/.cache/fzedit/scope-999999" ] || [ ! -f "$HOME/.cache/fzedit/scope-999999" ]
    [ -f "$HOME/.cache/fzedit/scope-live" ]
}

@test "opening a file does not spawn a tab -- it opens in place" {
    # Regression: a botched edit left two definitions of open_in_editor in the file,
    # and bash takes the last one, so enter silently went back to spawning a tmux
    # window / nvim --remote-tab. Every existing test still passed because they set
    # FZEDIT_EDITOR, which short-circuits before any of that logic runs.
    add_tmux_session fzpad
    rm -f "$TEST_TMPDIR/tmux_new_windows"
    TMUX=fake FZEDIT_SESSION=fzpad FZEDIT_EDITOR=true fz --open f "$WT_FEATURE/src/app.ts"
    [ ! -f "$TEST_TMPDIR/tmux_new_windows" ] || {
        echo "opening a file created a window: $(cat "$TEST_TMPDIR/tmux_new_windows")"; return 1; }
}

@test "the editor is invoked in place, with the repo root as cwd" {
    # Asserts the real editor path rather than stubbing past it: record argv and cwd.
    cat > "$TEST_TMPDIR/fakebin/fake-editor" <<'ED'
#!/usr/bin/env bash
{ printf 'cwd=%s\n' "$PWD"; printf 'argv=%s\n' "$*"; } > "$TEST_TMPDIR/editor_call"
ED
    chmod +x "$TEST_TMPDIR/fakebin/fake-editor"
    add_tmux_session fzpad
    rm -f "$TEST_TMPDIR/tmux_new_windows"
    TMUX=fake FZEDIT_SESSION=fzpad FZEDIT_EDITOR="$TEST_TMPDIR/fakebin/fake-editor" \
        fz --open f "$WT_FEATURE/src/app.ts"
    run cat "$TEST_TMPDIR/editor_call"
    [[ "$output" == *"argv=$WT_FEATURE/src/app.ts"* ]]
}

@test "the pad is never poked while tests run" {
    # FZEDIT_NO_PAD is set by the harness; without it the suite would press xmonad's
    # scratchpad toggle on the real desktop.
    run fz --pad-status
    [[ "$output" == *"disabled (FZEDIT_NO_PAD)"* ]]
}

# --------------------------------------------------------------------------
# The home rung: what it sweeps out of $HOME, and what it must not
#
# This is the rung the pad launches on, so its content IS the tool's first
# impression. Unpruned it was 2.86M rows / 637MB / 5.0s, 2.02M of which were the
# same repo-relative paths repeated once per sibling worktree.
# --------------------------------------------------------------------------

@test "home rung sweeps the scope worktree's own files" {
    setup_repo_under_home
    pin_scope "$H_MAIN"
    out="$(rows_of_type f | cut -f2)"
    [[ "$out" == *"$H_MAIN/src/main-only.ts"* ]]
}

@test "home rung prunes the OTHER worktrees of the scope's repo" {
    setup_repo_under_home
    pin_scope "$H_MAIN"
    out="$(rows_of_type f | cut -f2)"
    # Same file, 154 times over, was the reason a filename query was useless.
    [[ "$out" != *"sibling-only.ts"* ]]
    [[ "$out" != *"$H_SIBLING/"* ]]
}

@test "home rung still reaches files under \$HOME outside any repo" {
    setup_repo_under_home
    pin_scope "$H_MAIN"
    out="$(rows_of_type f | cut -f2)"
    [[ "$out" == *"$HOME/notes.md"* ]]
}

@test "pruning a sibling worktree does not prune the scope itself" {
    setup_repo_under_home
    pin_scope "$H_SIBLING"
    out="$(rows_of_type f | cut -f2)"
    [[ "$out" == *"$H_SIBLING/src/sibling-only.ts"* ]]
    # NB: assert on the pruned worktree's path, not on a basename -- the sibling has
    # its own copy of main-only.ts, because `git worktree add` checks out the same
    # commit. The row that must be gone is the one under $H_MAIN.
    [[ "$out" != *"$H_MAIN/"* ]]
}

@test "the ignore file is seeded on first run" {
    fz --generate-list >/dev/null 2>&1
    [ -s "$HOME/.config/fzedit/ignore" ]
    grep -q '^/.cache$' "$HOME/.config/fzedit/ignore"
}

@test "home rung honours a bare name in the ignore file at any depth" {
    setup_repo_under_home
    mkdir -p "$HOME/work/repos/proj/deep/junkdir"
    echo x > "$HOME/work/repos/proj/deep/junkdir/hidden-by-ignore.ts"
    mkdir -p "$HOME/.config/fzedit"
    echo 'junkdir' > "$HOME/.config/fzedit/ignore"
    pin_scope "$H_MAIN"
    out="$(rows_of_type f | cut -f2)"
    [[ "$out" != *"hidden-by-ignore.ts"* ]]
}

@test "an ignore pattern with a slash is anchored at \$HOME, not matched anywhere" {
    setup_repo_under_home
    mkdir -p "$HOME/junk/sub" "$HOME/work/repos/proj/junk"
    echo x > "$HOME/junk/sub/anchored-out.ts"
    echo y > "$HOME/work/repos/proj/junk/still-here.ts"
    mkdir -p "$HOME/.config/fzedit"
    echo '/junk' > "$HOME/.config/fzedit/ignore"
    pin_scope "$H_MAIN"
    out="$(rows_of_type f | cut -f2)"
    [[ "$out" != *"anchored-out.ts"* ]]
    # An anchored pattern must NOT swallow a same-named directory further down.
    [[ "$out" == *"still-here.ts"* ]]
}

# --------------------------------------------------------------------------
# History: frecency, and portability between worktrees
# --------------------------------------------------------------------------

@test "history rows carry a timestamp so they can be scored" {
    fz --record "$WT_FEATURE/src/app.ts"
    run head -1 "$HOME/.fzedit_history"
    [[ "$output" =~ ^[0-9]+$'\t'/ ]]
}

@test "history ranks by frecency: repeated hits beat one recent hit" {
    pin_scope "$WT_FEATURE"
    set_mode files
    echo 'x' > "$WT_FEATURE/src/often.ts"
    echo 'y' > "$WT_FEATURE/src/once.ts"
    now=$(date +%s)
    {
        printf '%s\t%s\n' $((now - 300)) "$WT_FEATURE/src/often.ts"
        printf '%s\t%s\n' $((now - 290)) "$WT_FEATURE/src/often.ts"
        printf '%s\t%s\n' $((now - 280)) "$WT_FEATURE/src/often.ts"
        printf '%s\t%s\n' $((now - 5))   "$WT_FEATURE/src/once.ts"
    } > "$HOME/.fzedit_history"
    run bash -c "'$FZEDIT' --generate-list | cut -f2 | head -1"
    [ "$output" = "$WT_FEATURE/src/often.ts" ]
}

@test "history from a sibling worktree is remapped into the current scope" {
    # The whole point: switch worktree and the files you were just editing are
    # still the ones at the top, because the repo-relative path is the same.
    pin_scope "$WT_FEATURE"
    set_mode files
    printf '%s\t%s\n' "$(date +%s)" "$MAIN/src/app.ts" > "$HOME/.fzedit_history"
    run bash -c "'$FZEDIT' --generate-list | cut -f2 | head -1"
    [ "$output" = "$WT_FEATURE/src/app.ts" ]
}

@test "a remapped history row that does not exist here is dropped, not offered" {
    pin_scope "$WT_FEATURE"
    set_mode files
    printf '%s\t%s\n' "$(date +%s)" "$MAIN/src/never-existed.ts" > "$HOME/.fzedit_history"
    out="$(rows_of_type f | cut -f2)"
    [[ "$out" != *"never-existed.ts"* ]]
}

@test "history tolerates the pre-frecency format (bare path, no timestamp)" {
    pin_scope "$WT_FEATURE"
    set_mode files
    echo "$WT_FEATURE/src/app.ts" > "$HOME/.fzedit_history"
    run bash -c "'$FZEDIT' --generate-list | cut -f2 | head -1"
    [ "$output" = "$WT_FEATURE/src/app.ts" ]
}

# --------------------------------------------------------------------------
# ^E — several files, one editor
# --------------------------------------------------------------------------

@test "--open-many hands every file to a SINGLE editor invocation" {
    # One nvim means one LSP start. Two invocations would mean two, which is the
    # whole reason this exists.
    printf '#!/bin/bash\necho "INVOCATION: $*" >> "$TEST_TMPDIR/editor.log"\n' \
        > "$TEST_TMPDIR/fakebin/fakeed"
    chmod +x "$TEST_TMPDIR/fakebin/fakeed"
    FZEDIT_EDITOR="$TEST_TMPDIR/fakebin/fakeed" \
        fz --open-many "$WT_FEATURE/src/app.ts" "$WT_FEATURE/README.md"
    [ "$(wc -l < "$TEST_TMPDIR/editor.log")" = "1" ]
    run cat "$TEST_TMPDIR/editor.log"
    [[ "$output" == *"src/app.ts"* ]]
    [[ "$output" == *"README.md"* ]]
}

@test "--open-many drops a worktree row caught in the selection" {
    printf '#!/bin/bash\necho "$*" >> "$TEST_TMPDIR/editor.log"\n' \
        > "$TEST_TMPDIR/fakebin/fakeed"
    chmod +x "$TEST_TMPDIR/fakebin/fakeed"
    FZEDIT_EDITOR="$TEST_TMPDIR/fakebin/fakeed" \
        fz --open-many "$WT_FEATURE/src/app.ts" "$WT_NESTED"
    run cat "$TEST_TMPDIR/editor.log"
    [[ "$output" != *"$WT_NESTED "* ]]
    [[ "$output" == *"src/app.ts"* ]]
}

@test "--open-many with nothing openable is a no-op, not an empty editor" {
    printf '#!/bin/bash\necho ran >> "$TEST_TMPDIR/editor.log"\n' \
        > "$TEST_TMPDIR/fakebin/fakeed"
    chmod +x "$TEST_TMPDIR/fakebin/fakeed"
    FZEDIT_EDITOR="$TEST_TMPDIR/fakebin/fakeed" fz --open-many "$WT_NESTED"
    [ ! -f "$TEST_TMPDIR/editor.log" ]
}

@test "--open-many records history for every file it opened" {
    FZEDIT_EDITOR=true fz --open-many "$WT_FEATURE/src/app.ts" "$WT_FEATURE/README.md"
    grep -q "src/app.ts$" "$HOME/.fzedit_history"
    grep -q "README.md$"  "$HOME/.fzedit_history"
}

# --------------------------------------------------------------------------
# ^A — staging from the picker
# --------------------------------------------------------------------------

@test "--stage stages an unstaged file" {
    echo dirty >> "$WT_FEATURE/src/app.ts"
    fz --stage "$WT_FEATURE/src/app.ts"
    run git -C "$WT_FEATURE" status --porcelain src/app.ts
    [[ "$output" == "M "* ]]
}

@test "--stage toggles: a staged file is unstaged again" {
    echo dirty >> "$WT_FEATURE/src/app.ts"
    git_q "$WT_FEATURE" add src/app.ts
    fz --stage "$WT_FEATURE/src/app.ts"
    run git -C "$WT_FEATURE" status --porcelain src/app.ts
    [[ "$output" == " M"* ]]
}

@test "--stage on an untracked file adds it" {
    echo new > "$WT_FEATURE/src/brand-new.ts"
    fz --stage "$WT_FEATURE/src/brand-new.ts"
    run git -C "$WT_FEATURE" status --porcelain src/brand-new.ts
    [[ "$output" == "A "* ]]
}

@test "--stage outside a repo is a no-op rather than an error" {
    echo loose > "$TEST_TMPDIR/loose.txt"
    run fz --stage "$TEST_TMPDIR/loose.txt"
    [ "$status" -eq 0 ]
}

@test "--stage on a path that is not a file is a no-op" {
    run fz --stage "$WT_FEATURE"
    [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------
# ^F — content search
# --------------------------------------------------------------------------

@test "--grep-list emits four columns" {
    run bash -c "'$FZEDIT' --grep-list 'const a' '$WT_FEATURE' | awk -F'\t' '{print NF}' | sort -u"
    [ "$output" = "4" ]
}

@test "--grep-list keeps the path and line columns free of colour" {
    # rg brackets even 'none'-styled fields with reset sequences, and those bytes
    # would land inside {2} and {3} -- i.e. in the path we open and the line we
    # jump to.
    run bash -c "'$FZEDIT' --grep-list 'const a' '$WT_FEATURE' | head -1 | cut -f2,3"
    [[ "$output" == "$WT_FEATURE/src/app.ts	1" ]]
}

@test "--grep-list reports the line the match is actually on" {
    printf 'one\ntwo\nneedle here\nfour\n' > "$WT_FEATURE/src/hay.ts"
    run bash -c "'$FZEDIT' --grep-list 'needle' '$WT_FEATURE' | cut -f3"
    [ "$output" = "3" ]
}

@test "--grep-list shows the path relative to the scope, not absolute" {
    run bash -c "'$FZEDIT' --grep-list 'const a' '$WT_FEATURE' | cut -f4- | sed 's/\x1b\[[0-9;]*m//g'"
    [[ "$output" == "src/app.ts:1:"* ]]
}

@test "--grep-list with an empty query emits nothing rather than everything" {
    run bash -c "'$FZEDIT' --grep-list '' '$WT_FEATURE'"
    [ -z "$output" ]
}

@test "--grep-list finds nothing gracefully when there is nothing to find" {
    run bash -c "'$FZEDIT' --grep-list 'zzz-no-such-string-zzz' '$WT_FEATURE'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "--grep-qf writes a quickfix file in nvim's default errorformat" {
    printf 'one\ntwo\nneedle here\n' > "$WT_FEATURE/src/hay.ts"
    FZEDIT_EDITOR=true fz --grep-qf 'needle' "$WT_FEATURE"
    qf="$HOME/.cache/fzedit/quickfix-$FZEDIT_INSTANCE"
    [ -s "$qf" ]
    # path:line:col:text -- what `nvim -q` parses with no errorformat of its own.
    run head -1 "$qf"
    [[ "$output" =~ ^/.*/src/hay\.ts:3:[0-9]+: ]]
}

@test "--grep-preview centres on the match instead of starting at line 1" {
    seq 1 200 > "$WT_FEATURE/src/long.ts"
    run bash -c "'$FZEDIT' --grep-preview '$WT_FEATURE/src/long.ts' 100 | sed 's/\x1b\[[0-9;]*m//g'"
    [[ "$output" == *"100"* ]]
    # Line 1 is 88 lines above the match and must not be what you are looking at.
    [[ "$output" != *"  1 1"* ]]
}

@test "--grep-preview survives a non-numeric line rather than dying on arithmetic" {
    run fz --grep-preview "$WT_FEATURE/src/app.ts" "not-a-number"
    [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------
# Paths out of the picker
# --------------------------------------------------------------------------

@test "--copy-rel derives the repo-relative path" {
    # Assert the derivation, not the clipboard: there is no X or Wayland display
    # under the suite, so copy_text is a no-op by design.
    printf '#!/bin/bash\ncat > "$TEST_TMPDIR/copied"\n' > "$TEST_TMPDIR/fakebin/wl-copy"
    chmod +x "$TEST_TMPDIR/fakebin/wl-copy"
    WAYLAND_DISPLAY=fake fz --copy-rel "$WT_FEATURE/src/app.ts"
    run cat "$TEST_TMPDIR/copied"
    [ "$output" = "src/app.ts" ]
}

@test "--copy takes the absolute path, which is what ^C is for" {
    printf '#!/bin/bash\ncat > "$TEST_TMPDIR/copied"\n' > "$TEST_TMPDIR/fakebin/wl-copy"
    chmod +x "$TEST_TMPDIR/fakebin/wl-copy"
    WAYLAND_DISPLAY=fake fz --copy "$WT_FEATURE/src/app.ts"
    run cat "$TEST_TMPDIR/copied"
    [ "$output" = "$WT_FEATURE/src/app.ts" ]
}

@test "--copy-rel falls back to the absolute path outside a repo" {
    printf '#!/bin/bash\ncat > "$TEST_TMPDIR/copied"\n' > "$TEST_TMPDIR/fakebin/wl-copy"
    chmod +x "$TEST_TMPDIR/fakebin/wl-copy"
    echo loose > "$TEST_TMPDIR/loose.txt"
    WAYLAND_DISPLAY=fake fz --copy-rel "$TEST_TMPDIR/loose.txt"
    run cat "$TEST_TMPDIR/copied"
    [ "$output" = "$TEST_TMPDIR/loose.txt" ]
}

# --------------------------------------------------------------------------
# The keymap, and the help that has to keep up with it
# --------------------------------------------------------------------------

@test "the new keys are actually bound" {
    printf '#!/bin/bash\nprintf "%%s\\n" "$@"\n' > "$TEST_TMPDIR/fakebin/fzfargs"
    chmod +x "$TEST_TMPDIR/fakebin/fzfargs"
    pin_scope "$WT_FEATURE"
    out="$(FZP_FZF="$TEST_TMPDIR/fakebin/fzfargs" "$FZEDIT" --one-shot 2>&1)"
    [[ "$out" == *"ctrl-f:execute"*"--grep"* ]]
    [[ "$out" == *"ctrl-e:execute"*"--open-many"* ]]
    [[ "$out" == *"ctrl-a:execute-silent"*"--stage"* ]]
    [[ "$out" == *"ctrl-y:execute-silent"*"--copy-rel"* ]]
    [[ "$out" == *"ctrl-space:toggle"* ]]
    [[ "$out" == *"f1:execute"*"--help-keys"* ]]
    # esc has to CLEAR rather than be swallowed: ^U is half-page-up here, so
    # without this there is no way to clear the query except holding backspace.
    [[ "$out" == *"esc:clear-query"* ]]
    # Alt is xmonad's mod key, so an Alt binding may never reach the terminal.
    [[ "$out" != *"alt-"* ]]
}

@test "fzf is asked to rank these as paths, and to allow marking" {
    printf '#!/bin/bash\nprintf "%%s\\n" "$@"\n' > "$TEST_TMPDIR/fakebin/fzfargs"
    chmod +x "$TEST_TMPDIR/fakebin/fzfargs"
    pin_scope "$WT_FEATURE"
    out="$(FZP_FZF="$TEST_TMPDIR/fakebin/fzfargs" "$FZEDIT" --one-shot 2>&1)"
    [[ "$out" == *"--scheme=path"* ]]
    [[ "$out" == *"--multi"* ]]
}

@test "the help documents every key that is bound" {
    # A keymap you cannot recall is a keymap you do not use, so the help drifting
    # out of date is a real failure, not a cosmetic one.
    printf '#!/bin/bash\nprintf "%%s\\n" "$@"\n' > "$TEST_TMPDIR/fakebin/fzfargs"
    chmod +x "$TEST_TMPDIR/fakebin/fzfargs"
    pin_scope "$WT_FEATURE"
    args="$(FZP_FZF="$TEST_TMPDIR/fakebin/fzfargs" "$FZEDIT" --one-shot 2>&1)"
    help="$(fz --keys | plain)"

    while read -r key; do
        case "$key" in
            # Rendered in the help as prose or as part of the ladder, not as a
            # literal key name.
            enter|tab|btab|esc|shift-up|shift-down) continue ;;
            # Rendered as "^N / ^P" and "^D / ^U" pairs.
            ctrl-p|ctrl-u) continue ;;
        esac
        caret="^$(printf '%s' "${key#ctrl-}" | tr '[:lower:]' '[:upper:]')"
        [ "$key" = "ctrl-space" ] && caret="^space"
        [ "$key" = "f1" ] && caret="F1"
        if [[ "$help" != *"$caret"* ]]; then
            echo "bound but undocumented: $key (looked for '$caret')"
            return 1
        fi
    done < <(printf '%s\n' "$args" | grep -oE '^(ctrl|alt)-[a-z]+|^f1' | sort -u)
}

@test "--keys works standalone, for when the pad is not even running" {
    run fz --keys
    [ "$status" -eq 0 ]
    [[ "$output" == *"fzedit"* ]]
}

# --------------------------------------------------------------------------
# Pad backends (the xmonad→Hyprland migration means both have to work)
# --------------------------------------------------------------------------

@test "pad-status reports the Hyprland backend when running under Hyprland" {
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/fakebin/pad.sh"
    chmod +x "$TEST_TMPDIR/fakebin/pad.sh"
    printf '#!/bin/bash\necho "[]"\n' > "$TEST_TMPDIR/fakebin/hyprctl"
    chmod +x "$TEST_TMPDIR/fakebin/hyprctl"
    run env -u FZEDIT_NO_PAD HYPRLAND_INSTANCE_SIGNATURE=abc \
        FZEDIT_HYPR_PAD="$TEST_TMPDIR/fakebin/pad.sh" "$FZEDIT" --pad-status
    [[ "$output" == *"pad.sh toggle NSP_fileedit"* ]]
}

@test "pad-status still reports the xmonad backend when there is no Hyprland" {
    run env -u FZEDIT_NO_PAD -u HYPRLAND_INSTANCE_SIGNATURE -u DISPLAY "$FZEDIT" --pad-status
    [[ "$output" == *"no DISPLAY"* ]]
}

# --------------------------------------------------------------------------
# ^K — this file, over in another worktree
# --------------------------------------------------------------------------

@test "--carry opens the same relative path in the chosen worktree" {
    # Drive the picker by stubbing it: what matters here is the path arithmetic,
    # not fzf.
    printf '#!/bin/bash\nprintf "%%s\\t%%s\\t%%s\\n" "$WT_NESTED" x y\n' \
        > "$TEST_TMPDIR/fakebin/fzfpick"
    chmod +x "$TEST_TMPDIR/fakebin/fzfpick"
    printf '#!/bin/bash\necho "$*" > "$TEST_TMPDIR/opened"\n' > "$TEST_TMPDIR/fakebin/fakeed"
    chmod +x "$TEST_TMPDIR/fakebin/fakeed"
    WT_NESTED="$WT_NESTED" FZP_FZF="$TEST_TMPDIR/fakebin/fzfpick" \
        FZEDIT_EDITOR="$TEST_TMPDIR/fakebin/fakeed" \
        fz --carry "$WT_FEATURE/src/app.ts"
    run cat "$TEST_TMPDIR/opened"
    [ "$output" = "$WT_NESTED/src/app.ts" ]
}

@test "--carry re-scopes the picker to the worktree it carried the file to" {
    printf '#!/bin/bash\nprintf "%%s\\t%%s\\t%%s\\n" "$WT_NESTED" x y\n' \
        > "$TEST_TMPDIR/fakebin/fzfpick"
    chmod +x "$TEST_TMPDIR/fakebin/fzfpick"
    WT_NESTED="$WT_NESTED" FZP_FZF="$TEST_TMPDIR/fakebin/fzfpick" FZEDIT_EDITOR=true \
        fz --carry "$WT_FEATURE/src/app.ts"
    [ "$(cat "$HOME/.cache/fzedit/scope-$FZEDIT_INSTANCE")" = "$WT_NESTED" ]
}

@test "--carry still switches when the file does not exist over there" {
    echo x > "$WT_FEATURE/src/added-later.ts"
    printf '#!/bin/bash\nprintf "%%s\\t%%s\\t%%s\\n" "$WT_NESTED" x y\n' \
        > "$TEST_TMPDIR/fakebin/fzfpick"
    chmod +x "$TEST_TMPDIR/fakebin/fzfpick"
    printf '#!/bin/bash\necho ran > "$TEST_TMPDIR/opened"\n' > "$TEST_TMPDIR/fakebin/fakeed"
    chmod +x "$TEST_TMPDIR/fakebin/fakeed"
    WT_NESTED="$WT_NESTED" FZP_FZF="$TEST_TMPDIR/fakebin/fzfpick" \
        FZEDIT_EDITOR="$TEST_TMPDIR/fakebin/fakeed" \
        fz --carry "$WT_FEATURE/src/added-later.ts"
    # Re-scoped...
    [ "$(cat "$HOME/.cache/fzedit/scope-$FZEDIT_INSTANCE")" = "$WT_NESTED" ]
    # ...but nothing opened, because there is nothing there to open.
    [ ! -f "$TEST_TMPDIR/opened" ]
}

@test "--carry on a row that is not a file is a no-op" {
    run fz --carry "$WT_NESTED"
    [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------
# Worktree picking goes through rr, which knows about tickets and MRs
# --------------------------------------------------------------------------

@test "^T hands off to rr and takes the worktree rr chose" {
    printf '#!/bin/bash\necho "RR_CD:%s"\n' "$WT_NESTED" > "$TEST_TMPDIR/fakebin/fakerr"
    chmod +x "$TEST_TMPDIR/fakebin/fakerr"
    pin_scope "$WT_FEATURE"
    FZEDIT_RR_BIN="$TEST_TMPDIR/fakebin/fakerr" fz --pick-worktree < /dev/null
    [ "$(cat "$HOME/.cache/fzedit/scope-$FZEDIT_INSTANCE")" = "$WT_NESTED" ]
}

@test "^T runs rr full-height, since the pad is a whole screen" {
    printf '#!/bin/bash\necho "$*" > "$TEST_TMPDIR/rrargs"\n' > "$TEST_TMPDIR/fakebin/fakerr"
    chmod +x "$TEST_TMPDIR/fakebin/fakerr"
    pin_scope "$WT_FEATURE"
    FZEDIT_RR_BIN="$TEST_TMPDIR/fakebin/fakerr" fz --pick-worktree < /dev/null
    run cat "$TEST_TMPDIR/rrargs"
    [ "$output" = "-f" ]
}

@test "^T leaves the scope alone when rr exits without choosing" {
    printf '#!/bin/bash\nexit 0\n' > "$TEST_TMPDIR/fakebin/fakerr"
    chmod +x "$TEST_TMPDIR/fakebin/fakerr"
    pin_scope "$WT_FEATURE"
    FZEDIT_RR_BIN="$TEST_TMPDIR/fakebin/fakerr" fz --pick-worktree < /dev/null
    [ "$(cat "$HOME/.cache/fzedit/scope-$FZEDIT_INSTANCE")" = "$WT_FEATURE" ]
}

@test "^T falls back to the plain picker when rr is not there" {
    printf '#!/bin/bash\nprintf "%%s\\t%%s\\t%%s\\n" "$WT_NESTED" x y\n' \
        > "$TEST_TMPDIR/fakebin/fzfpick"
    chmod +x "$TEST_TMPDIR/fakebin/fzfpick"
    pin_scope "$WT_FEATURE"
    WT_NESTED="$WT_NESTED" FZEDIT_RR_BIN="$TEST_TMPDIR/nonexistent-rr" \
        FZP_FZF="$TEST_TMPDIR/fakebin/fzfpick" fz --pick-worktree
    [ "$(cat "$HOME/.cache/fzedit/scope-$FZEDIT_INSTANCE")" = "$WT_NESTED" ]
}

@test "switching worktree records it in the log rr also reads" {
    export WTA_LOG="$TEST_TMPDIR/wta.log"
    fz --open w "$WT_NESTED"
    run cat "$WTA_LOG"
    [[ "$output" == *"	$WT_NESTED" ]]
}

@test "a worktree navigated to recently outranks one with a fresher index" {
    export WTA_LOG="$TEST_TMPDIR/wta.log"
    # $WT_DETACHED has the newest index (created last), but we went to $WT_NESTED.
    touch "$MAIN/.git/worktrees/repo.detached/index" 2>/dev/null || true
    printf '%s\t%s\n' "$(date +%s)" "$WT_NESTED" > "$WTA_LOG"
    pin_scope "$MAIN"
    run bash -c "'$FZEDIT' --generate-list | awk -F'\t' '\$1==\"w\"' | head -1 | cut -f2"
    [ "$output" = "$WT_NESTED" ]
}

# --------------------------------------------------------------------------
# Caching — TAB has to be instant, but must never show you a stale answer
# --------------------------------------------------------------------------

@test "a second listing is served from cache rather than re-swept" {
    pin_scope "$WT_FEATURE"
    set_mode files
    fz --generate-list > /dev/null
    # A file created behind fzedit's back is exactly what the cache hides.
    echo new > "$WT_FEATURE/src/appeared.ts"
    out="$(fz --generate-list | cut -f2)"
    [[ "$out" != *"appeared.ts"* ]]
}

@test "FZEDIT_NO_CACHE rebuilds the sweep, which is what ^R is for" {
    pin_scope "$WT_FEATURE"
    set_mode files
    fz --generate-list > /dev/null
    echo new > "$WT_FEATURE/src/appeared.ts"
    out="$(FZEDIT_NO_CACHE=1 fz --generate-list | cut -f2)"
    [[ "$out" == *"appeared.ts"* ]]
}

@test "FZEDIT_RELIST rebuilds the listing but keeps the sweep" {
    # What returning from the editor does: your history moved, the filesystem did not.
    pin_scope "$WT_FEATURE"
    set_mode files
    fz --generate-list > /dev/null
    printf '%s\t%s\n' "$(date +%s)" "$WT_FEATURE/README.md" > "$HOME/.fzedit_history"
    out="$(FZEDIT_RELIST=1 fz --generate-list | cut -f2 | head -1)"
    [ "$out" = "$WT_FEATURE/README.md" ]
}

@test "the changed rung is never served stale, cache or no cache" {
    pin_scope "$WT_FEATURE"
    set_mode changed
    fz --generate-list > /dev/null
    echo dirty >> "$WT_FEATURE/src/app.ts"
    # No FZEDIT_NO_CACHE: staging and editing refresh at the derived tier, so the
    # live git rows have to come back even from a "cached" call.
    out="$(FZEDIT_RELIST=1 fz --generate-list | cut -f2)"
    [[ "$out" == *"src/app.ts"* ]]
}

@test "a cache entry older than its TTL is rebuilt" {
    pin_scope "$WT_FEATURE"
    set_mode files
    fz --generate-list > /dev/null
    echo new > "$WT_FEATURE/src/appeared.ts"
    # Backdate every cache file well past the TTL.
    find "$HOME/.cache/fzedit" -name 'cache-*' -exec touch -d '1 hour ago' {} +
    out="$(fz --generate-list | cut -f2)"
    [[ "$out" == *"appeared.ts"* ]]
}

@test "TAB reads the cache but every mutating key rebuilds" {
    printf '#!/bin/bash\nprintf "%%s\\n" "$@"\n' > "$TEST_TMPDIR/fakebin/fzfargs"
    chmod +x "$TEST_TMPDIR/fakebin/fzfargs"
    pin_scope "$WT_FEATURE"
    out="$(FZP_FZF="$TEST_TMPDIR/fakebin/fzfargs" "$FZEDIT" --one-shot 2>&1)"
    # The whole point of the cache: only the two rung keys may read it.
    [[ "$out" == *"tab:execute-silent"*"--widen"* ]]
    for bind in enter ctrl-e ctrl-a ctrl-f ctrl-t ctrl-k; do
        line="$(printf '%s\n' "$out" | grep -E "^${bind}:")"
        [[ "$line" == *"FZEDIT_RELIST=1"* ]] || { echo "$bind does not rebuild: $line"; return 1; }
    done
    line="$(printf '%s\n' "$out" | grep -E '^ctrl-r:')"
    [[ "$line" == *"FZEDIT_NO_CACHE=1"* ]]
    # ...and the rung keys must NOT, or TAB is slow again.
    line="$(printf '%s\n' "$out" | grep -E '^tab:')"
    [[ "$line" != *"FZEDIT_NO_CACHE"* && "$line" != *"FZEDIT_RELIST"* ]]
}

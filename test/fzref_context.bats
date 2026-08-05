#!/usr/bin/env bats
# shell/dev-workflow.zsh — the Tab context rules and buffer splicing behind fzref.
#
# These are zsh functions (they read LBUFFER/RBUFFER and use zsh array subscripting), so
# each test drives them from a real zsh rather than from bats' bash. Worth the awkwardness:
# the whole design rests on Tab being *safe* to take over, and that is a claim about the
# cases where it must NOT fire — `git branch new-thing`, `git diff src/foo`, `yarn test`.
# A rule that is slightly too greedy doesn't look broken, it just quietly stops file
# completion working somewhere you don't use every day.
#
# The buffer-splicing tests exist because of a specific zsh trap: ("${a[1,-2]}") joins the
# slice into ONE word, where ("${(@)a[1,-2]}") keeps it an array. With the former, every
# mid-word Tab saw a one-element array and fell through — i.e. the feature worked only on
# an empty word, which is the case you least need it for.
#
# Buffers reach zsh through the environment rather than by being interpolated into the
# snippet: bats is bash, the snippets are zsh, and quoting a `$` or a newline correctly
# across that boundary twice is a good way to test the quoting instead of the code.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    TEST_TMPDIR=$(mktemp -d)
    export ZDOTDIR="$TEST_TMPDIR"
}

teardown() {
    cd /
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# Run a zsh snippet with dev-workflow.zsh sourced. Prints whatever the snippet prints.
zrun() {
    DEV_WORKFLOW_TOOLS_DIR="$REPO_ROOT" ZCOMPDUMP="$TEST_TMPDIR/zcompdump" \
    zsh -c '
        autoload -Uz compinit && compinit -u -d "$ZCOMPDUMP" >/dev/null 2>&1
        source "$DEV_WORKFLOW_TOOLS_DIR/shell/dev-workflow.zsh" >/dev/null 2>&1
        unalias w 2>/dev/null
        eval "$ZSNIPPET"
    ' 2>&1
}

# The context verdict for a left-of-cursor buffer: only | maybe | no
ctx() {
    L="$1" ZSNIPPET='
        LBUFFER="$L"; RBUFFER=""; REPLY=""
        if _fzref_tab_context; then print -r -- "$REPLY"; else print -r -- no; fi
    ' zrun
}

# "<buffer>|<cursor>" after replacing the word at the cursor with $3.
splice() {
    L="$1" R="$2" TOK="$3" ZSNIPPET='
        LBUFFER="$L"; RBUFFER="$R"; BUFFER="$LBUFFER$RBUFFER"
        _fzref_word_at_cursor
        _fzref_replace_word "$TOK"
        print -r -- "$BUFFER|$CURSOR"
    ' zrun
}

# ============================================================================
# A ref is the only possible argument — Tab takes over unconditionally
# ============================================================================

@test "the ref-only git subcommands claim Tab" {
    local buf
    for buf in 'git rebase ' 'git merge ' 'git switch ' 'git cherry-pick ' 'git revert '; do
        run ctx "$buf"
        [ "$output" = "only" ] || { echo "[$buf] -> $output" >&2; return 1; }
    done
}

@test "a partial word does not stop the subcommand being recognised" {
    # This is the ("${(@)a[1,-2]}") case: dropping the cursor's own word used to collapse
    # the array, so `git rebase UL-16<TAB>` fell through while `git rebase <TAB>` worked.
    run ctx 'git rebase UL-16'
    [ "$output" = "only" ]
}

@test "options before the subcommand do not hide it" {
    run ctx 'git -C /elsewhere rebase '
    [ "$output" = "only" ]
    run ctx 'git -C /elsewhere rebase UL-16'
    [ "$output" = "only" ]
    run ctx 'git --git-dir /x/.git merge '
    [ "$output" = "only" ]
}

@test "options after the subcommand do not stop it wanting a ref" {
    run ctx 'git rebase --onto main '
    [ "$output" = "only" ]
    run ctx 'git rebase -i '
    [ "$output" = "only" ]
}

@test "git branch wants an existing ref only with a flag that operates on one" {
    # Bare `git branch <TAB>` is naming a branch to CREATE. Hijacking that would be worse
    # than useless: it would offer exactly the names you cannot use.
    run ctx 'git branch '
    [ "$output" = "no" ]
    run ctx 'git branch new-thing'
    [ "$output" = "no" ]
    local buf
    for buf in 'git branch -d ' 'git branch -D ' 'git branch -m ' 'git branch --delete ' 'git branch -f '; do
        run ctx "$buf"
        [ "$output" = "only" ] || { echo "[$buf] -> $output" >&2; return 1; }
    done
}

@test "git worktree add wants a path first and a ref second" {
    run ctx 'git worktree '
    [ "$output" = "no" ]
    run ctx 'git worktree add '
    [ "$output" = "no" ]
    run ctx 'git worktree add ../somewhere '
    [ "$output" = "only" ]
}

@test "push and pull want a ref only after the remote" {
    run ctx 'git push '
    [ "$output" = "no" ]
    run ctx 'git push origin '
    [ "$output" = "only" ]
    run ctx 'git pull origin ma'
    [ "$output" = "only" ]
    run ctx 'git fetch origin '
    [ "$output" = "only" ]
}

@test "create-wt takes a ticket or branch and nothing else" {
    run ctx 'create-wt '
    [ "$output" = "only" ]
}

# ============================================================================
# A ref OR a path — Tab defers to the word already typed
# ============================================================================

@test "the dual-purpose subcommands are only a maybe" {
    local buf
    for buf in 'git diff ' 'git checkout ' 'git log ' 'git show ' 'git reset --hard ' 'git restore '; do
        run ctx "$buf"
        [ "$output" = "maybe" ] || { echo "[$buf] -> $output" >&2; return 1; }
    done
}

@test "maybe resolves by asking whether any ref starts with the word" {
    cd "$TEST_TMPDIR"
    git init -q -b main repo
    cd repo
    git commit -q --allow-empty -m init
    git branch TEST-100
    git branch fix/some-thing
    mkdir -p src
    : > src/index.ts

    reflike() {
        W="$1" ZSNIPPET='
            if _fzref_word_is_reflike "$W"; then print -r -- yes; else print -r -- no; fi
        ' zrun
    }

    run reflike 'TEST-10';    [ "$output" = "yes" ]
    run reflike 'TEST-100';   [ "$output" = "yes" ]
    run reflike 'main';       [ "$output" = "yes" ]
    run reflike 'fix/some';   [ "$output" = "yes" ]
    # The tail of a namespaced branch, which is how you actually remember it.
    run reflike 'some-thing'; [ "$output" = "yes" ]
    run reflike 'nope-xyz';   [ "$output" = "no" ]
    run reflike '';           [ "$output" = "no" ]
    # An existing path wins outright: `git diff src<TAB>` must keep completing files.
    run reflike 'src';        [ "$output" = "no" ]
}

# ============================================================================
# Not our business at all
# ============================================================================

@test "non-git commands and non-ref subcommands fall through" {
    local buf
    for buf in 'git ' 'git commit ' 'git status --short' 'git add ' 'ls ' 'j foo' '' 'yarn test ' 'vim src/'; do
        run ctx "$buf"
        [ "$output" = "no" ] || { echo "[$buf] -> $output" >&2; return 1; }
    done
}

# ============================================================================
# Splicing the token back into the buffer
# ============================================================================

@test "a partial word is replaced, not appended to" {
    run splice 'git rebase UL-16' '' 'UL-1633'
    [ "$output" = "git rebase UL-1633 |19" ]
}

@test "an empty word inserts at the cursor" {
    run splice 'git rebase ' '' 'origin/main'
    [ "$output" = "git rebase origin/main |23" ]
}

@test "a word the cursor sits inside is replaced whole, both halves" {
    run splice 'git rebase UL-16' '33-old-name' 'UL-1633'
    [ "$output" = "git rebase UL-1633 |19" ]
}

@test "mid-line replacement does not insert a space that was not asked for" {
    run splice 'git diff ' ' --stat' 'UL-1633'
    [ "$output" = "git diff UL-1633 --stat|16" ]
}

@test "a slash in a ref name is not quoted, because it does not need to be" {
    # `git rebase 'origin/main'` in your shell history is noise. Only quote what breaks.
    run splice 'git rebase ' '' 'feature/nested/thing'
    [ "$output" = "git rebase feature/nested/thing |32" ]
}

@test "a ref name that would break the command line is quoted" {
    run splice 'git rebase ' '' 'weird branch name'
    [ "$output" = 'git rebase weird\ branch\ name |31' ]
    run splice 'git rebase ' '' 'has$dollar'
    [ "$output" = 'git rebase has\$dollar |23' ]
}

@test "a newline is a word boundary, so a continued command line still works" {
    run splice "$(printf 'git rebase \\\ngit merge UL-16')" '' 'UL-1633'
    [ "$output" = "$(printf 'git rebase \\\ngit merge UL-1633 |31')" ]
}

# ============================================================================
# The pieces the .zshrc Tab dispatcher relies on
# ============================================================================

@test "the functions the .zshrc hook calls all exist under the names it uses" {
    # ~/.zshrc guards on $+functions[_fzref_tab_try]; renaming this without renaming it
    # there turns the whole Tab integration off silently, with Tab still working — so the
    # failure looks like "the feature was never installed" rather than like a bug.
    check_fns() {
        ZSNIPPET='
            for f in _fzref_tab_try _fzref_tab_context _fzref_word_at_cursor \
                     _fzref_replace_word _fzref_word_is_reflike _fzref_pick_into_buffer \
                     fzref-widget; do
                (( $+functions[$f] )) || print -r -- "MISSING $f"
            done
            print -r -- checked
        ' zrun
    }
    run check_fns
    [[ "$output" == *checked* ]]
    [[ "$output" != *MISSING* ]] || { echo "$output" >&2; return 1; }
}

@test "ctrl-b is bound to the widget in both insert and command mode" {
    show_binds() { ZSNIPPET='bindkey -M viins "^B"; bindkey -M vicmd "^B"' zrun; }
    run show_binds
    [ "$(printf '%s\n' "$output" | grep -c fzref-widget)" = "2" ]
}

@test "ctrl-b is also registered to be rebound after zsh-vi-mode's init" {
    # zvm rebuilds part of the viins keymap after this file is sourced and takes ^B back to
    # backward-char. The direct bindkey above cannot survive that on its own, and the
    # symptom — ^B moving the cursor left — reads as "never installed" rather than as a bug,
    # so the hook registration is worth asserting separately from the binding.
    show_hook() { ZSNIPPET='print -r -- "hook:${(j:,:)zvm_after_init_commands}"' zrun; }
    run show_hook
    [[ "$output" == *"_fzref_bind_keys"* ]]
}

@test "the after-init rebinder actually rebinds, from a keymap zvm has reclaimed" {
    # Simulates what zvm does to ^B, then runs only the hook, and checks it comes back.
    replay() {
        ZSNIPPET='
            bindkey -M viins "^B" backward-char
            bindkey -M vicmd "^B" undefined-key
            for cmd in $zvm_after_init_commands; do eval $cmd; done
            bindkey -M viins "^B"; bindkey -M vicmd "^B"
        ' zrun
    }
    run replay
    [ "$(printf '%s\n' "$output" | grep -c fzref-widget)" = "2" ]
}

@test "the tab hook declines outside a git repository" {
    mkdir -p "$TEST_TMPDIR/not-a-repo"
    cd "$TEST_TMPDIR/not-a-repo"
    try_tab() {
        L='git rebase ' ZSNIPPET='
            LBUFFER="$L"; RBUFFER=""
            if _fzref_tab_try; then print -r -- handled; else print -r -- declined; fi
        ' zrun
    }
    run try_tab
    [ "$output" = "declined" ]
}

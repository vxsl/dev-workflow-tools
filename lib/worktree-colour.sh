#!/bin/sh
# worktree-colour - one worktree, one colour, in the prompt and in the picker.
#
# The p10k segment (shell/p10k-worktree.zsh) tints itself per worktree, so "which of the
# 150-odd checkouts am I in" is a glance rather than a read. fzedit's ⊙ rows want the
# same thing -- but a second palette, or the same palette with a different hash, would
# be worse than leaving them one flat colour: two tools that both claim to colour by
# worktree and then disagree about WHICH colour teach you to stop trusting the colour.
# So the palette, the key and the hash live here, and both sides ask this file.
#
# Sourced from bash (fzedit) and from zsh (the prompt), so this stays inside the
# intersection of the two: no arrays, no `printf -v`, no `$((#c))`. And no forks -- the
# prompt runs this on every single command, where the `cksum` pipeline it replaced was
# three processes for four bits of information.
#
# THE KEY is git's own name for the worktree: the directory under .git/worktrees, which
# is the basename of that worktree's gitdir. Not the checkout's own basename, which
# collides once worktrees nest (repo.hotfix/fix-x and repo.other/fix-x are both
# "fix-x"), and not the branch, which moves under you mid-rebase -- a worktree changing
# colour because you started a rebase in it is exactly the wrong time to lose the cue.
#
# The primary worktree has no entry under worktrees/ and therefore no key and no colour.
# Deliberate: "untinted" is itself the signal that you are on the main checkout.

# Prevent multiple loads (fzedit sources this once; a shell may source it again).
if [ -n "$WTC_LOADED" ]; then
    return 0
fi
WTC_LOADED=1

# Ten colours, picked to be told apart at a glance and to work BOTH ways round: as a
# p10k segment background with black text on it, and as a foreground tint on a dark
# terminal. That rules out anything dark, which is why they are all in the light half of
# the 256-colour cube.
WTC_PALETTE="220 81 141 114 167 214 109 173 117 205"

# Printable ASCII in order, used as the character -> number table.
#
# A lookup string rather than each language's ord(), because there isn't one they share:
# bash has no `$((#c))`, zsh has no `printf '%d' "'c"`, and awk's sprintf("%c") is
# locale-dependent above 127. Position within a string is the one thing all three agree
# on exactly -- and exactly is the requirement here, since the shell hash and the awk
# hash have to return the same number, not merely similar ones. Anything not in this set
# (i.e. anything non-ASCII) scores 0 in every implementation, so they still agree.
WTC_ALPHABET=' !"#$%&'\''()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~'

# Exported because the awk half reads these out of ENVIRON rather than taking them as
# -v assignments: gawk expands escape sequences in a -v value, and the alphabet above
# contains a backslash.
export WTC_PALETTE WTC_ALPHABET

# Sets WTC_SLOT (palette index, 0-based) and WTC_COLOUR (an xterm-256 colour) from a
# worktree key. Both are empty when the key is -- see the note about the primary
# worktree above, and default to your own flat colour when that happens.
#
# Globals rather than stdout, because the prompt calls this on every command and a
# command substitution is a fork. Same reasoning as read_wt_state in fzedit.
#
# The hash is `h = h * 31 + position` per character, mod a prime. Nothing cryptographic
# is wanted -- just a spread that two languages can compute identically in ordinary
# integer arithmetic. 1000003 * 31 needs 25 bits, so it stays well inside awk's doubles
# and inside every shell's integers.
wtc_colour() {
    local key="$1" i=0 n=${#1} h=0 c pre pos slot count=0 p rest
    WTC_SLOT=""
    WTC_COLOUR=""
    [ -n "$key" ] || return 0

    while [ "$i" -lt "$n" ]; do
        c=${key:$i:1}
        pre=${WTC_ALPHABET%%"$c"*}
        if [ "$pre" = "$WTC_ALPHABET" ]; then pos=0; else pos=$(( ${#pre} + 1 )); fi
        h=$(( (h * 31 + pos) % 1000003 ))
        i=$(( i + 1 ))
    done

    # The palette is walked by hand rather than split into an array or into positional
    # parameters, because `for p in $WTC_PALETTE` does not word-split in zsh at all --
    # it iterates once, over the whole string, and every worktree silently comes out the
    # same colour. Two passes over ten numbers, which is free beside the git call that
    # produced the key in the first place.
    rest="$WTC_PALETTE"
    while [ -n "$rest" ]; do
        p="${rest%% *}"
        rest="${rest#"$p"}"
        rest="${rest# }"
        [ -n "$p" ] && count=$(( count + 1 ))
    done
    [ "$count" -gt 0 ] || return 0
    slot=$(( h % count ))
    WTC_SLOT="$slot"

    i=0
    rest="$WTC_PALETTE"
    while [ -n "$rest" ]; do
        p="${rest%% *}"
        rest="${rest#"$p"}"
        rest="${rest# }"
        [ -n "$p" ] || continue
        if [ "$i" -eq "$slot" ]; then WTC_COLOUR="$p"; return 0; fi
        i=$(( i + 1 ))
    done
}

# Sets WTC_KEY to the colour key for a worktree given only its path: git's own name for
# it, which is the basename of the gitdir the worktree's .git file points at. Empty for the
# primary checkout, whose .git is a directory and which therefore has no worktree name.
#
# For callers that already hold a gitdir (fzedit's read_wt_state reads one anyway) this is
# just "${gitdir##*/}" and not worth a call. This exists for the ones that only have the
# path -- rr, once per row -- which is also why it reads the file with `read` instead of
# `grep | cut`: two forks per row is two too many there.
worktree_colour_key() {
    local wt_path="$1" line
    WTC_KEY=""
    [ -f "$wt_path/.git" ] || return 0
    while IFS= read -r line; do
        case "$line" in
            gitdir:*)
                line="${line#gitdir:}"
                line="${line# }"
                WTC_KEY="${line##*/}"
                return 0
                ;;
        esac
    done < "$wt_path/.git"
}

# The same hash, for a caller that is already inside awk. Prepend it to an awk program:
#
#     awk -F'\t' "$WTC_AWK"'{ print wtc_colour($3) }'
#
# Not duplication for its own sake: fzedit tints ~154 rows inside one awk pass on every
# redraw, and a shell call per row would be 154 forks on the hot path -- the exact cost
# the rest of that file goes out of its way to avoid. wtc_selftest below is what keeps
# the two honest, and the test suite runs it.
WTC_AWK='
function wtc_colour(name,   i, n, h, pos) {
    if (_wtc_n == 0) {
        _wtc_n = split(ENVIRON["WTC_PALETTE"], _wtc_pal, " ")
        _wtc_alpha = ENVIRON["WTC_ALPHABET"]
    }
    if (name == "") return ""
    h = 0
    n = length(name)
    for (i = 1; i <= n; i++) {
        pos = index(_wtc_alpha, substr(name, i, 1))
        h = (h * 31 + pos) % 1000003
    }
    return _wtc_pal[h % _wtc_n + 1]
}
'

# Prove the shell half and the awk half still agree. Silent and 0 on agreement; prints
# every disagreement and returns 1 otherwise. Takes keys to check, or uses a set that
# covers the shapes real worktree names come in (branches, ticket ids, nested paths,
# single characters, non-ASCII).
wtc_selftest() {
    local names="$*" name want got bad=0 rest
    if [ -z "$names" ]; then
        names="main feature UB-6709-add-custom-trimet-layer fix-x a Z 0 _ .. --- ünïcode"
        names="$names return-400-for-an-unbound-placeholder-data-source ul.hotfix"
    fi
    rest="$names"
    while [ -n "$rest" ]; do
        name="${rest%% *}"
        rest="${rest#"$name"}"
        rest="${rest# }"
        [ -n "$name" ] || continue
        wtc_colour "$name"
        want="$WTC_COLOUR"
        got=$(printf '%s\n' "$name" | awk "$WTC_AWK"'{ print wtc_colour($0) }')
        if [ "$want" != "$got" ]; then
            printf 'wtc_selftest: %s -> shell %s, awk %s\n' "$name" "$want" "$got" >&2
            bad=1
        fi
    done
    return "$bad"
}

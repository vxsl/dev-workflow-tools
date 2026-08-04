#!/usr/bin/env bats
# lib/worktree-colour.sh — the palette shared by the p10k prompt segment and fzedit.
#
# What is worth testing here is not "does it return a colour" but "do both
# implementations return the SAME colour". There are two on purpose — a shell one for the
# prompt, an awk one for the ~154 rows fzedit tints per redraw — and the entire value of
# the file is that one worktree looks the same in both tools. Drift between them is not a
# cosmetic bug: it is the feature quietly not existing any more, while still looking like
# it does.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "$REPO_ROOT/lib/worktree-colour.sh"
}

@test "the shell hash and the awk hash agree" {
    wtc_selftest
}

@test "they agree over a couple of hundred generated names too" {
    local names="" i
    for i in $(seq 1 60); do
        names="$names UB-${i}00-a-branch-name-$i wt.$i repo.nested/deep-$i"
    done
    wtc_selftest $names
}

# Branch names are ASCII in practice, but "in practice" is not a guarantee, and the two
# implementations reach for characters differently (substr in awk, ${x:i:1} in the
# shell). They agree by both scoring an unknown character 0 — assert that, rather than
# assuming it.
@test "a non-ASCII key still agrees between the two implementations" {
    wtc_selftest "ünïcode-brânch ☃-snowman naïve"
}

@test "the same key always gets the same colour" {
    local first
    wtc_colour UB-6709-add-custom-trimet-layer
    first="$WTC_COLOUR"
    [ -n "$first" ]
    wtc_colour something-completely-different
    wtc_colour UB-6709-add-custom-trimet-layer
    [ "$WTC_COLOUR" = "$first" ]
}

# The primary worktree has no entry under .git/worktrees and therefore no key. Untinted
# is the intended answer, not a fallback that happened to work: it is what tells you at a
# glance that you are on the main checkout rather than in one of the siblings.
@test "an empty key gets no colour at all" {
    wtc_colour ""
    [ -z "$WTC_COLOUR" ]
    [ -z "$WTC_SLOT" ]
}

@test "the colour is always one of the palette's, and the slot indexes it" {
    local key colour n=0 p
    for p in $WTC_PALETTE; do n=$(( n + 1 )); done
    for key in main feature deep repo.detached a Z 0 --- .. UB-1; do
        wtc_colour "$key"
        [ "$WTC_SLOT" -ge 0 ]
        [ "$WTC_SLOT" -lt "$n" ]
        [[ " $WTC_PALETTE " == *" $WTC_COLOUR "* ]]
    done
}

# A hash that spreads badly is indistinguishable from no colour at all: if two thirds of
# the worktrees come out the same shade, glancing at the tint tells you nothing. Real
# worktree names share long prefixes (ticket ids, "fix-", the repo name), which is
# exactly the input a weak hash collapses.
@test "colours spread across the whole palette rather than piling into a few buckets" {
    local i seen="" key
    for i in $(seq 1 200); do
        wtc_colour "UB-6${i}0-fix-the-thing-that-broke-$i"
        case " $seen " in *" $WTC_COLOUR "*) ;; *) seen="$seen $WTC_COLOUR" ;; esac
    done
    local used=0 c
    for c in $seen; do used=$(( used + 1 )); done
    local total=0 p
    for p in $WTC_PALETTE; do total=$(( total + 1 )); done
    [ "$used" -eq "$total" ] || { echo "used $used of $total colours: $seen"; return 1; }
}

# The prompt has to unroll the palette into one named p10k style per colour, which is the
# one place a longer palette would silently half-work: the extra colours would hash fine
# and then resolve to a style p10k has never heard of.
@test "the prompt segment defines a p10k style for every palette colour" {
    command -v zsh >/dev/null 2>&1 || skip "no zsh"
    run zsh -c 'source '"$REPO_ROOT"'/shell/p10k-worktree.zsh
                i=0
                for c in ${=WTC_PALETTE}; do
                    eval "print -r -- \$POWERLEVEL9K_WORKTREE_COLOR${i}_BACKGROUND"
                    i=$(( i + 1 ))
                done'
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf '%s\n' $WTC_PALETTE)" ]
}

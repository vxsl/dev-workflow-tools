#!/bin/sh
# worktree-mismatch - "this checkout is not on the branch its name promises".
#
# One rule, shared by the p10k prompt segment and fzedit's header, for the same reason
# the palette next door is shared (lib/worktree-colour.sh): both draw the same alarm, and
# an alarm that fires in one tool but not the other is worse than no alarm at all,
# because you learn to trust whichever one happens to be quiet.
#
# The convention it rests on: worktrees made by create-wt and rr are named
# <repo>.<branch>, so the directory name states which branch is meant to be checked out
# and git states which one is. A disagreement means either you switched branches inside a
# worktree built for a different one, or you are about to edit files on a branch you did
# not think you were on -- and in a 150-worktree checkout, "the directory name" is the
# only thing you actually navigate by.
#
# Tolerant in both directions, deliberately. A directory called ul.UB-6709 legitimately
# holds UB-6709-add-custom-trimet-layer, and a directory named after a long branch is
# usually the truncated version of it, so a prefix match either way is a match. Detached
# HEAD is not a mismatch either: it means mid-rebase or mid-bisect, which is a transient
# state rather than a misfiled worktree, and an alarm that goes off every time you rebase
# is an alarm you switch off.
#
# Sourced from bash (fzedit) and zsh (the prompt), so: no arrays, no forks, no [[ =~ ]]
# -- the last of those is why the ticket id is picked apart with `case` below rather than
# with a regex, since bash and zsh put the capture groups in different variables.

# Prevent multiple loads.
if [ -n "$WTM_LOADED" ]; then
    return 0
fi
WTM_LOADED=1

# Sets WTM_EXPECTED (the branch the directory name promises, empty if it promises
# nothing) and WTM_MISMATCH (empty, or the branch that is actually checked out).
# $1 = the worktree directory's basename, $2 = the branch git says is checked out
# ("HEAD" for a detached one).
wtm_check() {
    local wt_basename="$1" actual="$2"
    WTM_EXPECTED=""
    WTM_MISMATCH=""

    # No dot, no promise: a worktree not named <repo>.<branch> claims nothing, so there
    # is nothing to contradict.
    case "$wt_basename" in *.*) WTM_EXPECTED="${wt_basename##*.}" ;; esac
    [ -n "$WTM_EXPECTED" ] || return 0
    [ -n "$actual" ] || return 0
    [ "$actual" = "HEAD" ] && return 0

    case "$actual" in "$WTM_EXPECTED"*) return 0 ;; esac
    case "$WTM_EXPECTED" in "$actual"*) return 0 ;; esac
    WTM_MISMATCH="$actual"
}

# Sets WTM_TICKET to the ticket id leading a branch name (UB-6709 out of
# UB-6709-add-custom-trimet-layer), or empty when there isn't one.
#
# Used to keep the alarm short: the whole point of it is to be read at a glance, and
# forty characters of branch name is not a glance.
wtm_ticket() {
    local b="$1" proj rest num
    WTM_TICKET=""
    proj="${b%%-*}"
    [ "$proj" != "$b" ] || return 0
    rest="${b#*-}"
    num="${rest%%-*}"
    # All capitals, then all digits. `case` rather than a regex so this reads the same in
    # bash and zsh -- see the header.
    case "$proj" in ''|*[!A-Z]*) return 0 ;; esac
    case "$num"  in ''|*[!0-9]*) return 0 ;; esac
    WTM_TICKET="$proj-$num"
}

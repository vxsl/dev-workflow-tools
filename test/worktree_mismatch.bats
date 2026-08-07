#!/usr/bin/env bats
# lib/worktree-mismatch.sh — "this checkout is not on the branch its name promises".
#
# The alarm is shared with the p10k prompt segment, so what matters is not only that it
# fires but that it is quiet in all the ordinary cases. A false alarm here is expensive in
# a specific way: it goes off in the prompt, on every command, in a worktree you are
# working in perfectly happily — and after the second day of that you stop seeing the real
# one too.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "$REPO_ROOT/lib/worktree-mismatch.sh"
}

@test "a checkout on the branch its name promises is quiet" {
    wtm_check repo.feature feature
    [ -z "$WTM_MISMATCH" ]
    [ "$WTM_EXPECTED" = feature ]
}

# create-wt names a worktree after the ticket and checks out the full branch, so the two
# only ever agree by prefix. If this were an exact comparison the alarm would fire in
# every worktree the tooling makes.
@test "the promised branch matching by prefix is a match" {
    wtm_check repo.UB-6709 UB-6709-add-custom-trimet-layer
    [ -z "$WTM_MISMATCH" ]
}

# And the other way round, because a worktree is sometimes named after the whole branch
# while the branch itself gets shortened later.
@test "the checked-out branch matching by prefix is also a match" {
    wtm_check repo.UB-6709-add-custom-trimet-layer UB-6709
    [ -z "$WTM_MISMATCH" ]
}

@test "a genuinely different branch is a mismatch, and names itself" {
    wtm_check repo.feature elsewhere
    [ "$WTM_MISMATCH" = elsewhere ]
    [ "$WTM_EXPECTED" = feature ]
}

# The confusable pair that motivates the whole thing: two branches sharing a long prefix,
# in two worktrees whose names differ by six characters.
@test "branches sharing a prefix are still told apart in the direction that matters" {
    wtm_check repo.smp-selected-state smp-select
    [ -z "$WTM_MISMATCH" ]
    wtm_check repo.smp-select some-unrelated-branch
    [ "$WTM_MISMATCH" = some-unrelated-branch ]
}

# A worktree not named <repo>.<branch> promises nothing, so there is nothing to contradict
# — the plain checkout of a repo, or anything created by hand.
@test "a name with no dot promises nothing and cannot mismatch" {
    wtm_check repo elsewhere
    [ -z "$WTM_EXPECTED" ]
    [ -z "$WTM_MISMATCH" ]
}

@test "a detached HEAD is a transient state, not a misfiled worktree" {
    wtm_check repo.feature HEAD
    [ -z "$WTM_MISMATCH" ]
}

@test "not knowing the branch is not the same as knowing it is wrong" {
    wtm_check repo.feature ""
    [ -z "$WTM_MISMATCH" ]
}

@test "the ticket id is picked out of a branch name" {
    wtm_ticket UB-6709-add-custom-trimet-layer
    [ "$WTM_TICKET" = UB-6709 ]
    wtm_ticket DE-3101
    [ "$WTM_TICKET" = DE-3101 ]
}

# Two worktrees for one ticket -- ul.UB-6802 holding the implementation and
# ul.UB-6802-review-<branch-under-review> for reviewing it -- must not wear the same
# badge, so the review flavour survives the shortening. A "review" further along is
# ordinary description and still drops.
@test "a review worktree keeps its -review, and only when it leads" {
    wtm_ticket UB-6802-review-migrate-from-wasm-join-engine-to-geo-fil
    [ "$WTM_TICKET" = UB-6802-review ]
    wtm_ticket UB-6802-review
    [ "$WTM_TICKET" = UB-6802-review ]
    wtm_ticket UB-6802-add-review-button
    [ "$WTM_TICKET" = UB-6802 ]
    wtm_ticket UB-6802-reviewers
    [ "$WTM_TICKET" = UB-6802 ]
}

@test "a branch that only looks ticket-shaped has no ticket id" {
    for b in feature main add-6709-thing ub-6709-lowercase UB-six-hundred UB- -6709; do
        wtm_ticket "$b"
        [ -z "$WTM_TICKET" ] || { echo "$b -> $WTM_TICKET"; return 1; }
    done
}

# The prompt runs this rule under zsh, on every command. `local`, `case` patterns and
# ${x##*.} all read subtly differently there, which is why the rule avoids [[ =~ ]] — the
# capture groups land in different variables in the two shells.
@test "the rule gives the same answers under zsh, which is where the prompt runs it" {
    command -v zsh >/dev/null 2>&1 || skip "no zsh"
    run zsh -c 'source '"$REPO_ROOT"'/lib/worktree-mismatch.sh
                wtm_check repo.feature elsewhere       ; print -r -- "1:$WTM_MISMATCH"
                wtm_check repo.UB-6709 UB-6709-add-x   ; print -r -- "2:$WTM_MISMATCH"
                wtm_check repo HEAD                    ; print -r -- "3:$WTM_EXPECTED"
                wtm_ticket UB-6709-add-x               ; print -r -- "4:$WTM_TICKET"
                wtm_ticket feature                     ; print -r -- "5:$WTM_TICKET"
                wtm_ticket UB-6802-review-migrate-x    ; print -r -- "6:$WTM_TICKET"'
    [ "$status" -eq 0 ]
    [ "$output" = "1:elsewhere
2:
3:
4:UB-6709
5:
6:UB-6802-review" ] || { echo "$output"; return 1; }
}

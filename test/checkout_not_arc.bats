#!/usr/bin/env bats
# Tests for the rule that a directory holding somebody else's branch is not a workstream.
#
# Kyle: "if there's a checkout-only arc with none of my own work, doesn't that mean that
# it's not an arc at all?" It does. An arc is a piece of work of his; a branch of Logan's
# he fetched to read is evidence that he was reading it, and evidence belongs on the
# review, not on a workstream invented to hold the directory.
#
# And the boundary he drew himself, which is the whole reason this cannot be a one-line
# filter: "what if i check something out and start to make changes on it but havent
# committed yet. that would be an arc... right?" Uncommitted work is his work in the form
# that would be lost the most completely -- on no branch, no remote, in no reflog -- so the
# working tree is the line and not the commit.
#
# Real git repositories throughout, because both halves of the question are read off real
# git state: authorship decides what a checkout is, and a working tree decides whether one
# has been promoted back. Nothing here pins wording.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    export JIRA_PROJECTS="UL,UB"
    ARC_REPO="$TEST_TMPDIR/repo"
    export ARC_REPO
    mkdir -p "$ARC_REPO"
    git -C "$ARC_REPO" init -q -b main
    git -C "$ARC_REPO" config user.email kyle@example.com
    git -C "$ARC_REPO" config user.name "Kyle Grimsrud-Manz"
    printf 'base\n' > "$ARC_REPO/base.txt"
    git -C "$ARC_REPO" add base.txt
    GIT_AUTHOR_DATE="2026-05-01 09:00:00 +0000" \
    GIT_COMMITTER_DATE="2026-05-01 09:00:00 +0000" \
        git -C "$ARC_REPO" commit -q -m base
    git -C "$ARC_REPO" update-ref refs/remotes/origin/main main
    git -C "$ARC_REPO" checkout -q main
}

teardown() {
    teardown_temp_dir
}

# One commit somebody else authored, on a branch cut from main. Args: branch, day, file.
theirs() {
    local branch="$1" day="$2" file="${3:-theirs.txt}"
    if git -C "$ARC_REPO" rev-parse --verify -q "$branch" >/dev/null; then
        git -C "$ARC_REPO" checkout -q "$branch"
    else
        git -C "$ARC_REPO" checkout -q -b "$branch" main
    fi
    printf 'work on %s\n' "$branch" >> "$ARC_REPO/$file"
    git -C "$ARC_REPO" add "$file"
    GIT_AUTHOR_NAME="Ella Example" GIT_AUTHOR_EMAIL="ella@example.com" \
    GIT_AUTHOR_DATE="$day 09:00:00 +0000" GIT_COMMITTER_DATE="$day 09:00:00 +0000" \
        git -C "$ARC_REPO" commit -q -m "their work on $branch"
    git -C "$ARC_REPO" checkout -q main
}

# One commit of Kyle's own on an existing branch.
mine_on() {
    local branch="$1" day="$2"
    git -C "$ARC_REPO" checkout -q "$branch"
    GIT_AUTHOR_DATE="$day 09:00:00 +0000" GIT_COMMITTER_DATE="$day 09:00:00 +0000" \
        git -C "$ARC_REPO" commit -q --allow-empty -m "my fix on $branch"
    git -C "$ARC_REPO" checkout -q main
}

pushed() {
    git -C "$ARC_REPO" update-ref "refs/remotes/origin/$1" "$1"
}

# Check a branch out into a worktree of its own, which is the only kind that can be dirty.
worktree_for() {
    git -C "$ARC_REPO" worktree add -q "$TEST_TMPDIR/wt-$1" "$1" 2>/dev/null
}

dirty_worktree() {
    printf 'half a thought\n' >> "$TEST_TMPDIR/wt-$1/scratch.txt"
}

wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" "$ARC_REPO" <<'PY' "$1"
import importlib.machinery, importlib.util, sys, json
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
REPO = sys.argv[2]
snippet = sys.argv[3]
sys.argv = ["wa"]
loader.exec_module(wa)
wa.TICKET_RE = wa._ticket_re()

def build(**kw):
    """Every arc this repo produces, finalized, exactly as main builds them."""
    branches = wa.collect_branches(REPO, "origin/main")
    stashes = wa.collect_stashes(REPO)
    arcs, unattached = wa.build_arcs(branches, stashes, [], kw.get("sessions") or {},
                                     "origin/main", repo=REPO, mrs_known=True)
    return arcs

def by_id(arcs):
    return {a["id"]: a for a in arcs}

exec(snippet)
PY
}

# ── the demotion itself ───────────────────────────────────────────────────────

@test "a branch that is only somebody else's is not a workstream of yours" {
    theirs UL-1816 2026-08-01
    pushed UL-1816
    run wa '
arcs = build()
print("before", sorted(a["id"] for a in arcs))
kept, checkouts = wa.demote_checkouts(arcs)
print("after", sorted(a["id"] for a in kept))
print("checkouts", [(c["branch"], c["owner"], c["iid"]) for c in checkouts])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"before ['UL-1816']"* ]]
    [[ "$output" == *"after []"* ]]
    [[ "$output" == *"checkouts [('UL-1816', 'ella', None)]"* ]]
}

@test "a checkout with a review joined to it is that review's evidence, not an arc" {
    theirs UL-1816 2026-08-01
    pushed UL-1816
    run wa '
arcs = build()
r = {"iid": 10530, "ref": "!10530", "source_branch": "UL-1816", "author": "logan",
     "whose_turn": "mine", "rounds": 3, "my_last": 100, "their_last": 200, "arc": None}
wa.attach_reviews(arcs, [r])
print("joined", r["arc"])
kept, checkouts = wa.demote_checkouts(arcs)
print("after", [a["id"] for a in kept], "checkouts", [c["branch"] for c in checkouts])
print("evidence", r["checked_out"], r["checkout_branches"], r["arc"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"joined UL-1816"* ]]
    [[ "$output" == *"after [] checkouts []"* ]]
    # The arc it named is gone, so the pointer goes with it -- and what replaces it says
    # the same thing without one: the branch is here.
    [[ "$output" == *"evidence True ['UL-1816'] None"* ]]
}

@test "one commit of your own on their branch keeps it a workstream" {
    theirs UB-6438 2026-08-01
    mine_on UB-6438 2026-08-02
    pushed UB-6438
    run wa '
arcs = build()
kept, checkouts = wa.demote_checkouts(arcs)
print("after", [a["id"] for a in kept], "checkouts", [c["branch"] for c in checkouts])
print("checkout_only", wa.checkout_only(arcs[0]))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"after ['UB-6438'] checkouts []"* ]]
    [[ "$output" == *"checkout_only False"* ]]
}

# ── the promotion boundary: the working tree, not the commit ──────────────────

@test "uncommitted changes on their branch make it yours again" {
    theirs UL-1815 2026-08-01
    pushed UL-1815
    worktree_for UL-1815
    dirty_worktree UL-1815
    run wa '
arcs = build()
print("dirty", [b.get("dirty") for a in arcs for b in a["branches"]])
print("why", wa.checkout_promoted(arcs[0]))
kept, checkouts = wa.demote_checkouts(arcs)
print("after", [a["id"] for a in kept], "checkouts", [c["branch"] for c in checkouts])
print("stage", kept[0]["stage"])
print("state", kept[0]["state"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"dirty [True]"* ]]
    [[ "$output" == *"why dirty"* ]]
    [[ "$output" == *"after ['UL-1815'] checkouts []"* ]]
    [[ "$output" == *"stage checkout"* ]]
    # A state, not an amount -- workscale stays the authority on how much work something
    # is, and nothing here has counted anything. Whose branch it is comes off the commits.
    [[ "$output" == *"uncommitted"* ]]
    [[ "$output" == *"ella"* ]]
}

@test "a clean worktree on their branch is a checkout and nothing more" {
    theirs UL-1815 2026-08-01
    pushed UL-1815
    worktree_for UL-1815
    run wa '
arcs = build()
print("dirty", [b.get("dirty") for a in arcs for b in a["branches"]])
print("why", wa.checkout_promoted(arcs[0]))
kept, checkouts = wa.demote_checkouts(arcs)
print("after", [a["id"] for a in kept], "checkouts", [c["branch"] for c in checkouts])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"dirty [False]"* ]]
    [[ "$output" == *"why None"* ]]
    [[ "$output" == *"after [] checkouts ['UL-1815']"* ]]
}

@test "cleaning the tree demotes it again on the very next run" {
    # The boundary has to move in both directions or it is a one-way ratchet: a checkout
    # dirtied for an afternoon would be a workstream forever.
    theirs UL-1815 2026-08-01
    pushed UL-1815
    worktree_for UL-1815
    dirty_worktree UL-1815
    run wa '
print("while_dirty", [a["id"] for a in wa.demote_checkouts(build())[0]])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"while_dirty ['UL-1815']"* ]]
    rm -f "$TEST_TMPDIR/wt-UL-1815/scratch.txt"
    run wa '
kept, checkouts = wa.demote_checkouts(build())
print("once_clean", [a["id"] for a in kept], [c["branch"] for c in checkouts])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"once_clean [] ['UL-1815']"* ]]
}

@test "a stash taken on their branch keeps it a workstream" {
    theirs UL-1812 2026-08-01
    pushed UL-1812
    git -C "$ARC_REPO" checkout -q UL-1812
    printf 'not finished\n' > "$ARC_REPO/wip.py"
    git -C "$ARC_REPO" add wip.py
    git -C "$ARC_REPO" stash -q
    git -C "$ARC_REPO" checkout -q main
    run wa '
arcs = build()
print("stashes", [len(a["stashes"]) for a in arcs])
print("why", wa.checkout_promoted(arcs[0]))
kept, checkouts = wa.demote_checkouts(arcs)
print("after", [a["id"] for a in kept], "checkouts", [c["branch"] for c in checkouts])
print("state", kept[0]["state"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"why stash"* ]]
    [[ "$output" == *"after ['UL-1812'] checkouts []"* ]]
    [[ "$output" == *"stashed"* ]]
}

@test "a working tree git cannot read is kept, never read as clean" {
    theirs UL-1815 2026-08-01
    pushed UL-1815
    run wa '
arcs = build()
for b in arcs[0]["branches"]:
    b["dirty"], b["worktree"] = None, True
wa.finalize(arcs[0], REPO, "origin/main")
print("why", wa.checkout_promoted(arcs[0]))
kept, checkouts = wa.demote_checkouts(arcs)
print("after", [a["id"] for a in kept])
print("state", kept[0]["state"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"why unreadable"* ]]
    [[ "$output" == *"after ['UL-1815']"* ]]
    [[ "$output" == *"would not say"* ]]
}

@test "reading a session on their branch is reading it, not working on it" {
    # Sessions are deliberately NOT a promotion. A transcript that mentions a branch is a
    # record of having read it, which is exactly what reviewing looks like -- promoting on
    # it would put every checkout straight back where it was.
    theirs UL-1816 2026-08-01
    pushed UL-1816
    run wa '
sessions = {"UL-1816": {"entries": 40, "last": 1756000000, "days": {},
                        "paths": ["/tmp/a.jsonl", "/tmp/b.jsonl"]}}
arcs = build(sessions=sessions)
print("sessions", [len(a["sessions"]) for a in arcs])
print("why", wa.checkout_promoted(arcs[0]))
kept, checkouts = wa.demote_checkouts(arcs)
print("after", [a["id"] for a in kept])
print("carried", [c["sessions"] for c in checkouts])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"sessions [2]"* ]]
    [[ "$output" == *"why None"* ]]
    [[ "$output" == *"after []"* ]]
    # Carried onto the checkout row rather than lost with the arc: two sittings spent
    # reading somebody's branch is a fact worth keeping, it is just not a workstream.
    [[ "$output" == *"carried [2]"* ]]
}

# ── nothing is deleted in silence ─────────────────────────────────────────────

@test "every demoted branch leaves as evidence or as a checkout, never as nothing" {
    theirs UL-1816 2026-08-01
    theirs UL-1568 2026-08-02
    pushed UL-1816
    pushed UL-1568
    run wa '
arcs = build()
r = {"iid": 1, "ref": "!1", "source_branch": "UL-1816", "author": "logan",
     "whose_turn": "mine", "rounds": 1, "my_last": 1, "their_last": 2, "arc": None}
wa.attach_reviews(arcs, [r])
was = sorted(b["name"] for a in arcs for b in a["branches"])
kept, checkouts = wa.demote_checkouts(arcs)
now = sorted([b["name"] for a in kept for b in a["branches"]]
             + [c["branch"] for c in checkouts]
             + (r.get("checkout_branches") or []))
print("was", was)
print("now", now)
print("accounted", was == now)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"accounted True"* ]]
}

@test "the checkouts list has one total order with a total tiebreak" {
    theirs UL-1816 2026-08-01
    theirs UL-1568 2026-08-01
    theirs UL-1812 2026-07-01
    pushed UL-1816
    pushed UL-1568
    pushed UL-1812
    run wa '
kept, checkouts = wa.demote_checkouts(build())
print("order", [c["branch"] for c in checkouts])'
    [ "$status" -eq 0 ]
    # Oldest first, because a checkout nobody has touched is the one worth deleting; then
    # the branch name, which is unique and so makes the order total.
    [[ "$output" == *"order ['UL-1812', 'UL-1568', 'UL-1816']"* ]]
}

# ── what the rest of the page must never say about a checkout ─────────────────

@test "no ranking of your own work can mourn a branch that was never yours" {
    # cliff, forgotten and only_here all run downstream of the demotion, so the proof is
    # that they are handed a list with no checkout in it at all.
    theirs UL-1816 2026-08-01
    run wa '
theirs_only = build()
kept, checkouts = wa.demote_checkouts(theirs_only)
fell = wa.fell_off_a_cliff(kept)
print("kept", [a["id"] for a in kept])
print("cliff", [a["id"] for a in fell])
print("only_here", wa.only_here(kept))
print("forgotten", [a["id"] for a in kept if a.get("forgotten")])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"kept []"* ]]
    [[ "$output" == *"cliff []"* ]]
    [[ "$output" == *"only_here []"* ]]
    [[ "$output" == *"forgotten []"* ]]
}

@test "the stage a checkout carries is exempt from the forgotten test under its new name" {
    # The exemption existed because UL-1816 carries 25 of Logan's commits, which clears
    # min_commits on its own -- so the arc would be accused of a cliff built entirely out
    # of another person's rhythm. It has to follow the stage through its rename.
    run wa '
print("exempt", sorted(wa.FORGOTTEN_EXEMPT))
print("has_checkout", "checkout" in wa.FORGOTTEN_EXEMPT)
print("no_reviewing", "reviewing" in wa.FORGOTTEN_EXEMPT)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"has_checkout True"* ]]
    [[ "$output" == *"no_reviewing False"* ]]
}

@test "the run-over-run diff says once why the arc count fell, and then stops" {
    run wa '
def snap(gen, checkouts):
    return wa.snapshot_of([], None, {"mrs": True, "ledger": True, "issues": True,
                                     "reviews": True}, "ul", gen, [], [], checkouts)
old = snap("2026-08-01T09:00:00+0000", [])
del old["checkouts"]
new = snap("2026-08-02T09:00:00+0000", [{"branch": "UL-1816", "age_days": 3}])
after = snap("2026-08-03T09:00:00+0000", [{"branch": "UL-1816", "age_days": 4}])
print("first", wa.diff_runs(old, new, [], None)["checkouts_first_seen"])
print("then", wa.diff_runs(new, after, [], None)["checkouts_first_seen"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"first True"* ]]
    [[ "$output" == *"then False"* ]]
}

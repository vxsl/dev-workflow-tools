#!/usr/bin/env bats
# Tests for the scale the page speaks in: days of work, not commits.
#
# The complaint these correct, in Kyle's words: "the goal is to keep track of the broad
# strokes of my work, not every singular commit everywhere". In fast agentic development an
# agent writes fifty commits in an afternoon and a backup or squash-remnant branch
# multiplies them again, so a commit count measures churn. It was nonetheless the loudest
# figure on the page -- the rung a workstream sat on, the demand under its card, the
# Jira-mismatch row and the aggregate tile all opened on one.
#
# So two things are pinned here. The derivation: distinct AUTHOR-DATE days over the
# distinct commits no remote has, with superseded copies excluded, counted once each
# however many branches carry them. And the wording: every headline says a rung and a
# human scale, and no headline says a number of commits.
#
# Real git repositories, because that is the whole point -- the dates come out of the
# commits and there is nothing to derive from a fixture that hands them over. The degraded
# path, where finalize has no repo to ask, is tested for what it must NOT do: invent one.

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
    git -C "$ARC_REPO" config user.email test@example.com
    git -C "$ARC_REPO" config user.name Tester
    on main 2026-07-01 base
    # A remote-tracking ref rather than a real remote: "--not --remotes" is the whole
    # question, and a bare repo to push into would only be a slower way to write this ref.
    git -C "$ARC_REPO" update-ref refs/remotes/origin/main main
}

teardown() {
    teardown_temp_dir
}

# One empty commit on a branch, authored on the day given. The offset is fixed so the
# day a commit lands on is a fact about the fixture and not about the machine's timezone.
on() {
    local branch="$1" day="$2" msg="$3"
    if git -C "$ARC_REPO" rev-parse --verify -q "$branch" >/dev/null; then
        git -C "$ARC_REPO" checkout -q "$branch"
    else
        git -C "$ARC_REPO" checkout -q -b "$branch"
    fi
    GIT_AUTHOR_DATE="$day 09:00:00 +0000" GIT_COMMITTER_DATE="$day 09:00:00 +0000" \
        git -C "$ARC_REPO" commit -q --allow-empty -m "$msg"
}

wa() {
    python3 - "$ARCS_ROOT/bin/work-arcs" "$ARC_REPO" <<PY
import importlib.machinery, importlib.util, sys, json
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
REPO = sys.argv[2]
sys.argv = ["wa"]
loader.exec_module(wa)
wa.TICKET_RE = wa._ticket_re()

def br(name, **kw):
    b = {"name": name, "sha": "sha-" + name, "unpushed": 0, "commits_ahead": 0,
         "age_days": 5, "parents": [], "pushed": False, "committed": 0}
    b.update(kw)
    return b

def arc(branches, mrs=(), repo=REPO, **kw):
    a = {"id": "a1", "label": "metadata-latlng", "kind": "cluster",
         "branches": list(branches), "mrs": list(mrs), "stashes": [], "sessions": [],
         "issues": [], "engagement": 0, "mrs_known": True}
    a.update(kw)
    wa.finalize(a, repo)
    return a

$1
PY
}

# ── the derivation ───────────────────────────────────────────────────────────

@test "days of work are distinct author days, not commits" {
    on work 2026-08-01 one
    on work 2026-08-01 two
    on work 2026-08-01 three
    on work 2026-08-03 four
    run wa '
a = arc([br("work", unpushed=4)])
print(a["unpushed_live"], a["unpushed_days"], a["unpushed_dates"])'
    [ "${lines[0]}" = "4 2 ['2026-08-01', '2026-08-03']" ]
}

@test "a stack is one body of work, so its shared days are counted once" {
    # The same double-count that made an arc claim 130 unpushed commits where the truth
    # was 98, asked in days: a backup branch is an ancestor of the branch it backs up, so
    # its days ARE that branch's days.
    on work 2026-08-01 one
    on work 2026-08-02 two
    git -C "$ARC_REPO" branch work-backup work
    on work 2026-08-05 three
    run wa '
a = arc([br("work", unpushed=3), br("work-backup", unpushed=2)])
print(a["unpushed_live"], a["unpushed_days"])'
    [ "${lines[0]}" = "3 3" ]
}

@test "a superseded copy contributes no days, because its content is already accounted for" {
    # Supersession is derived, not declared, so the fixture gives the copy the subjects
    # that earn the mark rather than setting it -- finalize recomputes it from scratch on
    # every pass and a hand-set mark would be popped before it was read.
    on work 2026-08-01 one
    on work 2026-08-02 two
    git -C "$ARC_REPO" checkout -q main
    on copy 2026-06-10 one
    on copy 2026-06-11 two
    run wa '
a = arc([br("work", unpushed=2, commits_ahead=2, subjects=["one", "two"]),
         br("copy", unpushed=2, subjects=["one", "two"])])
print([b.get("superseded_by") for b in a["branches"]])
print(a["unpushed_days"], a["unpushed_dates"])'
    [[ "${lines[0]}" == *"work"* ]]
    [ "${lines[1]}" = "2 ['2026-08-01', '2026-08-02']" ]
}

@test "a branch whose merge request landed contributes no days either" {
    on work 2026-08-01 one
    git -C "$ARC_REPO" checkout -q main
    on shipped 2026-05-04 landed-already
    run wa '
a = arc([br("work", unpushed=1),
         br("shipped", unpushed=1, mr_fate={"state": "merged", "iid": 1})])
print(a["unpushed_days"], a["unpushed_dates"])'
    [ "${lines[0]}" = "1 ['2026-08-01']" ]
}

@test "nothing unpushed is no days, and no scale is claimed" {
    run wa '
a = arc([br("main", unpushed=0, pushed=True)])
print(a["unpushed_live"], a["unpushed_days"], a["unpushed_dates"])'
    [ "${lines[0]}" = "0 0 []" ]
}

# ── what the page says ───────────────────────────────────────────────────────

@test "the local-only rung says days of work, never a commit count" {
    # Fifty commits in an afternoon is the case the whole change exists for. The rung must
    # not report fifty of anything.
    on work 2026-08-01 one
    for i in 1 2 3 4 5 6 7 8 9; do on work 2026-08-02 "churn-$i"; done
    on work 2026-08-06 last
    run wa '
a = arc([br("work", unpushed=11)])
print(a["stage"], "|", a["state"], "|", a["unpushed_live"])
print([d["what"] for d in a["demands"]])'
    [ "${lines[0]}" = "local-only | 3 days of work, only here | 11" ]
    [ "${lines[1]}" = "['3 days of work exist nowhere but this laptop']" ]
}

@test "one day of several commits is a day's work" {
    on work 2026-08-01 one
    on work 2026-08-01 two
    run wa '
a = arc([br("work", unpushed=2)])
print(a["state"])
print(a["demands"][0]["what"])'
    [ "${lines[0]}" = "a day's work, only here" ]
    [ "${lines[1]}" = "a day's work exists nowhere but this laptop" ]
}

@test "a single dangling commit claims less than a day, not a whole one" {
    on fix 2026-08-01 one-line-fix
    run wa '
a = arc([br("fix", unpushed=1)])
print(a["state"])
print(a["demands"][0]["what"])'
    [ "${lines[0]}" = "less than a day's work, only here" ]
    [ "${lines[1]}" = "less than a day's work exists nowhere but this laptop" ]
}

@test "the rung still follows the worst thing outstanding, and still says days" {
    # An arc holding an open merge request AND unpublished work is not simply "in review",
    # and the sentence that says so is now in days.
    on work 2026-08-01 one
    on work 2026-08-04 two
    run wa '
mr = {"iid": 10502, "branch": "work", "title": "t", "url": "u", "draft": False,
      "updated": "2026-08-20T00:00:00Z", "threads": [], "reviewers": ["vadym"],
      "assignees": [], "approvals": 0, "notes": 2, "conflicts": False}
a = arc([br("work", unpushed=2, pushed=True, commits_ahead=2)], [mr])
print(a["stage"], "|", a["state"])'
    [ "${lines[0]}" = "local-only | 2 days of work, only here" ]
}

@test "with no repo to ask there are no dates, and no scale is invented" {
    # The degraded path names the condition and stops. A guess here would be a number the
    # page could not defend, which is worse than no number at all.
    run wa '
a = arc([br("nowhere", unpushed=40)], repo=None)
print(a["unpushed_live"], a["unpushed_days"], "|", a["state"])
print(a["demands"][0]["what"])'
    [ "${lines[0]}" = "40 0 | unpushed work, only here" ]
    [ "${lines[1]}" = "unpushed work exists nowhere but this laptop" ]
}

@test "a pushed branch with no merge request names the branch and no number" {
    # Nothing is at risk here, so there is no scale to state -- and the only number that
    # was ever available was a commit count.
    run wa '
a = arc([br("UL-1852", unpushed=0, pushed=True, commits_ahead=7)], mrs_known=True)
print(a["stage"], "|", a["state"])
print([d["what"] for d in a["demands"]])'
    [ "${lines[0]}" = "not-proposed | pushed, no merge request" ]
    [ "${lines[1]}" = "['UL-1852 is pushed and has no merge request']" ]
}

# ── the row that tells you your ticket is lying ──────────────────────────────

@test "the Jira mismatch counts days of work, not commits" {
    on UL-1852 2026-08-01 one
    on UL-1852 2026-08-01 two
    on UL-1852 2026-08-02 three
    on UL-1852 2026-08-07 four
    run wa '
a = arc([br("UL-1852", unpushed=4)])
issues = [{"key": "UL-1852", "status": "In Review", "handed_off": True,
           "summary": "s", "url": "", "updated": "2026-08-20T00:00:00Z"}]
g = wa.reconcile([a], issues)
print(g["status_mismatch"][0]["why"])'
    [ "${lines[0]}" = "status 'In Review' but 3 days of work never pushed" ]
}

@test "a one-day one-commit mismatch degrades rather than rounding up" {
    on UL-99 2026-08-01 only
    run wa '
a = arc([br("UL-99", unpushed=1)])
issues = [{"key": "UL-99", "status": "Done", "handed_off": True,
           "summary": "s", "url": "", "updated": "2026-08-20T00:00:00Z"}]
g = wa.reconcile([a], issues)
print(g["status_mismatch"][0]["why"])'
    [ "${lines[0]}" = "status 'Done' but less than a day's work never pushed" ]
}

# ── the aggregate the page opens on ──────────────────────────────────────────

@test "the tile unions days across workstreams rather than summing them" {
    # A Tuesday spent on two workstreams is one Tuesday. Summing per-arc day counts would
    # be the same double-count in days that per-branch summing was in commits.
    run python3 - "$ARCS_ROOT/bin/arcs-page" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("ap", sys.argv[1])
spec = importlib.util.spec_from_loader("ap", loader)
ap = importlib.util.module_from_spec(spec)
sys.argv = ["ap"]
loader.exec_module(ap)
loc = [{"unpushed_live": 30, "unpushed_dates": ["2026-08-01", "2026-08-04"]},
       {"unpushed_live": 5, "unpushed_dates": ["2026-08-04", "2026-08-05"]}]
days = len({d for x in loc for d in x.get("unpushed_dates") or []})
print(ap.work_scale(days, sum(x["unpushed_live"] for x in loc))[0])
PY
    [ "${lines[0]}" = "3 days of work" ]
}

@test "no headline on a rebuilt page counts commits" {
    # The acceptance test, run over the strings the derivation actually produces rather
    # than over a page: every phrase this change owns, checked for the retired unit.
    on work 2026-08-01 one
    on work 2026-08-04 two
    run wa '
a = arc([br("work", unpushed=2)])
issues = [{"key": "UL-1852", "status": "In Review", "handed_off": True,
           "summary": "s", "url": "", "updated": "2026-08-20T00:00:00Z"}]
a["branches"].append(br("UL-1852", unpushed=0, pushed=True, commits_ahead=9))
wa.finalize(a, REPO)
g = wa.reconcile([a], issues)
said = [a["state"]] + [d["what"] for d in a["demands"]] \
       + [m["why"] for m in g["status_mismatch"]]
print("\n".join(said))
print("COMMITS" if any("commit" in s for s in said) else "NO-COMMITS")'
    [ "${lines[-1]}" = "NO-COMMITS" ]
}

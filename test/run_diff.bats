#!/usr/bin/env bats
# Tests for the run-over-run diff in work-arcs. Only the parts that can be wrong without
# looking wrong -- and every one of them produces a *confident sentence about a change that
# never happened*, which is the expensive failure here (plan principle 5: a wrong "changed
# under you" costs more trust than a missed one).
#
#   - arc identity is the branch set, never the label. The split pass reworded one arc
#     "selected state" -> "selected-state" -> back within an evening; a name-keyed diff
#     reports that arc as deleted and recreated, with every fact on it news both times
#   - a 50/50 split of a two-branch arc has no majority in either direction, so it must
#     resolve to silence rather than to a coin toss between the halves
#   - a 7/3 split leaves the majority holding the identity, and the minority is a new arc
#   - collect_mrs asks GitLab to recompute the mergeability verdicts it lacks, so an
#     `unchecked` that becomes `conflict` is the verdict arriving and not the branch
#     breaking. Every transition with an unknown at either end has to be silent
#   - only the first note of a thread is quoted, so a reviewer's third comment leaves the
#     demand's count, names and oldest date unchanged -- the fingerprint must not
#   - a stage that moved after your own commit moved because of your own commit
#   - a stage that moved while the membership shifted may have moved for that reason alone
#   - an arc's own MRs, threads and issues are compared only where BOTH runs saw them
#   - a snapshot at another version is discarded, not misread
#
# The diff functions are called directly rather than through the CLI: everything they do is
# pure, and going through the CLI would mean standing up a git repo, a GitLab and a Jira to
# test arithmetic over two dicts.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
}

teardown() {
    teardown_temp_dir
}

# Runs a python snippet with work-arcs imported as `wa` and the snapshot helpers in scope.
# Everything printed comes back as $output.
wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" <<PY
import importlib.machinery, importlib.util, sys, json
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
sys.argv = ["wa"]
loader.exec_module(wa)

def sarc(label, branches, **kw):
    """A snapshot row, at rest: nothing here has moved."""
    d = {"id": label, "label": label, "ticket": None, "branches": sorted(branches),
         "stage": "in-review", "state": "in review", "settled": None,
         "own_activity": 1000, "mrs": {}, "threads": [], "ledger": [], "issues": {}}
    d.update(kw)
    return d

def smr(state="opened", merge_state="not_approved", conflicts=False,
        pipeline="success", url="U", at=""):
    return {"state": state, "merge_state": merge_state, "conflicts": conflicts,
            "pipeline": pipeline, "url": url, "at": at}

def snap(arcs, gen="2026-08-14T01:00:00-0700", **known):
    k = {"mrs": True, "ledger": True, "issues": True}
    k.update(known)
    return {"v": 1, "generated": gen, "repo": "ul", "known": k, "arcs": arcs}

def what(prev, cur, arcs=(), ledger=None):
    """Every sentence the diff produces, flattened."""
    d = wa.diff_runs(prev, snap(cur["arcs"], "2026-08-14T05:00:00-0700",
                                **(cur.get("known") or {})), list(arcs), ledger)
    return [w for c in d["changes"] for w in c["what"]]

$1
PY
}

# ── identity ──────────────────────────────────────────────────────────────────

@test "an arc relabelled between runs is the same arc" {
    run wa '
p = snap([sarc("selected state", ["a", "b", "c"], mrs={"1": smr()})])
c = snap([sarc("selected-state", ["a", "b", "c"], mrs={"1": smr()})])
pairs, reg = wa.match_runs(p["arcs"], c["arcs"])
print(len(pairs), len(reg["was"]), len(reg["now"]))
print(what(p, c))'
    [ "${lines[0]}" = "1 0 0" ]
    # ...and nothing about it is news, which is the whole point of matching on membership.
    [ "${lines[1]}" = "[]" ]
}

@test "a 50/50 split has no majority either way, so it is silent" {
    run wa '
p = snap([sarc("X", ["a", "b"], mrs={"1": smr()})])
c = snap([sarc("X1", ["a"], mrs={"1": smr(conflicts=True, merge_state="conflict")}),
          sarc("X2", ["b"])])
pairs, reg = wa.match_runs(p["arcs"], c["arcs"])
print(len(pairs), reg["was"][0]["how"], sorted(r["how"] for r in reg["now"]))
print(what(p, c))'
    [ "${lines[0]}" = "0 split ['split_off', 'split_off']" ]
    # A conflict on one half would have been reported had the halves been matched by a
    # coin toss. It is not, because neither half is a majority of the old arc.
    [ "${lines[1]}" = "[]" ]
}

@test "a 7/3 split leaves the majority holding the identity" {
    run wa '
p = snap([sarc("X", list("abcdefghij"), mrs={"1": smr()})])
c = snap([sarc("X", list("abcdefg"), mrs={"1": smr(pipeline="failed")}),
          sarc("Y", list("hij"))])
pairs, reg = wa.match_runs(p["arcs"], c["arcs"])
print(len(pairs), [r["how"] for r in reg["now"]], reg["was"])
print(what(p, c))'
    [ "${lines[0]}" = "1 ['split_off'] []" ]
    # The seven-branch remainder IS the arc, so a fact about its MR is still comparable.
    [[ "${lines[1]}" == *"pipeline turned failed"* ]]
}

@test "two arcs merging into one is a regrouping, not a change" {
    run wa '
p = snap([sarc("A", ["a", "b"], mrs={"1": smr()}), sarc("B", ["c", "d"])])
c = snap([sarc("AB", list("abcd"), mrs={"1": smr(conflicts=True,
                                                 merge_state="conflict")})])
pairs, reg = wa.match_runs(p["arcs"], c["arcs"])
print(len(pairs), reg["now"][0]["how"], sorted(r["how"] for r in reg["was"]))
print(what(p, c))'
    [ "${lines[0]}" = "0 merged ['absorbed', 'absorbed']" ]
    [ "${lines[1]}" = "[]" ]
}

@test "a branch leaving a three-branch arc keeps the identity but marks it shifted" {
    run wa '
p = snap([sarc("X", ["a", "b", "c"])])
c = snap([sarc("X", ["a", "b"])])
d = wa.diff_runs(p, snap(c["arcs"], "2026-08-14T05:00:00-0700"), [], None)
pairs, reg = wa.match_runs(p["arcs"], c["arcs"])
print(len(pairs), d["changed"])'
    # Matched (2 of 3 is a majority), and silent: nothing but the membership moved.
    [ "$output" = "1 0" ]
}

# ── a verdict arriving is not the world moving ─────────────────────────────────

@test "unchecked becoming a conflict is the recheck landing, not the branch breaking" {
    run wa '
p = snap([sarc("A", ["a"], mrs={"1": smr(merge_state="unchecked")})])
c = snap([sarc("A", ["a"], mrs={"1": smr(merge_state="conflict", conflicts=True)})])
print(what(p, c))'
    [ "$output" = "[]" ]
}

@test "unchecked becoming mergeable is not an approval appearing" {
    run wa '
p = snap([sarc("A", ["a"], mrs={"1": smr(merge_state="unchecked")})])
c = snap([sarc("A", ["a"], mrs={"1": smr(merge_state="mergeable")})])
print(what(p, c))'
    [ "$output" = "[]" ]
}

@test "a known state becoming a conflict IS the branch breaking" {
    run wa '
p = snap([sarc("A", ["a"], mrs={"1": smr()})])
c = snap([sarc("A", ["a"], mrs={"1": smr(merge_state="conflict", conflicts=True)})])
print(what(p, c))'
    [[ "$output" == *"no longer merges into main"* ]]
}

@test "a pipeline with no previous status has not turned anything" {
    run wa '
p = snap([sarc("A", ["a"], mrs={"1": smr(pipeline="")})])
c = snap([sarc("A", ["a"], mrs={"1": smr(pipeline="failed")})])
print(what(p, c))'
    [ "$output" = "[]" ]
}

# ── your own activity is not something changing under you ─────────────────────

@test "a stage that moved after your own commit is your own doing" {
    run wa '
p = snap([sarc("A", ["a"], own_activity=1000)])
c = snap([sarc("A", ["a"], stage="local-only", state="4 commits exist only here",
                own_activity=2000)])
print(what(p, c))'
    [ "$output" = "[]" ]
}

@test "the same stage move with you idle is reported" {
    run wa '
p = snap([sarc("A", ["a"], own_activity=1000)])
c = snap([sarc("A", ["a"], stage="local-only", state="4 commits exist only here",
                own_activity=1000)])
print(what(p, c))'
    [ "$output" = "['moved from in review to 4 commits exist only here']" ]
}

@test "a conflict on a branch you also committed to is still reported" {
    # The own-activity gate gags the aggregate claim, never the facts. A stage move can be
    # explained by your own commit; a reviewer's conflict cannot.
    run wa '
p = snap([sarc("A", ["a"], own_activity=1000, mrs={"1": smr()})])
c = snap([sarc("A", ["a"], own_activity=2000, stage="local-only", state="1 commit",
                mrs={"1": smr(merge_state="conflict", conflicts=True)})])
print(what(p, c))'
    [ "$output" = "['!1 no longer merges into main — a conflict appeared since the last build']" ]
}

@test "a stage move on an arc whose membership shifted is not claimed" {
    run wa '
p = snap([sarc("A", ["a", "b", "c"])])
c = snap([sarc("A", ["a", "b", "c", "d"], stage="local-only", state="1 commit")])
print(what(p, c))'
    [ "$output" = "[]" ]
}

@test "a merge is reported once, in its own words, not twice as a stage move" {
    run wa '
p = snap([sarc("A", ["a"], mrs={"1": smr()})])
c = snap([sarc("A", ["a"], stage="landed", state="landed", settled="landed",
                mrs={"1": smr(state="merged", at="2026-08-14")})])
print(what(p, c))'
    [ "$output" = "['!1 merged on 2026-08-14']" ]
}

# ── only what both runs saw ───────────────────────────────────────────────────

@test "an MR the previous run never saw is not a development" {
    run wa '
p = snap([sarc("A", ["a"], mrs={})])
c = snap([sarc("A", ["a"], mrs={"9": smr(merge_state="conflict", conflicts=True)})])
print(what(p, c))'
    [ "$output" = "[]" ]
}

@test "a run that did not ask GitLab compares no merge requests" {
    run wa '
p = snap([sarc("A", ["a"], mrs={"1": smr()})], mrs=False)
c = snap([sarc("A", ["a"], mrs={"1": smr(merge_state="conflict", conflicts=True)})])
d = wa.diff_runs(p, snap(c["arcs"], "2026-08-14T05:00:00-0700"), [], None)
print(d["skipped_universes"], [w for x in d["changes"] for w in x["what"]])'
    [ "$output" = "['mrs'] []" ]
}

@test "a ticket status is compared only where both runs had one" {
    run wa '
p = snap([sarc("A", ["a"], issues={"UL-1": "In Progress"})])
c = snap([sarc("A", ["a"], issues={"UL-1": "In Review", "UL-2": "To Do"})])
print(what(p, c))'
    [ "$output" = "['UL-1 moved from In Progress to In Review']" ]
}

# ── review threads ────────────────────────────────────────────────────────────

@test "a reviewer's third comment on one thread is a change, though the quote is not" {
    # The demand's sentence is identical either side -- one thread, same author, same
    # oldest date. Only the note count and who spoke last moved, which is what `sig`
    # exists to fingerprint.
    run wa '
def arc_with(threads):
    a = {"id": "A", "label": "A", "stage": "in-review", "state": "in review",
         "settled": None, "own_activity": 1000, "age_days": 1, "urgency": 5,
         "engagement": 0, "ticket": None, "issues": [], "unpushed_live": 0,
         "mrs_known": True, "branches": [{"name": "a", "unpushed": 0, "age_days": 1,
          "parents": [], "pushed": True, "commits_ahead": 1, "committed": 1000}],
         "stashes": [], "sessions": [],
         "mrs": [{"iid": 1, "url": "U", "updated": "2026-08-14", "target": "main",
                  "threads": threads, "pipeline": {"status": "success"}, "draft": False,
                  "approved": False, "conflicts": False, "merge_state": "not_approved"}]}
    a["demands"] = wa.demands(a)
    return a

def t(notes, last_by="logan", answered=False):
    return {"author": "logan", "at": "2026-08-14", "last_by": last_by,
            "last_at": "2026-08-14", "notes": notes, "quote": "why not memoize this?",
            "answered": answered}

one, three = arc_with([t(1)]), arc_with([t(3)])
def sn(a, gen):
    return wa.snapshot_of([a], None, {"mrs": True, "ledger": False, "issues": True},
                          "ul", gen)
d = wa.diff_runs(sn(one, "2026-08-14T01:00:00-0700"),
                 sn(three, "2026-08-14T05:00:00-0700"), [three], None)
print(len(d["changes"]), [w for c in d["changes"] for w in c["what"]])
# ...and your own reply moves it to the bucket that is never reported.
mine = arc_with([t(4, last_by="kyle", answered=True)])
d = wa.diff_runs(sn(three, "2026-08-14T01:00:00-0700"),
                 sn(mine, "2026-08-14T05:00:00-0700"), [mine], None)
print(d["changed"])'
    [[ "${lines[0]}" == "1 ['!1: 1 thread awaiting your reply"* ]]
    [ "${lines[1]}" = "0" ]
}

# ── the store itself ──────────────────────────────────────────────────────────

# These three assert on the last line of $output, because bats folds stderr in and each of
# them is meant to be loud: a snapshot silently ignored looks identical to a quiet night,
# so the note on stderr is part of the behaviour under test rather than noise around it.

@test "a snapshot at another version is discarded rather than misread" {
    printf '{"v": 99, "repo": "ul", "arcs": []}' \
        > "$XDG_STATE_HOME/work-arcs/snapshot.json"
    run wa '
snap_, why = wa.load_snapshot("ul")
print(snap_ is None, why)'
    [[ "${lines[-1]}" == "True the previous snapshot is v99"* ]]
    [[ "$output" == *"discarding snapshot v99"* ]]
}

@test "a snapshot of another repo is discarded" {
    printf '{"v": 1, "repo": "other", "arcs": []}' \
        > "$XDG_STATE_HOME/work-arcs/snapshot.json"
    run wa '
snap_, why = wa.load_snapshot("ul")
print(snap_ is None, "different repo" in why)'
    [ "${lines[-1]}" = "True True" ]
    [[ "$output" == *"discarding a snapshot of 'other'"* ]]
}

@test "a truncated snapshot is a cache miss, not a graph of new work" {
    printf '{"v": 1, "repo": "ul", "arcs": [{"id": "A", "bran' \
        > "$XDG_STATE_HOME/work-arcs/snapshot.json"
    run wa '
snap_, why = wa.load_snapshot("ul")
print(snap_ is None, why)'
    [ "${lines[-1]}" = "True the previous snapshot could not be read" ]
    [[ "$output" == *"could not be read"* ]]
}

@test "the write is atomic and leaves no temp file behind" {
    run wa '
ok = wa.write_snapshot(snap([sarc("A", ["a"])]))
import json
back = json.loads(wa.SNAPSHOT.read_text())
print(ok, back["v"], len(back["arcs"]), wa.SNAPSHOT.with_suffix(".json.tmp").exists())'
    [ "$output" = "True 1 1 False" ]
}

@test "no previous snapshot is a stated reason, not an empty diff" {
    run wa '
snap_, why = wa.load_snapshot("ul")
print(snap_ is None, why)'
    [ "$output" = "True no previous snapshot to compare against" ]
}

# ── ordering ──────────────────────────────────────────────────────────────────

@test "changes are totally ordered, worst first" {
    # Rank ties constantly -- six arcs can all have gone red -- and a stable sort would
    # then hand the page whatever order the arcs arrived in. That order reaches the
    # morning brief, which caches on the text it is given.
    run wa '
p = snap([sarc(n, [n], mrs={"1" + n[-1]: smr()}) for n in ("a1", "b2", "c3")])
c = snap([sarc("c3", ["c3"], mrs={"13": smr(merge_state="conflict", conflicts=True)}),
          sarc("a1", ["a1"], mrs={"11": smr(pipeline="failed")}),
          sarc("b2", ["b2"], mrs={"12": smr(merge_state="mergeable")})])
d = wa.diff_runs(p, snap(c["arcs"], "2026-08-14T05:00:00-0700"), [], None)
print([x["label"] for x in d["changes"]])
# Same arcs, opposite input order: same output.
c2 = snap(list(reversed(c["arcs"])))
d2 = wa.diff_runs(p, snap(c2["arcs"], "2026-08-14T05:00:00-0700"), [], None)
print([x["label"] for x in d2["changes"]])'
    [ "${lines[0]}" = "['c3', 'a1', 'b2']" ]
    [ "${lines[1]}" = "['c3', 'a1', 'b2']" ]
}

@test "what is a projection of evidence, so the two cannot drift apart" {
    run wa '
p = snap([sarc("A", ["a"], mrs={"1": smr(), "2": smr()})])
c = snap([sarc("A", ["a"], mrs={"1": smr(merge_state="conflict", conflicts=True),
                                "2": smr(pipeline="failed")})])
d = wa.diff_runs(p, snap(c["arcs"], "2026-08-14T05:00:00-0700"), [], None)
ch = d["changes"][0]
print(ch["what"] == [e["what"] for e in ch["evidence"]], ch["kinds"])'
    [ "$output" = "True ['conflict', 'pipeline']" ]
}

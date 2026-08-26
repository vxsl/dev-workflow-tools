#!/usr/bin/env bats
# Tests for the closed loop: every noise row dismissible, and what is dismissed reaching
# the pipeline without a person doing anything.
#
# The verdict this exists for: "we need an emphasis on guided/encouraged curation, like for
# example 'real work with no ticket' has some items that i need to be able to dismiss
# easily. i should find it very comfortable to continually clean up noise, which is one of
# the biggest levers in terms of making the dashboard meaningful."
#
# Three things were in the way and each of them gets a section here.
#
#   no coverage    the two gap folds carried no fingerprint and were in none of
#                  apply_dismissals' universes, so their rows had no ✕ at all -- while
#                  the lede opened the page on one of their counts.
#   no closed loop what the page recorded lived in the browser and reached these stores
#                  only by a manual download, which has never once been done.
#   no prompting   the one guided flow was the second-to-last fold on the page.
#
# Nothing here pins wording. Every assertion is about which rows carry a fingerprint, what
# a count includes, which questions get asked and what a store holds afterwards.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    # No test may read or write the real stores: work-arcs resolves every store path at
    # import time, so this is exported before the module loads.
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
}

teardown() {
    teardown_temp_dir
}

# Runs a python snippet with work-arcs imported as wa and gap fixtures in scope.
wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" <<PY
import importlib.machinery, importlib.util, sys, json
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
sys.argv = ["wa"]
loader.exec_module(wa)

def arc(ident, days=6, eng=400, age=4, **kw):
    a = {"id": ident, "label": ident, "kind": "cluster", "stage": "local-only",
         "age_days": age, "engagement": eng,
         "unpushed_live": days * 2, "unpushed_days": days, "unpushed": days * 2,
         "branches": [{"name": "br-" + ident, "sha": "a" * 7}],
         "mrs": [], "demands": [{"kind": "review", "what": "x"}], "issues": [],
         "counts": {"branches": 1, "sessions": 2}}
    a.update(kw)
    a["fingerprint"] = wa.arc_fingerprint(a)
    return a

def issue(key, status="To Do", done=False):
    return {"key": key, "status": status, "done": done, "summary": "about " + key,
            "updated": "2026-08-01T00:00:00.000+0000", "handed_off": False,
            "url": "https://j/" + key}

def dismiss(fp, note=""):
    wa.DISMISSED.parent.mkdir(parents=True, exist_ok=True)
    wa.DISMISSED.write_text(json.dumps({fp: {"ref": "", "at": 1, "note": note}}))

$1
PY
}

# --- coverage: both folds became acknowledgeable ---------------------------------------

@test "every row of both gap folds carries a fingerprint" {
    run wa '
gap = wa.reconcile([arc("smp")], [issue("UL-1")])
print(bool(gap["unticketed_work"][0].get("gap_fp")),
      bool(gap["tickets_without_work"][0].get("gap_fp")))'
    [ "$status" -eq 0 ]
    [ "$output" = "True True" ]
}

# The fingerprint is the fact, never the day it was rendered. Acknowledging says "I know
# this work has no ticket"; another day's commits make that a claim about different work.
@test "a no-ticket acknowledgement expires when the work moves" {
    run wa '
a = arc("smp")
one = wa.reconcile([a], [])["unticketed_work"][0]["gap_fp"]
a["branches"][0]["sha"] = "b" * 7
a["fingerprint"] = wa.arc_fingerprint(a)
two = wa.reconcile([a], [])["unticketed_work"][0]["gap_fp"]
print(one == two)'
    [ "$output" = "False" ]
}

@test "an empty-ticket acknowledgement expires when the status moves" {
    run wa '
one = wa.reconcile([], [issue("UL-1", "To Do")])["tickets_without_work"][0]["gap_fp"]
two = wa.reconcile([], [issue("UL-1", "In Progress")])["tickets_without_work"][0]["gap_fp"]
print(one == two)'
    [ "$output" = "False" ]
}

# A day passing is not the fact moving. A fingerprint that changed at midnight would
# reopen every acknowledged row every morning, which is the one thing a ✕ must not do.
@test "the fingerprint does not move when only the clock does" {
    run wa '
one = wa.reconcile([arc("smp", age=4)], [])["unticketed_work"][0]["gap_fp"]
two = wa.reconcile([arc("smp", age=25)], [])["unticketed_work"][0]["gap_fp"]
print(one == two)'
    [ "$output" = "True" ]
}

# The row IS the workstream and IS the issue -- the same objects the cards elsewhere
# render -- so the mark cannot be the word that already means something about a demand or
# a ledger row. A workstream marked `dismissed` would read as the workstream having been
# acknowledged rather than the one sentence about its missing ticket.
@test "acknowledging a gap row marks the row and never the workstream" {
    run wa '
a = arc("smp")
gap = wa.reconcile([a], [])
dismiss(gap["unticketed_work"][0]["gap_fp"])
wa.apply_dismissals(None, [a], gap)
print(a.get("gap_dismissed"), a.get("dismissed"))'
    [ "$output" = "True None" ]
}

@test "an acknowledgement whose row is gone is pruned" {
    run wa '
gap = wa.reconcile([arc("smp")], [])
dismiss("nothing-matches-this")
wa.apply_dismissals(None, [], gap, prune=True)
print(json.loads(wa.DISMISSED.read_text()))' 2>/dev/null
    [[ "$output" == *"{}"* ]]
}

# --- the guided queue grew a kind ------------------------------------------------------

@test "an unticketed workstream becomes a question" {
    run wa '
gap = wa.reconcile([arc("smp")], [])
q = wa.unticketed_queue(gap)
print(len(q), q[0]["kind"], q[0]["arc_id"])'
    [ "$output" = "1 unticketed smp" ]
}

# One fingerprint over one fact. Two would let the question and the row it is about be
# acknowledged separately, and the page would show a ✕'d row still being asked about.
@test "the question carries the fold row's own fingerprint" {
    run wa '
gap = wa.reconcile([arc("smp")], [])
print(wa.unticketed_queue(gap)[0]["fp"] == gap["unticketed_work"][0]["gap_fp"])'
    [ "$output" = "True" ]
}

# The loop closing, not a filter: a question a person answered coming back next morning is
# the fastest way to teach them that answering is pointless.
@test "an acknowledged row is not asked about" {
    run wa '
a = arc("smp")
gap = wa.reconcile([a], [])
dismiss(gap["unticketed_work"][0]["gap_fp"])
wa.apply_dismissals(None, [a], gap)
print(len(wa.unticketed_queue(gap)))'
    [ "$output" = "0" ]
}

# The size of what Jira cannot see is the size of the fold's whole claim, so it is what
# decides which question is worth asking first.
@test "the biggest pile of invisible work is asked about first" {
    run wa '
gap = wa.reconcile([arc("small", days=1), arc("big", days=9), arc("mid", days=4)], [])
print([q["arc_id"] for q in wa.unticketed_queue(gap)])'
    [ "$output" = "['big', 'mid', 'small']" ]
}

# Total, because arc-brief caches on evidence text and a queue that shuffled between two
# builds of one graph would ask the same five questions in a different order every morning.
@test "two workstreams alike in every figure are asked in the same order twice" {
    run wa '
mk = lambda: [arc("bbb"), arc("aaa")]
one = [q["arc_id"] for q in wa.unticketed_queue(wa.reconcile(mk(), []))]
two = [q["arc_id"] for q in wa.unticketed_queue(wa.reconcile(mk()[::-1], []))]
print(one == two, one)'
    [[ "$output" == "True "* ]]
}

# Membership leads and intent keeps its floor; no-ticket takes what is left and holds none.
# That is a claim about what each kind costs to get wrong, not about what each is worth:
# this is the one kind with somewhere else to be answered.
@test "no-ticket questions take the seats the other two do not want" {
    run wa '
mem = [{"kind": "membership"}] * 2
res = [{"kind": "residue"}]
unt = [{"kind": "unticketed"}] * 4
print([q["kind"] for q in wa.combined_queue(mem, res, unt)])'
    [ "$output" = "['membership', 'membership', 'residue', 'unticketed', 'unticketed']" ]
}

@test "a full membership queue still leaves intent its seat and no-ticket none" {
    run wa '
mem = [{"kind": "membership"}] * 9
res = [{"kind": "residue"}] * 3
unt = [{"kind": "unticketed"}] * 3
print([q["kind"] for q in wa.combined_queue(mem, res, unt)])'
    [ "$output" = "['membership', 'membership', 'membership', 'membership', 'residue']" ]
}

# --- what an answer does ---------------------------------------------------------------

# "It needs a ticket" is a claim about the future -- there is no ticket yet to file it
# under -- so nothing is written and the row stays where it was, still counted, which is
# what wanting a ticket looks like.
@test "wanting a ticket acknowledges nothing" {
    run wa '
q = wa.unticketed_queue(wa.reconcile([arc("smp")], []))[0]
wa.answer_unticketed(q, "ticket")
print(wa.DISMISSED.exists(), json.loads(wa.CURATION_LABELS.read_text())["answer"])'
    [ "$output" = "False ticket" ]
}

# Both acknowledgements go through the one dismissal store, so the fold's ✕, this question
# and --dismiss cannot disagree about a row. They differ only in the note.
@test "fine and noise both acknowledge, and are told apart in the record" {
    run wa '
gap = wa.reconcile([arc("smp"), arc("crash")], [])
qs = {q["arc_id"]: q for q in wa.unticketed_queue(gap)}
wa.answer_unticketed(qs["smp"], "fine")
wa.answer_unticketed(qs["crash"], "noise")
store = json.loads(wa.DISMISSED.read_text())
print(sorted(v["note"] for v in store.values()),
      sorted(json.loads(l)["answer"] for l in wa.CURATION_LABELS.read_text().splitlines()))'
    [ "$output" = "['fine', 'noise'] ['fine', 'noise']" ]
}

# An eval set of corrections alone would score a detector that called everything unfiled as
# perfect. Every answer is recorded, including the one that changes nothing.
@test "every answer reaches the eval set" {
    run wa '
gap = wa.reconcile([arc("a"), arc("b"), arc("c")], [])
for q, ans in zip(wa.unticketed_queue(gap), ["ticket", "fine", "noise"]):
    wa.answer_unticketed(q, ans)
print(len(wa.CURATION_LABELS.read_text().splitlines()))'
    [ "$output" = "3" ]
}

# --- the loop closing ------------------------------------------------------------------

@test "the seed a page publishes is adopted into the stores" {
    seed="$TEST_TMPDIR/seed.json"
    cat >"$seed" <<'EOF'
{"dismissed": {"aaa111": {"ref": "smp", "at": 100, "note": "fine"}},
 "confirmed": {"br-x": {"from": "arc-1", "with": ["br-y"], "at": 101}},
 "answers": [{"kind": "unticketed", "answer": "ticket", "arc_id": "smp", "at": 103}]}
EOF
    run python3 "$REPO_ROOT/bin/work-arcs" --ingest-acks "$seed"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.aaa111.note' "$XDG_STATE_HOME/work-arcs/dismissed.json")" = "fine" ]
    [ "$(jq -r '."br-x".from' "$XDG_STATE_HOME/work-arcs/confirmed.json")" = "arc-1" ]
    [ "$(wc -l <"$XDG_STATE_HOME/work-arcs/curation-labels.jsonl")" -eq 1 ]
}

# A union, because the page's copy is whatever the browser last saw: a page open since
# Tuesday holds Tuesday's set, and letting it replace the file would silently undo every
# judgement made anywhere else since.
@test "adopting never replaces what is already here" {
    echo '{"aaa111": {"ref": "mine", "at": 1, "note": "noise"}}' \
        >"$XDG_STATE_HOME/work-arcs/dismissed.json"
    echo '{"dismissed": {"aaa111": {"ref": "theirs", "at": 99, "note": "fine"}}}' \
        >"$TEST_TMPDIR/seed.json"
    run python3 "$REPO_ROOT/bin/work-arcs" --ingest-acks "$TEST_TMPDIR/seed.json"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.aaa111.note' "$XDG_STATE_HOME/work-arcs/dismissed.json")" = "noise" ]
}

# The one removal, and the only judgement a union cannot express. Nothing else is ever
# deleted here: expiry belongs to apply_dismissals, which is the only thing that knows
# whether a fact moved.
@test "an acknowledgement the page names as taken back is taken back" {
    echo '{"gone": {"ref": "x", "at": 1, "note": ""}, "kept": {"ref": "y", "at": 1}}' \
        >"$XDG_STATE_HOME/work-arcs/dismissed.json"
    echo '{"dismissed": {}, "undismissed": ["gone"]}' >"$TEST_TMPDIR/seed.json"
    run python3 "$REPO_ROOT/bin/work-arcs" --ingest-acks "$TEST_TMPDIR/seed.json"
    [ "$status" -eq 0 ]
    [ "$(jq -r 'has("gone")' "$XDG_STATE_HOME/work-arcs/dismissed.json")" = "false" ]
    [ "$(jq -r 'has("kept")' "$XDG_STATE_HOME/work-arcs/dismissed.json")" = "true" ]
}

# A rebuild that fails after the ingest, or a page republished unchanged, must not count
# one click as two.
@test "adopting the same page twice records one answer" {
    echo '{"answers": [{"kind": "unticketed", "answer": "fine", "arc_id": "smp", "at": 7}]}' \
        >"$TEST_TMPDIR/seed.json"
    python3 "$REPO_ROOT/bin/work-arcs" --ingest-acks "$TEST_TMPDIR/seed.json"
    python3 "$REPO_ROOT/bin/work-arcs" --ingest-acks "$TEST_TMPDIR/seed.json"
    [ "$(wc -l <"$XDG_STATE_HOME/work-arcs/curation-labels.jsonl")" -eq 1 ]
}

# A lost acknowledgement teaches distrust faster than no acknowledgement system does, so a
# seed that could not be read is a failure the caller has to see -- not a quiet no-op that
# reads as success.
@test "a seed that cannot be read is a failure and not a silent no-op" {
    echo 'not json at all' >"$TEST_TMPDIR/seed.json"
    run python3 "$REPO_ROOT/bin/work-arcs" --ingest-acks "$TEST_TMPDIR/seed.json"
    [ "$status" -eq 1 ]
}

@test "a section of the wrong shape is named, and the rest is still adopted" {
    echo '{"dismissed": {"ok1": 1}, "confirmed": ["not", "an", "object"]}' \
        >"$TEST_TMPDIR/seed.json"
    run python3 "$REPO_ROOT/bin/work-arcs" --ingest-acks "$TEST_TMPDIR/seed.json"
    [ "$status" -eq 1 ]
    [[ "$output" == *"confirmed"* ]]
    [ "$(jq -r 'has("ok1")' "$XDG_STATE_HOME/work-arcs/dismissed.json")" = "true" ]
}

# The page's oldest shape for a plain ✕ carries nothing at all. Given a home here it
# becomes the entry the CLI writes, so a click and --dismiss leave the same kind of record.
@test "a bare acknowledgement from the page is given the shape a store keeps" {
    echo '{"dismissed": {"bare": 1}}' >"$TEST_TMPDIR/seed.json"
    run python3 "$REPO_ROOT/bin/work-arcs" --ingest-acks "$TEST_TMPDIR/seed.json"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.bare | type' "$XDG_STATE_HOME/work-arcs/dismissed.json")" = "object" ]
}

# It runs before the repo is even read, so a machine with no JIRA_REPO -- and no git at
# all -- can still adopt what the page recorded.
@test "adopting needs no repo, no network and no clock but its own" {
    unset JIRA_REPO WORK_ARCS_REPO
    echo '{"dismissed": {"x": 1}}' >"$TEST_TMPDIR/seed.json"
    run env -u JIRA_REPO -u WORK_ARCS_REPO \
        python3 "$REPO_ROOT/bin/work-arcs" --ingest-acks "$TEST_TMPDIR/seed.json"
    [ "$status" -eq 0 ]
}

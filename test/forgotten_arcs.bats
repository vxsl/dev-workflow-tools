#!/usr/bin/env bats
# Tests for forgotten-work detection in work-arcs. Only the cases where a wrong verdict
# would look right, because this feature makes an accusation -- "you were deep in this and
# you dropped it" -- and a false one costs more trust than ten true ones earn.
#
# The two failure modes worth guarding, in the plan's own words:
#
#   collapse into "old"        an arc touched steadily but lightly for three weeks is not
#                              forgotten; one hammered for three days and dropped cold is.
#                              The level test and the ratio test each catch one half of
#                              that, and neither alone catches both
#   accuse the working case    an arc whose only silence is a reviewer's queue must never
#                              read as forgotten. Same for parked (declared), settled
#                              (finished) and pre-landing (residue). Four different reasons
#                              for the same silence, and only one of them is forgetting
#
# Plus the arithmetic that decides them: day buckets are local, a stack's commits are one
# body of work and not five, and the dismissal fingerprint has to die the moment the arc
# is touched again.
#
# activity_of and mark_forgotten are called directly. Both are pure over their inputs, and
# reaching them through the CLI would mean standing up a git repo, a GitLab and a Jira to
# test arithmetic over a dict of day counts.

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

# Runs a python snippet with work-arcs imported as `wa` and the arc builders in scope.
wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" <<PY
import importlib.machinery, importlib.util, sys, time, json
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
sys.argv = ["wa"]
loader.exec_module(wa)

TODAY = wa.day_no(time.time())

def sess(spec):
    """{days_ago: (entries, sessions)} -> what session_index hands build_arcs."""
    return {TODAY - ago: {"entries": n,
                          "paths": {"/p/s%d-%d.jsonl" % (ago, i) for i in range(s)}}
            for ago, (n, s) in spec.items()}

def cmts(spec, tag="c"):
    """{days_ago: n} -> a branch's commit list, stamped at local noon of each day."""
    out = []
    for ago, n in spec.items():
        at = (TODAY - ago) * wa.DAY - wa.LOCAL_OFFSET + 12 * 3600
        out += [{"at": at, "sha": "%s%d-%d" % (tag, ago, i)} for i in range(n)]
    return out

def br(name, commits=(), **kw):
    d = {"name": name, "sha": name[:9], "commits": list(commits)}
    d.update(kw)
    return d

def arc(session=None, branches=(), **kw):
    a = {"id": "A", "label": "A", "branches": list(branches), "landed_branches": 0,
         "settled": None, "parked": None, "stage": "local-only"}
    a.update(kw)
    a["activity"] = wa.activity_of(a, session or {})
    wa.mark_forgotten(a)
    return a

def v(a):
    return a["activity"].get("forgotten") or {}

$1
PY
}

# ── the shape the plan named ──────────────────────────────────────────────────

@test "hammered for three days and dropped cold is forgotten, in the plan's words" {
    run wa '
a = arc(sess({14: (900, 8), 13: (700, 7), 12: (500, 4)}))
print(v(a)["verdict"])
print(v(a)["why"])'
    [ "${lines[0]}" = "True" ]
    [ "${lines[1]}" = "19 sessions across 3 days, then nothing for 12 days, never landed." ]
}

@test "touched steadily but lightly for three weeks is not forgotten" {
    # Same 12-day silence, same three-week span, a fifth of the investment. Nothing was
    # lost here worth telling anybody about, and age alone could not tell the two apart --
    # which is exactly what made the loose-ends list useless.
    run wa '
a = arc(sess({d: (20, 1) for d in range(12, 33, 2)}))
print(v(a)["verdict"], a["activity"]["invested"]["days"], a["activity"]["cliff_days"])
print(v(a)["why"])'
    [ "${lines[0]}" = "False 11 12" ]
    [[ "${lines[1]}" == "only 220 entries and 0 commits went in"* ]]
}

@test "one missed beat on a slow rhythm is a pause, not a cliff" {
    # The derivative doing the work the level cannot. This arc is heavily invested and
    # eight days quiet -- but it was only ever touched every fourth day, so eight days is
    # two of its own beats. Measured on the real corpus this is the only test that rejects
    # UB-6828, and rejecting it is right.
    run wa '
a = arc(sess({d: (400, 2) for d in range(8, 33, 4)}))
print(v(a)["verdict"], a["activity"]["typical_gap_days"], a["activity"]["cliff_days"])
print(v(a)["why"])'
    [ "${lines[0]}" = "False 4 8" ]
    [[ "${lines[1]}" == *"a pause, not a cliff"* ]]
}

@test "the same silence on a daily rhythm is a cliff" {
    # Identical cliff_days to the test above, opposite verdict, and the only thing that
    # differs is the rhythm it is measured against. That is the whole claim of item 5.
    run wa '
a = arc(sess({d: (400, 2) for d in range(8, 15)}))
print(v(a)["verdict"], a["activity"]["typical_gap_days"], a["activity"]["cliff_days"])'
    [ "$output" = "True 1 8" ]
}

# ── silence that is not forgetting ────────────────────────────────────────────

@test "an arc waiting on a reviewer is never forgotten" {
    # The one this must not get wrong. A review wait is the system working; calling it
    # forgotten accuses him of dropping the one workflow that is not dropped.
    run wa '
a = arc(sess({14: (900, 8), 13: (700, 7), 12: (500, 4)}), stage="in-review")
print(v(a)["verdict"])
print(v(a)["why"])'
    [ "${lines[0]}" = "False" ]
    [[ "${lines[1]}" == *"the clock is a reviewer"* ]]
}

@test "a parked arc is set aside on purpose, not forgotten" {
    run wa '
a = arc(sess({14: (900, 8), 13: (700, 7), 12: (500, 4)}),
        parked={"at": 1, "note": "after the release"}, stage="parked")
print(v(a)["verdict"])
print(v(a)["why"])'
    [ "${lines[0]}" = "False" ]
    [[ "${lines[1]}" == *"parked on purpose"* ]]
}

@test "a landed arc is finished, not forgotten" {
    run wa '
a = arc(sess({14: (900, 8), 13: (700, 7), 12: (500, 4)}), settled="landed",
        stage="landed")
print(v(a)["verdict"], v(a)["why"])'
    [ "$output" = "False landed — finished, not forgotten" ]
}

@test "branches older than a sibling's landing are residue, not forgotten" {
    run wa '
a = arc(sess({14: (900, 8), 13: (700, 7), 12: (500, 4)}), stage="pre-landing")
print(v(a)["verdict"])
print(v(a)["why"])'
    [ "${lines[0]}" = "False" ]
    [[ "${lines[1]}" == *"drafts from before a sibling landed"* ]]
}

@test "still-live work is not forgotten, however much went into it" {
    run wa '
a = arc(sess({2: (4000, 20), 1: (3000, 15), 0: (900, 6)}))
print(v(a)["verdict"])
print(v(a)["why"])'
    [ "${lines[0]}" = "False" ]
    [[ "${lines[1]}" == "still live — last touched 0 days ago" ]]
}

@test "past the ceiling it is archaeology, which is the list this replaces" {
    run wa '
a = arc(branches=[br("b", cmts({92: 12, 91: 14, 90: 9}))])
print(v(a)["verdict"])
print(v(a)["why"])'
    [ "${lines[0]}" = "False" ]
    [[ "${lines[1]}" == *"past recovering from memory"* ]]
}

# ── the level, on either axis ─────────────────────────────────────────────────

@test "an arc built by hand qualifies on commits with no session at all" {
    # Sessions reach back only as far as the transcripts do, so commits have to be able
    # to carry a verdict alone -- and the sentence has to read as one body of work rather
    # than as a missing session count.
    run wa '
a = arc(branches=[br("b", cmts({16: 9, 15: 11, 14: 6}))])
print(v(a)["verdict"])
print(v(a)["why"])'
    [ "${lines[0]}" = "True" ]
    [ "${lines[1]}" = "26 commits across 3 days, then nothing for 14 days, never landed." ]
}

@test "a stack is one body of work, not five copies of it" {
    # Three branches of a stack share their commits by sha, and a fourth is a superseded
    # copy whose content already lives on the branch that supersedes it. Counting either
    # would let a five-branch arc claim five times the investment it holds -- the same
    # correction distinct_unpushed makes, for the same reason.
    run wa '
c = cmts({16: 9, 15: 11})
a = arc(branches=[br("tip", c), br("mid", c[:9]), br("base", c[:4]),
                  br("tip-bak", cmts({16: 30}, tag="x"), superseded_by="tip")])
print(a["activity"]["invested"]["commits"])
print(v(a)["verdict"], v(a)["why"])'
    [ "${lines[0]}" = "20" ]
    [[ "${lines[1]}" == "True 20 commits across 2 days"* ]]
}

@test "an arc part of which landed does not claim it never landed" {
    # "never landed" beside a row already reading "7 already merged" is a flat
    # contradiction, and that mixture is common enough to have its own line in finalize.
    run wa '
a = arc(branches=[br("b", cmts({20: 12, 19: 14}))], landed_branches=7)
print(v(a)["why"])'
    [ "$output" = "26 commits across 2 days, then nothing for 19 days — 7 branches landed, what is left never did." ]
}

@test "an arc with no evidence at all gets no verdict rather than a false one" {
    # Absence of evidence is not evidence of a cliff. A zero series would invite the
    # verdict to fire on the strength of knowing nothing.
    run wa '
a = arc()
print(a["activity"]["invested"], a["activity"]["series"], "forgotten" in a["activity"])'
    [ "$output" = "None [] False" ]
}

# ── the series ────────────────────────────────────────────────────────────────

@test "the series is [days_ago, count] pairs, newest first, with no empty days in it" {
    # 90 zeroes are not data, they are the absence of it -- and the morning brief has to
    # read this.
    run wa '
a = arc(sess({14: (900, 8), 12: (500, 4)}), branches=[br("b", cmts({12: 3}))])
print(a["activity"]["series"])
print(a["activity"]["first_active"] < a["activity"]["last_active"])'
    [ "${lines[0]}" = "[[12, 503], [14, 900]]" ]
    [ "${lines[1]}" = "True" ]
}

@test "a day is a local day, so an evening does not become two days' work" {
    # Bucketing on UTC splits one sitting at UTC-7 across two days, which inflates active
    # days and so deflates the intensity that separates a burst from a trickle.
    run wa '
midnight = TODAY * wa.DAY - wa.LOCAL_OFFSET
print(wa.day_no(midnight) == wa.day_no(midnight + 86399) == TODAY)
print(wa.day_no(midnight - 1) == TODAY - 1, wa.day_no(midnight + 86400) == TODAY + 1)
print(wa.day_str(TODAY) == time.strftime("%Y-%m-%d"))'
    [ "${lines[0]}" = "True" ]
    [ "${lines[1]}" = "True True" ]
    [ "${lines[2]}" = "True" ]
}

# ── acknowledgement ───────────────────────────────────────────────────────────

@test "the dismissal fingerprint dies the moment the arc is touched again" {
    # Keyed to the arc plus the day it went quiet, so a commit landing on it does not
    # merely change the sentence -- it expires the acknowledgement, and the arc comes
    # back on its own. Same contract as parking and as every ledger row.
    run wa '
old = arc(sess({14: (900, 8), 13: (700, 7), 12: (500, 4)}))
same = arc(sess({14: (900, 8), 13: (700, 7), 12: (500, 4)}))
moved = arc(sess({14: (900, 8), 13: (700, 7), 12: (500, 4), 1: (10, 1)}))
renamed = arc(sess({14: (900, 8), 13: (700, 7), 12: (500, 4)}), label="B")
print(v(old)["fp"] == v(same)["fp"])
print(v(old)["fp"] == v(moved)["fp"], v(old)["fp"] == v(renamed)["fp"])'
    [ "${lines[0]}" = "True" ]
    [ "${lines[1]}" = "False False" ]
}

@test "only a positive verdict is acknowledgeable" {
    # The negative verdicts exist so a consumer can ask why an arc was NOT called
    # forgotten. There is nothing there to acknowledge, and putting them in the dismissal
    # universe would fill the store with rows nobody can ever click.
    run wa '
yes = arc(sess({14: (900, 8), 13: (700, 7), 12: (500, 4)}))
no = arc(sess({14: (900, 8), 13: (700, 7), 12: (500, 4)}), stage="in-review")
live = {}
for a in (yes, no):
    f = (a.get("activity") or {}).get("forgotten") or {}
    if f.get("verdict") and f.get("fp"):
        live[f["fp"]] = f
print(len(live), bool(v(no).get("fp")))'
    [ "$output" = "1 True" ]
}

@test "a verdict is recomputed, never accumulated" {
    # mark_forgotten runs after apply_parked and after the second finalize pass. A True
    # left over from a run before the park would outlive the facts that produced it.
    run wa '
a = arc(sess({14: (900, 8), 13: (700, 7), 12: (500, 4)}))
was = v(a)["verdict"]
a["parked"] = {"at": 1, "note": ""}
wa.mark_forgotten(a)
print(was, v(a)["verdict"])'
    [ "$output" = "True False" ]
}

# ── ordering ──────────────────────────────────────────────────────────────────

@test "forgotten arcs are ordered freshest cliff first, and totally" {
    # Freshest first because the one you can still resume is the one you fell off most
    # recently. Total down to the label, because arc-brief fingerprints evidence text and
    # any order that reaches output has to be the same order twice.
    run wa '
def one(label, ago):
    a = arc(sess({ago: (900, 3), ago + 1: (900, 3), ago + 2: (900, 3)}), label=label,
            id=label)
    return a
arcs = [one("zulu", 20), one("alpha", 10), one("mike", 10), one("bravo", 30)]
print([a["label"] for a in wa.fell_off_a_cliff(arcs)])
print([a["label"] for a in wa.fell_off_a_cliff(list(reversed(arcs)))])'
    [ "${lines[0]}" = "['alpha', 'mike', 'zulu', 'bravo']" ]
    [ "${lines[1]}" = "['alpha', 'mike', 'zulu', 'bravo']" ]
}

@test "a dismissed verdict can be excluded without changing the order of the rest" {
    run wa '
def one(label, ago):
    return arc(sess({ago: (900, 3), ago + 1: (900, 3)}), label=label, id=label)
arcs = [one("alpha", 10), one("mike", 12), one("zulu", 14)]
arcs[1]["activity"]["forgotten"]["dismissed"] = True
print([a["label"] for a in wa.fell_off_a_cliff(arcs, include_dismissed=False)])
print([a["label"] for a in wa.fell_off_a_cliff(arcs)])'
    [ "${lines[0]}" = "['alpha', 'zulu']" ]
    [ "${lines[1]}" = "['alpha', 'mike', 'zulu']" ]
}

# ── the knobs ─────────────────────────────────────────────────────────────────

@test "every threshold is env-tunable, because the right value is one corpus's" {
    WORK_ARCS_FORGOTTEN_COMMITS=8 run wa '
a = arc(branches=[br("b", cmts({16: 5, 15: 5}))])
print(v(a)["verdict"], a["activity"]["invested"]["commits"])'
    [ "$output" = "True 10" ]

    # ...and the same arc under the measured default is below the line.
    run wa '
a = arc(branches=[br("b", cmts({16: 5, 15: 5}))])
print(v(a)["verdict"])'
    [ "$output" = "False" ]
}

# ── the page ──────────────────────────────────────────────────────────────────

# Runs a python snippet with arcs-page imported as `pg`.
pg() {
    python3 - "$REPO_ROOT/bin/arcs-page" <<PY
import importlib.machinery, importlib.util, sys, re
loader = importlib.machinery.SourceFileLoader("pg", sys.argv[1])
spec = importlib.util.spec_from_loader("pg", loader)
pg = importlib.util.module_from_spec(spec)
sys.argv = ["pg"]
loader.exec_module(pg)

def act(*ago):
    return {"series": [[d, 10] for d in sorted(ago, reverse=True)]}

def xs(svg):
    return [float(x) for x in re.findall(r'<rect x="([-0-9.]+)"', svg)]

def hs(svg):
    return {h for h in re.findall(r'height="([0-9.]+)" rx=', svg)}

$1
PY
}

# Renders a whole page from a minimal work-arcs document.
page() {
    python3 - "$REPO_ROOT/bin/arcs-page" "$1" <<'PY' > "$TEST_TMPDIR/page.html"
import json, subprocess, sys
doc = json.loads(sys.argv[2])
r = subprocess.run([sys.executable, sys.argv[1], "--focus", "14"],
                   input=json.dumps(doc), capture_output=True, text=True)
sys.stderr.write(r.stderr)
sys.stdout.write(r.stdout)
PY
    cat "$TEST_TMPDIR/page.html"
}

@test "the sparkline axis is the section's, so two rows can be read against each other" {
    # Scaled per row, an 8-day cliff after two days' work and a 43-day cliff after
    # eighteen draw the same picture -- immediately beside the column that says 8d and
    # 43d. A chart the number next to it has to correct is worse than no chart.
    run pg '
span = 61
near = xs(pg.cliff_spark(act(8, 9), span))
far  = xs(pg.cliff_spark(act(43, 61), span))
print(max(near) > max(far), round(max(near)), round(max(far)))'
    [ "$output" = "True 82 28" ]
}

@test "every tick is the same height, because the units are not commensurable" {
    # A height axis over entries-plus-commits flattened sixteen commit days of UB-6908 to
    # the minimum stroke behind one 514-entry session, and said "one spike then nothing"
    # about seventeen days of work.
    run pg '
svg = pg.cliff_spark({"series": [[3, 514], [4, 11], [9, 1]]}, 20)
print(sorted(hs(svg)))'
    [ "$output" = "['15.0']" ]
}

@test "nothing is drawn where there is nothing to draw" {
    run pg '
print(repr(pg.cliff_spark({"series": []}, 20)), repr(pg.cliff_spark(act(4), 0)))'
    [ "$output" = "'' ''" ]
}

@test "a day older than the axis is clamped onto it, never drawn off the edge" {
    # The domain is the section's longest history so this cannot arise -- but off-canvas
    # is the one failure mode that would lose evidence silently rather than loudly.
    run pg '
print(min(xs(pg.cliff_spark(act(3, 90), 20))))'
    [ "$output" = "0.0" ]
}

@test "the page has no cliff section when nothing fell off one" {
    # Silence, not an empty state. A section reading "0 forgotten" every morning trains
    # you to stop reading it, and then the morning it says 1 you will not see that either.
    run page '{"generated": "2026-08-14T09:00:00-0700", "repo": "r", "arc_count": 1,
      "arcs": [{"id": "A", "label": "A", "stage": "local-only", "state": "x",
                "age_days": 1, "branches": [], "mrs": [], "stashes": [], "sessions": [],
                "counts": {}, "demands": [], "issues": [],
                "activity": {"series": [[1, 5]], "invested": {"entries": 5},
                             "cliff_days": 1,
                             "forgotten": {"verdict": false, "why": "still live"}}}]}'
    [[ "$output" != *"Fell off a cliff"* ]]
}

@test "a forgotten row carries its sentence and an acknowledge control" {
    run page '{"generated": "2026-08-14T09:00:00-0700", "repo": "r", "arc_count": 1,
      "arcs": [{"id": "A", "label": "A", "stage": "local-only", "state": "x",
                "age_days": 12, "branches": [], "mrs": [], "stashes": [], "sessions": [],
                "counts": {}, "demands": [], "issues": [],
                "activity": {"series": [[12, 5], [14, 9]],
                             "invested": {"entries": 900, "commits": 0},
                             "cliff_days": 12, "last_active": "2026-08-02",
                             "forgotten": {"verdict": true, "fp": "deadbeefdeadbeef",
                                           "why": "19 sessions across 3 days, then nothing for 12 days, never landed."}}}]}'
    [[ "$output" == *"Fell off a cliff"* ]]
    [[ "$output" == *"19 sessions across 3 days, then nothing for 12 days, never landed."* ]]
    [[ "$output" == *'data-fp="deadbeefdeadbeef"'* ]]
    [[ "$output" == *'class="dis"'* ]]
    # In the focus window, so its name links to the row it also renders as.
    [[ "$output" == *'<a href="#ws-a-'* ]]
}

@test "a forgotten arc outside the focus window is named but not linked" {
    # Most of them are outside it -- an arc that went quiet five weeks ago is by
    # construction hidden by a two-week window, which is why nobody was going to notice
    # it. An anchor to a row that was never rendered is the same lie as a link to a 404.
    run page '{"generated": "2026-08-14T09:00:00-0700", "repo": "r", "arc_count": 1,
      "arcs": [{"id": "Zed", "label": "Zed", "stage": "local-only", "state": "x",
                "age_days": 43, "branches": [], "mrs": [], "stashes": [], "sessions": [],
                "counts": {}, "demands": [], "issues": [],
                "activity": {"series": [[43, 5], [61, 9]],
                             "invested": {"entries": 0, "commits": 426},
                             "cliff_days": 43, "last_active": "2026-07-02",
                             "forgotten": {"verdict": true, "fp": "f0f0f0f0f0f0f0f0",
                                           "why": "426 commits across 18 days, then nothing for 43 days, never landed."}}}]}'
    [[ "$output" == *"Fell off a cliff"* ]]
    [[ "$output" == *"426 commits across 18 days"* ]]
    [[ "$output" != *'href="#ws-zed-'* ]]
}

@test "a junk knob falls back to the measured default rather than to zero" {
    # An empty or unparseable env var must not silently turn the level test off, which
    # would make every quiet arc on the page read as forgotten.
    WORK_ARCS_FORGOTTEN_COMMITS=banana run wa 'print(wa._knob("min_commits"))'
    [ "$output" = "20" ]

    WORK_ARCS_FORGOTTEN_CLIFF="" run wa 'print(wa._knob("cliff_days"))'
    [ "$output" = "7" ]
}

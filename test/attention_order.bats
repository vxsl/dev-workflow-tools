#!/usr/bin/env bats
# Tests for what the page puts first, and why.
#
# One verdict underneath all of them: "the tool is too obsessed with me having commits on
# my laptop. i guess i do want that information somewhere but it's not the main signal of
# unfinished work". Local-only work gets a permanent home -- the ranked disclosure, which
# these must not weaken -- and it does not get the first attention slot. Those belong to
# loops with a person and a clock on them, because those compound while they wait and a
# commit sitting on this disk does not.
#
# DEMAND_RANK already said so: every came-back kind ranks above `unpushed`. What these pin
# is the presentation agreeing with it -- the order of the condition tiles, the order
# inside a recency group, and the one ranking behind the Jira-mismatch table and both
# sentences that name its worst row.
#
# Nothing here pins wording. Every assertion is about which thing came first.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    export JIRA_PROJECTS="UL,UB"
}

teardown() {
    teardown_temp_dir
}

# Runs a python snippet with work-arcs imported as `wa`.
wa() {
    python3 - "$ARCS_ROOT/bin/work-arcs" <<PY
import importlib.machinery, importlib.util, sys, json
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
sys.argv = ["wa"]
loader.exec_module(wa)
wa.TICKET_RE = wa._ticket_re()

def issue(key, status, updated, handed_off=True):
    return {"key": key, "summary": key + " summary", "status": status,
            "handed_off": handed_off, "updated": updated,
            "url": "https://jira.example/browse/" + key}

def arc(aid, key, days, live=None, age=3):
    """One arc owning the ticket, through a branch name: where the map reads it from."""
    return {"id": aid, "label": key, "kind": "ticket", "ticket": key, "age_days": age,
            "unpushed_live": days * 3 if live is None else live,
            "unpushed_days": days, "engagement": 300, "settled": None,
            "issues": [], "branches": [{"name": key.lower() + "-work"}], "mrs": []}

$1
PY
}

# ── the one ranking behind the Jira table and both sentences that quote it ────

@test "the mismatch that has gone longest uncorrected leads, not the widest" {
    # The size of the pile on this laptop used to decide which ticket the page called out
    # to the team. A status nobody has corrected in two months is wrong in a way that
    # compounds every time somebody reads it; a fortnight of local work behind a ticket
    # touched this morning is not.
    run wa '
issues = [issue("UL-101", "In Review", "2026-08-24"),
          issue("UL-102", "Releasing", "2026-06-01")]
arcs = [arc("a1", "UL-101", 14), arc("a2", "UL-102", 1)]
g = wa.reconcile(arcs, issues)
print([m["ref"] for m in g["status_mismatch"]])'
    [ "${lines[0]}" = "['UL-102', 'UL-101']" ]
}

@test "each row carries the figure that ordered it" {
    # A column of days that does not descend reads as a broken sort unless the row also
    # prints the number that broke it -- the rule the at-risk list already follows.
    run wa '
issues = [issue("UL-101", "In Review", "2026-08-24")]
g = wa.reconcile([arc("a1", "UL-101", 4)], issues)
m = g["status_mismatch"][0]
print(isinstance(m["stale_days"], int), m["stale_days"] >= 0)'
    [ "${lines[0]}" = "True True" ]
}

@test "days of work breaks a tie on the clock, and commits break a tie on that" {
    # Not gone, demoted. Two tickets Jira has been equally wrong about for equally long
    # are still separated by how much work the wrong status hides -- and 202 commits over
    # one agentic afternoon is still less work than nine days of it.
    run wa '
issues = [issue("UL-101", "In Review", "2026-07-01"),
          issue("UL-102", "In Review", "2026-07-01")]
arcs = [arc("a1", "UL-101", 1, live=202), arc("a2", "UL-102", 9, live=12)]
g = wa.reconcile(arcs, issues)
print([m["ref"] for m in g["status_mismatch"]])'
    [ "${lines[0]}" = "['UL-102', 'UL-101']" ]
}

@test "a ticket with no date to read is ranked, not dropped" {
    # An unknown clock is not a claim that the record went wrong today, but the row is
    # still a contradiction and still has to appear.
    run wa '
issues = [issue("UL-101", "In Review", ""), issue("UL-102", "In Review", "2026-08-01")]
g = wa.reconcile([arc("a1", "UL-101", 5), arc("a2", "UL-102", 1)], issues)
print([(m["ref"], m["stale_days"] > 0) for m in g["status_mismatch"]])'
    [ "${lines[0]}" = "[('UL-102', True), ('UL-101', False)]" ]
}

@test "two mismatches alike in every figure come back in the same order twice" {
    run wa '
issues = [issue("UL-109", "In Review", "2026-08-01"),
          issue("UL-102", "In Review", "2026-08-01")]
arcs = [arc("a9", "UL-109", 3), arc("a2", "UL-102", 3)]
one = [m["ref"] for m in wa.reconcile(arcs, issues)["status_mismatch"]]
two = [m["ref"] for m in wa.reconcile(arcs[::-1], issues[::-1])["status_mismatch"]]
print(one == two, one)'
    [ "${lines[0]}" = "True ['UL-102', 'UL-109']" ]
}

@test "the fingerprint does not move when the clock does" {
    # A row acknowledged on Tuesday must not reopen on Wednesday because one more day
    # passed. The staleness ranks the row; the status and the scale identify it.
    run wa '
a = wa.reconcile([arc("a1", "UL-101", 4)],
                 [issue("UL-101", "In Review", "2026-08-01")])["status_mismatch"][0]
b = wa.reconcile([arc("a1", "UL-101", 4)],
                 [issue("UL-101", "In Review", "2026-05-01")])["status_mismatch"][0]
print(a["fp"] == b["fp"], a["stale_days"] != b["stale_days"])'
    [ "${lines[0]}" = "True True" ]
}

# ── what the page leads with ─────────────────────────────────────────────────

# A work-arcs document holding one workstream per rung, plus whatever gap is handed in.
# Every arc sits in the same recency bucket unless a test moves it.
doc() {
    python3 - "$@" <<'PY'
import json, sys

def arc(aid, stage, urgency, unpushed=0, age=3, **kw):
    a = {"id": aid, "label": aid, "kind": "cluster", "stage": stage,
         "state": stage + " state", "urgency": urgency,
         "unpushed_live": unpushed, "unpushed_days": unpushed,
         "unpushed_dates": ["2026-08-%02d" % (d + 1) for d in range(unpushed)],
         "age_days": age, "engagement": 300, "authoritative": "br-" + aid,
         "branches": [], "mrs": [], "stashes": [], "sessions": [], "issues": [],
         "demands": [], "counts": {"branches": 1, "stashes": 0, "mrs": 0, "sessions": 1},
         "brief": {"name": aid, "summary": "It reroutes the thing."}}
    a.update(kw)
    return a

arcs = [arc("came-back-one", "came-back", 0),
        arc("in-review-one", "in-review", 9),
        arc("local-one", "local-only", 5, unpushed=6),
        arc("no-reviewer-one", "no-reviewer", 6),
        arc("not-proposed-one", "not-proposed", 7)]
live = [x for x in arcs if x["unpushed_live"]]
live.sort(key=lambda x: (-(x["unpushed_days"] * max(x["age_days"], 1)), x["id"]))
doc = {"generated": 1756000000, "repo": "ul", "main": "origin/main", "me": "kyle",
       "project_url": "https://gitlab.example/ul", "arc_count": len(arcs),
       "arcs": arcs, "forgotten": [], "only_here": [x["id"] for x in live],
       "gap": json.loads(sys.argv[1]) if len(sys.argv) > 1 else None}
print(json.dumps(doc))
PY
}

# Renders a whole page from a work-arcs document handed over as JSON on argv.
page() {
    python3 - "$ARCS_ROOT/bin/arcs-page" "$1" <<'PY'
import json, subprocess, sys
r = subprocess.run([sys.executable, sys.argv[1], "--focus", "30"],
                   input=sys.argv[2], capture_output=True, text=True)
sys.stderr.write(r.stderr)
if r.returncode != 0:
    sys.exit(r.returncode)
sys.stdout.write(r.stdout)
PY
}

# The condition tiles, in the order they are rendered.
tiles() {
    python3 - "$1" <<'PY'
import re, sys
html = open(sys.argv[1]).read()
strip = re.search(r'<ul class="conditions">.*?</ul>', html, re.S)
print(" | ".join(re.findall(r'<span class="l">([^<]*)</span>', strip.group(0))))
PY
}

@test "the strip leads with the loops that have somebody else in them" {
    page "$(doc)" > "$TEST_TMPDIR/page.html"
    run tiles "$TEST_TMPDIR/page.html"
    [ "$output" = "have come back to you | are out for review | exist only on this laptop | have a merge request nobody was asked to read | are pushed but never proposed" ]
}

@test "the self-facing tiles follow DEMAND_RANK, not the ladder's own order" {
    # An open merge request nobody was asked to read bites sooner than a branch with no
    # merge request at all -- unrequested 6, unreviewed 7 -- and the strip printed them
    # the other way round, so the ladder's shape was overriding the demand table.
    page "$(doc)" > "$TEST_TMPDIR/page.html"
    run tiles "$TEST_TMPDIR/page.html"
    [[ "$output" == *"nobody was asked to read | are pushed but never proposed"* ]]
}

# Four display figures at 2rem across the middle of the page, every one of them already
# printed on the rail or on a door three inches to the left. That is not emphasis, it is
# repetition wearing emphasis' clothes -- so the strip is lines now, in the shape of the
# disclosure that sits directly under it. Demoted and not deleted: this pins that every
# count, every subtitle and every anchor came through the change.
@test "the conditions are lines, and every count, subtitle and anchor survives" {
    page "$(doc)" > "$TEST_TMPDIR/page.html"
    run python3 - "$TEST_TMPDIR/page.html" <<'PY'
import re, sys
html = open(sys.argv[1]).read()
strip = re.search(r'<ul class="conditions">.*?</ul>', html, re.S).group(0)
rows = re.findall(r'<li>.*?</li>', strip, re.S)
print(len(rows))
# Every row still carries its figure, its label, its subtitle and its anchor.
print("WHOLE" if all(re.search(r'class="v">\d+<', r) and 'class="l"' in r
                     and 'class="sub"' in r and 'href="#' in r for r in rows)
      else "LOST-SOMETHING")
# And no row is a display figure any more: the count is set in the page's own body face,
# which is what a line is.
print("LINES" if '<span class="v">' not in strip else "TILES")
# One line each, in the source order the strip already argues for.
print(" ".join(re.search(r'class="v">(\d+)<', r).group(1) for r in rows))
PY
    [ "${lines[0]}" = "5" ]
    [ "${lines[1]}" = "WHOLE" ]
    [ "${lines[2]}" = "LINES" ]
}

@test "the local-only tile keeps its scale and still opens the disclosure" {
    # Moved one place to the right, not demoted and not shrunk. The tile is the only way
    # into the ranked list of which work is only here, and that list is the whole reason
    # the fact is safe to stop leading with.
    run page "$(doc)"
    [[ "$output" == *'href="#only-here"'* ]]
    [[ "$output" == *"6 days of work, no remote has them"* ]]
    [[ "$output" == *'<details class="atrisk" id="only-here">'* ]]
}

@test "within a group, what came back outranks a bigger pile on this laptop" {
    # The correction, in one comparison. Both were last touched the same day; one holds
    # six days of unpublished work and wants nothing from anybody, the other has a branch
    # that stopped merging. The order used to run straight from the volume.
    run python3 - "$(doc)" <<'PY'
import json, os, re, subprocess, sys
doc = json.loads(sys.argv[1])
doc["arcs"] = [a for a in doc["arcs"] if a["stage"] in ("local-only", "came-back")]
r = subprocess.run([sys.executable, os.environ["ARCS_ROOT"] + "/bin/arcs-page", "--focus", "30"],
                   input=json.dumps(doc), capture_output=True, text=True)
print(re.findall(r'id="ws-([a-z-]+)-', r.stdout))
PY
    [ "${lines[0]}" = "['came-back-one', 'local-one']" ]
}

@test "volume still orders two rows that want the same thing" {
    # Demoted to the tiebreak it always should have been, not removed.
    run python3 - "$(doc)" <<'PY'
import json, os, re, subprocess, sys
doc = json.loads(sys.argv[1])
one = dict(doc["arcs"][2], id="small-pile", label="small-pile", unpushed_live=2)
two = dict(doc["arcs"][2], id="big-pile", label="big-pile", unpushed_live=20)
doc["arcs"] = [one, two]
r = subprocess.run([sys.executable, os.environ["ARCS_ROOT"] + "/bin/arcs-page", "--focus", "30"],
                   input=json.dumps(doc), capture_output=True, text=True)
print(re.findall(r'id="ws-([a-z-]+)-', r.stdout))
PY
    [ "${lines[0]}" = "['big-pile', 'small-pile']" ]
}

@test "work out for review still sits at the foot of its group" {
    # The outer split survives the new key. A row with a reviewer named on it wants
    # nothing from him, whatever its urgency says -- here the local-only arc has no
    # demands at all and would sort last on urgency alone.
    run python3 - "$(doc)" <<'PY'
import json, os, re, subprocess, sys
doc = json.loads(sys.argv[1])
quiet = dict(doc["arcs"][2], id="quiet-local", label="quiet-local", urgency=99)
doc["arcs"] = [doc["arcs"][1], quiet]
r = subprocess.run([sys.executable, os.environ["ARCS_ROOT"] + "/bin/arcs-page", "--focus", "30"],
                   input=json.dumps(doc), capture_output=True, text=True)
print(re.findall(r'id="ws-([a-z-]+)-', r.stdout))
PY
    [ "${lines[0]}" = "['quiet-local', 'in-review-one']" ]
}

# ── the table, and the sentence that names its worst row ─────────────────────

# A gap document holding `n` mismatches, ranked as work-arcs would rank them.
gap() {
    python3 - "$1" <<'PY'
import json, sys
n = int(sys.argv[1])

def mismatch(i):
    key = "UL-%d" % (100 + i)
    return {"issue": {"key": key, "status": "In Review", "summary": key + " summary",
                      "url": "https://jira.example/browse/" + key},
            "arc": {"unpushed_live": 3, "unpushed_days": 1},
            "ref": key, "stale_days": 90 - i, "fp": "gp-" + key,
            "why": "status 'In Review' but a day of work never pushed"}

print(json.dumps({"status_mismatch": [mismatch(i) for i in range(n)],
                  "unticketed_work": [], "tickets_without_work": []}))
PY
}

@test "the table renders the ranking it was handed and never re-derives one" {
    run python3 - "$(doc "$(gap 3)")" <<'PY'
import json, os, re, subprocess, sys
doc = json.loads(sys.argv[1])
doc["gap"]["status_mismatch"] = list(reversed(doc["gap"]["status_mismatch"]))
r = subprocess.run([sys.executable, os.environ["ARCS_ROOT"] + "/bin/arcs-page", "--focus", "30"],
                   input=json.dumps(doc), capture_output=True, text=True)
table = re.search(r'<h2[^>]*>Jira says otherwise</h2>.*?</table>', r.stdout, re.S)
print(re.findall(r'browse/(UL-\d+)', table.group(0)))
PY
    [ "${lines[0]}" = "['UL-102', 'UL-101', 'UL-100']" ]
}

@test "the ticket the opening sentence names is a row the table actually printed" {
    # The table stops at fourteen rows. While the order was whatever Jira returned and the
    # sentence ran its own max() over the whole list, the two could disagree -- and the
    # link in the sentence pointed at an anchor the truncation had removed.
    run python3 - "$(doc "$(gap 20)")" <<'PY'
import json, os, re, subprocess, sys
doc = json.loads(sys.argv[1])
r = subprocess.run([sys.executable, os.environ["ARCS_ROOT"] + "/bin/arcs-page", "--focus", "30"],
                   input=json.dumps(doc), capture_output=True, text=True)
lede = re.search(r'<p class="lede">.*?</p>', r.stdout, re.S).group(0)
named = re.search(r"<em>(UL-\d+)</em>", lede).group(1)
table = re.search(r'<h2[^>]*>Jira says otherwise</h2>.*?</table>', r.stdout, re.S).group(0)
print(named, 'id="gp-gp-%s"' % named in table)
PY
    [ "${lines[0]}" = "UL-100 True" ]
}

@test "a table that cut its tail says how many it left out" {
    run page "$(doc "$(gap 20)")"
    [[ "$output" == *"and 6 more, each standing for less time than these"* ]]
}

@test "a table that fits says nothing about a remainder" {
    run page "$(doc "$(gap 4)")"
    [[ "$output" != *"more, each standing for less time"* ]]
}

@test "the sentence carries the clock that ordered the list" {
    run page "$(doc "$(gap 3)")"
    [[ "$output" == *"uncorrected for 90 days"* ]]
    [[ "$output" == *"longest-standing of 3 tickets"* ]]
}

@test "an acknowledged row is out of the opening sentence and out of its count" {
    # The rule the morning brief already follows. A count that includes hidden rows
    # disagrees with the table it points at, and an acknowledgement that still opens the
    # page with the same ticket does nothing at all.
    run python3 - "$(doc "$(gap 3)")" <<'PY'
import json, os, re, subprocess, sys
doc = json.loads(sys.argv[1])
doc["gap"]["status_mismatch"][0]["dismissed"] = True
r = subprocess.run([sys.executable, os.environ["ARCS_ROOT"] + "/bin/arcs-page", "--focus", "30"],
                   input=json.dumps(doc), capture_output=True, text=True)
lede = re.search(r'<p class="lede">.*?</p>', r.stdout, re.S).group(0)
print(re.search(r"<em>(UL-\d+)</em>", lede).group(1), "of 2" in lede)
PY
    [ "${lines[0]}" = "UL-101 True" ]
}

@test "a mismatch with no unpushed work is not said to have unpushed work" {
    # The second kind of row: a status claiming work is under way on a workstream nobody
    # has touched in three weeks. It has no scale to print, and under a ranking that can
    # put it first, "never reached a remote" is a sentence the page would open on.
    run python3 - "$(doc "$(gap 1)")" <<'PY'
import json, os, re, subprocess, sys
doc = json.loads(sys.argv[1])
m = doc["gap"]["status_mismatch"][0]
m["arc"] = {"unpushed_live": 0, "unpushed_days": 0}
m["why"] = "status 'In Progress' but untouched 34d"
r = subprocess.run([sys.executable, os.environ["ARCS_ROOT"] + "/bin/arcs-page", "--focus", "30"],
                   input=json.dumps(doc), capture_output=True, text=True)
lede = re.search(r'<p class="lede">.*?</p>', r.stdout, re.S).group(0)
print("REMOTE" if "reached a remote" in lede else "NO-REMOTE")
print("UNTOUCHED" if "untouched 34d" in lede else "NO-UNTOUCHED")
PY
    [ "${lines[0]}" = "NO-REMOTE" ]
    [ "${lines[1]}" = "UNTOUCHED" ]
}

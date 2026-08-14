#!/usr/bin/env bats
# Tests for the sprint lens in work-arcs: the fetch, the join, and the degradation.
#
# Only the cases where being wrong would look right. This feature makes two claims that a
# person acts on -- "nothing has been done about this ticket" and "you have not touched
# this in a working week" -- and both are the kind of claim that is embarrassing rather
# than merely useless when it is false. So the tests are concentrated on the four places
# the real Jira turned out not to match the obvious implementation:
#
#   the field is a HISTORY      an issue's Sprint array holds every sprint it has ever
#                               been in. Measured on the real instance, 21 issues carried
#                               ten distinct sprints between them, back three months. Only
#                               `state == "active"` is this fortnight
#   there is no "the" sprint    two boards run the same fortnight concurrently -- (UL) and
#                               (UB), 19 and 2 tickets. One name is a lie and two names is
#                               noise, so they collapse when they agree and both print
#                               when they do not
#   endDate is EXCLUSIVE        the sprint named "Aug 10 - Aug 21" stamps 2026-08-22T07:00Z,
#                               which is local midnight on the 22nd. Printed raw the page
#                               disagrees with Jira's own name for the sprint, forever
#   silence has four causes     landed, abandoned, parked and neglected all look identical
#                               from the activity series. Only the last one is worth saying
#
# collect_sprint is exercised through a stubbed _jira_get rather than over the network:
# these assert what the code does with a payload, and the payload's shape is pinned by the
# measurements quoted above. join_sprint is pure and is called directly.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    export JIRA_DOMAIN="jira.example.com"
    export JIRA_EMAIL="me@example.com"
    export JIRA_API_TOKEN="t"
    export JIRA_PROJECTS="UB,UL,DE"
    unset JIRA_EXTRA_PROJECTS
    unset WORK_ARCS_SPRINT_IDLE_DAYS
}

teardown() {
    teardown_temp_dir
}

# Runs a python snippet with work-arcs imported as `wa`, a stubbable Jira and the arc
# builders in scope.
wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" <<PY
import importlib.machinery, importlib.util, sys, time, json
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
sys.argv = ["wa"]
loader.exec_module(wa)
wa.TICKET_RE = wa._ticket_re()

TODAY = wa.day_no(time.time())
FIELD = "customfield_10018"

def stub_jira(fields=None, issues=None):
    """Stand in for the two GETs collect_sprint makes. None means "that call failed"."""
    def get(path, params=None):
        if path == "field":
            return fields
        if path == "search/jql":
            return None if issues is None else {"issues": issues}
        return None
    wa._jira_get = get

# The one field on the real instance that carries the greenhopper schema, plus two
# decoys: a differently-named custom field, and something an admin also called "Sprint".
FIELDS = [
    {"id": "customfield_10001", "name": "Story Points",
     "schema": {"custom": "com.atlassian.jira.plugin.system.customfieldtypes:float"}},
    {"id": "customfield_99999", "name": "Sprint",
     "schema": {"custom": "com.atlassian.jira.plugin.system.customfieldtypes:textfield"}},
    {"id": FIELD, "name": "Sprint",
     "schema": {"custom": "com.pyxis.greenhopper.jira:gh-sprint"}},
]

def sp(name, state="active", end="2099-01-02T08:00:00.000Z"):
    return {"id": 1, "name": name, "state": state, "endDate": end}

def iss(key, sprints, status="In Progress", cat="indeterminate", summary="s"):
    return {"key": key, "fields": {"summary": summary,
                                   "status": {"name": status,
                                              "statusCategory": {"key": cat}},
                                   "updated": "2026-08-13T00:00:00.000+0000",
                                   FIELD: sprints}}

def cmts(spec, tag="c"):
    out = []
    for ago, n in spec.items():
        at = (TODAY - ago) * wa.DAY - wa.LOCAL_OFFSET + 12 * 3600
        out += [{"at": at, "sha": "%s%d-%d" % (tag, ago, i)} for i in range(n)]
    return out

def arc(id, branches=(), commits=None, **kw):
    """An arc as join_sprint sees one, with a real activity block underneath it."""
    a = {"id": id, "label": kw.pop("label", id),
         "branches": [{"name": b, "sha": b[:9], "commits": []} for b in branches],
         "settled": None, "parked": None, "stage": "local-only", "engagement": 100,
         "age_days": 0}
    a.update(kw)
    if commits is not None and a["branches"]:
        a["branches"][0]["commits"] = cmts(commits)
    a["activity"] = wa.activity_of(a, kw.pop("session", None) or {})
    return a

def sprint_of(**kw):
    stub_jira(**kw)
    return wa.collect_sprint()

$1
PY
}

# ── discovering the field ─────────────────────────────────────────────────────

@test "the Sprint field is found by its greenhopper schema, not by its name" {
    # Both decoys are named "Sprint" or nearly so, and one of them sorts first. Matching
    # on the name picks customfield_99999 and every sprint query silently returns nothing.
    run wa '
stub_jira(fields=FIELDS)
print(wa._sprint_field())'
    [ "$output" = "customfield_10018" ]
}

@test "an instance with no Sprint field yields no sprint at all, not an empty one" {
    # A Jira without agile is a real thing. The distinction matters: None makes the strip
    # absent, whereas a dict with zero members would render "0 workstreams in play" and
    # assert a sprint that does not exist.
    run wa '
print(sprint_of(fields=[FIELDS[0]], issues=[iss("UL-1001", [sp("S")])]))'
    [ "$output" = "None" ]
}

@test "Jira unreachable yields no sprint" {
    run wa '
print(sprint_of(fields=None, issues=None))
print(sprint_of(fields=FIELDS, issues=None))'
    [ "${lines[0]}" = "None" ]
    [ "${lines[1]}" = "None" ]
}

@test "an open sprint with nothing of mine in it yields no sprint" {
    run wa '
print(sprint_of(fields=FIELDS, issues=[]))'
    [ "$output" = "None" ]
}

# ── the field is a history, not a membership ──────────────────────────────────

@test "closed sprints in an issue's history do not name the current sprint" {
    # openSprints() matched this issue on its ACTIVE sprint, but the field it hands back
    # carries every sprint the ticket has ever sat in. Taking the array's last element --
    # the obvious shortcut, and right on a ticket that was never carried over -- names a
    # sprint that ended in May.
    run wa '
s = sprint_of(fields=FIELDS, issues=[
    iss("UL-1001", [sp("May 4 - May 15", state="closed"),
                 sp("Aug 10 - Aug 21"),
                 sp("Jul 27 - Aug 7", state="closed")])])
print(s["name"])
print(s["boards"])'
    [ "${lines[0]}" = "Aug 10 - Aug 21" ]
    [ "${lines[1]}" = "['Aug 10 - Aug 21']" ]
}

@test "an issue whose sprints are all closed is not in this sprint" {
    # It matched the JQL through some sibling condition or a stale index; without an
    # active entry there is nothing claiming it for this fortnight.
    run wa '
print(sprint_of(fields=FIELDS, issues=[iss("UL-1001", [sp("Jul 27", state="closed")])]))'
    [ "$output" = "None" ]
}

# ── two boards, one fortnight ─────────────────────────────────────────────────

@test "two boards running the same dates collapse to one name" {
    run wa '
s = sprint_of(fields=FIELDS, issues=[
    iss("UL-1001", [sp("Aug 10 - Aug 21, 2026 (UL)")]),
    iss("UB-2002", [sp("Aug 10 - Aug 21, 2026 (UB)")])])
print(s["name"])
print(len(s["boards"]))'
    [ "${lines[0]}" = "Aug 10 - Aug 21, 2026" ]
    [ "${lines[1]}" = "2" ]
}

@test "two boards on genuinely different dates print both names" {
    # Collapsing these would answer "which sprint am I in" with a coin toss.
    run wa '
s = sprint_of(fields=FIELDS, issues=[
    iss("UL-1001", [sp("Aug 10 - Aug 21 (UL)")]),
    iss("UB-2002", [sp("Aug 3 - Aug 14 (UB)")])])
print(s["name"])'
    [ "$output" = "Aug 10 - Aug 21 (UL) + Aug 3 - Aug 14 (UB)" ]
}

@test "where two boards disagree the deadline that binds is the earlier one" {
    run wa '
s = sprint_of(fields=FIELDS, issues=[
    iss("UL-1001", [sp("A", end="2099-03-10T08:00:00.000Z")]),
    iss("UB-2002", [sp("B", end="2099-03-03T08:00:00.000Z")])])
print(s["ends"])'
    [ "$output" = "2099-03-02" ]
}

# ── endDate is the exclusive boundary ─────────────────────────────────────────

@test "a sprint ending at local midnight reports the previous day, as its name does" {
    # The measured case: "Aug 10 - Aug 21, 2026" stamps 2026-08-22T07:00:00Z, which is
    # midnight on the 22nd in the timezone this runs in. Printed raw, the page says the
    # sprint ends a day after Jira's own name for it says it does.
    run wa '
import time, datetime
# Midnight local on a fixed day, expressed in UTC, whatever this machine is set to.
mid = datetime.datetime(2099, 3, 2).astimezone()
print(wa._sprint_end(mid.astimezone(datetime.timezone.utc).isoformat().replace("+00:00", "Z")))'
    [ "$output" = "2099-03-01" ]
}

@test "a sprint ending at a real time of day is taken as it stands" {
    # A board configured to close at 5pm on the Friday. There is no exclusive boundary to
    # walk back here, and walking one back anyway would lose a day of the sprint.
    run wa '
import datetime
five = datetime.datetime(2099, 3, 2, 17, 0).astimezone()
print(wa._sprint_end(five.astimezone(datetime.timezone.utc).isoformat().replace("+00:00", "Z")))'
    [ "$output" = "2099-03-02" ]
}

@test "an unparseable endDate loses the date and not the sprint" {
    run wa '
s = sprint_of(fields=FIELDS, issues=[iss("UL-1001", [sp("S", end="whenever")])])
print(s["name"], s["ends"], s["days_left"])'
    [ "$output" = "S None None" ]
}

# ── the join ──────────────────────────────────────────────────────────────────

@test "an arc is claimed by a ticket key in a branch name, not only in its label" {
    # Clustering names an arc after its evidence, so the arc that owns UL-1692 is usually
    # called something else entirely. Keying off the label alone empties the map and every
    # sprint ticket reads as work that never started -- the exact bug reconcile carries a
    # comment about, which is why both callers share tickets_to_arcs.
    run wa '
s = sprint_of(fields=FIELDS, issues=[iss("UL-1692", [sp("S")])])
arcs = [arc("A", label="SMP neighbourhood selection", branches=["UL-1692-fix"])]
wa.join_sprint(s, arcs)
print(s["arcs"], len(s["tickets_without_work"]))
print(arcs[0]["sprint"]["name"])'
    [ "${lines[0]}" = "['A'] 0" ]
    [ "${lines[1]}" = "S" ]
}

@test "one arc carrying several sprint tickets is one workstream" {
    run wa '
s = sprint_of(fields=FIELDS, issues=[iss("UL-1001", [sp("S")]), iss("UL-1002", [sp("S")])])
arcs = [arc("A", branches=["UL-1001-a", "UL-1002-b"])]
wa.join_sprint(s, arcs)
print(s["arcs"], s["in_play"])'
    [ "$output" = "['A'] ['A']" ]
}

@test "a finished sprint ticket with nothing on disk is the sprint working, not a hole" {
    # The one place this list must differ from gap's list of the same name. collect_jira
    # never sees a Done ticket, so gap cannot make this mistake; collect_sprint fetches
    # Done deliberately -- the sprint arithmetic needs it -- and so it can.
    run wa '
s = sprint_of(fields=FIELDS, issues=[
    iss("UL-1001", [sp("S")], status="Done", cat="done"),
    iss("UL-1002", [sp("S")])])
wa.join_sprint(s, [])
print([i["key"] for i in s["tickets_without_work"]])
print(s["tickets"], s["done"])'
    [ "${lines[0]}" = "['UL-1002']" ]
    [ "${lines[1]}" = "1 1" ]
}

@test "done is read from the status category, not from the word Done" {
    # This instance calls live states "Releasing" and "MR". A name test either lets those
    # through as finished or, matching on the category name, calls them unstarted.
    run wa '
s = sprint_of(fields=FIELDS, issues=[
    iss("UL-1001", [sp("S")], status="Releasing", cat="indeterminate"),
    iss("UL-1002", [sp("S")], status="Shipped", cat="done")])
wa.join_sprint(s, [])
print(sorted(i["key"] for i in s["issues"] if i["done"]))
print([i["key"] for i in s["tickets_without_work"]])'
    [ "${lines[0]}" = "['UL-1002']" ]
    [ "${lines[1]}" = "['UL-1001']" ]
}

# ── which silence is neglect ──────────────────────────────────────────────────

@test "a sprint arc quiet past the threshold is untouched" {
    run wa '
s = sprint_of(fields=FIELDS, issues=[iss("UL-1001", [sp("S")])])
arcs = [arc("A", branches=["UL-1001"], commits={9: 3})]
wa.join_sprint(s, arcs)
print([(u["id"], u["days"]) for u in s["untouched"]])'
    [ "$output" = "[('A', 9)]" ]
}

@test "a sprint arc quiet for less than the threshold is not" {
    run wa '
s = sprint_of(fields=FIELDS, issues=[iss("UL-1001", [sp("S")])])
arcs = [arc("A", branches=["UL-1001"], commits={4: 3})]
wa.join_sprint(s, arcs)
print(s["untouched"])'
    [ "$output" = "[]" ]
}

@test "landed, abandoned and parked sprint arcs are silent for other reasons" {
    # Four causes of the same silence and only one of them is forgetting. An accusation
    # levelled at work that shipped is the fastest way to teach someone to stop reading a
    # strip. `parked` is tested both ways it can be expressed, because apply_parked sets
    # the flag while the stage is set upstream of it.
    run wa '
s = sprint_of(fields=FIELDS, issues=[iss("UL-100%d" % n, [sp("S")]) for n in range(1, 6)])
arcs = [arc("landed",    branches=["UL-1001"], commits={9: 3}, stage="landed"),
        arc("abandoned", branches=["UL-1002"], commits={9: 3}, stage="abandoned"),
        arc("parked",    branches=["UL-1003"], commits={9: 3}, stage="parked"),
        arc("flagged",   branches=["UL-1004"], commits={9: 3}, parked={"why": "later"}),
        arc("neglected", branches=["UL-1005"], commits={9: 3})]
wa.join_sprint(s, arcs)
print([u["id"] for u in s["untouched"]])
print(len(s["arcs"]), len(s["in_play"]))'
    [ "${lines[0]}" = "['neglected']" ]
    [ "${lines[1]}" = "5 1" ]
}

@test "in review is not exempt: a sprint ticket nobody has read is the risk" {
    # Deliberately unlike fell_off_a_cliff, which exempts in-review because a reviewer's
    # queue is not forgetting. At sprint scale it is: the fortnight ends whether or not
    # anyone opened the merge request.
    run wa '
s = sprint_of(fields=FIELDS, issues=[iss("UL-1001", [sp("S")])])
arcs = [arc("A", branches=["UL-1001"], commits={9: 3}, stage="in-review")]
wa.join_sprint(s, arcs)
print([u["id"] for u in s["untouched"]])'
    [ "$output" = "['A']" ]
}

@test "idleness is the arc's cliff, not its lineage age" {
    # cliff_days is measured over everything in the arc, so a colleague's commit landing
    # on it today makes it read 0 while age_days -- asked of the arc's own lineage --
    # still says 30. Under-claiming is the right direction for an accusation.
    run wa '
s = sprint_of(fields=FIELDS, issues=[iss("UL-1001", [sp("S")])])
arcs = [arc("A", branches=["UL-1001"], commits={0: 1}, age_days=30)]
wa.join_sprint(s, arcs)
print(arcs[0]["activity"]["cliff_days"], arcs[0]["age_days"], s["untouched"])'
    [ "$output" = "0 30 []" ]
}

@test "an arc with no dated evidence at all falls back to its age" {
    # A branch whose commits all predate the log window, named by no session. There is no
    # cliff to read, and reporting nothing would hide the case the strip most wants.
    run wa '
s = sprint_of(fields=FIELDS, issues=[iss("UL-1001", [sp("S")])])
arcs = [arc("A", branches=["UL-1001"], age_days=12)]
wa.join_sprint(s, arcs)
print(arcs[0]["activity"]["cliff_days"], [(u["id"], u["days"]) for u in s["untouched"]])'
    [ "$output" = "None [('A', 12)]" ]
}

@test "the threshold is configurable and the sprint says which one it used" {
    run wa '
import os
os.environ["WORK_ARCS_SPRINT_IDLE_DAYS"] = "10"
wa.SPRINT_IDLE_DAYS = int(os.environ["WORK_ARCS_SPRINT_IDLE_DAYS"])
s = sprint_of(fields=FIELDS, issues=[iss("UL-1001", [sp("S")])])
arcs = [arc("A", branches=["UL-1001"], commits={9: 3})]
wa.join_sprint(s, arcs)
print(s["idle_days"], s["untouched"])'
    [ "$output" = "10 []" ]
}

# ── orderings are total ───────────────────────────────────────────────────────

@test "arcs tied on engagement and on idleness keep a stable order" {
    # Every sort in this file needs a total tiebreak. Two arcs swapping places between
    # runs is not cosmetic here: arc-brief caches on the evidence text it is handed, so an
    # unstable order buys a model call and a fresh name for work that did not change.
    run wa '
s = sprint_of(fields=FIELDS, issues=[iss("UL-100%d" % n, [sp("S")]) for n in (1, 2, 3)])
mk = lambda: [arc("c", branches=["UL-1001"], commits={9: 1}),
              arc("a", branches=["UL-1002"], commits={9: 1}),
              arc("b", branches=["UL-1003"], commits={9: 1})]
one, two = dict(s), dict(s)
wa.join_sprint(one, mk()); wa.join_sprint(two, list(reversed(mk())))
print(one["arcs"], one["arcs"] == two["arcs"])
print([u["id"] for u in one["untouched"]])'
    [ "${lines[0]}" = "['a', 'b', 'c'] True" ]
    [ "${lines[1]}" = "['a', 'b', 'c']" ]
}

# ── the extra project keys ────────────────────────────────────────────────────

@test "JIRA_EXTRA_PROJECTS widens the ticket pattern and nothing else" {
    # It exists precisely so SBX can be recognised in prose without joining JIRA_PROJECTS,
    # where jira-fzf and rr.sh would interpolate it into `project IN (...)` and
    # create-jira-ticket would offer it as a board to file against.
    run wa '
import os, re
print(sorted(m.group(0) for m in wa._ticket_re().finditer("SBX-14 UL-1842 UTF-8")))
os.environ["JIRA_EXTRA_PROJECTS"] = "SBX"
print(sorted(m.group(0) for m in wa._ticket_re().finditer("SBX-14 UL-1842 UTF-8")))'
    [ "${lines[0]}" = "['UL-1842']" ]
    [ "${lines[1]}" = "['SBX-14', 'UL-1842']" ]
}

@test "a key named in both variables appears once in the pattern" {
    run wa '
import os
os.environ["JIRA_EXTRA_PROJECTS"] = "UL,SBX"
print(wa._ticket_re().pattern)'
    [ "$output" = '\b(UB|UL|DE|SBX)-(\d{2,5})\b' ]
}

#!/usr/bin/env bats
# Tests for the standup notes -- arc-standup.
#
# Two failures matter here and they are not crashes.
#
# The first is a window that is off by a day. Everything this stage says is "since the last
# standup", and there is no state anywhere to check that claim against -- the boundary is
# derived from the clock every run. A window computed one standup too early repeats what
# was already said; one too late silently drops a day's work, on the morning you are about
# to stand up and account for it. So the arithmetic is pinned at every edge: before and
# after the meeting, on an off day, over a weekend, at the exact minute.
#
# The second is a confident sentence about something that did not happen in the interval.
# A commitment closed three weeks ago read out as this week's; a Slack decision from a
# thread somebody merely replied to; a ticket transition inferred from a status nothing
# here ever saw change. Each of those is tested for by its absence.
#
# What is deliberately NOT tested is the wording, for the reason morning_brief.bats gives:
# the phrasing is tuned by reading it against the real payload, and pinning prose in
# assertions makes every improvement a failure. What is pinned is which facts were chosen,
# which were left out, and what the window was.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    # The cadence every test assumes unless it says otherwise. Set explicitly rather than
    # relied on as a default, so a change to the default cannot quietly rewrite what these
    # tests are asserting about Mondays.
    export STANDUP_DAYS="mon,wed,fri"
    export STANDUP_TIME="10:30"
    export STANDUP_TZ="America/Los_Angeles"
}

teardown() {
    teardown_temp_dir
}

# Runs a python snippet with arc-standup imported as `su` and the payload builders in
# scope. Every test names its own instant, because that is the input under test.
su() {
    python3 - "$REPO_ROOT/bin/arc-standup" <<PY
import importlib.machinery, importlib.util, sys, json
from datetime import datetime
loader = importlib.machinery.SourceFileLoader("su", sys.argv[1])
spec = importlib.util.spec_from_loader("su", loader)
su = importlib.util.module_from_spec(spec)
sys.argv = ["su"]
loader.exec_module(su)

PT = "-07:00"                                  # the fixtures all sit in daylight time

def at(s):
    return datetime.fromisoformat(s + PT if len(s) == 19 else s)

def arc(aid, label, **kw):
    a = {"id": aid, "label": label, "brief": {"name": label}, "branches": [],
         "mrs": [], "issues": [], "slack": [], "own_activity": 0, "state": ""}
    a.update(kw)
    return a

def owed(kind, ref, days, **kw):
    e = {"kind": kind, "ref": ref, "days": days, "who": kw.pop("who", "someone"),
         "fp": kw.pop("fp", "fp-" + ref), "url": "", "title": ""}
    e.update(kw)
    return e

def payload(**kw):
    d = {"generated": "2026-08-24T09:00:00-0700", "me": "kylegm", "arcs": [],
         "sprint": {}, "ledger": {"they_owe": [], "you_owe": [], "you_owe_closed": []}}
    d.update(kw)
    return d

def build(d, when):
    return su.build(d, at(when))

def beat(d, when, kind):
    """The texts of one beat, which is the assertion surface for selection."""
    st = build(d, when)
    b = next((x for x in st["beats"] if x["kind"] == kind), None)
    return [i["text"] for i in (b or {}).get("items", [])]

def subs(d, when, kind, i=0):
    st = build(d, when)
    b = next((x for x in st["beats"] if x["kind"] == kind), None)
    return [s["text"] for s in b["items"][i]["subs"]]

$1
PY
}

# ── the window ────────────────────────────────────────────────────────────────
#
# The one rule: it opens at the most recent standup that has already happened, and runs
# to now. Every case below is that sentence applied to a different clock.

@test "before Monday's standup, the window is the one that opened on Friday" {
    run su 'st = build(payload(), "2026-08-24T09:00:00")
print(st["since"]["day"], "->", st["for"]["day"])'
    [ "$status" -eq 0 ]
    [ "$output" = "Friday -> Monday" ]
}

@test "after Monday's standup, the window is for Wednesday and opened this morning" {
    # The half-hour after the meeting is the case that has no special branch and needs
    # none: the last standup is now this morning's, so the notes are already Wednesday's.
    run su 'st = build(payload(), "2026-08-24T11:00:00")
print(st["since"]["day"], "->", st["for"]["day"])'
    [ "$status" -eq 0 ]
    [ "$output" = "Monday -> Wednesday" ]
}

@test "at the exact minute of the standup, it is the one now being held" {
    # 10:30 is not yet past, so the window it opens is still Friday's and the meeting it
    # is for is this one. A boundary resolved the other way would hand you an empty page
    # at the moment you most need a full one.
    run su 'st = build(payload(), "2026-08-24T10:30:00")
print(st["since"]["day"], "->", st["for"]["day"])'
    [ "$status" -eq 0 ]
    [ "$output" = "Friday -> Monday" ]
}

@test "on an off day the window is the last standup and the next one" {
    run su 'st = build(payload(), "2026-08-25T16:00:00")
print(st["since"]["day"], "->", st["for"]["day"])'
    [ "$status" -eq 0 ]
    [ "$output" = "Monday -> Wednesday" ]
}

@test "Monday morning's window reaches back over the whole weekend" {
    # Three days, not one. The weekend is the interval a standup most needs held open,
    # because a Friday-to-Monday page that only reached back to Sunday would drop two of
    # the days he is about to be asked about.
    run su 'st = build(payload(), "2026-08-24T09:00:00")
print(st["since"]["date"], round(st["since"]["seconds"] / 3600))'
    [ "$status" -eq 0 ]
    [ "$output" = "2026-08-21 70" ]
}

@test "a window minutes old says so, rather than reading as a quiet interval" {
    run su 'print(build(payload(), "2026-08-24T10:40:00")["note"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"10 minutes ago"* ]]
}

@test "a full window carries no such caveat" {
    run su 'print(repr(build(payload(), "2026-08-24T09:00:00")["note"]))'
    [ "$status" -eq 0 ]
    [ "$output" = "''" ]
}

@test "a cadence of one day a week still finds last week's meeting" {
    STANDUP_DAYS="thu" run su 'st = build(payload(), "2026-08-24T09:00:00")
print(st["since"]["day"], "->", st["for"]["day"])'
    [ "$status" -eq 0 ]
    [ "$output" = "Thursday -> Thursday" ]
}

@test "an unreadable cadence falls back and says which knob it could not read" {
    STANDUP_DAYS="funday" run su 'st = build(payload(), "2026-08-24T09:00:00")
print(st["cadence"]["day_names"], "|", st["note"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['Mon', 'Wed', 'Fri']"* ]]
    [[ "$output" == *"STANDUP_DAYS"* ]]
}

# ── what moved ────────────────────────────────────────────────────────────────

@test "a workstream you touched in the window is named; one you did not is not" {
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
old = int(at("2026-08-19T14:00:00").timestamp())
d = payload(arcs=[arc("a", "worked on", own_activity=sat, state="s"),
                  arc("b", "left alone", own_activity=old, state="s")])
print(beat(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"worked on"* ]]
    [[ "$output" != *"left alone"* ]]
}

@test "an MR that landed in the window is named even with no activity of your own" {
    # The single most standup-worthy thing that can happen to a branch is somebody else
    # merging it, and that leaves no trace in your own activity at all.
    run su 'd = payload(arcs=[arc("a", "finished last week", own_activity=1,
    branches=[{"name": "b", "mr_fate": {"state": "merged", "iid": 42,
                                        "at": "2026-08-22", "url": "u"}}])])
print(beat(d, "2026-08-24T09:00:00", "moved"), subs(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"finished last week"* ]]
    [[ "$output" == *"!42 landed"* ]]
}

@test "an MR that landed before the window is not this standup's news" {
    run su 'd = payload(arcs=[arc("a", "old news", own_activity=1,
    branches=[{"name": "b", "mr_fate": {"state": "merged", "iid": 42,
                                        "at": "2026-08-18", "url": "u"}}])])
print(beat(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "a ticket is said as a status, never as a transition" {
    # Nothing here saw the ticket before the window opened, so "moved to In Review" would
    # be an inference. This stage does not make those.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "work", own_activity=sat, state="s",
    issues=[{"key": "UL-1", "status": "In Review", "updated": "2026-08-22", "url": ""}])])
print(subs(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"UL-1 In Review"* ]]
    [[ "$output" != *"moved to"* ]]
}

@test "a workstream named after its ticket does not say the key twice" {
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "UL-1918", ticket="UL-1918", own_activity=sat, state="s")])
print(beat(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [ "$output" = "['UL-1918']" ]
}

@test "a workstream whose name is not its key leads with the key" {
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "derive geometry", ticket="UL-1852", own_activity=sat,
                      state="s")])
print(beat(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [ "$output" = "['UL-1852 derive geometry']" ]
}

# ── what was discussed ────────────────────────────────────────────────────────

@test "a decision reached in the window is said" {
    run su 'd = payload(arcs=[arc("a", "work", slack=[{"channel": "tech-backend",
    "url": "https://s/archives/C1/p1787678400000000",
    "decided": [{"what": "push it down to Postgres", "who": "Neville",
                 "url": "https://s/archives/C1/p1787678400000000"}], "open": []}])])
print(beat(d, "2026-08-24T09:00:00", "discussed"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"push it down to Postgres"* ]]
    [[ "$output" == *"#tech-backend"* ]]
}

@test "a decision from before the window is not revived by a later reply to its thread" {
    # The thread's own clock moves whenever anybody adds to it; what was decided did not.
    # Windowing on the thread rather than on the quoted message is how these notes would
    # come to repeat last week's conclusions every time somebody said "thanks".
    run su 'd = payload(arcs=[arc("a", "work", slack=[{"channel": "tech-backend",
    "last_ts": "1787678400.0",
    "url": "https://s/archives/C1/p1787678400000000",
    "decided": [{"what": "settled a week ago", "who": "Neville",
                 "url": "https://s/archives/C1/p1787000000000000"}], "open": []}])])
print(beat(d, "2026-08-24T09:00:00", "discussed"))'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "a reviewer's question in the window is an ask; your reply to it is an answer" {
    run su 'd = payload(arcs=[arc("a", "work", mrs=[
  {"iid": 1, "url": "u", "threads": [{"author": "max", "quote": "why this string?",
                                      "at": "2026-08-22", "last_by": "max",
                                      "last_at": "2026-08-22", "answered": False}]},
  {"iid": 2, "url": "u", "threads": [{"author": "max", "quote": "and this one?",
                                      "at": "2026-08-18", "last_by": "kylegm",
                                      "last_at": "2026-08-22", "answered": True}]}])])
for t in beat(d, "2026-08-24T09:00:00", "discussed"): print(t)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"!1 max asked"* ]]
    [[ "$output" == *"!2 answered max"* ]]
}

@test "a review thread that neither moved nor was answered in the window is silent" {
    run su 'd = payload(arcs=[arc("a", "work", mrs=[
  {"iid": 1, "url": "u", "threads": [{"author": "max", "quote": "q",
                                      "at": "2026-08-12", "last_by": "max",
                                      "last_at": "2026-08-13", "answered": False}]}])])
print(beat(d, "2026-08-24T09:00:00", "discussed"))'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "a commitment is windowed on when it was closed, not on when it was promised" {
    # An old promise delivered on Saturday is Monday's news; an old promise delivered
    # three weeks ago is nobody's.
    run su 'sat = at("2026-08-22T14:00:00").timestamp()
old = at("2026-08-05T14:00:00").timestamp()
d = payload(ledger={"they_owe": [], "you_owe": [], "you_owe_closed": [
  {"promised": "do the layer fix", "asked": "2026-07-01", "closed_ts": sat,
   "closed_by": "you posted in-thread"},
  {"promised": "the ancient one", "asked": "2026-07-01", "closed_ts": old,
   "closed_by": "you posted in-thread"}]})
print(beat(d, "2026-08-24T09:00:00", "discussed"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"do the layer fix"* ]]
    [[ "$output" != *"ancient"* ]]
}

# ── who is waiting on whom ────────────────────────────────────────────────────

@test "eleven unreviewed MRs are one sentence, naming the ledger's own worst" {
    # The failure this fixes: eleven lines differing only in a number, burying the two
    # rows next to them that were about something else.
    run su 'rows = [owed("review-silence", "!%d" % (100 + i), 20 - i,
                         who=["brian", "vadym"]) for i in range(11)]
d = payload(ledger={"they_owe": rows, "you_owe": [], "you_owe_closed": []})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c .)" -eq 1 ]
    [[ "$output" == *"11 MRs"* ]]
    [[ "$output" == *"!100"* ]]
}

@test "a handful is named in full rather than counted" {
    run su 'rows = [owed("review-silence", "!100", 9, who=["brian"]),
        owed("review-silence", "!101", 8, who=["brian"])]
d = payload(ledger={"they_owe": rows, "you_owe": [], "you_owe_closed": []})
print(beat(d, "2026-08-24T09:00:00", "blocked"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"!100"* ]]
    [[ "$output" == *"!101"* ]]
}

@test "a five-month stall is still said, but behind everything actionable" {
    # Dropping it would let a real stall go quiet. Leading with it for the fortieth
    # consecutive standup is how the room stops listening.
    run su 'd = payload(ledger={"they_owe": [
    owed("ticket-stalled", "DE-2585", 159, who="Neville"),
    owed("review-silence", "!100", 4, who=["brian"])],
    "you_owe": [], "you_owe_closed": []})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | head -1)" == *"!100"* ]]
    [[ "$(echo "$output" | tail -1)" == *"DE-2585"* ]]
    [[ "$(echo "$output" | tail -1)" == *"unchanged"* ]]
}

@test "what you owe is said out loud alongside what you are owed" {
    run su 'd = payload(ledger={
    "they_owe": [owed("review-silence", "!100", 4, who=["brian"])],
    "you_owe": [owed("review-owed", "!10408", 17, who="vadym")],
    "you_owe_closed": []})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"nobody has reviewed"* ]]
    [[ "$output" == *"I owe"* ]]
    [[ "$output" == *"vadym"* ]]
}

@test "a reviewer panel is trimmed to a sayable length, not read out entire" {
    run su 'd = payload(ledger={"they_owe": [owed("review-silence", "!100", 4,
    who=["brian", "vadym", "ajit", "Matt", "ella"])],
    "you_owe": [], "you_owe_closed": []})
print(beat(d, "2026-08-24T09:00:00", "blocked"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"+2"* ]]
    [[ "$output" != *"ella"* ]]
}

@test "a DM is named by the person in it, and the name is not then repeated" {
    run su 'd = payload(ledger={"they_owe": [], "you_owe_closed": [],
    "you_owe": [owed("slack-dm", "DM", 6, who="loganwenzel")]})
print(beat(d, "2026-08-24T09:00:00", "blocked"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"loganwenzel"* ]]
    [ "$(grep -o loganwenzel <<<"$output" | wc -l)" -eq 1 ]
}

@test "a ledger kind with no phrase of its own is still said" {
    # A new kind upstream must not make this beat quieter.
    run su 'd = payload(ledger={"they_owe": [owed("something-new", "!7", 3, who="max")],
    "you_owe": [], "you_owe_closed": []})
print(beat(d, "2026-08-24T09:00:00", "blocked"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"!7"* ]]
    [[ "$output" == *"max"* ]]
}

# ── what is in front of you ───────────────────────────────────────────────────

@test "a sprint ticket already handed off is not offered as today's plan" {
    # `handed_off` is work-arcs' word for "somebody else's move now", and promising the
    # room one is promising them something you are waiting on them for.
    run su 'd = payload(sprint={"issues": [
    {"key": "UL-1", "status": "In Review", "summary": "theirs", "handed_off": True,
     "done": False, "url": ""},
    {"key": "UL-2", "status": "In Progress", "summary": "mine", "handed_off": False,
     "done": False, "url": ""}]})
print(beat(d, "2026-08-24T09:00:00", "next"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"UL-2"* ]]
    [[ "$output" != *"UL-1"* ]]
}

@test "a parked workstream is not what is in front of you" {
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "set aside", own_activity=sat, stage="parked")])
print(beat(d, "2026-08-24T09:00:00", "next"))'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

# ── the whole block ───────────────────────────────────────────────────────────

@test "a truncated beat says how many it left out" {
    # A cap that says nothing is indistinguishable from a complete list.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a%d" % i, "work %d" % i, own_activity=sat - i, state="s")
                  for i in range(9)])
print(beat(d, "2026-08-24T09:00:00", "moved")[-1])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 more not listed"* ]]
}

@test "an empty graph is an empty block and not an error" {
    run su 'st = build(payload(), "2026-08-24T09:00:00")
print(st["empty"], [len(b["items"]) for b in st["beats"]])'
    [ "$status" -eq 0 ]
    [ "$output" = "True [0, 0, 0, 0]" ]
}

@test "the text projection is one composition, so page and clipboard cannot disagree" {
    # The page renders `beats`; the copy button hands over `text`. Two projections of one
    # composition is how the screen and the clipboard end up disagreeing about Tuesday.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "the only thing", own_activity=sat, state="s")])
st = build(d, "2026-08-24T09:00:00")
print("the only thing" in st["text"], st["beats"][0]["items"][0]["text"])'
    [ "$status" -eq 0 ]
    [ "$output" = "True the only thing" ]
}

@test "the graph passes through untouched with one key added" {
    run su 'd = payload(arcs=[arc("a", "x")])
before = set(d)
d["standup"] = build(d, "2026-08-24T09:00:00")
print(sorted(set(d) - before))'
    [ "$status" -eq 0 ]
    [ "$output" = "['standup']" ]
}

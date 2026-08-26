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

def review(iid, days, turn, rounds, **kw):
    """One ongoing review, in the shape work-arcs puts on the wire.

    my_last and their_last are real instants rather than dates, which is the whole reason
    this beat can be windowed exactly -- so every test that cares hands them in.
    """
    r = {"iid": iid, "ref": "!%d" % iid, "title": "the %d change" % iid,
         "url": "https://gitlab.example/mr/%d" % iid,
         "author": kw.pop("author", "logan"), "source_branch": "br-%d" % iid,
         "asked": "2026-07-01", "days": days, "whose_turn": turn, "rounds": rounds,
         "quiet_days": 1, "arc": None, "fp": "rfp%d" % iid,
         "my_last": 0, "their_last": 0, "their_last_is_proxy": False}
    r.update(kw)
    return r

def ep(s):
    """An instant in the fixtures' own timezone, as the epoch the wire carries."""
    return int(at(s).timestamp())

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

def nsubs(d, when, kind):
    """How many sub-lines the beat produced. Every beat is one line per thing now."""
    st = build(d, when)
    b = next((x for x in st["beats"] if x["kind"] == kind), None)
    return sum(len(i["subs"]) for i in (b or {}).get("items", []))

def spoken(d, when):
    """The lines a person would actually read out: the block minus its headings."""
    return [l for l in build(d, when)["text"].splitlines()
            if l.startswith("  ") and l.strip()]

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
print(beat(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"finished last week"* ]]
    [[ "$output" == *"!42 landed"* ]]
}

@test "one workstream is one line, with nothing indented under it" {
    # The version with sub-lines put the name on one line and the rung on the next, which
    # is two lines to say one thing -- and the thing the second line said was a number.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "work", own_activity=sat, stage="in-review", state="in review",
                      mrs=[{"iid": 7, "url": "u", "threads": []}],
                      issues=[{"key": "UL-9", "status": "In Review",
                               "updated": "2026-08-22", "url": ""}])])
print(len(beat(d, "2026-08-24T09:00:00", "moved")), nsubs(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [ "$output" = "1 0" ]
}

@test "a landing leads the beat even when something newer was touched after it" {
    # A landing is the only finished thing in this beat. Recency orders everything else.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("fresh", "touched yesterday", own_activity=sat + 9999, state="s"),
                  arc("done", "merged on Saturday", own_activity=sat,
    branches=[{"name": "b", "mr_fate": {"state": "merged", "iid": 42,
                                        "at": "2026-08-22", "url": "u"}}])])
for t in beat(d, "2026-08-24T09:00:00", "moved"): print(t)'
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | head -1)" == *"merged on Saturday"* ]]
    [[ "$(echo "$output" | tail -1)" == *"touched yesterday"* ]]
}

@test "an MR that landed before the window is not this standup's news" {
    run su 'd = payload(arcs=[arc("a", "old news", own_activity=1,
    branches=[{"name": "b", "mr_fate": {"state": "merged", "iid": 42,
                                        "at": "2026-08-18", "url": "u"}}])])
print(beat(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "the rung is work-arcs own word for it, said as it arrived" {
    # Not recomposed here. A second vocabulary for one rung is a second author for one
    # judgement, and the two would differ inside a month.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "work", own_activity=sat, stage="came-back",
                      state="no longer merges",
                      mrs=[{"iid": 7, "url": "u", "threads": []}])])
print(beat(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"!7 no longer merges"* ]]
}

@test "a rung work-arcs phrases as a count is said without the count" {
    # The whole reason this file changed. "65 commits still local" is a number out of the
    # page's own books; in an afternoon of agentic work it is a fact about the tooling.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "the release cut", own_activity=sat, stage="local-only",
                      state="65 commits exist only here", unpushed_live=65)])
st = build(d, "2026-08-24T09:00:00")
print(beat(d, "2026-08-24T09:00:00", "moved"))
print("65" in st["text"], "commit" in st["text"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"the release cut — still unpushed"* ]]
    [[ "$(echo "$output" | tail -1)" = "False False" ]]
}

@test "a workstream on the unpushed rung with a review open says both halves" {
    # work-arcs is explicit that a review plus commits no remote has is not simply "in
    # review": the arc sits on the lower rung. The unpushed half leads, because it is the
    # half nobody else can see.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "work", own_activity=sat, stage="local-only",
                      state="85 commits exist only here", unpushed_live=85,
                      mrs=[{"iid": 7, "url": "u", "threads": []}])])
print(beat(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"still unpushed, !7 out for review"* ]]
}

@test "a workstream named after its ticket does not say the key twice" {
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "UL-1918", ticket="UL-1918", own_activity=sat, state="s")])
print(beat(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [ "$output" = "['UL-1918 — s']" ]
}

@test "a workstream whose name is not its key leads with the key" {
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "derive geometry", ticket="UL-1852", own_activity=sat,
                      state="s")])
print(beat(d, "2026-08-24T09:00:00", "moved"))'
    [ "$status" -eq 0 ]
    [ "$output" = "['UL-1852 derive geometry — s']" ]
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

@test "a five-month stall that did not change is not this standup's news" {
    # The line this replaces read "still open, unchanged: DE-2585 (159d), UB-6663 (116d),
    # UB-5628 (69d)" and was identical on every standup for as long as those sat there.
    # Nothing on it was news, and it was the fortieth-consecutive-time failure committed
    # in the one file that names it as the thing to avoid.
    run su 'd = payload(ledger={"they_owe": [
    owed("ticket-stalled", "DE-2585", 159, who="Neville"),
    owed("review-silence", "!100", 4, who=["brian"])],
    "you_owe": [], "you_owe_closed": []})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c .)" -eq 1 ]
    [[ "$output" == *"!100"* ]]
    [[ "$output" != *"DE-2585"* ]]
}

@test "a stall is said on the standup where it turns another month" {
    # Said once, on the crossing. Dropping it outright would let a real stall go quiet;
    # saying it every time is how the room learns to stop listening.
    run su 'd = payload(ledger={"they_owe": [
    owed("ticket-stalled", "DE-2585", 60, who="Neville")],
    "you_owe": [], "you_owe_closed": []})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"DE-2585"* ]]
    [[ "$output" == *"another month"* ]]
}

@test "the same crossing cannot be said on the next standup" {
    # Monday's window is the weekend, three days wide, and 60 days crosses inside it.
    # Wednesday's window is two days and 62 days crosses nothing: the row has already had
    # its say. This is the property the whole gate exists for.
    run su 'def one(days, when):
    d = payload(ledger={"they_owe": [owed("ticket-stalled", "DE-2585", days,
                                          who="Neville")],
                        "you_owe": [], "you_owe_closed": []})
    return [t for t in beat(d, when, "blocked") if "DE-2585" in t]
print(len(one(60, "2026-08-24T09:00:00")), len(one(62, "2026-08-26T09:00:00")))'
    [ "$status" -eq 0 ]
    [ "$output" = "1 0" ]
}

@test "everything you owe is one clause, not one line per category" {
    # Four consecutive sentences about Kyle's inbox is a status report given to a room
    # that came to hear an ask. Nothing is dropped -- the tail counts every row -- but
    # only the kind teammates actually chase him for is named.
    run su 'd = payload(ledger={"they_owe": [], "you_owe_closed": [], "you_owe":
    [owed("review-owed", "!10408", 17, who="vadym")]
    + [owed("reply-owed", "!96%d" % i, 13 - i, who="max") for i in range(5)]
    + [owed("slack-mention", "#tech-drive", 10, who="kean")]
    + [owed("slack-dm", "DM", 6, who="loganwenzel")]})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c .)" -eq 1 ]
    [[ "$output" == *"!10408"* ]]
    [[ "$output" == *"7 more waiting on me"* ]]
    [[ "$output" != *"tech-drive"* ]]
    [[ "$output" != *"loganwenzel"* ]]
}

@test "a review he owes leads the clause even when something older is behind it" {
    # A departure from the ledger's worst-first order, and a deliberate one: the ledger
    # ranks by what costs Kyle most, a standup by what the room is waiting on. Teammates
    # wait on his reviews; they never chase his DMs.
    run su 'd = payload(ledger={"they_owe": [], "you_owe_closed": [], "you_owe": [
    owed("slack-dm", "DM", 40, who="loganwenzel"),
    owed("review-owed", "!10408", 3, who="vadym")]})
print(beat(d, "2026-08-24T09:00:00", "blocked"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"!10408"* ]]
    [[ "$output" != *"loganwenzel"* ]]
}

@test "what you owe is said out loud alongside what you are owed" {
    run su 'd = payload(ledger={
    "they_owe": [owed("review-silence", "!100", 4, who=["brian"])],
    "you_owe": [owed("review-owed", "!10408", 17, who="vadym")],
    "you_owe_closed": []})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c .)" -eq 2 ]
    [[ "$(echo "$output" | head -1)" == *"nobody has reviewed"* ]]
    [[ "$(echo "$output" | tail -1)" == *"I owe"* ]]
    [[ "$(echo "$output" | tail -1)" == *"vadym"* ]]
}

# ── the reviews he is in the middle of ───────────────────────────────────────
#
# Kyle says these out loud -- "i have 6802" -- and until `reviews[]` existed nothing in
# this file could. The risk is not omission: twenty-one of his twenty-three reviews are his
# move, so the failure mode is reading the whole list out. What is pinned below is the
# partition that stops that, and the clock the window is measured on.

@test "a review nobody touched in the window is not standup material" {
    run su 'd = payload(reviews=[review(10500, 40, "mine", 0,
    my_last=ep("2026-08-01T09:00:00"), their_last=ep("2026-08-02T09:00:00"))],
    ledger={"they_owe": [], "you_owe": [], "you_owe_closed": []})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [[ "$output" != *"moved"* ]]
}

@test "a review either side touched in the window is said, with rounds and whose move" {
    run su 'd = payload(reviews=[review(10265, 20, "theirs", 12, author="ella",
    my_last=ep("2026-08-20T09:00:00"), their_last=ep("2026-08-22T09:00:00"))],
    ledger={"they_owe": [], "you_owe": [], "you_owe_closed": []})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"!10265"* ]]
    [[ "$output" == *"ella"* ]]
    [[ "$output" == *"round 12"* ]]
    [[ "$output" == *"their move"* ]]
}

@test "a round of his own landing in the window counts as movement" {
    run su 'd = payload(reviews=[review(10475, 7, "mine", 5,
    my_last=ep("2026-08-22T14:00:00"), their_last=ep("2026-08-01T09:00:00"))],
    ledger={"they_owe": [], "you_owe": [], "you_owe_closed": []})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"!10475"* ]]
    [[ "$output" == *"round 5"* ]]
}

@test "the ball in his court is said only for reviews the ledger cannot hold" {
    # `rounds > 0` and "he has already spoken on it" are the same test read from two
    # sides, and the second is exactly what drops a merge request out of `you_owe`. So
    # the two halves partition the list: nothing is said twice and nothing is lost.
    run su 'd = payload(reviews=[
    review(10600, 30, "mine", 0),
    review(10601, 20, "mine", 4)],
    ledger={"they_owe": [], "you_owe_closed": [],
            "you_owe": [owed("review-owed", "!10600", 30, who="logan")]})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"!10601"* ]]
    # !10600 is the ledger clause’s business and is named there, once.
    [ "$(echo "$output" | grep -c '''!10600''')" -eq 1 ]
}

@test "a reference the ledger clause just read out is not read out again" {
    run su 'd = payload(reviews=[review(10408, 17, "mine", 2, author="vadym")],
    ledger={"they_owe": [], "you_owe_closed": [],
            "you_owe": [owed("review-owed", "!10408", 17, who="vadym")]})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c '''!10408''')" -eq 1 ]
}

@test "twenty-three reviews are two lines with a stated remainder, never a list" {
    run su 'rs = [review(10600 + i, 40 - i, "mine", 1 + i) for i in range(23)]
d = payload(reviews=rs,
    ledger={"they_owe": [], "you_owe": [], "you_owe_closed": []})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c .)" -le 2 ]
    [[ "$output" == *"more"* ]]
}

@test "no reviews on the wire leaves the beat exactly as it was" {
    run su 'd = payload(ledger={"they_owe": [], "you_owe_closed": [],
    "you_owe": [owed("review-owed", "!10408", 17, who="vadym")]})
for t in beat(d, "2026-08-24T09:00:00", "blocked"): print(t)'
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | grep -c .)" -eq 1 ]
    [[ "$output" == *"I owe"* ]]
}

@test "a review reference points at its row in the page's reviewing section" {
    run su 'd = payload(reviews=[review(10265, 20, "theirs", 12, author="ella",
    my_last=ep("2026-08-22T09:00:00"), their_last=ep("2026-08-23T09:00:00"))],
    ledger={"they_owe": [], "you_owe": [], "you_owe_closed": []})
st = build(d, "2026-08-24T09:00:00")
b = next(x for x in st["beats"] if x["kind"] == "blocked")
for it in b["items"]:
    for p in it["parts"]:
        if isinstance(p, dict):
            print(p.get("t"), p.get("of"), p.get("fp"))'
    [ "$status" -eq 0 ]
    [ "$output" = "!10265 review rfp10265" ]
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

@test "what moved already said is not offered back as today's plan" {
    # This beat used to open with the two most recent arcs unconditionally -- which are by
    # definition the two `moved` had just listed -- so half of it was the previous beat
    # repeated, in the phrasing that made it worst.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "the release cut", own_activity=sat, stage="local-only",
                      state="65 commits exist only here")],
            sprint={"issues": [{"key": "UL-2", "status": "In Progress", "summary": "mine",
                                "handed_off": False, "done": False, "url": ""}]})
print(beat(d, "2026-08-24T09:00:00", "moved"))
print(beat(d, "2026-08-24T09:00:00", "next"))'
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | head -1)" == *"the release cut"* ]]
    [[ "$(echo "$output" | tail -1)" != *"the release cut"* ]]
    [[ "$(echo "$output" | tail -1)" == *"UL-2"* ]]
}

@test "the board leads what is in front of you, and fills the rest with workstreams" {
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "not in moved", own_activity=sat - 99999, state="s")],
            sprint={"issues": [{"key": "UL-2", "status": "In Progress", "summary": "mine",
                                "handed_off": False, "done": False, "url": ""}]})
for t in beat(d, "2026-08-24T09:00:00", "next"): print(t)'
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | head -1)" == *"UL-2"* ]]
    [[ "$(echo "$output" | tail -1)" == *"not in moved"* ]]
}

@test "a workstream the cap cut is still free to be what is in front of you" {
    # Cut by the cap is not the same as said. The exclusion is on what was actually
    # spoken, so the fourth workstream can still be raised here.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a%d" % i, "work %d" % i, own_activity=sat - i, state="s")
                  for i in range(5)])
print(beat(d, "2026-08-24T09:00:00", "moved"))
print(beat(d, "2026-08-24T09:00:00", "next"))'
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | head -1)" != *"work 3"* ]]
    [[ "$(echo "$output" | tail -1)" == *"work 3"* ]]
}

@test "a long Jira summary is cut rather than read to the end of" {
    run su 'd = payload(sprint={"issues": [{"key": "UL-1", "status": "In Progress",
    "summary": "report fails to load with 500 errors when both line and reference "
               "time range are active", "handed_off": False, "done": False, "url": ""}]})
print(beat(d, "2026-08-24T09:00:00", "next"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"…"* ]]
    [[ "$output" != *"are active"* ]]
}

@test "a parked workstream is not what is in front of you" {
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "set aside", own_activity=sat, stage="parked")])
print(beat(d, "2026-08-24T09:00:00", "next"))'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

# ── claimed ───────────────────────────────────────────────────────────────────
#
# The leading beat: what he said he would do at the last standup, each claim against what
# happened. Membership is the `asked` day equalling the window's opening day, and the
# outcomes are all somebody else's judgement -- work-arcs' closure evidence, the rung of
# the workstream the claim's own words name, or "not yet".

@test "a claim made on the last standup's day leads the block" {
    run su 'd = payload(ledger={"they_owe": [], "you_owe_closed": [], "you_owe": [
    owed("meeting-commitment", "FE Standup", 3, promised="migrate Dove workspaces",
         asked="2026-08-21", quote="I think I will get it in the next couple days")]})
st = build(d, "2026-08-24T09:00:00")
print(st["beats"][0]["kind"], "|", beat(d, "2026-08-24T09:00:00", "claimed"))'
    [ "$status" -eq 0 ]
    [[ "$output" == "claimed |"*"migrate Dove workspaces — not yet"* ]]
}

@test "a claim from an older standup is not replayed as last time's" {
    # Wednesday's claim was answered for at Friday's standup. The window opening Friday
    # covers only Friday's claims.
    run su 'd = payload(ledger={"they_owe": [], "you_owe_closed": [], "you_owe": [
    owed("meeting-commitment", "FE Standup", 5, promised="an old promise",
         asked="2026-08-19", quote="old words")]})
print(beat(d, "2026-08-24T09:00:00", "claimed"))'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "a Slack promise is not something he claimed at the standup" {
    run su 'd = payload(ledger={"they_owe": [], "you_owe_closed": [], "you_owe": [
    owed("commitment", "#tech-drive", 3, promised="typed in a channel",
         asked="2026-08-21", quote="will do")]})
print(beat(d, "2026-08-24T09:00:00", "claimed"))'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "a claim kept on evidence is said with the evidence that closed it" {
    run su 'closed = owed("meeting-commitment", "FE Standup", 3,
             promised="review the crash patterns MR", asked="2026-08-21",
             quote="I will review !10600", closed_by="!10600 merged the same day",
             closed_ts=at("2026-08-21T16:00:00").timestamp(), closed_url="u")
d = payload(ledger={"they_owe": [], "you_owe": [], "you_owe_closed": [closed]})
print(beat(d, "2026-08-24T09:00:00", "claimed"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"review the crash patterns MR — !10600 merged the same day"* ]]
}

@test "a kept claim is not read out again by discussed as a fresh closure" {
    run su 'closed = owed("meeting-commitment", "FE Standup", 3,
             promised="review the crash patterns MR", asked="2026-08-21",
             quote="I will review !10600", closed_by="!10600 merged the same day",
             closed_ts=at("2026-08-21T16:00:00").timestamp(), closed_url="u")
d = payload(ledger={"they_owe": [], "you_owe": [], "you_owe_closed": [closed]})
print(beat(d, "2026-08-24T09:00:00", "discussed"))'
    [ "$status" -eq 0 ]
    [ "$output" = "[]" ]
}

@test "a closure claimed at an older standup still reaches discussed" {
    # The dedup is per-claim, not a blanket: a promise made two standups ago and kept on
    # Tuesday is Tuesday's news and the claimed beat never mentioned it.
    run su 'closed = owed("meeting-commitment", "FE Standup", 5,
             promised="an older promise", asked="2026-08-19", quote="will do",
             closed_by="UB-1 moved to Done 2d after",
             closed_ts=at("2026-08-22T16:00:00").timestamp())
d = payload(ledger={"they_owe": [], "you_owe": [], "you_owe_closed": [closed]})
print(beat(d, "2026-08-24T09:00:00", "claimed"), beat(d, "2026-08-24T09:00:00", "discussed"))'
    [ "$status" -eq 0 ]
    [[ "$output" == "[] ["*"an older promise"* ]]
}

@test "a claim naming a ticket is answered with that workstream's rung" {
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
a = arc("a1", "Dove case inputs", own_activity=sat, stage="in-review",
        state="in review", ticket="UB-7001",
        mrs=[{"iid": 10554, "url": "u", "threads": []}])
d = payload(arcs=[a], ledger={"they_owe": [], "you_owe_closed": [], "you_owe": [
    owed("meeting-commitment", "FE Standup", 3, promised="finish UB-7001",
         asked="2026-08-21", quote="I will finish UB-7001 this week")]})
print(beat(d, "2026-08-24T09:00:00", "claimed"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"finish UB-7001 — !10554 in review"* ]]
}

@test "a workstream a claim answered for is not restated by moved or next" {
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
a = arc("a1", "Dove case inputs", own_activity=sat, stage="in-review",
        state="in review", ticket="UB-7001",
        mrs=[{"iid": 10554, "url": "u", "threads": []}])
d = payload(arcs=[a], ledger={"they_owe": [], "you_owe_closed": [], "you_owe": [
    owed("meeting-commitment", "FE Standup", 3, promised="finish UB-7001",
         asked="2026-08-21", quote="I will finish UB-7001 this week")]})
print(beat(d, "2026-08-24T09:00:00", "moved"), beat(d, "2026-08-24T09:00:00", "next"))'
    [ "$status" -eq 0 ]
    [ "$output" = "[] []" ]
}

@test "a bare ticket number he said out loud joins nothing" {
    # "682" could be half the board. A wrong join puts the wrong rung on a claim, so the
    # honest answer is "not yet" and one glance at the page.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
a = arc("a1", "the 682 work", own_activity=sat, state="in review", ticket="UB-682")
d = payload(arcs=[a], ledger={"they_owe": [], "you_owe_closed": [], "you_owe": [
    owed("meeting-commitment", "FE Standup", 3, promised="code review for 682",
         asked="2026-08-21", quote="doing a lot of code review for 682")]})
print(beat(d, "2026-08-24T09:00:00", "claimed"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"code review for 682 — not yet"* ]]
    [[ "$output" != *"in review"* ]]
}

@test "an unjoined claim carries the clock he set himself, in his words" {
    run su 'd = payload(ledger={"they_owe": [], "you_owe_closed": [], "you_owe": [
    owed("meeting-commitment", "FE Standup", 3, promised="migrate Dove workspaces",
         asked="2026-08-21", quote="non-trivial but soon",
         deadline="in the next couple days")]})
print(beat(d, "2026-08-24T09:00:00", "claimed"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"not yet (you said in the next couple days)"* ]]
}

@test "a claim answered not-yet is not also counted as a debt he owes" {
    run su 'd = payload(ledger={"they_owe": [], "you_owe_closed": [], "you_owe": [
    owed("meeting-commitment", "FE Standup", 3, promised="migrate Dove workspaces",
         asked="2026-08-21", quote="soon"),
    owed("review-owed", "!10408", 17, who="vadym")]})
print(beat(d, "2026-08-24T09:00:00", "blocked"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"!10408"* ]]
    [[ "$output" != *"more waiting on me"* ]]
    [[ "$output" != *"FE Standup"* ]]
}

@test "kept claims lead the beat, in the ledger's own order inside each half" {
    run su 'mk = lambda i, **kw: owed("meeting-commitment", "FE Standup", 3, fp="f%d" % i,
                                      asked="2026-08-21", quote="q", **kw)
d = payload(ledger={"they_owe": [],
    "you_owe": [mk(1, promised="still open one"), mk(2, promised="still open two")],
    "you_owe_closed": [mk(3, promised="kept one", closed_by="!1 merged the same day",
                          closed_ts=at("2026-08-22T09:00:00").timestamp())]})
print(beat(d, "2026-08-24T09:00:00", "claimed"))'
    [ "$status" -eq 0 ]
    [[ "$output" == "['kept one — !1 merged the same day', 'still open one — not yet', 'still open two — not yet']" ]]
}

# ── the whole block ───────────────────────────────────────────────────────────

@test "a truncated beat says how many it left out" {
    # A cap that says nothing is indistinguishable from a complete list.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a%d" % i, "work %d" % i, own_activity=sat - i, state="s")
                  for i in range(9)])
print(len(beat(d, "2026-08-24T09:00:00", "moved")),
      beat(d, "2026-08-24T09:00:00", "moved")[-1])'
    [ "$status" -eq 0 ]
    [[ "$output" == "4 "*"6 more not listed"* ]]
}

@test "an empty graph is an empty block and not an error" {
    run su 'st = build(payload(), "2026-08-24T09:00:00")
print(st["empty"], [len(b["items"]) for b in st["beats"]])'
    [ "$status" -eq 0 ]
    [ "$output" = "True [0, 0, 0, 0, 0]" ]
}

@test "the text projection is one composition, so page and clipboard cannot disagree" {
    # The page renders `beats`; the copy button hands over `text`. Two projections of one
    # composition is how the screen and the clipboard end up disagreeing about Tuesday.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[arc("a", "the only thing", own_activity=sat, state="s")])
st = build(d, "2026-08-24T09:00:00")
mv = next(b for b in st["beats"] if b["kind"] == "moved")
print("the only thing" in st["text"], mv["items"][0]["text"])'
    [ "$status" -eq 0 ]
    [ "$output" = "True the only thing — s" ]
}

@test "the whole block is about eight lines on a corpus the size of the real one" {
    # The number that matters. This is the shape of the payload the file was rewritten
    # against -- six workstreams touched, eleven MRs nobody has reviewed, sixteen debts of
    # his own, four long stalls, two sprint tickets -- and the version before this one
    # spoke twenty-two lines of it.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(
    arcs=[arc("a%d" % i, "workstream %d" % i, own_activity=sat - i, stage="local-only",
              state="%d commits exist only here" % (60 - i)) for i in range(6)],
    sprint={"issues": [{"key": "UL-%d" % i, "status": "In Progress",
                        "summary": "something on the board", "handed_off": False,
                        "done": False, "url": ""} for i in range(2)]},
    ledger={"you_owe_closed": [],
            "they_owe": [owed("review-silence", "!104%02d" % i, 18 - i,
                              who=["brian", "vadym", "ajit", "Matt", "ella"])
                         for i in range(11)]
                        + [owed("ticket-stalled", "DE-2585", 159, who="Neville"),
                           owed("ticket-stalled", "UB-6663", 116, who="Irene")],
            "you_owe": [owed("review-owed", "!1040%d" % i, 17 - i, who="vadym")
                        for i in range(8)]
                       + [owed("reply-owed", "!96%d" % i, 13 - i, who="max")
                          for i in range(5)]
                       + [owed("slack-mention", "#tech-drive", 10, who="kean"),
                          owed("slack-dm", "DM", 6, who="loganwenzel")]})
lines = spoken(d, "2026-08-24T09:00:00")
print(len(lines))
print("\n".join(lines))'
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | head -1)" -le 8 ]
    [[ "$output" != *"commit"* ]]
    [[ "$output" != *"60"* ]]
}

@test "no beat anywhere says a number of commits" {
    # An acceptance criterion rather than a preference: every count-bearing rung, all four
    # beats, one assertion.
    run su 'sat = int(at("2026-08-22T14:00:00").timestamp())
d = payload(arcs=[
    arc("a", "unpushed", own_activity=sat, stage="local-only", unpushed_live=65,
        state="65 commits exist only here"),
    arc("b", "residue", own_activity=sat - 1, stage="pre-landing",
        state="12 branches older than !10398, merged 2026-08-14")])
t = build(d, "2026-08-24T09:00:00")["text"]
print("commit" in t, "branches older" in t, "65" in t, "12" in t)'
    [ "$status" -eq 0 ]
    [ "$output" = "False False False False" ]
}

@test "the graph passes through untouched with one key added" {
    run su 'd = payload(arcs=[arc("a", "x")])
before = set(d)
d["standup"] = build(d, "2026-08-24T09:00:00")
print(sorted(set(d) - before))'
    [ "$status" -eq 0 ]
    [ "$output" = "['standup']" ]
}

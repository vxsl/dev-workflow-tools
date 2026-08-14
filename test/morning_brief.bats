#!/usr/bin/env bats
# Tests for the morning brief's selection logic -- arc-morning.
#
# The brief is the loudest paragraph on the page and it makes five claims a morning, so
# the failure that matters is not a crash. It is a sentence that is grammatical, confident
# and wrong: the wrong row picked as "the oldest", a promise called late that was not, an
# acknowledged fact reopening the page, a count that disagrees with the section it points
# at. Every test here is one of those.
#
# What is deliberately NOT tested: the wording. The sentences are read against the real
# payload and tuned by reading them (there are examples in the commit message), and pinning
# the prose in assertions would make every improvement a test failure. What is pinned is
# which fact was chosen, in what order, and what was said about its clock.
#
# The composition functions are called directly. They are pure over the payload dict, and
# reaching them through the CLI would only add a JSON round trip.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    # No test may read or write the real morning cache, and none may make a model call:
    # every composition here runs deterministically.
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
}

teardown() {
    teardown_temp_dir
}

# Runs a python snippet with arc-morning imported as `am` and the payload builders in
# scope. GENERATED fixes "now" at Thursday 14 August 2026, so every day count in a test is
# a fact about the fixture rather than about the day the suite runs.
am() {
    python3 - "$REPO_ROOT/bin/arc-morning" <<PY
import importlib.machinery, importlib.util, sys, json
loader = importlib.machinery.SourceFileLoader("am", sys.argv[1])
spec = importlib.util.spec_from_loader("am", loader)
am = importlib.util.module_from_spec(spec)
sys.argv = ["am"]
loader.exec_module(am)

GENERATED = "2026-08-14T07:30:00-0700"      # a Thursday

def owed(kind, ref, days, **kw):
    """One ledger row. Its fp defaults to the ref, which is all any test needs."""
    e = {"kind": kind, "ref": ref, "days": days, "who": kw.pop("who", ""),
         "fp": kw.pop("fp", "fp-" + ref), "url": "", "title": "", "asked": ""}
    e.update(kw)
    return e

def arc(aid, label, **kw):
    a = {"id": aid, "label": label, "brief": {}, "activity": {}}
    a.update(kw)
    return a

def dropped(aid, label, why, cliff=9, **kw):
    a = arc(aid, label, **kw)
    a["activity"] = {"cliff_days": cliff,
                     "forgotten": {"verdict": True, "why": why, "fp": "fg-" + aid}}
    return a

def mismatch(key, status, unpushed, **kw):
    m = {"issue": {"key": key, "status": status, "url": ""},
         "arc": {"unpushed_live": unpushed}, "ref": key,
         "why": "status '%s' but %d commits never pushed" % (status, unpushed),
         "fp": "gp-" + key}
    m.update(kw)
    return m

def payload(**kw):
    d = {"generated": GENERATED,
         "since_last_run": {"previous_generated": None, "interval_seconds": None,
                            "compared": 0, "changed": 0, "changes": []},
         "arcs": [], "forgotten": [], "gap": {},
         "ledger": {"they_owe": [], "you_owe": []}}
    d.update(kw)
    return d

def kinds(d):
    return [s["kind"] for s in am.compose(d)]

def says(d, kind):
    """The text of the one sentence of that kind, or "" -- the assertion surface."""
    return next((s["text"] for s in am.compose(d) if s["kind"] == kind), "")

$1
PY
}

# ── the order of what bites soonest ───────────────────────────────────────────

@test "all five inputs compose in the plan's order of priority" {
    # The order is the whole selection rule: what changed, what is owed, what is overdue,
    # what was dropped, what contradicts. Nothing downstream re-sorts these.
    run am '
d = payload(
    since_last_run={"previous_generated": "2026-08-13T21:00:00-0700",
                    "interval_seconds": 37800, "compared": 40, "changed": 1,
                    "changes": [{"id": "a1", "label": "one", "kinds": ["conflict"],
                                 "what": ["!1 no longer merges"],
                                 "evidence": [{"kind": "conflict",
                                               "what": "!1 no longer merges"}]}]},
    arcs=[arc("a1", "one"), dropped("a2", "two", "8 commits, then nothing.")],
    forgotten=["a2"],
    gap={"status_mismatch": [mismatch("UL-1", "In Review", 5)]},
    ledger={"they_owe": [owed("review-silence", "!9", 30, who=["a", "b"])],
            "you_owe": [owed("commitment", "#chan", 7, promised="ship it Monday",
                             asked="2026-08-07")]})
print(" ".join(kinds(d)))'
    [ "$output" = "changed owed overdue forgotten contradiction" ]
}

@test "a sentence with nothing to say simply vanishes" {
    # Not an empty-state, not a "no forgotten work" line. The brief is three to six
    # sentences because it drops the ones with no fact under them.
    run am '
d = payload(ledger={"they_owe": [owed("ticket-stalled", "DE-1", 100)], "you_owe": []})
print(" ".join(kinds(d)))'
    [ "$output" = "owed" ]
}

# ── the ledger: which of the two directions leads ─────────────────────────────

@test "the oldest row leads whichever side it is on" {
    run am '
they = [owed("ticket-stalled", "DE-1", 149, who="Neville")]
you = [owed("slack-dm", "DM", 10, who="bill")]
print(says(payload(ledger={"they_owe": they, "you_owe": you}), "owed"))
print(says(payload(ledger={"they_owe": [], "you_owe": you}), "owed"))'
    [[ "${lines[0]}" == "DE-1 has been sitting with Neville for 149 days — the oldest open loop in either direction; on your own side, a DM from bill has gone 10 days unanswered." ]]
    [[ "${lines[1]}" == "The oldest open loop in either direction is yours: a DM from bill has gone 10 days unanswered." ]]
}

@test "a tie on the clock goes to the side you can discharge yourself" {
    # Two things owed the same number of days is common -- the clocks are whole days. The
    # tiebreak is not arbitrary: your own debt is the one this morning can clear.
    run am '
d = payload(ledger={"they_owe": [owed("ticket-stalled", "DE-1", 12, who="Neville")],
                    "you_owe": [owed("review-owed", "!7", 12, who="vadym")]})
print(says(d, "owed"))'
    [ "$output" = "The oldest open loop in either direction is yours: vadym has been waiting 12 days for your review of !7; the other way, DE-1 has been sitting with Neville for 12 days." ]
}

@test "one direction empty is said out loud rather than left ambiguous" {
    # "Nothing is owed the other way" is a claim the ledger supports and a reader cannot
    # infer from a sentence that simply does not mention it.
    run am '
d = payload(ledger={"they_owe": [owed("ticket-stalled", "DE-1", 40, who="Neville")],
                    "you_owe": []})
print(says(d, "owed"))'
    [[ "$output" == *"nothing is owed the other way."* ]]
}

@test "an unconsulted ledger says nothing at all" {
    # An empty ledger and an unasked one are different claims -- mrs_known's rule. Neither
    # an owed sentence nor the all-clear may assert anything about a source never read.
    run am '
d = payload(ledger=None)
print(" ".join(kinds(d)))
print(says(d, "allclear"))'
    [ "${lines[0]}" = "allclear" ]
    [ "${lines[1]}" = "Nothing has fallen off a cliff and Jira agrees with the code." ]
}

# ── acknowledgement ───────────────────────────────────────────────────────────

@test "an acknowledged row does not open the page" {
    # The ✕ contract. If the loudest paragraph ignores it the mechanism is decorative.
    run am '
d = payload(ledger={"they_owe": [owed("ticket-stalled", "DE-1", 149, who="Neville",
                                      dismissed=True),
                                 owed("ticket-stalled", "DE-2", 20, who="Irene")],
                    "you_owe": []})
print(says(d, "owed")[:4])'
    [ "$output" = "DE-2" ]
}

@test "acknowledged rows leave the counts too" {
    # A count that includes hidden rows disagrees with the section it points at, and the
    # ledger headings count what is visible.
    run am '
mism = [mismatch("UL-1", "In Review", 5),
        mismatch("UL-2", "Releasing", 1, dismissed=True),
        mismatch("UL-3", "In Review", 2)]
print(says(payload(gap={"status_mismatch": mism}), "contradiction"))'
    [[ "$output" == *"the widest of 2 tickets"* ]]
}

@test "an acknowledged cliff verdict is not the freshest thing you dropped" {
    run am '
d = payload(arcs=[dropped("a1", "one", "40 commits, then nothing.", cliff=9),
                  dropped("a2", "two", "9 commits, then nothing.", cliff=20)],
            forgotten=["a1", "a2"])
d["arcs"][0]["activity"]["forgotten"]["dismissed"] = True
print(says(d, "forgotten"))'
    [[ "$output" == *"is two — 9 commits, then nothing."* ]]
    [[ "$output" != *"1 other"* ]]
}

# ── promises: the only clock read out of a sentence ───────────────────────────

@test "a promise past the day it named is overdue, dated from the day it named" {
    # The plan's own example, with its real numbers: said on Friday 7 August, for Monday,
    # read on Thursday 14th. The promise is 7 days old and 4 days late, and those are
    # different facts -- `days` ages the message, not the promise.
    run am '
d = payload(ledger={"they_owe": [], "you_owe": [
    owed("commitment", "#impl-trimet", 7, who="",
         promised="take a look at it Monday", asked="2026-08-07")]})
print(says(d, "overdue"))'
    [[ "$output" == *"came due on Mon 10 Aug, 4 days ago."* ]]
}

@test "a promise still inside its own window is not late" {
    # Said Wednesday for Friday, read Thursday. The message is a day old and the promise
    # is not due yet; ranking on the message's age would have called this overdue.
    run am '
d = payload(ledger={"they_owe": [], "you_owe": [
    owed("commitment", "#chan", 1, promised="send the notes Friday",
         asked="2026-08-12")]})
print(" ".join(kinds(d)) or "(nothing)")'
    [ "$output" = "owed" ]
}

@test "an ambiguous phrase resolves to the later reading" {
    # "Next Monday" said on a Friday is three days away or ten, and it is read as ten, so
    # a promise is only ever called late when it is late on every reading. A wrong "you
    # are late" costs more trust than a missed one.
    run am '
d = payload(ledger={"they_owe": [], "you_owe": [
    owed("commitment", "#chan", 7, promised="pick it up next Monday",
         asked="2026-08-07")]})
print(" ".join(kinds(d)))
print(am.promised_due({"asked": "2026-08-07"}, "pick it up next Monday")[0])
print(am.promised_due({"asked": "2026-08-07"}, "pick it up Monday")[0])'
    [ "${lines[0]}" = "owed" ]
    [ "${lines[1]}" = "2026-08-17" ]
    [ "${lines[2]}" = "2026-08-10" ]
}

@test "a promise that named no time never comes due" {
    # Most of them. "I'll take over investigating" has no clock, and inventing one for it
    # would make the overdue sentence fire on nearly every commitment in the ledger.
    run am '
for said in ("take over investigating the issue", "do a release once cherry-pick "
             "completes", "take a look at the MR"):
    print(said, "->", am.promised_due({"asked": "2026-08-01"}, said))'
    [[ "${lines[0]}" == *"-> None" ]]
    [[ "${lines[1]}" == *"-> None" ]]
    [[ "${lines[2]}" == *"-> None" ]]
}

@test "the clock is read from the restatement and never from the quoted message" {
    # The quote is the whole Slack message and its dates are usually about something else.
    # "The release was Monday, I'll pick this up after" must not resolve to that Monday.
    run am '
row = owed("commitment", "#chan", 6, promised="pick up the investigation",
           asked="2026-08-08",
           quote="the release was Monday, I will pick this up after")
print(am.promised_due(row))'
    [ "$output" = "None" ]
}

@test "the most overdue promise leads, and the rest are counted not listed" {
    run am '
d = payload(ledger={"they_owe": [], "you_owe": [
    owed("commitment", "#a", 3, promised="reply tomorrow", asked="2026-08-11"),
    owed("commitment", "#b", 9, promised="look at it Monday", asked="2026-08-05")]})
print(says(d, "overdue"))'
    [[ "$output" == "You said in #b you would look at it Monday"* ]]
    [[ "$output" == *"and 1 other promise of yours is also past its date."* ]]
}

# ── what moved, and when "overnight" is the honest word ───────────────────────

@test "overnight is only said when a night actually passed" {
    # The word the plan asks for, earned from the interval rather than assumed. A page
    # rebuilt twice before lunch did not span a night, and saying it did makes every
    # claim beside it worth less.
    run am '
def phrase(prev, secs, now="2026-08-14T07:30:00-0700"):
    return am.interval_phrase({"previous_generated": prev, "interval_seconds": secs}, now)
print(phrase("2026-08-13T21:00:00-0700", 37800))
print(phrase("2026-08-14T06:39:00-0700", 3060))
print(phrase("2026-08-13T23:55:00-0700", 12300))
print(phrase("2026-08-11T07:30:00-0700", 259200))
print(phrase(None, None))'
    [ "${lines[0]}" = "overnight" ]
    [ "${lines[1]}" = "in the 51 minutes since the last build" ]
    [ "${lines[2]}" = "in the 3 hours since the last build" ]
    [ "${lines[3]}" = "in the 3 days since the last build" ]
    [ "${lines[4]}" = "since the last build" ]
}

@test "one change is named, several are counted and the sharpest named" {
    # The strip further down is the list. This is the reason to read it, so it names the
    # top of the ranking work-arcs already computed and never re-ranks.
    run am '
def chg(i, kind, what):
    return {"id": "a%d" % i, "label": "arc %d" % i, "kinds": [kind], "what": [what],
            "evidence": [{"kind": kind, "what": what}]}
one = payload(arcs=[arc("a1", "arc 1")],
              since_last_run={"previous_generated": "2026-08-13T21:00:00-0700",
                              "interval_seconds": 37800, "compared": 40, "changed": 1,
                              "changes": [chg(1, "conflict", "!1 no longer merges")]})
print(says(one, "changed"))
many = payload(arcs=[arc("a1", "arc 1"), arc("a2", "arc 2")],
               since_last_run={"previous_generated": "2026-08-13T21:00:00-0700",
                               "interval_seconds": 37800, "compared": 40, "changed": 2,
                               "changes": [chg(1, "conflict", "!1 no longer merges"),
                                           chg(2, "ticket", "UL-2 moved")]})
print(says(many, "changed"))'
    [ "${lines[0]}" = "Overnight, arc 1 changed under you: !1 no longer merges." ]
    [[ "${lines[1]}" == "Overnight, 2 of 40 workstreams moved under you — the sharpest is arc 1, where !1 no longer merges." ]]
}

@test "the arc is named by its brief and not by its cluster label" {
    # The reason this stage runs after arc-brief at all.
    run am '
d = payload(arcs=[arc("a1", "ul-1692-wip", brief={"name": "SMP selected state"})],
            since_last_run={"previous_generated": "2026-08-13T21:00:00-0700",
                            "interval_seconds": 37800, "compared": 4, "changed": 1,
                            "changes": [{"id": "a1", "label": "ul-1692-wip",
                                         "kinds": ["ticket"], "what": ["UL-1692 moved"],
                                         "evidence": [{"kind": "ticket",
                                                       "what": "UL-1692 moved"}]}]})
print(says(d, "changed"))'
    [[ "$output" == *"SMP selected state changed under you"* ]]
}

@test "a quiet hour is not news, a quiet night is" {
    # Silence is only information when the gap was long enough for noise to have been
    # likely. Otherwise this is the stamp line said twice, in larger type. A ledger row
    # keeps the all-clear from firing, so what is measured here is the quiet line alone.
    run am '
LEDGER = {"they_owe": [owed("ticket-stalled", "DE-1", 5, who="Neville")], "you_owe": []}
def quiet(secs, prev="2026-08-13T21:00:00-0700"):
    d = payload(ledger=LEDGER,
                since_last_run={"previous_generated": prev, "interval_seconds": secs,
                                "compared": 40, "changed": 0, "changes": []})
    return " ".join(kinds(d))
print(quiet(3060))
print(quiet(37800))
print(" ".join(kinds(payload(ledger=LEDGER))))
print(says(payload(ledger=LEDGER,
                   since_last_run={"previous_generated": "2026-08-13T21:00:00-0700",
                                   "interval_seconds": 37800, "compared": 40,
                                   "changed": 0, "changes": []}), "quiet"))'
    [ "${lines[0]}" = "owed" ]
    [ "${lines[1]}" = "quiet owed" ]
    [ "${lines[2]}" = "owed" ]
    [ "${lines[3]}" = "Overnight, nothing moved under you — all 40 workstreams the last build saw are as you left them." ]
}

# ── the contradiction, and the rankings nobody re-derives ─────────────────────

@test "the widest mismatch wins, on the same rule the lede used" {
    run am '
mism = [mismatch("UL-1", "In Review", 6), mismatch("UL-2", "In Qualification", 202),
        mismatch("UL-3", "Releasing", 1)]
print(says(payload(gap={"status_mismatch": mism}), "contradiction"))'
    [[ "$output" == *"UL-2"* ]]
    [[ "$output" == *"202 of its commits have never reached a remote"* ]]
    [[ "$output" == *"the widest of 3 tickets"* ]]
}

@test "the forgotten order comes down the wire and is never re-sorted here" {
    # work-arcs ranks these freshest-cliff-first. Handed a deliberately unhelpful order,
    # this must follow it rather than re-deriving one -- a ranking with two authors will
    # differ in one of them.
    run am '
d = payload(arcs=[dropped("a1", "one", "5 commits, then nothing.", cliff=40),
                  dropped("a2", "two", "9 commits, then nothing.", cliff=9)],
            forgotten=["a1", "a2"])
print(says(d, "forgotten"))'
    [[ "$output" == *"is one — 5 commits, then nothing; 1 other fell off longer ago."* ]]
}

@test "the why-sentence is lifted whole rather than rebuilt" {
    # It already carries the level, the derivative and the reason it is still open, which
    # is the entire verdict. Composing a second version of it here would be a second
    # author for the same judgement.
    run am '
why = "19 sessions across 3 days, then nothing for 12 days, never landed."
d = payload(arcs=[dropped("a1", "one", why)], forgotten=["a1"])
print(says(d, "forgotten"))'
    [[ "$output" == *"— 19 sessions across 3 days, then nothing for 12 days, never landed." ]]
}

# ── degradation ───────────────────────────────────────────────────────────────

@test "an empty document says nothing rather than all-clear" {
    # A payload with no ledger, no cliff list and no gap has not established that nothing
    # is owed -- it has established nothing. Zero sentences, and arcs-page falls back to
    # the derived lede.
    run am 'b = am.build({}, model=""); print(len(b["sentences"]), repr(b["text"]))'
    [ "$output" = "0 ''" ]
}

@test "a genuinely quiet morning says so, and only about what was looked at" {
    run am '
print(says(payload(), "allclear"))
d = payload(); d.pop("gap"); d.pop("forgotten")
print(says(d, "allclear"))'
    [ "${lines[0]}" = "Nothing is owed in either direction, nothing has fallen off a cliff, and Jira agrees with the code." ]
    [ "${lines[1]}" = "Nothing is owed in either direction." ]
}

@test "text is a projection of parts, never composed beside them" {
    # The model cache fingerprints this string and the reader sees it. Two ways of
    # building it is two strings that will disagree.
    run am '
d = payload(ledger={"they_owe": [owed("ticket-stalled", "DE-1", 40, who="Neville")],
                    "you_owe": []})
b = am.build(d, model="")
print(b["text"] == am.text_of(b["parts"]))
print(all(s["text"] == am.text_of(s["parts"]) for s in b["sentences"]))
print(sum(1 for p in b["parts"] if not isinstance(p, str)))'
    [ "${lines[0]}" = "True" ]
    [ "${lines[1]}" = "True" ]
    [ "${lines[2]}" = "1" ]
}

@test "every sentence carries a link to the row it is a claim about" {
    # "The cards become the evidence layer you expand into" is only true if each claim
    # says which card. A sentence with no anchor is an assertion with no source.
    run am '
d = payload(
    arcs=[dropped("a2", "two", "8 commits, then nothing.")], forgotten=["a2"],
    gap={"status_mismatch": [mismatch("UL-1", "In Review", 5)]},
    ledger={"they_owe": [owed("review-silence", "!9", 30, who=["a", "b"])],
            "you_owe": [owed("slack-dm", "DM", 11, who="bill"),
                        owed("commitment", "#c", 7, promised="ship it Monday",
                             asked="2026-08-07")]})
for s in am.compose(d):
    links = [p for p in s["parts"] if not isinstance(p, str)]
    print(s["kind"], len(links), all(p.get("fp") or p.get("arc") or p.get("url")
                                     for p in links))'
    [ "${lines[0]}" = "owed 2 True" ]
    [ "${lines[1]}" = "overdue 1 True" ]
    [ "${lines[2]}" = "forgotten 1 True" ]
    [ "${lines[3]}" = "contradiction 1 True" ]
}

# ── the model pass is garnish, and the checks are what make it safe ───────────

@test "a rewrite that drops or invents a number is refused" {
    # "No new facts" enforced by code rather than requested by prompt, because the prompt
    # is the part that cannot be tested.
    run am '
det = "DE-1 has been with Neville for 149 days. 3 others fell off longer ago."
print(am.check(det, det.replace("149", "150"), ["DE-1"]))
print(am.check(det, det.replace(" 3 others fell off longer ago.", ""), ["DE-1"]))
print(am.check(det, det + " There are 4 open merge requests.", ["DE-1"]))'
    [[ "${lines[0]}" == *"dropped 149"*"invented 150"* ]]
    [[ "${lines[1]}" == *"dropped 3"* ]]
    [[ "${lines[2]}" == *"invented 4"* ]]
}

@test "a rewrite that loses or duplicates a link is refused" {
    # A span that moved or was reworded has nowhere to re-attach, and an unlinked claim in
    # the opening paragraph is the one thing this page may not print.
    run am '
det = "DE-1 has been with Neville for 149 days."
print(am.check(det, "The ticket has been with Neville for 149 days.", ["DE-1"]))
print(am.check(det, "DE-1: DE-1 has been with Neville for 149 days.", ["DE-1"]))
print(am.check(det, "- DE-1 has been with Neville for 149 days.", ["DE-1"]))
print(am.check(det, det, ["DE-1"]))'
    [[ "${lines[0]}" == *"appeared 0 times"* ]]
    [[ "${lines[1]}" == *"appeared 2 times"* ]]
    [[ "${lines[2]}" == *"list or a heading"* ]]
    [ "${lines[3]}" = "None" ]
}

@test "an accepted rewrite gets its links re-attached over the new words" {
    run am '
parts = ["The oldest is ", {"t": "DE-1", "fp": "x", "of": "ledger"}, " at 149 days."]
out = "At 149 days, DE-1 is the oldest."
print([p if isinstance(p, str) else p["t"] for p in am.reparts(out, parts)])
print("".join(p if isinstance(p, str) else p["t"] for p in am.reparts(out, parts)))'
    [ "${lines[0]}" = "['At 149 days, ', 'DE-1', ' is the oldest.']" ]
    [ "${lines[1]}" = "At 149 days, DE-1 is the oldest." ]
}

@test "a link phrase that is not unique declines the model pass rather than guessing" {
    # Two spans with the same words cannot be told apart in a rewrite. Declining costs a
    # nicer paragraph; guessing costs a link pointing at the wrong evidence.
    run am '
s = [am.sentence("x", ["see ", am.ref("DM", fp="a", of="ledger"), " and ",
                       am.ref("DM", fp="b", of="ledger"), "."])]
parts, note = am.smooth(s, "sonnet", "2026-08-14T07:30:00-0700")
print(parts, note)'
    [[ "$output" == "None skipped — 'DM' is not unique in the paragraph" ]]
}

@test "no model is a supported way to run, and it says so" {
    run am '
d = payload(ledger={"they_owe": [owed("ticket-stalled", "DE-1", 40, who="Neville")],
                    "you_owe": []})
b = am.build(d, model="")
print(b["source"], b["model"]["note"], len(b["sentences"]))
print(b["text"] == b["derived"])'
    [ "${lines[0]}" = "deterministic not attempted 1" ]
    [ "${lines[1]}" = "True" ]
}

@test "the cache keys on the prompt as well as the evidence" {
    # Item 1c's lesson, which cost a day: an evidence-keyed cache goes stale in exactly one
    # way, and it is that the question changed while the evidence did not. Both halves move
    # the key, and identical evidence asked the same question never re-pays.
    run am '
def key(tmpl, para):
    return am.cache_key("m", tmpl.format(anchors="    (none)", n=1, para=para))
base = key(am.MODEL_PROMPT, "DE-1 is 149 days old.")
print(base != key(am.MODEL_PROMPT.replace("Hard rules:", "Rules, all hard:"),
                  "DE-1 is 149 days old."))
print(base != key(am.MODEL_PROMPT, "DE-1 is 150 days old."))
print(base != am.cache_key("other-model",
                           am.MODEL_PROMPT.format(anchors="    (none)", n=1,
                                                  para="DE-1 is 149 days old.")))
print(base == key(am.MODEL_PROMPT, "DE-1 is 149 days old."))'
    [ "${lines[0]}" = "True" ]
    [ "${lines[1]}" = "True" ]
    [ "${lines[2]}" = "True" ]
    [ "${lines[3]}" = "True" ]
}

@test "identical evidence is answered from the cache without a call" {
    # The budget is one small call per changed morning. `--offline` proves the second read
    # never reaches the model: it is wired to refuse to make one.
    run am '
s = [am.sentence("x", ["DE-1 is 149 days old."])]
det = am.text_of(am.flat(s))
k = am.cache_key("m", am.MODEL_PROMPT.format(anchors="    (none)", n=1, para=det))
print(am.smooth(s, "m", "", offline=True)[1])
am.cache_write(k, {"at": "", "prose": "At 149 days, DE-1 is the oldest.", "why": ""})
parts, note = am.smooth(s, "m", "", offline=True)
print(note, "|", am.text_of(parts))'
    [ "${lines[0]}" = "not attempted" ]
    [ "${lines[1]}" = "cached (m) | At 149 days, DE-1 is the oldest." ]
}

# ── the brief against a commitment that closed on evidence ────────────────────
#
# close_commitments removes a kept promise from `you_owe` and moves it to
# `you_owe_closed`, and the overdue sentence is chosen from `you_owe`. So the interesting
# case is the one where the row the overdue sentence WOULD have led with is the row that
# closed: the sentence has to vanish rather than be composed out of a promise that was
# kept, and the ledger sentence has to stop stepping aside for a row that is no longer
# there.

@test "a promise that closed on evidence is not still called overdue" {
    run am '
p = owed("commitment", "#eng", 6, who="Neville", promised="send the doc Monday",
         asked="2026-08-06", fp="fp-promise")
other = owed("review-owed", "!101", 3, who="Logan")
open_led = {"they_owe": [], "you_owe": [p, other], "you_owe_closed": []}
shut = dict(p, closed_how="thread", closed_by="you posted in-thread: \"here\"")
shut_led = {"they_owe": [], "you_owe": [other], "you_owe_closed": [shut]}
print("open", kinds(payload(ledger=open_led)))
print("shut", kinds(payload(ledger=shut_led)))
print("shut-overdue", repr(says(payload(ledger=shut_led), "overdue")))'
    [ "$status" -eq 0 ]
    # While it is open the promise earns its own sentence...
    [[ "${lines[0]}" == *"overdue"* ]]
    # ...and once it closes there is no overdue sentence at all, rather than one about a
    # promise that was kept.
    [[ "${lines[1]}" != *"overdue"* ]]
    [[ "${lines[2]}" == "shut-overdue ''" ]]
}

@test "the ledger sentence stops standing aside for a row that closed" {
    # `owed_sentence` is passed the fp of the row the overdue sentence is about to take, so
    # the same fact does not open two consecutive sentences. When the overdue row closes
    # there is no fp to skip, and the ledger sentence must lead with the real oldest row
    # rather than keep a hole where the promise used to be.
    run am '
p = owed("commitment", "#eng", 6, who="Neville", promised="send the doc Monday",
         asked="2026-08-06", fp="fp-promise")
other = owed("review-owed", "!101", 3, who="Logan")
shut = dict(p, closed_how="thread", closed_by="you posted in-thread: \"here\"")
print(says(payload(ledger={"they_owe": [], "you_owe": [other],
                           "you_owe_closed": [shut]}), "owed"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"!101"* ]]
    [[ "$output" != *"send the doc"* ]]
}

@test "a ledger holding only a closed promise is all clear, not empty-handed" {
    # The pathological shape: every row closed on evidence this run. `you_owe` is empty and
    # `you_owe_closed` is not, and "nothing is owed in either direction" is then exactly
    # true -- the promise was kept. The page shows what closed it separately.
    run am '
shut = dict(owed("commitment", "#eng", 6, promised="send the doc Monday",
                 asked="2026-08-06", fp="fp-promise"),
            closed_how="thread", closed_by="you posted in-thread: \"here\"")
d = payload(ledger={"they_owe": [], "you_owe": [], "you_owe_closed": [shut]})
print(kinds(d))
print(says(d, "allclear"))'
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"allclear"* ]]
    [[ "${lines[1]}" == *"Nothing is owed in either direction"* ]]
}

#!/usr/bin/env bats
# Tests for joining a Slack thread to the arc it is about, and for not saying twice what
# the ledger already said once.
#
# The join is the whole feature. A thread attached to the wrong workstream is worse than a
# thread attached to none: the page's other lenses are derived and therefore trustworthy,
# and one card carrying somebody else's decision teaches the reader to distrust all of
# them. So the signals are exact identifiers only -- a ticket key that some arc owns, a
# branch name that exists, an MR iid that is open on the arc -- and every one of these
# tests is about a way an exact-looking identifier is not one:
#
#   UTF-8 / IPV-4              ticket-shaped, not tickets. TICKET_RE is built from
#                              JIRA_PROJECTS for exactly this reason
#   SBX-1                      a real key from a project nobody files against; recognisable
#                              in prose (JIRA_EXTRA_PROJECTS) and owned by no arc here
#   UL-9999                    a real-looking key that no arc owns -- not a join, a miss
#   !12 / wow!!10418           MR-shaped punctuation. MR_MENTION_RE's floor is three digits
#   main, fix                  branch names too generic to survive contact with prose
#
# The dedupe is the second half. A thread whose one decision is already a commitment row in
# the ledger must not also appear here as a decision: the same fact twice, in two registers,
# reads as two facts. Matching is on (channel, message ts) recovered from the permalink and
# not on the permalink string, because search and conversations.replies write the same
# message's URL differently -- one carries ?thread_ts=, the other does not.
#
# Called directly, like commitment_closeout.bats: everything here is pure once the Slack
# and model edges are stubbed, and going through the CLI would mean standing up a git repo,
# a GitLab and a Jira to test a string match.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    export JIRA_PROJECTS="UL,UB,DE"
    export JIRA_EXTRA_PROJECTS="SBX"
    # slack_threads returns before doing anything at all without one, so the tests that
    # exercise the sweep need a token to exist. It is deliberately not a real one, and every
    # test that gets this far stubs the two network edges; a test that forgot to would reach
    # Slack, be told the token is invalid, and take the same early exit.
    export SLACK_USER_TOKEN="xoxp-not-a-token"
}

teardown() {
    teardown_temp_dir
}

wa() {
    python3 - "$ARCS_ROOT/bin/work-arcs" <<PY
import importlib.machinery, importlib.util, sys, json, time
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
sys.argv = ["wa"]
loader.exec_module(wa)
wa.TICKET_RE = wa._ticket_re()

DAY = 86400
NOW = 1786500000.0

def arc(label, branches=(), mrs=(), aid=None):
    return {"id": aid or label, "label": label, "kind": "ticket",
            "branches": [{"name": b, "sha": "deadbeef"} for b in branches],
            "mrs": [{"iid": i, "url": f"https://gitlab/mr/{i}", "title": ""} for i in mrs],
            "stashes": [], "sessions": [], "demands": []}

def msg(ts, text, user="U2"):
    """A message as conversations.replies returns it: no permalink of its own."""
    return {"ts": f"{ts:.6f}", "text": text, "user": user}

def thread(msgs, chan="C1", name="chan", arc_label=None):
    return {"chan": chan, "name": name, "ts": msgs[0]["ts"], "msgs": msgs,
            "base": "https://acme.slack.com"}

class FakeHC:
    def __init__(self, out, rc=0, boom=None):
        self.out, self.rc, self.boom, self.prompts = out, rc, boom, []
    def run(self, argv, timeout=None):
        self.prompts.append(argv[-1])
        if self.boom:
            raise self.boom
        return type("R", (), {"returncode": self.rc, "stdout": self.out})()

$1
PY
}

# --- the ticket join ------------------------------------------------------------------

@test "a ticket key an arc owns joins the thread to that arc" {
    run wa '
idx = wa._thread_join_index([arc("UB-6802", branches=["UB-6802-catalog"])])
a, how, tok = wa._join_thread("I think UB-6802 already fixed that", idx)
print("arc", a and a["label"])
print("how", how, tok)
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"arc UB-6802"* ]]
    [[ "$output" == *"how ticket UB-6802"* ]]
}

@test "a ticket-shaped string that is not a ticket key joins nothing" {
    run wa '
idx = wa._thread_join_index([arc("UB-6802", branches=["UB-6802-catalog"])])
for text in ("the file is UTF-8 encoded", "over IPV-4 only", "see ABC-1234"):
    a, how, tok = wa._join_thread(text, idx)
    print(repr(text), "->", a and a["label"], how)
'
    [ "$status" -eq 0 ]
    [[ "$output" != *"UB-6802"* ]]
    [[ "$(grep -c 'None' <<<"$output")" -eq 3 ]]
}

@test "a real key that no arc owns is a miss, not a join to the nearest arc" {
    run wa '
idx = wa._thread_join_index([arc("UB-6802", branches=["UB-6802-catalog"])])
a, how, tok = wa._join_thread("blocked on UL-9999 landing first", idx)
print("arc", a and a["label"], "how", repr(how))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"arc None how ''"* ]]
}

@test "a JIRA_EXTRA_PROJECTS key is recognised in prose and still needs an arc to own it" {
    run wa '
print("re matches SBX:", bool(wa.TICKET_RE.search("SBX-12 is the initiative")))
idx = wa._thread_join_index([arc("UB-6802", branches=["UB-6802-catalog"])])
print("joins:", wa._join_thread("SBX-12 is the initiative", idx)[0])
idx2 = wa._thread_join_index([arc("SBX-12", branches=["SBX-12-work"])])
print("owned:", wa._join_thread("SBX-12 is the initiative", idx2)[0]["label"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"re matches SBX: True"* ]]
    [[ "$output" == *"joins: None"* ]]
    [[ "$output" == *"owned: SBX-12"* ]]
}

# --- the branch and MR joins ----------------------------------------------------------

@test "a branch name an arc holds joins the thread to that arc" {
    run wa '
idx = wa._thread_join_index([arc("adaptive", branches=["adaptive-backup"])])
a, how, tok = wa._join_thread("pushed it to adaptive-backup last night", idx)
print("arc", a and a["label"], "how", how)
a, how, tok = wa._join_thread("try origin/adaptive-backup.", idx)
print("prefixed", a and a["label"], "how", how)
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"arc adaptive how branch adaptive-backup"* ]]
    [[ "$output" == *"prefixed adaptive how branch adaptive-backup"* ]]
}

@test "a branch name too generic to survive prose is left out of the index" {
    run wa '
idx = wa._thread_join_index([arc("x", branches=["main", "fix", "wip", "a-b"])])
print("index:", sorted(idx["branches"]))
print("join:", wa._join_thread("this is the main problem, needs a fix", idx)[0])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"index: []"* ]]
    [[ "$output" == *"join: None"* ]]
}

@test "an MR reference joins on the iid an arc actually holds" {
    run wa '
idx = wa._thread_join_index([arc("slack threads", mrs=[10418])])
for text in ("see !10418 for the fix",
             "https://gitlab.com/g/p/-/merge_requests/10418",
             "wow!!10418", "only !12 left", "!99999999 is not one"):
    a, how, tok = wa._join_thread(text, idx)
    print(repr(text), "->", a and a["label"], how)
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"see !10418 for the fix' -> slack threads mr !10418"* ]]
    [[ "$output" == *"merge_requests/10418' -> slack threads mr !10418"* ]]
    [[ "$output" == *"wow!!10418' -> None"* ]]
    [[ "$output" == *"only !12 left' -> None"* ]]
    [[ "$output" == *"!99999999 is not one' -> None"* ]]
}

@test "a ticket outranks a branch, and a branch outranks an MR" {
    run wa '
idx = wa._thread_join_index([arc("T", branches=["UB-6802-catalog"]),
                             arc("B", branches=["adaptive-backup"]),
                             arc("M", mrs=[10418])])
print(wa._join_thread("UB-6802 on adaptive-backup, see !10418", idx)[1])
print(wa._join_thread("on adaptive-backup, see !10418", idx)[1])
print(wa._join_thread("see !10418", idx)[1])
'
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "ticket UB-6802" ]]
    [[ "${lines[1]}" == "branch adaptive-backup" ]]
    [[ "${lines[2]}" == "mr !10418" ]]
}

@test "the arc with the most matching identifiers wins, and ties break the same way twice" {
    run wa '
arcs = [arc("A", branches=["UB-6802-catalog"]), arc("B", branches=["UL-1744-lint"])]
# B is named once, A twice: the thread is about A even though B is mentioned first.
text = "UL-1744 reminds me: UB-6802 changed this, and UB-6802 again"
print("most:", wa._join_thread(text, wa._thread_join_index(arcs))[0]["label"])
# A dead tie resolves on which was mentioned first, and never on dict order.
tie = "UL-1744 and UB-6802"
print("tie:", wa._join_thread(tie, wa._thread_join_index(arcs))[0]["label"])
print("tie reversed input:", wa._join_thread(tie, wa._thread_join_index(arcs[::-1]))[0]["label"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"most: A"* ]]
    [[ "$output" == *"tie: B"* ]]
    [[ "$output" == *"tie reversed input: B"* ]]
}

# --- the dedupe against rows the ledger already shows ---------------------------------

@test "a decision whose message is already a ledger row is dropped" {
    run wa '
led = {"they_owe": [], "you_owe": [
    {"kind": "commitment", "url": "https://acme.slack.com/archives/C1/p1786500001000000"}],
    "you_owe_covered": 0, "you_owe_closed": []}
seen = wa._ledger_permalinks(led)
print("seen", sorted(seen))
items = [{"what": "he will rerun the job", "ts": "1786500001.000000"},
         {"what": "the cache is the culprit", "ts": "1786500002.000000"}]
kept = wa._drop_seen(items, "C1", seen)
print("kept", [k["what"] for k in kept])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"seen [('C1', '1786500001.000000')]"* ]]
    [[ "$output" == *"kept ['the cache is the culprit']"* ]]
}

@test "the same message written two ways is one message" {
    run wa '
# search writes ?thread_ts= and a trailing cid; conversations.replies has no permalink at
# all, so ours is constructed. Both must reduce to the same message.
searched = ("https://acme.slack.com/archives/C1/p1786500001000000"
            "?thread_ts=1786499000.000000&cid=C1")
built = wa._thread_link("https://acme.slack.com", "C1", "1786500001.000000",
                        "1786499000.000000")
print("built", built)
print("same", wa._perma_id(searched) == wa._perma_id(built))
print("id", wa._perma_id(built))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"same True"* ]]
    [[ "$output" == *"id ('C1', '1786500001.000000')"* ]]
}

@test "a closed commitment still counts as already said" {
    run wa '
led = {"they_owe": [], "you_owe": [], "you_owe_covered": 0, "you_owe_closed": [
    {"kind": "commitment", "url": "https://acme.slack.com/archives/C1/p1786500001000000",
     "closed_url": "https://acme.slack.com/archives/C1/p1786500009000000"}]}
print(sorted(t for _, t in wa._ledger_permalinks(led)))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"1786500001.000000"* ]]
    [[ "$output" == *"1786500009.000000"* ]]
}

@test "a thread whose every item is already a ledger row produces no block at all" {
    run wa '
led = {"they_owe": [], "you_owe": [
    {"kind": "commitment", "url": "https://acme.slack.com/archives/C1/p1786500001000000"}],
    "you_owe_covered": 0, "you_owe_closed": []}
t = thread([msg(1786500001, "I will rerun the job with UB-6802 in")], chan="C1")
wa.headless_claude = FakeHC(
    json.dumps({"decided": [{"what": "he will rerun the job", "i": 0}], "open": []}))
blocks = wa._synthesise_threads([{**t, "arc": "UB-6802", "how": "ticket UB-6802"}], led)
print("blocks", len(blocks))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"blocks 0"* ]]
}

# --- the quote, verbatim -----------------------------------------------------------------

@test "Slack's own escaping is undone before the quote is a quote" {
    # Slack escapes exactly three characters in message text -- & < > -- and _slack_text
    # never undid them, so `A -> B` came back as `A -&gt; B` in the terminal ledger and as
    # `A -&amp;gt; B` on the page, where esc() escaped the ampersand a second time. Found on
    # a real quote: "the sequence of MRs is UL-1637-&gt;UL-1790". Every Slack quote on the
    # page and in the ledger goes through this, so the fix is shared and so is the bug.
    #
    # Order is the whole subtlety. The markup passes read real angle brackets (`<@U1>`,
    # `<url|label>`), so the unescaping has to come after them -- and `&amp;` has to come
    # last, or `&amp;gt;`, which Slack means as the literal text "&gt;", would end up as a
    # bare `>`.
    run wa '
for raw, want in (
        ("the sequence is UL-1637-&gt;UL-1790", "the sequence is UL-1637->UL-1790"),
        ("if a &lt; b &amp;&amp; c", "if a < b && c"),
        ("A &amp;gt; B", "A &gt; B"),
        ("ask <@U0559U5P64F> about <https://x.test/y|the doc>",
         "ask @U0559U5P64F about the doc"),
        ("<https://x.test/plain>", "https://x.test/plain")):
    got = wa._slack_text(raw)
    print(("ok  " if got == want else "BAD "), repr(got))
'
    [ "$status" -eq 0 ]
    [[ "$output" != *"BAD"* ]]
}

# --- what counts as having seen everything ---------------------------------------------

@test "a thread read whole that holds nothing quotable is not an outage" {
    # A thread of attachment-only messages -- an alert, a screenshot with no caption --
    # comes back complete and empty. Counted as unreadable it made `complete` false, and a
    # false `complete` freezes the dismissal prune for every universe on the page, forever:
    # this thread is in the window every day and fails the same way every day. Measured: one
    # such thread in the live window, and it alone was enough.
    run wa '
wa._slack = lambda m, **p: {"ok": True, "user_id": "U1"} if m == "auth.test" else None
wa._slack_sweep = lambda q, pages=4: ([
    {"ts": "1786500001.000000", "text": "hi",
     "permalink": "https://acme.slack.com/archives/C1/p1786500001000000",
     "channel": {"id": "C1", "name": "chan"}},
    {"ts": "1786500002.000000", "text": "hi",
     "permalink": "https://acme.slack.com/archives/C2/p1786500002000000",
     "channel": {"id": "C2", "name": "other"}}], True)
wa._thread_messages = lambda chan, ts: (([], "whole") if chan == "C1"
                                        else ([], "unknown"))
rep = wa.slack_threads([arc("A", branches=["UB-6802-x"])], None)
print("empty-but-whole:", rep["readable"], rep["unreadable"], rep["complete"])
wa._thread_messages = lambda chan, ts: ([], "whole")
rep = wa.slack_threads([arc("A", branches=["UB-6802-x"])], None)
print("both whole:", rep["readable"], rep["unreadable"], rep["complete"])
'
    [ "$status" -eq 0 ]
    # One whole-and-empty, one refused: the refusal alone makes the run incomplete.
    [[ "$output" == *"empty-but-whole: 1 1 False"* ]]
    [[ "$output" == *"both whole: 2 0 True"* ]]
}

@test "a DM is refused before it is asked, and refusal is not incompleteness" {
    run wa '
asked = []
wa._slack = lambda m, **p: {"ok": True, "user_id": "U1"} if m == "auth.test" else None
wa._slack_sweep = lambda q, pages=4: ([
    {"ts": f"178650000{i}.000000", "text": "hi",
     "permalink": f"https://acme.slack.com/archives/{c}/p178650000{i}000000",
     "channel": {"id": c, "name": "x"}}
    for i, c in enumerate(("D1", "D2", "C1"))], True)
def fetch(chan, ts):
    asked.append(chan)
    return [msg(1786500009, "we will use UB-6802 for this")], "whole"
wa._thread_messages = fetch
wa.headless_claude = FakeHC(json.dumps({"decided": [{"what": "d", "i": 0}], "open": []}))
rep = wa.slack_threads([arc("A", branches=["UB-6802-x"])], None)
print("asked", asked)
print("threads", rep["threads"], "denied", rep["denied"], "readable", rep["readable"])
print("complete", rep["complete"], "joined", rep["joined"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"asked ['C1']"* ]]
    [[ "$output" == *"threads 3 denied 2 readable 1"* ]]
    [[ "$output" == *"complete True joined 1"* ]]
}

@test "no Slack token is a complete universe; --no-slack-threads is not" {
    run wa '
import os
os.environ.pop("SLACK_USER_TOKEN", None)
rep = wa.slack_threads([arc("A")], None)
print("no token:", rep["consulted"], rep["complete"], rep["why"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"no token: False True no Slack token"* ]]
}

@test "an unfinished from:me sweep is incomplete even when every thread reads whole" {
    run wa '
wa._slack = lambda m, **p: {"ok": True, "user_id": "U1"} if m == "auth.test" else None
wa._slack_sweep = lambda q, pages=4: ([
    {"ts": "1786500001.000000", "text": "hi",
     "permalink": "https://acme.slack.com/archives/C1/p1786500001000000",
     "channel": {"id": "C1", "name": "chan"}}], False)
wa._thread_messages = lambda chan, ts: ([msg(1786500009, "plain talk")], "whole")
rep = wa.slack_threads([arc("A", branches=["UB-6802-x"])], None)
print("complete", rep["complete"], "|", rep["why"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"complete False | the from:me sweep did not finish"* ]]
}

# --- the synthesis pass ---------------------------------------------------------------

@test "each item carries the quote and permalink of the one message it projects" {
    run wa '
t = thread([msg(1786500001, "shall we drop the array_has calls?", user="U9"),
            msg(1786500002, "yes, UB-6802 removes them all", user="U2")], chan="C1")
wa.headless_claude = FakeHC(json.dumps(
    {"decided": [{"what": "array_has calls are being removed", "i": 1}],
     "open": [{"what": "nobody has measured the query cost", "i": 0}]}))
b = wa._synthesise_threads([{**t, "arc": "UB-6802", "how": "ticket UB-6802"}], None)[0]
d, o = b["decided"][0], b["open"][0]
print("d", d["what"], "|", d["quote"], "|", d["url"])
print("o", o["quote"])
print("fp", bool(b["fp"]), "chan", b["chan"], "n", b["messages"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"d array_has calls are being removed | yes, UB-6802 removes them all | https://acme.slack.com/archives/C1/p1786500002000000?thread_ts=1786500001.000000"* ]]
    [[ "$output" == *"o shall we drop the array_has calls?"* ]]
    [[ "$output" == *"fp True chan C1 n 2"* ]]
}

@test "an item pointing at no message in the thread is dropped, not rendered bare" {
    run wa '
t = thread([msg(1786500001, "one message only")], chan="C1")
wa.headless_claude = FakeHC(json.dumps(
    {"decided": [{"what": "invented", "i": 7}, {"what": "real", "i": 0}], "open": []}))
b = wa._synthesise_threads([{**t, "arc": "A", "how": "ticket A-1"}], None)
print("items", [d["what"] for d in b[0]["decided"]])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"items ['real']"* ]]
}

@test "a failed model call caches nothing and shows nothing" {
    run wa '
import pathlib
t = thread([msg(1786500001, "something was decided here")], chan="C1")
wa.headless_claude = FakeHC("", rc=1)
print("blocks", len(wa._synthesise_threads([{**t, "arc": "A", "how": "ticket A-1"}], None)))
p = wa.SLACK_THREAD_CACHE
print("cached", json.loads(p.read_text())["verdicts"] if p.exists() else "no file")
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"blocks 0"* ]]
    [[ "$output" == *"cached"* ]]
    [[ "$output" != *"cached {'"* ]]
}

@test "a second run over the same thread makes no model call" {
    run wa '
t = thread([msg(1786500001, "yes, lets do that"), msg(1786500002, "ok")], chan="C1")
item = {**t, "arc": "A", "how": "ticket A-1"}
hc = FakeHC(json.dumps({"decided": [{"what": "they agreed", "i": 0}], "open": []}))
wa.headless_claude = hc
print("first", len(wa._synthesise_threads([item], None)), "calls", len(hc.prompts))
hc2 = FakeHC("SHOULD NOT BE CALLED")
wa.headless_claude = hc2
print("second", len(wa._synthesise_threads([item], None)), "calls", len(hc2.prompts))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"first 1 calls 1"* ]]
    [[ "$output" == *"second 1 calls 0"* ]]
}

@test "a new message in the thread is a new question and a new fingerprint" {
    run wa '
first = thread([msg(1786500001, "yes, lets do that")], chan="C1")
hc = FakeHC(json.dumps({"decided": [{"what": "they agreed", "i": 0}], "open": []}))
wa.headless_claude = hc
a = wa._synthesise_threads([{**first, "arc": "A", "how": "ticket A-1"}], None)[0]
grown = thread([msg(1786500001, "yes, lets do that"),
                msg(1786500009, "actually no, hold off")], chan="C1")
hc2 = FakeHC(json.dumps({"decided": [{"what": "they held off", "i": 1}], "open": []}))
wa.headless_claude = hc2
b = wa._synthesise_threads([{**grown, "arc": "A", "how": "ticket A-1"}], None)[0]
print("recalled", len(hc2.prompts))
print("fp moved", a["fp"] != b["fp"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"recalled 1"* ]]
    [[ "$output" == *"fp moved True"* ]]
}

@test "a reworded prompt does not reuse yesterdays answers" {
    run wa '
t = thread([msg(1786500001, "yes, lets do that")], chan="C1")
item = {**t, "arc": "A", "how": "ticket A-1"}
hc = FakeHC(json.dumps({"decided": [{"what": "they agreed", "i": 0}], "open": []}))
wa.headless_claude = hc
wa._synthesise_threads([item], None)
wa.SLACK_THREAD_PROMPT = wa.SLACK_THREAD_PROMPT + "\nAnd one more rule.\n"
hc2 = FakeHC(json.dumps({"decided": [{"what": "they agreed", "i": 0}], "open": []}))
wa.headless_claude = hc2
wa._synthesise_threads([item], None)
print("asked again", len(hc2.prompts))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"asked again 1"* ]]
}

@test "a thread that decided nothing produces nothing" {
    run wa '
t = thread([msg(1786500001, "morning all"), msg(1786500002, "thanks!")], chan="C1")
wa.headless_claude = FakeHC(json.dumps({"decided": [], "open": []}))
print("blocks", len(wa._synthesise_threads([{**t, "arc": "A", "how": "ticket A-1"}], None)))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"blocks 0"* ]]
}

@test "at most two of each survive, however many the model returns" {
    run wa '
t = thread([msg(1786500001 + i, f"m{i}") for i in range(6)], chan="C1")
wa.headless_claude = FakeHC(json.dumps(
    {"decided": [{"what": f"d{i}", "i": i} for i in range(4)],
     "open": [{"what": f"o{i}", "i": i} for i in range(3)]}))
b = wa._synthesise_threads([{**t, "arc": "A", "how": "ticket A-1"}], None)[0]
print("d", len(b["decided"]), "o", len(b["open"]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"d 2 o 2"* ]]
}

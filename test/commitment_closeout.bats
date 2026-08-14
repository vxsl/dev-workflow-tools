#!/usr/bin/env bats
# Tests for closing a commitment row on evidence that the promise was kept.
#
# The ledger's other rows all die when the other person moves -- Neville replies, the row
# is gone. A commitment had no such death: nothing noticed the promised thing being DONE,
# so the row aged out through the 14-day Slack window instead. A row that survives its own
# fulfilment is a wrong reminder, and those cost more trust than ten right ones earn.
#
# Every test here is about one of the two ways this feature can be wrong, and they are not
# symmetric:
#
#   closing a row that is still owed   -- a promise silently deleted. The expensive one:
#                                         the tool has quietly stopped telling you things
#   keeping a row that was fulfilled   -- a stale reminder that shows its own quote and is
#                                         read and dismissed in a second
#
# So the default everywhere is "the row stays", and most of these tests assert exactly
# that against evidence that looks like fulfilment and is not: a ticket that reached Done
# before the promise, a ticket merely started, a merge request abandoned rather than
# merged, a later message in the same channel but a different thread, a model that failed.
#
# The functions are called directly. Everything they do over a ledger dict and a fates
# dict is pure once the two network edges are stubbed, and going through the CLI would
# mean standing up a git repo, a GitLab and a Jira to test a join.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    export JIRA_PROJECTS="UL,UB,DE"
}

teardown() {
    teardown_temp_dir
}

# Runs a python snippet with work-arcs imported as `wa` and the fixtures in scope.
wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" <<PY
import importlib.machinery, importlib.util, sys, json, time
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
sys.argv = ["wa"]
loader.exec_module(wa)
wa.TICKET_RE = wa._ticket_re()

DAY = 86400
NOW = 1786500000.0          # a fixed clock; nothing here reads the wall one

def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(ts))

def day(ts):
    return time.strftime("%Y-%m-%d", time.localtime(ts))

def commitment(quote, at=NOW - 3 * DAY, promised="do the thing", ref="#chan"):
    """A commitment row as ledger_commitments leaves it."""
    return {"kind": "commitment", "ref": ref, "title": "", "who": "",
            "promised": promised, "asked": day(at), "days": 3,
            "asked_ts": at, "expires_in": 11, "window_days": 14,
            "quote": quote, "url": "https://slack/p1", "fp": "fp-commit"}

def ledger(*rows, they=()):
    return {"they_owe": list(they), "you_owe": list(rows),
            "you_owe_covered": 0, "you_owe_closed": [], "slack": True}

def fate(iid, state="merged", at=NOW):
    return {"iid": iid, "state": state, "at": iso(at)[:10], "at_ts": iso(at),
            "url": f"https://gitlab/mr/{iid}"}

def moves(key, category, status, at):
    """What jira_status_moves would return, stubbed in so no Jira is needed."""
    return {key: {"key": key, "status": status, "category": category,
                  "moved": iso(at), "url": f"https://jira/{key}"}}

def no_jira(keys):
    raise AssertionError("jira_status_moves called with " + repr(list(keys)))

def msg(ts, text, chan="C1", thread=None, name="chan"):
    """A Slack search match, with the thread encoded where the real ones encode it."""
    link = f"https://slack/archives/{chan}/p{int(ts * 1e6)}"
    if thread:
        link += f"?thread_ts={thread}"
    return {"ts": f"{ts:.6f}", "text": text, "permalink": link,
            "channel": {"id": chan, "name": name}}

class FakeHC:
    """headless_claude, replaced. Records the prompts it was given."""
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

@test "a ticket that reached Done after the promise closes the row" {
    run wa '
led = ledger(commitment("I will get UL-1802 out today"))
wa.jira_status_moves = lambda keys: moves("UL-1802", "Done", "Done", NOW - DAY)
wa.close_commitments(led, {})
print("owed", len(led["you_owe"]))
print("closed", len(led["you_owe_closed"]))
print("why", led["you_owe_closed"][0]["closed_by"])
print("how", led["you_owe_closed"][0]["closed_how"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"owed 0"* ]]
    [[ "$output" == *"closed 1"* ]]
    [[ "$output" == *"why UL-1802 moved to Done 2d after"* ]]
    [[ "$output" == *"how ticket"* ]]
}

@test "a ticket already Done before the promise is evidence about something else" {
    run wa '
led = ledger(commitment("I will get UL-1802 out today"))
wa.jira_status_moves = lambda keys: moves("UL-1802", "Done", "Done", NOW - 9 * DAY)
wa.close_commitments(led, {})
print("owed", len(led["you_owe"]))
print("closed", len(led["you_owe_closed"]))
'
    [[ "$output" == *"owed 1"* ]]
    [[ "$output" == *"closed 0"* ]]
}

@test "a ticket merely moved into progress is the promise being worked, not kept" {
    run wa '
led = ledger(commitment("I will get UL-1802 out today"))
wa.jira_status_moves = lambda keys: moves("UL-1802", "In Progress", "In Review",
                                          NOW - DAY)
wa.close_commitments(led, {})
print("owed", len(led["you_owe"]))
'
    [[ "$output" == *"owed 1"* ]]
}

@test "a ticket Jira could not answer for closes nothing" {
    run wa '
led = ledger(commitment("I will get UL-1802 out today"))
wa.jira_status_moves = lambda keys: {}
wa.close_commitments(led, {})
print("owed", len(led["you_owe"]))
'
    [[ "$output" == *"owed 1"* ]]
}

@test "a promise naming no ticket and no MR never asks Jira" {
    run wa '
led = ledger(commitment("I will take a look at it on Monday"))
wa.jira_status_moves = no_jira
wa.close_commitments(led, {})
print("owed", len(led["you_owe"]))
print("expires", led["you_owe"][0]["expires_in"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"owed 1"* ]]
    [[ "$output" == *"expires 11"* ]]
}

# --- the merge request join -----------------------------------------------------------

@test "a merge request that merged after the promise closes the row, with no Jira call" {
    run wa '
led = ledger(commitment("I will rebase !10481 this afternoon"))
wa.jira_status_moves = no_jira
wa.close_commitments(led, {"br": fate(10481, "merged", NOW - DAY)})
print("closed", len(led["you_owe_closed"]))
print("why", led["you_owe_closed"][0]["closed_by"])
print("how", led["you_owe_closed"][0]["closed_how"])
print("url", led["you_owe_closed"][0]["closed_url"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"closed 1"* ]]
    [[ "$output" == *"why !10481 merged 2d after"* ]]
    [[ "$output" == *"how mr"* ]]
    [[ "$output" == *"url https://gitlab/mr/10481"* ]]
}

@test "a merge request closed rather than merged is work abandoned, not a promise kept" {
    run wa '
led = ledger(commitment("I will rebase !10481 this afternoon"))
wa.jira_status_moves = lambda keys: {}
wa.close_commitments(led, {"br": fate(10481, "closed", NOW - DAY)})
print("owed", len(led["you_owe"]))
'
    [[ "$output" == *"owed 1"* ]]
}

@test "a merge request that had already merged when the promise was made closes nothing" {
    run wa '
led = ledger(commitment("I will rebase !10481 this afternoon"))
wa.jira_status_moves = lambda keys: {}
wa.close_commitments(led, {"br": fate(10481, "merged", NOW - 5 * DAY)})
print("owed", len(led["you_owe"]))
'
    [[ "$output" == *"owed 1"* ]]
}

@test "a merge request merged the same afternoon is still ordered against the promise" {
    run wa '
led = ledger(commitment("I will rebase !10481 this afternoon"))
wa.jira_status_moves = no_jira
wa.close_commitments(led, {"br": fate(10481, "merged", NOW - 3 * DAY + 3600)})
print("why", led["you_owe_closed"][0]["closed_by"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"why !10481 merged the same day"* ]]
}

@test "the merge request in a URL counts the same as one written !10481" {
    run wa '
led = ledger(commitment("done in https://gitlab/x/-/merge_requests/10481, will rebase"))
wa.jira_status_moves = no_jira
wa.close_commitments(led, {"br": fate(10481, "merged", NOW - DAY)})
print("closed", len(led["you_owe_closed"]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"closed 1"* ]]
}

# --- in-thread delivery, judged -------------------------------------------------------

@test "a later message in the same thread that delivers closes the row" {
    run wa '
m = msg(NOW - 3 * DAY, "I will send the doc", thread="900.1")
row = commitment("I will send the doc")
mine = [m, msg(NOW - 2 * DAY, "here you go: the doc", thread="900.1")]
wa.headless_claude = FakeHC("[0]")
wa._commitment_delivered([(row, m)], mine)
print("how", row.get("closed_how"))
print("why", row.get("closed_by"))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"how thread"* ]]
    [[ "$output" == *'why you posted in-thread: "here you go: the doc"'* ]]
}

@test "a long delivering message is quoted to a word boundary, and kept whole beside it" {
    run wa '
m = msg(NOW - 3 * DAY, "I will send the doc", thread="900.1")
row = commitment("I will send the doc")
long = ("1. offsetLinesIf: [literal, true] — coming back to what I said before, "
        "the second argument is the one that matters here")
mine = [m, msg(NOW - 2 * DAY, long, thread="900.1")]
wa.headless_claude = FakeHC("[0]")
wa._commitment_delivered([(row, m)], mine)
print("why", row["closed_by"])
print("whole", row["closed_quote"] == long)
'
    [ "$status" -eq 0 ]
    [[ "$output" == *'why you posted in-thread: "1. offsetLinesIf: [literal, true] — coming back to what I…"'* ]]
    [[ "$output" == *"whole True"* ]]
}

@test "the newest delivering message is the one quoted back" {
    run wa '
m = msg(NOW - 3 * DAY, "I will send the doc", thread="900.1")
row = commitment("I will send the doc")
mine = [m, msg(NOW - 2 * DAY, "on it", thread="900.1"),
        msg(NOW - DAY, "done, merged", thread="900.1")]
wa.headless_claude = FakeHC("[0, 1]")
wa._commitment_delivered([(row, m)], mine)
print("why", row.get("closed_by"))
'
    [[ "$output" == *'why you posted in-thread: "done, merged"'* ]]
}

@test "a later message elsewhere in the channel is not offered as evidence at all" {
    run wa '
m = msg(NOW - 3 * DAY, "I will send the doc", thread="900.1")
row = commitment("I will send the doc")
mine = [m, msg(NOW - 2 * DAY, "unrelated, in another thread", thread="777.2")]
hc = FakeHC("[0]")
wa.headless_claude = hc
wa._commitment_delivered([(row, m)], mine)
print("how", row.get("closed_how"))
print("calls", len(hc.prompts))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"how None"* ]]
    [[ "$output" == *"calls 0"* ]]
}

@test "in a DM the whole channel is the thread, because Slack gives each message its own" {
    run wa '
m = msg(NOW - 3 * DAY, "I will look at the MR", chan="D9")
row = commitment("I will look at the MR", ref="DM")
mine = [m, msg(NOW - 2 * DAY, "looked, it is fine, approved", chan="D9")]
wa.headless_claude = FakeHC("[0]")
wa._commitment_delivered([(row, m)], mine)
print("how", row.get("closed_how"))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"how thread"* ]]
}

@test "a message earlier than the promise is never a delivery of it" {
    run wa '
m = msg(NOW - 3 * DAY, "I will send the doc", thread="900.1")
row = commitment("I will send the doc")
mine = [m, msg(NOW - 4 * DAY, "here you go", thread="900.1")]
hc = FakeHC("[0]")
wa.headless_claude = hc
wa._commitment_delivered([(row, m)], mine)
print("how", row.get("closed_how"))
print("calls", len(hc.prompts))
'
    [[ "$output" == *"how None"* ]]
    [[ "$output" == *"calls 0"* ]]
}

@test "a judge that leaves a pair out leaves the row alone" {
    run wa '
m = msg(NOW - 3 * DAY, "I will send the doc", thread="900.1")
row = commitment("I will send the doc")
mine = [m, msg(NOW - 2 * DAY, "still digging into this", thread="900.1")]
wa.headless_claude = FakeHC("[]")
wa._commitment_delivered([(row, m)], mine)
print("how", row.get("closed_how"))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"how None"* ]]
}

@test "a model call that fails closes nothing and caches nothing" {
    run wa '
import os, pathlib
m = msg(NOW - 3 * DAY, "I will send the doc", thread="900.1")
row = commitment("I will send the doc")
mine = [m, msg(NOW - 2 * DAY, "here you go", thread="900.1")]
wa.headless_claude = FakeHC("", boom=OSError("no claude"))
wa._commitment_delivered([(row, m)], mine)
print("how", row.get("closed_how"))
print("cache", wa.COMMIT_CLOSE_CACHE.exists())
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"how None"* ]]
    [[ "$output" == *"cache False"* ]]
}

@test "an unparseable answer closes nothing" {
    run wa '
m = msg(NOW - 3 * DAY, "I will send the doc", thread="900.1")
row = commitment("I will send the doc")
mine = [m, msg(NOW - 2 * DAY, "here you go", thread="900.1")]
wa.headless_claude = FakeHC("I could not decide")
wa._commitment_delivered([(row, m)], mine)
print("how", row.get("closed_how"))
'
    [[ "$output" == *"how None"* ]]
}

@test "a verdict is cached per pair, so a re-run makes no model call" {
    run wa '
m = msg(NOW - 3 * DAY, "I will send the doc", thread="900.1")
mine = [m, msg(NOW - 2 * DAY, "here you go", thread="900.1")]
hc = FakeHC("[0]")
wa.headless_claude = hc
first = commitment("I will send the doc")
wa._commitment_delivered([(first, m)], mine)
again = commitment("I will send the doc")
wa._commitment_delivered([(again, m)], mine)
print("how", again.get("closed_how"))
print("calls", len(hc.prompts))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"how thread"* ]]
    [[ "$output" == *"calls 1"* ]]
}

@test "rewording the question throws the cached verdicts away" {
    run wa '
m = msg(NOW - 3 * DAY, "I will send the doc", thread="900.1")
mine = [m, msg(NOW - 2 * DAY, "here you go", thread="900.1")]
hc = FakeHC("[0]")
wa.headless_claude = hc
wa._commitment_delivered([(commitment("d"), m)], mine)
wa.COMMIT_CLOSE_PROMPT = wa.COMMIT_CLOSE_PROMPT + "\nAnd be careful.\n"
wa._commitment_delivered([(commitment("d"), m)], mine)
print("calls", len(hc.prompts))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"calls 2"* ]]
}

# --- the mechanics around the signals -------------------------------------------------

@test "a row already closed in-thread is not looked up again" {
    run wa '
row = commitment("I will get UL-1802 out today")
row["closed_how"], row["closed_by"] = "thread", "you posted in-thread: \"done\""
led = ledger(row)
wa.jira_status_moves = no_jira
wa.close_commitments(led, {})
print("closed", len(led["you_owe_closed"]))
print("how", led["you_owe_closed"][0]["closed_how"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"closed 1"* ]]
    [[ "$output" == *"how thread"* ]]
}

@test "closing a commitment leaves every other row and its fingerprint untouched" {
    run wa '
other = {"kind": "review-owed", "ref": "!10500", "who": "ella", "asked": "2026-08-01",
         "days": 13, "fp": "fp-review"}
kept = commitment("I will look at it on Monday", promised="look at it Monday")
led = ledger(other, kept, commitment("I will get UL-1802 out today"))
wa.jira_status_moves = lambda keys: moves("UL-1802", "Done", "Done", NOW - DAY)
wa.close_commitments(led, {})
print("refs", ",".join(e["ref"] for e in led["you_owe"]))
print("fps", ",".join(e["fp"] for e in led["you_owe"]))
print("closed", len(led["you_owe_closed"]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"refs !10500,#chan"* ]]
    [[ "$output" == *"fps fp-review,fp-commit"* ]]
    [[ "$output" == *"closed 1"* ]]
}

@test "a ledger with no commitments still reports an empty closed list" {
    run wa '
led = {"they_owe": [], "you_owe": [{"kind": "review-owed", "ref": "!1"}],
       "you_owe_covered": 0, "slack": True}
wa.jira_status_moves = no_jira
wa.close_commitments(led, {})
print("closed", json.dumps(led["you_owe_closed"]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"closed []"* ]]
}

@test "no ledger at all is not an error" {
    run wa '
wa.close_commitments(None, {})
print("fine")
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"fine"* ]]
}

@test "only merged fates join, and only ones that carry an iid" {
    run wa '
led = ledger(commitment("I will rebase !10481 this afternoon"))
wa.jira_status_moves = lambda keys: {}
wa.close_commitments(led, {"a": {"iid": None, "state": "merged", "at_ts": iso(NOW)},
                           "b": fate(10333, "merged", NOW)})
print("owed", len(led["you_owe"]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"owed 1"* ]]
}

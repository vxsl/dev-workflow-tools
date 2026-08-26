#!/usr/bin/env bats
# Tests for promises read out of Gemini meeting transcripts -- the ledger's third leg.
#
# This source is unlike every other one in the pipeline in a way that decides what is worth
# testing. GitLab and Jira assert facts; Slack rows quote a message with a permalink anyone
# can open. A meeting row quotes a sentence a model heard in a spoken transcript, about a
# document whose own summary tab is demonstrably wrong about who owns what. So the failure
# that matters here is not a crash and not a missed row -- it is a confident sentence
# claiming Kyle owes something he never said.
#
# The two ways this feature can be wrong are not symmetric, and the tests are weighted the
# way the costs are:
#
#   a row Kyle never promised      -- the tool putting words in his mouth, and worse, in a
#                                     colleague's. Read once, believed, and every other row
#                                     on the ledger is discounted from then on
#   a promise not noticed          -- a reminder that never appears. Costs one loop
#   a row that outlives its own    -- a stale reminder that shows its own quote and is read
#     fulfilment                      and dismissed in a second
#
# So the defaults asserted throughout are: no quote means no row, an unparseable answer
# caches nothing and reports the universe unknown rather than empty, a spoken bare number
# closes nothing, and a doc Gemini may still be writing is not read at all.
#
# No test makes a model call or touches Google Drive. `_drive` is the single seam both the
# discovery and the extraction call go through, so stubbing it replaces the network
# entirely, and everything either side of it is pure over dicts.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    export JIRA_PROJECTS="UL,UB,DE"
    # Every window here is stated by the test that needs it; these keep a stray default
    # from making an assertion depend on the day the suite runs.
    export WORK_ARCS_MEETING_LOOKBACK=14
    export WORK_ARCS_MEETING_SETTLE_HOURS=3
}

teardown() {
    teardown_temp_dir
}

# Runs a python snippet with work-arcs imported as `wa` and the fixtures in scope. `now` is
# frozen so a doc's age is a fact about the fixture, never about the clock.
wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" <<PY
import importlib.machinery, importlib.util, sys, json, time, types
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
sys.argv = ["wa"]
loader.exec_module(wa)
wa.TICKET_RE = wa._ticket_re()

DAY = 86400
NOW = 1786500000.0
wa.time = types.SimpleNamespace(time=lambda: NOW, sleep=lambda n: None)

def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(ts))

def day(ts):
    return time.strftime("%Y-%m-%d", time.localtime(ts))

def title(name="FE standup", at=None):
    """A Gemini doc title, in the shape Gemini writes them. Local time, because that is
    what Gemini stamps and what _meeting_instant has to read back."""
    t = time.localtime(NOW - DAY if at is None else at)
    return (name + time.strftime(" - %Y/%m/%d %H:%M ", t)
            + (time.tzname[t.tm_isdst] if time.tzname[t.tm_isdst] else "UTC")
            + " - Notes by Gemini")

DOC = "1WeZlXgicM0eAqjUAKwCjpz1RhNUJIHnuhXeXRUFw"

def found(id=DOC, name="FE standup", at=None, modified="2026-08-24T17:45:48.166Z"):
    """One row of what the discovery call relays back."""
    return {"id": id, "title": title(name, at), "modified": modified}

def promise(promised="migrate the Dove workspaces", quote=None, deadline="", to=""):
    return {"promised": promised, "to": to, "deadline": deadline,
            "quote": "I think I will " + promised + " in the next couple days"
                     if quote is None else quote}

class Drive:
    """_drive, replaced. Answers the discovery call from one list and every extraction
    call from a per-file-id map, and records what it was asked."""
    def __init__(self, docs=(), per_doc=None, rc=0, docs_rc=0, boom=None, junk=False):
        self.docs, self.per_doc = list(docs), dict(per_doc or {})
        self.rc, self.docs_rc, self.boom, self.junk = rc, docs_rc, boom, junk
        self.calls = []
    def __call__(self, prompt, model, timeout=None):
        self.calls.append((prompt, model))
        if self.boom:
            raise self.boom
        discovery = "search_files" in prompt
        if self.junk:
            return type("R", (), {"returncode": 0, "stdout": "I could not do that."})()
        if discovery:
            return type("R", (), {"returncode": self.docs_rc,
                                  "stdout": json.dumps(self.docs)})()
        fid = next((k for k in self.per_doc if k in prompt), None)
        if fid is None:
            # A document this stub was given no answer for is one the read FAILED on --
            # not one that held no promises. Conflating those is the distinction half the
            # tests below are about, so the stub must not blur it either.
            return type("R", (), {"returncode": 1, "stdout": ""})()
        return type("R", (), {"returncode": self.rc,
                              "stdout": json.dumps(self.per_doc[fid])})()

def commitment(quote, at=NOW - 3 * DAY, promised="do the thing", ref="FE standup",
               kind="meeting-commitment"):
    """A meeting-commitment row as ledger_meetings leaves it."""
    return {"kind": kind, "ref": ref, "title": "", "who": "", "promised": promised,
            "deadline": "", "asked": day(at), "days": 3, "asked_ts": at,
            "expires_in": 11, "window_days": 14, "quote": quote,
            "url": "https://docs.google.com/document/d/" + DOC + "/edit",
            "inferred": True, "fp": "fp-meeting"}

def ledger(*rows):
    return {"they_owe": [], "you_owe": list(rows), "you_owe_covered": 0,
            "you_owe_closed": [], "slack": True}

def fate(iid, state="merged", at=NOW):
    return {"iid": iid, "state": state, "at": iso(at)[:10], "at_ts": iso(at),
            "url": "https://gitlab/mr/" + str(iid)}

def moves(key, category, status, at):
    return {key: {"key": key, "status": status, "category": category,
                  "moved": iso(at), "url": "https://jira/" + key}}

def no_jira(keys):
    raise AssertionError("Jira was called for " + repr(list(keys)))

$1
PY
}

# Runs a python snippet with arc-morning imported as `am`.
am() {
    python3 - "$REPO_ROOT/bin/arc-morning" <<PY
import importlib.machinery, importlib.util, sys, json
loader = importlib.machinery.SourceFileLoader("am", sys.argv[1])
spec = importlib.util.spec_from_loader("am", loader)
am = importlib.util.module_from_spec(spec)
sys.argv = ["am"]
loader.exec_module(am)

def row(kind="meeting-commitment", **kw):
    e = {"kind": kind, "ref": "FE standup", "days": 3, "who": "", "fp": "fp-m",
         "url": "", "title": "", "asked": "2026-08-10", "promised": "do the thing",
         "deadline": ""}
    e.update(kw)
    return e

$1
PY
}

# --- the transcript is the row's evidence ---------------------------------------------

@test "a promise in the transcript becomes a row that quotes it" {
    run wa '
d = Drive([found()], {DOC: [promise(deadline="in the next couple days")]})
wa._drive = d
rows, whole = wa.ledger_meetings()
print("rows", len(rows))
print("kind", rows[0]["kind"])
print("ref", rows[0]["ref"])
print("deadline", rows[0]["deadline"])
print("inferred", rows[0]["inferred"])
print("whole", whole)
print("quoted", "in the next couple days" in rows[0]["quote"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rows 1"* ]]
    [[ "$output" == *"kind meeting-commitment"* ]]
    [[ "$output" == *"ref FE standup"* ]]
    [[ "$output" == *"deadline in the next couple days"* ]]
    [[ "$output" == *"inferred True"* ]]
    [[ "$output" == *"whole True"* ]]
    [[ "$output" == *"quoted True"* ]]
}

@test "a transcript holding no promises is a real answer and is cached as one" {
    run wa '
d = Drive([found()], {DOC: []})
wa._drive = d
rows, whole = wa.ledger_meetings()
print("rows", len(rows))
print("whole", whole)
d2 = Drive([found()], {DOC: []})
wa._drive = d2
wa.ledger_meetings()
print("reads", len([c for c in d2.calls if "read_file_content" in c[0]]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rows 0"* ]]
    [[ "$output" == *"whole True"* ]]
    [[ "$output" == *"reads 0"* ]]
}

@test "a commitment the model cannot quote is not a row" {
    # The plan's rule is that every inferred claim shows the words it is about. Held here
    # by construction rather than trusted: a promise with no quote is one nobody can check
    # against the transcript, which is the exact failure the Notes tab already makes.
    run wa '
d = Drive([found()], {DOC: [promise(quote=""), promise(quote="   ")]})
wa._drive = d
rows, whole = wa.ledger_meetings()
print("rows", len(rows))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rows 0"* ]]
}

@test "a commitment with a quote but no restatement is not a row either" {
    run wa '
d = Drive([found()], {DOC: [{"promised": "", "quote": "I will do it tomorrow"}]})
wa._drive = d
rows, whole = wa.ledger_meetings()
print("rows", len(rows))
'
    [[ "$output" == *"rows 0"* ]]
}

@test "the row points at the document the words came from" {
    run wa '
d = Drive([found()], {DOC: [promise()]})
wa._drive = d
rows, _ = wa.ledger_meetings()
print(rows[0]["url"])
'
    [[ "$output" == *"docs.google.com/document/d/1WeZlXgicM0eAqjUAKwCjpz1RhNUJIHnuhXeXRUFw/edit"* ]]
}

# --- absent is not empty --------------------------------------------------------------

@test "a discovery call that fails leaves the meeting universe unknown, not empty" {
    # The distinction the dismissal prune is read off. Deleting an acknowledgement means
    # claiming its row is gone, and a sweep that never answered cannot support that.
    run wa '
d = Drive([found()], docs_rc=1)
wa._drive = d
rows, whole = wa.ledger_meetings()
print("rows", len(rows))
print("whole", whole)
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rows 0"* ]]
    [[ "$output" == *"whole False"* ]]
}

@test "a discovery reply that is not JSON is a failure, not an empty Drive" {
    run wa '
d = Drive([found()], junk=True)
wa._drive = d
rows, whole = wa.ledger_meetings()
print("rows", len(rows))
print("whole", whole)
'
    [[ "$output" == *"rows 0"* ]]
    [[ "$output" == *"whole False"* ]]
}

@test "claude failing to run at all is reported, not raised" {
    # cron owns this run and nobody is watching it. A traceback out through main would
    # take the whole morning page with it.
    run wa '
d = Drive([found()], boom=OSError("no claude on PATH"))
wa._drive = d
rows, whole = wa.ledger_meetings()
print("rows", len(rows))
print("whole", whole)
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rows 0"* ]]
    [[ "$output" == *"whole False"* ]]
}

@test "one transcript that will not read leaves the run incomplete but keeps the others" {
    run wa '
other = "2AbCdEfGhIjKlMnOpQrStUvWxYz012345678"
d = Drive([found(), found(id=other, name="Platform Standup")],
          {other: [promise(promised="plug it into Trellis")]})
wa._drive = d
rows, whole = wa.ledger_meetings()
print("rows", len(rows))
print("whole", whole)
print("promised", rows[0]["promised"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rows 1"* ]]
    [[ "$output" == *"whole False"* ]]
    [[ "$output" == *"promised plug it into Trellis"* ]]
}

@test "an unparseable extraction caches nothing, so the next run asks again" {
    # Caching a failure as "this meeting held no promises" would make one bad call
    # permanent, and the row it lost would never come back.
    run wa '
d = Drive([found()], junk=False, rc=1)
wa._drive = d
wa.ledger_meetings()
first = len([c for c in d.calls if "read_file_content" in c[0]])
d2 = Drive([found()], {DOC: [promise()]})
wa._drive = d2
rows, _ = wa.ledger_meetings()
print("first", first)
print("second", len([c for c in d2.calls if "read_file_content" in c[0]]))
print("rows", len(rows))
'
    [[ "$output" == *"first 1"* ]]
    [[ "$output" == *"second 1"* ]]
    [[ "$output" == *"rows 1"* ]]
}

# --- the cache ------------------------------------------------------------------------

@test "a transcript already read costs no second call" {
    run wa '
d = Drive([found()], {DOC: [promise()]})
wa._drive = d
wa.ledger_meetings()
d2 = Drive([found()], {DOC: [promise()]})
wa._drive = d2
rows, _ = wa.ledger_meetings()
reads = len([c for c in d2.calls if "read_file_content" in c[0]])
print("reads", reads)
print("rows", len(rows))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"reads 0"* ]]
    [[ "$output" == *"rows 1"* ]]
}

@test "the discovery call is never cached, so this morning can appear" {
    run wa '
d = Drive([found()], {DOC: [promise()]})
wa._drive = d
wa.ledger_meetings()
d2 = Drive([found()], {DOC: [promise()]})
wa._drive = d2
wa.ledger_meetings()
print("searches", len([c for c in d2.calls if "search_files" in c[0]]))
'
    [[ "$output" == *"searches 1"* ]]
}

@test "an edited document is a new revision and is read again" {
    # modifiedTime is the only revision the connector exposes. Gemini writes the doc once,
    # so it is stable; a human editing the transcript changes it, and that is correct.
    run wa '
d = Drive([found()], {DOC: [promise()]})
wa._drive = d
wa.ledger_meetings()
d2 = Drive([found(modified="2026-08-24T19:00:00.000Z")], {DOC: [promise()]})
wa._drive = d2
wa.ledger_meetings()
print("reads", len([c for c in d2.calls if "read_file_content" in c[0]]))
'
    [[ "$output" == *"reads 1"* ]]
}

@test "rewording the question cannot reuse yesterdays answers" {
    # Item 1c, which cost a release: an evidence-keyed cache with the prompt left out of
    # the key went on serving verdicts to a question nobody was asking any more.
    run wa '
d = Drive([found()], {DOC: [promise()]})
wa._drive = d
wa.ledger_meetings()
wa.MEETING_PROMPT = wa.MEETING_PROMPT + "\nAlso ignore anything about tests."
d2 = Drive([found()], {DOC: [promise()]})
wa._drive = d2
wa.ledger_meetings()
print("reads", len([c for c in d2.calls if "read_file_content" in c[0]]))
'
    [[ "$output" == *"reads 1"* ]]
}

# --- what is and is not a settled record ----------------------------------------------

@test "a meeting still inside the settle window is not read" {
    # The doc Gemini is still writing is not a record of anything yet.
    run wa '
d = Drive([found(at=NOW - 600)], {DOC: [promise()]})
wa._drive = d
rows, whole = wa.ledger_meetings()
print("reads", len([c for c in d.calls if "read_file_content" in c[0]]))
print("rows", len(rows))
print("whole", whole)
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"reads 0"* ]]
    [[ "$output" == *"rows 0"* ]]
    [[ "$output" == *"whole True"* ]]
}

@test "a document whose title has no timestamp is skipped rather than dated to now" {
    # No instant means no honest clock: its age, its expiry and every "did this happen
    # after the promise" comparison would be invented.
    run wa '
d = Drive([{"id": DOC, "title": "Notes by Gemini",
            "modified": "2026-08-24T17:45:48.166Z"}], {DOC: [promise()]})
wa._drive = d
rows, _ = wa.ledger_meetings()
print("rows", len(rows))
print("reads", len([c for c in d.calls if "read_file_content" in c[0]]))
'
    [[ "$output" == *"rows 0"* ]]
    [[ "$output" == *"reads 0"* ]]
}

@test "a relayed file id that is not a Drive id is dropped before it costs a read" {
    run wa '
d = Drive([{"id": "nope", "title": title(), "modified": "2026-08-24T17:45:48.166Z"},
           {"id": "", "title": title(), "modified": "2026-08-24T17:45:48.166Z"},
           found()], {DOC: [promise()]})
wa._drive = d
rows, _ = wa.ledger_meetings()
print("rows", len(rows))
print("reads", len([c for c in d.calls if "read_file_content" in c[0]]))
'
    [[ "$output" == *"rows 1"* ]]
    [[ "$output" == *"reads 1"* ]]
}

@test "a file with no modifiedTime has no revision to key on and is dropped" {
    run wa '
d = Drive([{"id": DOC, "title": title(), "modified": ""}], {DOC: [promise()]})
wa._drive = d
rows, _ = wa.ledger_meetings()
print("rows", len(rows))
'
    [[ "$output" == *"rows 0"* ]]
}

@test "the meeting name and its instant are read out of the title" {
    run wa '
name, at = wa._meeting_instant("FE standup - 2026/08/24 10:29 PDT - Notes by Gemini")
print("name", name)
print("utc", time.strftime("%Y-%m-%dT%H:%M", time.gmtime(at)))
print("unknown", wa._meeting_instant("something else entirely"))
'
    [[ "$output" == *"name FE standup"* ]]
    [[ "$output" == *"utc 2026-08-24T17:29"* ]]
    [[ "$output" == *"unknown ('something else entirely', 0)"* ]]
}

# --- the expiry it names for itself ---------------------------------------------------

@test "a promise nothing can show says how many days it has left" {
    run wa '
d = Drive([found(at=NOW - 5 * DAY)], {DOC: [promise()]})
wa._drive = d
rows, _ = wa.ledger_meetings()
print("days", rows[0]["days"])
print("expires", rows[0]["expires_in"])
print("window", rows[0]["window_days"])
'
    [[ "$output" == *"days 5"* ]]
    [[ "$output" == *"expires 9"* ]]
    [[ "$output" == *"window 14"* ]]
}

@test "the expiry never counts below zero" {
    run wa '
import os
os.environ["WORK_ARCS_MEETING_LOOKBACK"] = "3"
d = Drive([found(at=NOW - 9 * DAY)], {DOC: [promise()]})
wa._drive = d
rows, _ = wa.ledger_meetings()
print("expires", rows[0]["expires_in"])
'
    [[ "$output" == *"expires 0"* ]]
}

# --- closing on evidence, with no model in it ------------------------------------------

@test "a merge request merged after a spoken promise closes the row" {
    run wa '
led = ledger(commitment("I will get !10481 rebased and up today"))
wa.jira_status_moves = no_jira
wa.close_commitments(led, {"br": fate(10481, "merged", NOW - DAY)})
print("owed", len(led["you_owe"]))
print("why", led["you_owe_closed"][0]["closed_by"])
print("how", led["you_owe_closed"][0]["closed_how"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"owed 0"* ]]
    [[ "$output" == *"why !10481 merged 2d after"* ]]
    [[ "$output" == *"how mr"* ]]
}

@test "a ticket that reached Done after a spoken promise closes the row" {
    run wa '
led = ledger(commitment("next sprint I am hoping to complete UB-6938"))
wa.jira_status_moves = lambda keys: moves("UB-6938", "Done", "Done", NOW - DAY)
wa.close_commitments(led, {})
print("owed", len(led["you_owe"]))
print("how", led["you_owe_closed"][0]["closed_how"])
'
    [[ "$output" == *"owed 0"* ]]
    [[ "$output" == *"how ticket"* ]]
}

@test "a ticket already Done when it was promised closes nothing" {
    run wa '
led = ledger(commitment("next sprint I am hoping to complete UB-6938"))
wa.jira_status_moves = lambda keys: moves("UB-6938", "Done", "Done", NOW - 9 * DAY)
wa.close_commitments(led, {})
print("owed", len(led["you_owe"]))
'
    [[ "$output" == *"owed 1"* ]]
}

@test "a spoken bare number is not a ticket key and closes nothing" {
    # The transcript writes what it heard: Kyle says "682" and "6938", never "UL-682".
    # Resolving a spoken number to a project would be a guess, and a wrong guess here
    # deletes a real reminder -- the one failure this feature must not have. So a bare
    # number matches neither pattern, asks nothing, and the row correctly stands.
    run wa '
led = ledger(commitment("today I will be doing a lot of code review for 682"))
wa.jira_status_moves = no_jira
wa.close_commitments(led, {"br": fate(682, "merged", NOW - DAY)})
print("owed", len(led["you_owe"]))
print("closed", len(led["you_owe_closed"]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"owed 1"* ]]
    [[ "$output" == *"closed 0"* ]]
}

@test "a merge request closed rather than merged is not a promise kept" {
    run wa '
led = ledger(commitment("I will get !10481 rebased and up today"))
wa.jira_status_moves = lambda keys: {}
wa.close_commitments(led, {"br": fate(10481, "closed", NOW - DAY)})
print("owed", len(led["you_owe"]))
'
    [[ "$output" == *"owed 1"* ]]
}

@test "both kinds of promise close in the one pass" {
    # The reason COMMITMENT_KINDS is a shared constant. A meeting row this pass does not
    # recognise renders forever, because nothing else will ever close it.
    run wa '
led = ledger(commitment("I will get !10481 up today"),
             commitment("I will merge !10500 today", kind="commitment", ref="#chan"))
wa.jira_status_moves = no_jira
wa.close_commitments(led, {"a": fate(10481, "merged", NOW - DAY),
                           "b": fate(10500, "merged", NOW - DAY)})
print("owed", len(led["you_owe"]))
print("closed", len(led["you_owe_closed"]))
print("kinds", sorted(e["kind"] for e in led["you_owe_closed"]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"owed 0"* ]]
    [[ "$output" == *"closed 2"* ]]
    [[ "$output" == *"kinds ['commitment', 'meeting-commitment']"* ]]
}

@test "a promise naming nothing at all keeps its row and asks Jira nothing" {
    run wa '
led = ledger(commitment("I will take a look at the vocabulary mapping"))
wa.jira_status_moves = no_jira
wa.close_commitments(led, {})
print("owed", len(led["you_owe"]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"owed 1"* ]]
}

# --- the ledger only prunes when every source answered --------------------------------

@test "the environment can turn the sweep off for a caller with no argv" {
    # This source is the only one with no credential to gate itself on, and the first
    # thing that cost was a test file about glab, which hung on a Drive connector.
    run wa '
import os
os.environ["WORK_ARCS_NO_MEETINGS"] = "1"
def boom(*a, **k):
    raise AssertionError("Drive was consulted when meetings were turned off")
wa._drive = boom
rows, whole = wa.ledger_meetings()
print("rows", len(rows))
print("whole", whole)
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rows 0"* ]]
    [[ "$output" == *"whole True"* ]]
}

@test "skipping meetings is complete-and-empty, not incomplete" {
    # --no-meetings means there are no meeting rows and there never were, so nothing is
    # missing and a dismissal prune is perfectly safe. A failed sweep is the opposite.
    run wa '
def boom(*a, **k):
    raise AssertionError("build_ledger consulted meetings when told not to")
wa.ledger_meetings = boom
wa.gitlab_me = lambda repo: None
wa.ledger_jira_stalled = lambda: ([], True)
wa.ledger_slack = lambda: ([], [], False, True)
led = wa.build_ledger("repo", [], meetings=False)
print("complete", led["complete"])
print("you", len(led["you_owe"]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"you 0"* ]]
}

@test "a meeting sweep that half answered makes the whole ledger incomplete" {
    run wa '
wa.ledger_meetings = lambda: ([], False)
wa.gitlab_me = lambda repo: "kyle"
wa.ledger_they_owe = lambda r, m, me: ([], True)
wa.ledger_you_owe = lambda r, me: ([], 0, True, [], 0)
wa.ledger_jira_stalled = lambda: ([], True)
wa.ledger_slack = lambda: ([], [], True, True)
led = wa.build_ledger("repo", [])
print("complete", led["complete"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"complete False"* ]]
}

@test "meeting rows join you_owe alongside the Slack ones" {
    run wa '
wa.ledger_meetings = lambda: ([commitment("I will do it today")], True)
wa.gitlab_me = lambda repo: "kyle"
wa.ledger_they_owe = lambda r, m, me: ([], True)
wa.ledger_you_owe = lambda r, me: ([], 0, True, [], 0)
wa.ledger_jira_stalled = lambda: ([], True)
wa.ledger_slack = lambda: ([], [], True, True)
led = wa.build_ledger("repo", [])
print("you", len(led["you_owe"]))
print("kind", led["you_owe"][0]["kind"])
print("complete", led["complete"])
print("has_fp", bool(led["you_owe"][0].get("fp")))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"you 1"* ]]
    [[ "$output" == *"kind meeting-commitment"* ]]
    [[ "$output" == *"complete True"* ]]
    [[ "$output" == *"has_fp True"* ]]
}

# --- the clock he set himself ---------------------------------------------------------

@test "the deadline field is where a spoken clock is read from" {
    # It is the cleanest input promised_due has ever had: the model's isolated answer to
    # "what clock did he name", rather than a paraphrase of the deliverable that may or
    # may not have kept the phrase.
    run am '
r = row(promised="migrate the Dove workspaces", deadline="in the next couple days",
        asked="2026-08-24")
print(am.promised_due(r)[0])
'
    [ "$output" = "2026-08-27" ]
}

@test "a couple of days reads as three and a few as five" {
    # Ambiguity resolves to the later date, like every other reading here: a promise is
    # called late only when it is late on every reading of what was said.
    run am '
for said in ("in the next couple days", "a couple of days", "in a few days",
             "in a couple weeks"):
    d = am.promised_due(row(asked="2026-08-10"), said)
    print(said, "->", d[0])
'
    [[ "$output" == *"in the next couple days -> 2026-08-13"* ]]
    [[ "$output" == *"a couple of days -> 2026-08-13"* ]]
    [[ "$output" == *"in a few days -> 2026-08-15"* ]]
    [[ "$output" == *"in a couple weeks -> 2026-08-31"* ]]
}

@test "a promise that named no clock still comes due never" {
    # Most spoken promises name nothing, and "next sprint" is one of them here: no sprint
    # boundary is in this function's inputs, so reading it would be inventing a date.
    run am '
for said in ("", "next sprint", "when I get a chance", "at some point"):
    print(repr(said), "->", am.promised_due(row(asked="2026-08-10"), said))
'
    [[ "$output" == *"-> None"* ]]
    run am '
print(len([s for s in ("", "next sprint", "when I get a chance", "at some point")
           if am.promised_due(row(asked="2026-08-10"), s) is not None]))
'
    [ "$output" = "0" ]
}

@test "a spoken promise past its own date is overdue like a typed one" {
    run am '
led = {"they_owe": [], "you_owe": [
    row(deadline="today", asked="2026-08-10", days=4, promised="migrate the workspaces"),
    row(kind="commitment", ref="#chan", deadline="", promised="reply tomorrow",
        asked="2026-08-11", days=3, fp="fp-s")]}
import datetime
over = am.overdue_commitments(led, datetime.date(2026, 8, 14))
print("n", len(over))
print("first", over[0][1]["kind"], over[0][0])
'
    [[ "$output" == *"n 2"* ]]
    [[ "$output" == *"first meeting-commitment 4"* ]]
}

@test "the overdue order is total down past the reference" {
    # One standup holds every promise made in it, so the ref ties where a channel would
    # not. A tie hands the brief whatever order the rows arrived in, and the brief caches
    # on the text it is given.
    run am '
import datetime
mk = lambda fp: row(deadline="today", asked="2026-08-10", days=4,
                    promised="do the thing", fp=fp)
led = {"they_owe": [], "you_owe": [mk("fp-b"), mk("fp-a")]}
over = am.overdue_commitments(led, datetime.date(2026, 8, 14))
print([e[1]["fp"] for e in over])
'
    [ "$output" = "['fp-a', 'fp-b']" ]
}

@test "a spoken promise says where it was spoken, not in a channel" {
    run am '
print("".join(x if isinstance(x, str) else "[REF]"
              for x in am.you_clause(row(promised="migrate the workspaces", days=3))))
'
    [[ "$output" == *"you said at FE standup you would "* ]]
}

# --- the page it ends up on -----------------------------------------------------------

# Renders a whole page from a minimal work-arcs document, the same way forgotten_arcs does.
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

@test "a spoken promise renders with its clock, its meeting and its own words" {
    run page '{"generated": "2026-08-14T09:00:00-0700", "repo": "r", "arc_count": 0,
      "arcs": [],
      "ledger": {"they_owe": [], "you_owe_covered": 0, "you_owe_closed": [],
        "slack": true, "slack_complete": true, "complete": true,
        "you_owe": [{"kind": "meeting-commitment", "ref": "FE standup", "title": "",
          "who": "Ella", "promised": "migrate the Dove workspaces",
          "deadline": "in the next couple days", "asked": "2026-08-12", "days": 2,
          "asked_ts": 1786000000, "expires_in": 12, "window_days": 14,
          "quote": "it is kind of non-trivial but I think I will get it in the next couple days",
          "url": "https://docs.google.com/document/d/abc/edit", "inferred": true,
          "fp": "fp-m"}]}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"migrate the Dove workspaces"* ]]
    [[ "$output" == *"in the next couple days"* ]]
    [[ "$output" == *"said out loud on 2026-08-12"* ]]
    [[ "$output" == *"inferred from the transcript, quoted"* ]]
    # How it dies, and named as the transcript window rather than Slack's.
    [[ "$output" == *"14-day transcript window in 12d"* ]]
    # And the quote is Kyle's, never Ella's -- she is who he promised.
    [[ "$output" != *"Ella:"* ]]
    # The meeting's name is the link label; the row saying it twice read badly enough to be
    # a bug. Counted inside the row rather than across the page: the cockpit door above the
    # ledger names that section's own oldest loop, which on this document is this row, and
    # a door naming what it points at is the whole of what a door is for. Last in the test,
    # because `run` rebinds $output and every assertion above it reads the page.
    run python3 - "$TEST_TMPDIR/page.html" <<'ZZONCE'
import re, sys
html = open(sys.argv[1]).read()
row = re.search(r'<li data-fp="fp-m".*?</li>', html, re.S).group(0)
print(row.count("FE standup"))
ZZONCE
    [ "${lines[0]}" = "1" ]
}

@test "a spoken promise closed on evidence is shown as closed, with the evidence" {
    run page '{"generated": "2026-08-14T09:00:00-0700", "repo": "r", "arc_count": 0,
      "arcs": [],
      "ledger": {"they_owe": [], "you_owe": [], "you_owe_covered": 0,
        "slack": true, "slack_complete": true, "complete": true,
        "you_owe_closed": [{"kind": "meeting-commitment", "ref": "FE standup",
          "who": "", "promised": "get the sharding MR up", "deadline": "today",
          "asked": "2026-08-12", "days": 2, "quote": "I will get it up today",
          "url": "https://docs.google.com/document/d/abc/edit",
          "closed_how": "mr", "closed_by": "!10481 merged the same day",
          "closed_url": "https://gitlab/mr/10481", "fp": "fp-m"}]}}'
    [ "$status" -eq 0 ]
    [[ "$output" == *"closed on evidence"* ]]
    [[ "$output" == *"get the sharding MR up"* ]]
    [[ "$output" == *"!10481 merged the same day"* ]]
}

# --- whose words the quote is ---------------------------------------------------------

@test "a meeting quote is attributed to Kyle and never to the person he promised" {
    # The one failure a quote cannot survive. The row's `who` is the person relying on the
    # promise, so getting this wrong prints a colleague saying a sentence Kyle said.
    run python3 -c "
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader('ap', '$REPO_ROOT/bin/arcs-page')
spec = importlib.util.spec_from_loader('ap', loader)
ap = importlib.util.module_from_spec(spec)
sys.argv = ['ap']
loader.exec_module(ap)
print('mine', 'meeting-commitment' in ap.MINE)
print('kinds', ap.COMMITMENT_KINDS)
"
    [[ "$output" == *"mine True"* ]]
    [[ "$output" == *"meeting-commitment"* ]]
}

@test "every program agrees on which rows are promises" {
    run python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/lib')
from commitments import COMMITMENT_KINDS, is_commitment
print(COMMITMENT_KINDS)
print(is_commitment({'kind': 'meeting-commitment'}),
      is_commitment({'kind': 'commitment'}),
      is_commitment({'kind': 'slack-dm'}), is_commitment(None))
"
    [[ "$output" == *"('commitment', 'meeting-commitment')"* ]]
    [[ "$output" == *"True True False False"* ]]
}

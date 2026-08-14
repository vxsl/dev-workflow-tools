#!/usr/bin/env bats
# Tests for what happens when the world does not cooperate.
#
# Every other suite here tests a feature against inputs that arrived. This one tests the
# features against inputs that did not, because that is where the whole class of
# expensive bug lives: a section that is silently missing a third of its rows looks
# exactly like a section where a third of the loops closed. The house rule is absence of
# a section over a wrong section -- degrade with words, never with a plausible number,
# and never with a traceback.
#
# The four doors, all of which were open:
#
#   partial network       a paged sweep whose page 2 fails returns page 1 and says nothing
#   dead credentials      an expired token looks like a quiet week
#   corrupt state         a truncated snapshot.json / dismissed.json / commitments.json
#   empty universe        no transcripts, no branches, no Slack
#
# The prune tests are the load-bearing ones. Pruning a dismissal means deleting Kyle's
# acknowledgement on the grounds that its row is gone, and every one of these doors let a
# run make that claim about rows it had simply failed to fetch. A dismissal that dies
# because the network hiccuped is worse than no dismissal feature at all: the tool
# silently un-acknowledges things, so the list you cleared fills back up and you stop
# believing that clearing it does anything.

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

# Runs a python snippet with work-arcs imported as `wa` and the Slack fakes in scope.
wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" <<PY
import importlib.machinery, importlib.util, sys, json, os
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
sys.argv = ["wa"]
loader.exec_module(wa)

AUTH = {"ok": True, "user_id": "U1"}

def slack(auth=True, pages=None):
    """A fake _slack. \`pages\` maps page number -> response, None meaning the call fails."""
    def call(method, **params):
        if method == "auth.test":
            return AUTH if auth else None
        if pages is None:
            return {"ok": True, "messages": {"matches": []}}
        return pages.get(params.get("page"))
    return call

def dismissal(fp="fp-row"):
    """One acknowledgement in the store, as --dismiss leaves it."""
    wa.DISMISSED.parent.mkdir(parents=True, exist_ok=True)
    wa.DISMISSED.write_text(json.dumps({fp: {"ref": "#eng", "at": 1, "note": ""}}))

def survives(fp="fp-row"):
    return fp in json.loads(wa.DISMISSED.read_text())

def prune_run(ledger, arcs=(), gap={}):
    """apply_dismissals with the real pipeline's gate verbatim.

    \`gap\` defaults to {} rather than None: an empty dict is "Jira answered and had no
    mismatches", which is the state a healthy run is usually in, and None is "Jira was
    never asked" -- which switches the gate off and would make every test below pass by
    never pruning at all.
    """
    wa.apply_dismissals(ledger, list(arcs), gap,
                        prune=bool(ledger and ledger.get("complete")
                                   and gap is not None))

def led(consulted, complete, you=()):
    """A ledger whose GitLab and Jira halves were fine and whose Slack half is the variable."""
    return {"they_owe": [], "you_owe": list(you), "you_owe_covered": 0,
            "you_owe_closed": [], "slack": consulted, "slack_complete": complete,
            "complete": complete}

def only_slack():
    """No Slack token, Jira quiet: whatever goes wrong is GitLab's, not a co-factor."""
    os.environ.pop("SLACK_USER_TOKEN", None)
    wa.ledger_jira_stalled = lambda *a, **k: ([], True)

$1
PY
}

# ── a Slack outage must not be mistaken for a closed loop ─────────────────────

@test "Slack answering auth and then nothing is not a complete ledger" {
    # The exact door the prune fell through: auth.test proves a token existed a moment ago
    # and nothing whatsoever about the searches after it. The ledger used to report
    # slack=True here, so the page showed no caveat and the prune ran on a Slack universe
    # that was entirely absent.
    SLACK_USER_TOKEN=xoxp-x run wa '
wa._slack = slack(auth=True, pages={1: None})
they, you, consulted, complete = wa.ledger_slack()
print("consulted", consulted, "complete", complete, "rows", len(they) + len(you))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"consulted True complete False rows 0"* ]]
}

@test "a sweep that loses page two says so instead of returning page one" {
    # 100 matches then a failure is indistinguishable from a complete 100-match sweep by
    # length alone, and length was the only signal. Three quarters of the commitment
    # candidates can vanish this way with the ledger reporting itself whole.
    run wa '
full = {"ok": True, "messages": {"matches": [{"ts": "1.0"}] * 100}}
wa._slack = slack(pages={1: full, 2: None})
out, ok = wa._slack_sweep("q")
print("matches", len(out), "complete", ok)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"matches 100 complete False"* ]]
}

@test "an expired token keeps every dismissal it could not see" {
    # SLACK_USER_TOKEN=invalid. auth.test fails, no Slack rows exist, and the old gate
    # pruned every acknowledgement on them while announcing that their facts had moved.
    SLACK_USER_TOKEN=xoxp-expired run wa '
wa._slack = slack(auth=False)
they, you, consulted, complete = wa.ledger_slack()
dismissal()
prune_run(led(consulted, complete))
print("survived", survives())'
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived True"* ]]
}

@test "a partial outage keeps every dismissal it could not see" {
    SLACK_USER_TOKEN=xoxp-x run wa '
wa._slack = slack(auth=True, pages={1: None})
they, you, consulted, complete = wa.ledger_slack()
dismissal()
prune_run(led(consulted, complete))
print("survived", survives())'
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived True"* ]]
}

@test "no Slack token at all still prunes, because nothing can be missing" {
    # The reason the gate reads slack_complete rather than slack. With no token there are
    # no Slack rows and there never were, so a stale GitLab acknowledgement must still be
    # able to expire -- gating on "was Slack consulted" would freeze the store forever on
    # a machine that has no Slack.
    run wa '
os.environ.pop("SLACK_USER_TOKEN", None)
they, you, consulted, complete = wa.ledger_slack()
print("consulted", consulted, "complete", complete)
dismissal()
prune_run(led(consulted, complete))
print("survived", survives())'
    [ "$status" -eq 0 ]
    [[ "$output" == *"consulted False complete True"* ]]
    [[ "$output" == *"survived False"* ]]
}

@test "a full Slack answer prunes a dismissal whose row really is gone" {
    # The control. Without this the four tests above are satisfied by never pruning at all,
    # which would be its own bug -- an acknowledgement that outlives its fact is a row the
    # tool has quietly stopped telling you about.
    SLACK_USER_TOKEN=xoxp-x run wa '
wa._slack = slack(auth=True)
they, you, consulted, complete = wa.ledger_slack()
dismissal()
prune_run(led(consulted, complete))
print("survived", survives())'
    [ "$status" -eq 0 ]
    [[ "$output" == *"survived False"* ]]
}

# ── the other three doors into the same prune ─────────────────────────────────

@test "glab refusing to say who you are leaves both GitLab sides absent, not empty" {
    # The narrowest door and the one nothing guarded: collect_mrs succeeds, so mrs_known is
    # true and the ledger is built, and glab then dies before `user`. Both GitLab halves
    # are keyed on that username, so they come back empty -- and a prune deleted every
    # acknowledgement on a GitLab row while announcing that its fact had moved.
    run wa '
only_slack()
wa.glab = lambda *a, **k: None
l = wa.build_ledger(Path("/nonexistent"), [])
print("complete", l["complete"])
dismissal("fp-gitlab")
prune_run(l)
print("survived", survives("fp-gitlab"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"complete False"* ]]
    [[ "$output" == *"survived True"* ]]
    [[ "$output" == *"would not say who you are"* ]]
}

@test "an MR whose notes GitLab will not return is left off, not called silent" {
    # The false-positive direction, which is the more expensive one. _mr_notes ended in
    # `or []`, and ledger_they_owe reads an empty note list as "nobody has said a word" --
    # which IS the review-silence claim. So one failed call invented a row accusing five
    # reviewers of ignoring a merge request they had already discussed.
    run wa '
only_slack()
mr = {"iid": 10481, "reviewers": ["brian", "vadym"], "draft": False,
      "title": "t", "url": "u", "updated": "2026-08-01"}
calls = []
def glab(repo, path, **k):
    calls.append(path)
    if path == "user":
        return {"username": "kyle"}
    return None                      # notes and approvals both refuse
wa.glab = glab
rows, whole = wa.ledger_they_owe(Path("/nonexistent"), [mr], "kyle")
print("rows", len(rows), "complete", whole)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rows 0 complete False"* ]]
    [[ "$output" == *"would not answer for 1 merge request"* ]]
}

@test "an MR GitLab will not discuss is not counted as already handled either" {
    # `covered` is a claim -- somebody approved, or you already spoke -- and an unreadable
    # MR fell into it, inflating "+N review requests already handled" with requests nobody
    # had handled. Silently, and in the reassuring direction.
    run wa '
only_slack()
def glab(repo, path, **k):
    if path == "user":
        return {"username": "kyle"}
    if "merge_requests?state=opened" in path:
        return [{"iid": 7, "title": "t", "web_url": "u", "draft": False,
                 "author": {"username": "someone"}, "created_at": "2026-08-01"}]
    return None                      # discussions refuse
wa.glab = glab
rows, covered, whole = wa.ledger_you_owe(Path("/nonexistent"), "kyle")
print("rows", len(rows), "covered", covered, "complete", whole)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rows 0 covered 0 complete False"* ]]
}

@test "Jira timing out leaves its side absent, not empty" {
    JIRA_DOMAIN=example.atlassian.net JIRA_EMAIL=a@b JIRA_API_TOKEN=t run wa '
import urllib.error
def boom(*a, **k):
    raise urllib.error.URLError("timed out")
wa.urllib.request.urlopen = boom
rows, whole = wa.ledger_jira_stalled()
print("rows", len(rows), "complete", whole)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rows 0 complete False"* ]]
    [[ "$output" == *"Jira would not answer"* ]]
}

@test "Jira configured but absent is a complete answer" {
    # The control for the gate reading completeness rather than presence: no credentials
    # means no Jira rows and none ever, so a prune stays safe.
    run wa '
for k in ("JIRA_DOMAIN", "JIRA_EMAIL", "JIRA_API_TOKEN"):
    os.environ.pop(k, None)
rows, whole = wa.ledger_jira_stalled()
print("rows", len(rows), "complete", whole)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rows 0 complete True"* ]]
}

# ── corrupt state must cost a cache, never a run ──────────────────────────────

# Every wrong shape a state file can hold. The truncations are what a process killed
# during write_text leaves behind; `null` is what json.dumps(None) writes; the valid-JSON
# ones are the interesting half, because `except (OSError, ValueError)` catches neither
# and the old readers went straight on to `.items()` on a list.
SHAPES=('[{"x": 1}]' '["a","b"]' '"hello"' '42' 'null' '{"a": {"b"' '')

@test "every wrong shape in every state file costs a cache and not a traceback" {
    # 22 tracebacks before this, across apply_dismissals, apply_parked, apply_detached,
    # cached_clusters and arc-morning's cache_read/cache_write. The readers are driven with
    # non-empty inputs on purpose: an empty arc list makes apply_parked's loop never run,
    # which is how a fuzz over this can come back clean while the bug is live.
    for shape in "${SHAPES[@]}"; do
        for f in dismissed.json parked.json detached.json authoritative.json \
                 cluster-cache.json commitments.json morning.json briefs.json; do
            printf '%s' "$shape" >"$XDG_STATE_HOME/work-arcs/$f"
        done
        run wa '
arc = {"id": "A", "label": "A", "fingerprint": "fp", "branches": [], "demands": [],
       "activity": {}, "settled": None, "notify": []}
row = {"kind": "commitment", "ref": "#c", "fp": "fp-r", "days": 1, "quote": "q",
       "promised": "p", "asked": "2026-08-01"}
wa.apply_dismissals({"they_owe": [], "you_owe": [row]}, [arc], {}, prune=True)
wa.apply_parked([dict(arc)])
wa.apply_detached({"b": "A", "c": "A"})
wa.load_overrides()
wa.load_snapshot("proj")
wa.load_store(wa.CLUSTER_CACHE, "the clustering cache").get("key")
print("survived")'
        [[ "$output" != *Traceback* ]] || {
            echo "shape ${shape@Q} raised:"; echo "$output"; return 1; }
        [[ "$output" == *survived* ]]
    done
}

@test "a discarded state file names itself rather than emptying quietly" {
    # A cache that silently empties looks exactly like a cache that is working and cold,
    # and the difference is a run's worth of model calls. The wrong-shape case is the one
    # that used to say nothing at all, because it never reached a message.
    printf '%s' '[{"x": 1}]' >"$XDG_STATE_HOME/work-arcs/dismissed.json"
    run wa 'wa.apply_dismissals({"they_owe": [], "you_owe": []}, [], {}, prune=False)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"dismissed.json"* ]]
    [[ "$output" == *"holds list where an object belongs"* ]]
    [[ "$output" == *"the dismissal store starts empty this run"* ]]
}

@test "a corrupt dismissal store never prunes on its own emptiness" {
    # The nastiest compound: the store is unreadable, so `live` and `store` are both empty,
    # so a prune has nothing to delete -- but it must also not WRITE the empty store back
    # over a file that might still be recoverable by hand.
    printf '%s' '{"fp-r": {"ref": "#c"' >"$XDG_STATE_HOME/work-arcs/dismissed.json"
    run wa '
before = wa.DISMISSED.read_text()
wa.apply_dismissals({"they_owe": [], "you_owe": []}, [], {}, prune=True)
print("untouched", wa.DISMISSED.read_text() == before)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"untouched True"* ]]
}

# ── a stage must not traceback on what the stage before it handed over ────────

@test "each pipeline stage rejects a non-JSON payload with a sentence" {
    for prog in arc-brief arc-morning arcs-page; do
        run bash -c "printf 'not json {' | '$REPO_ROOT/bin/$prog' --out /dev/null 2>&1"
        [[ "$output" != *Traceback* ]] || { echo "$prog: $output"; return 1; }
        [[ "$output" == *"$prog:"* ]]
    done
}

@test "each pipeline stage rejects a payload of the wrong shape with a sentence" {
    # `[1,2,3]` parses, so the JSONDecodeError guard let it through to an AttributeError
    # several frames deeper -- in arcs-page's case after work-arcs and both model passes
    # had already been paid for.
    for prog in arc-brief arc-morning arcs-page; do
        run bash -c "printf '[1,2,3]' | '$REPO_ROOT/bin/$prog' --out /dev/null 2>&1"
        [[ "$output" != *Traceback* ]] || { echo "$prog: $output"; return 1; }
        [[ "$output" == *"list"* ]]
    done
}

@test "a row that did arrive is still marked acknowledged during an outage" {
    # An outage costs a prune, never a shout. The rows Slack managed to return keep their
    # dismissed mark, so a partial answer does not make the acknowledged half loud again.
    SLACK_USER_TOKEN=xoxp-x run wa '
row = {"kind": "commitment", "ref": "#eng", "fp": "fp-row", "days": 3}
dismissal()
l = led(True, False, you=[row])
prune_run(l)
print("dismissed", row.get("dismissed"), "survived", survives())'
    [ "$status" -eq 0 ]
    [[ "$output" == *"dismissed True survived True"* ]]
}

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
                        prune=bool(ledger and ledger.get("slack_complete")
                                   and gap is not None))

def led(consulted, complete, you=()):
    return {"they_owe": [], "you_owe": list(you), "you_owe_covered": 0,
            "you_owe_closed": [], "slack": consulted, "slack_complete": complete}

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

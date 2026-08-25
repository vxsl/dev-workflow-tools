#!/usr/bin/env bats
# Tests for the curation queue's second question type: is this still intended work?
#
# Everything in curation.bats asks whether the derivation put a branch in the right arc.
# Nothing there can ask whether the work is work at all, and that is what Kyle's verdict
# on the local-only figures was about: much of what is on the disk in agentic development
# is residue -- experiments and churn that were never meant to land -- and the tool
# counted every commit of it as debt. Without a verdict on intent, five days of dead
# experiments outrank a meaningful half-day fix in the only-here ranking forever.
#
# So what is worth pinning here is not an arithmetic. It is the four ways the queue can
# stop being trustworthy:
#
#   never-asked      work that is intended by construction must never be asked about.
#                    Warm, proposed, sprint-claimed and promised all have exactly one
#                    honest answer, and a question with one answer spends the day's
#                    attention for nothing.
#   the abstentions  every test above is an EXCLUSION, so a source that did not answer
#                    does not shorten the queue -- it lets through precisely the work
#                    that would have been excluded. Missing evidence must produce no
#                    questions, out loud, rather than a shorter list.
#   the effect       "residue" moves numbers: out of unpushed_days, out of the only_here
#                    ranking, out of the lede. The branches stay exactly where they are.
#   the expiry       and it undoes itself. A commit on any branch of the arc means you
#                    went back to the work, and work you went back to was meant.
#
# The functions are called directly. residue_queue, apply_residue and finalize are pure
# over their inputs, and reaching them through the CLI would mean standing up a git repo,
# a GitLab, a Jira and a Slack to test a ranking.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    # No test may read or write the real stores. work-arcs resolves RESIDUE, INTENDED and
    # CURATION_LABELS at import time, so this is exported before the module loads.
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
}

teardown() {
    teardown_temp_dir
}

# Runs a python snippet with work-arcs imported as wa and arc fixtures in scope.
wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" <<PY
import importlib.machinery, importlib.util, sys, json
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
sys.argv = ["wa"]
loader.exec_module(wa)

def br(name, sha="s1", **kw):
    """One branch with three commits nothing has pushed."""
    d = {"name": name, "sha": sha, "unpushed": 3, "commits_ahead": 3, "age_days": 20,
         "parents": [], "pushed": False, "commits": []}
    d.update(kw)
    return d

def arc(ident, branches=None, cliff=20, gap=2, **kw):
    """A cold, unproposed, unclaimed workstream -- the shape the queue exists to ask about.

    Twenty days quiet against a two-day rhythm is ten of its own beats, so it clears the
    ratio comfortably; every test that wants a different answer changes one field.
    """
    d = {"id": ident, "label": ident, "kind": "cluster",
         "branches": branches if branches is not None else [br(ident + "-branch")],
         "stashes": [], "mrs": [], "sessions": [], "issues": [], "mrs_known": True,
         "activity": {"invested": {"entries": 400, "sessions": 6, "commits": 9,
                                   "days": 3},
                      "cliff_days": cliff, "typical_gap_days": gap}}
    d.update(kw)
    wa.finalize(d)
    return d

def after(a, **kw):
    """Fields finalize owns, set once it has run.

    `stage` and `settled` are derived, so a fixture that passed them into arc() would
    have them recomputed out from under it -- which is finalize working. A test that
    wants an arc on a particular rung has to say so after the ladder has spoken.
    """
    a.update(kw)
    return a

# A ledger that answered for everything it holds, and holds no promises.
LEDGER = {"complete": True, "you_owe": [], "they_owe": []}

def asked(arcs, ledger=LEDGER, jira=True, pinned=()):
    q, why = wa.residue_queue(arcs, ledger, jira, pinned)
    return [x["arc"] for x in q], why

$1
PY
}

# A stand-in for fzf that answers with \$FAKE_KEY on the first row and exits, so the
# keystroke flow can be driven from a test. Built with printf rather than a heredoc:
# every helper in this repo that writes a shell script from a bats file is one edit away
# from a substitution the outer heredoc eats, and that failure lands on every test in the
# file at once rather than on the one that introduced it.
fake_fzf() {
    {
        echo '#!/usr/bin/env bash'
        echo 'first=$(head -1)'
        printf '%s\n' 'printf "%s\n%s\n" "$FAKE_KEY" "$first"'
    } > "$TEST_TMPDIR/fzf"
    chmod +x "$TEST_TMPDIR/fzf"
    export FZP_FZF="$TEST_TMPDIR/fzf"
}

# ── who gets asked ────────────────────────────────────────────────────────────

@test "cold, unproposed, unclaimed local-only work is asked about" {
    run wa 'print(asked([arc("A")]))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"(['A'], '')"* ]]
}

@test "the question carries the evidence for asking it, not just the question" {
    # A reader who cannot see which exclusions were applied has no way to notice the day
    # one of them is wrong, and this question proposes writing work off.
    run wa '
q, _ = wa.residue_queue([arc("A")], LEDGER, True)
print(q[0]["why"])
print(q[0]["cliff_days"], q[0]["gap_days"], q[0]["beats"])
print(wa.residue_preview(q[0]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"never proposed"* ]]
    [[ "$output" == *"20 2 10.0"* ]]
    [[ "$output" == *"no sprint carries it and no promise names it"* ]]
    [[ "$output" == *"quiet 20 days"* ]]
}

@test "work touched within its own rhythm is never asked about" {
    # Work in progress is not residue whatever it looks like.
    run wa 'print(asked([arc("A", cliff=3)]))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"([], '')"* ]]
}

@test "quiet is measured against the arc's own rhythm, not the calendar" {
    # Seven days of silence on a four-day rhythm is one missed beat, and a whole working
    # week of nothing on something worked daily is a stop. Same seven days, opposite
    # readings, and only the ratio can tell them apart -- the same arithmetic the cliff
    # verdict uses, deliberately not a second staleness measure.
    run wa 'print(asked([arc("SLOW", cliff=7, gap=4)]), asked([arc("FAST", cliff=7, gap=1)]))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"([], '') (['FAST'], '')"* ]]
}

@test "an arc with no evidence of activity is not asked about" {
    # An arc whose commits all predate the log window has no rhythm to be cold against,
    # and a question built on knowing nothing would be asked about every one of them.
    run wa '
a = arc("A")
a["activity"] = {"invested": None, "cliff_days": None, "typical_gap_days": None}
print(asked([a]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"([], '')"* ]]
}

@test "an open merge request means the work is intended by construction" {
    run wa 'print(asked([arc("A", mrs=[{"iid": 10, "updated": "", "threads": []}])]))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"([], '')"* ]]
}

@test "a merge request that already merged still counts as having been proposed" {
    # "Never proposed" is about whether the work was ever put up, not about whether an MR
    # is open now -- and mr_fate is the only record of one that is not.
    run wa '
a = arc("A", branches=[br("A-branch", mr_fate={"state": "merged", "iid": 9})])
print(asked([a]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"([], '')"* ]]
}

@test "a sprint claiming the work outranks a guess about intent" {
    run wa 'print(asked([arc("A", sprint={"name": "S12", "ends": ""})]))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"([], '')"* ]]
}

@test "a promise naming the work is the most direct evidence of intent there is" {
    # Joined through _join_thread, the same author as the Slack thread join: a promise is
    # a sentence about work exactly as a thread is, and two implementations of "which
    # work is this sentence about" would disagree the first time one improved.
    run wa '
a = arc("A", branches=[br("geo-filter-collection-spike")])
led = {"complete": True, "they_owe": [],
       "you_owe": [{"kind": "commitment", "ref": "#tech-backend", "title": "",
                    "promised": "", "quote": "I will get geo-filter-collection-spike up today"}]}
print(asked([a], led))
print(asked([a]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"([], '')"* ]]
    [[ "$output" == *"(['A'], '')"* ]]
}

@test "a promise made out loud in a meeting counts the same as one typed in Slack" {
    # COMMITMENT_KINDS exists for exactly this: the two differ only in the room.
    run wa '
a = arc("A", branches=[br("geo-filter-collection-spike")])
led = {"complete": True, "they_owe": [],
       "you_owe": [{"kind": "meeting-commitment", "ref": "Standup", "title": "",
                    "promised": "", "quote": "I will finish geo-filter-collection-spike"}]}
print(asked([a], led))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"([], '')"* ]]
}

@test "a row somebody else owes is not a promise you made" {
    run wa '
a = arc("A", branches=[br("geo-filter-collection-spike")])
led = {"complete": True, "you_owe": [],
       "they_owe": [{"kind": "review-silence", "ref": "!1", "title": "",
                     "quote": "geo-filter-collection-spike is waiting on you"}]}
print(asked([a], led))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"(['A'], '')"* ]]
}

@test "the cliff's own exemptions apply, rather than being restated" {
    # in-review and pre-landing come out of FORGOTTEN_EXEMPT, so the two features cannot
    # drift apart about which silences mean nothing.
    run wa '
print(asked([after(arc("A"), stage="in-review")]))
print(asked([after(arc("B"), stage="pre-landing")]))
print(asked([after(arc("C"), parked={"at": 1, "note": ""})]))
print(asked([after(arc("D"), settled="landed")]))
'
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | grep -c "(\[\], '')")" -eq 4 ]]
}

@test "an arc holding no local-only work has nothing to be residue" {
    run wa 'print(asked([arc("A", branches=[br("A-branch", unpushed=0)])]))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"([], '')"* ]]
}

@test "an arc already answered either way is not asked again" {
    run wa '
a = arc("A")
a["residue"] = {"at": 1, "note": "", "branches": ["A-branch"]}
print(asked([a]))
print(asked([arc("B")], pinned={"B": {}}))
'
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | grep -c "(\[\], '')")" -eq 2 ]]
}

# ── the abstentions ───────────────────────────────────────────────────────────

@test "no ledger means no questions about intent, and it says so" {
    # Every test above is an exclusion, so missing evidence does not make the queue
    # shorter -- it lets through exactly the work that would have been excluded.
    run wa 'print(asked([arc("A")], None))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"([], "* ]]
    [[ "$output" == *"ledger is incomplete"* ]]
}

@test "a ledger that came back short is as good as none" {
    # The same judgement apply_dismissals makes: a source that half-answered cannot
    # support a claim about anything it might have been missing.
    run wa 'print(asked([arc("A")], {"complete": False, "you_owe": [], "they_owe": []}))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ledger is incomplete"* ]]
}

@test "Jira unasked means no questions about intent, and it says so" {
    run wa 'print(asked([arc("A")], LEDGER, False))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"([], "* ]]
    [[ "$output" == *"whether a sprint claims this work cannot be known"* ]]
}

@test "GitLab unasked means no questions about intent, and it says so" {
    # With --no-mr every arc has an empty MR list, so "never proposed" would be asserted
    # of work that is out for review right now.
    run wa 'print(asked([arc("A", mrs_known=False)]))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"([], "* ]]
    [[ "$output" == *"whether this work was ever proposed cannot be known"* ]]
}

# ── the order and the cap ─────────────────────────────────────────────────────

@test "the coldest against its own rhythm is asked first" {
    run wa '
q, _ = wa.residue_queue([arc("STEADY", cliff=20, gap=4), arc("STOPPED", cliff=20, gap=1)],
                        LEDGER, True)
print([x["arc"] for x in q])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['STOPPED', 'STEADY']"* ]]
}

@test "the residue queue is capped on its own before it is merged" {
    run wa '
print(len(wa.residue_queue([arc("A%d" % i) for i in range(9)], LEDGER, True)[0]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"5"* ]]
}

@test "one shared cap across both question types, membership first" {
    # A budget of attention, not a budget of question types: five is what fits on a
    # screen, and ten questions in two sections is the backlog this was designed not to
    # become. Membership leads because a branch in the wrong arc poisons the residue
    # question too -- "is this workstream intended?" is unanswerable about a workstream
    # that is two pieces of work.
    run wa '
mem = [{"kind": "membership", "branch": "b%d" % i, "arc": "M%d" % i} for i in range(4)]
res = [{"kind": "residue", "arc": "R%d" % i} for i in range(4)]
print([q.get("branch") or q["arc"] for q in wa.combined_queue(mem, res)])
print([q.get("branch") or q["arc"] for q in wa.combined_queue(mem[:1], res)])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['b0', 'b1', 'b2', 'b3', 'R0']"* ]]
    [[ "$output" == *"['b0', 'R0', 'R1', 'R2', 'R3']"* ]]
}

# ── what an answer does ───────────────────────────────────────────────────────

@test "residue takes the work out of the debt numbers and leaves the branches alone" {
    run wa '
a = arc("A", branches=[br("A-one"), br("A-two")])
print("before", a["stage"], a["unpushed_live"], wa.only_here([a]))
for b in a["branches"]:
    b["residue"] = True
a["residue"] = {"at": 1, "note": "", "branches": ["A-one", "A-two"]}
wa.finalize(a)
print("after", a["stage"], a["unpushed_live"], a["unpushed_days"], wa.only_here([a]))
print("still here", len(a["branches"]), a["residue_commits"])
print("state", a["state"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"before local-only 6 ['A']"* ]]
    [[ "$output" == *"after residue 0 0 []"* ]]
    # Nothing was deleted, and the figure that stopped counting is still on the arc so the
    # card has something to strike through. De-emphasis is not hiding.
    [[ "$output" == *"still here 2 6"* ]]
    [[ "$output" == *"state residue"* ]]
}

@test "residue silences the demand for the work as well as the count" {
    # A commit you are not going to push is not a thing waiting on you.
    run wa '
a = arc("A")
print([d["kind"] for d in a["demands"]])
a["branches"][0]["residue"] = True
a["residue"] = {"at": 1, "note": "", "branches": ["A-branch"]}
wa.finalize(a)
print([d["kind"] for d in a["demands"]])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['unpushed']"* ]]
    [[ "$output" == *"[]"* ]]
}

@test "residue work is never accused of having been forgotten" {
    # The feature's own worst failure mode would be a false accusation on the one arc a
    # person has already told it about.
    run wa '
a = arc("A")
a["activity"]["invested"] = {"entries": 4000, "sessions": 6, "commits": 90, "days": 12}
a["activity"]["cliff_days"] = 30
wa.mark_forgotten(a)
print("plain", a["activity"]["forgotten"]["verdict"])
a["residue"] = {"at": 1, "note": "", "branches": ["A-branch"]}
wa.mark_forgotten(a)
print("residue", a["activity"]["forgotten"]["verdict"],
      a["activity"]["forgotten"]["why"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"plain True"* ]]
    [[ "$output" == *"residue False"* ]]
    [[ "$output" == *"never meant to land"* ]]
}

@test "residue is not swallowed by the superseded-copy figure" {
    # That number says what deleting the copies would cost, which is a claim about the
    # repo. Leaving declared residue inside it would credit a person's judgement to a
    # derivation and overstate the one figure on the card that exists to answer it.
    run wa '
a = arc("A", branches=[br("A-one"), br("A-two")])
a["branches"][0]["residue"] = True
a["residue"] = {"at": 1, "note": "", "branches": ["A-one"]}
wa.finalize(a)
print(a["unpushed_only_on_copies"], a["residue_commits"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 3"* ]]
}

# ── both answer paths ─────────────────────────────────────────────────────────

@test "n records residue, y records intent, and both reach the eval set" {
    # An eval set of corrections alone would score a detector that called everything
    # residue as perfect. "Yes, this is real work" is the half that makes the other mean
    # something.
    fake_fzf

    FAKE_KEY=n run wa '
q, _ = wa.residue_queue([arc("A")], LEDGER, True)
wa.curate(q, {})
print(sorted(json.loads(wa.RESIDUE.read_text())))
print([json.loads(x)["answer"] for x in wa.CURATION_LABELS.read_text().splitlines()])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['A']"* ]]
    [[ "$output" == *"['residue']"* ]]

    FAKE_KEY=y run wa '
q, _ = wa.residue_queue([arc("A")], LEDGER, True)
wa.curate(q, {})
print(sorted(json.loads(wa.INTENDED.read_text())),
      sorted(json.loads(wa.RESIDUE.read_text())))
print([json.loads(x)["answer"] for x in wa.CURATION_LABELS.read_text().splitlines()])
'
    [ "$status" -eq 0 ]
    # The pin lands, the residue mark the first half wrote is cleared, and the log keeps
    # both verdicts -- the two answers to one question are the record.
    [[ "$output" == *"['A'] []"* ]]
    [[ "$output" == *"['residue', 'intended']"* ]]
}

@test "a skipped intent question leaves no record at all" {
    # Painlessness is the feature, and it is more load-bearing here than for membership:
    # this question asks a person to write work off, and one that cost something to
    # decline would be answered carelessly.
    fake_fzf
    FAKE_KEY=s run wa '
q, _ = wa.residue_queue([arc("A")], LEDGER, True)
wa.curate(q, {})
print(wa.RESIDUE.exists(), wa.INTENDED.exists(), wa.CURATION_LABELS.exists())
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"False False False"* ]]
}

@test "an intent answer is logged as one, not as a membership verdict" {
    # arc-cluster replays the eval set against a clustering. An intent answer scored as a
    # keep or a pry would be a made-up disagreement about a grouping nobody ruled on.
    fake_fzf
    FAKE_KEY=n run wa '
q, _ = wa.residue_queue([arc("A")], LEDGER, True)
wa.curate(q, {})
row = json.loads(wa.CURATION_LABELS.read_text().splitlines()[0])
print(row["kind"], row["answer"], row.get("branch"), row["arc"], row["via"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"residue residue None A cli"* ]]
}

@test "a mixed queue answers each row by its own kind" {
    fake_fzf
    FAKE_KEY=n run wa '
mem = [{"kind": "membership", "branch": "stray", "arc": "M", "arc_id": "M", "fp": "f1",
        "confidence": 0.1, "why": "held by 2 shared files", "with": "p1", "shared": 2,
        "files": [], "links": 1, "peers": 2, "commits": 3, "age_days": 4,
        "flagged_by_model": False, "authoritative": False}]
res, _ = wa.residue_queue([arc("A")], LEDGER, True)
wa.curate(wa.combined_queue(mem, res), {"stray": "M", "p1": "M"})
print(sorted(json.loads(wa.DETACHED.read_text())))
print(sorted(json.loads(wa.RESIDUE.read_text())))
rows = [json.loads(x) for x in wa.CURATION_LABELS.read_text().splitlines()]
print(sorted((r["kind"], r["answer"]) for r in rows))
'
    [ "$status" -eq 0 ]
    # n on the membership row writes a detachment; n on the intent row writes a residue
    # mark. One keystroke vocabulary, two stores, and neither answer reached the other.
    [[ "$output" == *"['stray']"* ]]
    [[ "$output" == *"['A']"* ]]
    [[ "$output" == *"[('membership', 'pry'), ('residue', 'residue')]"* ]]
}

@test "no fzf prints both kinds of question rather than failing the build" {
    run wa '
wa.fzf_bin = lambda: None
res, _ = wa.residue_queue([arc("A")], LEDGER, True)
wa.curate(res, {})
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"fzf is not installed"* ]]
    [[ "$output" == *"still intended work?"* ]]
}

# ── the expiry ────────────────────────────────────────────────────────────────

@test "a residue mark applies while the work it was a claim about stands" {
    run wa '
a = arc("A")
wa.answer_residue({"arc_id": "A", "arc": "A", "fp": "q", "fingerprint": a["fingerprint"],
                   "branches": ["A-branch"], "days": 0, "commits": 3, "cliff_days": 20,
                   "gap_days": 2, "why": "w"}, False)
b = arc("A")
print(wa.apply_residue([b]), b["stage"], b["unpushed_live"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[] residue 0"* ]]
}

@test "a commit on the work undoes the residue mark by itself, out loud" {
    # Derived beats declared. The one thing a person should never have to remember is to
    # withdraw a judgement the evidence has already withdrawn.
    run wa '
a = arc("A")
wa.answer_residue({"arc_id": "A", "arc": "A", "fp": "q", "fingerprint": a["fingerprint"],
                   "branches": ["A-branch"], "days": 0, "commits": 3, "cliff_days": 20,
                   "gap_days": 2, "why": "w"}, False)
b = arc("A", branches=[br("A-branch", sha="s2")])
stale = wa.apply_residue([b])
print(stale[0]["why"])
print(b["stage"], b["unpushed_live"])
print(json.loads(wa.RESIDUE.read_text()))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"work you went back to is work you meant"* ]]
    [[ "$output" == *"local-only 3"* ]]
    # And it drops itself, so it cannot come back the next time the tips happen to match.
    [[ "$output" == *"{}"* ]]
}

@test "an answer survives the split pass rewording the arc" {
    # Arc ids are cluster labels and the split pass rewrites them between runs --
    # "selected state" became "selected-state" within an evening. Keyed on the id alone a
    # rewording would lose the answer silently, which is the failure the membership
    # stores' own contract exists to rule out. The tips are the referent, so they are
    # also the last resort for finding the entry about them.
    run wa '
a = arc("selected state")
wa.answer_residue({"arc_id": "selected state", "arc": "selected state", "fp": "q",
                   "fingerprint": a["fingerprint"],
                   "branches": ["selected state-branch"], "days": 0, "commits": 3,
                   "cliff_days": 20, "gap_days": 2, "why": "w"}, False)
b = arc("selected-state", branches=[br("selected state-branch")])
print(wa.apply_residue([b]), b["stage"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"[] residue"* ]]
}

@test "a pin expires the same way, and the commit that expired it is the better proof" {
    run wa '
a = arc("A")
wa.answer_residue({"arc_id": "A", "arc": "A", "fp": "q", "fingerprint": a["fingerprint"],
                   "branches": ["A-branch"], "days": 0, "commits": 3, "cliff_days": 20,
                   "gap_days": 2, "why": "w"}, True)
b = arc("A")
live, stale = wa.apply_intended([b])
print(sorted(live), stale)
c = arc("A", branches=[br("A-branch", sha="s9")])
live, stale = wa.apply_intended([c])
print(sorted(live), stale[0]["why"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['A'] []"* ]]
    [[ "$output" == *"[] a commit has landed"* ]]
}

@test "an entry no workstream claimed this run is left alone rather than swept" {
    # An arc absent from one run is usually a --no-cluster run, a branch checked out
    # elsewhere or a half-fetched repo. Deleting a human judgement on that evidence is
    # the one thing these stores may never do.
    run wa '
a = arc("A")
wa.answer_residue({"arc_id": "A", "arc": "A", "fp": "q", "fingerprint": a["fingerprint"],
                   "branches": ["A-branch"], "days": 0, "commits": 3, "cliff_days": 20,
                   "gap_days": 2, "why": "w"}, False)
b = arc("A", branches=[br("A-branch", sha="s2")])
wa.apply_residue([arc("UNRELATED"), b])
print(sorted(json.loads(wa.RESIDUE.read_text())))
'
    [ "$status" -eq 0 ]
    # A's entry went because A itself was seen and had moved; nothing else was touched.
    [[ "$output" == *"[]"* ]]
}

@test "a pinned and a residue answer cannot both stand for one workstream" {
    run wa '
q = {"arc_id": "A", "arc": "A", "fp": "q", "fingerprint": "fp", "branches": ["A-branch"],
     "days": 0, "commits": 3, "cliff_days": 20, "gap_days": 2, "why": "w"}
wa.answer_residue(q, False)
wa.answer_residue(q, True)
print(sorted(json.loads(wa.INTENDED.read_text())),
      sorted(json.loads(wa.RESIDUE.read_text())))
wa.answer_residue(q, False)
print(sorted(json.loads(wa.INTENDED.read_text())),
      sorted(json.loads(wa.RESIDUE.read_text())))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['A'] []"* ]]
    [[ "$output" == *"[] ['A']"* ]]
}

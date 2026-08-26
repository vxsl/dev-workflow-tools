#!/usr/bin/env bats
# Tests for guided curation -- the confidence ranking in arc-cluster, and the queue,
# the pins and the eval log in work-arcs.
#
# The feature exists because the clustering's residual error has one shape that no
# threshold reaches: two tickets editing the same module are identical by file overlap
# however the weights are set. So the system publishes where it is least sure instead of
# tuning, and a human answers five questions a build. That makes three things worth
# pinning, and each of them is a way the loop stops being painless rather than a way it
# computes a wrong number:
#
#   never-question   asking about a fact is worse than asking nothing. Ancestry, the
#                    arc's own ticket, the authoritative branch and superseded copies
#                    are facts; a question about one of them spends the day's attention
#                    on something with no answer but yes.
#   the cap and the  five, one per arc. The corpus has fifty-odd eligible memberships
#   spread           and a queue that showed them all is a backlog nobody opens; two
#                    questions about one arc is the same question twice, since answering
#                    the first changes the evidence for the second.
#   expiry           a pin is permanent only while it still refers to something. The
#                    moment the branch's company changes, a confirmation is vouching for
#                    a grouping it never saw, which is exactly what the detachment
#                    contract was built to prevent.
#
# And one that is about the number: both answers are logged, because an eval set of
# corrections alone would score a clusterer that splits everything into singletons as
# perfect.
#
# The functions are called directly. curation_queue, membership and the stores are pure
# over their inputs, and reaching them through the CLI would mean standing up a git repo,
# a GitLab and a Jira to test a ranking.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    # No test may read or write the real stores. work-arcs resolves DETACHED, CONFIRMED
    # and CURATION_LABELS at import time, so this is exported before the module loads.
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
}

teardown() {
    teardown_temp_dir
}

# Runs a python snippet with work-arcs imported as wa and some arc fixtures in scope.
wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" <<PY
import importlib.machinery, importlib.util, sys, json
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
sys.argv = ["wa"]
loader.exec_module(wa)

def br(name, **kw):
    d = {"name": name, "commits_ahead": 3, "age_days": 10}
    d.update(kw)
    return d

def arc(ident, branches, kind="cluster", label=None):
    return {"id": ident, "label": label or ident, "kind": kind,
            "branches": list(branches)}

def m(conf, **kw):
    """One membership record, the shape arc-cluster emits."""
    d = {"confidence": conf, "why": "held by 2 shared files", "with": None,
         "shared": 2, "files": ["a.ts", "b.ts"], "links": 2, "peers": 3,
         "ancestry": False, "named": False}
    d.update(kw)
    return d

def names(queue):
    return [q["branch"] for q in queue]

$1
PY
}

# A stand-in for fzf that answers with $FAKE_KEY on the first row and exits, so the
# keystroke flow can be driven from a test. Built with printf rather than a heredoc:
# every helper in this repo that writes a shell script from a bats file is one edit away
# from a backtick or a $( ) that the outer heredoc eats, and the failure lands on every
# test in the file at once rather than on the one that introduced it.
fake_fzf() {
    {
        echo '#!/usr/bin/env bash'
        echo 'first=$(head -1)'
        printf '%s\n' 'printf "%s\n%s\n" "$FAKE_KEY" "$first"'
    } > "$TEST_TMPDIR/fzf"
    chmod +x "$TEST_TMPDIR/fzf"
    export FZP_FZF="$TEST_TMPDIR/fzf"
}

# Runs a python snippet with arc-cluster imported as ac.
ac() {
    python3 - "$REPO_ROOT/bin/arc-cluster" <<PY
import importlib.machinery, importlib.util, sys, json, collections
loader = importlib.machinery.SourceFileLoader("ac", sys.argv[1])
spec = importlib.util.spec_from_loader("ac", loader)
ac = importlib.util.module_from_spec(spec)
sys.argv = ["ac"]
loader.exec_module(ac)

def graph(files_by_branch, stacks=(), sims=None, margins=None, label="UB-1000"):
    """A one-arc world: branch -> its distinctive files, plus what holds it together.

    Every file is rare (df of 1 or 2 against a large N), so nothing is discounted as a
    hub unless a test says so, and the only thing separating memberships is how many
    files a pair actually shares.
    """
    ents = {("branch", b): set(fs) for b, fs in files_by_branch.items()}
    members = list(ents)
    N = 400
    df = collections.Counter()
    for fs in ents.values():
        for f in fs:
            df[f] += 1
    idf = {f: 5.0 for f in df}
    if sims is None:
        sims = {}
        for i, a in enumerate(members):
            for b in members[i + 1:]:
                if ents[a] & ents[b]:
                    sims[(a, b) if a < b else (b, a)] = 0.5
    stackset = set()
    for c, p in stacks:
        stackset.add((("branch", c), ("branch", p)))
        stackset.add((("branch", p), ("branch", c)))
    margins = {("branch", b): v for b, v in (margins or {}).items()}
    margins = {k: margins.get(k, 1.0) for k in members}
    return ac.membership(members, ents, idf, df, N, int(N * ac.HUB_SHARE),
                         sims, margins, stackset, label)

$1
PY
}

# ── never question a fact ─────────────────────────────────────────────────────

@test "a branch cut from another in the same arc is never questioned" {
    # Ancestry is a fact, not an inference: the branch was literally cut from the one
    # beside it. Weighting it heavily is not enough -- enforce_stacks applies it as a
    # constraint after the partition precisely because modularity may overrule a hint,
    # and a question about it would be asking whether git is telling the truth.
    run ac '
mm = graph({"UB-1000": ["x.ts", "y.ts", "z.ts"], "side-branch": ["x.ts", "q.ts"]},
           stacks=[("side-branch", "UB-1000")])
print(mm["side-branch"]["confidence"], mm["side-branch"]["ancestry"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == "1.0 True"* ]]
}

@test "a branch whose own name carries the arc's ticket is never questioned" {
    # The arc is named after this branch. It cannot be in the wrong arc; at most the arc
    # has the wrong other members, and that is a question about them.
    run ac '
mm = graph({"UB-1000": ["x.ts", "y.ts"], "UB-1000-followup": ["x.ts", "w.ts"]})
print(mm["UB-1000"]["confidence"], mm["UB-1000"]["named"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == "1.0 True"* ]]
}

@test "a superseded copy never reaches the queue" {
    # Whether a branch is a copy depends on patch-ids, which is work-arcs' to see and not
    # the clusterer's. A backup shares its original's files and nothing else, so it would
    # otherwise sit near the top of every queue -- asking the question its original has
    # already been asked.
    run wa '
mem = {"the-work": m(1.0), "the-work-bak": m(0.05), "stranger": m(0.05)}
a = arc("UB-1000", [br("the-work"), br("the-work-bak", superseded_by="the-work"),
                    br("stranger")])
print(names(wa.curation_queue([a], mem, {})))
'
    [ "$status" -eq 0 ]
    [[ "$output" == "['stranger']" ]]
}

@test "a thin authoritative branch is asked about, and the question says what it costs" {
    # Authority follows the newest merge request, not the weight of the work, so an arc's
    # subject can be decided by a stranger: UL-1852 is two commits of geo_filter migration
    # holding a fifteen-branch metadata-geometry arc'"'"'s merge request, in on the two-file
    # floor. Excluding the authoritative branch hid exactly that -- the one case where the
    # arc is wrong about its own subject, which is worse than a stranger merely standing
    # in it.
    run wa '
mem = {"stranger": m(0.05), "the-bulk": m(1.0)}
a = arc("UB-1000", [br("stranger", authoritative=True), br("the-bulk")])
q = wa.curation_queue([a], mem, {})
print(names(q), q[0]["authoritative"])
print("MR" in wa.question_line(q[0]), "merge request" in wa.question_preview(q[0]))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['stranger'] True"* ]]
    [[ "$output" == *"True True"* ]]
}

@test "a well-corroborated authoritative branch is still never asked about" {
    # The score does the work the exclusion used to: measured on this corpus, 51 of 64
    # authoritative branches in clustered arcs are above the line on their own evidence.
    run wa '
mem = {"the-work": m(0.9), "other": m(1.0)}
a = arc("UB-1000", [br("the-work", authoritative=True), br("other")])
print(names(wa.curation_queue([a], mem, {})))
'
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

@test "an arc the clustering did not group is not asked about at all" {
    # A ticket-named or prefix-named arc was never a claim about file overlap, so there
    # is no derivation to doubt. Asking would be asking whether a branch is named what
    # it is named.
    run wa '
mem = {"a": m(0.01), "b": m(0.01)}
a = arc("UB-1000", [br("a"), br("b")], kind="ticket")
print(names(wa.curation_queue([a], mem, {})))
'
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

# ── the ranking ───────────────────────────────────────────────────────────────

@test "the queue is least confident first" {
    run wa '
mem = {"a": m(0.30), "b": m(0.05), "c": m(0.20)}
arcs = [arc("A", [br("a")]), arc("B", [br("b")]), arc("C", [br("c")])]
for x in arcs:
    x["branches"].append(br("anchor-" + x["id"]))
    mem["anchor-" + x["id"]] = m(1.0)
print(names(wa.curation_queue(arcs, mem, {})))
'
    [ "$status" -eq 0 ]
    [[ "$output" == "['b', 'c', 'a']" ]]
}

@test "equally unconfident memberships are ordered by what you can still remember" {
    # The corpus has eleven memberships at the identical lowest score, all the same
    # shape, and nothing structural tells them apart -- that is the residual error, by
    # definition. What tells them apart is whether the person can answer: a branch
    # touched last week you remember, a two-month-old stub you would have to go and read
    # the diff for, and a question you have to research is a question that gets skipped.
    run wa '
mem = {"old": m(0.125), "recent": m(0.125), "middle": m(0.125)}
arcs = [arc("A", [br("old", age_days=70), br("anchor-a")]),
        arc("B", [br("recent", age_days=2), br("anchor-b")]),
        arc("C", [br("middle", age_days=20), br("anchor-c")])]
for k in ("anchor-a", "anchor-b", "anchor-c"):
    mem[k] = m(1.0)
print(names(wa.curation_queue(arcs, mem, {})))
'
    [ "$status" -eq 0 ]
    [[ "$output" == "['recent', 'middle', 'old']" ]]
}

@test "a confident membership is not asked about" {
    run wa '
mem = {"solid": m(0.9), "anchor": m(1.0)}
print(names(wa.curation_queue([arc("A", [br("solid"), br("anchor")])], mem, {})))
'
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

@test "the model's own doubt makes a membership eligible without letting it take over" {
    # The split pass read the commits, kept the branch and said it could not justify
    # keeping it. That is a verdict about content, which file overlap cannot see, so it
    # earns a place in the queue whatever the structure says -- but it does not jump the
    # ones the clusterer is genuinely unsure about, or a model that turned talkative
    # would fill every slot with memberships nothing is wrong with.
    run wa '
mem = {"flagged": m(0.95), "thin": m(0.05), "anchor-a": m(1.0), "anchor-b": m(1.0)}
arcs = [arc("A", [br("flagged"), br("anchor-a")]),
        arc("B", [br("thin"), br("anchor-b")])]
print(names(wa.curation_queue(arcs, mem, {}, uncertain=["flagged"])))
'
    [ "$status" -eq 0 ]
    [[ "$output" == "['thin', 'flagged']" ]]
}

@test "a question whose named neighbour has left the arc is not asked" {
    # The claim being tested is "this branch is the same work as that one". If the split
    # pass has already separated the two, the split IS the answer, and the branch's
    # remaining membership rests on evidence nothing here has measured.
    run wa '
mem = {"stray": m(0.05, **{"with": "departed"}), "anchor": m(1.0)}
print(names(wa.curation_queue([arc("A", [br("stray"), br("anchor")])], mem, {})))
'
    [ "$status" -eq 0 ]
    [[ "$output" == "[]" ]]
}

# ── the whole queue and the spread ────────────────────────────────────────────

@test "the queue is every doubt there is, not a rationed five" {
    # The cap used to live here and pace the asking, back when every answer cost an fzf
    # round-trip or a rebuild. The page closed the loop, so pacing is presentation, and
    # presentation belongs where the rendering is -- a list truncated at emission could
    # never be un-truncated on the page.
    run wa '
mem, arcs = {}, []
for i in range(20):
    mem["b%d" % i] = m(0.01 + i / 1000.0)
    mem["anchor%d" % i] = m(1.0)
    arcs.append(arc("A%d" % i, [br("b%d" % i), br("anchor%d" % i)]))
q = wa.curation_queue(arcs, mem, {})
print(len(q), hasattr(wa, "CURATION_CAP"))
'
    [ "$status" -eq 0 ]
    [[ "$output" == "20 False" ]]
}

@test "one question per arc, so two branches holding each other up are asked once" {
    # UL-1810 and UL-1810-prerebase are each other'"'"'s only evidence, and the first queue
    # this ever produced asked about both: two keystrokes to settle one thing, the second
    # asked against evidence the first had already changed.
    run wa '
mem = {"UL-1810": m(0.125, **{"with": "UL-1810-prerebase"}),
       "UL-1810-prerebase": m(0.125, **{"with": "UL-1810"}),
       "elsewhere": m(0.13), "anchor": m(1.0), "anchor2": m(1.0)}
arcs = [arc("A", [br("UL-1810"), br("UL-1810-prerebase"), br("anchor")]),
        arc("B", [br("elsewhere"), br("anchor2")])]
print(names(wa.curation_queue(arcs, mem, {})))
'
    [ "$status" -eq 0 ]
    [[ "$output" == "['UL-1810', 'elsewhere']" ]]
}

@test "nothing below the line means no queue at all, not an empty one" {
    # The renderer tests for a section that exists rather than for a length, so a build
    # with nothing to ask is silent -- no heading, no empty state, nothing.
    run wa '
mem = {"a": m(1.0), "b": m(0.9)}
print(wa.curation_queue([arc("A", [br("a"), br("b")])], mem, {}) or "absent")
'
    [ "$status" -eq 0 ]
    [[ "$output" == "absent" ]]
}

# ── pins, and how they die ────────────────────────────────────────────────────

@test "a confirmed membership is not asked about again" {
    run wa '
q = {"branch": "kept", "arc": "A", "fp": "f1", "confidence": 0.1}
assign = {"kept": "A", "other": "A", "third": "A"}
wa.answer_question(q, True, assign)
pinned, stale = wa.apply_confirmed(assign)
print(sorted(pinned), stale)
mem = {"kept": m(0.05), "anchor": m(1.0)}
mem = {k: v for k, v in mem.items() if k not in pinned}
print(names(wa.curation_queue([arc("A", [br("kept"), br("anchor")])], mem, assign)))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['kept'] []"* ]]
    [[ "$output" == *"[]"* ]]
}

@test "a pin survives the arc being renamed" {
    # The split pass rewords labels between runs -- "selected state" became
    # "selected-state" within an evening -- and an answer must not expire over a
    # rewording. The referent is the company the branch keeps, never the name.
    run wa '
q = {"branch": "kept", "arc": "old name", "fp": "f1", "confidence": 0.1}
wa.answer_question(q, True, {"kept": "old name", "p1": "old name", "p2": "old name"})
pinned, stale = wa.apply_confirmed({"kept": "new name", "p1": "new name",
                                    "p2": "new name"})
print(sorted(pinned), stale)
'
    [ "$status" -eq 0 ]
    [[ "$output" == "['kept'] []" ]]
}

@test "a pin expires once half its recorded company has gone" {
    # The point of the whole expiry contract: a confirmation whose neighbourhood has
    # changed is vouching for a grouping it never saw. It dies by itself and says so,
    # rather than quietly outvoting evidence that arrived after it.
    run wa '
q = {"branch": "kept", "arc": "A", "fp": "f1", "confidence": 0.1}
wa.answer_question(q, True, {"kept": "A", "p1": "A", "p2": "A", "p3": "A", "p4": "A"})
pinned, stale = wa.apply_confirmed({"kept": "A", "p1": "A", "n1": "A", "n2": "A"})
print(sorted(pinned), [s["branch"] for s in stale])
'
    [ "$status" -eq 0 ]
    [[ "$output" == "[] ['kept']" ]]
}

@test "a pin held by most of its recorded company survives" {
    run wa '
q = {"branch": "kept", "arc": "A", "fp": "f1", "confidence": 0.1}
wa.answer_question(q, True, {"kept": "A", "p1": "A", "p2": "A", "p3": "A", "p4": "A"})
pinned, stale = wa.apply_confirmed({"kept": "A", "p1": "A", "p2": "A", "p3": "A",
                                    "n1": "A"})
print(sorted(pinned), [s["branch"] for s in stale])
'
    [ "$status" -eq 0 ]
    [[ "$output" == "['kept'] []" ]]
}

@test "a branch cannot be both pinned and pried" {
    # The two stores are one contract pointing in opposite directions. A branch in both
    # would be a page that shows it as kept and a build that detaches it.
    run wa '
q = {"branch": "b", "arc": "A", "fp": "f1", "confidence": 0.1}
assign = {"b": "A", "p1": "A"}
wa.answer_question(q, False, assign)
wa.answer_question(q, True, assign)
print(sorted(json.loads(wa.CONFIRMED.read_text())),
      sorted(json.loads(wa.DETACHED.read_text())))
wa.answer_question(q, False, assign)
print(sorted(json.loads(wa.CONFIRMED.read_text())),
      sorted(json.loads(wa.DETACHED.read_text())))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['b'] []"* ]]
    [[ "$output" == *"[] ['b']"* ]]
}

# ── the eval set ──────────────────────────────────────────────────────────────

@test "both answers are logged, not only the corrections" {
    # The half that makes the labels an eval set. Scored on prys alone, a clusterer that
    # split everything into singletons would agree with every correction and be useless;
    # the keeps are what stop that.
    run wa '
assign = {"a": "A", "b": "A", "p": "A"}
wa.answer_question({"branch": "a", "arc": "A", "fp": "f1", "confidence": 0.1}, False,
                   assign)
wa.answer_question({"branch": "b", "arc": "A", "fp": "f2", "confidence": 0.2}, True,
                   assign)
rows = [json.loads(x) for x in wa.CURATION_LABELS.read_text().splitlines()]
print([(r["branch"], r["answer"]) for r in rows])
'
    [ "$status" -eq 0 ]
    [[ "$output" == "[('a', 'pry'), ('b', 'keep')]" ]]
}

@test "the log is append-only, so changing your mind keeps both answers" {
    # An overwrite would lose the fact that the question was asked twice, which is the
    # one thing a disagreement between two verdicts can teach.
    run wa '
assign = {"a": "A", "p": "A"}
q = {"branch": "a", "arc": "A", "fp": "f1", "confidence": 0.1}
wa.answer_question(q, False, assign)
wa.answer_question(q, True, assign)
rows = [json.loads(x) for x in wa.CURATION_LABELS.read_text().splitlines()]
print(len(rows), [r["answer"] for r in rows])
'
    [ "$status" -eq 0 ]
    [[ "$output" == "2 ['pry', 'keep']" ]]
}

@test "an answer records the evidence it was given, not just the verdict" {
    # A label with no evidence cannot be re-scored against a changed clusterer -- it
    # would say a human once disagreed and nothing about what they were shown.
    run wa '
q = {"branch": "a", "arc": "A", "fp": "f1", "confidence": 0.125,
     "why": "held by 2 shared files", "shared": 2, "files": ["x.ts", "y.ts"]}
wa.answer_question(q, False, {"a": "A", "p1": "A"})
r = json.loads(wa.CURATION_LABELS.read_text().splitlines()[0])
print(r["confidence"], r["shared"], r["files"], r["with"], r["why"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == "0.125 2 ['x.ts', 'y.ts'] ['p1'] held by 2 shared files" ]]
}

@test "the question fingerprint tracks the claim, not the arc's name" {
    run wa '
same = wa.question_fp("b", ["p1", "p2"]) == wa.question_fp("b", ["p2", "p1"])
moved = wa.question_fp("b", ["p1", "p2"]) == wa.question_fp("b", ["p1", "p9"])
print(same, moved)
'
    [ "$status" -eq 0 ]
    [[ "$output" == "True False" ]]
}

# ── answering, one keystroke at a time ────────────────────────────────────────

@test "n records a detachment, y a confirmation, and both reach the eval set" {
    # The keystroke flow end to end, driven through the same $FZP_FZF override
    # lib/fzf-helpers documents -- an interface nobody can script is an interface nobody
    # can regression-test.
    fake_fzf

    FAKE_KEY=n run wa '
q = [{"branch": "stray", "arc": "A", "arc_id": "A", "fp": "f1", "confidence": 0.1,
      "why": "held by 2 shared files", "with": "p1", "shared": 2, "files": ["x.ts"],
      "links": 1, "peers": 2, "commits": 3, "age_days": 4, "flagged_by_model": False,
      "authoritative": False}]
wa.curate(q, {"stray": "A", "p1": "A", "p2": "A"})
print(sorted(json.loads(wa.DETACHED.read_text())))
print([json.loads(x)["answer"] for x in wa.CURATION_LABELS.read_text().splitlines()])
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['stray']"* ]]
    [[ "$output" == *"['pry']"* ]]

    FAKE_KEY=y run wa '
q = [{"branch": "stray", "arc": "A", "arc_id": "A", "fp": "f1", "confidence": 0.1,
      "why": "held by 2 shared files", "with": "p1", "shared": 2, "files": ["x.ts"],
      "links": 1, "peers": 2, "commits": 3, "age_days": 4, "flagged_by_model": False,
      "authoritative": False}]
wa.curate(q, {"stray": "A", "p1": "A", "p2": "A"})
print(sorted(json.loads(wa.CONFIRMED.read_text())),
      sorted(json.loads(wa.DETACHED.read_text())))
print([json.loads(x)["answer"] for x in wa.CURATION_LABELS.read_text().splitlines()])
'
    [ "$status" -eq 0 ]
    # The pin lands, the detachment the first half of this test wrote is cleared, and the
    # log keeps both answers -- the two verdicts on one question are the record.
    [[ "$output" == *"['stray'] []"* ]]
    [[ "$output" == *"['pry', 'keep']"* ]]
}

@test "skip and escape leave no record at all" {
    # Painlessness is the feature. A skipped question must cost nothing -- no store
    # entry, no label, no nag -- or the queue becomes something to get through rather
    # than something to answer.
    fake_fzf

    FAKE_KEY=s run wa '
q = [{"branch": "stray", "arc": "A", "arc_id": "A", "fp": "f1", "confidence": 0.1,
      "why": "w", "with": "p1", "shared": 2, "files": [], "links": 1, "peers": 2,
      "commits": 1, "age_days": 4, "flagged_by_model": False, "authoritative": False}]
wa.curate(q, {"stray": "A", "p1": "A"})
print(wa.DETACHED.exists(), wa.CONFIRMED.exists(), wa.CURATION_LABELS.exists())
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"False False False"* ]]
}

@test "no fzf prints the questions rather than failing the build" {
    run wa '
wa.fzf_bin = lambda: None
q = [{"branch": "stray", "arc": "A", "arc_id": "A", "fp": "f1", "confidence": 0.1,
      "why": "held by 2 shared files", "with": "p1", "shared": 2, "files": [],
      "links": 1, "peers": 2, "commits": 3, "age_days": 4, "flagged_by_model": False,
      "authoritative": False}]
wa.curate(q, {})
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"fzf is not installed"* ]]
    [[ "$output" == *"stray"* ]]
}

@test "an answer given on the page is caught up into the eval set" {
    # The page saves confirmed.json and detached.json through the browser download, which
    # cannot append to a log; --detach predates the eval set entirely. An eval set that
    # only saw one command would under-count exactly the surface a person used.
    run wa '
wa.CONFIRMED.write_text(json.dumps(
    {"kept": {"from": "A", "with": ["p1", "p2"], "at": 111}}))
wa.DETACHED.write_text(json.dumps(
    {"pried": {"from": "A", "with": ["p1", "p2"], "at": 222}}))
print(wa.log_from_stores(), wa.log_from_stores())
rows = [json.loads(x) for x in wa.CURATION_LABELS.read_text().splitlines()]
print(sorted((r["branch"], r["answer"], r["via"]) for r in rows))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 0"* ]]
    [[ "$output" == *"[('kept', 'keep', 'store'), ('pried', 'pry', 'store')]"* ]]
}

# ── scoring a clustering against the answers ─────────────────────────────────

@test "score-labels counts both agreement and disagreement" {
    run ac '
import io, contextlib, json
from pathlib import Path
labels = Path("'"$TEST_TMPDIR"'/labels.jsonl")
labels.write_text("\n".join([
    json.dumps({"at": 1, "answer": "keep", "branch": "kept", "arc": "A", "fp": "f1",
                "with": ["p1", "p2"]}),
    json.dumps({"at": 2, "answer": "pry", "branch": "pried", "arc": "A", "fp": "f2",
                "with": ["p1", "p2"]}),
]) + "\n")
arcs = [{"label": "A", "branches": ["kept", "pried", "p1", "p2"]}]
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    ac.score_labels(arcs, labels)
print(buf.getvalue().splitlines()[0])
'
    [ "$status" -eq 0 ]
    [[ "$output" == "1/2 agree (50%)" ]]
}

@test "a branch that has left the corpus is unscorable, never a regression" {
    run ac '
import io, contextlib, json
from pathlib import Path
labels = Path("'"$TEST_TMPDIR"'/labels.jsonl")
labels.write_text(json.dumps({"at": 1, "answer": "keep", "branch": "deleted",
                              "arc": "A", "fp": "f1", "with": ["p1"]}) + "\n")
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    ac.score_labels([{"label": "A", "branches": ["p1"]}], labels)
print(buf.getvalue().strip())
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"none scorable"* ]]
}

@test "only the latest answer to a question is scored" {
    # A person is allowed to change their mind, and a question legitimately returns once
    # its pin expires. Scoring both verdicts would score the clusterer against a
    # contradiction it cannot satisfy.
    run ac '
import io, contextlib, json
from pathlib import Path
labels = Path("'"$TEST_TMPDIR"'/labels.jsonl")
labels.write_text("\n".join([
    json.dumps({"at": 1, "answer": "pry", "branch": "b", "arc": "A", "fp": "f1",
                "with": ["p1", "p2"]}),
    json.dumps({"at": 2, "answer": "keep", "branch": "b", "arc": "A", "fp": "f1",
                "with": ["p1", "p2"]}),
]) + "\n")
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    ac.score_labels([{"label": "A", "branches": ["b", "p1", "p2"]}], labels)
print(buf.getvalue().splitlines()[0])
'
    [ "$status" -eq 0 ]
    [[ "$output" == "1/1 agree (100%)" ]]
}

# ── the confidence terms themselves ──────────────────────────────────────────

@test "the corroboration floor scores lower than a module's worth of overlap" {
    run ac '
mm = graph({"thin": ["a.ts", "b.ts"],
            "thick": ["a.ts", "b.ts", "c.ts", "d.ts", "e.ts", "f.ts"],
            "anchor": ["a.ts", "b.ts", "c.ts", "d.ts", "e.ts", "f.ts", "g.ts"]})
print(mm["thin"]["confidence"] < mm["thick"]["confidence"])
'
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]
}

@test "a branch hanging off one neighbour scores below one embedded in the arc" {
    run ac '
files = {"anchor": ["a.ts", "b.ts", "c.ts", "d.ts"],
         "embedded": ["a.ts", "b.ts", "c.ts", "d.ts"],
         "third": ["a.ts", "b.ts", "c.ts", "d.ts"],
         "leaf": ["a.ts", "b.ts", "c.ts", "d.ts", "z.ts"]}
mm = graph(files, sims={
    (("branch", "anchor"), ("branch", "embedded")): 0.5,
    (("branch", "anchor"), ("branch", "third")): 0.5,
    (("branch", "embedded"), ("branch", "third")): 0.5,
    (("branch", "anchor"), ("branch", "leaf")): 0.5,
})
print(mm["leaf"]["links"], mm["embedded"]["links"],
      mm["leaf"]["confidence"] < mm["embedded"]["confidence"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == "1 2 True" ]]
}

@test "doubt discounts a membership and can never sink it on its own" {
    # Both doubt signals are routinely true of correct memberships -- modularity margins
    # are small for every well-connected node at the boundary of two dense arcs, and a
    # stack legitimately carries one ticket'"'"'s commits across branches named for
    # another. As floors they buried the thin-evidence cases under boundary artefacts;
    # bounded, they reorder the queue without filling it.
    run ac '
files = {"unticketed": ["a.ts", "b.ts", "c.ts", "d.ts", "e.ts", "f.ts"],
         "UB-1000": ["a.ts", "b.ts", "c.ts", "d.ts", "e.ts", "f.ts"],
         "anchor": ["a.ts", "b.ts", "c.ts", "d.ts", "e.ts", "f.ts"]}
sure = graph(files, margins={"unticketed": 1.0})
tied = graph(files, margins={"unticketed": 0.0})
print(round(sure["unticketed"]["confidence"], 3),
      round(tied["unticketed"]["confidence"], 3),
      tied["unticketed"]["confidence"] >= ac.DOUBT_MAX)
'
    [ "$status" -eq 0 ]
    [[ "$output" == "1.0 0.5 True" ]]
}

@test "a branch filed under a different ticket from its arc's is doubted" {
    # The residual error, named: two tickets editing the same module. The split prompt
    # calls the ticket key the single most reliable signal for telling two bodies of work
    # apart, so a name that disagrees with the arc is evidence -- and only evidence, since
    # a stack carries one ticket'"'"'s commits across branches named for another.
    run ac '
files = {"UB-1000-own": ["a.ts", "b.ts"], "UL-9999": ["a.ts", "b.ts"],
         "anchor": ["a.ts", "b.ts", "c.ts"]}
mm = graph(files)
print(mm["UL-9999"]["confidence"] < mm["anchor"]["confidence"],
      "not UB-1000" in mm["UL-9999"]["why"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == "True True" ]]
}

@test "a membership with no shared file at all says so rather than blaming the floor" {
    # Rare and real: modularity'"'"'s local moving is order-dependent, so a community can
    # end up holding two branches with no edge between them once the node that linked
    # them has moved away. It is the weakest membership there is and the message has to
    # name that, not report a floor it never reached.
    run ac '
mm = graph({"alone": ["q.ts"], "UB-1000": ["a.ts", "b.ts"]}, sims={})
print(mm["alone"]["confidence"], mm["alone"]["why"])
'
    [ "$status" -eq 0 ]
    [[ "$output" == "0.0 it shares no distinctive file with any branch here" ]]
}

@test "a branch alone in its arc has no membership to doubt" {
    run ac '
print(graph({"only-one": ["a.ts"]}))
'
    [ "$status" -eq 0 ]
    [ "$output" = "{}" ]
}

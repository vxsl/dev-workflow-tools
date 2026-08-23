#!/usr/bin/env bats
# Tests for `--authoritative-ticket ARC=KEY`: the one thing about a workstream that neither
# git nor Jira can settle, and the rules that keep a human's answer from outliving its
# evidence.
#
# The failure it exists to correct, from the live page: UL-1852 reached review as one merge
# request, file overlap had already gathered eleven other branches into the same arc --
# experiments, backups, a pre-squash copy, a spike -- and every one of them held the arc on
# the `local-only` rung, reporting "85 commits exist only here" about work that had shipped.
# Every count was right. What they were counts *of* was the question.
#
# So the tests are about the two directions a declaration can be wrong:
#
#   too little effect      the rung, the live commit count and the demands are all
#                          downstream of it, and one that moved only the label would have
#                          left the page saying the thing it was made to stop saying
#   too much effect        it is a suppression. One that outlived its reason would hide
#                          real outstanding work, which is worse than never having existed,
#                          so it expires on a commit landing on anything it set aside
#
# finalize, apply_ticket_authority and demands are called directly: they are pure over the
# arc dict once `repo` is None, and reaching them through the CLI would mean standing up a
# git repo, a GitLab and a Jira to test which branches are counted.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    export JIRA_PROJECTS="UL,UB"
}

teardown() {
    teardown_temp_dir
}

wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" <<PY
import importlib.machinery, importlib.util, sys, json, time
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
sys.argv = ["wa"]
loader.exec_module(wa)
wa.TICKET_RE = wa._ticket_re()

def br(name, **kw):
    b = {"name": name, "sha": "sha-" + name, "unpushed": 0, "commits_ahead": 0,
         "age_days": 5, "parents": [], "pushed": True, "committed": 0}
    b.update(kw)
    return b

def mr(iid, branch, **kw):
    m = {"iid": iid, "branch": branch, "title": branch, "url": "u%d" % iid,
         "updated": "2026-08-20T00:00:00Z", "draft": False, "threads": [],
         "reviewers": ["vadym"], "assignees": [], "approvals": 0, "notes": 2,
         "conflicts": False}
    m.update(kw)
    return m

def arc(branches, mrs=(), **kw):
    a = {"id": "a1", "label": "metadata-latlng", "kind": "cluster",
         "branches": list(branches), "mrs": list(mrs), "stashes": [], "sessions": [],
         "issues": [], "engagement": 0, "mrs_known": True}
    a.update(kw)
    wa.finalize(a)
    return a

def declare(a, key, residue=None):
    """The store entry --authoritative-ticket would have written."""
    branch, why = wa._ta_resolve(a, key)
    lin = wa._ta_lineage(a, branch) if branch else set()
    return {a["label"]: {"key": key, "branch": branch, "at": 0,
                         "residue": wa._ta_residue_fp(a, lin)
                                    if residue is None else residue}}

$1
PY
}

# ── what it corrects ─────────────────────────────────────────────────────────

@test "the rung follows the merge request once the drafts are declared history" {
    # The whole complaint in one test: the arc is on `local-only` because of branches that
    # are not the work, and the declaration is what makes it "up for review".
    run wa '
a = arc([br("UL-1852", commits_ahead=8, unpushed=0),
         br("metadata-full", unpushed=40), br("metadata-spike", unpushed=45)],
        [mr(10502, "UL-1852")])
print(a["stage"], a["unpushed_live"])
stale = wa.apply_ticket_authority([a], declare(a, "UL-1852"))
print(stale)
print(a["stage"], a["state"], a["unpushed_live"])
print([d["kind"] for d in a["demands"]])'
    [ "${lines[0]}" = "local-only 85" ]
    [ "${lines[1]}" = "[]" ]
    [ "${lines[2]}" = "in-review in review 0" ]
    [ "${lines[3]}" = "[]" ]
}

@test "the declared ticket is the arc's ticket, whatever the branch names say" {
    # `arc["ticket"]` is normally read off the authoritative branch's name and falls back to
    # the arc's first issue. Neither knows which of five keys the work is answering, which
    # is the whole reason a subhead printing all of them says nothing.
    run wa '
a = arc([br("latlng-geom", commits_ahead=3), br("spike-latlng", unpushed=12)],
        [mr(10502, "latlng-geom", title="UL-1852 metadata lat/lng geometry")],
        issues=[{"key": "UB-7004", "url": ""}])
print(a["ticket"])
wa.apply_ticket_authority([a], declare(a, "UL-1852"))
print(a["ticket"], a["ticket_authority"]["branch"], a["historical_branches"])'
    [ "${lines[0]}" = "UB-7004" ]
    [ "${lines[1]}" = "UL-1852 latlng-geom 1" ]
}

@test "a stack below the declared branch is inside it, not history" {
    # Its commits are commits the tip already contains, so counting them as outstanding
    # would be the same double-count supersession already corrects for copies.
    run wa '
a = arc([br("UL-1852", commits_ahead=8, parents=["UL-1852-base"]),
         br("UL-1852-base", commits_ahead=2), br("unrelated-spike", unpushed=9)],
        [mr(10502, "UL-1852")])
print(a["unpushed_live"])
wa.apply_ticket_authority([a], declare(a, "UL-1852"))
print(sorted(b["name"] for b in a["branches"] if b.get("historical")))
print(a["unpushed_live"])'
    [ "${lines[0]}" = "9" ]
    [ "${lines[1]}" = "['unrelated-spike']" ]
    [ "${lines[2]}" = "0" ]
}

@test "a copy of the declared work is inside it too" {
    run wa '
a = arc([br("UL-1852", commits_ahead=8), br("UL-1852-bak", unpushed=8)],
        [mr(10502, "UL-1852")])
# Set after finalize on purpose: mark_duplicates derives supersession from commit
# subjects, and with no repo to read them from it would clear a hand-set field.
[b for b in a["branches"] if b["name"] == "UL-1852-bak"][0]["superseded_by"] = "UL-1852"
wa.apply_ticket_authority([a], declare(a, "UL-1852"))
print([b["name"] for b in a["branches"] if b.get("historical")])'
    [ "${lines[0]}" = "[]" ]
}

@test "history is accounted for, so the arc can finally land" {
    # Without this the merge request merges and eleven drafts from before it keep the
    # workstream open forever -- the exact shape of wrongness the declaration corrects.
    run wa '
a = arc([br("UL-1852", mr_fate={"state": "merged", "iid": 10502, "at": "", "url": ""}),
         br("metadata-spike", unpushed=45)])
print(a["settled"])
wa.apply_ticket_authority([a], declare(a, "UL-1852"))
print(a["settled"], a["stage"])'
    [ "${lines[0]}" = "None" ]
    [ "${lines[1]}" = "landed landed" ]
}

@test "a failed pipeline on work you filed elsewhere is not a demand" {
    run wa '
a = arc([br("UL-1852", commits_ahead=4),
         br("metadata-spike", unpushed=9,
            pipeline={"status": "failed", "at": "2026-08-01", "url": "p"})],
        [mr(10502, "UL-1852")])
print([d["kind"] for d in a["demands"]])
wa.apply_ticket_authority([a], declare(a, "UL-1852"))
print([d["kind"] for d in a["demands"]])'
    [ "${lines[0]}" = "['pipeline', 'unpushed']" ]
    [ "${lines[1]}" = "[]" ]
}

@test "what the merge request itself asks for still gets asked" {
    # The declaration silences the drafts. It has no opinion about the work under review,
    # and one that silenced a conflict would be hiding the thing the page is for.
    run wa '
a = arc([br("UL-1852", commits_ahead=4), br("metadata-spike", unpushed=9)],
        [mr(10502, "UL-1852", conflicts=True, target="main")])
wa.apply_ticket_authority([a], declare(a, "UL-1852"))
print([d["kind"] for d in a["demands"]], a["stage"])'
    [ "${lines[0]}" = "['conflict'] came-back" ]
}

# ── how it expires ───────────────────────────────────────────────────────────

@test "a commit on work you set aside means you went back to it" {
    # The one expiry that matters. "This is history" is a claim about branches that are not
    # moving, and it stops being true the moment one of them does.
    run wa '
a = arc([br("UL-1852", commits_ahead=4), br("metadata-spike", unpushed=9)],
        [mr(10502, "UL-1852")])
store = declare(a, "UL-1852")
a2 = arc([br("UL-1852", commits_ahead=4),
          br("metadata-spike", unpushed=10, sha="sha-new")],
         [mr(10502, "UL-1852")])
stale = wa.apply_ticket_authority([a2], store)
print(stale[0]["key"], "|", stale[0]["why"])
print(a2.get("ticket_authority"), a2["stage"], a2["unpushed_live"])'
    [ "${lines[0]}" = "UL-1852 | a commit has landed on work you set aside, so it is not history" ]
    [ "${lines[1]}" = "None local-only 10" ]
}

@test "a commit on the declared work itself is not an expiry" {
    # Working on the thing you filed is the case this must survive; only the residue is
    # fingerprinted, exactly so that it does.
    run wa '
a = arc([br("UL-1852", commits_ahead=4), br("metadata-spike", unpushed=9)],
        [mr(10502, "UL-1852")])
store = declare(a, "UL-1852")
a2 = arc([br("UL-1852", commits_ahead=9, sha="sha-moved"),
          br("metadata-spike", unpushed=9)],
         [mr(10502, "UL-1852")])
print(wa.apply_ticket_authority([a2], store), a2["stage"])'
    [ "${lines[0]}" = "[] in-review" ]
}

@test "a ticket the workstream no longer holds reports itself rather than applying" {
    run wa '
a = arc([br("UL-1852", commits_ahead=4), br("metadata-spike", unpushed=9)],
        [mr(10502, "UL-1852")])
store = declare(a, "UL-1852")
a2 = arc([br("metadata-spike", unpushed=9)])
stale = wa.apply_ticket_authority([a2], store)
print(stale[0]["why"])
print(a2.get("ticket_authority"), a2["unpushed_live"])'
    [ "${lines[0]}" = "nothing in this workstream is UL-1852" ]
    [ "${lines[1]}" = "None 9" ]
}

@test "two branches naming the key and no merge request is refused, not guessed" {
    run wa '
a = arc([br("UL-1852", unpushed=4), br("UL-1852-v2", unpushed=9)])
print(wa._ta_resolve(a, "UL-1852"))'
    [[ "${lines[0]}" == *"2 branches name UL-1852 and no merge request picks one"* ]]
}

@test "a branch naming the key stands in where no merge request exists yet" {
    run wa '
a = arc([br("UL-1852", commits_ahead=4), br("old-spike", unpushed=30)])
wa.apply_ticket_authority([a], declare(a, "UL-1852"))
print(a["ticket_authority"]["via"], a["unpushed_live"], a["stage"])'
    [ "${lines[0]}" = "the one branch naming UL-1852 0 not-proposed" ]
}

@test "unpushed commits on the work itself are still unpushed" {
    # The declaration says which branches are not the work. It says nothing about the work,
    # and one that swallowed the real risk on the real branch would be hiding exactly what
    # the page exists to show.
    run wa '
a = arc([br("UL-1852", unpushed=4, commits_ahead=4), br("old-spike", unpushed=30)])
wa.apply_ticket_authority([a], declare(a, "UL-1852"))
print(a["stage"], a["unpushed_live"], [d["kind"] for d in a["demands"]])'
    [ "${lines[0]}" = "local-only 4 ['unpushed', 'unreviewed']" ]
}

@test "the authoritative branch is the declared one, and says so" {
    # Ahead of every derivation, because it is the only statement here that is not an
    # inference -- the tip-of-the-stack rule would have picked the 45-commit spike.
    run wa '
a = arc([br("UL-1852", commits_ahead=4, committed=1),
         br("metadata-spike", unpushed=45, commits_ahead=45, committed=2)],
        [mr(10502, "UL-1852")])
print(a["authoritative"])
wa.apply_ticket_authority([a], declare(a, "UL-1852"))
print(a["authoritative"], "|", a["authoritative_via"])'
    [ "${lines[0]}" = "UL-1852" ]
    [[ "${lines[1]}" == "UL-1852 | you filed this as UL-1852 — source of !10502" ]]
}

@test "an arc nobody declared anything about is untouched" {
    run wa '
a = arc([br("UL-1852", commits_ahead=4), br("metadata-spike", unpushed=9)],
        [mr(10502, "UL-1852")])
print(wa.apply_ticket_authority([a], {}), a["stage"], a["unpushed_live"],
      a.get("ticket_authority"), a["historical_branches"])'
    [ "${lines[0]}" = "[] local-only 9 None 0" ]
}

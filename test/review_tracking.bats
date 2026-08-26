#!/usr/bin/env bats
# Tests for reviewing as a first-class thing, and for the three ways it used to be
# mistaken for work of Kyle's own.
#
# Kyle: "i think it should be doable to track ongoing reviews, and not conflate me
# checking people's branches out to review them with me working on them. also me actively
# reviewing someone's MR is in its own category, e.x. i have 6802 which is a long ongoing
# review and various logan MRs which are long ongoing reviews. it would be cool to see
# these as first-class things."
#
# Three defects underneath that, and one of them is invisible unless authorship is read:
#
#   1. Nothing ever read who wrote a commit. Every clock was built on the tip's
#      committerdate, so a branch checked out to review dated the workstream by its
#      author's last push -- measured on the real corpus, UB-6974 read 26 days off a
#      checkout of Ella's while its own newest work was 48 days old.
#   2. Other people's merge requests joined to no workstream, by a deliberate decision
#      that was right for the ledger and wrong for this.
#   3. An ongoing review is not a debt. The ledger drops a merge request the moment you
#      first speak on it, correctly -- and that is exactly when the review starts.
#
# Real git repositories with two authoring identities for the first, because authorship is
# derived from commits and there is nothing to derive from a fixture that hands it over.
# Stubbed GitLab for the rest, because what is pinned is which merge requests make the list
# and how whose-turn flips, never a sentence.
#
# Nothing here pins wording.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    export JIRA_PROJECTS="UL,UB"
    ARC_REPO="$TEST_TMPDIR/repo"
    export ARC_REPO
    mkdir -p "$ARC_REPO"
    git -C "$ARC_REPO" init -q -b main
    git -C "$ARC_REPO" config user.email kyle@example.com
    git -C "$ARC_REPO" config user.name "Kyle Grimsrud-Manz"
    mine main 2026-05-01 base
    git -C "$ARC_REPO" update-ref refs/remotes/origin/main main
}

teardown() {
    teardown_temp_dir
}

# One empty commit authored by you. The offset is fixed so the day a commit lands on is a
# fact about the fixture and not about the machine's timezone.
mine() {
    local branch="$1" day="$2" msg="$3"
    # Always cut a new branch from main. Left to inherit HEAD, a branch created after
    # another one contains its commits -- which is a stack, not a checkout, and it would
    # make every fixture here silently test the wrong thing.
    if git -C "$ARC_REPO" rev-parse --verify -q "$branch" >/dev/null; then
        git -C "$ARC_REPO" checkout -q "$branch"
    elif git -C "$ARC_REPO" rev-parse --verify -q main >/dev/null; then
        git -C "$ARC_REPO" checkout -q -b "$branch" main
    else
        git -C "$ARC_REPO" checkout -q -b "$branch" 2>/dev/null || true
    fi
    GIT_AUTHOR_DATE="$day 09:00:00 +0000" GIT_COMMITTER_DATE="$day 09:00:00 +0000" \
        git -C "$ARC_REPO" commit -q --allow-empty -m "$msg"
}

# One empty commit somebody else authored, committed by you -- which is exactly what a
# rebase of their branch leaves behind, and the case that makes the committer useless as
# an identity. Args: branch, day, message, author email.
theirs() {
    local branch="$1" day="$2" msg="$3" who="${4:-ella@example.com}"
    # Always cut a new branch from main. Left to inherit HEAD, a branch created after
    # another one contains its commits -- which is a stack, not a checkout, and it would
    # make every fixture here silently test the wrong thing.
    if git -C "$ARC_REPO" rev-parse --verify -q "$branch" >/dev/null; then
        git -C "$ARC_REPO" checkout -q "$branch"
    elif git -C "$ARC_REPO" rev-parse --verify -q main >/dev/null; then
        git -C "$ARC_REPO" checkout -q -b "$branch" main
    else
        git -C "$ARC_REPO" checkout -q -b "$branch" 2>/dev/null || true
    fi
    GIT_AUTHOR_NAME="Somebody Else" GIT_AUTHOR_EMAIL="$who" \
    GIT_AUTHOR_DATE="$day 09:00:00 +0000" GIT_COMMITTER_DATE="$day 09:00:00 +0000" \
        git -C "$ARC_REPO" commit -q --allow-empty -m "$msg"
}

# Pretend a branch is on the remote, so it carries no unpushed commits -- which is what a
# checkout of somebody's pushed branch actually looks like.
pushed() {
    git -C "$ARC_REPO" update-ref "refs/remotes/origin/$1" "$1"
}

# Runs a python snippet with work-arcs imported as wa, against the fixture repo.
wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" "$ARC_REPO" <<PY
import importlib.machinery, importlib.util, sys, json, re
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
REPO = sys.argv[2]
sys.argv = ["wa"]
loader.exec_module(wa)
wa.TICKET_RE = wa._ticket_re()

def note(who, when, body="a word", system=False):
    return {"author": {"username": who}, "created_at": when, "body": body,
            "system": system}

def mr(iid, author="ella", branch="UL-1816", title="their work", updated=None,
       draft=False, **kw):
    m = {"iid": iid, "title": title, "web_url": "https://g/-/merge_requests/%d" % iid,
         "author": {"username": author}, "source_branch": branch,
         "target_branch": "main", "draft": draft, "work_in_progress": draft,
         "created_at": "2026-06-01T09:00:00.000Z",
         "updated_at": updated or "2026-06-01T09:00:00.000Z"}
    m.update(kw)
    return m

def fake_glab(mrs, discussions, me="kyle"):
    """Every call ledger_you_owe makes, answered from a fixture."""
    def glab(repo, path, **k):
        if path == "user":
            return {"username": me}
        if "merge_requests?state=opened" in path:
            return mrs
        g = re.search(r"merge_requests/(\d+)/discussions", path)
        if g:
            return discussions.get(int(g.group(1)), [])
        g = re.search(r"merge_requests/(\d+)/approvals", path)
        if g:
            return {"approved_by": []}
        return None
    return glab

def arc(aid, branches, mrs=(), reviews=(), **kw):
    a = {"id": aid, "label": aid, "kind": "ticket", "ticket": None, "issues": [],
         "branches": list(branches), "mrs": list(mrs), "sessions": [], "stashes": [],
         "reviews": list(reviews), "engagement": 0}
    a.update(kw)
    return a

$1
PY
}

# ── R1: who wrote the commits ─────────────────────────────────────────────────

@test "a branch holding only somebody else's commits is a checkout" {
    theirs UL-1816 2026-08-01 "their first"
    theirs UL-1816 2026-08-02 "their second"
    pushed UL-1816
    run wa '
b = wa.collect_branches(REPO, "origin/main")["UL-1816"]
print("role", b["role"])
print("own", b["own_commits"], "foreign", b["foreign_commits"])
print("own_committed", b["own_committed"], "own_age", b["own_age_days"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"role checkout"* ]]
    [[ "$output" == *"own 0 foreign 2"* ]]
    [[ "$output" == *"own_committed 0 own_age None"* ]]
}

@test "one commit of your own among theirs makes the branch yours" {
    # Deliberately the low-ratio case. On the real corpus UB-6438-suggestion is 1 commit of
    # Kyle's on top of 11 of Brian's, and that is still him having worked here -- the
    # counts ride on the row for anyone who wants the ratio.
    theirs UB-6438 2026-08-01 "theirs one"
    theirs UB-6438 2026-08-02 "theirs two"
    mine UB-6438 2026-08-03 "my suggestion"
    run wa '
b = wa.collect_branches(REPO, "origin/main")["UB-6438"]
print("role", b["role"], "own", b["own_commits"], "foreign", b["foreign_commits"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"role authored own 1 foreign 2"* ]]
}

@test "a rebase of their branch does not make it yours" {
    # The whole reason authorship is read off the author and never the committer: every
    # commit below has YOU as committer and them as author, which is what a rebase leaves.
    theirs UL-1815 2026-08-01 "theirs"
    run wa '
import subprocess
out = subprocess.run(["git", "-C", REPO, "log", "--format=%ae %ce", "-1", "UL-1815"],
                     capture_output=True, text=True).stdout.strip()
print("author_committer", out)
print("role", wa.collect_branches(REPO, "origin/main")["UL-1815"]["role"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"author_committer ella@example.com kyle@example.com"* ]]
    [[ "$output" == *"role checkout"* ]]
}

@test "an old address of yours is you, and a colleague who shares a first name is not" {
    run wa '
ident = wa.own_authors(REPO)
for who in ("kyle@example.com", "kyle.grimsrud-manz@old.example",
            "manz@elsewhere.org", "kyle.smith@example.com", "ella@example.com", ""):
    print("is_own", repr(who), wa.author_is_own(who, ident))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"is_own 'kyle@example.com' True"* ]]
    [[ "$output" == *"is_own 'kyle.grimsrud-manz@old.example' True"* ]]
    [[ "$output" == *"is_own 'manz@elsewhere.org' True"* ]]
    [[ "$output" == *"is_own 'kyle.smith@example.com' False"* ]]
    [[ "$output" == *"is_own 'ella@example.com' False"* ]]
    [[ "$output" == *"is_own '' False"* ]]
}

# ── R2: the clocks stop counting other people's afternoons ────────────────────

@test "own_activity ignores a checkout branch and reads your own commit instead" {
    mine mywork 2026-06-01 "my old work"
    theirs UL-1816 2026-08-20 "their fresh push"
    pushed UL-1816
    run wa '
bs = wa.collect_branches(REPO, "origin/main")
a = arc("x", [bs["mywork"], bs["UL-1816"]])
print("tip_of_theirs", bs["UL-1816"]["committed"])
print("my_commit", bs["mywork"]["own_committed"])
print("own_activity", wa.own_activity(a))'
    [ "$status" -eq 0 ]
    mine_ts=$(echo "$output" | sed -n 's/^my_commit //p')
    theirs_ts=$(echo "$output" | sed -n 's/^tip_of_theirs //p')
    act=$(echo "$output" | sed -n 's/^own_activity //p')
    [ "$act" -eq "$mine_ts" ]
    [ "$act" -ne "$theirs_ts" ]
}

@test "a checkout does not date the workstream, and where there is nothing else it says so" {
    mine mywork 2026-06-01 "my old work"
    theirs UL-1816 2026-08-20 "their fresh push"
    pushed UL-1816
    run wa '
bs = wa.collect_branches(REPO, "origin/main")
mixed = arc("mixed", [bs["mywork"], bs["UL-1816"]])
wa.finalize(mixed, REPO, "origin/main")
print("mixed_age", mixed["age_days"], "foreign", mixed["age_is_foreign"])
print("their_age", bs["UL-1816"]["age_days"], "my_age", bs["mywork"]["age_days"])
only = arc("only", [bs["UL-1816"]])
wa.finalize(only, REPO, "origin/main")
print("only_age", only["age_days"], "foreign", only["age_is_foreign"])'
    [ "$status" -eq 0 ]
    my_age=$(echo "$output" | sed -n 's/.*my_age //p')
    mixed_age=$(echo "$output" | sed -n 's/^mixed_age \([0-9]*\).*/\1/p')
    [ "$mixed_age" -eq "$my_age" ]
    [[ "$output" == *"mixed_age $my_age foreign False"* ]]
    # An arc that is nothing but their branch has no age of yours at all, and says which
    # kind of date it fell back to rather than inventing one in either direction.
    [[ "$output" == *"foreign True"* ]]
}

@test "a checkout carries no unpushed commits, so the days-of-work count was never wrong" {
    # Verified rather than fixed. unpushed_days is immune by construction -- a branch you
    # fetched is on a remote -- and a change made here would have been a change made for
    # no reason.
    theirs UL-1816 2026-08-01 "theirs"
    pushed UL-1816
    run wa '
bs = wa.collect_branches(REPO, "origin/main")
a = arc("x", [bs["UL-1816"]])
wa.finalize(a, REPO, "origin/main")
print("unpushed", bs["UL-1816"]["unpushed"], "days", a["unpushed_days"],
      "live", a["unpushed_live"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"unpushed 0 days 0 live 0"* ]]
}

@test "nobody is told to open a merge request for somebody else's branch" {
    theirs UL-1816 2026-08-01 "theirs"
    pushed UL-1816
    run wa '
bs = wa.collect_branches(REPO, "origin/main")
a = arc("x", [bs["UL-1816"]], mrs_known=True)
wa.finalize(a, REPO, "origin/main")
print("kinds", sorted(d["kind"] for d in a["demands"]))
print("stage", a["stage"], "checkout_only", wa.checkout_only(a))
print("state", a["state"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"kinds []"* ]]
    [[ "$output" == *"stage checkout checkout_only True"* ]]
    # Whose branch it is, from the commits on it, and never an accusation about one.
    [[ "$output" == *"ella"* ]]
    [[ "$output" != *"unreviewed"* ]]
}

@test "the same branch with a commit of yours on it still demands a merge request" {
    # The guard has to be about authorship and not about the branch merely being foreign-
    # looking, or it would silence a real demand on real work.
    theirs UL-1816 2026-08-01 "theirs"
    mine UL-1816 2026-08-02 "mine on top"
    pushed UL-1816
    run wa '
bs = wa.collect_branches(REPO, "origin/main")
a = arc("x", [bs["UL-1816"]], mrs_known=True)
wa.finalize(a, REPO, "origin/main")
print("kinds", sorted(d["kind"] for d in a["demands"]))
print("checkout_only", wa.checkout_only(a))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"unreviewed"* ]]
    [[ "$output" == *"checkout_only False"* ]]
}

@test "an arc of your own work that contains one of their branches is not a review" {
    # The mixed case, and the one the corpus is full of: UB-6802 is 22 commits of Kyle's
    # and 17 of Ella's. Calling that a review would lose the work.
    mine UB-6802 2026-08-01 "mine"
    theirs UB-6888 2026-08-01 "theirs"
    pushed UB-6888
    run wa '
bs = wa.collect_branches(REPO, "origin/main")
a = arc("x", [bs["UB-6802"], bs["UB-6888"]], mrs_known=True)
wa.finalize(a, REPO, "origin/main")
print("checkout_only", wa.checkout_only(a))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"checkout_only False"* ]]
}

# ── R3: which merge requests make the reviewing list ──────────────────────────

@test "their open merge request naming you a reviewer is an ongoing review" {
    run wa '
mrs = [mr(10530, author="logan", branch="UL-1816")]
disc = {10530: [{"notes": [note("logan", "2026-06-01T09:00:00.000Z"),
                           note("kyle", "2026-06-02T09:00:00.000Z")]}]}
wa.glab = fake_glab(mrs, disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
rows, covered, whole, reviews, drafts, approved = wa.ledger_you_owe("repo", "kyle")
print("n", len(reviews), "known", whole, "drafts", drafts)
r = reviews[0]
print("iid", r["iid"], "author", r["author"], "branch", r["source_branch"])
print("turn", r["whose_turn"], "rounds", r["rounds"])
print("has_fp", bool(r["fp"]), "arc", r["arc"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"n 1 known True drafts 0"* ]]
    [[ "$output" == *"iid 10530 author logan branch UL-1816"* ]]
    [[ "$output" == *"turn theirs rounds 1"* ]]
    [[ "$output" == *"has_fp True arc None"* ]]
}

@test "a review survives the moment the ledger stops demanding one" {
    # The defect in one test. Once you have spoken, you no longer owe a first read and the
    # ledger is right to drop the row -- and that is exactly when the review begins.
    run wa '
mrs = [mr(10530, author="logan")]
disc = {10530: [{"notes": [note("kyle", "2026-06-02T09:00:00.000Z")]}]}
wa.glab = fake_glab(mrs, disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
rows, covered, whole, reviews, drafts, approved = wa.ledger_you_owe("repo", "kyle")
print("ledger_rows", len(rows), "covered", covered)
print("reviews", len(reviews))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ledger_rows 0 covered 1"* ]]
    [[ "$output" == *"reviews 1"* ]]
}

@test "your own merge request is never one of your reviews" {
    run wa '
mrs = [mr(1, author="kyle"), mr(2, author="logan")]
disc = {1: [], 2: []}
wa.glab = fake_glab(mrs, disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
rows, covered, whole, reviews, drafts, approved = wa.ledger_you_owe("repo", "kyle")
print("iids", [r["iid"] for r in reviews])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"iids [2]"* ]]
}

@test "a draft is left off the list and counted rather than dropped in silence" {
    run wa '
mrs = [mr(3, author="logan", draft=True), mr(4, author="logan")]
disc = {3: [], 4: []}
wa.glab = fake_glab(mrs, disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
rows, covered, whole, reviews, drafts, approved = wa.ledger_you_owe("repo", "kyle")
print("iids", [r["iid"] for r in reviews], "drafts", drafts)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"iids [4] drafts 1"* ]]
}

@test "whose turn it is flips on their word and back on yours" {
    run wa '
def turn_after(notes):
    disc = {5: [{"notes": notes}]}
    wa.glab = fake_glab([mr(5, author="logan")], disc)
    wa.shutil.which = lambda n: "/usr/bin/" + n
    return wa.ledger_you_owe("repo", "kyle")[3][0]
never = turn_after([])
print("never", never["whose_turn"], never["rounds"])
spoke = turn_after([note("kyle", "2026-06-02T09:00:00.000Z")])
print("i_spoke", spoke["whose_turn"], spoke["rounds"])
back = turn_after([note("kyle", "2026-06-02T09:00:00.000Z"),
                   note("logan", "2026-06-03T09:00:00.000Z")])
print("they_replied", back["whose_turn"], back["rounds"])
again = turn_after([note("kyle", "2026-06-02T09:00:00.000Z"),
                    note("logan", "2026-06-03T09:00:00.000Z"),
                    note("kyle", "2026-06-04T09:00:00.000Z")])
print("i_replied", again["whose_turn"], again["rounds"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"never mine 0"* ]]
    [[ "$output" == *"i_spoke theirs 1"* ]]
    [[ "$output" == *"they_replied mine 1"* ]]
    [[ "$output" == *"i_replied theirs 2"* ]]
}

@test "six comments in one sitting are one round of review, not six" {
    run wa '
notes = [note("kyle", "2026-06-02T09:0%d:00.000Z" % i) for i in range(6)]
disc = {6: [{"notes": notes}]}
wa.glab = fake_glab([mr(6, author="logan")], disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
print("rounds", wa.ledger_you_owe("repo", "kyle")[3][0]["rounds"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rounds 1"* ]]
}

@test "a push they made after your review turns it back to you, and says it inferred that" {
    # The case notes cannot answer: new commits move nothing but the merge request's own
    # updated_at. It stands in, and the row admits that it is standing in.
    run wa '
disc = {7: [{"notes": [note("kyle", "2026-06-02T09:00:00.000Z")]}]}
wa.glab = fake_glab([mr(7, author="logan", updated="2026-06-05T09:00:00.000Z")], disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
r = wa.ledger_you_owe("repo", "kyle")[3][0]
print("turn", r["whose_turn"], "proxy", r["their_last_is_proxy"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"turn mine proxy True"* ]]
}

@test "storing your own note does not read as a reply to it" {
    # updated_at moves when GitLab stores a note, at essentially the note's own instant.
    # A zero tolerance would flip the turn the moment you spoke, which is the one reading
    # this feature exists to get right.
    run wa '
disc = {8: [{"notes": [note("kyle", "2026-06-02T09:00:00.000Z")]}]}
wa.glab = fake_glab([mr(8, author="logan", updated="2026-06-02T09:00:01.000Z")], disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
r = wa.ledger_you_owe("repo", "kyle")[3][0]
print("turn", r["whose_turn"], "proxy", r["their_last_is_proxy"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"turn theirs proxy False"* ]]
}

@test "yours first, then longest running, and the order is total" {
    run wa '
mrs = [mr(11, author="a", updated="2026-06-02T09:00:00.000Z"),
       mr(12, author="b", updated="2026-06-02T09:00:00.000Z"),
       mr(13, author="c", updated="2026-06-02T09:00:00.000Z")]
disc = {11: [{"notes": [note("kyle", "2026-06-02T09:00:00.000Z")]}],
        12: [{"notes": []}],
        13: [{"notes": []}]}
wa.glab = fake_glab(mrs, disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
reviews = wa.ledger_you_owe("repo", "kyle")[3]
print("order", [(r["iid"], r["whose_turn"]) for r in reviews])'
    [ "$status" -eq 0 ]
    # 12 and 13 are both yours and the same age, so only the iid can separate them.
    [[ "$output" == *"order [(12, 'mine'), (13, 'mine'), (11, 'theirs')]"* ]]
}

@test "no glab means the reviewing list is unknown, never empty" {
    run wa '
wa.shutil.which = lambda n: None
rows, covered, whole, reviews, drafts, approved = wa.ledger_you_owe("repo", "kyle")
print("reviews", len(reviews), "whole", whole)'
    [ "$status" -eq 0 ]
    [[ "$output" == *"reviews 0 whole False"* ]]
}

@test "the ledger carries the list and says whether it is all of it" {
    run wa '
mrs = [mr(21, author="logan")]
wa.glab = fake_glab(mrs, {21: []})
wa.shutil.which = lambda n: "/usr/bin/" + n
wa.ledger_they_owe = lambda r, m, me: ([], True)
wa.ledger_jira_stalled = lambda: ([], True)
wa.ledger_slack = lambda: ([], [], True, True)
wa.ledger_meetings = lambda: ([], True)
led = wa.build_ledger("repo", [])
print("n", len(led["reviews"]), "known", led["reviews_known"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"n 1 known True"* ]]
}

# ── R4: the join to a workstream ──────────────────────────────────────────────

@test "a review joins the arc whose branch is its source branch" {
    run wa '
a = arc("theirs", [{"name": "UL-1816", "role": "checkout", "sha": "s", "unpushed": 0,
                    "commits_ahead": 1, "age_days": 3, "parents": [], "pushed": True,
                    "committed": 0, "own_committed": 0}],
        stage="checkout", state="checkout of ella/s branch")
r = {"iid": 10530, "ref": "!10530", "source_branch": "UL-1816", "author": "logan",
     "whose_turn": "mine", "rounds": 3, "my_last": 100, "their_last": 200, "arc": None}
wa.attach_reviews([a], [r])
print("joined", r["arc"], "how", r["arc_via"])
print("on_arc", len(a["reviews"]))
print("own_activity", wa.own_activity(a))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"joined theirs"* ]]
    [[ "$output" == *"on_arc 1"* ]]
    # A word you said on their merge request is not a touch on any workstream here. It
    # used to be folded in so that a checkout-only arc had one clock of yours instead of
    # none; those arcs are not emitted any more and the clause went with them.
    [[ "$output" == *"own_activity 0"* ]]
}

@test "failing that, a review joins the arc that names the same ticket" {
    run wa '
a = arc("UL-1816", [{"name": "UL-1816-local-copy", "role": "checkout", "sha": "s",
                     "unpushed": 0, "commits_ahead": 1, "age_days": 3, "parents": [],
                     "pushed": True, "committed": 0, "own_committed": 0}],
        stage="checkout", state="x", ticket="UL-1816")
r = {"iid": 1, "ref": "!1", "source_branch": "UL-1816-theirs", "author": "logan",
     "whose_turn": "theirs", "rounds": 1, "my_last": 5, "their_last": 1, "arc": None}
wa.attach_reviews([a], [r])
print("joined", r["arc"], "how", r["arc_via"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"joined UL-1816"* ]]
    [[ "$output" == *"UL-1816"* ]]
}

@test "a review that matches nothing joins nothing and is still on the list" {
    run wa '
a = arc("mine", [{"name": "something-else", "role": "authored", "sha": "s",
                  "unpushed": 0, "commits_ahead": 1, "age_days": 3, "parents": [],
                  "pushed": True, "committed": 0, "own_committed": 0}])
r = {"iid": 9, "ref": "!9", "source_branch": "no-such-branch", "author": "logan",
     "whose_turn": "mine", "rounds": 0, "my_last": 0, "their_last": 1, "arc": None}
wa.attach_reviews([a], [r])
print("joined", r["arc"], "on_arc", len(a["reviews"]))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"joined None on_arc 0"* ]]
}

@test "a comment on their merge request cannot silence news on a workstream of yours" {
    # The bound on own_activity. Folding a review into an authored arc would let a note on
    # somebody else's branch suppress the news that your own branch stopped merging.
    run wa '
a = arc("mine", [{"name": "UL-1816", "role": "authored", "sha": "s", "unpushed": 0,
                  "commits_ahead": 1, "age_days": 3, "parents": [], "pushed": True,
                  "committed": 50, "own_committed": 50}])
r = {"iid": 1, "ref": "!1", "source_branch": "UL-1816", "author": "logan",
     "whose_turn": "mine", "rounds": 1, "my_last": 9999, "their_last": 1, "arc": None}
wa.attach_reviews([a], [r])
print("own_activity", wa.own_activity(a))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"own_activity 50"* ]]
}

# ── R5: what moved between two runs ───────────────────────────────────────────

@test "the snapshot carries the reviews and the diff says when a turn flipped" {
    run wa '
def snap(turn, rounds, gen):
    r = [{"iid": 10530, "ref": "!10530", "url": "u", "author": "logan", "title": "t",
          "whose_turn": turn, "rounds": rounds, "my_last": 1, "their_last": 2,
          "arc": "UL-1816"}]
    return wa.snapshot_of([], None, {"mrs": True, "ledger": True, "issues": True,
                                     "reviews": True}, "ul", gen, r)
a = snap("theirs", 1, "2026-08-01T09:00:00+0000")
b = snap("mine", 1, "2026-08-02T09:00:00+0000")
print("stored", sorted(a["reviews"]["10530"]))
d = wa.diff_runs(a, b, [], None)
print("kinds", [c["kind"] for c in d["reviews"]])
print("arc", d["reviews"][0]["arc"])
c = snap("mine", 2, "2026-08-03T09:00:00+0000")
print("rounds_moved", [x["kind"] for x in wa.diff_runs(b, c, [], None)["reviews"]])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"whose_turn"* ]]
    [[ "$output" == *"kinds ['turned_mine']"* ]]
    [[ "$output" == *"arc UL-1816"* ]]
    [[ "$output" == *"rounds_moved ['answered']"* ]]
}

@test "a run that did not ask about reviews compares none of them" {
    # The same discipline every other universe here follows: a snapshot that never held
    # the reviews would otherwise report every one of them as having appeared.
    run wa '
r = [{"iid": 1, "ref": "!1", "url": "u", "author": "logan", "title": "t",
      "whose_turn": "mine", "rounds": 0, "my_last": 0, "their_last": 1, "arc": None}]
old = wa.snapshot_of([], None, {"mrs": True, "ledger": True, "issues": True,
                                "reviews": False}, "ul", "2026-08-01T09:00:00+0000", [])
new = wa.snapshot_of([], None, {"mrs": True, "ledger": True, "issues": True,
                                "reviews": True}, "ul", "2026-08-02T09:00:00+0000", r)
d = wa.diff_runs(old, new, [], None)
print("reviews", d["reviews"], "skipped", "reviews" in d["skipped_universes"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"reviews [] skipped True"* ]]
}

# ── R6: an MR you already approved is not an ongoing review ───────────────────
#
# Kyle: "most of the reviews seem like BS, in particular it's reporting on things i've
# already approved." On the real corpus 21 of 23 rows read "your turn" and four of them
# were merge requests he had approved and nobody had touched since.
#
# Two defects, and the first is what made the second invisible. Approving moves the merge
# request's updated_at and writes no human note, so the whose-turn proxy read HIS OWN
# approval as THEIR push. Then nothing anywhere asked whether an approval had settled the
# engagement at all.

@test "an approval of yours is not read as a push of theirs" {
    # The proxy bug on its own. updated_at moves when you approve, and reading that as
    # their activity flips the row to your turn at the moment your end of it finished.
    run wa '
disc = {30: [{"notes": [note("logan", "2026-06-01T09:00:00.000Z"),
                        note("kyle", "2026-06-10T09:00:00.000Z",
                             "approved this merge request", system=True)]}]}
wa.glab = fake_glab([mr(30, author="logan", updated="2026-06-10T09:00:05.000Z")], disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
r = wa._review_row(mr(30, author="logan", updated="2026-06-10T09:00:05.000Z"),
                   disc[30], "kyle")
print("proxy", r["their_last_is_proxy"], "covers", r["approved_covers"])
print("approved_at_set", bool(r["approved_at"]))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"proxy False covers True"* ]]
    [[ "$output" == *"approved_at_set True"* ]]
}

@test "you approved it and nobody has moved since, so it leaves the ongoing list" {
    run wa '
disc = {31: [{"notes": [note("logan", "2026-06-01T09:00:00.000Z"),
                        note("kyle", "2026-06-02T09:00:00.000Z"),
                        note("kyle", "2026-06-10T09:00:00.000Z",
                             "approved this merge request", system=True)]}]}
wa.glab = fake_glab([mr(31, author="logan", updated="2026-06-10T09:00:00.000Z")], disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
rows, covered, whole, reviews, drafts, approved = wa.ledger_you_owe("repo", "kyle")
print("ongoing", [r["iid"] for r in reviews])
print("approved", [r["iid"] for r in approved])
print("covers", approved[0]["approved_covers"], "rounds", approved[0]["rounds"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ongoing []"* ]]
    [[ "$output" == *"approved [31]"* ]]
    [[ "$output" == *"covers True rounds 1"* ]]
}

@test "a push after your approval revives the review and the turn is yours" {
    run wa '
disc = {32: [{"notes": [note("kyle", "2026-06-02T09:00:00.000Z"),
                        note("kyle", "2026-06-10T09:00:00.000Z",
                             "approved this merge request", system=True)]}]}
wa.glab = fake_glab([mr(32, author="logan", updated="2026-06-20T09:00:00.000Z")], disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
rows, covered, whole, reviews, drafts, approved = wa.ledger_you_owe("repo", "kyle")
print("ongoing", [(r["iid"], r["whose_turn"]) for r in reviews])
print("approved", [r["iid"] for r in approved])
print("still_approved", bool(reviews[0]["approved_at"]), "proxy",
      reviews[0]["their_last_is_proxy"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ongoing [(32, 'mine')]"* ]]
    [[ "$output" == *"approved []"* ]]
    # The approval is still on the row -- it was overtaken, not withdrawn.
    [[ "$output" == *"still_approved True proxy True"* ]]
}

@test "a word after your approval revives it just as a push does" {
    run wa '
disc = {33: [{"notes": [note("kyle", "2026-06-02T09:00:00.000Z"),
                        note("kyle", "2026-06-10T09:00:00.000Z",
                             "approved this merge request", system=True),
                        note("logan", "2026-06-12T09:00:00.000Z")]}]}
wa.glab = fake_glab([mr(33, author="logan", updated="2026-06-12T09:00:00.000Z")], disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
rows, covered, whole, reviews, drafts, approved = wa.ledger_you_owe("repo", "kyle")
print("ongoing", [(r["iid"], r["whose_turn"]) for r in reviews], "approved",
      [r["iid"] for r in approved])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ongoing [(33, 'mine')] approved []"* ]]
}

@test "a review you never approved stays exactly where it was" {
    run wa '
disc = {34: [{"notes": [note("logan", "2026-06-01T09:00:00.000Z"),
                        note("kyle", "2026-06-02T09:00:00.000Z")]}]}
wa.glab = fake_glab([mr(34, author="logan", updated="2026-06-02T09:00:00.000Z")], disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
rows, covered, whole, reviews, drafts, approved = wa.ledger_you_owe("repo", "kyle")
print("ongoing", [(r["iid"], r["whose_turn"]) for r in reviews], "approved",
      [r["iid"] for r in approved])
print("approved_at", reviews[0]["approved_at"], "covers",
      reviews[0]["approved_covers"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ongoing [(34, 'theirs')] approved []"* ]]
    [[ "$output" == *"approved_at 0 covers False"* ]]
}

@test "taking your approval back puts the review back on the list" {
    run wa '
disc = {35: [{"notes": [note("kyle", "2026-06-10T09:00:00.000Z",
                             "approved this merge request", system=True),
                        note("kyle", "2026-06-11T09:00:00.000Z",
                             "unapproved this merge request", system=True)]}]}
wa.glab = fake_glab([mr(35, author="logan", updated="2026-06-11T09:00:00.000Z")], disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
rows, covered, whole, reviews, drafts, approved = wa.ledger_you_owe("repo", "kyle")
print("ongoing", [r["iid"] for r in reviews], "approved", [r["iid"] for r in approved])
print("approved_at", reviews[0]["approved_at"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ongoing [35] approved []"* ]]
    [[ "$output" == *"approved_at 0"* ]]
}

@test "somebody else approving is not you approving" {
    run wa '
disc = {36: [{"notes": [note("irene", "2026-06-10T09:00:00.000Z",
                             "approved this merge request", system=True)]}]}
wa.glab = fake_glab([mr(36, author="logan", updated="2026-06-10T09:00:00.000Z")], disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
rows, covered, whole, reviews, drafts, approved = wa.ledger_you_owe("repo", "kyle")
print("ongoing", [r["iid"] for r in reviews], "approved", [r["iid"] for r in approved])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ongoing [36] approved []"* ]]
}

@test "the approved list carries the same total order as the ongoing one" {
    run wa '
def approval(when):
    return note("kyle", when, "approved this merge request", system=True)
mrs = [mr(41, author="a", updated="2026-06-10T09:00:00.000Z"),
       mr(42, author="b", updated="2026-06-10T09:00:00.000Z"),
       mr(43, author="c", updated="2026-06-10T09:00:00.000Z")]
disc = {41: [{"notes": [approval("2026-06-10T09:00:00.000Z")]}],
        42: [{"notes": [approval("2026-06-10T09:00:00.000Z")]}],
        43: [{"notes": [approval("2026-06-10T09:00:00.000Z")]}]}
wa.glab = fake_glab(mrs, disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
approved = wa.ledger_you_owe("repo", "kyle")[5]
print("order", [r["iid"] for r in approved])'
    [ "$status" -eq 0 ]
    # Same age and same turn, so only the iid can separate them -- the tiebreak the
    # brief cache depends on holds on this list too.
    [[ "$output" == *"order [41, 42, 43]"* ]]
}

@test "approving does not inflate the count of requests the ledger stopped demanding" {
    # covered is a claim about review REQUESTS the ledger dropped. A finished review is a
    # different fact and adding it here would make both numbers unreadable.
    run wa '
disc = {44: [{"notes": [note("kyle", "2026-06-02T09:00:00.000Z"),
                        note("kyle", "2026-06-10T09:00:00.000Z",
                             "approved this merge request", system=True)]}]}
wa.glab = fake_glab([mr(44, author="logan", updated="2026-06-10T09:00:00.000Z")], disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
rows, covered, whole, reviews, drafts, approved = wa.ledger_you_owe("repo", "kyle")
print("covered", covered, "approved", len(approved), "ledger_rows", len(rows))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"covered 1 approved 1 ledger_rows 0"* ]]
}

@test "the ledger carries both lists and counts the finished one" {
    run wa '
disc = {45: [{"notes": [note("kyle", "2026-06-10T09:00:00.000Z",
                             "approved this merge request", system=True)]}],
        46: [{"notes": [note("logan", "2026-06-01T09:00:00.000Z")]}]}
mrs = [mr(45, author="logan", updated="2026-06-10T09:00:00.000Z"),
       mr(46, author="logan", updated="2026-06-01T09:00:00.000Z")]
wa.glab = fake_glab(mrs, disc)
wa.shutil.which = lambda n: "/usr/bin/" + n
wa.ledger_they_owe = lambda r, m, me: ([], True)
wa.ledger_jira_stalled = lambda: ([], True)
wa.ledger_slack = lambda: ([], [], True, True)
wa.ledger_meetings = lambda: ([], True)
led = wa.build_ledger("repo", [])
print("ongoing", [r["iid"] for r in led["reviews"]])
print("approved", [r["iid"] for r in led["reviews_approved"]],
      "n", led["reviews_approved_n"])
print("known", led["reviews_known"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"ongoing [46]"* ]]
    [[ "$output" == *"approved [45] n 1"* ]]
    [[ "$output" == *"known True"* ]]
}

@test "an acknowledgement survives the row being approved away" {
    # The prune deletes a dismissal whose row no longer exists. A row that merely changed
    # lists still exists, and pruning it would un-acknowledge the revived row later.
    run wa '
r = {"iid": 47, "ref": "!47", "fp": "deadbeefdeadbeef", "url": "u", "author": "logan",
     "title": "t", "whose_turn": "theirs", "rounds": 1, "approved_covers": True}
led = {"they_owe": [], "you_owe": [], "reviews": [], "reviews_approved": [r],
       "complete": True}
import json, pathlib
store = pathlib.Path(wa.DISMISSED)
store.parent.mkdir(parents=True, exist_ok=True)
store.write_text(json.dumps({"deadbeefdeadbeef": {"at": "2026-06-01", "ref": "!47"}}))
kept = wa.apply_dismissals(led, [], None, prune=True)
print("kept", sorted(kept), "on_disk", sorted(json.loads(store.read_text())))
print("marked", led["reviews_approved"][0].get("dismissed"))'
    [ "$status" -eq 0 ]
    [[ "$output" == *"kept ['deadbeefdeadbeef'] on_disk ['deadbeefdeadbeef']"* ]]
    [[ "$output" == *"marked True"* ]]
}

# ── R7: what the run-over-run diff says about an approval ─────────────────────

@test "approving reads as movement off the list and never as the merge request vanishing" {
    run wa '
def snap(live, ap, gen):
    def row(iid, turn):
        return {"iid": iid, "ref": "!%d" % iid, "url": "u", "author": "logan",
                "title": "t", "whose_turn": turn, "rounds": 1, "my_last": 1,
                "their_last": 2, "arc": None}
    return wa.snapshot_of([], None, {"mrs": True, "ledger": True, "issues": True,
                                     "reviews": True}, "ul", gen,
                          [row(i, "mine") for i in live], [row(i, "theirs") for i in ap])
a = snap([50], [], "2026-08-01T09:00:00+0000")
b = snap([], [50], "2026-08-02T09:00:00+0000")
c = snap([50], [], "2026-08-03T09:00:00+0000")
d = snap([], [], "2026-08-04T09:00:00+0000")
print("approved", [(x["kind"], x["ref"]) for x in wa.diff_runs(a, b, [], None)["reviews"]])
print("revived", [x["kind"] for x in wa.diff_runs(b, c, [], None)["reviews"]])
print("still_approved", [x["kind"] for x in wa.diff_runs(b, b, [], None)["reviews"]])
print("gone", [x["kind"] for x in wa.diff_runs(b, d, [], None)["reviews"]])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"approved [('approved', '!50')]"* ]]
    [[ "$output" == *"revived ['revived']"* ]]
    [[ "$output" == *"still_approved []"* ]]
    [[ "$output" == *"gone ['gone']"* ]]
}

@test "a merge request first seen already approved is not news" {
    # Nothing moved between the two runs; this one simply looked and found finished work.
    # Announcing it would put a line in the diff for every review approved before the
    # feature that reads approvals existed.
    run wa '
def snap(ap, gen):
    rows = [{"iid": i, "ref": "!%d" % i, "url": "u", "author": "logan", "title": "t",
             "whose_turn": "theirs", "rounds": 1, "my_last": 1, "their_last": 2,
             "arc": None} for i in ap]
    return wa.snapshot_of([], None, {"mrs": True, "ledger": True, "issues": True,
                                     "reviews": True}, "ul", gen, [], rows)
a = snap([], "2026-08-01T09:00:00+0000")
b = snap([51], "2026-08-02T09:00:00+0000")
print("changes", wa.diff_runs(a, b, [], None)["reviews"])'
    [ "$status" -eq 0 ]
    [[ "$output" == *"changes []"* ]]
}

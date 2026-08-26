#!/usr/bin/env bats
# Tests for the orch join: the sessions that did the work, on the arcs they did it to.
#
# Kyle: "if my brain is one my brain is in the other" -- orch holds which sessions are
# running right now and the one-line summary each idle one left behind, and work-arcs
# held neither.
#
# And the law that decides the shape of all of it, verbatim: "currently a workstream in
# orch _is_ a worktree, which is not necessarily the right mapping. a session often ends
# up doing its work in a different worktree." So THE JOIN UNIT IS THE SESSION. What is
# pinned here is that consequence, over and over from different angles:
#
#   * an orch workstream is a LABEL on a session and never its attribution;
#   * a session attributes to the arc owning the branch of its MOST RECENT turn, from
#     work-arcs' own turn evidence and from nothing orch says;
#   * a session that named a branch from a DIFFERENT repo attributes to nothing, because
#     `main` is a branch in every repo on this machine;
#   * the database's project_dir is never decoded, which is the trap orch's own decoder
#     fights and loses on this machine's dotted worktree names.
#
# Every source is a fixture reached through its env knob, so nothing here reads the live
# machine: not the real orch database, not ~/.claude/sessions, not orch's data.json, not
# its notification log. A test that read those would pass or fail depending on what Kyle
# happened to have running.
#
# Nothing here pins wording.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    # Every source of orch's, pointed at a fixture. Resolved when work-arcs is imported,
    # so these must be exported before the python below runs -- which is why they are
    # here and not in each test.
    export WORK_ARCS_ORCH_DB="$TEST_TMPDIR/orch-sessions.db"
    export WORK_ARCS_CLAUDE_SESSIONS_DIR="$TEST_TMPDIR/claude-sessions"
    export WORK_ARCS_ORCH_DATA="$TEST_TMPDIR/data.json"
    export WORK_ARCS_ORCH_NOTIFICATIONS="$TEST_TMPDIR/notifications.jsonl"
    export WORK_ARCS_PROJECTS="$TEST_TMPDIR/projects"
    mkdir -p "$WORK_ARCS_CLAUDE_SESSIONS_DIR" "$WORK_ARCS_PROJECTS"
    # A real repo, because the repo test encodes real worktree paths and there is nothing
    # to encode without one. One worktree with a dotted name, which is the shape orch's
    # own decoder mis-handles and therefore the shape worth having in the fixture.
    ARC_REPO="$TEST_TMPDIR/repo"
    export ARC_REPO
    git init -q -b main "$ARC_REPO"
    git -C "$ARC_REPO" config user.email kyle@example.com
    git -C "$ARC_REPO" config user.name "Kyle Grimsrud-Manz"
    git -C "$ARC_REPO" commit -q --allow-empty -m base
    git -C "$ARC_REPO" branch -q UB-1
    git -C "$ARC_REPO" worktree add -q "$TEST_TMPDIR/repo.UB-1-a-dotted-name" UB-1
}

teardown() {
    teardown_temp_dir
}

# Runs a python snippet with work-arcs imported as wa, plus fixture builders for each of
# orch's four sources. Nothing is created until a test asks for it, so "the database does
# not exist" is a state a test can simply not leave.
wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" "$ARC_REPO" <<PY
import importlib.machinery, importlib.util, json, os, sqlite3, sys, time
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
REPO = sys.argv[2]
sys.argv = ["wa"]
loader.exec_module(wa)

TMP = Path(os.environ["TEST_TMPDIR"])
PROJECTS = Path(os.environ["WORK_ARCS_PROJECTS"])

DB_COLUMNS = ("session_id", "project_dir", "project_path", "title", "started_at",
              "last_activity", "message_count", "jsonl_path", "is_live",
              "files_mutated", "git_branch", "last_assistant_message_text")

def db(rows, columns=DB_COLUMNS):
    """orch's session database, with only the columns asked for.

    Column list is a parameter so a test can build the database an OLDER orch wrote --
    one with no last_assistant_message_text in it at all.
    """
    path = Path(os.environ["WORK_ARCS_ORCH_DB"])
    con = sqlite3.connect(path)
    cols = ", ".join("%s TEXT" % c if c not in ("message_count", "is_live")
                     else "%s INTEGER" % c for c in columns)
    con.execute("create table sessions (%s, primary key (session_id))" % cols)
    for r in rows:
        vals = [r.get(c, 0 if c in ("message_count", "is_live") else "")
                for c in columns]
        con.execute("insert into sessions (%s) values (%s)"
                    % (", ".join(columns), ", ".join("?" * len(columns))), vals)
    con.commit()
    con.close()

def live(rows):
    """Claude Code's per-process status files. One per row, named by pid like the real ones."""
    d = Path(os.environ["WORK_ARCS_CLAUDE_SESSIONS_DIR"])
    d.mkdir(parents=True, exist_ok=True)
    for i, r in enumerate(rows):
        row = {"pid": 1000 + i, "updatedAt": 1787000000000 + i}
        row.update(r)
        (d / ("%d.json" % row["pid"])).write_text(json.dumps(row))

def data(workstreams):
    Path(os.environ["WORK_ARCS_ORCH_DATA"]).write_text(
        json.dumps({"workstreams": list(workstreams)}))

def notes(rows):
    """orch's notification log: one json object per line, oldest first."""
    Path(os.environ["WORK_ARCS_ORCH_NOTIFICATIONS"]).write_text(
        "".join(json.dumps(r) + "\n" for r in rows))

def transcript(sid, at=REPO):
    """Where a session's transcript would sit, for a session that ran in *at*.

    Encoded the way Claude Code names the directory, which is the same function the join
    uses -- there is no second implementation here to disagree with it.
    """
    return str(PROJECTS / wa._encoded_dir(at) / ("%s.jsonl" % sid))

def sidx(pairs):
    """A session index: (branch, session id, epoch, where it ran) tuples.

    Only the two fields the join reads -- the transcript paths and the per-session
    recency. The rest of what session_index returns is not consulted by any of this.
    """
    idx = {}
    for branch, sid, epoch, at in pairs:
        e = idx.setdefault(branch, {"paths": set(), "sess": {}, "entries": 0, "last": 0})
        e["paths"].add(transcript(sid, at))
        e["sess"][sid] = max(epoch, e["sess"].get(sid, 0))
        e["last"] = max(epoch, e["last"])
    return idx

def arc(aid, branches, label=None):
    return {"id": aid, "label": label or aid,
            "branches": [{"name": b} for b in branches]}

NOW = int(time.time())

$1
PY
}

# ── the session is the join unit ──────────────────────────────────────────────

@test "a session attributes to the arc owning the branch of its most recent turn" {
    run wa '
db([{"session_id": "s1", "last_activity": "z", "title": "orch:whatever"}])
live([{"sessionId": "s1", "status": "busy", "cwd": REPO, "name": "orch:whatever"}])
data([])
arcs = [arc("a1", ["UB-1"]), arc("a2", ["UB-2"])]
# The same session on both branches, later on UB-2.
idx = sidx([("UB-1", "s1", NOW - 900, REPO), ("UB-2", "s1", NOW, REPO)])
bench, known, why, states = wa.orch_join(arcs, idx, Path(REPO))
print(arcs[0]["orch"]["n"], arcs[1]["orch"]["n"])
print(bench[0]["arc"], bench[0]["branch"], bench[0]["also_touched"])'
    [ "${lines[0]}" = "0 1" ]
    [ "${lines[1]}" = "a2 UB-2 1" ]
}

@test "the workstream that spawned a session is a label on it, never its attribution" {
    # The law, stated as a test. The session was launched from a workstream named after
    # one ticket and did its work on a branch belonging to another, which is the case
    # Kyle says is normal -- and the arc it lands on has to be the second one.
    run wa '
db([{"session_id": "s1", "title": "orch:UL-1853: FE: metadata geometry"}])
live([{"sessionId": "s1", "status": "idle", "cwd": REPO,
       "name": "orch:UL-1853: FE: metadata geometry"}])
data([])
arcs = [arc("a1", ["UB-1"], label="UB-6919")]
bench, known, why, states = wa.orch_join(
    arcs, sidx([("UB-1", "s1", NOW, REPO)]), Path(REPO))
print(bench[0]["via"])
print(bench[0]["arc"], bench[0]["arc_label"])'
    [ "${lines[0]}" = "UL-1853: FE: metadata geometry" ]
    [ "${lines[1]}" = "a1 UB-6919" ]
}

@test "a session that named the same branch name in another repo attributes to nothing" {
    # main is a branch in every repo on this machine and there are fifty sessions live in
    # half a dozen of them. Without the repo test they would all land on whichever arc
    # held a branch of the same name.
    run wa '
db([{"session_id": "here"}, {"session_id": "elsewhere"}])
live([{"sessionId": "here", "status": "busy", "cwd": REPO},
      {"sessionId": "elsewhere", "status": "busy", "cwd": str(TMP / "other")}])
data([])
arcs = [arc("a1", ["main"])]
bench, known, why, states = wa.orch_join(
    arcs, sidx([("main", "here", NOW, REPO),
                ("main", "elsewhere", NOW, str(TMP / "other"))]), Path(REPO))
print(arcs[0]["orch"]["n"])
print(sorted((b["id"], b["arc"] or "-") for b in bench))'
    [ "${lines[0]}" = "1" ]
    [ "${lines[1]}" = "[('elsewhere', '-'), ('here', 'a1')]" ]
}

@test "a worktree with a dotted name is still this repo, without decoding anything" {
    # The trap: orch's own decoder guesses dashes back into slashes and dots by testing
    # which candidate paths exist, and gets ul.UB-1852 wrong. Encoding forward has nothing
    # to guess, so a session that ran in a dotted worktree attributes normally.
    run wa '
wt = str(TMP / "repo.UB-1-a-dotted-name")
db([{"session_id": "s1"}])
live([{"sessionId": "s1", "status": "busy", "cwd": wt}])
data([])
arcs = [arc("a1", ["UB-1"])]
bench, known, why, states = wa.orch_join(
    arcs, sidx([("UB-1", "s1", NOW, wt)]), Path(REPO))
print(arcs[0]["orch"]["n"], bench[0]["arc"])'
    [ "$output" = "1 a1" ]
}

@test "a branch-name prefix does not swallow a longer repo name" {
    run wa '
print(wa._in_repo("-home-kyle-repos-ul", ("-home-kyle-repos-ul",)),
      wa._in_repo("-home-kyle-repos-ul-UB-1", ("-home-kyle-repos-ul",)),
      wa._in_repo("-home-kyle-repos-ultimate", ("-home-kyle-repos-ul",)),
      wa._in_repo("", ("-home-kyle-repos-ul",)))'
    [ "$output" = "True True False False" ]
}

@test "the encoding is the one Claude Code uses for both separators" {
    run wa '
print(wa._encoded_dir("/home/kyle/work/repos/ul"))
print(wa._encoded_dir("/home/kyle/work/repos/ul.6919-review"))
print(wa._encoded_dir("/home/kyle/.dotfiles"))'
    [ "${lines[0]}" = "-home-kyle-work-repos-ul" ]
    [ "${lines[1]}" = "-home-kyle-work-repos-ul-6919-review" ]
    [ "${lines[2]}" = "-home-kyle--dotfiles" ]
}

@test "a session that swept three arcs says so rather than claiming all three" {
    run wa '
db([{"session_id": "s1"}])
live([{"sessionId": "s1", "status": "idle", "cwd": REPO}])
data([])
arcs = [arc("a1", ["UB-1"]), arc("a2", ["UB-2"]), arc("a3", ["UB-3"])]
idx = sidx([("UB-1", "s1", NOW - 60, REPO), ("UB-2", "s1", NOW - 30, REPO),
            ("UB-3", "s1", NOW, REPO)])
bench, known, why, states = wa.orch_join(arcs, idx, Path(REPO))
print([a["orch"]["n"] for a in arcs], bench[0]["also_touched"])'
    [ "$output" = "[0, 0, 1] 2" ]
}

# ── liveness has one author ───────────────────────────────────────────────────

@test "a status file says a session is live and the database's own column does not" {
    run wa '
db([{"session_id": "s1", "is_live": 1}, {"session_id": "s2", "is_live": 0}])
live([{"sessionId": "s2", "status": "busy", "cwd": REPO}])
data([])
arcs = [arc("a1", ["UB-1"])]
idx = sidx([("UB-1", "s1", NOW, REPO), ("UB-1", "s2", NOW, REPO)])
bench, known, why, states = wa.orch_join(arcs, idx, Path(REPO))
print(sorted((s["id"], s["live"]) for s in arcs[0]["orch"]["sessions"]))
print([b["id"] for b in bench])'
    [ "${lines[0]}" = "[('s1', False), ('s2', True)]" ]
    [ "${lines[1]}" = "['s2']" ]
}

@test "with the status directory gone, the database's is_live is the fallback" {
    run wa '
import shutil
shutil.rmtree(os.environ["WORK_ARCS_CLAUDE_SESSIONS_DIR"])
db([{"session_id": "s1", "is_live": 1}])
data([])
arcs = [arc("a1", ["UB-1"])]
bench, known, why, states = wa.orch_join(
    arcs, sidx([("UB-1", "s1", NOW, REPO)]), Path(REPO))
print(known, arcs[0]["orch"]["sessions"][0]["live"], len(bench))
print("said something" if why else "said nothing")'
    [ "${lines[0]}" = "True True 1" ]
    [ "${lines[1]}" = "said something" ]
}

@test "the state is whatever Claude Code says it is, including a word this file does not know" {
    # status is Claude Code's vocabulary, not this file's: a session sitting at a shell
    # prompt writes "shell". Narrowing it to a known pair would report that as unknown,
    # which is a claim about our ignorance dressed as a fact about the session.
    run wa '
db([{"session_id": "s1"}, {"session_id": "s2"}, {"session_id": "s3"}])
live([{"sessionId": "s1", "status": "shell", "cwd": REPO},
      {"sessionId": "s2", "cwd": REPO},
      {"sessionId": "s3", "status": "busy", "cwd": REPO}])
data([])
bench, known, why, states = wa.orch_join([], {}, Path(REPO))
print(sorted((b["id"], str(b["state"])) for b in bench))'
    [ "$output" = "[('s1', 'shell'), ('s2', 'None'), ('s3', 'busy')]" ]
}

@test "the bench holds every live session, and names the ones landing nowhere as null" {
    run wa '
db([{"session_id": "s1"}, {"session_id": "s2"}])
live([{"sessionId": "s1", "status": "busy", "cwd": REPO},
      {"sessionId": "s2", "status": "busy", "cwd": str(TMP / "elsewhere")}])
data([])
arcs = [arc("a1", ["UB-1"])]
bench, known, why, states = wa.orch_join(
    arcs, sidx([("UB-1", "s1", NOW, REPO)]), Path(REPO))
print(len(bench), [b["arc"] for b in bench])'
    [ "$output" = "2 ['a1', None]" ]
}

@test "the bench is totally ordered: on a workstream here first, then mid-turn, then the id" {
    run wa '
db([{"session_id": "s%d" % i} for i in range(1, 6)])
live([{"sessionId": "s1", "status": "idle", "cwd": REPO, "statusUpdatedAt": 1787000000000},
      {"sessionId": "s2", "status": "busy", "cwd": str(TMP / "x"), "statusUpdatedAt": 1787000000000},
      {"sessionId": "s3", "status": "busy", "cwd": REPO, "statusUpdatedAt": 1787000000000},
      {"sessionId": "s4", "status": "busy", "cwd": REPO, "statusUpdatedAt": 1787000000000},
      {"sessionId": "s5", "status": "idle", "cwd": str(TMP / "x"), "statusUpdatedAt": 1787000000000}])
data([])
arcs = [arc("a1", ["UB-1"])]
idx = sidx([("UB-1", s, NOW, REPO) for s in ("s1", "s3", "s4")])
bench, known, why, states = wa.orch_join(arcs, idx, Path(REPO))
print([b["id"] for b in bench])'
    [ "$output" = "['s3', 's4', 's1', 's2', 's5']" ]
}

# ── the summary, and which source it came from ────────────────────────────────

@test "the summary is the database's assistant text, clipped, and says so" {
    run wa '
long = "word " * 200
db([{"session_id": "s1", "last_assistant_message_text": long}])
live([{"sessionId": "s1", "status": "idle", "cwd": REPO}])
data([])
bench, known, why, states = wa.orch_join([], {}, Path(REPO))
s = bench[0]
print(s["summary_src"], len(s["summary"]) <= wa.ORCH_SUMMARY_CHARS + 1,
      s["summary"].endswith(chr(8230)))'
    [ "$output" = "assistant True True" ]
}

@test "a row with no assistant text falls back to the last notification line, and says so" {
    run wa '
db([{"session_id": "s1"}])
live([{"sessionId": "s1", "status": "idle", "cwd": REPO}])
data([])
notes([{"session_id": "s1", "message": "an older word"},
       {"session_id": "other", "message": "not this one"},
       {"session_id": "s1", "message": "the last word"}])
bench, known, why, states = wa.orch_join([], {}, Path(REPO))
print(bench[0]["summary_src"], "|", bench[0]["summary"])'
    [ "$output" = "notification | the last word" ]
}

@test "a session nothing has said anything about carries no summary rather than an empty one" {
    run wa '
db([{"session_id": "s1"}])
live([{"sessionId": "s1", "status": "idle", "cwd": REPO}])
data([])
bench, known, why, states = wa.orch_join([], {}, Path(REPO))
print(bench[0]["summary"], bench[0]["summary_src"])'
    [ "$output" = "None None" ]
}

@test "the notification scan says when it gave up before answering" {
    run wa '
notes([{"session_id": "wanted", "message": "far back"}]
      + [{"session_id": "x", "message": "filler"} for _ in range(30)])
got, why = wa._orch_notifications({"wanted"}, cap=5)
print(got, "|", "said something" if why else "said nothing")
got, why = wa._orch_notifications({"wanted"}, cap=100)
print(got["wanted"], "|", "said something" if why else "said nothing")'
    [ "${lines[0]}" = "{} | said something" ]
    [ "${lines[1]}" = "far back | said nothing" ]
}

# ── provenance, which is a label ──────────────────────────────────────────────

@test "the workstream label comes from the status file, then the database, then the path" {
    run wa '
db([{"session_id": "s1", "title": "orch:from the database"},
    {"session_id": "s2", "title": "orch:from the database"},
    {"session_id": "s3", "title": "not an orch title"},
    {"session_id": "s4", "title": ""}])
live([{"sessionId": "s1", "status": "idle", "cwd": REPO, "name": "orch:from the file"},
      {"sessionId": "s3", "status": "idle", "cwd": REPO},
      {"sessionId": "s4", "status": "idle", "cwd": REPO}])
data([{"name": "from the path", "repo_path": REPO}])
bench, known, why, states = wa.orch_join([], {}, Path(REPO))
seen = {b["id"]: b["via"] for b in bench}
print(seen["s1"], "|", seen["s3"], "|", seen["s4"])
rows = wa._orch_db()[0]
print(wa._orch_via(None, rows["s2"], {}))'
    [ "${lines[0]}" = "from the file | from the path | from the path" ]
    [ "${lines[1]}" = "from the database" ]
}

@test "a session with no workstream anywhere says null rather than guessing one" {
    run wa '
db([{"session_id": "s1"}])
live([{"sessionId": "s1", "status": "idle", "cwd": str(TMP / "nowhere")}])
data([{"name": "some other thing", "repo_path": REPO}])
bench, known, why, states = wa.orch_join([], {}, Path(REPO))
print(bench[0]["via"])'
    [ "$output" = "None" ]
}

@test "auto is only true for a loop that is actually running" {
    run wa '
db([{"session_id": "s1"}, {"session_id": "s2"}, {"session_id": "s3"}])
live([{"sessionId": s, "status": "idle", "cwd": REPO} for s in ("s1", "s2", "s3")])
data([{"name": "running", "repo_path": REPO, "auto_running": True,
       "auto_current_todo_id": "t1", "auto_coord_sid": "s1", "auto_impl_sids": ["s2"]},
      {"name": "finished", "repo_path": str(TMP / "b"), "auto_running": False,
       "auto_current_todo_id": "t9", "auto_coord_sid": "s3", "auto_impl_sids": []}])
bench, known, why, states = wa.orch_join([], {}, Path(REPO))
seen = {b["id"]: (b["auto"], b["auto_todo"]) for b in bench}
print(seen["s1"], seen["s2"], seen["s3"])'
    [ "$output" = "(True, 't1') (True, 't1') (False, '')" ]
}

# ── an unreadable source is unknown, never empty ──────────────────────────────

@test "with nothing of orch's readable, what is running is unknown and says why" {
    run wa '
import shutil
shutil.rmtree(os.environ["WORK_ARCS_CLAUDE_SESSIONS_DIR"])
bench, known, why, states = wa.orch_join([arc("a1", ["UB-1"])], {}, Path(REPO))
print(known, len(bench), bool(why))'
    [ "$output" = "False 0 True" ]
}

@test "one source failing does not make the others unknown" {
    run wa '
live([{"sessionId": "s1", "status": "busy", "cwd": REPO}])
# No database, no data.json, no notification log.
arcs = [arc("a1", ["UB-1"])]
bench, known, why, states = wa.orch_join(
    arcs, sidx([("UB-1", "s1", NOW, REPO)]), Path(REPO))
print(known, len(bench), bench[0]["arc"], bench[0]["state"])
print(bool(why))'
    [ "${lines[0]}" = "True 1 a1 busy" ]
    [ "${lines[1]}" = "True" ]
}

@test "a database written by an older orch is read for the columns it does have" {
    run wa '
cols = ("session_id", "title", "is_live", "last_activity", "message_count")
db([{"session_id": "s1", "title": "orch:old build", "is_live": 1,
     "last_activity": "2026-08-01T00:00:00Z", "message_count": 7}], columns=cols)
live([{"sessionId": "s1", "status": "idle", "cwd": REPO}])
data([])
bench, known, why, states = wa.orch_join([], {}, Path(REPO))
print(known, bench[0]["via"], "|", bench[0]["messages"], bench[0]["summary"])'
    [ "$output" = "True old build | 7 None" ]
}

@test "every arc carries an orch key, so nothing running is a zero and not a missing key" {
    run wa '
db([])
live([])
data([])
arcs = [arc("a1", ["UB-1"]), arc("a2", ["UB-2"])]
bench, known, why, states = wa.orch_join(arcs, {}, Path(REPO))
print(known, [a["orch"] for a in arcs] == [{"sessions": [], "n": 0, "more": 0, "live": 0}] * 2)'
    [ "$output" = "True True" ]
}

# ── caps are announced ────────────────────────────────────────────────────────

@test "an arc names three sessions and counts the rest" {
    run wa '
ids = ["s%d" % i for i in range(1, 8)]
db([{"session_id": s} for s in ids])
live([{"sessionId": "s7", "status": "busy", "cwd": REPO}])
data([])
arcs = [arc("a1", ["UB-1"])]
# s1 is the newest of the idle ones; s7 is live and must lead whatever its turn said.
idx = sidx([("UB-1", s, NOW - i * 60, REPO) for i, s in enumerate(ids)])
bench, known, why, states = wa.orch_join(arcs, idx, Path(REPO))
o = arcs[0]["orch"]
print(o["n"], o["more"], o["live"], [s["id"] for s in o["sessions"]])'
    [ "$output" = "7 4 1 ['s7', 's1', 's2']" ]
}

@test "a session orch knows nothing about is not a row of nulls on a card" {
    run wa '
db([{"session_id": "known"}])
live([])
data([])
arcs = [arc("a1", ["UB-1"])]
idx = sidx([("UB-1", "known", NOW, REPO), ("UB-1", "stranger", NOW, REPO)])
bench, known, why, states = wa.orch_join(arcs, idx, Path(REPO))
print(arcs[0]["orch"]["n"], [s["id"] for s in arcs[0]["orch"]["sessions"]])'
    [ "$output" = "1 ['known']" ]
}

# ── what moved since the last build ───────────────────────────────────────────

@test "a session going idle, picking up again, or appearing is each a line" {
    run wa '
k = {"mrs": True, "ledger": True, "issues": True, "slack": True, "reviews": True,
     "orch": True}
def snap(bench, gen):
    return wa.snapshot_of([], None, k, "ul", gen, sessions=wa._orch_snapshot(bench))
def s(sid, state, label):
    return {"id": sid, "state": state, "arc": "a1", "arc_label": label, "via": "ws"}
was = snap([s("a", "busy", "UB-6802"), s("b", "idle", "UB-6802"),
            s("gone", "busy", "UB-6802")], "2026-08-26T01:00:00-0700")
now = snap([s("a", "idle", "UB-6802"), s("b", "busy", "UB-6802"),
            s("new", "busy", "UB-6802")], "2026-08-26T02:00:00-0700")
d = wa.diff_runs(was, now, [], None)
for c in d["sessions"]:
    print(c["kind"], c["id"], "|", c["what"])'
    [ "${#lines[@]}" -eq 3 ]
    [ "${lines[0]}" = "went_idle a | a session on UB-6802 went idle" ]
    [ "${lines[1]}" = "appeared new | a session started on UB-6802" ]
    [ "${lines[2]}" = "went_busy b | a session on UB-6802 picked up again" ]
}

@test "a session that simply exited is not a line" {
    # A status file disappears every time a window is closed, fifty-odd times a day here.
    # The interesting half of that event is the summary it left, which lands on the arc.
    run wa '
k = {"mrs": True, "ledger": True, "issues": True, "slack": True, "reviews": True,
     "orch": True}
def snap(bench, gen):
    return wa.snapshot_of([], None, k, "ul", gen, sessions=wa._orch_snapshot(bench))
row = {"id": "a", "state": "busy", "arc": "a1", "arc_label": "UB-6802", "via": "ws"}
d = wa.diff_runs(snap([row], "2026-08-26T01:00:00-0700"),
                 snap([], "2026-08-26T02:00:00-0700"), [], None)
print(d["sessions"])'
    [ "$output" = "[]" ]
}

@test "a run that could not read orch compares no sessions" {
    run wa '
def snap(bench, gen, **known):
    k = {"mrs": True, "ledger": True, "issues": True, "slack": True, "reviews": True,
         "orch": True}
    k.update(known)
    return wa.snapshot_of([], None, k, "ul", gen, sessions=wa._orch_snapshot(bench))
row = {"id": "a", "state": "busy", "arc": "a1", "arc_label": "UB-6802", "via": "ws"}
now = {"id": "a", "state": "idle", "arc": "a1", "arc_label": "UB-6802", "via": "ws"}
d = wa.diff_runs(snap([row], "2026-08-26T01:00:00-0700", orch=False),
                 snap([now], "2026-08-26T02:00:00-0700"), [], None)
print(d["sessions"], "orch" in d["skipped_universes"])'
    [ "$output" = "[] True" ]
}

@test "a snapshot taken before this existed is silent for one run, not a flood" {
    # The v1 contract: a new universe is added without bumping the version, and `known` is
    # what makes that safe. An old snapshot carries no known["orch"], so the gate reads
    # false and every other comparison goes on working.
    run wa '
old = {"v": 1, "generated": "2026-08-26T01:00:00-0700", "repo": "ul",
       "known": {"mrs": True, "ledger": True, "issues": True}, "arcs": []}
row = {"id": "a", "state": "busy", "arc": None, "arc_label": "", "via": "ws"}
new = wa.snapshot_of([], None, {"mrs": True, "ledger": True, "issues": True,
                                "orch": True}, "ul",
                     "2026-08-26T02:00:00-0700", sessions=wa._orch_snapshot([row]))
d = wa.diff_runs(old, new, [], None)
print(d["sessions"], d["compared"], "orch" in d["skipped_universes"])'
    [ "$output" = "[] 0 True" ]
}

@test "the session changes are totally ordered" {
    run wa '
k = {"mrs": True, "ledger": True, "issues": True, "slack": True, "reviews": True,
     "orch": True}
def snap(bench, gen):
    return wa.snapshot_of([], None, k, "ul", gen, sessions=wa._orch_snapshot(bench))
def s(sid, state):
    return {"id": sid, "state": state, "arc": None, "arc_label": "", "via": "ws"}
was = snap([s("z", "busy"), s("a", "busy")], "2026-08-26T01:00:00-0700")
now = snap([s("z", "idle"), s("a", "idle"), s("m", "busy"), s("b", "busy")],
           "2026-08-26T02:00:00-0700")
one = wa.diff_runs(was, now, [], None)["sessions"]
print([(c["kind"], c["id"]) for c in one])'
    [ "$output" = "[('went_idle', 'a'), ('went_idle', 'z'), ('appeared', 'b'), ('appeared', 'm')]" ]
}

# ── the turn evidence the join is built on ────────────────────────────────────

@test "the session index records when each session last named each branch" {
    if ! command -v rg >/dev/null; then skip "rg is what the index is built on"; fi
    d="$WORK_ARCS_PROJECTS/-tmp-somewhere"
    mkdir -p "$d"
    printf '%s\n' \
      '{"timestamp":"2026-08-20T10:00:00.000Z","gitBranch":"UB-1"}' \
      '{"timestamp":"2026-08-21T10:00:00.000Z","gitBranch":"UB-1"}' \
      '{"timestamp":"2026-08-22T10:00:00.000Z","gitBranch":"UB-2"}' > "$d/aaa.jsonl"
    printf '%s\n' \
      '{"timestamp":"2026-08-19T10:00:00.000Z","gitBranch":"UB-1"}' \
      '{"timestamp":"2026-08-19T11:00:00.000Z","gitBranch":"HEAD"}' > "$d/bbb.jsonl"
    run wa '
idx = wa.session_index(PROJECTS)
print(sorted(idx["UB-1"]["sess"]), sorted(idx["UB-2"]["sess"]))
print(idx["UB-1"]["sess"]["aaa"] > idx["UB-1"]["sess"]["bbb"])
print(idx["UB-1"]["entries"], idx["UB-1"]["last"] == idx["UB-1"]["sess"]["aaa"])'
    [ "${lines[0]}" = "['aaa', 'bbb'] ['aaa']" ]
    [ "${lines[1]}" = "True" ]
    [ "${lines[2]}" = "3 True" ]
}

@test "a run that could not read busy/idle compares no states" {
    # The narrower gate. With the status directory gone the sessions are still known --
    # the database says which are live -- and not one word about what any of them is
    # doing is. A snapshot of that against the next healthy run would report every
    # session on the machine as having just picked up work.
    run wa '
import shutil
shutil.rmtree(os.environ["WORK_ARCS_CLAUDE_SESSIONS_DIR"])
db([{"session_id": "s1", "is_live": 1}])
data([])
bench, known, why, states = wa.orch_join([], {}, Path(REPO))
print(known, states, len(bench), bench[0]["state"])
k = {"mrs": True, "ledger": True, "issues": True, "slack": True, "reviews": True}
was = wa.snapshot_of([], None, dict(k, orch=states), "ul", "2026-08-26T01:00:00-0700",
                     sessions=wa._orch_snapshot(bench))
now = wa.snapshot_of([], None, dict(k, orch=True), "ul", "2026-08-26T02:00:00-0700",
                     sessions={"s1": {"state": "busy", "arc": None, "label": "",
                                      "via": ""}})
d = wa.diff_runs(was, now, [], None)
print(d["sessions"], "orch" in d["skipped_universes"])'
    [ "${lines[0]}" = "True False 1 None" ]  # the database enumerates them, with no state
    [ "${lines[1]}" = "[] True" ]
}

@test "a branch nobody worked on in this repo has no sessions and no error" {
    run wa '
db([{"session_id": "s1"}])
live([])
data([])
arcs = [arc("a1", ["UB-9"])]
bench, known, why, states = wa.orch_join(
    arcs, sidx([("UB-1", "s1", NOW, REPO)]), Path(REPO))
print(known, arcs[0]["orch"]["n"], len(bench))'
    [ "$output" = "True 0 0" ]
}

#!/usr/bin/env bats
# Tests for where dangling work is reported, and where it must not be.
#
# Two complaints, and they pull in opposite directions. The first: "not every singular
# commit everywhere" -- the page must not diffuse a commit-count alarm across every card.
# The second, in the same breath: "i do often have a dangling commit that _is_ meaningful
# and i dont want to lose track of". One ranked, capped list answers both, and it is the
# absence of that list -- a tile saying how much work exists only on this laptop and
# nothing saying which -- that these pin.
#
# Alongside it, the two things the page said that were simply untrue. It offered a one-step
# command to file a Jira ticket for work that had already merged, and it rendered the
# literal "!None" against branches whose landing was detected rather than fetched.
#
# Real git repositories for the derivations, because days of work come out of author dates
# and there is nothing to derive from a fixture that hands them over. Rendered pages for
# the page's own claims, because the bug in both cases was in what reached the HTML.

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
    git -C "$ARC_REPO" config user.email test@example.com
    git -C "$ARC_REPO" config user.name Tester
    on main 2026-07-01 base
    git -C "$ARC_REPO" update-ref refs/remotes/origin/main main
}

teardown() {
    teardown_temp_dir
}

# One empty commit on a branch, authored on the day given. The offset is fixed so the day a
# commit lands on is a fact about the fixture and not about the machine's timezone.
on() {
    local branch="$1" day="$2" msg="$3"
    if git -C "$ARC_REPO" rev-parse --verify -q "$branch" >/dev/null; then
        git -C "$ARC_REPO" checkout -q "$branch"
    else
        git -C "$ARC_REPO" checkout -q -b "$branch"
    fi
    GIT_AUTHOR_DATE="$day 09:00:00 +0000" GIT_COMMITTER_DATE="$day 09:00:00 +0000" \
        git -C "$ARC_REPO" commit -q --allow-empty -m "$msg"
}

# Runs a python snippet with work-arcs imported as `wa`, against the fixture repo.
wa() {
    python3 - "$REPO_ROOT/bin/work-arcs" "$ARC_REPO" <<PY
import importlib.machinery, importlib.util, sys, json
loader = importlib.machinery.SourceFileLoader("wa", sys.argv[1])
spec = importlib.util.spec_from_loader("wa", loader)
wa = importlib.util.module_from_spec(spec)
REPO = sys.argv[2]
sys.argv = ["wa"]
loader.exec_module(wa)
wa.TICKET_RE = wa._ticket_re()

def br(name, **kw):
    b = {"name": name, "sha": "sha-" + name, "unpushed": 0, "commits_ahead": 0,
         "age_days": 5, "parents": [], "pushed": False, "committed": 0}
    b.update(kw)
    return b

def mr(iid, branch, **kw):
    m = {"iid": iid, "branch": branch, "title": "t", "url": "u", "draft": False,
         "updated": "2026-08-20T00:00:00Z", "threads": [], "reviewers": [],
         "assignees": [], "approvals": 0, "notes": 0, "conflicts": False}
    m.update(kw)
    return m

def arc(branches, mrs=(), repo=REPO, **kw):
    a = {"id": "a1", "label": "metadata-latlng", "kind": "cluster",
         "branches": list(branches), "mrs": list(mrs), "stashes": [], "sessions": [],
         "issues": [], "engagement": 400, "age_days": 5, "mrs_known": True}
    a.update(kw)
    wa.finalize(a, repo)
    return a

$1
PY
}

# Renders a whole page from a work-arcs document handed over as JSON on argv.
page() {
    python3 - "$REPO_ROOT/bin/arcs-page" "$1" <<'PY' > "$TEST_TMPDIR/page.html"
import json, subprocess, sys
doc = json.loads(sys.argv[2])
r = subprocess.run([sys.executable, sys.argv[1], "--focus", "30"],
                   input=json.dumps(doc), capture_output=True, text=True)
sys.stderr.write(r.stderr)
if r.returncode != 0:
    sys.exit(r.returncode)
sys.stdout.write(r.stdout)
PY
    cat "$TEST_TMPDIR/page.html"
}

# ── work with no ticket, and whether there is any work left in it ────────────

@test "an arc whose work landed is not offered a ticket to file" {
    # The whole defect, in one arc. It has no ticket, plenty of engagement and recent
    # activity -- every test the old filter applied -- and its merge request merged, which
    # was the one thing nothing asked.
    on shipped 2026-08-01 one
    run wa '
b = br("shipped", unpushed=3, pushed=True, commits_ahead=3,
       mr_fate={"state": "merged", "iid": 10348, "at": "2026-08-20", "url": "u"})
a = arc([b])
g = wa.reconcile([a], [])
print(a["settled"], "|", len(g["unticketed_work"]))'
    [ "${lines[0]}" = "landed | 0" ]
}

@test "an arc every branch of which was abandoned is not offered one either" {
    # Nobody files a ticket for work they dropped. `settled` says abandoned rather than
    # landed, and the section wants neither.
    on dropped 2026-08-01 one
    run wa '
b = br("dropped", unpushed=2, pushed=True, commits_ahead=2,
       mr_fate={"state": "closed", "iid": 10100, "at": "2026-08-20", "url": "u"})
a = arc([b])
g = wa.reconcile([a], [])
print(a["settled"], "|", len(g["unticketed_work"]))'
    [ "${lines[0]}" = "abandoned | 0" ]
}

@test "an open merge request with no ticket behind it still wants one filing" {
    # The case the section exists for, and the one a blunt "exclude anything with an MR"
    # would have swallowed. The work is proposed, it is out there, and Jira has never
    # heard of it.
    on live 2026-08-01 one
    run wa '
b = br("live", unpushed=0, pushed=True, commits_ahead=4)
a = arc([b], [mr(10500, "live", reviewers=["vadym"])])
g = wa.reconcile([a], [])
print(a["settled"], "|", len(g["unticketed_work"]), "|", g["unticketed_work"][0]["id"])'
    [ "${lines[0]}" = "None | 1 | a1" ]
}

@test "unpushed work with no ticket wants one filing" {
    on local 2026-08-01 one
    on local 2026-08-04 two
    run wa '
a = arc([br("local", unpushed=2)])
g = wa.reconcile([a], [])
print(len(g["unticketed_work"]), "|", a["unpushed_days"])'
    [ "${lines[0]}" = "1 | 2" ]
}

@test "drafts from before a sibling landed are residue, not work to file" {
    # `settled` is None here -- the surviving branch has no merge request of its own -- so
    # nothing but the rung can tell this apart from live work. The work shipped as a
    # reshape and what is left is deletable.
    on reshaped 2026-08-01 one
    run wa '
a = arc([br("reshaped", unpushed=1)], stage="pre-landing")
a["stage"] = "pre-landing"
g = wa.reconcile([a], [])
print(a["settled"], "|", len(g["unticketed_work"]))'
    [ "${lines[0]}" = "None | 0" ]
}

@test "an arc that already names a ticket is left alone whatever else is true" {
    on UL-1852 2026-08-01 one
    run wa '
a = arc([br("UL-1852", unpushed=2)])
g = wa.reconcile([a], [])
print(len(g["unticketed_work"]))'
    [ "${lines[0]}" = "0" ]
}

@test "two arcs tied on engagement come back in the same order twice" {
    # Total tiebreak, like every other ordering that reaches output: engagement is a
    # coarse integer and ties are ordinary.
    on one 2026-08-01 x
    on two 2026-08-01 y
    run wa '
a = arc([br("one", unpushed=1)], id="zeta", label="zeta")
b = arc([br("two", unpushed=1)], id="alpha", label="alpha")
first = [x["id"] for x in wa.reconcile([a, b], [])["unticketed_work"]]
second = [x["id"] for x in wa.reconcile([b, a], [])["unticketed_work"]]
print(first == second, first)'
    [ "${lines[0]}" = "True ['alpha', 'zeta']" ]
}

# ── which work exists only here, ranked ──────────────────────────────────────

@test "the at-risk ranking is days of work times how long nothing touched it" {
    # Neither half alone would do. Days alone ranks a fortnight committed this morning
    # above a week nobody has looked at since June; staleness alone ranks a one-line
    # scratch branch above a month of unpushed work.
    run wa '
def a(i, days, age):
    return {"id": i, "unpushed_live": days * 3, "unpushed_days": days, "age_days": age}
big_fresh   = a("big-fresh", 10, 1)
small_stale = a("small-stale", 1, 40)
mid         = a("mid", 4, 8)
print(wa.only_here([mid, small_stale, big_fresh]))'
    [ "${lines[0]}" = "['small-stale', 'mid', 'big-fresh']" ]
}

@test "work touched today is ranked on its size, not zeroed by its age" {
    # age_days is 0 on an arc committed to this morning, and a product with zero in it
    # would sort the largest live body of work to the bottom of a list about risk.
    run wa '
def a(i, days, age):
    return {"id": i, "unpushed_live": days * 3, "unpushed_days": days, "age_days": age}
print(wa.only_here([a("small-today", 1, 0), a("big-today", 9, 0)]))'
    [ "${lines[0]}" = "['big-today', 'small-today']" ]
}

@test "an arc with nothing unpushed is not in the at-risk ranking at all" {
    run wa '
pushed = {"id": "pushed", "unpushed_live": 0, "unpushed_days": 0, "age_days": 9}
held = {"id": "held", "unpushed_live": 6, "unpushed_days": 2, "age_days": 9}
print(wa.only_here([pushed, held]))'
    [ "${lines[0]}" = "['held']" ]
}

@test "the ranking covers work held on top of an open review, not just the rung" {
    # An arc out for review with a fortnight of unpushed work on top of its merge request
    # is holding exactly as much unrecoverable work as one that never pushed. The rung
    # says whose move it is; this says what is on the disk.
    run wa '
rung = {"id": "never-pushed", "stage": "local-only", "unpushed_live": 3,
        "unpushed_days": 1, "age_days": 2}
onmr = {"id": "in-review-too", "stage": "in-review", "unpushed_live": 30,
        "unpushed_days": 10, "age_days": 2}
print(wa.only_here([rung, onmr]))'
    [ "${lines[0]}" = "['in-review-too', 'never-pushed']" ]
}

@test "two arcs with identical risk come back in the same order twice" {
    run wa '
def a(i):
    return {"id": i, "unpushed_live": 6, "unpushed_days": 2, "age_days": 5}
print(wa.only_here([a("zeta"), a("alpha")]) == wa.only_here([a("alpha"), a("zeta")]),
      wa.only_here([a("zeta"), a("alpha")]))'
    [ "${lines[0]}" = "True ['alpha', 'zeta']" ]
}

# ── what the page renders ────────────────────────────────────────────────────

# A work-arcs document holding `n` local-only workstreams plus one landed arc whose merge
# request was detected rather than fetched, which is the shape that produced "!None".
doc() {
    python3 - "$1" <<'PY'
import json, sys
n = int(sys.argv[1])

def arc(i, days, age, name, **kw):
    a = {"id": name, "label": name, "kind": "cluster", "stage": "local-only",
         "state": str(days) + " days of work, only here",
         "unpushed_live": days * 3, "unpushed_days": days,
         "unpushed_dates": ["2026-08-%02d" % (d + 1) for d in range(days)],
         "age_days": age, "engagement": 300, "authoritative": "br-" + str(i),
         "branches": [], "mrs": [], "stashes": [], "sessions": [], "issues": [],
         "demands": [], "counts": {"branches": 1, "stashes": 0, "mrs": 0, "sessions": 1},
         "brief": {"name": name,
                   "summary": "It reroutes the thing. Then a second sentence nobody has "
                              "room for on one line."}}
    a.update(kw)
    return a

arcs = [arc(i, (i % 4) + 1, i + 1, "workstream " + str(i)) for i in range(n)]
landed = arc(99, 0, 4, "Dove travel-time filter allowlist stopgap",
             stage="landed", settled="landed", state="landed")
landed["unpushed_live"] = 0
landed["unpushed_days"] = 0
landed["unpushed_dates"] = []
landed["branches"] = [{"name": "dove-travel-time-allowlist", "unpushed": 0,
                       "mr_fate": {"state": "merged", "iid": None, "at": "",
                                   "url": "", "via": "squash"}}]
arcs.append(landed)
live = [x for x in arcs if x["unpushed_live"]]
live.sort(key=lambda x: (-(x["unpushed_days"] * max(x["age_days"], 1)), x["id"]))
print(json.dumps({
    "generated": 1756000000, "repo": "ul", "main": "origin/main", "me": "kyle",
    "project_url": "https://gitlab.example/ul", "arc_count": len(arcs),
    "arcs": arcs, "forgotten": [], "only_here": [x["id"] for x in live], "gap": None}))
PY
}

@test "a landing with no merge request to name names its branch, never !None" {
    # Three of the four ways work-arcs concludes a branch landed -- the squash index,
    # per-commit equivalence, ancestry under a merged tip -- record iid: None. The old
    # default of "?" was unreachable because the key existed.
    run page "$(doc 3)"
    [ "$status" -eq 0 ]
    [[ "$output" != *"!None"* ]]
    [[ "$output" == *"dove-travel-time-allowlist"* ]]
}

@test "the at-risk tile opens into the list of what is at risk" {
    run page "$(doc 3)"
    [[ "$output" == *'href="#only-here"'* ]]
    [[ "$output" == *'<details class="atrisk" id="only-here">'* ]]
}

@test "each at-risk row carries a name, a cost, a branch and a link to its card" {
    run page "$(doc 3)"
    [[ "$output" == *'class="riskrows"'* ]]
    [[ "$output" == *'<span class="dy">3 days of work</span>'* ]]
    [[ "$output" == *'<span class="br">br-2</span>'* ]]
    [[ "$output" == *'<span class="wy">It reroutes the thing.</span>'* ]]
    [[ "$output" == *'class="nm" href="#ws-workstream-2-'* ]]
}

@test "a row prints both figures its rank is made of, not only the cost" {
    # The order is days of work times staleness, so the days column does not descend. A
    # column of figures that does not descend reads as a broken sort unless the row also
    # carries the figure that broke it -- the same rule the morning brief follows about
    # its superlative.
    run page "$(doc 3)"
    [[ "$output" == *'<span class="dy">3 days of work</span><span class="ag">3d quiet</span>'* ]]
}

@test "the order named in the summary is the order the rows are in" {
    # Sixteen days of work touched yesterday sits below three days nobody has opened for a
    # month, and the row has to be able to say why.
    run python3 - "$(doc 2)" <<'PY'
import json, re, subprocess, sys
doc = json.loads(sys.argv[1])
live = [x for x in doc["arcs"] if x["unpushed_live"]]
live[0].update(unpushed_days=16, unpushed_live=48, age_days=1,
               unpushed_dates=["2026-08-%02d" % (d + 1) for d in range(16)])
live[1].update(unpushed_days=3, unpushed_live=9, age_days=30,
               unpushed_dates=["2026-08-%02d" % (d + 1) for d in range(3)])
live.sort(key=lambda x: (-(x["unpushed_days"] * max(x["age_days"], 1)), x["id"]))
doc["only_here"] = [x["id"] for x in live]
r = subprocess.run([sys.executable, "bin/arcs-page", "--focus", "40"],
                   input=json.dumps(doc), capture_output=True, text=True)
m = re.search(r'<details class="atrisk".*?</details>', r.stdout, re.S)
print(re.findall(r'<span class="dy">([^<]*)</span><span class="ag">([^<]*)</span>',
                 m.group(0)))
PY
    [ "${lines[0]}" = "[('3 days of work', '30d quiet'), ('16 days of work', '1d quiet')]" ]
}

@test "a row whose brief says nothing leaves the line blank rather than repeating the cost" {
    # For every arc in this list `state` IS the days-of-work sentence -- that is what puts
    # them on the local-only rung -- so falling back to it printed "3 days of work, only
    # here" beside a cell already reading "3 days of work".
    run python3 - "$(doc 1)" <<'PY'
import json, re, subprocess, sys
doc = json.loads(sys.argv[1])
for x in doc["arcs"]:
    if x["unpushed_live"]:
        x["brief"] = {"name": "no summary here"}
r = subprocess.run([sys.executable, "bin/arcs-page", "--focus", "30"],
                   input=json.dumps(doc), capture_output=True, text=True)
m = re.search(r'<details class="atrisk".*?</details>', r.stdout, re.S)
print("WY" if 'class="wy"' in m.group(0) else "NO-WY")
print("DUPE" if "only here" in m.group(0) else "NO-DUPE")
PY
    [ "${lines[0]}" = "NO-WY" ]
    [ "${lines[1]}" = "NO-DUPE" ]
}

@test "the rows come down the wire in the order work-arcs ranked them" {
    # Four workstreams, and the page must not re-derive their order. Reversing only the
    # ranking -- the arcs list untouched -- must reverse the rows.
    forward=$(page "$(doc 4)" | grep -o 'class="nm" href="#ws-workstream-[0-9]*')
    reversed=$(python3 - "$(doc 4)" <<'PY' | grep -o 'class="nm" href="#ws-workstream-[0-9]*'
import json, subprocess, sys
doc = json.loads(sys.argv[1])
doc["only_here"] = list(reversed(doc["only_here"]))
r = subprocess.run([sys.executable, "bin/arcs-page", "--focus", "30"],
                   input=json.dumps(doc), capture_output=True, text=True)
sys.stdout.write(r.stdout)
PY
)
    [ -n "$forward" ]
    [ "$forward" != "$reversed" ]
    [ "$(printf '%s\n' "$forward" | tac)" = "$reversed" ]
}

@test "the list stops at eight and says how many it left out" {
    # A list that stops silently reads as a complete list of eight.
    run page "$(doc 11)"
    rows=$(printf '%s\n' "$output" | grep -c 'class="nm" href="#ws-workstream-')
    [ "$rows" -eq 8 ]
    [[ "$output" == *"and 3 more, each smaller or more recently touched"* ]]
}

@test "a list that fits says nothing about a remainder" {
    run page "$(doc 5)"
    rows=$(printf '%s\n' "$output" | grep -c 'class="nm" href="#ws-workstream-')
    [ "$rows" -eq 5 ]
    [[ "$output" != *"more, each smaller"* ]]
}

@test "no at-risk disclosure when nothing is only here" {
    # A section that says "0 at risk" every morning trains you to stop reading it.
    run page "$(doc 0)"
    [ "$status" -eq 0 ]
    [[ "$output" != *'id="only-here"'* ]]
}

@test "the disclosure never holds fewer workstreams than the tile counted" {
    # An arc the ranking does not name -- an older graph, a ranking written before the arc
    # existed -- sorts to the end rather than being dropped. The tile says 4 and the list
    # has to be able to show 4.
    run python3 - "$(doc 4)" <<'PY'
import json, re, subprocess, sys
doc = json.loads(sys.argv[1])
doc["only_here"] = []
r = subprocess.run([sys.executable, "bin/arcs-page", "--focus", "30"],
                   input=json.dumps(doc), capture_output=True, text=True)
m = re.search(r'<details class="atrisk".*?</details>', r.stdout, re.S)
print(len(re.findall(r'class="nm" href', m.group(0))) if m else "NO DISCLOSURE")
PY
    [ "${lines[0]}" = "4" ]
}

@test "no CSS content string smuggles a control character out of a python escape" {
    # CSS is a plain triple-quoted string, not a raw one, so a CSS codepoint escape written
    # as content:"\25be " is read by python as octal \25 followed by the letters "be" --
    # and the disclosure marker rendered as a tofu box with "be" beside it. The original
    # rules used the literal glyphs for exactly this reason. Checked over every content
    # string in the stylesheet, because the next one will be written the same way.
    run python3 - "$REPO_ROOT/bin/arcs-page" <<'PY'
import importlib.machinery, importlib.util, re, sys
loader = importlib.machinery.SourceFileLoader("pg", sys.argv[1])
spec = importlib.util.spec_from_loader("pg", loader)
pg = importlib.util.module_from_spec(spec)
sys.argv = ["pg"]
loader.exec_module(pg)
bad = [c for c in re.findall(r'content:"([^"]*)"', pg.CSS)
       if any(ord(ch) < 32 for ch in c)]
print(bad)
PY
    [ "${lines[0]}" = "[]" ]
}

@test "a summary with no sentence break is dropped rather than chopped mid-thought" {
    # A phrase cut at a character count says less than nothing. Where the first sentence
    # is too long for one line the row falls back to a fact it already has.
    run python3 - "$REPO_ROOT/bin/arcs-page" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("pg", sys.argv[1])
spec = importlib.util.spec_from_loader("pg", loader)
pg = importlib.util.module_from_spec(spec)
sys.argv = ["pg"]
loader.exec_module(pg)
print(repr(pg.first_clause("Short one. Second.")))
print(repr(pg.first_clause("word " * 60)))
print(repr(pg.first_clause("")))
print(repr(pg.first_clause(None)))
PY
    [ "${lines[0]}" = "'Short one.'" ]
    [ "${lines[1]}" = "''" ]
    [ "${lines[2]}" = "''" ]
    [ "${lines[3]}" = "''" ]
}

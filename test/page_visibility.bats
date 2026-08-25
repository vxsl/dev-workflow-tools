#!/usr/bin/env bats
# Tests for what the page shows without being asked, and what it puts behind one line.
#
# The verdict underneath all of them: "it feels a bit all over the place ... just another
# bucket of slop to wrangle". Fifteen sections rendered fully expanded, so the morning
# brief and a twenty-row table of last week's landed branches were structurally equal, and
# a page whose sections are all the same weight has no opinion about what it is for.
#
# The other load-bearing fact is that no manual control on this page has been touched in a
# fortnight: the defaults have to be the selection and the controls the override. So these
# pin the defaults, and they pin the one law that keeps a default honest -- de-emphasis is
# not hiding, which here means every collapsed header states its real count and its single
# worst item, and every truncation under one states its own remainder.
#
# Nothing here pins wording. Every assertion is about what is open, what is a line, and
# whether a stated number matches what is under it.

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

# A work-arcs document with workstreams in every recency bucket, plus whatever extra
# top-level keys a test hands in as JSON on argv.
doc() {
    python3 - "$@" <<'ZZDOC'
import json, sys

def arc(aid, age, stage="local-only", **kw):
    a = {"id": aid, "label": aid, "kind": "cluster", "stage": stage,
         "state": stage + " state", "urgency": 5, "age_days": age,
         "unpushed_live": 6, "unpushed_days": 6,
         "unpushed_dates": ["2026-08-%02d" % (d + 1) for d in range(6)],
         "engagement": 300, "authoritative": "br-" + aid,
         "branches": [], "mrs": [], "stashes": [], "sessions": [], "issues": [],
         "demands": [], "counts": {"branches": 1, "stashes": 0, "mrs": 0, "sessions": 1},
         "brief": {"name": aid, "summary": "It reroutes the thing."}}
    a.update(kw)
    return a

arcs = [arc("today-one", 0), arc("week-one", 3), arc("week-two", 4),
        arc("lastweek-one", 9), arc("lastweek-two", 11),
        arc("earlier-one", 17), arc("earlier-two", 19),
        arc("done-one", 5, stage="landed", settled="merged"),
        arc("done-two", 6, stage="landed", settled="merged")]
out = {"generated": 1756000000, "repo": "ul", "main": "origin/main", "me": "kyle",
       "project_url": "https://gitlab.example/ul", "arc_count": len(arcs),
       "arcs": arcs, "forgotten": [], "only_here": [x["id"] for x in arcs]}
for extra in sys.argv[1:]:
    out.update(json.loads(extra))
print(json.dumps(out))
ZZDOC
}

# Renders a whole page from a work-arcs document handed over as JSON on argv.
page() {
    python3 - "$REPO_ROOT/bin/arcs-page" "$1" <<'ZZPAGE'
import subprocess, sys
r = subprocess.run([sys.executable, sys.argv[1], "--focus", "30"],
                   input=sys.argv[2], capture_output=True, text=True)
sys.stderr.write(r.stderr)
if r.returncode != 0:
    sys.exit(r.returncode)
sys.stdout.write(r.stdout)
ZZPAGE
}

# Every collapsed header on a rendered page, as "title | count | lead".
folds() {
    python3 - "$1" <<'ZZFOLDS'
import re, sys
html = open(sys.argv[1]).read()
for m in re.finditer(r'<details class="fold"[^>]*>\s*<summary>(.*?)</summary>',
                     html, re.S):
    inner = m.group(1)

    def grab(pat):
        g = re.search(pat, inner, re.S)
        return re.sub(r'<[^>]+>', '', g.group(1)).strip() if g else ''

    print("%s | %s | %s" % (grab(r'<h2[^>]*>(.*?)</h2>'),
                            grab(r'<span class="fn">(.*?)</span>'),
                            grab(r'<span class="fl">(.*?)</span>')))
ZZFOLDS
}

# The balanced inner HTML of one disclosure: everything between the element the pattern
# matches and its own closing tag, counting nested disclosures rather than stopping at the
# first one. Every section here holds folded notes and folded workstream rows, so a
# non-greedy regex reads a section as ending at the first note inside it.
inner_of() {
    python3 - "$1" "$2" <<'ZZINNER'
import re, sys
html, pat = open(sys.argv[1]).read(), sys.argv[2]
i = re.search(pat, html, re.S).start()
depth = 0
for t in re.finditer(r'<details[^>]*>|</details>', html[i:]):
    depth += -1 if t.group(0).startswith('</') else 1
    if depth == 0:
        print(html[i:i + t.start()])
        break
ZZINNER
}

# ── which recency groups are open ────────────────────────────────────────────

@test "today and this week have their rows on screen, last week and earlier are lines" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run folds "$TEST_TMPDIR/p.html"
    [[ "$output" == *"Last week |"* ]]
    [[ "$output" == *"Earlier |"* ]]
    # The two open groups keep their plain heading and never become a disclosure.
    [[ "$output" != *"Today |"* ]]
    [[ "$output" != *"Earlier this week |"* ]]
}

@test "a folded group still holds every one of its rows" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    for k in lastweek earlier; do
        n="$(inner_of "$TEST_TMPDIR/p.html" "<details class=.fold. data-bucket=.$k." \
             | grep -c 'details class="ws"')"
        [ "$n" = "2" ]
    done
}

# ── de-emphasis is not hiding ────────────────────────────────────────────────

@test "every collapsed header states a count" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run folds "$TEST_TMPDIR/p.html"
    [ "${#lines[@]}" -gt 3 ]
    for ln in "${lines[@]}"; do
        count="$(printf '%s' "$ln" | awk -F' \\| ' '{print $2}')"
        [ -n "$count" ]
    done
}

@test "every collapsed header naming a non-empty list names one item in it" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run folds "$TEST_TMPDIR/p.html"
    for ln in "${lines[@]}"; do
        count="$(printf '%s' "$ln" | awk -F' \\| ' '{print $2}')"
        lead="$(printf '%s' "$ln" | awk -F' \\| ' '{print $3}')"
        case "$count" in
            0*) ;;                       # an empty section has no worst item to name
            *)  [ -n "$lead" ] ;;
        esac
    done
}

@test "a section refuses to collapse without a size to state" {
    # The law in the code rather than only in a comment: fold() asserts, so a section
    # added later cannot quietly hide how much it is holding.
    run python3 - "$REPO_ROOT/bin/arcs-page" <<'ZZASSERT'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("ap", sys.argv[1])
spec = importlib.util.spec_from_loader("ap", loader)
ap = importlib.util.module_from_spec(spec)
sys.argv = ["ap"]
loader.exec_module(ap)
out = []
try:
    ap.fold(out.append, "Some section", "")
    print("no assertion")
except AssertionError:
    print("refused")
ZZASSERT
    [ "${lines[0]}" = "refused" ]
}

@test "a header's count is the number of rows behind it" {
    # The retired section renders every member, so its header figure and its row count are
    # the same claim made twice and have to agree.
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    body="$(inner_of "$TEST_TMPDIR/p.html" '<details class="fold">.{0,80}id="settled"')"
    stated="$(printf '%s' "$body" | grep -o 'class="fn">[0-9]*' | head -1 | tr -dc '0-9')"
    rows="$(printf '%s' "$body" | grep -c '<li id="ws-')"
    [ "$stated" = "2" ]
    [ "$rows" = "2" ]
}

@test "a table that cut its tail under a counted header says how many it left out" {
    # The Jira tables cap their rows. The header above states the whole figure now, so a
    # silent cut would make the one number a closed section is trusted for a lie.
    empty="$(python3 -c '
import json
print(json.dumps({"gap": {"tickets_without_work": [
    {"key": "UL-%d" % i, "status": "To Do", "summary": "s", "url": "u",
     "initiatives": []} for i in range(20)]}}))')"
    page "$(doc "$empty")" > "$TEST_TMPDIR/p.html"
    run folds "$TEST_TMPDIR/p.html"
    [[ "$output" == *"Tickets with nothing behind them | 20 "* ]]
    grep -q "and 6 more, as Jira listed them" "$TEST_TMPDIR/p.html"
}

# ── the ledger ───────────────────────────────────────────────────────────────

# A ledger side of n you-owe rows, each standing longer than the last.
owed() {
    python3 - "$1" <<'ZZOWED'
import json, sys
n = int(sys.argv[1])
you = [{"kind": "review-owed", "who": "person%d" % i, "days": 40 - i,
        "ref": "!%d" % (100 + i), "title": "a merge request", "url": "u",
        "asked": "2026-08-01", "fp": "you%d" % i} for i in range(n)]
print(json.dumps({"ledger": {"they_owe": [], "you_owe": you}}))
ZZOWED
}

@test "the five oldest loops stand and the rest go behind one line that states its size" {
    page "$(doc "$(owed 29)")" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZSIDE'
import re, sys
html = open(sys.argv[1]).read()
side = re.search(r'<div class="side">(.*?)<div class="side">', html, re.S).group(1)
top = re.sub(r'<details class="more">.*?</details>', '', side, flags=re.S)
more = re.search(r'<details class="more"><summary>(.*?)</summary>(.*?)</details>',
                 side, re.S)
print(len(re.findall(r'<li data-fp=', top)),
      len(re.findall(r'<li data-fp=', more.group(2))),
      re.sub(r'<[^>]+>', '', more.group(1)).split(' more,')[0])
ZZSIDE
    [ "${lines[0]}" = "5 24 24" ]
}

@test "a side short enough to read whole grows no disclosure" {
    page "$(doc "$(owed 4)")" > "$TEST_TMPDIR/p.html"
    run grep -c 'details class="more"' "$TEST_TMPDIR/p.html"
    [ "$status" -ne 0 ]
}

@test "the heading still counts every row, including the ones behind the line" {
    page "$(doc "$(owed 29)")" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZCOUNT'
import re, sys
html = open(sys.argv[1]).read()
print(re.search(r'You owe them <span class="n" data-count>(\d+)</span>', html).group(1))
ZZCOUNT
    [ "${lines[0]}" = "29" ]
}

# A ledger with n silent review requests plus one stalled hand-off.
silent() {
    python3 - "$1" <<'ZZSILENT'
import json, sys
n = int(sys.argv[1])
they = [{"kind": "review-silence", "who": ["brian", "vadym"], "days": 40 - i,
         "ref": "!%d" % (200 + i), "title": "a merge request", "url": "u",
         "asked": "2026-07-01", "fp": "sil%d" % i} for i in range(n)]
they.append({"kind": "ticket-stalled", "who": "ajit", "days": 5, "ref": "UL-9",
             "title": "a ticket", "url": "u", "asked": "2026-08-20",
             "status": "In Progress", "fp": "stall"})
print(json.dumps({"ledger": {"they_owe": they, "you_owe": []}}))
ZZSILENT
}

@test "several silent review requests are one row that expands to all of them" {
    page "$(doc "$(silent 11)")" > "$TEST_TMPDIR/p.html"
    inside="$(inner_of "$TEST_TMPDIR/p.html" '<details><summary><b data-aggcount>')"
    [ "$(printf '%s' "$inside" | grep -c '<li data-fp=')" = "11" ]
    # And the stalled hand-off is not in there: it is a different fact and its own row.
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZAGG'
import re, sys
html = open(sys.argv[1]).read()
side = re.search(r'They owe you.*?(?=<ul class="conditions">)', html, re.S).group(0)
out = re.sub(r'<li class="agg">.*?</details></div></li>', '', side, flags=re.S)
print(len(re.findall(r'<li data-fp=', out)),
      re.search(r'<b data-aggcount>(\d+)</b>', side).group(1))
ZZAGG
    [ "${lines[0]}" = "1 11" ]
}

@test "the aggregate carries no fingerprint of its own" {
    # A fingerprint over a set expires the moment the set changes, so acknowledging "the
    # silent reviews" would evaporate the next morning one of them answered.
    page "$(doc "$(silent 11)")" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZFP'
import re, sys
html = open(sys.argv[1]).read()
print("data-fp" in re.search(r'<li class="agg"[^>]*>', html).group(0))
ZZFP
    [ "${lines[0]}" = "False" ]
}

@test "two silent requests are two facts and stay two rows" {
    page "$(doc "$(silent 2)")" > "$TEST_TMPDIR/p.html"
    run grep -c 'class="agg"' "$TEST_TMPDIR/p.html"
    [ "$status" -ne 0 ]
}

# ── the derivation notes ─────────────────────────────────────────────────────

@test "a long note goes behind its own first sentence, whole" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZNOTE'
import re, sys
html = open(sys.argv[1]).read()
m = re.search(r'<details class="note why"><summary>(.*?)</summary>(.*?)</details>',
              html, re.S)
head = re.sub(r'<[^>]+>', '', m.group(1)).strip()
print(head.endswith(".") or head.endswith("?"), len(m.group(2).strip()) > 40)
ZZNOTE
    [ "${lines[0]}" = "True True" ]
}

@test "a one-sentence note keeps no toggle that would hide nothing" {
    stale="$(python3 -c '
import json
print(json.dumps({"stale_parks": [{"label": "an-arc", "why": "a commit landed"}]}))')"
    page "$(doc "$stale")" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZSHORT'
import re, sys
html = open(sys.argv[1]).read()
print(bool(re.search(r'<p class="note">[^<]*an-arc is no longer parked', html)))
ZZSHORT
    [ "${lines[0]}" = "True" ]
}

# ── the strip's links reach the sections they name ───────────────────────────

@test "every condition tile points at an anchor the page actually rendered" {
    # Two of them used to point at the one rung neither of their members is on, which was
    # survivable while every section was open and is a dead end now that they are folded.
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZTILES'
import re, sys
html = open(sys.argv[1]).read()
strip = re.search(r'<ul class="conditions">.*?</ul>', html, re.S).group(0)
ids = set(re.findall(r'id="([^"]+)"', html))
print([h for h in re.findall(r'href="#([^"]+)"', strip) if h not in ids] or "all resolve")
ZZTILES
    [ "${lines[0]}" = "all resolve" ]
}

@test "the retired tile points at the retired section and not at the rung above it" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZTILE2'
import re, sys
html = open(sys.argv[1]).read()
strip = re.search(r'<ul class="conditions">.*?</ul>', html, re.S).group(0)
for li in re.findall(r'<li>.*?</li>', strip, re.S):
    if "landed or been abandoned" in li:
        print(re.search(r'href="#([^"]+)"', li).group(1))
ZZTILE2
    [ "${lines[0]}" = "settled" ]
}

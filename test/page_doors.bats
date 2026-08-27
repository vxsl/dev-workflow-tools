#!/usr/bin/env bats
# Tests for what the page opens on, and how you get anywhere from there.
#
# Two verdicts sit underneath these. The first: "the dashboard still looks more or less the
# same ... we want this thing to make me _want_ to use it, not for it to be a chore." The
# page opened on its own title, set larger than anything else on it, and then asked for three
# screenfuls of scrolling before you reached the section you came for.
#
# The second is the one that decided the shape of the fix. The first attempt chose what to
# lead with from the viewer's clock -- a standup panel before the standup, loose ends in the
# afternoon -- and it was rejected outright: "no, i dont like the idea of it being
# unpredictable. emphasizing different sections depending on the time of day is not a good
# solution to what im asking for." So these tests pin the opposite property. The doors are
# the same doors in the same order every time the page is rendered, whatever the data says,
# and nothing on the page reads a clock to decide what to show.
#
# Nothing here pins wording. What is pinned is which element holds the opening fact, that
# the promotion of that fact drops nothing, that the doors keep their order and their
# anchors, and the one law they are held to: a figure on a door is the figure its own
# section prints, never a second count.

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

# A work-arcs document with a brief, a standup, both sides of the ledger and rows in every
# recency bucket -- plus whatever top-level keys a test overrides as JSON on argv.
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

arcs = [arc("today-one", 0), arc("week-one", 3), arc("lastweek-one", 9),
        arc("earlier-one", 17), arc("parked-one", 5, stage="parked", parked=True),
        arc("done-one", 5, stage="landed", settled="merged")]

def line(kind, lead, text):
    return {"kind": kind, "lead": lead, "parts": [text], "text": text}

out = {"generated": "2026-08-25T10:17:05", "repo": "ul", "main": "origin/main",
       "me": "kyle", "project_url": "https://gitlab.example/ul", "arc_count": len(arcs),
       "arcs": arcs, "forgotten": [], "only_here": [x["id"] for x in arcs],
       "brief": {"lines": [line("contradiction", "jira disagrees",
                                "The first fact, and the most consequential."),
                           line("owed", "open loop", "The second fact."),
                           line("forgotten", "dropped", "The third fact.")]},
       "standup": {"for": {"when": "Wednesday 10:30"},
                   "since": {"when": "Monday 10:30"}, "text": "notes",
                   "beats": [{"kind": "claimed", "lead": "last time you said",
                              "items": [{"parts": ["the first thing you will say"]},
                                        {"parts": ["the second thing"]}]},
                             {"kind": "moved", "lead": "moved",
                              "items": [{"parts": ["something moved"]}]}]},
       "ledger": {"you_owe": [{"fp": "y1", "kind": "review-owed", "who": "brian",
                               "days": 9, "ref": "!10406", "title": "the newer loop",
                               "url": "https://g/1", "asked": "2026-08-16"}],
                  "they_owe": [{"fp": "t1", "kind": "review-silence", "who": ["vadym"],
                                "days": 24, "ref": "!10388", "title": "the older loop",
                                "url": "https://g/3", "asked": "2026-08-01"}],
                  "slack": True, "slack_complete": True}}
for extra in sys.argv[1:]:
    if extra:
        out.update(json.loads(extra))
print(json.dumps(out))
ZZDOC
}

# Renders a whole page from a work-arcs document handed over as JSON on argv. Any further
# arguments are passed straight to arcs-page.
page() {
    python3 - "$ARCS_ROOT/bin/arcs-page" "$@" <<'ZZPAGE'
import subprocess, sys
r = subprocess.run([sys.executable, sys.argv[1], "--focus", "30"] + sys.argv[3:],
                   input=sys.argv[2], capture_output=True, text=True)
sys.stderr.write(r.stderr)
if r.returncode != 0:
    sys.exit(r.returncode)
sys.stdout.write(r.stdout)
ZZPAGE
}

# One door's figure and its named item, as "figure | item". Scoped to the strip, because
# every door's data-door value also appears in the stylesheet that colours its edge.
door() {
    python3 - "$1" "$2" <<'ZZDOOR'
import re, sys
html = open(sys.argv[1]).read()
nav = re.search(r'<nav class="cockpit".*?</nav>', html, re.S).group(0)
d = re.search(r'<a class="door" data-door="%s".*?</a>' % sys.argv[2], nav, re.S)
if not d:
    print("NO-DOOR")
    raise SystemExit
parts = dict((k, re.sub(r'<[^>]+>', '', v).strip()) for k, v in re.findall(
    r'<span class="(dk|dv|dl)">(.*?)(?=<span class="d[kvl]">|</a>)', d.group(0), re.S))
print("%s | %s" % (parts.get("dv", ""), parts.get("dl", "")))
ZZDOOR
}

# Every door on the strip, in the order it renders.
doors() {
    python3 - "$1" <<'ZZDOORS'
import re, sys
nav = re.search(r'<nav class="cockpit".*?</nav>', open(sys.argv[1]).read(), re.S)
print(" ".join(re.findall(r'<a class="door" data-door="([a-z]+)"', nav.group(0))))
ZZDOORS
}

# The markup with every script block removed, so a selector written inside a script is not
# mistaken for an element on the page.
markup() {
    python3 - "$1" <<'ZZMARKUP'
import re, sys
print(re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S))
ZZMARKUP
}

# ── what the page opens on ───────────────────────────────────────────────────

@test "the biggest thing on the page is a fact, and the title is a line in the corner" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZOPEN'
import re, sys
html = open(sys.argv[1]).read()
# The title lives inside the masthead, which is the quiet line.
mast = re.search(r'<div class="masthead">(.*?)</div></div>', html, re.S).group(1)
print("TITLED" if "<h1>" in mast else "NO-TITLE")
# The one candidate in the deck that is not hidden holds arc-morning's first line, and
# only that one. The others are behind it in the document -- see headline_block -- and a
# reader is shown exactly one of them.
heads = re.findall(r'<div class="headline"([^>]*)>(.*?)</div>', html, re.S)
open_heads = [h for at, h in heads if " hidden" not in at]
print("ONE-OPEN" if len(open_heads) == 1 else "%d-OPEN" % len(open_heads))
head = open_heads[0]
print("FIRST" if "The first fact" in head else "NOT-FIRST")
print("ONLY" if "The second fact" not in head else "ALSO-SECOND")
# Its label rides above it, in arc-morning's own vocabulary.
print(re.search(r'<span class="eyebrow">(.*?)</span>', head).group(1))
ZZOPEN
    [ "${lines[0]}" = "TITLED" ]
    [ "${lines[1]}" = "ONE-OPEN" ]
    [ "${lines[2]}" = "FIRST" ]
    [ "${lines[3]}" = "ONLY" ]
    [ "${lines[4]}" = "jira disagrees" ]
}

@test "every line is drawn at both sizes, and each shows the one the other hides" {
    # The law the instant promotion rests on. A ✕ cannot rewrite the opening sentence
    # without the page becoming a second author for which fact leads -- so the server draws
    # every line as a headline AND as a shortlist row, and the client only ever chooses
    # which of each pair is not hidden. Both halves have to be complete for that choice to
    # be a choice.
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZDECK'
import re, sys
html = open(sys.argv[1]).read()
facts = ["The first fact", "The second fact", "The third fact"]
deck = re.search(r'<div class="deck"[^>]*>(.*?)\n?<ul class="brief">', html, re.S).group(1)
heads = re.findall(r'<div class="headline"([^>]*)>(.*?)</div>', deck, re.S)
brief = re.search(r'<ul class="brief">(.*?)</ul>', html, re.S).group(1)
rows = re.findall(r'<li([^>]*)>(.*?)</li>', brief, re.S)
# Each fact once as a headline candidate and once as a row, in arc-morning's order.
print([next(i for i, f in enumerate(facts) if f in h) for _, h in heads])
print([next(i for i, f in enumerate(facts) if f in r) for _, r in rows])
# And exactly one of each pair is showing, on opposite sides.
print([" hidden" not in at for at, _ in heads])
print([" hidden" not in at for at, _ in rows])
ZZDECK
    [ "${lines[0]}" = "[0, 1, 2]" ]
    [ "${lines[1]}" = "[0, 1, 2]" ]
    [ "${lines[2]}" = "[True, False, False]" ]
    [ "${lines[3]}" = "[False, True, True]" ]
}

@test "promoting the first line drops nothing: it is in the list, not out of it" {
    # The count is intact by construction rather than by an announced truncation. The
    # promoted line is in the shortlist at the rank it always had, hidden while it is the
    # headline -- so the moment the client steps past it, it is already there to be shown
    # struck rather than composed from anything.
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZWHOLE'
import re, sys
html = open(sys.argv[1]).read()
brief = re.search(r'<ul class="brief">(.*?)</ul>', html, re.S).group(1)
rows = re.findall(r'<span class="bs">(.*?)</span>', brief, re.S)
first = [i for i, r in enumerate(rows) if "The first fact" in r]
print(len(rows), first)
ZZWHOLE
    # Three facts in, three rows, and the promoted one is the first of them.
    [ "${lines[0]}" = "3 [0]" ]
}

@test "one brief line leaves a headline and no list under it" {
    one="$(python3 -c '
import json
print(json.dumps({"brief": {"lines": [{"kind": "owed", "lead": "open loop",
                                       "parts": ["The only fact."], "text": "x"}]}}))')"
    page "$(doc "$one")" > "$TEST_TMPDIR/p.html"
    run grep -c 'ul class="brief"' "$TEST_TMPDIR/p.html"
    [ "$status" -ne 0 ]
    run grep -c 'The only fact' "$TEST_TMPDIR/p.html"
    [ "${lines[0]}" = "1" ]
}

@test "without arc-morning the headline is the derived sentence" {
    page "$(doc '{"brief": {}}')" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZDERIVED'
import re, sys
html = open(sys.argv[1]).read()
head = re.search(r'<div class="headline"[^>]*>(.*?)</div>', html, re.S).group(1)
print("LEDE" if 'class="lede"' in head else "NO-LEDE")
ZZDERIVED
    [ "${lines[0]}" = "LEDE" ]
}

@test "a hand-passed sentence is the headline and beats both of the derived ones" {
    page "$(doc)" --lede "Typed on purpose." > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZHAND'
import re, sys
html = open(sys.argv[1]).read()
head = re.search(r'<div class="headline"[^>]*>(.*?)</div>', html, re.S).group(1)
print("TYPED" if "Typed on purpose." in head else "NOT-TYPED")
print("NO-BRIEF" if 'ul class="brief"' not in html else "BRIEF")
ZZHAND
    [ "${lines[0]}" = "TYPED" ]
    [ "${lines[1]}" = "NO-BRIEF" ]
}

# ── the doors do not move ────────────────────────────────────────────────────

@test "the doors are the same three in the same order, whatever the data says" {
    # Two documents whose shapes disagree about everything a clock-driven strip would have
    # reordered on: one with a loud ledger and a quiet standup, one the other way round.
    loud="$(python3 -c '
import json
print(json.dumps({"ledger": {"you_owe": [{"fp": "y%d" % i, "kind": "review-owed",
    "who": "brian", "days": 40 - i, "ref": "!%d" % i, "title": "t", "url": "u"}
    for i in range(20)], "they_owe": [], "slack": True}}))')"
    quiet="$(python3 -c '
import json
print(json.dumps({"standup": {"for": {"when": "Friday 10:30"},
                              "since": {"when": "Wednesday 10:30"},
                              "text": "n", "beats": []}}))')"
    for extra in "" "$loud" "$quiet"; do
        page "$(doc "$extra")" > "$TEST_TMPDIR/p.html"
        run doors "$TEST_TMPDIR/p.html"
        [ "${lines[0]}" = "standup ledger play" ]
    done
}

@test "nothing on this page reads the clock to decide what to show" {
    # The whole of the rejected design in one assertion: no script here asks the browser
    # what time it is in order to choose what the reader sees.
    run grep -nE 'new Date|Date\.now|getHours|getDay|toLocaleTime' \
        "$ARCS_ROOT/bin/arcs-page"
    # The clock is allowed in exactly one shape: the second a person's declaration was
    # recorded, stamped onto the stored entry. That is a record of when something was said,
    # never a decision about what to render.
    for ln in "${lines[@]}"; do
        [[ "$ln" == *"Math.floor(Date.now()/1000)"* ]]
    done
}

@test "a door is absent when its own section is" {
    page "$(doc '{"standup": {}, "ledger": null}')" > "$TEST_TMPDIR/p.html"
    run doors "$TEST_TMPDIR/p.html"
    [ "${lines[0]}" = "play" ]
    run markup "$TEST_TMPDIR/p.html"
    [[ "$output" != *'<section class="standup"'* ]]
    [[ "$output" != *'<section id="ledger">'* ]]
}

@test "every door and every mini-map stop lands on an id the page rendered" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZANCHORS'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
ids = set(re.findall(r'\sid="([^"]+)"', html))
bad = []
for nav in ("cockpit", "minimap"):
    block = re.search(r'<nav class="%s".*?</nav>' % nav, html, re.S)
    for href in re.findall(r'href="#([^"]+)"', block.group(0)):
        if href not in ids:
            bad.append(nav + ":" + href)
print(bad or "ALL-LAND")
ZZANCHORS
    [ "${lines[0]}" = "ALL-LAND" ]
}

# ── a door never states a figure of its own ──────────────────────────────────

@test "every figure on a door or the mini-map is the number its own section prints" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZMIRROR'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
bad, seen = [], 0
for m in re.finditer(r'data-mirror="([^"]+)"[^>]*>([^<]*)<', html):
    sel = m.group(1).replace("&quot;", '"')
    shown, seen = m.group(2).strip(), seen + 1
    if sel.startswith("#"):
        src = re.findall(r'id="%s"[^>]*>([^<]*)<' % re.escape(sel[1:]), html)
    else:
        attr = re.match(r'\[([a-z-]+)="([^"]+)"\]$', sel)
        src = re.findall(r'%s="%s"[^>]*>([^<]*)<'
                         % (re.escape(attr.group(1)), re.escape(attr.group(2))), html)
    if len(src) != 1:
        bad.append("%s resolves to %d elements" % (sel, len(src)))
    elif src[0].strip() != shown:
        bad.append("%s says %r, section says %r" % (sel, shown, src[0].strip()))
print(seen, bad or "ALL-MIRROR")
ZZMIRROR
    # Nine figures mirror on this document: the standup's notes, both ledger sides and
    # what is in play, each once on a door and once on the map, plus the parked count.
    [ "${lines[0]}" = "9 ALL-MIRROR" ]
}

@test "an acknowledged ledger row leaves the door and the section one figure, not two" {
    # The server renders both from the same variable, so the page is already consistent
    # with scripting off -- which is the half of the contract a test can hold.
    page "$(doc '{"ledger": {"you_owe": [{"fp": "y1", "kind": "review-owed", "who": "b",
        "days": 9, "ref": "!1", "title": "t", "url": "u", "dismissed": true},
        {"fp": "y2", "kind": "review-owed", "who": "c", "days": 3, "ref": "!2",
         "title": "t", "url": "u"}], "they_owe": [], "slack": true}}')" \
        > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZACK'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
door = re.search(r'data-mirror="#lg-you-n"[^>]*>([^<]*)<', html).group(1)
side = re.search(r'id="lg-you-n"[^>]*>([^<]*)<', html).group(1)
print(door, side)
ZZACK
    [ "${lines[0]}" = "1 1" ]
}

@test "an acknowledged Jira mismatch leaves the fold header and the rail stop too" {
    # The last fold on the page still stating its raw total. It was survivable while the
    # only ✕ for these rows was three screens down the section; it stopped being survivable
    # the day the opening sentence grew one, because acknowledging the ticket the headline
    # names moved the headline and left this header, and the stop above it, unchanged.
    mism="$(python3 -c '
import json
print(json.dumps({"gap": {"jira": True, "status_mismatch": [
    {"fp": "g1", "ref": "UL-1", "stale_days": 40, "dismissed": True,
     "issue": {"key": "UL-1", "status": "In Review", "url": "u"},
     "arc": {"id": "today-one", "unpushed_live": 6, "unpushed_days": 6},
     "why": "status In Review but six days never pushed"},
    {"fp": "g2", "ref": "UL-2", "stale_days": 20,
     "issue": {"key": "UL-2", "status": "Releasing", "url": "u"},
     "arc": {"id": "week-one", "unpushed_live": 2, "unpushed_days": 2},
     "why": "status Releasing but two days never pushed"}]}}))')"
    page "$(doc "$mism")" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZJIRA'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
stop = re.search(r'data-mirror="\[data-count=&quot;jira&quot;\]"[^>]*>([^<]*)<',
                 html).group(1)
hdr = re.search(r'data-count="jira"[^>]*>([^<]*)<', html).group(1)
# And the fold names an unacknowledged row as its worst, not a faded one.
lead = re.search(r'sid="jira".*?<span class="fl">(.*?)</span>', html, re.S)
lead = re.sub(r'<[^>]+>', '', lead.group(1)) if lead else re.search(
    r'<span class="fl">([^<]*UL-[^<]*)</span>', html).group(1)
print(stop, hdr, "UL-2" in lead, "UL-1" in lead)
ZZJIRA
    [ "${lines[0]}" = "1 1 True False" ]
}

# ── what the doors name ──────────────────────────────────────────────────────

@test "the ledger door names the older of the two sides' own first rows" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run door "$TEST_TMPDIR/p.html" ledger
    # they_owe's head stands 24 days, you_owe's 9, so the older one is named -- and it is
    # named with the clock that decided it.
    [[ "${lines[0]}" == *"| they owe you · 24d"* ]]
    [[ "${lines[0]}" == *"the older loop"* ]]
}

@test "a tie on the clock goes to the half you can close yourself" {
    tie="$(python3 -c '
import json
print(json.dumps({"ledger": {
    "you_owe": [{"fp": "y1", "kind": "review-owed", "who": "b", "days": 12,
                 "ref": "!1", "title": "yours", "url": "u"}],
    "they_owe": [{"fp": "t1", "kind": "review-silence", "who": ["v"], "days": 12,
                  "ref": "!2", "title": "theirs", "url": "u"}], "slack": True}}))')"
    page "$(doc "$tie")" > "$TEST_TMPDIR/p.html"
    run door "$TEST_TMPDIR/p.html" ledger
    [[ "${lines[0]}" == *"| you owe · 12d"* ]]
}

@test "the in-play door names the first row of the first group, not a row of its own" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZPLAY'
import re, sys
html = open(sys.argv[1]).read()
nav = re.search(r'<nav class="cockpit".*?</nav>', html, re.S).group(0)
d = re.search(r'data-door="play".*?<span class="dl">(.*?)</a>', nav, re.S).group(1)
named = re.sub(r'<[^>]+>', '', d).strip()
# The section's own first row, in the first group it renders.
first = re.search(r'<div class="wslist" data-list="today">.*?class="nm">([^<]*)',
                  html, re.S).group(1).strip()
print(named.startswith("today · "), first in named)
ZZPLAY
    [ "${lines[0]}" = "True True" ]
}

@test "the standup door names arc-standup's own first beat and first item" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run door "$TEST_TMPDIR/p.html" standup
    [[ "${lines[0]}" == *"| last time you said · the first thing you will say" ]]
}

@test "a quiet standup window still has a door, and it says so" {
    quiet="$(python3 -c '
import json
print(json.dumps({"standup": {"for": {"when": "Friday 10:30"},
                              "since": {"when": "Wednesday 10:30"},
                              "text": "n", "beats": []}}))')"
    page "$(doc "$quiet")" > "$TEST_TMPDIR/p.html"
    run door "$TEST_TMPDIR/p.html" standup
    # It says the window is empty rather than vanishing, and it names nothing, because
    # there is nothing in there to name.
    [ "${lines[0]}" = "nothing yet for Friday 10:30 | " ]
}

# ── the mini-map names only what was rendered ────────────────────────────────

@test "a section this run did not render has no stop on the mini-map" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZSTOPS'
import re, sys
html = open(sys.argv[1]).read()
nav = re.search(r'<nav class="minimap".*?</nav>', html, re.S).group(0)
print(" ".join(re.findall(r'href="#([^"]+)"', nav)))
ZZSTOPS
    # No sprint, no cliff, no unticketed work, no questions and no cost in this document,
    # so none of them is offered as a place to go.
    [[ "${lines[0]}" != *"sprint"* ]]
    [[ "${lines[0]}" != *"cliff"* ]]
    [[ "${lines[0]}" != *"cost"* ]]
    [[ "${lines[0]}" == *"ledger"* ]]
    [[ "${lines[0]}" == *"play"* ]]
    [[ "${lines[0]}" == *"parked"* ]]
}

@test "the mini-map needs no script to be reachable" {
    # Sticky in CSS and nothing else: navigation is the last thing on a page that should
    # depend on scripting, and this page runs sandboxed.
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run markup "$TEST_TMPDIR/p.html"
    [[ "$output" == *'<nav class="minimap"'* ]]
    run grep -c 'position:sticky;top:0' "$TEST_TMPDIR/p.html"
    [ "${lines[0]}" -ge 1 ]
}

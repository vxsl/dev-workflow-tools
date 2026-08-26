#!/usr/bin/env bats
# Tests for the rule that a workstream partly made of somebody else's ticket says so.
#
# Kyle: "for something like ul-1816, since it's logan's ticket, is it really my own arc? or
# can it be shown as a separate category of arc? or at least have some different styling to
# show that it's a 'review arc'?"
#
# The half of that question about arcs holding NOTHING of his was answered elsewhere and by
# removal -- demote_checkouts stops emitting those, and checkout_not_arc.bats pins it. What
# is left is the mixed case, which is the one the example actually is: three commits of his
# own on UL-1816-lazy-popup-fixes, four branches of Logan's checked out beside them, and two
# of Logan's merge requests joined to it as reviews he is giving.
#
# So everything here is about rendering an identity the wire already asserts. Two claims,
# and they fail apart:
#
#   * SELECTION -- which arcs partition to the foot of their time bucket, and which arcs
#     get the chip in each of the six places a workstream's name is drawn. That is what
#     nearly all of this pins.
#   * ACCOUNTING -- the three figures at the foot of the Reviewing zone. Each exists because
#     a number that changed has to have an account of what changed it, and each is absent
#     rather than nought where the run could not support the claim.
#
# Nothing here pins wording, and nothing here pins CSS: whether the chip is grey or the edge
# is parked-toned is a screenshot's job, not a grep's.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    export ROOT="$REPO_ROOT"
    export JIRA_PROJECTS="UL,UB"
}

teardown() {
    teardown_temp_dir
}

# A document with review arcs and plain arcs side by side in the same bucket, and with a
# review arc in every other list that draws a workstream's name: the news, the run-over-run
# strip, the only-here shortlist, the cliff verdicts, the settled archive, and both derived
# sentences at the top of the page.
doc() {
    python3 - "$@" <<'ZZDOC'
import json, sys

def arc(aid, age, **kw):
    a = {"id": aid, "label": aid, "kind": "cluster", "stage": "local-only",
         "state": "state of " + aid, "urgency": 5, "age_days": age,
         "unpushed_live": 6, "unpushed_days": 6, "engagement": 300,
         "unpushed_dates": ["2026-08-0%d" % (d + 1) for d in range(6)],
         "authoritative": "br-" + aid, "branches": [], "mrs": [], "stashes": [],
         "sessions": [], "issues": [], "demands": [], "reviews": [],
         "counts": {"branches": 1, "stashes": 0, "mrs": 0, "sessions": 1},
         "brief": {"name": aid, "summary": "It reroutes the thing."}}
    a.update(kw)
    return a

def rv(iid, who, **kw):
    r = {"iid": iid, "ref": "!%d" % iid, "title": "their work",
         "url": "https://gl/%d" % iid, "author": who, "days": 9, "rounds": 2,
         "whose_turn": "mine", "quiet_days": 0, "arc": None,
         "fp": "rv%d" % iid, "my_last": 10, "their_last": 9}
    r.update(kw)
    return r

# Two of somebody else's merge requests joined to one workstream of his, which is the shape
# UL-1816 really has. Ordered second in the wire so the partition has something to move.
mixed = arc("mixed-today", 0, urgency=1,
            reviews=[rv(101, "logan", arc="mixed-today"),
                     rv(102, "logan", arc="mixed-today")])
# A second review arc, out for review itself, so the row wears both facts at once.
both = arc("both-today", 0, stage="in-review", state="waiting on review",
           reviews=[rv(103, "ella", arc="both-today")])
# Plain work of his, in the same bucket and with a worse demand, so a partition that were
# really a sort would be visible as one.
plain = arc("plain-today", 0, urgency=9)
louder = arc("louder-today", 0, urgency=0)
week = arc("plain-week", 3)
# A bucket with rows and nothing of anybody else's in it at all.
lastweek = arc("plain-lastweek", 9)

news = arc("news-week", 2, notify=[
    {"kind": "threads", "what": "a comment landed", "at": 1787000000, "fp": "nwA",
     "url": "https://gl/9"}], reviews=[rv(104, "vadym", arc="news-week")])
news["demands"] = list(news["notify"])

fell = arc("dropped-earlier", 20, reviews=[rv(105, "brian", arc="dropped-earlier")])
fell["activity"] = {"cliff_days": 20, "series": [[22, 9], [23, 6], [24, 4]],
                    "invested": {"entries": 19},
                    "forgotten": {"verdict": True, "fp": "fgA",
                                  "why": "19 sessions across 3 days, then nothing"}}
settled = arc("settled-one", 4, stage="landed", settled="merged",
              reviews=[rv(106, "ella", arc="settled-one")])

arcs = [louder, plain, mixed, both, week, lastweek, news, fell, settled]

def part(t, **kw):
    p = {"t": t}
    p.update(kw)
    return p

out = {
    "generated": "2026-08-26T10:17:05", "repo": "ul", "main": "origin/main", "me": "kyle",
    "project_url": "https://gitlab.example/ul", "arc_count": len(arcs),
    "arcs": arcs,
    "forgotten": ["dropped-earlier"],
    # Ranked so a review arc leads it, which is the only way the shortlist's cap cannot hide
    # the one row this file is about.
    "only_here": ["mixed-today", "louder-today", "plain-today", "plain-week"],
    "brief": {"lines": [
        {"kind": "local", "lead": "unpublished", "text": "x",
         "parts": ["Six days of work sit on ",
                   part("mixed-today", arc="mixed-today"), " and nowhere else."]},
        {"kind": "quiet", "lead": "overnight", "text": "x",
         "parts": ["Nothing moved on ", part("plain-week", arc="plain-week"),
                   " overnight."]}]},
    "standup": {"for": {"when": "tomorrow"}, "since": {"when": "yesterday"},
                "text": "spoken notes", "beats": [
                    {"kind": "shipped", "lead": "shipped", "items": [
                        {"parts": ["Carried on with ",
                                   part("mixed-today", arc="mixed-today"), "."],
                         "subs": [{"parts": ["and read ",
                                             part("news-week", arc="news-week"),
                                             " again."]}]}]}]},
    "since_last_run": {"interval_seconds": 3600, "changes": [
        {"id": "mixed-today", "label": "mixed-today", "age_days": 0,
         "evidence": [{"kind": "threads", "what": "a note landed",
                       "url": "https://gl/101"}]}],
        "reviews": [{"arc": "mixed-today", "kind": "turn", "what": "the turn flipped",
                     "ref": "!101", "url": "https://gl/101"}]},
    "ledger": {"you_owe": [], "they_owe": [], "slack": True, "slack_complete": True,
               "reviews_drafts_skipped": 0},
    "reviews_known": True,
    "reviews": [rv(101, "logan", arc="mixed-today"), rv(102, "logan", arc="mixed-today"),
                rv(103, "ella", arc="both-today"), rv(104, "vadym", arc="news-week"),
                # The one whose workstream stopped existing: demote_checkouts withdrew the
                # arc and left the branch on the review as evidence.
                rv(200, "logan", arc=None, checked_out=True,
                   checkout_branches=["UL-1849"], checkout_sessions=2,
                   checkout_age_days=7)],
    "reviews_approved": [rv(300, "vadym", approved_at=1787000000),
                         rv(301, "brian", approved_at=1787000000)],
    "reviews_approved_n": 2,
    "checkouts": [
        {"branch": "UL-1568", "age_days": 26, "owner": "ella", "worktree": True,
         "iid": None, "sessions": 0, "was_arc": "UL-1568 line chart padding"},
        {"branch": "UL-1812", "age_days": 14, "owner": "logan", "worktree": False,
         "iid": None, "sessions": 1, "was_arc": "One metric instance many layers"}],
    "checkouts_n": 2,
    "gap": {"jira": True, "status_mismatch": []},
}
for extra in sys.argv[1:]:
    if extra:
        out.update(json.loads(extra))
print(json.dumps(out))
ZZDOC
}

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

# ── the partition inside a time bucket ────────────────────────────────────────

@test "review arcs sit at the foot of their own bucket, under a boundary of their own" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZPART'
import re, sys
html = open(sys.argv[1]).read()
seg = html[html.index('data-list="today"'):]
seg = seg[:seg.index('data-list=', 20)]
pat = (r'<details class="ws" id="ws-([a-z-]+?)-[0-9a-f]{6}"[^>]*data-review="(\d)"'
       r'|<div class="wsgrp" data-revgroup="([^"]*)"')
for m in re.finditer(pat, seg):
    if m.group(3):
        print("boundary " + m.group(3))
    else:
        print("%s %s" % (m.group(2), m.group(1)))
ZZPART
    # His own work first, in the order the bucket's own key gave it -- urgency 0 above
    # urgency 9 -- then the line, then everything whose ticket is somebody else's.
    [ "${lines[0]}" = "0 louder-today" ]
    [ "${lines[1]}" = "0 plain-today" ]
    [ "${lines[2]}" = "boundary today" ]
    # And the two review arcs keep THEIR own order below it: `mixed` at urgency 1 leads
    # `both`, which is out for review and sinks by the same key that has always sunk one.
    # A partition is not a re-rank of either side of itself.
    [ "${lines[3]}" = "1 mixed-today" ]
    [ "${lines[4]}" = "1 both-today" ]
    [ "${#lines[@]}" -eq 5 ]
}

@test "the boundary states its own count and appears only where a bucket holds one" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZBOUND'
import re, sys
html = open(sys.argv[1]).read()
for m in re.finditer(r'<div class="wsgrp" data-revgroup="([^"]*)".*?'
                     r'data-revcount="([^"]*)"[^>]*>(\d+)<', html, re.S):
    print("%s %s %s" % m.groups())
play = html[html.index('<h2 id="play">'):]
print("buckets: " + ",".join(re.findall(r'data-list="([a-z]+)"', play)))
ZZBOUND
    # One boundary per bucket that holds anybody else's ticket, keyed to that bucket, and
    # counting the group rather than the rows under it -- the same figure the client
    # rewrites when parking moves one out from under it.
    [ "${lines[0]}" = "today today 2" ]
    [ "${lines[1]}" = "week week 1" ]
    [ "${lines[2]}" = "earlier earlier 1" ]
    # Four buckets have rows. The one holding nothing of anybody else's has no boundary at
    # all, rather than one reading nought.
    [ "${lines[3]}" = "buckets: today,week,lastweek,earlier" ]
    [ "${#lines[@]}" -eq 4 ]
}

@test "the partition changes no count: a review arc is still a workstream of his" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZCOUNT'
import re, sys
html = open(sys.argv[1]).read()
print("play " + re.search(r'id="play-n">(\d+)<', html).group(1))
for m in re.finditer(r'data-count="(today|week|earlier)"[^>]*>(\d+)<', html):
    print("%s %s" % m.groups())
ZZCOUNT
    # Eight live workstreams: four today, two this week, one last week, one earlier. Every
    # review arc is counted among them, because each holds work of his -- the partition is a
    # statement about what the rows are and not a filter over them.
    [ "${lines[0]}" = "play 8" ]
    [ "${lines[1]}" = "today 4" ]
}

# ── the row's own identity ────────────────────────────────────────────────────

@test "a review arc's row carries the attribute, the chip, the merge requests and the owner" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZROW'
import re, sys
html = open(sys.argv[1]).read()
for aid in ("mixed-today", "both-today", "plain-today"):
    m = re.search(r'<details class="ws" id="ws-' + aid + r'-[0-9a-f]{6}"(.*?)</summary>',
                  html, re.S)
    row = m.group(1)
    print("%s | rev=%s | chip=%d | %s | who=%s" % (
        aid,
        re.search(r'data-review="(\d)"', row).group(1),
        row.count('class="revchip"'),
        ",".join(re.findall(r'class="revjoin">(.*?)</span>', row, re.S)[:1]),
        ",".join(re.findall(r'class="revwho">\s*([^<]*)</span>', row))))
ZZROW
    # Both merge requests, linked, and whose they are -- read off the joined reviews and
    # invented nowhere.
    [[ "${lines[0]}" == "mixed-today | rev=1 | chip=1 | "*'href="https://gl/101"'*"!101"*"!102"*" | who=logan" ]]
    # The attribute is independent of the rung, so the row can wear whose ticket it is
    # instead of whose turn it is even where it has both.
    [[ "${lines[1]}" == "both-today | rev=1 | chip=1 | "*"!103"*" | who=ella" ]]
    # And his own work wears none of it.
    [ "${lines[2]}" = "plain-today | rev=0 | chip=0 |  | who=" ]
}

# ── the chip travels wherever the name is drawn ───────────────────────────────

@test "the chip follows the name into every other list that draws one" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZTRAVEL'
import re, sys
html = open(sys.argv[1]).read()

def seg(start, end=None):
    i = html.index(start)
    j = html.index(end, i) if end else len(html)
    return html[i:j]

def after(anchor, start, end):
    i = html.index(start, html.index(anchor))
    return html[i:html.index(end, i)]

# The news card, the run-over-run strip's two lists, the only-here shortlist, the cliff
# verdicts, and the settled archive. One review arc is named in each.
cases = [
    ("news", seg('<section id="cameback"', '</section>'), "news-week"),
    ("runover", seg('<ul class="lb">', '</ul>'), "mixed-today"),
    ("runover-rv", seg('<ul class="lb rv">', '</ul>'), "mixed-today"),
    ("onlyhere", seg('id="only-here"', '</details>'), "mixed-today"),
    ("cliff", seg('parked-list cliff', '</ul>'), "dropped-earlier"),
    # The archive's own compact list. Cut from the heading onwards and then to the end of
    # the list itself -- the note directly under the heading is a disclosure of its own, so
    # the first </details> after the heading is not the section's.
    ("settled", after('<h2 id="settled">', '<ul class="parked-list">', '</ul>'),
     "settled-one"),
]
for name, s, aid in cases:
    rows = [r for r in re.findall(r'<(?:li|div class="news")[^>]*>.*?(?=<(?:li|div class="news")|\Z)',
                                  s, re.S) if aid in r]
    print("%s %s %d" % (name, aid in s, sum(r.count('class="revchip"') for r in rows)))
ZZTRAVEL
    # Present in each, and wearing the chip in each. One chip per name, never two.
    [ "${lines[0]}" = "news True 1" ]
    [ "${lines[1]}" = "runover True 1" ]
    [ "${lines[2]}" = "runover-rv True 1" ]
    [ "${lines[3]}" = "onlyhere True 1" ]
    [ "${lines[4]}" = "cliff True 1" ]
    [ "${lines[5]}" = "settled True 1" ]
}

@test "a folded section naming a review arc as its worst says whose ticket that is" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZFOLD'
import re, sys
html = open(sys.argv[1]).read()
for m in re.finditer(r'<summary><h2[^>]*>([^<]*)</h2>(.*?)</summary>', html, re.S):
    lead = re.search(r'<span class="fl">(.*?)</span>', m.group(2), re.S)
    if not lead:
        continue
    print("%s %d" % (m.group(1), lead.group(1).count('class="revchip"')))
ZZFOLD
    # Every folded section names one row inside it -- the worst, the freshest, an example --
    # and where that row is somebody else's ticket the header says so. A closed section
    # naming a workstream is making the same claim as an open one naming it, and it is read
    # by more people, because on a folded section it is the only line there is.
    [ "${lines[0]}" = "Since the last build 1" ]
    # And a bucket whose named row is his own work carries nothing.
    [ "${lines[1]}" = "Last week 0" ]
    [ "${lines[2]}" = "Earlier 1" ]
    [ "${lines[3]}" = "Fell off a cliff 1" ]
    [ "${lines[4]}" = "Landed or abandoned 1" ]
    [ "${#lines[@]}" -eq 5 ]
}

@test "the chip follows the name into the derived sentences at the top of the page" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZSENT'
import re, sys
html = open(sys.argv[1]).read()
for cls, close in (("headline", "div"), ("brief", "ul"), ("standup", "section")):
    m = re.search(r'<' + close + r' class="' + cls + r'"[^>]*>(.*?)</' + close + r'>',
                  html, re.S)
    body = m.group(1) if m else ""
    print("%s %d" % (cls, body.count('class="revchip"')))
ZZSENT
    # The headline and the brief both draw every line -- one of the two is hidden by the
    # client -- so the one line naming a review arc carries the chip in each.
    [ "${lines[0]}" = "headline 1" ]
    [ "${lines[1]}" = "brief 1" ]
    # The standup names one review arc on its item and a second on the sub-item under it.
    [ "${lines[2]}" = "standup 2" ]
}

@test "the Reviewing zone's own rows get no chip: they are already merge requests" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZNOSPRAY'
import re, sys
html = open(sys.argv[1]).read()
zone = html[html.index('<section id="reviewing"'):]
zone = zone[:zone.index('</section>')]
print("rows %d chips %d" % (len(re.findall(r'<li data-fp="rv', zone)),
                            zone.count('class="revchip"')))
ZZNOSPRAY
    # Five rows, no chips. The chip says "this workstream is partly somebody else's ticket";
    # a row in this zone IS somebody else's merge request and the section says so.
    [ "${lines[0]}" = "rows 5 chips 0" ]
}

# ── the three accountings at the foot of the zone ─────────────────────────────

@test "the reviews you approved are counted and named, not quietly subtracted" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZAPP'
import re, sys
html = open(sys.argv[1]).read()
zone = html[html.index('<section id="reviewing"'):]
line = [p for p in re.findall(r'<p class="covered">(.*?)</p>', zone, re.S)
        if "approved" in p]
print(len(line))
print("2" in line[0], "!300" in line[0], "!301" in line[0],
      'href="https://gl/300"' in line[0])
ZZAPP
    [ "${lines[0]}" = "1" ]
    # The figure and both refs, each a link: the count is the fact and the ref is what a
    # reader does with it.
    [ "${lines[1]}" = "True True True True" ]
}

@test "an unconsulted GitLab accounts for nothing rather than claiming nought" {
    # reviews_known false is "nobody looked", which cannot support "you approved 0".
    page "$(doc '{"reviews_known": false}')" > "$TEST_TMPDIR/p.html"
    run grep -c 'id="reviewing"' "$TEST_TMPDIR/p.html"
    [ "$status" -ne 0 ] || [ "$output" = "0" ]
}

@test "the approved line is absent when there is nothing to account for" {
    page "$(doc '{"reviews_approved": [], "reviews_approved_n": 0}')" \
        > "$TEST_TMPDIR/p.html"
    run bash -c "grep -o 'approved and nobody has moved' '$TEST_TMPDIR/p.html' | wc -l"
    [ "$output" = "0" ]
}

@test "somebody else's checked-out branches are named under the zone, behind a disclosure" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZCO'
import re, sys
html = open(sys.argv[1]).read()
zone = html[html.index('<section id="reviewing"'):]
zone = zone[:zone.index('</section>')]
line = [p for p in re.findall(r'<p class="covered">(.*?)</p>', zone, re.S)
        if "checked out" in p]
print(len(line), "2" in line[0])
rows = re.findall(r'<ul class="cox">(.*?)</ul>', zone, re.S)
print(len(rows))
for li in re.findall(r'<li>(.*?)</li>', rows[0], re.S):
    print(re.sub(r'<[^>]+>', '', li))
ZZCO
    # One line, carrying the real count.
    [ "${lines[0]}" = "1 True" ]
    # And the branch names behind a disclosure, each with whose it is, how old it is and
    # what it used to be filed as -- so a reader who remembers yesterday's page can find
    # where the row went.
    [ "${lines[1]}" = "1" ]
    [[ "${lines[2]}" == *"UL-1568"*"ella"*"26d"*"UL-1568 line chart padding"* ]]
    [[ "${lines[3]}" == *"UL-1812"*"logan"*"14d"*"1 session"* ]]
}

@test "no checkouts, no line: the accounting is absent rather than nought" {
    page "$(doc '{"checkouts": [], "checkouts_n": 0}')" > "$TEST_TMPDIR/p.html"
    run bash -c "grep -c 'class=\"cox\"' '$TEST_TMPDIR/p.html' || true"
    [ "$output" = "0" ]
}

@test "a review whose workstream stopped existing still says the branch is here" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZEV'
import re, sys
html = open(sys.argv[1]).read()
zone = html[html.index('<section id="reviewing"'):]
row = re.search(r'<li data-fp="rv200".*?</li>', zone, re.S).group(0)
print("checked out here" in row, "UL-1849" in row, ">2</span> session" in row,
      'class="arcl"' in row)
ZZEV
    # The branch, and that he has opened it here -- which is what demote_checkouts left
    # behind when it withdrew the workstream. Never an arc link: there is no arc.
    [ "${lines[0]}" = "True True True False" ]
}

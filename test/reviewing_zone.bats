#!/usr/bin/env bats
# Tests for the Reviewing zone: the reviews you are giving, rendered as work with a clock.
#
# Kyle: "me actively reviewing someone's MR is in its own category, e.x. i have 6802 which
# is a long ongoing review and various logan MRs which are long ongoing reviews. it would
# be cool to see these as first-class things." The data arrived in f760a6b and nothing
# rendered it, so the page could report that GitLab had been asked and could not report
# what it said.
#
# What is pinned here is not wording. It is the four laws this section has to keep, each of
# which the page already keeps somewhere else and each of which is easy to break by adding
# a section: an absent universe is not an empty one; wire order is the only order; a figure
# on a door is a copy of the one its section printed; and a foreign clock is never rendered
# as yours.

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

# A work-arcs document carrying a ledger and a set of reviews, plus whatever top-level keys
# a test overrides as JSON on argv. The reviews are in the order work-arcs would have
# ranked them -- yours first, then longest-running -- because that is the order the page is
# required to render and re-sorting them here would test the fixture instead.
doc() {
    python3 - "$@" <<'ZZDOC'
import json, sys

def arc(aid, age, stage="local-only", **kw):
    a = {"id": aid, "label": aid, "kind": "cluster", "stage": stage,
         "state": stage + " state", "urgency": 5, "age_days": age,
         "unpushed_live": 2, "unpushed_days": 2, "unpushed_dates": ["2026-08-01"],
         "engagement": 300, "authoritative": "br-" + aid,
         "branches": [], "mrs": [], "stashes": [], "sessions": [], "issues": [],
         "demands": [], "reviews": [],
         "counts": {"branches": 1, "stashes": 0, "mrs": 0, "sessions": 1},
         "brief": {"name": aid, "summary": "It reroutes the thing."}}
    a.update(kw)
    return a

def review(iid, days, turn, rounds, author, **kw):
    r = {"iid": iid, "ref": "!%d" % iid, "title": "the %d change" % iid,
         "url": "https://gitlab.example/mr/%d" % iid, "author": author,
         "source_branch": "br-%d" % iid, "target_branch": "main",
         "asked": "2026-07-01", "asked_is_proxy": False, "days": days,
         "my_last": 1787000000, "their_last": 1787000001,
         "their_last_is_proxy": False, "whose_turn": turn, "rounds": rounds,
         "quiet_days": 3, "arc": None, "fp": "rfp%d" % iid}
    r.update(kw)
    return r

arcs = [arc("today-one", 0), arc("week-one", 3),
        arc("UB-6802", 20, stage="reviewing", state="reviewing !10265 for ella")]

reviews = [review(10500, 40, "mine", 0, "vadym"),
           review(10510, 12, "mine", 3, "logan"),
           review(10520, 4, "mine", 1, "brian"),
           review(10265, 20, "theirs", 12, "ella",
                  arc="UB-6802", arc_via="its source branch is checked out here")]

out = {"generated": "2026-08-25T10:17:05", "repo": "ul", "main": "origin/main",
       "me": "kyle", "project_url": "https://gitlab.example/ul", "arc_count": len(arcs),
       "arcs": arcs, "forgotten": [], "only_here": [x["id"] for x in arcs],
       "reviews": reviews, "reviews_known": True,
       "ledger": {"you_owe": [], "they_owe": [], "slack": True, "slack_complete": True,
                  "reviews": reviews, "reviews_known": True,
                  "reviews_drafts_skipped": 3}}
for extra in sys.argv[1:]:
    if extra:
        out.update(json.loads(extra))
print(json.dumps(out))
ZZDOC
}

# Renders a whole page from a work-arcs document handed over as JSON on argv.
page() {
    python3 - "$REPO_ROOT/bin/arcs-page" "$@" <<'ZZPAGE'
import subprocess, sys
r = subprocess.run([sys.executable, sys.argv[1], "--focus", "30"] + sys.argv[3:],
                   input=sys.argv[2], capture_output=True, text=True)
sys.stderr.write(r.stderr)
if r.returncode != 0:
    sys.exit(r.returncode)
sys.stdout.write(r.stdout)
ZZPAGE
}

# The markup with every script block removed, so a selector written inside a script is not
# mistaken for an element on the page.
markup() {
    python3 - "$1" <<'ZZMARKUP'
import re, sys
print(re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S))
ZZMARKUP
}

# Every door on the strip, in the order it renders.
doors() {
    python3 - "$1" <<'ZZDOORS'
import re, sys
nav = re.search(r'<nav class="cockpit".*?</nav>', open(sys.argv[1]).read(), re.S)
print(" ".join(re.findall(r'<a class="door" data-door="([a-z]+)"', nav.group(0))))
ZZDOORS
}

# ── an absent universe is not an empty one ───────────────────────────────────

@test "GitLab unasked: no section, no door, no stop on the rail" {
    page "$(doc '{"reviews": [], "reviews_known": false}')" > "$TEST_TMPDIR/p.html"
    run markup "$TEST_TMPDIR/p.html"
    [[ "$output" != *'<section id="reviewing">'* ]]
    run doors "$TEST_TMPDIR/p.html"
    [[ "$output" != *reviewing* ]]
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZNOSTOP'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
nav = re.search(r'<nav class="minimap".*?</nav>', html, re.S).group(0)
print("STOP" if "#reviewing" in nav else "NO-STOP")
ZZNOSTOP
    [ "${lines[0]}" = "NO-STOP" ]
}

@test "GitLab asked and answered nothing: the section stands and says none" {
    page "$(doc '{"reviews": [], "reviews_known": true}')" > "$TEST_TMPDIR/p.html"
    run markup "$TEST_TMPDIR/p.html"
    [[ "$output" == *'<section id="reviewing">'* ]]
    # It says so in words rather than standing over an empty list.
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZNONE'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
sec = re.search(r'<section id="reviewing">.*?</section>', html, re.S).group(0)
print("QUIET" if 'class="quiet"' in sec else "NO-QUIET")
print("ROWS" if "<li data-fp" in sec else "NO-ROWS")
print(re.search(r'id="rv-n"[^>]*>([^<]*)<', sec).group(1))
ZZNONE
    [ "${lines[0]}" = "QUIET" ]
    [ "${lines[1]}" = "NO-ROWS" ]
    [ "${lines[2]}" = "0" ]
    # And it still has a door, because nought reviews is a state and a good one.
    run doors "$TEST_TMPDIR/p.html"
    [[ "$output" == *reviewing* ]]
}

# ── the order came down the wire ─────────────────────────────────────────────

@test "the rows render in wire order, whatever else is on them" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZORDER'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
ul = re.search(r'<ul class="reviewing".*?</ul>', html, re.S).group(0)
print(" ".join(re.findall(r'class="ref"[^>]*>(![0-9]+)<', ul)))
ZZORDER
    # The wire's own ranking: yours first, then longest-running. !10265 is last because it
    # is the one waiting on somebody else -- and it is the row this section was asked for,
    # which is why nothing here may re-sort or truncate.
    [ "${lines[0]}" = "!10500 !10510 !10520 !10265" ]
}

@test "nothing is cut: five stand, the rest are announced and still in the document" {
    many="$(python3 -c '
import json
rs = [{"iid": 9000 + i, "ref": "!%d" % (9000 + i), "title": "t%d" % i,
       "url": "https://g/%d" % i, "author": "logan", "source_branch": "b%d" % i,
       "asked": "2026-07-01", "days": 60 - i, "my_last": 1, "their_last": 2,
       "whose_turn": "mine", "rounds": i, "quiet_days": 1, "arc": None,
       "fp": "f%d" % i} for i in range(23)]
print(json.dumps({"reviews": rs, "reviews_known": True,
                  "ledger": {"you_owe": [], "they_owe": [], "slack": True,
                             "slack_complete": True, "reviews": rs,
                             "reviews_known": True}}))')"
    page "$(doc "$many")" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZALL'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
sec = re.search(r'<section id="reviewing">.*?</section>', html, re.S).group(0)
uls = re.findall(r'<ul class="reviewing">.*?</ul>', sec, re.S)
# Every one of them is on the page: the disclosure is a fold, not a cap.
print(len(re.findall(r'<li data-fp=', sec)))
print(len(re.findall(r'<li data-fp=', uls[0])))
# And the fold states its own size, which is the remainder and never a rounded one.
more = re.search(r'<details class="more"><summary>(.*?)</summary>', sec, re.S).group(1)
print(re.search(r'<b>(\d+)</b>', more).group(1))
# The heading over the whole section still counts every row, standing or folded.
print(re.search(r'id="rv-n"[^>]*>([^<]*)<', sec).group(1))
ZZALL
    [ "${lines[0]}" = "23" ]
    [ "${lines[1]}" = "5" ]
    [ "${lines[2]}" = "18" ]
    [ "${lines[3]}" = "23" ]
}

# The wire is longest-running-first, so reading the first five off it put a merge request
# nobody had said a word on for four months at the top of the section and yesterday's
# movement below the fold -- the ranking inverted by accident. What stands is the first
# five that are still moving; what has gone quiet is set faint and waits with the rest. The
# order itself is never touched, which is what this pins: the fold holds the wire's own
# sequence with the standing rows lifted out of it, not a re-sort.
@test "a review quieter than its own rhythm waits in the fold, and nothing is re-sorted" {
    quiet="$(python3 -c '
import json
def rv(iid, days, quiet):
    return {"iid": iid, "ref": "!%d" % iid, "title": "t%d" % iid,
            "url": "https://g/%d" % iid, "author": "logan", "source_branch": "b%d" % iid,
            "asked": "2026-07-01", "days": days, "my_last": 1, "their_last": 2,
            "whose_turn": "mine", "rounds": 1, "quiet_days": quiet, "arc": None,
            "fp": "f%d" % iid}
rs = [rv(9001, 129, 126), rv(9002, 120, 9), rv(9003, 60, 2), rv(9004, 30, 1),
      rv(9005, 20, 18), rv(9006, 10, 1), rv(9007, 5, 1), rv(9008, 2, 0)]
print(json.dumps({"reviews": rs, "reviews_known": True,
                  "ledger": {"you_owe": [], "they_owe": [], "slack": True,
                             "slack_complete": True, "reviews": rs,
                             "reviews_known": True}}))')"
    page "$(doc "$quiet")" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZQUIET'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
sec = re.search(r'<section id="reviewing">.*?</section>', html, re.S).group(0)
uls = re.findall(r'<ul class="reviewing">.*?</ul>', sec, re.S)
refs = lambda u: " ".join(re.findall(r'class="ref"[^>]*>(![0-9]+)<', u))
print(refs(uls[0]))
print(refs(uls[1]))
# 9001 has said nothing in 126 of its 129 days and 9005 in 18 of its 20; 9008 is merely
# the ninth-longest-running, which is a different reason to be here and a different ink.
faint = [re.search(r'class="ref"[^>]*>(![0-9]+)<', li).group(1)
         for li in re.findall(r'<li data-fp=.*?</li>', sec, re.S) if 'class="slow"' in li]
print(" ".join(faint))
more = re.search(r'<details class="more"><summary>(.*?)</summary>', sec, re.S).group(1)
print(re.findall(r'<b>(\d+)</b>', more))
ZZQUIET
    [ "${lines[0]}" = "!9002 !9003 !9004 !9006 !9007" ]
    [ "${lines[1]}" = "!9001 !9005 !9008" ]
    [ "${lines[2]}" = "!9001 !9005" ]
    # How many are behind the disclosure, and how many of those stopped rather than queued.
    [ "${lines[3]}" = "['3', '2']" ]
}

# A review opened yesterday and untouched since has been silent for its whole life, which a
# ratio on its own calls "gone quiet" and a reader calls new. The floor under the rhythm
# test is what keeps the two apart.
@test "a day-old review has not gone quiet, however little has happened on it" {
    fresh="$(python3 -c '
import json
rs = [{"iid": 9100 + i, "ref": "!%d" % (9100 + i), "title": "t%d" % i,
       "url": "https://g/%d" % i, "author": "logan", "source_branch": "b%d" % i,
       "asked": "2026-08-24", "days": 1, "my_last": 1, "their_last": 2,
       "whose_turn": "mine", "rounds": 0, "quiet_days": 1, "arc": None,
       "fp": "n%d" % i} for i in range(3)]
print(json.dumps({"reviews": rs, "reviews_known": True,
                  "ledger": {"you_owe": [], "they_owe": [], "slack": True,
                             "slack_complete": True, "reviews": rs,
                             "reviews_known": True}}))')"
    page "$(doc "$fresh")" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZFRESH'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
sec = re.search(r'<section id="reviewing">.*?</section>', html, re.S).group(0)
print("FAINT" if 'class="slow"' in sec else "NONE-FAINT")
print("FOLD" if '<details class="more">' in sec else "NO-FOLD")
ZZFRESH
    [ "${lines[0]}" = "NONE-FAINT" ]
    [ "${lines[1]}" = "NO-FOLD" ]
}

@test "the drafts the sweep left out are announced with their real count" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZDRAFT'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
sec = re.search(r'<section id="reviewing">.*?</section>', html, re.S).group(0)
m = re.search(r'<p class="covered">(.*?)</p>', sec, re.S)
print(re.sub(r'<[^>]+>', '', m.group(1)) if m else "NOTHING-SAID")
ZZDRAFT
    [[ "${lines[0]}" == "3 draft"* ]]
}

# ── every row carries the facts that make it first-class ─────────────────────

@test "a row names its author and its rounds, and its group names whose turn it is" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZROW'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
ul = re.search(r'<ul class="reviewing".*?</ul>', html, re.S).group(0)
row = [li for li in re.findall(r'<li data-fp=.*?</li>', ul, re.S)
       if "!10265" in li][0]
who = re.search(r'<span class="who">(.*?)</span></div>', row, re.S).group(1)
print("AUTHOR" if "ella" in who else "NO-AUTHOR")
print("ROUNDS" if re.search(r'>12</span> rounds', who) else "NO-ROUNDS")
# The label is the group's now. Repeating it on every row said nothing about any of
# them, and it buried the one row of the four that is the exception.
print("NO-ROW-LABEL" if "their turn" not in who else "ROW-LABEL")
print("IN-GROUP" if 'data-turn="theirs"' in row else "UNGROUPED")
ZZROW
    [ "${lines[0]}" = "AUTHOR" ]
    [ "${lines[1]}" = "ROUNDS" ]
    [ "${lines[2]}" = "NO-ROW-LABEL" ]
    [ "${lines[3]}" = "IN-GROUP" ]
}

# The boundary is already on the wire -- work-arcs ranks these yours-first -- so drawing
# it is a rendering of an existing order and never a second ranking. Nothing here pins
# wording; what is pinned is that there are two groups, in the wire's order, each stating
# the size of what is under it.
@test "whose turn it is is said once per group, in the wire's order" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZGRP'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
ul = re.search(r'<ul class="reviewing".*?</ul>', html, re.S).group(0)
for li in re.findall(r'<li class="grp".*?</li>', ul, re.S):
    turn = re.search(r'data-turn="([a-z]+)"', li).group(1)
    n = re.search(r'data-turncount="[a-z]+"[^>]*>(\d+)<', li).group(1)
    print(turn, n, "WARM" if 'class="gl mine"' in li else "PLAIN")
# The rows stay in the order they arrived in, headers or no headers.
print([re.search(r'data-fp="rfp(\d+)"', li).group(1)
       for li in re.findall(r'<li data-fp=.*?</li>', ul, re.S)])
ZZGRP
    [ "${lines[0]}" = "mine 3 WARM" ]
    [ "${lines[1]}" = "theirs 1 PLAIN" ]
    [ "${lines[2]}" = "['10500', '10510', '10520', '10265']" ]
}

# A group that runs across the fold is headed on both sides of it, because a reader who
# opens the disclosure should not have to scroll back up to learn whose turn the rows under
# their cursor are. The count beside each heading is the group's own size wherever its rows
# are standing -- deliberately the same number in the window and in the fold, so it reads as
# a property of the group rather than a tally of the lines directly below it, and the
# disclosure states its own size separately.
@test "the fold keeps the headings, and a heading counts its whole group" {
    split="$(python3 -c '
import json
def rv(iid, days, turn):
    return {"iid": iid, "ref": "!%d" % iid, "title": "t%d" % iid,
            "url": "https://g/%d" % iid, "author": "logan", "source_branch": "b%d" % iid,
            "asked": "2026-07-01", "days": days, "my_last": 1, "their_last": 2,
            "whose_turn": turn, "rounds": 1, "quiet_days": 1, "arc": None,
            "fp": "s%d" % iid}
rs = [rv(9200 + i, 40 - i, "mine") for i in range(8)]
rs += [rv(9300, 30, "theirs"), rv(9301, 20, "theirs")]
print(json.dumps({"reviews": rs, "reviews_known": True,
                  "ledger": {"you_owe": [], "they_owe": [], "slack": True,
                             "slack_complete": True, "reviews": rs,
                             "reviews_known": True}}))')"
    page "$(doc "$split")" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZSPLIT'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
sec = re.search(r'<section id="reviewing">.*?</section>', html, re.S).group(0)
for li in re.findall(r'<li class="grp".*?</li>', sec, re.S):
    print(re.search(r'data-turn="([a-z]+)"', li).group(1),
          re.search(r'data-turncount="[a-z]+"[^>]*>(\d+)<', li).group(1))
# Exactly one of them carries the id the door mirrors, so there is one source and not two.
print(sec.count('id="rv-turn-mine"'))
ZZSPLIT
    # The window holds five of the eight yours; the fold picks the group up again and then
    # crosses into theirs.
    [ "${lines[0]}" = "mine 8" ]
    [ "${lines[1]}" = "mine 8" ]
    [ "${lines[2]}" = "theirs 2" ]
    [ "${lines[3]}" = "1" ]
}

# Provenance, carried and not printed. Sixteen of twenty-three turns on the real corpus
# are read off a push rather than off a note, so printing it would be the same majority
# state repeated per row that the headings exist to undo.
@test "how a turn was decided rides on the row rather than being printed on it" {
    run python3 - "$REPO_ROOT/bin/arcs-page" "$(doc)" <<'ZZPROXY'
import json, re, subprocess, sys
d = json.loads(sys.argv[2])
d["reviews"][0]["their_last_is_proxy"] = True
r = subprocess.run([sys.executable, sys.argv[1], "--focus", "30"],
                   input=json.dumps(d), capture_output=True, text=True)
html = re.sub(r'<script.*?</script>', '', r.stdout, flags=re.S)
ul = re.search(r'<ul class="reviewing".*?</ul>', html, re.S).group(0)
rows = re.findall(r'<li data-fp=.*?</li>', ul, re.S)
print("CARRIED" if "standing in for a word" in rows[0] else "LOST")
print("QUIET" if "read off a push" not in ul else "PRINTED")
print("ONLY-THAT-ROW" if "standing in for a word" not in rows[1] else "EVERYWHERE")
ZZPROXY
    [ "${lines[0]}" = "CARRIED" ]
    [ "${lines[1]}" = "QUIET" ]
    [ "${lines[2]}" = "ONLY-THAT-ROW" ]
}

# A heading over a group that is not a group is worse than the repetition it replaces, so
# a wire order that does not partition keeps every row's own label.
@test "an unsorted wire order gets no headings and keeps its row labels" {
    run python3 - "$REPO_ROOT/bin/arcs-page" "$(doc)" <<'ZZMIX'
import json, re, subprocess, sys
d = json.loads(sys.argv[2])
d["reviews"] = [d["reviews"][i] for i in (0, 3, 1, 2)]
r = subprocess.run([sys.executable, sys.argv[1], "--focus", "30"],
                   input=json.dumps(d), capture_output=True, text=True)
html = re.sub(r'<script.*?</script>', '', r.stdout, flags=re.S)
ul = re.search(r'<ul class="reviewing".*?</ul>', html, re.S).group(0)
print("NO-HEADINGS" if '<li class="grp"' not in ul else "HEADINGS")
print("ROW-LABELS" if ul.count("your turn") == 3 else "MISSING-LABELS")
ZZMIX
    [ "${lines[0]}" = "NO-HEADINGS" ]
    [ "${lines[1]}" = "ROW-LABELS" ]
}

@test "a joined workstream is linked where its row exists and stated where it does not" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZJOIN'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
ids = set(re.findall(r'\sid="([^"]+)"', html))
ul = re.search(r'<ul class="reviewing".*?</ul>', html, re.S).group(0)
arcl = re.search(r'<a class="arcl" href="#([^"]+)"([^>]*)>', ul)
print("LANDS" if arcl and arcl.group(1) in ids else "DANGLING")
print("VIA" if "checked out here" in (arcl.group(2) if arcl else "") else "NO-VIA")
ZZJOIN
    [ "${lines[0]}" = "LANDS" ]
    [ "${lines[1]}" = "VIA" ]
}

@test "a workstream outside the window is named and never linked" {
    # The join is a fact whatever the focus window says; an anchor to a row that was never
    # rendered is the same lie as a link to a 404, so outside the window it is plain text.
    page "$(doc)" --focus 5 > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZOUT'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
ul = re.search(r'<ul class="reviewing".*?</ul>', html, re.S).group(0)
print("LINKED" if '<a class="arcl"' in ul else "PLAIN")
print("NAMED" if '<span class="arcl"' in ul else "DROPPED")
ZZOUT
    [ "${lines[0]}" = "PLAIN" ]
    [ "${lines[1]}" = "NAMED" ]
}

# ── the door is a copy, never a second count ─────────────────────────────────

@test "the door and the rail mirror the figure the section printed" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZMIRROR'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
src = re.findall(r'id="rv-n"[^>]*>([^<]*)<', html)
mirrors = [m.group(1).strip() for m in
           re.finditer(r'data-mirror="#rv-n"[^>]*>([^<]*)<', html)]
print(len(src), src[0] if src else "-", mirrors)
# Both the door and the rail stop, and both copies of the section's own number.
print("ALL-EQUAL" if src and all(m == src[0] for m in mirrors) else "DISAGREE")
print(len(mirrors))
ZZMIRROR
    [ "${lines[0]}" = "1 4 ['4', '4']" ]
    [ "${lines[1]}" = "ALL-EQUAL" ]
    [ "${lines[2]}" = "2" ]
}

# "23 ongoing" is a census: it reads the same on a morning when every one of them is with
# its author as on a morning when every one is with you, and a figure that cannot change
# what you do is one the eye stops reading. What can is how many are yours -- which is a
# number the section already prints over its own group, so the door copies it rather than
# working it out again.
@test "the reviewing door leads with how many are yours and keeps the census under it" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZFIG'
import re, sys
html = open(sys.argv[1]).read()
nav = re.search(r'<nav class="cockpit".*?</nav>', html, re.S).group(0)
d = re.search(r'<a class="door" data-door="reviewing".*?</a>', nav, re.S).group(0)
big = re.search(r'<span class="dn" data-mirror="([^"]+)">(\d+)<', d)
print(big.group(1), big.group(2))
# And the section printed that element, with that number in it -- a mirror and not a count.
src = re.search(r'id="rv-turn-mine"[^>]*>(\d+)<', html)
print(src.group(1) if src else "NO-SOURCE")
sub = re.search(r'<span class="dsub">of <span class="dq" data-mirror="#rv-n">(\d+)<', d)
print(sub.group(1) if sub else "NO-CENSUS")
ZZFIG
    [ "${lines[0]}" = "#rv-turn-mine 3" ]
    [ "${lines[1]}" = "3" ]
    [ "${lines[2]}" = "4" ]
}

# Where the wire is not in two runs there is no heading to mirror, and a door pointing at an
# element the section never printed is the same lie as a link to a 404. It falls back to the
# figure the section did print.
@test "an unpartitioned wire leaves the door mirroring a figure that exists" {
    run python3 - "$REPO_ROOT/bin/arcs-page" "$(doc)" <<'ZZFALL'
import json, re, subprocess, sys
d = json.loads(sys.argv[2])
d["reviews"] = [d["reviews"][i] for i in (0, 3, 1, 2)]
r = subprocess.run([sys.executable, sys.argv[1], "--focus", "30"],
                   input=json.dumps(d), capture_output=True, text=True)
html = r.stdout
nav = re.search(r'<nav class="cockpit".*?</nav>', html, re.S).group(0)
door = re.search(r'<a class="door" data-door="reviewing".*?</a>', nav, re.S).group(0)
print("NO-DANGLE" if "rv-turn-mine" not in html else "DANGLING")
print(re.search(r'data-mirror="([^"]+)"', door).group(1))
ZZFALL
    [ "${lines[0]}" = "NO-DANGLE" ]
    [ "${lines[1]}" = "#rv-n" ]
}

# Every figure the strip and the rail repeat is a copy of one its own section printed. The
# law existed before this section did; what is new is that it now has two of them.
@test "every mirror on the page points at something the page rendered" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZRESOLVE'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
ids = set(re.findall(r'\sid="([^"]+)"', html))
bad = []
for sel in set(re.findall(r'data-mirror="([^"]+)"', html)):
    sel = sel.replace("&quot;", '"')
    if sel.startswith("#"):
        if sel[1:] not in ids:
            bad.append(sel)
    elif sel.startswith("["):
        if sel.strip("[]").replace('"', "&quot;") not in html:
            bad.append(sel)
print(sorted(bad) or "all resolve")
ZZRESOLVE
    [ "${lines[0]}" = "all resolve" ]
}

@test "the door names the first row on the wire, not a row it chose itself" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZLEAD'
import re, sys
html = open(sys.argv[1]).read()
nav = re.search(r'<nav class="cockpit".*?</nav>', html, re.S).group(0)
d = re.search(r'<a class="door" data-door="reviewing".*?</a>', nav, re.S).group(0)
print(re.sub(r'<[^>]+>', '', re.search(r'<span class="dl">(.*?)</span>',
                                       d, re.S).group(1)).strip())
ZZLEAD
    # Clock then subject, the shape the ledger's own door already uses.
    [[ "${lines[0]}" == "40d — !10500 "* ]]
}

@test "the door sits where its section does, between the ledger and what is in play" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run doors "$TEST_TMPDIR/p.html"
    [ "${lines[0]}" = "ledger reviewing play" ]
    # And it lands somewhere the page actually emitted.
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZLANDS'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
ids = set(re.findall(r'\sid="([^"]+)"', html))
print("LANDS" if "reviewing" in ids else "DANGLING")
ZZLANDS
    [ "${lines[0]}" = "LANDS" ]
}

# ── a foreign clock is never rendered as yours ───────────────────────────────

@test "an age that is somebody else's push is marked and says whose clock it is" {
    foreign="$(python3 -c '
import json
print(json.dumps({"arcs": [
  {"id": "UL-1812", "label": "UL-1812", "kind": "cluster", "stage": "reviewing",
   "state": "checkout of someone’s branch", "urgency": 5, "age_days": 14,
   "age_is_foreign": True, "role": "review", "unpushed_live": 0, "unpushed_days": 0,
   "unpushed_dates": [], "engagement": 10, "branches": [], "mrs": [], "stashes": [],
   "sessions": [], "issues": [], "demands": [], "reviews": [], "counts": {},
   "brief": {"name": "UL-1812"}},
  {"id": "mine-one", "label": "mine-one", "kind": "cluster", "stage": "local-only",
   "state": "only here", "urgency": 5, "age_days": 2, "unpushed_live": 3,
   "unpushed_days": 3, "unpushed_dates": ["2026-08-01"], "engagement": 90,
   "branches": [], "mrs": [], "stashes": [], "sessions": [], "issues": [],
   "demands": [], "reviews": [], "counts": {}, "brief": {"name": "mine-one"}}]}))')"
    page "$(doc "$foreign")" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZFOREIGN'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
marked = re.findall(r'<span class="ag foreign"([^>]*)>([^<]*)</span>', html)
print(len(marked))
print("SAYS-WHOSE" if marked and "not your clock" in marked[0][0] else "SILENT")
print("KEPT" if marked and "14d" in marked[0][1] else "DROPPED")
# The workstream that IS his keeps a plain age -- the mark is not decoration.
plain = re.findall(r'<span class="ag">([^<]*)</span>', html)
print("PLAIN-ELSEWHERE" if any("2d" in p for p in plain) else "MARKED-EVERYWHERE")
ZZFOREIGN
    [ "${lines[0]}" = "1" ]
    [ "${lines[1]}" = "SAYS-WHOSE" ]
    [ "${lines[2]}" = "KEPT" ]
    [ "${lines[3]}" = "PLAIN-ELSEWHERE" ]
}

# ── the run-over-run half ────────────────────────────────────────────────────

@test "a review that moved renders in the since-the-last-build fold" {
    since="$(python3 -c '
import json
print(json.dumps({"since_last_run": {
  "previous_generated": "2026-08-25T09:00:00-0700", "interval_seconds": 4500,
  "compared": 3, "changed": 0, "changes": [],
  "reviews": [{"iid": "10265", "kind": "turned_mine", "ref": "!10265",
               "url": "https://g/10265", "arc": "UB-6802",
               "what": "ella moved on !10265 — your turn"}]}}))')"
    page "$(doc "$since")" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZSINCE'
import re, sys
html = re.sub(r'<script.*?</script>', '', open(sys.argv[1]).read(), flags=re.S)
ids = set(re.findall(r'\sid="([^"]+)"', html))
ul = re.search(r'<ul class="lb rv">.*?</ul>', html, re.S)
print("RENDERED" if ul else "MISSING")
print("KIND" if ul and 'data-k="turned_mine"' in ul.group(0) else "NO-KIND")
# It joined to a workstream on this page, so it links to that row and not to a 404.
href = re.search(r'<span class="nm"><a href="#([^"]+)"', ul.group(0)) if ul else None
print("LANDS" if href and href.group(1) in ids else "DANGLING")
# The fold's header counts both halves.
fn = re.search(r'id="sincebuild">[^<]*</h2><span class="fn">([^<]*)<', html)
print(fn.group(1) if fn else "NO-COUNT")
# And no acknowledgement anywhere on a diff line: an interval fact expires by itself.
print("NO-DIS" if 'class="dis"' not in ul.group(0) else "HAS-DIS")
ZZSINCE
    [ "${lines[0]}" = "RENDERED" ]
    [ "${lines[1]}" = "KIND" ]
    [ "${lines[2]}" = "LANDS" ]
    [ "${lines[3]}" = "1 moved" ]
    [ "${lines[4]}" = "NO-DIS" ]
}

@test "a run that never compared reviews puts no review line in the fold" {
    since="$(python3 -c '
import json
print(json.dumps({"since_last_run": {
  "previous_generated": "2026-08-25T09:00:00-0700", "interval_seconds": 4500,
  "compared": 3, "changed": 0, "changes": [],
  "skipped_universes": ["reviews"], "reviews": []}}))')"
    page "$(doc "$since")" > "$TEST_TMPDIR/p.html"
    run markup "$TEST_TMPDIR/p.html"
    [[ "$output" != *'<ul class="lb rv">'* ]]
    # Nothing moved either side, so the fold is absent entirely -- which is the section's
    # own standing behaviour and must survive the second list being added to it.
    [[ "$output" != *'id="sincebuild"'* ]]
}

#!/usr/bin/env bats
# Tests for the brief's controls, and for the one thing they move.
#
# "please know that the main page title is BS. if i ack/dismiss de-2585 and !10408, will
# they disappear from the title?" The answer has to be yes, and it has to be yes before the
# next build: a page whose loudest sentence goes on naming what you have just dealt with is
# a page arguing with its own ✕, and it argues for the whole day.
#
# Two halves, and they are tested apart because they fail apart.
#
# The build half is arcs-page's, and it is a claim about markup: every line arc-morning
# ranked is drawn twice -- once at display size, once as a shortlist row -- so that the
# client's entire job is choosing which half of each pair is not hidden. If the deck were
# only ever the first line, the client would have to compose the replacement, and this page
# would have a second author for which fact leads. That is the thing these pin.
#
# The client half is INTERACT_JS's, run for real against the shimmed DOM in
# test_helper/interact_dom.js. What it decides is a question about one store and two
# attributes and nothing here drives a browser.
#
# The build half of the SELECTION -- that an acknowledged row never reaches arc-morning in
# the first place -- is not here. It belongs to the stage that does the selecting and it is
# in morning_brief.bats, beside the other four rules about what may open the page.
#
# Nothing here pins wording.

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

need_node() {
    command -v node >/dev/null 2>&1 || skip "node is not installed"
}

# A document whose brief names rows the page really renders: one ledger row on each side,
# one cliff verdict and one Jira mismatch. Every fingerprint a line quotes below is a
# fingerprint with a row of its own, which is the condition line_acts draws a ✕ on.
doc() {
    python3 - "$@" <<'ZZDOC'
import json, sys

def arc(aid, age, **kw):
    a = {"id": aid, "label": aid, "kind": "cluster", "stage": "local-only",
         "state": "local-only state", "urgency": 5, "age_days": age,
         "unpushed_live": 6, "unpushed_days": 6, "engagement": 300,
         "unpushed_dates": ["2026-08-0%d" % (d + 1) for d in range(6)],
         "authoritative": "br-" + aid, "branches": [], "mrs": [], "stashes": [],
         "sessions": [], "issues": [], "demands": [],
         "counts": {"branches": 1, "stashes": 0, "mrs": 0, "sessions": 1},
         "brief": {"name": aid, "summary": "It reroutes the thing."}}
    a.update(kw)
    return a

fell = arc("dropped-one", 12)
fell["activity"] = {"cliff_days": 12, "series": [[14, 9], [15, 6], [16, 4]],
                    "invested": {"entries": 19},
                    "forgotten": {"verdict": True, "fp": "fgA",
                                  "why": "19 sessions across 3 days, then nothing"}}

def part(t, **kw):
    p = {"t": t}
    p.update(kw)
    return p

out = {
    "generated": "2026-08-25T10:17:05", "repo": "ul", "main": "origin/main", "me": "kyle",
    "project_url": "https://gitlab.example/ul", "arc_count": 2,
    "arcs": [arc("today-one", 0), fell], "forgotten": ["dropped-one"],
    "only_here": ["today-one", "dropped-one"],
    "brief": {"lines": [
        # Two subjects, which is the ledger sentence's own shape and the case a single ✕
        # could not serve.
        {"kind": "owed", "lead": "open loop", "text": "x",
         "parts": [part("DE-1", fp="lgA", of="ledger", url="https://jira/DE-1"),
                   " has sat with someone; and ",
                   part("!2", fp="lgB", of="ledger", url="https://gl/2"), "."]},
        # One subject with somewhere to go off the page.
        {"kind": "contradiction", "lead": "jira disagrees", "text": "x",
         "parts": [part("UL-9", fp="gpA", of="gap", url="https://jira/UL-9"),
                   " says one thing and the code says another."]},
        # One subject and nowhere off the page to go: a ✕ and no arrow.
        {"kind": "forgotten", "lead": "dropped", "text": "x",
         "parts": ["The freshest thing you dropped is ",
                   part("dropped-one", fp="fgA", of="forgotten", arc="dropped-one"), "."]},
        # And a line naming no row at all, which can never be stepped past.
        {"kind": "quiet", "lead": "overnight", "text": "x",
         "parts": ["Nothing moved under you overnight."]}]},
    "ledger": {"you_owe": [{"fp": "lgA", "kind": "review-owed", "who": "brian",
                            "days": 9, "ref": "DE-1", "title": "the one you owe",
                            "url": "https://jira/DE-1", "asked": "2026-08-16"}],
               "they_owe": [{"fp": "lgB", "kind": "review-silence", "who": ["vadym"],
                             "days": 24, "ref": "!2", "title": "the one they owe",
                             "url": "https://gl/2", "asked": "2026-08-01"}],
               "slack": True, "slack_complete": True},
    "gap": {"jira": True, "status_mismatch": [
        {"fp": "gpA", "ref": "UL-9", "stale_days": 40,
         "issue": {"key": "UL-9", "status": "In Review", "url": "https://jira/UL-9"},
         "arc": {"id": "today-one", "unpushed_live": 6, "unpushed_days": 6},
         "why": "status says In Review but six days of work never pushed"}]},
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

# ── the controls a line carries ───────────────────────────────────────────────

@test "a line carries one control group per subject, and only where the wire has one" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZACTS'
import re, sys
html = open(sys.argv[1]).read()
brief = re.search(r'<ul class="brief">(.*?)</ul>', html, re.S).group(1)
for row in re.findall(r'<li[^>]*>.*?</li>', brief, re.S):
    bas = re.findall(r'data-ackfp="([^"]*)"', row)
    print("%s | x=%d | arrow=%d" % (",".join(bas) or "-",
                                    row.count('class="dis"'), row.count('class="bo"')))
ZZACTS
    # Two subjects, two ✕es, two doors off the page.
    [ "${lines[0]}" = "lgA,lgB | x=2 | arrow=2" ]
    [ "${lines[1]}" = "gpA | x=1 | arrow=1" ]
    # A cliff verdict has a row here and no URL anywhere, so it gets the ✕ and no arrow --
    # never a dead control.
    [ "${lines[2]}" = "fgA | x=1 | arrow=0" ]
    # And a line naming nothing carries nothing at all.
    [ "${lines[3]}" = "- | x=0 | arrow=0" ]
}

@test "a subject with no row on this page gets no control, only its words" {
    # The same test spans() makes before it draws an anchor. A ✕ on a fingerprint no row
    # claims is an acknowledgement the next build prunes while announcing that a fact
    # nobody touched has moved.
    gone='{"gap": {"jira": true, "status_mismatch": []}}'
    page "$(doc "$gone")" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZGONE'
import re, sys
html = open(sys.argv[1]).read()
brief = re.search(r'<ul class="brief">(.*?)</ul>', html, re.S).group(1)
row = [r for r in re.findall(r'<li[^>]*>.*?</li>', brief, re.S) if "UL-9" in r][0]
print("UL-9" in row, 'data-ackfp="gpA"' in row, 'href="#gp-gpA"' in row)
ZZGONE
    # The words stay, the anchor goes, and so does the ✕.
    [ "${lines[0]}" = "True False False" ]
}

@test "the label appears only where a line names more than one row" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZLABEL'
import re, sys
html = open(sys.argv[1]).read()
brief = re.search(r'<ul class="brief">(.*?)</ul>', html, re.S).group(1)
for row in re.findall(r'<li[^>]*>.*?</li>', brief, re.S):
    print(re.findall(r'<span class="bal">([^<]*)</span>', row))
ZZLABEL
    # With two subjects an unlabelled pair could not be aimed at; with one the sentence has
    # already said what the control is for, and the label would be the words twice.
    [ "${lines[0]}" = "['DE-1', '!2']" ]
    [ "${lines[1]}" = "[]" ]
    [ "${lines[2]}" = "[]" ]
}

@test "the ✕ on a line is the row's own fingerprint, not a second one" {
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZSAME'
import re, sys
html = open(sys.argv[1]).read()
for fp in ("lgA", "lgB", "gpA", "fgA"):
    rows = len(re.findall(r'data-fp="%s"' % fp, html))
    proj = len(re.findall(r'data-ackfp="%s"' % fp, html))
    print(fp, rows, proj)
ZZSAME
    # One row per fingerprint, and two projections of it -- the headline candidate and the
    # shortlist row, which are the same line drawn at two sizes.
    [ "${lines[0]}" = "lgA 1 2" ]
    [ "${lines[1]}" = "lgB 1 2" ]
    [ "${lines[2]}" = "gpA 1 2" ]
    [ "${lines[3]}" = "fgA 1 2" ]
}

@test "a projection is never a row: it is not in the universe the store is pruned against" {
    # The load path enumerates [data-fp] to decide which acknowledgements still refer to
    # something, which fades adopt, and what the display:none rule hides. A brief line is a
    # projection of a row and must be none of the three -- above all not the third, or the
    # ✕ that acknowledged it would vanish with it and could never be clicked again.
    page "$(doc)" > "$TEST_TMPDIR/p.html"
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZUNI'
import re, sys
html = open(sys.argv[1]).read()
deck = re.search(r'<div class="deck".*?<ul class="brief">.*?</ul>', html, re.S).group(0)
print(len(re.findall(r'data-fp="', deck)))
ZZUNI
    [ "${lines[0]}" = "0" ]
}

# ── the headline answers ──────────────────────────────────────────────────────

@test "acknowledging every subject of the opening line promotes the next one" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  const h = makeHarness({
    seed: {dismissed: {}},
    rows: [{fp: 'lgA', ref: 'DE-1'}, {fp: 'lgB', ref: '!2'}, {fp: 'gpA', ref: 'UL-9'}],
    brief: [{fps: ['lgA', 'lgB']}, {fps: ['gpA']}, {fps: []}]});
  await h.load(process.env.ROOT + '/bin/arcs-page');
  assert.strictEqual(h.headline(), 0, 'opens on the first line');
  assert.deepStrictEqual(h.listed(), [false, true, true], 'and the rest are the list');

  // One of the two is not all of them: the line still makes half its claim.
  h.clickLine(0, 'lgA', 'head');
  assert.strictEqual(h.headline(), 0, 'one subject acknowledged does not move it');
  assert.deepStrictEqual(h.subjectStruck(0, 'lgA'), [true, true],
    'but the subject is struck wherever it is drawn');
  assert.deepStrictEqual(h.subjectStruck(0, 'lgB'), [false, false],
    'and the other is not');

  h.clickLine(0, 'lgB', 'head');
  assert.strictEqual(h.headline(), 1, 'both acknowledged, and the next line takes the slot');
  assert.deepStrictEqual(h.listed(), [true, false, true],
    'the displaced line is in the list and the promoted one is out of it');
  assert.deepStrictEqual(h.struck(), [true, false, false],
    'and it is struck rather than removed');
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

@test "taking one acknowledgement back puts the headline back" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  const h = makeHarness({
    seed: {dismissed: {}},
    rows: [{fp: 'lgA', ref: 'DE-1'}, {fp: 'lgB', ref: '!2'}, {fp: 'gpA', ref: 'UL-9'}],
    brief: [{fps: ['lgA', 'lgB']}, {fps: ['gpA']}]});
  await h.load(process.env.ROOT + '/bin/arcs-page');
  h.clickLine(0, 'lgA', 'head');
  h.clickLine(0, 'lgB', 'head');
  assert.strictEqual(h.headline(), 1, 'promoted');
  // The demoted line is in the list now, so the ✕ that undoes it is the one on the row.
  h.clickLine(0, 'lgA', 'row');
  assert.strictEqual(h.headline(), 0, 'and back, on the same click that made it');
  assert.deepStrictEqual(h.listed(), [false, true], 'with the shortlist as it was');
  assert.deepStrictEqual(h.struck(), [false, false], 'and nothing left struck');
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

@test "a ✕ on a brief line is a ✕ on the row it points at" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  const h = makeHarness({
    seed: {dismissed: {}},
    rows: [{fp: 'lgA', ref: 'DE-1'}, {fp: 'lgB', ref: '!2'}],
    brief: [{fps: ['lgA', 'lgB']}]});
  await h.load(process.env.ROOT + '/bin/arcs-page');
  h.clickLine(0, 'lgA', 'head');
  assert.strictEqual(h.faded('lgA'), true, 'the row three screens down fades on this click');
  assert.strictEqual(h.faded('lgB'), false, 'and only that row');
  assert.deepStrictEqual(h.controlOn(0, 'lgA'), [true, true],
    'the control says so wherever the line is drawn');
  // One store and one fingerprint: what is published is what the row would have published.
  const seed = await h.publish();
  assert.deepStrictEqual(Object.keys(seed.dismissed), ['lgA'],
    'and the seed names it once: ' + JSON.stringify(seed.dismissed));
  assert.strictEqual(seed.dismissed.lgA.ref, 'DE-1',
    'under the row’s own reference, not the line’s words');
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

@test "the row's own ✕ moves the headline exactly as the line's does" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  const h = makeHarness({
    seed: {dismissed: {}},
    rows: [{fp: 'lgA', ref: 'DE-1'}, {fp: 'lgB', ref: '!2'}, {fp: 'gpA', ref: 'UL-9'}],
    brief: [{fps: ['lgA', 'lgB']}, {fps: ['gpA']}]});
  await h.load(process.env.ROOT + '/bin/arcs-page');
  h.click('lgA'); h.click('lgB');
  assert.strictEqual(h.headline(), 1,
    'acknowledging the rows themselves is the same acknowledgement');
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

@test "a line naming no row is never stepped past" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  // The overnight sentence names an arc and no acknowledgeable row. There is nothing there
  // to have dealt with, so there is nothing that could mean it had been.
  const h = makeHarness({
    seed: {dismissed: {}},
    rows: [{fp: 'gpA', ref: 'UL-9'}],
    brief: [{fps: []}, {fps: ['gpA']}]});
  await h.load(process.env.ROOT + '/bin/arcs-page');
  assert.strictEqual(h.headline(), 0, 'it opens the page');
  h.click('gpA');
  assert.strictEqual(h.headline(), 0, 'and every other line being dealt with does not move it');
  assert.deepStrictEqual(h.struck(), [false, true], 'the ones that were are still said so');
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

@test "a morning with everything acknowledged still opens on a fact" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  const h = makeHarness({
    seed: {dismissed: {}},
    rows: [{fp: 'lgA', ref: 'DE-1'}, {fp: 'gpA', ref: 'UL-9'}],
    brief: [{fps: ['lgA']}, {fps: ['gpA']}]});
  await h.load(process.env.ROOT + '/bin/arcs-page');
  h.click('lgA'); h.click('gpA');
  // Clamped rather than run off the end: answering the last ✕ by deleting the page's own
  // headline would be the one thing this page has never done to a fact.
  assert.strictEqual(h.headline(), 1, 'the last line stays in the slot');
  assert.deepStrictEqual(h.listed(), [true, false], 'with the rest of them below it');
  assert.deepStrictEqual(h.struck(), [true, true], 'and every one of them saying so');
  h.click('gpA');
  assert.strictEqual(h.headline(), 1, 'and one taken back is the slot it was always in');
  assert.deepStrictEqual(h.struck(), [true, false]);
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

@test "a fade the build baked opens the page on the next line, before any click" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  // The load path adopts what the build baked, so a page rebuilt while an acknowledgement
  // was in flight opens correctly on the first read rather than on the first click.
  const h = makeHarness({
    seed: {dismissed: {}},
    rows: [{fp: 'lgA', dismissed: true, ref: 'DE-1'}, {fp: 'gpA', ref: 'UL-9'}],
    brief: [{fps: ['lgA']}, {fps: ['gpA']}]});
  await h.load(process.env.ROOT + '/bin/arcs-page');
  assert.strictEqual(h.headline(), 1, 'opens on the line that has not been dealt with');
  assert.deepStrictEqual(h.subjectStruck(0, 'lgA'), [true, true],
    'and says why about the one that has');
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

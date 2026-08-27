#!/usr/bin/env bats
# Tests for taking an acknowledgement back.
#
# The ✕ has always been able to say "I have dealt with this" and never able to say "no I
# have not". That reads like a missing nicety and is the loop breaking: the merge at the
# pipeline end is a UNION, deliberately, so that a page open since Tuesday cannot undo
# every judgement made anywhere else since -- and a union can only ever add. The one
# channel that can subtract is the page naming, outright, the fingerprints it was seeded
# with and has been told to let go of. If the page never fills that in, a ✕ clicked a
# second time is not slow to arrive; it can never arrive at all.
#
# Which is exactly what happened on the live page: a row the build had rendered faded was
# un-✕ed, the publish went through, and the row came straight back faded. Three things had
# to be true at once for that, and each has its own test below:
#
#   the page's record of what it arrived carrying was the seed block alone -- but the seed
#   is rewritten by the client on every publish while the rows' data-dismissed stays the
#   bytes the last rebuild baked, so after one publish the page no longer recognised its
#   own acknowledgements and had nothing to name;
#
#   the take-back was never written down anywhere that survives a reload;
#
#   and the load path applied fades in one direction only, adopting every baked one back
#   in -- so the reload that follows a publish re-faded the row and closed the circle.
#
# The JS is run for real, against a DOM shimmed down to the three things it decides on:
# see test_helper/interact_dom.js. Nothing here drives a browser.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    export ROOT="$REPO_ROOT"
    # arcs-page lives in the extracted work-arcs repo; the JS test helper does not
    export ARCS="$ARCS_ROOT"
}

teardown() {
    teardown_temp_dir
}

# The harness runs the shipped INTERACT_JS. Where there is no node there is no test rather
# than a green one: a skipped test says the link is untested, and a deleted one says it
# does not need testing.
need_node() {
    command -v node >/dev/null 2>&1 || skip "node is not installed"
}

# --- what the page knows it arrived carrying -------------------------------------------

@test "a fade the build baked counts as an acknowledgement the page arrived carrying" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  // The state the live page was in: one row rendered faded by the build, and a seed block
  // a previous publish had already rewritten without it.
  const h = makeHarness({seed: {dismissed: {}},
                         rows: [{fp: 'baked', dismissed: true, ref: '!1'}]});
  await h.load(process.env.ARCS + '/bin/arcs-page');
  assert.strictEqual(h.faded('baked'), true, 'arrives faded');
  h.click('baked');
  assert.strictEqual(h.faded('baked'), false, 'the un-click un-fades in place');
  const seed = await h.publish();
  assert.deepStrictEqual(seed.undismissed, ['baked'],
    'the take-back is named on the way back: ' + JSON.stringify(seed));
  assert.ok(!('baked' in seed.dismissed),
    'and is not also published as an acknowledgement');
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

@test "a take-back survives the reload that follows the publish" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  const first = makeHarness({seed: {dismissed: {}},
                             rows: [{fp: 'baked', dismissed: true, ref: '!1'}]});
  await first.load(process.env.ARCS + '/bin/arcs-page');
  first.click('baked');
  await first.publish();
  // What comes back from a publish is the same baked markup with one block replaced, so
  // the row is still faded in the bytes. Carrying the browser's stores across is the whole
  // point: without them the load adopts that fade straight back.
  const back = makeHarness({seed: {dismissed: {}},
                            rows: [{fp: 'baked', dismissed: true, ref: '!1'}],
                            storage: first.storage()});
  await back.load(process.env.ARCS + '/bin/arcs-page');
  assert.strictEqual(back.faded('baked'), false, 'the fade stays lifted on reload');
  assert.ok('baked' in back.read('work-arcs:undismissed:v1'),
    'and the take-back still names the fingerprint: '
    + JSON.stringify(back.read('work-arcs:undismissed:v1')));
  // And it goes on being named on every publish until the pipeline has read it: nothing
  // about a reload tells this page whether that has happened yet.
  const again = makeHarness({seed: {dismissed: {}},
                             rows: [{fp: 'baked', dismissed: true, ref: '!1'},
                                    {fp: 'other', dismissed: false, ref: '!2'}],
                             storage: back.storage()});
  await again.load(process.env.ARCS + '/bin/arcs-page');
  again.click('other');
  const seed = await again.publish();
  assert.deepStrictEqual(seed.undismissed, ['baked'],
    'still taken back: ' + JSON.stringify(seed));
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

@test "the take-back lets go once the pipeline has caught up" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  const first = makeHarness({seed: {dismissed: {}},
                             rows: [{fp: 'baked', dismissed: true, ref: '!1'}]});
  await first.load(process.env.ARCS + '/bin/arcs-page');
  first.click('baked');
  // A rebuild has since read the take-back: the row is no longer baked faded and the seed
  // no longer carries it. There is nothing left to take back, and holding on to it would
  // un-acknowledge the next honest ✕ on the same row.
  const fresh = makeHarness({seed: {dismissed: {}},
                             rows: [{fp: 'baked', dismissed: false, ref: '!1'}],
                             storage: first.storage()});
  await fresh.load(process.env.ARCS + '/bin/arcs-page');
  assert.deepStrictEqual(fresh.read('work-arcs:undismissed:v1'), {},
    'the store expired itself');
  fresh.click('baked');
  assert.strictEqual(fresh.faded('baked'), true, 're-acknowledging works');
  const seed = await fresh.publish();
  assert.ok('baked' in seed.dismissed, 'and publishes as an acknowledgement');
  assert.deepStrictEqual(seed.undismissed, [], 'with nothing taken back');
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

@test "acknowledging again in the same sitting cancels the take-back" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  const h = makeHarness({seed: {dismissed: {'baked': {ref: '!1', at: 9, note: ''}}},
                         rows: [{fp: 'baked', dismissed: true, ref: '!1'}]});
  await h.load(process.env.ARCS + '/bin/arcs-page');
  h.click('baked');
  h.click('baked');
  const seed = await h.publish();
  assert.deepStrictEqual(seed.undismissed, [], 'nothing is taken back');
  assert.ok('baked' in seed.dismissed, 'the row is acknowledged again');
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

# --- the seed the page publishes -------------------------------------------------------

@test "a republish is a union of what the page was handed and what this browser clicked" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  // 'elsewhere' was acknowledged on another device and rides in the seed with no row on
  // this page at all -- a workstream outside the focus window. Publishing this browser's
  // stores alone would drop it out of the page's own account of itself, and there is no
  // reading that absence back: a fingerprint the page never rendered looks identical.
  const h = makeHarness({
    seed: {dismissed: {'elsewhere': {ref: 'UL-9', at: 700, note: 'fine'}}},
    rows: [{fp: 'here', dismissed: false, ref: '!2'}]});
  await h.load(process.env.ARCS + '/bin/arcs-page');
  h.click('here');
  const seed = await h.publish();
  assert.ok('elsewhere' in seed.dismissed, 'the seed half survives');
  assert.ok('here' in seed.dismissed, 'the browser half is added');
  assert.strictEqual(seed.dismissed.elsewhere.note, 'fine', 'with its judgement intact');
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

# When a row was acknowledged is a fact about the acknowledgement, and a republish is not a
# new one. The live page had every acknowledgement on it restamped to the second of the
# publish, which is a page quietly rewriting its own history every time anything is
# clicked anywhere on it.
@test "a republish does not restamp the acknowledgements it was handed" {
    need_node
    node - <<'ZZJS'
const {makeHarness} = require(process.env.ROOT + '/test/test_helper/interact_dom.js');
const assert = require('assert');
(async () => {
  const h = makeHarness({
    seed: {dismissed: {'old': {ref: '!1', at: 1700000000, note: 'noise'}}},
    rows: [{fp: 'old', dismissed: true, ref: '!1'},
           {fp: 'new', dismissed: false, ref: '!2'}]});
  await h.load(process.env.ARCS + '/bin/arcs-page');
  h.click('new');
  const seed = await h.publish();
  assert.strictEqual(seed.dismissed.old.at, 1700000000,
    'the old stamp is kept: ' + JSON.stringify(seed.dismissed.old));
  assert.strictEqual(seed.dismissed.old.note, 'noise', 'and so is the judgement');
  assert.ok(seed.dismissed.new.at > 1700000000, 'the new one is stamped now');
})().catch(e => { console.error(e); process.exit(1); });
ZZJS
}

# --- what the build has to promise the client ------------------------------------------
#
# Everything above rests on one thing the server does: a row rendered faded and the seed
# block have to agree about which fingerprints are acknowledged. They are two halves of one
# record -- apply_dismissals marks the row and returns the same entry for the seed -- and
# if a future universe ever bakes a fade from a store the seed does not carry, the page
# will not recognise that acknowledgement as its own and its ✕ will go nowhere, silently.

@test "every fade the page bakes is a fingerprint the seed block carries" {
    python3 - "$ARCS_ROOT/bin/arcs-page" >"$TEST_TMPDIR/p.html" <<'ZZDOC'
import json, subprocess, sys
row = {"kind": "review-owed", "who": "person", "days": 4, "ref": "!101",
       "title": "a merge request", "url": "u", "asked": "2026-08-01",
       "fp": "led1", "dismissed": True}
mis = {"issue": {"key": "UL-3", "summary": "a ticket", "url": "u"},
       "status": "In Progress", "reality": "local-only", "stale_days": 9,
       "fp": "mis1", "dismissed": True}
doc = {"generated": 1756000000, "repo": "ul", "main": "origin/main", "me": "kyle",
       "arc_count": 0, "arcs": [], "forgotten": [], "only_here": [],
       "ledger": {"they_owe": [], "you_owe": [row]},
       "gap": {"status_mismatch": [mis]},
       "acks": {"dismissed": {"led1": {"ref": "!101", "at": 5, "note": ""},
                              "mis1": {"ref": "UL-3", "at": 6, "note": ""}}}}
r = subprocess.run([sys.executable, sys.argv[1], "--focus", "30"],
                   input=json.dumps(doc), capture_output=True, text=True)
sys.stderr.write(r.stderr)
sys.exit(r.returncode) if r.returncode else sys.stdout.write(r.stdout)
ZZDOC
    run python3 - "$TEST_TMPDIR/p.html" <<'ZZCHECK'
import json, re, sys
h = open(sys.argv[1]).read()
seed = json.loads(re.search(
    r'<script type="application/json" id="ackseed">(.*?)</script>', h, re.S).group(1))
baked = set()
for tag in re.finditer(r'<(?:li|tr|div|article)\b[^>]*>', h):
    t = tag.group(0)
    fp = re.search(r'data-fp="([^"]*)"', t)
    if fp and re.search(r'data-dismissed="1"', t):
        baked.add(fp.group(1))
missing = sorted(baked - set(seed["dismissed"]))
print(len(baked), "|", ",".join(missing))
ZZCHECK
    [ "${lines[0]}" = "2 | " ]
}

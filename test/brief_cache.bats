#!/usr/bin/env bats
# Tests for the brief cache's retention -- arc-brief.
#
# The cache is keyed on the evidence, the model and the prompt together, so every prompt
# reword and every model switch retires the generation before it wholesale. That is correct
# and is not what these tests are about. What was missing is the other half: nothing ever
# removed the retired generation, so three weeks of edits had left 914 entries carrying
# their full evidence text to serve 157 live arcs.
#
# Two failures are worth pinning, and they pull against each other. Pruning too eagerly
# throws away a brief for an arc that is merely quiet, and the next run pays a model call to
# learn what it already knew. Pruning by write-time rather than by use does exactly that, so
# the horizon is measured from last use and the tests say so. Pruning too little is the bug
# being fixed, so the drop is asserted too -- as is the announcement, because a cache that
# silently shrinks is indistinguishable from a cache that is working and cold.
#
# The third test is the subtle one. The last-use stamp must not reach the emitted payload:
# arc-morning keys its own cache on the prompt it builds, and that prompt embeds every arc's
# brief, so a timestamp in there would reword the question every run and miss that cache
# every time -- reintroducing downstream precisely the bug being fixed here.
#
# The cache functions are called directly. They are pure over the store dict and the clock,
# and reaching them through the CLI would mean a git repo and a model call to test a filter.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    # No test may read or write the real brief cache. arc-brief resolves STATE and CACHE at
    # import time, so this has to be exported before the module is loaded, not after.
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    mkdir -p "$XDG_STATE_HOME/work-arcs"
}

teardown() {
    teardown_temp_dir
}

# Runs a python snippet with arc-brief imported as `ab`. NOW fixes the clock at a fixed
# instant so an age in a test is a fact about the fixture and not about the day it runs.
ab() {
    python3 - "$ARCS_ROOT/bin/arc-brief" <<PY
import importlib.machinery, importlib.util, sys, json, time
loader = importlib.machinery.SourceFileLoader("ab", sys.argv[1])
spec = importlib.util.spec_from_loader("ab", loader)
ab = importlib.util.module_from_spec(spec)
sys.argv = ["ab"]
loader.exec_module(ab)

NOW = int(time.time())
DAY = 86400

def brief(name, at_days=0, used_days=None, **kw):
    """One cache entry, aged in days before NOW. used_days=None is the legacy shape."""
    e = {"name": name, "summary": "", "blocker": "", "model": "sonnet",
         "at": NOW - at_days * DAY, "evidence_sha": "x", "evidence": "ev:" + name}
    if used_days is not None:
        e["last_used"] = NOW - used_days * DAY
    e.update(kw)
    return e

def saved():
    """The cache as it exists on disk after a save."""
    return json.loads(ab.CACHE.read_text())

def names(store):
    return sorted(v["name"] for v in store.values() if isinstance(v, dict))

$1
PY
}

# ── what the horizon is measured from ─────────────────────────────────────────

@test "a brief nothing has asked for past the horizon is dropped" {
    run ab '
ab.save_cache({"a": brief("kept", at_days=3), "b": brief("stale", at_days=90)})
print(names(saved()))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['kept']"* ]]
}

@test "last use outranks write time: an old brief served yesterday stays" {
    # The case that separates this from pruning by age. An arc untouched since June is a
    # cache hit the day you return to it, and paying a model call to rediscover its name is
    # the cost this whole file exists to avoid.
    run ab '
ab.save_cache({"a": brief("old-but-used", at_days=200, used_days=1)})
print(names(saved()))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['old-but-used']"* ]]
}

@test "a brief written recently but never served since is dated by its write" {
    # The legacy shape: every entry in the cache predating this feature has no last_used,
    # and dating those by `at` is the conservative reading -- it can only make an entry look
    # older than it is, never newer, and the first run that serves one stamps it.
    run ab '
ab.save_cache({"a": brief("fresh-write", at_days=2),
               "b": brief("old-write", at_days=60)})
print(names(saved()))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['fresh-write']"* ]]
}

@test "the horizon is configurable and zero disables pruning entirely" {
    run ab '
store = {"a": brief("ancient", at_days=400)}
ab.save_cache(store, keep_days=0)
print("keep0", names(saved()))
ab.save_cache(store, keep_days=500)
print("keep500", names(saved()))
ab.save_cache(store, keep_days=30)
print("keep30", names(saved()))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"keep0 ['ancient']"* ]]
    [[ "$output" == *"keep500 ['ancient']"* ]]
    [[ "$output" == *"keep30 []"* ]]
}

# ── saying what it did ────────────────────────────────────────────────────────

@test "a prune announces the count it dropped and the count it kept" {
    # A cache that quietly shrinks looks exactly like a cache that is working and cold, and
    # the difference is a run's worth of model calls.
    run ab '
said = []
ab.save_cache({"a": brief("keep", at_days=1),
               "b": brief("drop1", at_days=99),
               "c": brief("drop2", at_days=99)}, say=said.append)
print("|".join(said))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"dropped 2"* ]]
    [[ "$output" == *"1 kept"* ]]
}

@test "a save that drops nothing says nothing" {
    run ab '
said = []
ab.save_cache({"a": brief("keep", at_days=1)}, say=said.append)
print("SAID:" + "|".join(said))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"SAID:"* ]]
    [[ "$output" != *"dropped"* ]]
}

# ── the bookkeeping must not reach the payload ────────────────────────────────

@test "the payload handed downstream carries no last_used" {
    # arc-morning keys its cache on a prompt that embeds every arc's brief. A stamp in here
    # reworks that question on every run and misses that cache every time.
    run ab '
e = brief("named", at_days=1, used_days=0)
p = ab.payload_of(e)
print("keys", sorted(p))
print("stamped", "last_used" in e)
'
    [ "$status" -eq 0 ]
    # The stamp is on the entry the file keeps...
    [[ "$output" == *"stamped True"* ]]
    # ...and absent from the keys the payload exposes.
    [[ "$output" != *"'last_used'"* ]]
}

@test "the payload is otherwise the brief unchanged" {
    run ab '
e = brief("named", at_days=1, used_days=0)
p = ab.payload_of(e)
print("same", all(p[k] == e[k] for k in p))
print("only", sorted(set(e) - set(p)))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"same True"* ]]
    [[ "$output" == *"only ['last_used']"* ]]
}

# ── it must not fall over on a store it did not write ─────────────────────────

@test "a junk value in the store is dropped rather than crashing the save" {
    # load_store returns whatever a dict-shaped file holds, and this one is edited by hand
    # often enough that a malformed value has to cost an entry rather than the run.
    run ab '
ab.save_cache({"a": brief("real", at_days=1), "b": "not-a-dict", "c": None, "d": 42})
print(names(saved()))
print("n", len(saved()))
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"['real']"* ]]
    [[ "$output" == *"n 1"* ]]
}

@test "an entry whose timestamps are the wrong type is dated zero, not crashed on" {
    run ab '
ab.save_cache({"a": brief("bad-at", at_days=1, at="yesterday"),
               "b": brief("bad-used", at_days=1, last_used=[]),
               "c": brief("good", at_days=1)})
print(names(saved()))
'
    [ "$status" -eq 0 ]
    # "bad-used" still has a usable `at`; "bad-at" has neither and goes.
    [[ "$output" == *"bad-used"* ]]
    [[ "$output" == *"good"* ]]
    [[ "$output" != *"bad-at"* ]]
}

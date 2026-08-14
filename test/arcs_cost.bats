#!/usr/bin/env bats
# Tests for arcs-cost. Only the parts that can be wrong without looking wrong:
#
#   - a streamed assistant turn is written twice with one message.id, so counting lines
#     instead of responses inflates every figure by a third
#   - the two cache TTLs differ by 1.6x in write cost and this pipeline uses the dearer
#     one, so the split has to be read per call rather than assumed
#   - the pipeline's calls and his own sessions must never be summed together
#   - `resets_at` jitters in the sub-second digits on every response, so comparing it
#     exactly makes every sample pair look like it crossed a reset and the quota rate
#     stays silently unmeasurable forever
#   - a model with no listed price must be counted and left unpriced, never guessed at
#
# The arithmetic itself is not tested; it is one expression and reading it is cheaper
# than asserting on it.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export WORK_ARCS_PROJECTS="$TEST_TMPDIR/projects"
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    # The pipeline's own project directory is named after headless_claude's session dir,
    # which hangs off XDG_STATE_HOME -- so it moves with it, and the fixture has to ask
    # for the name rather than hardcode it.
    PIPELINE_DIR="$(python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/lib')
import headless_claude; print(headless_claude.PROJECT_DIR)")"
    mkdir -p "$WORK_ARCS_PROJECTS/$PIPELINE_DIR" "$WORK_ARCS_PROJECTS/-home-kyle-work"
}

teardown() {
    teardown_temp_dir
}

# add_call <dir> <file> <msgid> <model> <in> <out> <cache1h> <cache5m> <cacheread>
add_call() {
    python3 - "$WORK_ARCS_PROJECTS/$1/$2.jsonl" "$3" "$4" "$5" "$6" "$7" "$8" "$9" <<'PY'
import json, sys, datetime
path, mid, model, ti, to, c1h, c5m, cr = sys.argv[1:9]
now = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=5)
rec = {"type": "assistant", "timestamp": now.isoformat().replace("+00:00", "Z"),
       "message": {"id": mid, "model": model, "usage": {
           "input_tokens": int(ti), "output_tokens": int(to),
           "cache_creation_input_tokens": int(c1h) + int(c5m),
           "cache_read_input_tokens": int(cr),
           "cache_creation": {"ephemeral_1h_input_tokens": int(c1h),
                              "ephemeral_5m_input_tokens": int(c5m)}}}}
with open(path, "a") as fh:
    fh.write(json.dumps(rec) + "\n")
PY
}

# samples <weekly_a> <weekly_b> <reset_a_offset_days> <reset_b_offset_days>
# Writes a start/end pair whose weekly reset boundaries sit the given number of days out.
samples() {
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    python3 - "$XDG_STATE_HOME/work-arcs/usage.jsonl" "$1" "$2" "$3" "$4" <<'PY'
import json, sys, time, datetime
path, ua, ub, ra, rb = sys.argv[1:6]
now = time.time()
def rec(ts, util, reset_days, marker, micros):
    reset = (datetime.datetime.now(datetime.timezone.utc)
             + datetime.timedelta(days=float(reset_days))).replace(microsecond=micros)
    win = {"utilization": float(util), "resets_at": reset.isoformat()}
    return {"ts": int(ts), "marker": marker, "seven_day": win, "five_hour": win}
with open(path, "w") as fh:
    fh.write(json.dumps(rec(now - 600, ua, ra, "start", 527968)) + "\n")
    fh.write(json.dumps(rec(now - 60, ub, rb, "end", 31740)) + "\n")
PY
}

cost() {
    "$REPO_ROOT/bin/arcs-cost" --json > "$TEST_TMPDIR/cost.json"
    python3 - "$TEST_TMPDIR/cost.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d, "w": d["windows"]["week"], "q": d["quota"],
                         "r": d["runs"]}))
PY
}

@test "a streamed turn written twice is one call, not two" {
    # Same message.id twice, exactly as Claude Code appends it mid-stream and again on
    # completion. Counting lines here would report 2 calls and double the tokens.
    add_call "$PIPELINE_DIR" s1 msg_dup claude-opus-5 10 100 0 0 0
    add_call "$PIPELINE_DIR" s1 msg_dup claude-opus-5 10 100 0 0 0
    add_call "$PIPELINE_DIR" s1 msg_two claude-opus-5 10 100 0 0 0

    [ "$(cost 'w["pipeline"]["calls"]')" = "2" ]
    [ "$(cost 'w["pipeline"]["output"]')" = "200" ]
}

@test "a 1-hour cache write costs more than the same 5-minute write" {
    add_call "$PIPELINE_DIR" hour  m_h claude-opus-5 0 0 1000000 0 0
    h="$(cost 'round(w["pipeline"]["list_cost"], 4)')"
    rm "$WORK_ARCS_PROJECTS/$PIPELINE_DIR/hour.jsonl"
    add_call "$PIPELINE_DIR" five  m_f claude-opus-5 0 0 0 1000000 0
    f="$(cost 'round(w["pipeline"]["list_cost"], 4)')"

    # 2x vs 1.25x of $5/MTok on a million tokens: $10 against $6.25.
    [ "$h" = "10.0" ]
    [ "$f" = "6.25" ]
}

@test "his own sessions are counted apart from the pipeline's calls" {
    add_call "$PIPELINE_DIR"      p m_p claude-opus-5 0 1000 0 0 0
    add_call "-home-kyle-work"    i m_i claude-opus-5 0 3000 0 0 0

    [ "$(cost 'w["pipeline"]["calls"]')" = "1" ]
    [ "$(cost 'w["interactive"]["calls"]')" = "1" ]
    # A quarter of the weighted total is the pipeline's.
    [ "$(cost 'round(w["share_pct"])')" = "25" ]
}

@test "sub-second jitter in resets_at is the same window, so the rate is observable" {
    # The two boundaries differ only in their microseconds -- one reading said
    # ...59.527968 and the next ...00.031740 of the same weekly window.
    add_call "$PIPELINE_DIR" p m_p claude-opus-5 0 200000 0 0 0
    samples 10 14 7 7

    [ "$(cost 'q["rates"]["seven_day"]["pairs"]')" = "1" ]
    [ "$(cost 'q["rates"]["seven_day"]["points"]')" = "4.0" ]
    [ "$(cost 'q["rates"]["seven_day"]["cost_per_point"] is not None')" = "True" ]
    [ "$(cost 'q["pipeline_share_pct"] is not None')" = "True" ]
}

@test "a real reset is rejected, and the share says so rather than guessing" {
    # Same utilisation movement, but the boundary jumped a whole window forward.
    add_call "$PIPELINE_DIR" p m_p claude-opus-5 0 200000 0 0 0
    samples 10 14 0.01 7

    [ "$(cost 'q["rates"]["seven_day"]["pairs"]')" = "0" ]
    [ "$(cost 'q["pipeline_share_pct"] is None')" = "True" ]
    [ -n "$(cost 'q["unmeasured"]')" ]
}

@test "a run is measured only when its own two snapshots bracket it" {
    add_call "$PIPELINE_DIR" p m_p claude-opus-5 0 200000 0 0 0

    [ "$(cost 'r["measured"]')" = "0" ]
    samples 10 14 7 7
    [ "$(cost 'r["measured"]')" = "1" ]
    [ "$(cost 'r["last"]["list_cost"] > 0')" = "True" ]
}

@test "an unlisted model is counted and left unpriced rather than guessed at" {
    add_call "$PIPELINE_DIR" p m_x claude-something-unreleased 0 1000000 0 0 0

    [ "$(cost 'w["pipeline"]["calls"]')" = "1" ]
    [ "$(cost 'w["pipeline"]["output"]')" = "1000000" ]
    [ "$(cost 'w["pipeline"]["unpriced"]')" = "1" ]
    [ "$(cost 'w["pipeline"]["list_cost"]')" = "0.0" ]
}

@test "Claude Code's synthetic lines are not API calls" {
    add_call "$PIPELINE_DIR" p m_s "<synthetic>" 0 1000 0 0 0

    [ "$(cost 'w["pipeline"]["calls"]')" = "0" ]
}

@test "a fast run still gets its closing snapshot, and an end never orphans" {
    # The throttle is on the pair. Rate-limiting both ends drops the `end` of any run
    # shorter than a minute -- which is what a fully-cached rebuild is -- so those runs
    # would silently never be measured and the per-run figure would describe only the
    # slow ones. Faked here by writing the start directly, since the real one needs
    # credentials.
    mkdir -p "$XDG_STATE_HOME/work-arcs"
    python3 -c "
import json, time
w = {'utilization': 5.0, 'resets_at': '2026-08-19T11:00:00.1+00:00'}
print(json.dumps({'ts': int(time.time()), 'marker': 'start',
                  'seven_day': w, 'five_hour': w}))" \
        > "$XDG_STATE_HOME/work-arcs/usage.jsonl"

    # An end immediately after a start is the second half of one measurement, so it is
    # written even though well under a minute has passed.
    run python3 -c "
import importlib.util as u
from importlib.machinery import SourceFileLoader
s = u.spec_from_loader('ac', SourceFileLoader('ac', '$REPO_ROOT/bin/arcs-cost'))
m = u.module_from_spec(s); s.loader.exec_module(m)
m.fetch_usage = lambda: {'five_hour': {'utilization': 9.0, 'resets_at': '2026-08-19T11:00:00.2+00:00'},
                         'seven_day': {'utilization': 9.0, 'resets_at': '2026-08-19T11:00:00.3+00:00'}}
m.take_sample('end')
m.take_sample('end')   # nothing left to close
m.take_sample('start') # throttled behind the fresh end
print(sum(1 for _ in open(m.SAMPLES)))"
    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "sampling degrades silently with no credentials" {
    export HOME="$TEST_TMPDIR/nohome"
    mkdir -p "$HOME"
    run "$REPO_ROOT/bin/arcs-cost" --sample start
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

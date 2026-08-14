#!/usr/bin/env bats
# The isolation contract for `claude -p` utility calls -- see lib/headless_claude.py.
#
# A tool that shells out to Claude to classify a Slack message or name an arc starts a
# real session, and four consumers have to recognise it as not-work: orch's session list,
# arc-backfill's prompt corpus, arc-record's Stop hook, and arcs-cost's spend split. Each
# recognised it by the one absolute path the current XDG_STATE_HOME derives, and the A/B
# that chose the brief model gave each arm its own state root -- so all four went blind at
# once to 65 of arc-brief's own calls. What these tests pin is that the *name* of the
# directory is the contract, not where it happens to be rooted.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir
    export XDG_STATE_HOME="$TEST_TMPDIR/state"
    PROJECTS="$TEST_TMPDIR/projects"
    # A headless dir under a state root that is not this process's -- exactly the shape
    # the A/B produced, and the shape a path match cannot see.
    SCRATCH_HEADLESS="$PROJECTS/-tmp-scratch-ab-sonnet-claude-headless"
    mkdir -p "$SCRATCH_HEADLESS" "$PROJECTS/-home-kyle-work-repo"
}

teardown() {
    teardown_temp_dir
}

# A transcript with one substantive prompt in it.
add_transcript() {
    python3 - "$1" "$2" <<'PY'
import json, sys, datetime
path, prompt = sys.argv[1:3]
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
with open(path, "w") as fh:
    fh.write(json.dumps({"type": "user", "timestamp": now, "cwd": "/somewhere",
                         "gitBranch": "main",
                         "message": {"content": prompt}}) + "\n")
PY
}

pred() {
    python3 -c "
import sys; sys.path.insert(0, '$REPO_ROOT/lib')
import headless_claude as h; print(h.$1)"
}

@test "a headless dir is recognised under any state root, not just this one" {
    [ "$(pred "is_utility_project_dir('-tmp-scratch-ab-sonnet-claude-headless')")" = "True" ]
    [ "$(pred "is_utility_project_dir(h.PROJECT_DIR)")" = "True" ]
    [ "$(pred "is_utility_project_dir('-home-kyle-work-repo')")" = "False" ]
}

@test "the cwd form recognises a moved session dir too" {
    [ "$(pred "is_utility_cwd('/tmp/scratch/ab-sonnet/claude-headless')")" = "True" ]
    [ "$(pred "is_utility_cwd('/home/kyle/bin/dev-workflow-tools')")" = "False" ]
    [ "$(pred "is_utility_cwd('')")" = "False" ]
}

@test "arc-backfill leaves a moved headless dir out of the prompt corpus" {
    # The loop this closes: arc-brief describing 59 arcs writes 59 transcripts that the
    # next backfill reads back as prompts, clusters, and describes again.
    add_transcript "$SCRATCH_HEADLESS/util.jsonl" \
        "Name this cluster of work in under six words, returning only the name"
    add_transcript "$PROJECTS/-home-kyle-work-repo/real.jsonl" \
        "the dev server reloads twice on every save and it is driving me up the wall"

    run "$REPO_ROOT/bin/arc-backfill" --projects "$PROJECTS"
    [ "$status" -eq 0 ]

    log="$XDG_STATE_HOME/work-arcs/turns.jsonl"
    [ -f "$log" ]
    run grep -c "dev server reloads" "$log"
    [ "$output" = "1" ]
    run grep -c "Name this cluster" "$log"
    [ "$output" = "0" ]
}

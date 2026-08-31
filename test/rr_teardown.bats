#!/usr/bin/env bats
# Tests for rr.sh's generator teardown.
#
# The generator runs a blocking dirty-check fan-out (xargs -P) before it writes a single
# row, so no SIGPIPE ever reaches it when fzf goes away. Killing the subshell pid alone
# left the fan-out and its children running to completion after rr had exited -- verified
# at 24 of 24 -- which is why the launch enables job control and the teardown kills the
# whole process group.
#
# Two of these are text assertions about rr.sh rather than behaviour, deliberately. The
# realistic regressions here are "someone drops set -m" and "someone escalates TERM to
# KILL", and the second is the dangerous one: git removes .git/index.lock on TERM and
# strands it on KILL, so a group KILL here would strand up to RR_DIRTY_JOBS locks per
# invocation and silently make every later git call in those worktrees re-hash its whole
# tracked tree. Nothing else in the suite would notice either change.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
RR="$REPO_ROOT/bin/rr.sh"

@test "the generator is launched under job control so it owns a process group" {
    run grep -B2 -E '^\} > "\$_data_fifo" 2>/dev/null &' "$RR"
    [ "$status" -eq 0 ]
    run grep -n '^set -m$' "$RR"
    [ "$status" -eq 0 ]
    run grep -n '^set +m$' "$RR"
    [ "$status" -eq 0 ]
}

@test "the teardown kills the process group, not just the subshell" {
    run grep -E 'kill -TERM -- "-\$_gen_pid"' "$RR"
    [ "$status" -eq 0 ]
    # A bare kill of the pid is what let the fan-out outlive rr.
    run grep -E '\{ kill "\$_gen_pid"' "$RR"
    [ "$status" -ne 0 ]
}

# The one that must never regress quietly.
@test "nothing in rr.sh SIGKILLs the generator group" {
    run grep -nE 'kill +(-9|-KILL|-s *KILL|-SIGKILL).*-\$_gen_pid' "$RR"
    [ "$status" -ne 0 ]
}

@test "every exit path runs the cleanup, since the group no longer gets terminal SIGINT" {
    run grep -E '^trap _rr_cleanup EXIT$' "$RR"
    [ "$status" -eq 0 ]
    run grep -E "^trap '_rr_cleanup; exit 130' INT$" "$RR"
    [ "$status" -eq 0 ]
    run grep -E "^trap '_rr_cleanup; exit 143' TERM$" "$RR"
    [ "$status" -eq 0 ]
}

# The INT handler and the EXIT trap both fire on one Ctrl-C, so cleanup runs twice.
@test "the cleanup is idempotent" {
    setup_temp_dir
    cat > "$TEST_TMPDIR/c.sh" <<'SH'
_gen_pid=""
_data_fifo="$1"
AUTO_WT_ROWS_FILE="$2"
_remote_rows_file="$3"
_branchless_rows_file="$4"
SH
    sed -n '/^_rr_cleanup() {/,/^}/p' "$RR" >> "$TEST_TMPDIR/c.sh"
    printf '_rr_cleanup; _rr_cleanup; echo SURVIVED\n' >> "$TEST_TMPDIR/c.sh"
    touch "$TEST_TMPDIR/a" "$TEST_TMPDIR/b" "$TEST_TMPDIR/c"
    run bash "$TEST_TMPDIR/c.sh" "$TEST_TMPDIR/fifo" "$TEST_TMPDIR/a" "$TEST_TMPDIR/b" "$TEST_TMPDIR/c"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SURVIVED"* ]]
    teardown_temp_dir
}

# The mechanism itself, on rr.sh's exact shape: a blocking parallel pass that writes
# nothing until it finishes, feeding a fifo whose reader leaves early.
@test "a group TERM cancels a blocking xargs fan-out that a bare kill would not" {
    setup_temp_dir
    local marker="$TEST_TMPDIR/ran"
    cat > "$TEST_TMPDIR/h.sh" <<'SH'
marker="$1"; mode="$2"
fifo=$(mktemp -u); mkfifo "$fifo"
gen() {
    while IFS= read -r l; do :; done < <(
        seq 1 4 | xargs -r -P 4 -I{} bash -c 'sleep 8; echo ran >> "'"$marker"'"' _ {}
    )
    echo rows
}
[ "$mode" = "group" ] && set -m
{ gen | cat > "$fifo"; } 2>/dev/null &
gen_pid=$!
set +m
head -c 1 < "$fifo" >/dev/null 2>&1 & reader=$!
sleep 0.5; kill "$reader" 2>/dev/null
if [ "$mode" = "group" ]; then kill -TERM -- "-$gen_pid" 2>/dev/null; else kill "$gen_pid" 2>/dev/null; fi
rm -f "$fifo"
SH
    # Bare kill of the pid: the fan-out survives and finishes.
    : > "$marker"
    bash "$TEST_TMPDIR/h.sh" "$marker" bare
    sleep 10
    [ "$(wc -l < "$marker")" -eq 4 ]

    # Group TERM: nothing survives to write.
    : > "$marker"
    bash "$TEST_TMPDIR/h.sh" "$marker" group
    sleep 10
    [ "$(wc -l < "$marker")" -eq 0 ]
    teardown_temp_dir
}

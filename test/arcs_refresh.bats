#!/usr/bin/env bats
# Tests for arcs-refresh. An unattended job's failures are all of the quiet kind, so these
# cover the paths where being wrong looks exactly like being right:
#
#   - standing down on quota, in both directions and at the boundary, because the account
#     has extra_usage enabled and 100% is where it starts charging rather than stopping
#   - failing closed when the quota cannot be read at all, which is the decision that
#     costs a stale page to avoid a bill
#   - a held lock skipping instead of racing, because two runs both move the run-over-run
#     snapshot baseline and the loser's interval of changes is gone
#   - a page that built fine with every model call failing -- exit 0, no arc names, and
#     nothing anywhere saying so, which is what actually happened when this was measured
#   - the crontab line being add-or-replace rather than append, including the case where
#     `crontab -l` exits 1 because there is no crontab yet
#   - silence on success, which is the only reason a notification means anything
#
# The stubs live in $HOME/bin, and $HOME is the temp dir: that is not a trick, it is the
# same PATH the script builds for itself, so the stubs are found the way cron would find
# the real ones.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir

    # Exactly what cron hands a job. Without this the suite inherits a login shell's PATH,
    # ~/.local/bin comes with it, and the one test that matters most -- the missing
    # `claude` -- passes for the wrong reason because the real one is still findable.
    export PATH=/usr/bin:/bin

    export HOME="$TEST_TMPDIR/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    STATE="$XDG_STATE_HOME/work-arcs"
    mkdir -p "$HOME/bin/notification" "$HOME/.claude" "$STATE"

    LOG="$STATE/refresh.log"
    LOCK="$STATE/refresh.lock"
    STATE_JSON="$STATE/refresh.json"

    # A copy rather than the real path, so the script's own .env is a fixture and Kyle's
    # is never sourced into a test.
    FAKE_REPO="$TEST_TMPDIR/repo"
    mkdir -p "$FAKE_REPO/bin"
    cp "$REPO_ROOT/bin/arcs-refresh" "$FAKE_REPO/bin/arcs-refresh"
    REFRESH="$FAKE_REPO/bin/arcs-refresh"
    echo 'WORK_ARCS_ARTIFACT_URL=https://example.invalid/artifact' >"$FAKE_REPO/.env"

    export NOTIFY_LOG="$TEST_TMPDIR/notify.log"
    export STUB_USAGE="$TEST_TMPDIR/usage.json"
    export STUB_HTTP_CODE=200
    export CRONTAB_FILE="$TEST_TMPDIR/crontab"

    cat >"$HOME/bin/notification/claude-notify.sh" <<'EOF'
#!/bin/sh
printf '%s :: %s\n' "$1" "$2" >>"$NOTIFY_LOG"
EOF

    # Only the -o path and the status code matter; everything else the real curl is handed
    # is header and timeout noise this never has to interpret.
    cat >"$HOME/bin/curl" <<'EOF'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
[ -n "$out" ] && cp "$STUB_USAGE" "$out"
printf '%s' "${STUB_HTTP_CODE:-200}"
EOF

    # Present only so preflight passes; nothing in these tests reaches a model.
    printf '#!/bin/sh\nexit 0\n' >"$HOME/bin/claude"

    cat >"$HOME/bin/crontab" <<'EOF'
#!/bin/sh
case "$1" in
    -l) [ -s "$CRONTAB_FILE" ] || exit 1; cat "$CRONTAB_FILE" ;;
    -)  cat >"$CRONTAB_FILE" ;;
    *)  exit 2 ;;
esac
EOF

    chmod +x "$HOME/bin/notification/claude-notify.sh" "$HOME/bin/curl" \
             "$HOME/bin/claude" "$HOME/bin/crontab"

    echo '{"claudeAiOauth":{"accessToken":"tok"}}' >"$HOME/.claude/.credentials.json"
    set_quota 20 30

    # The documented seam: the pipeline is a command name, so a test can hand it one that
    # finishes in a millisecond instead of forty seconds.
    export WORK_ARCS_REFRESH_CMD="$TEST_TMPDIR/pipeline"
    pipeline_ok
}

teardown() {
    teardown_temp_dir
}

# set_quota <five_hour> <seven_day>
set_quota() {
    printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":%s}}\n' \
        "$1" "$2" >"$STUB_USAGE"
}

make_pipeline() {
    printf '#!/bin/sh\n%s\n' "$1" >"$TEST_TMPDIR/pipeline"
    chmod +x "$TEST_TMPDIR/pipeline"
}

pipeline_ok() {
    make_pipeline 'echo "  page: built"; : >"$XDG_STATE_HOME/work-arcs/page.html"; exit 0'
}

ran_pipeline() { [ -f "$STATE/page.html" ]; }
notified()     { [ -s "$NOTIFY_LOG" ]; }

# --- the quota guard -----------------------------------------------------------------

@test "a 5-hour quota over the ceiling stands the run down" {
    set_quota 85 30
    WORK_ARCS_REFRESH_MAX_5H=80 run "$REFRESH"
    [ "$status" -eq 3 ]
    ! ran_pipeline
    grep -q "stood down: 5-hour quota at 85%" "$LOG"
}

@test "a 7-day quota over the ceiling stands the run down" {
    set_quota 10 95
    WORK_ARCS_REFRESH_MAX_7D=90 run "$REFRESH"
    [ "$status" -eq 3 ]
    ! ran_pipeline
    grep -q "stood down: 7-day quota at 95%" "$LOG"
}

# The ceiling is the last value that is still allowed, so 80 with a limit of 80 runs and
# 81 does not. Off by one here is a run skipped every day for no reason, or a run made on
# the day it should not have been.
@test "a quota exactly at the ceiling still runs" {
    set_quota 80 90
    WORK_ARCS_REFRESH_MAX_5H=80 WORK_ARCS_REFRESH_MAX_7D=90 run "$REFRESH"
    [ "$status" -eq 0 ]
    ran_pipeline
}

@test "standing down on quota is worth a notification" {
    set_quota 99 30
    run "$REFRESH"
    [ "$status" -eq 3 ]
    notified
    grep -q "skipped — 5-hour quota at 99%" "$NOTIFY_LOG"
}

@test "--force runs through a quota that would otherwise stand it down" {
    set_quota 99 99
    run "$REFRESH" --force
    [ "$status" -eq 0 ]
    ran_pipeline
    grep -q "running anyway (--force)" "$LOG"
}

# Fail closed. Not knowing the quota is not the same as knowing it is fine, and the cost
# of being wrong is asymmetric: a skipped morning costs a stale page that /arcs rebuilds,
# a run made blind can cost money.
@test "an unreadable quota stands the run down rather than guessing" {
    STUB_HTTP_CODE=401 run "$REFRESH"
    [ "$status" -eq 3 ]
    ! ran_pipeline
    grep -q "stood down: the usage endpoint could not be read" "$LOG"
}

@test "a usage response with no utilisation figures is also unknown" {
    echo '{"limits":[]}' >"$STUB_USAGE"
    run "$REFRESH"
    [ "$status" -eq 3 ]
    ! ran_pipeline
    grep -q "carried no utilisation figures" "$LOG"
}

@test "WORK_ARCS_REFRESH_ON_UNKNOWN=run overrides the fail-closed default" {
    STUB_HTTP_CODE=401
    WORK_ARCS_REFRESH_ON_UNKNOWN=run run "$REFRESH"
    [ "$status" -eq 0 ]
    ran_pipeline
    grep -q "quota unknown" "$LOG"
}

@test "--check-quota reports without running anything" {
    set_quota 41 52
    run "$REFRESH" --check-quota
    [ "$status" -eq 0 ]
    [[ "$output" == *"5h 41%"* ]]
    ! ran_pipeline
}

# --- the lock ------------------------------------------------------------------------

@test "a held lock is a skip, not a second run" {
    exec 8>"$LOCK"
    flock -n 8
    run "$REFRESH"
    exec 8>&-
    [ "$status" -eq 4 ]
    ! ran_pipeline
    grep -q "another arcs-refresh holds" "$LOG"
}

# An overlapping manual run is the system working, not a fault. Waking him up for it
# would make the notification mean nothing.
@test "a held lock does not notify" {
    exec 8>"$LOCK"
    flock -n 8
    run "$REFRESH"
    exec 8>&-
    [ "$status" -eq 4 ]
    ! notified
}

@test "the lock is released, so the next run proceeds" {
    run "$REFRESH"
    [ "$status" -eq 0 ]
    rm -f "$STATE/page.html"
    run "$REFRESH"
    [ "$status" -eq 0 ]
    ran_pipeline
}

# --- preflight -----------------------------------------------------------------------

# The measured failure: with cron's PATH, `claude` is not found, every model call raises
# FileNotFoundError, the page builds anonymous and the pipeline exits 0. Caught before the
# run rather than deduced from the wreckage.
@test "a missing claude is caught before the run, not after" {
    rm -f "$HOME/bin/claude"
    run "$REFRESH"
    [ "$status" -eq 5 ]
    ! ran_pipeline
    grep -q "preflight failed: not on PATH: claude" "$LOG"
    notified
}

@test "preflight records the PATH it searched" {
    rm -f "$HOME/bin/claude"
    run "$REFRESH"
    grep -q "    PATH=" "$LOG"
}

# --- what counts as a failed run -------------------------------------------------------

@test "a pipeline that exits non-zero is a failure" {
    make_pipeline 'echo "glab timed out"; exit 7'
    run "$REFRESH"
    [ "$status" -eq 1 ]
    grep -q "FAILED after .*(exit 7)" "$LOG"
    notified
}

# Exit 0 is not the same as a good page.
@test "a page built with no arc names is a failure even though the pipeline exited 0" {
    make_pipeline '
echo "  ! no brief for Zero-fill chart domains — could not run claude (FileNotFoundError)"
echo "  ! no brief for ulcli logs search — could not run claude (FileNotFoundError)"
: >"$XDG_STATE_HOME/work-arcs/page.html"
exit 0'
    run "$REFRESH"
    [ "$status" -eq 1 ]
    grep -q "2 model call(s) could not reach claude" "$LOG"
    grep -q "no arc names" "$NOTIFY_LOG"
}

@test "the pipeline's own output is in the log, stamped line by line" {
    make_pipeline 'echo "arc-brief: 169 cached, nothing to write"; exit 0'
    run "$REFRESH"
    grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}[+-][0-9]{4}  \| arc-brief: 169 cached' "$LOG"
}

# --- a good run ------------------------------------------------------------------------

# The whole point of the notification budget: a daily "it worked" is training to ignore
# the ones that matter.
@test "a successful run says nothing" {
    run "$REFRESH"
    [ "$status" -eq 0 ]
    ! notified
}

@test "a successful run leaves the publish line in the log" {
    run "$REFRESH"
    grep -q "publish .* to https://example.invalid/artifact" "$LOG"
    grep -q "upload-only" "$LOG"
}

@test "a successful run stamps the state file" {
    run "$REFRESH"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.built_at | type' "$STATE_JSON")" = "number" ]
    [ "$(jq -r '.five_hour' "$STATE_JSON")" = "20" ]
    [ "$(jq -r '.page' "$STATE_JSON")" = "$STATE/page.html" ]
}

# This script cannot publish -- only a Claude session can -- so whatever stamped
# published_at knows something a rebuild does not, and a rebuild must not erase it.
@test "a rebuild carries published_at through" {
    echo '{"published_at": 1700000000}' >"$STATE_JSON"
    run "$REFRESH"
    [ "$(jq -r '.published_at' "$STATE_JSON")" = "1700000000" ]
    [ "$(jq -r '.built_at | type' "$STATE_JSON")" = "number" ]
}

@test "the log is ring-trimmed to its ceiling" {
    seq 1 500 >"$LOG"
    WORK_ARCS_REFRESH_LOG_LINES=40 run "$REFRESH"
    [ "$status" -eq 0 ]
    [ "$(wc -l <"$LOG")" -eq 40 ]
    # The trim keeps the tail, so this run's own lines survive it.
    grep -q "refreshed in" "$LOG"
}

# --- the crontab line ---------------------------------------------------------------------

@test "--install-cron writes one line at the time asked for" {
    run "$REFRESH" --install-cron 06:30
    [ "$status" -eq 0 ]
    [ "$(grep -c 'work-arcs-refresh' "$CRONTAB_FILE")" -eq 1 ]
    grep -q "^30 6 \* \* \* $REFRESH >/dev/null 2>&1  # work-arcs-refresh$" "$CRONTAB_FILE"
}

@test "--install-cron defaults to 07:10" {
    run "$REFRESH" --install-cron
    grep -q "^10 7 \* \* \* " "$CRONTAB_FILE"
}

# `crontab -l` exits 1 when there is no crontab at all, and treating that as an error is
# how an installer ends up refusing to install the very first entry.
@test "--install-cron works when there is no crontab yet" {
    [ ! -f "$CRONTAB_FILE" ]
    run "$REFRESH" --install-cron
    [ "$status" -eq 0 ]
    [ "$(grep -c 'work-arcs-refresh' "$CRONTAB_FILE")" -eq 1 ]
}

@test "installing twice replaces rather than duplicates" {
    run "$REFRESH" --install-cron 06:30
    run "$REFRESH" --install-cron 08:45
    [ "$status" -eq 0 ]
    [ "$(grep -c 'work-arcs-refresh' "$CRONTAB_FILE")" -eq 1 ]
    grep -q "^45 8 " "$CRONTAB_FILE"
    ! grep -q "^30 6 " "$CRONTAB_FILE"
}

@test "--install-cron keeps every other crontab line" {
    printf '%s\n' '@reboot /usr/bin/true' '0 3 * * * /usr/bin/backup' >"$CRONTAB_FILE"
    run "$REFRESH" --install-cron
    [ "$status" -eq 0 ]
    grep -q '@reboot /usr/bin/true' "$CRONTAB_FILE"
    grep -q '0 3 \* \* \* /usr/bin/backup' "$CRONTAB_FILE"
    [ "$(grep -c 'work-arcs-refresh' "$CRONTAB_FILE")" -eq 1 ]
}

@test "--uninstall-cron removes its own line and no other" {
    printf '%s\n' '0 3 * * * /usr/bin/backup' >"$CRONTAB_FILE"
    run "$REFRESH" --install-cron
    run "$REFRESH" --uninstall-cron
    [ "$status" -eq 0 ]
    ! grep -q 'work-arcs-refresh' "$CRONTAB_FILE"
    grep -q '/usr/bin/backup' "$CRONTAB_FILE"
}

@test "--uninstall-cron on a crontab of only our line leaves it empty" {
    run "$REFRESH" --install-cron
    run "$REFRESH" --uninstall-cron
    [ "$status" -eq 0 ]
    ! grep -q 'work-arcs-refresh' "$CRONTAB_FILE"
}

@test "--install-cron rejects a time that is not a time" {
    run "$REFRESH" --install-cron 25:00
    [ "$status" -eq 2 ]
    run "$REFRESH" --install-cron breakfast
    [ "$status" -eq 2 ]
    [ ! -f "$CRONTAB_FILE" ]
}

# A minute written 06:05 must not be read as octal 5 and rejected, nor as 65.
@test "--install-cron reads a leading-zero time as decimal" {
    run "$REFRESH" --install-cron 08:09
    [ "$status" -eq 0 ]
    grep -q "^9 8 " "$CRONTAB_FILE"
}

@test "the cron line silences cron's own mail" {
    run "$REFRESH" --install-cron
    grep -q '>/dev/null 2>&1' "$CRONTAB_FILE"
}

# --- the hook that is deliberately not installed ---------------------------------------

@test "--hook prints a settings.json block that merges with the existing Stop hook" {
    run "$REFRESH" --hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-stop-hook.sh"* ]]
    [[ "$output" == *"bin/arc-record"* ]]
    [[ "$output" == *"NOT installed"* ]]
}

@test "a run points at --hook while the hook is missing, and stops once it is there" {
    run "$REFRESH"
    grep -q "arc-record Stop hook is not installed" "$LOG"

    mkdir -p "$HOME/.claude"
    echo '{"hooks":{"Stop":[{"hooks":[{"command":"~/bin/dev-workflow-tools/bin/arc-record"}]}]}}' \
        >"$HOME/.claude/settings.json"
    : >"$LOG"
    rm -f "$STATE/page.html"
    run "$REFRESH"
    [ "$status" -eq 0 ]
    ! grep -q "arc-record Stop hook is not installed" "$LOG"
}

@test "an unknown argument is refused rather than ignored" {
    run "$REFRESH" --publish
    [ "$status" -eq 2 ]
    ! ran_pipeline
}

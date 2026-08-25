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
#   - an access token that expired overnight buying exactly one refresh, and a timeout or
#     a 500 buying none, because a refresh spent on a slow network writes "your login is
#     broken" in the log on a morning nothing was wrong with the login
#   - the refreshed token never reaching the credentials file, which a Claude Code session
#     owns and rewrites unlocked -- a lost race there is a broken login, not a stale page
#   - Persistent=true on the shipped timer, which is the single property the crontab line
#     lacked and the entire reason for replacing it
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
    cp -r "$REPO_ROOT/systemd" "$FAKE_REPO/systemd"
    REFRESH="$FAKE_REPO/bin/arcs-refresh"
    echo 'WORK_ARCS_ARTIFACT_URL=https://example.invalid/artifact' >"$FAKE_REPO/.env"

    export NOTIFY_LOG="$TEST_TMPDIR/notify.log"
    export STUB_DIR="$TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    export STUB_USAGE="$TEST_TMPDIR/usage.json"
    export STUB_TOKEN_RESP="$TEST_TMPDIR/token-response.json"
    # Exported here so a test can override them with a bare assignment, which is how the
    # rest of this file already reads.
    export STUB_USAGE_CODES=200
    export STUB_TOKEN_CODE=200
    export CRONTAB_FILE="$TEST_TMPDIR/crontab"
    export SYSTEMCTL_LOG="$TEST_TMPDIR/systemctl.log"

    cat >"$HOME/bin/notification/claude-notify.sh" <<'EOF'
#!/bin/sh
printf '%s :: %s\n' "$1" "$2" >>"$NOTIFY_LOG"
EOF

    # Enough of curl to be the two endpoints arcs-refresh talks to, told apart by the URL.
    # /usage answers the next code in $STUB_USAGE_CODES each time it is called, the last
    # one repeating -- so "401 200", the actual shape of a 07:10 morning, is a fixture and
    # not a special case. Every call is appended to $STUB_DIR/calls with the bearer token
    # it carried, which is how a test can tell the retry used the fresh token.
    cat >"$HOME/bin/curl" <<'EOF'
#!/bin/sh
out=""; url=""; data=""; auth=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -H) case "$2" in Authorization:*) auth="$2" ;; esac; shift 2 ;;
        --data) data="${2#@}"; shift 2 ;;
        -w|-m) shift 2 ;;
        -*) shift ;;
        *)  url="$1"; shift ;;
    esac
done
case "$url" in
*/oauth/token*)
    [ -n "$data" ] && cp "$data" "$STUB_DIR/token-request.json"
    echo "token" >>"$STUB_DIR/calls"
    [ -n "$out" ] && cp "$STUB_TOKEN_RESP" "$out"
    printf '%s' "${STUB_TOKEN_CODE:-200}"
    ;;
*)
    echo "usage $auth" >>"$STUB_DIR/calls"
    n=$(grep -c '^usage' "$STUB_DIR/calls")
    code=$(echo "${STUB_USAGE_CODES:-200}" | awk -v n="$n" '{print (n <= NF) ? $n : $NF}')
    [ -n "$out" ] && cp "$STUB_USAGE" "$out"
    printf '%s' "$code"
    ;;
esac
EOF

    # `systemctl --user` on a machine with no user manager exits non-zero rather than
    # missing, so the stub answers show-environment and $SYSTEMCTL_ABSENT is how a test
    # gets the machine that has no bus to talk to.
    cat >"$HOME/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
case "$*" in
    "--user show-environment") [ -z "${SYSTEMCTL_ABSENT:-}" ] || exit 1 ;;
esac
exit 0
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
             "$HOME/bin/claude" "$HOME/bin/crontab" "$HOME/bin/systemctl"

    # The full credential shape, because the refresh request is built out of three of its
    # fields and a fixture with only the access token is the "nothing to refresh with" case.
    export WORK_ARCS_CREDS="$TEST_TMPDIR/credentials.json"
    write_creds
    set_quota 20 30

    printf '{"access_token":"fresh-token","expires_in":3600}\n' >"$STUB_TOKEN_RESP"

    # The retry on an unreachable endpoint is three tries ten seconds apart in real life,
    # which is right for a morning after a wake and wrong for a test suite.
    export WORK_ARCS_REFRESH_NET_DELAY=0

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

# The shape Claude Code actually keeps, minus the token values. write_creds --no-refresh
# is the case where there is nothing to refresh with, which must not reach the network.
write_creds() {
    local refresh='"refreshToken": "stored-refresh",'
    [ "${1:-}" = "--no-refresh" ] && refresh=''
    cat >"$WORK_ARCS_CREDS" <<EOF
{"claudeAiOauth": {"accessToken": "stale-token", $refresh
  "scopes": ["user:inference", "user:profile"]}}
EOF
}

# `grep -c` prints 0 and exits 1 when it matches nothing, so the count and the status
# disagree; swallowing the status is the whole point of the || true.
count_calls() {
    local n=0
    if [ -f "$STUB_DIR/calls" ]; then
        n="$(grep -c "^$1" "$STUB_DIR/calls" || true)"
    fi
    printf '%s' "${n:-0}"
}
usage_calls()  { count_calls usage; }
token_calls()  { count_calls token; }
nth_usage_auth() { grep '^usage' "$STUB_DIR/calls" | sed -n "$1p"; }

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
# Fail closed, still. The 401 path now tries a refresh first (see the block below), so
# the endpoint that refuses everything is what this asserts on.
@test "an unreadable quota stands the run down rather than guessing" {
    STUB_USAGE_CODES=500 run "$REFRESH"
    [ "$status" -eq 3 ]
    ! ran_pipeline
    grep -q "stood down: the usage endpoint could not be read (HTTP 500)" "$LOG"
}

@test "a usage response with no utilisation figures is also unknown" {
    echo '{"limits":[]}' >"$STUB_USAGE"
    run "$REFRESH"
    [ "$status" -eq 3 ]
    ! ran_pipeline
    grep -q "carried no utilisation figures" "$LOG"
}

@test "WORK_ARCS_REFRESH_ON_UNKNOWN=run overrides the fail-closed default" {
    STUB_USAGE_CODES=500
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

# --- the expired access token ----------------------------------------------------------
#
# THE BUG THIS SECTION EXISTS FOR. At 07:10 nobody has run a Claude session since the
# evening before, so the access token in the credentials file is stale, /usage answers 401,
# and the fail-closed guard above stands the run down -- correctly, and for eight days.
# What follows is the decision table for the one retry that fixes it, and the three log
# sentences the retry has to be able to tell apart. The middle one is the one that was
# missing: "could not be read" reads like a network fault whichever thing broke.

@test "a 401 buys one token refresh and the run goes ahead" {
    STUB_USAGE_CODES="401 200" run "$REFRESH"
    [ "$status" -eq 0 ]
    ran_pipeline
    [ "$(token_calls)" -eq 1 ]
    grep -q "quota ok after refreshing the access token: 5h 20%" "$LOG"
}

# A run that had to mint a token is not a run worth waking anybody for; it is the feature
# working. The notification budget is the whole reason a notification means anything.
@test "refreshing the token on the way past is not worth a notification" {
    STUB_USAGE_CODES="401 200" run "$REFRESH"
    [ "$status" -eq 0 ]
    ! notified
}

# The retry has to actually carry the new token. Sending the stale one again would 401
# again and land in the "still 401 after a refresh" branch, which looks like a server
# problem and would have been a very quiet way to get this wrong.
@test "the retry carries the refreshed token and not the stale one" {
    STUB_USAGE_CODES="401 200" run "$REFRESH"
    [ "$status" -eq 0 ]
    [ "$(usage_calls)" -eq 2 ]
    [[ "$(nth_usage_auth 1)" == *"Bearer stale-token"* ]]
    [[ "$(nth_usage_auth 2)" == *"Bearer fresh-token"* ]]
}

# The request is the refresh_token half of the flow Claude Code itself uses, read out of
# the CLI rather than guessed. If any of these four fields drifts, the endpoint answers
# 400 and the log says the login is broken when it is not.
@test "the refresh request is the flow the CLI uses" {
    STUB_USAGE_CODES="401 200" run "$REFRESH"
    [ "$status" -eq 0 ]
    local req="$STUB_DIR/token-request.json"
    [ "$(jq -r '.grant_type' "$req")" = "refresh_token" ]
    [ "$(jq -r '.refresh_token' "$req")" = "stored-refresh" ]
    [ "$(jq -r '.client_id' "$req")" = "9d1c250a-e61b-44d9-88ed-5944d1962f5e" ]
    [ "$(jq -r '.scope' "$req")" = "user:inference user:profile" ]
}

# THE LOAD-BEARING ONE. ~/.claude/.credentials.json belongs to whichever Claude Code
# session is running and it rewrites the whole file with no lock; a second writer turns a
# lost race into a truncated credential file, which is a broken login rather than a stale
# page. The refreshed token lives in a variable and dies there.
@test "the refreshed token is never written back to the credentials file" {
    local before after
    before="$(cat "$WORK_ARCS_CREDS")"
    STUB_USAGE_CODES="401 200" run "$REFRESH"
    [ "$status" -eq 0 ]
    after="$(cat "$WORK_ARCS_CREDS")"
    [ "$before" = "$after" ]
}

# A timeout says something about the network and nothing about the token. Spending a
# refresh on one would write "your login is broken" in the log on a morning the wifi was
# merely slow -- and it is the wake-from-sleep morning that is most likely to be slow.
@test "an unreachable endpoint does not spend a refresh" {
    STUB_USAGE_CODES="000 000 000" run "$REFRESH"
    [ "$status" -eq 3 ]
    ! ran_pipeline
    [ "$(token_calls)" -eq 0 ]
    grep -q "stood down: the usage endpoint could not be read (HTTP 000)" "$LOG"
}

@test "a 500 does not spend a refresh either" {
    STUB_USAGE_CODES=500 run "$REFRESH"
    [ "$status" -eq 3 ]
    [ "$(token_calls)" -eq 0 ]
    grep -q "could not be read (HTTP 500)" "$LOG"
}

# The timer fires on the next wake, which is while wifi is still associating, so the first
# read comes back with no HTTP status at all and the second one works. Retried rather than
# stood down, because a run that happens without a network is the same missing page as a
# run that never happened.
@test "a network that arrives late is waited for rather than stood down" {
    STUB_USAGE_CODES="000 200" run "$REFRESH"
    [ "$status" -eq 0 ]
    ran_pipeline
    [ "$(token_calls)" -eq 0 ]
    grep -q "unreachable (try 1 of 3) — waiting 0s for the network" "$LOG"
}

@test "the wait for the network is bounded" {
    STUB_USAGE_CODES="000 000 000 000 200" WORK_ARCS_REFRESH_NET_TRIES=2 run "$REFRESH"
    [ "$status" -eq 3 ]
    [ "$(usage_calls)" -eq 2 ]
}

# Outcome three of three, and it must not read like outcome one. A refused refresh is a
# login that needs a person, and the log line has to say so or the next reader goes
# looking at the network again.
@test "a refused refresh says the token expired, not that the endpoint was unreadable" {
    STUB_USAGE_CODES=401 STUB_TOKEN_CODE=400 run "$REFRESH"
    [ "$status" -eq 3 ]
    ! ran_pipeline
    grep -q "the access token is expired and refreshing it was refused (token endpoint HTTP 400)" "$LOG"
    grep -q "run any claude session to refresh it" "$LOG"
    ! grep -q "the usage endpoint could not be read" "$LOG"
}

@test "a token response with no access token in it is a refused refresh" {
    echo '{"error":"invalid_grant"}' >"$STUB_TOKEN_RESP"
    STUB_USAGE_CODES=401 run "$REFRESH"
    [ "$status" -eq 3 ]
    grep -q "refreshing it was refused" "$LOG"
}

# Nothing to refresh with is not a network round trip, and must not be reported as one.
@test "a credentials file with no refresh token does not reach the token endpoint" {
    write_creds --no-refresh
    STUB_USAGE_CODES=401 run "$REFRESH"
    [ "$status" -eq 3 ]
    [ "$(token_calls)" -eq 0 ]
    grep -q "(token endpoint HTTP none)" "$LOG"
}

# A 401 that survives a fresh token is the endpoint's problem, not the credential's, and
# gets a fourth sentence of its own so nobody spends a morning re-logging in.
@test "a 401 that survives the refresh is its own sentence" {
    STUB_USAGE_CODES="401 401 401" run "$REFRESH"
    [ "$status" -eq 3 ]
    [ "$(token_calls)" -eq 1 ]
    grep -q "still answered HTTP 401 with a freshly refreshed access token" "$LOG"
}

@test "a credentials file that is not there at all is named in the log" {
    rm -f "$WORK_ARCS_CREDS"
    run "$REFRESH"
    [ "$status" -eq 3 ]
    [ "$(usage_calls)" -eq 0 ]
    grep -q "no access token in $WORK_ARCS_CREDS" "$LOG"
}

# The quota still wins over a working refresh: minting a token says nothing about whether
# there is room to spend it.
@test "a refreshed token still stands down on an over-ceiling quota" {
    set_quota 99 30
    STUB_USAGE_CODES="401 200" run "$REFRESH"
    [ "$status" -eq 3 ]
    ! ran_pipeline
    [ "$(token_calls)" -eq 1 ]
    grep -q "stood down: 5-hour quota at 99%" "$LOG"
}

@test "--check-quota says when it had to refresh to answer" {
    STUB_USAGE_CODES="401 200" run "$REFRESH" --check-quota
    [ "$status" -eq 0 ]
    [[ "$output" == *"after refreshing the access token"* ]]
}

# --- the systemd user timer --------------------------------------------------------------
#
# The other half of the same eight days: `10 7 * * *` does not fire on a sleeping laptop
# and cron keeps no memory of a run it owes, so three days of closed lid produced no line
# in the log at all. Persistent=true is the only property that changes, and it is the
# reason for the whole move -- so it is asserted on the shipped file, not just the flag.

@test "the shipped timer catches up after a missed run" {
    grep -q "^Persistent=true$" "$REPO_ROOT/systemd/work-arcs-refresh.timer"
    grep -q "^OnCalendar=07:10$" "$REPO_ROOT/systemd/work-arcs-refresh.timer"
    grep -q "^WantedBy=timers.target$" "$REPO_ROOT/systemd/work-arcs-refresh.timer"
}

# Waking a laptop in a bag at 07:10 to rebuild a page nobody is looking at yet is worse
# than rebuilding it when the lid opens.
@test "the shipped timer does not wake the machine to do it" {
    ! grep -q "^WakeSystem" "$REPO_ROOT/systemd/work-arcs-refresh.timer"
}

# 90 seconds is the default and the pipeline is four to nine minutes, so without this the
# unit kills its own run mid-flight, holding the lock, with the baseline already moved.
@test "the shipped service allows the pipeline time to finish" {
    grep -q "^TimeoutStartSec=45min$" "$REPO_ROOT/systemd/work-arcs-refresh.service"
}

# Stood down on quota and a held lock are the design working; a unit left in `failed` for
# either would train `systemctl --user status` to be ignored.
@test "the shipped service does not call a quota skip a failure" {
    grep -q "^SuccessExitStatus=3 4$" "$REPO_ROOT/systemd/work-arcs-refresh.service"
}

@test "--install-timer writes both units and enables the timer" {
    run "$REFRESH" --install-timer
    [ "$status" -eq 0 ]
    [ -f "$HOME/.config/systemd/user/work-arcs-refresh.timer" ]
    [ -f "$HOME/.config/systemd/user/work-arcs-refresh.service" ]
    grep -q "daemon-reload" "$SYSTEMCTL_LOG"
    grep -q -- "--user enable --now work-arcs-refresh.timer" "$SYSTEMCTL_LOG"
}

# ExecStart has to point at the checkout it was installed from, not at whatever path the
# shipped file happens to name -- that is the difference between a unit file and a
# template, and getting it wrong runs somebody else's copy of the pipeline.
@test "--install-timer points ExecStart at the checkout it was run from" {
    run "$REFRESH" --install-timer
    grep -q "^ExecStart=$REFRESH$" "$HOME/.config/systemd/user/work-arcs-refresh.service"
}

@test "--install-timer writes the time it was asked for" {
    run "$REFRESH" --install-timer 06:30
    [ "$status" -eq 0 ]
    grep -q "^OnCalendar=06:30$" "$HOME/.config/systemd/user/work-arcs-refresh.timer"
    grep -q "^Persistent=true$" "$HOME/.config/systemd/user/work-arcs-refresh.timer"
}

@test "--install-timer defaults to 07:10" {
    run "$REFRESH" --install-timer
    grep -q "^OnCalendar=07:10$" "$HOME/.config/systemd/user/work-arcs-refresh.timer"
}

# Two schedulers for one job is a race dressed up as redundancy: the lock would make it a
# coin toss over which run's snapshot baseline survives.
@test "--install-timer removes the crontab line it replaces" {
    run "$REFRESH" --install-cron
    grep -q 'work-arcs-refresh' "$CRONTAB_FILE"
    run "$REFRESH" --install-timer
    [ "$status" -eq 0 ]
    ! grep -q 'work-arcs-refresh' "$CRONTAB_FILE"
    [[ "$output" == *"the timer owns the schedule now"* ]]
}

@test "--install-timer keeps every other crontab line while it does that" {
    printf '%s\n' '0 3 * * * /usr/bin/backup' >"$CRONTAB_FILE"
    run "$REFRESH" --install-cron
    run "$REFRESH" --install-timer
    [ "$status" -eq 0 ]
    grep -q '/usr/bin/backup' "$CRONTAB_FILE"
}

@test "--install-timer says nothing about cron when there was no cron line" {
    run "$REFRESH" --install-timer
    [ "$status" -eq 0 ]
    [[ "$output" != *"the timer owns the schedule now"* ]]
}

@test "--install-timer rejects a time that is not a time" {
    run "$REFRESH" --install-timer 25:00
    [ "$status" -eq 2 ]
    run "$REFRESH" --install-timer breakfast
    [ "$status" -eq 2 ]
    [ ! -f "$HOME/.config/systemd/user/work-arcs-refresh.timer" ]
}

@test "--install-timer reads a leading-zero time as decimal" {
    run "$REFRESH" --install-timer 08:09
    [ "$status" -eq 0 ]
    grep -q "^OnCalendar=08:09$" "$HOME/.config/systemd/user/work-arcs-refresh.timer"
}

# systemctl exists on machines with no user manager answering it, so "is the binary there"
# is the wrong question and would install a timer that never fires.
@test "--install-timer points at the cron fallback where there is no user manager" {
    SYSTEMCTL_ABSENT=1 run "$REFRESH" --install-timer
    [ "$status" -eq 2 ]
    [[ "$output" == *"--install-cron"* ]]
    [ ! -f "$HOME/.config/systemd/user/work-arcs-refresh.timer" ]
}

@test "--uninstall-timer disables the timer and removes both units" {
    run "$REFRESH" --install-timer
    : >"$SYSTEMCTL_LOG"
    run "$REFRESH" --uninstall-timer
    [ "$status" -eq 0 ]
    [ ! -f "$HOME/.config/systemd/user/work-arcs-refresh.timer" ]
    [ ! -f "$HOME/.config/systemd/user/work-arcs-refresh.service" ]
    grep -q -- "--user disable --now work-arcs-refresh.timer" "$SYSTEMCTL_LOG"
}

@test "--uninstall-timer on a machine that never had one is not an error" {
    run "$REFRESH" --uninstall-timer
    [ "$status" -eq 0 ]
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

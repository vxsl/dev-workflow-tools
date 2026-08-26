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
    cp -r "$REPO_ROOT/lib" "$FAKE_REPO/lib"
    REFRESH="$FAKE_REPO/bin/arcs-refresh"
    # A real-shaped artifact link, because the slug is parsed out of it and a publish with
    # no slug is the one failure that is silent and permanent -- it makes a second
    # artifact instead of updating this one.
    export STUB_SLUG="11111111-2222-3333-4444-555555555555"
    export ARTIFACT_URL="https://claude.ai/code/artifact/$STUB_SLUG"
    echo "WORK_ARCS_ARTIFACT_URL=$ARTIFACT_URL" >"$FAKE_REPO/.env"

    export NOTIFY_LOG="$TEST_TMPDIR/notify.log"
    export STUB_DIR="$TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    export STUB_USAGE="$TEST_TMPDIR/usage.json"
    export STUB_TOKEN_RESP="$TEST_TMPDIR/token-response.json"
    export STUB_FRAMES="$TEST_TMPDIR/frames.json"
    # The published page as the read-back sees it, and what the artifact says it may do.
    # Both default to the quiet answer -- a page whose seed holds nothing new -- so the
    # many tests that are not about the read-back are not about it.
    export STUB_PAGE="$TEST_TMPDIR/published.html"
    export STUB_BOOT="$TEST_TMPDIR/boot.json"
    export STUB_CAPS="$TEST_TMPDIR/caps.json"
    # As the content host serves it: the runtime's preamble, then the stored bytes. What
    # is stored is the page's own markup with no document around it, so there is no
    # doctype here and there never was one -- a fixture with one would let a doctype test
    # pass that the real service would fail.
    printf '<!-- frame-runtime --><head></head><!-- /frame-runtime --><title>Work Arcs</title><script type="application/json" id="ackseed">%s</script>\n' \
        '{"dismissed":{},"answers":[],"undismissed":[]}' >"$STUB_PAGE"
    echo '{"ver":"1787706300-d2fa","assetToken":"tok.1.2.3","title":"Work Arcs"}' >"$STUB_BOOT"
    echo '{"contract":"0.2.23","capabilities":{"artifact":{},"downloads":{}}}' >"$STUB_CAPS"
    # Exported here so a test can override them with a bare assignment, which is how the
    # rest of this file already reads.
    export STUB_USAGE_CODES=200
    export STUB_TOKEN_CODE=200
    export STUB_FRAMES_CODE=200
    export STUB_PAGE_CODE=200
    export STUB_BOOT_CODE=200
    export STUB_CAPS_CODE=200
    export STUB_DEPLOY_CODES=200
    export STUB_DEPLOY_MSG=refused
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
out=""; url=""; data=""; auth=""; hdrs=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        # -X takes a value. Without this case it fell through to the catch-all -*, which
        # dropped the flag and left "POST" to be read as the URL -- so every frame call
        # would have been answered by the /usage branch.
        -X) shift 2 ;;
        -H) hdrs="$hdrs$2
"; case "$2" in Authorization:*) auth="$2" ;; esac; shift 2 ;;
        --data|--data-binary) data="${2#@}"; shift 2 ;;
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
*/api/frame/frames*)
    echo "frames $auth" >>"$STUB_DIR/calls"
    printf '%s' "$hdrs" >"$STUB_DIR/frames-headers"
    [ -n "$out" ] && cp "$STUB_FRAMES" "$out"
    printf '%s' "${STUB_FRAMES_CODE:-200}"
    ;;
*/api/frame/deploy/direct*)
    # `grep -c` prints 0 AND exits 1 when it matches nothing, so a `|| echo 0` here would
    # append a second zero and the arithmetic below would be a fatal syntax error -- which
    # arrives at the caller as a bare HTTP 000, the same shape as an unreachable host.
    n=$(grep -c '^deploy' "$STUB_DIR/calls" 2>/dev/null)
    n=$(( ${n:-0} + 1 ))
    echo "deploy $auth" >>"$STUB_DIR/calls"
    printf '%s' "$hdrs" >"$STUB_DIR/deploy-headers"
    # Every attempt kept separately: the supersede path sends a second, different body,
    # and a test that can only see the last one cannot tell it apart from a first try.
    [ -n "$data" ] && cp "$data" "$STUB_DIR/deploy-request-$n.json"
    code=$(echo "${STUB_DEPLOY_CODES:-200}" | awk -v n="$n" '{print (n <= NF) ? $n : $NF}')
    if [ -n "$out" ]; then
        if [ "$code" = "200" ]; then
            printf '{"slug":"%s","version":"v-new","title":"Work Arcs"}' \
                "${STUB_SLUG:-}" >"$out"
        else
            printf '{"error":{"type":"invalid_request_error","message":"%s"}}' \
                "${STUB_DEPLOY_MSG:-refused}" >"$out"
        fi
    fi
    printf '%s' "$code"
    ;;
*/api/frame/read/*)
    echo "capread $auth" >>"$STUB_DIR/calls"
    [ -n "$out" ] && cp "$STUB_CAPS" "$out"
    printf '%s' "${STUB_CAPS_CODE:-200}"
    ;;
# Reading the page takes two calls to two hosts, which is not an implementation detail
# worth hiding here: the boot response says which version is live and hands out a
# short-lived token, and the page itself is on the content host with that token in the
# query string. A stub that answered the page from the boot route would pass a test the
# real service fails.
*/api/frame/*)
    echo "bootread $auth" >>"$STUB_DIR/calls"
    [ -n "$out" ] && cp "$STUB_BOOT" "$out"
    printf '%s' "${STUB_BOOT_CODE:-200}"
    ;;
*claudeusercontent.com*|*/_f/*)
    echo "pageread $url" >>"$STUB_DIR/calls"
    [ -n "$out" ] && cp "$STUB_PAGE" "$out"
    printf '%s' "${STUB_PAGE_CODE:-200}"
    ;;
*)
    echo "usage $auth" >>"$STUB_DIR/calls"
    n=$(grep -c '^usage' "$STUB_DIR/calls")
    code=$(echo "${STUB_USAGE_CODES:-200}" | awk -v n="$n" '{print (n <= NF) ? $n : $NF}')
    [ -n "$out" ] && cp "$STUB_USAGE" "$out"
    printf '%s' "$code"
    # Real curl prints 000 from -w AND exits non-zero when it never reached the host, so a
    # caller that appends its own 000 on failure ends up comparing against "000000". The
    # stub has to do both or the retry-on-unreachable path is tested against a fiction.
    if [ "$code" = "000" ]; then exit 7; fi
    ;;
esac
exit 0
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

    # Present so preflight passes, and -- since the session fallback shells out to it --
    # recording where and how it was invoked, because running it in the wrong cwd puts a
    # transcript in the corpus work-arcs reads back as work Kyle did.
    cat >"$HOME/bin/claude" <<'EOF'
#!/bin/sh
{
  printf 'cwd=%s\n' "$PWD"
  printf 'quiet=%s\n' "${CLAUDE_NOTIFY_QUIET:-unset}"
  printf 'args=%s\n' "$*"
} >>"$STUB_DIR/claude-calls"
[ -n "${STUB_CLAUDE_REFRESHES:-}" ] && cat >"$WORK_ARCS_CREDS" <<CREDS
{"claudeAiOauth": {"accessToken": "session-token", "refreshToken": "stored-refresh",
  "scopes": ["user:inference", "user:profile"]}}
CREDS
exit "${STUB_CLAUDE_EXIT:-0}"
EOF

    cat >"$HOME/bin/crontab" <<'EOF'
#!/bin/sh
case "$1" in
    -l) [ -s "$CRONTAB_FILE" ] || exit 1; cat "$CRONTAB_FILE" ;;
    -)  cat >"$CRONTAB_FILE" ;;
    *)  exit 2 ;;
esac
EOF

    # The one thing arcs-refresh shells to that is not the pipeline. A stub, because what
    # is under test here is the moving of bytes -- which seed reached which writer, and
    # what the log said when one did not -- and never what a dismissal means. That belongs
    # to work-arcs and to work-arcs' own tests.
    cat >"$HOME/bin/work-arcs" <<'EOF'
#!/bin/sh
echo "work-arcs $*" >>"$STUB_DIR/calls"
[ "$1" = "--ingest-acks" ] && cp "$2" "$STUB_DIR/seed.json"
[ -n "${STUB_INGEST_MSG:-}" ] && echo "$STUB_INGEST_MSG" >&2
exit "${STUB_INGEST_EXIT:-0}"
EOF

    chmod +x "$HOME/bin/notification/claude-notify.sh" "$HOME/bin/curl" \
             "$HOME/bin/claude" "$HOME/bin/crontab" "$HOME/bin/systemctl" \
             "$HOME/bin/work-arcs"

    # Off unless a test asks for it, so the many tests that never reach a 401 do not
    # quietly depend on a session being able to rescue them.
    export STUB_CLAUDE_REFRESHES=""
    export STUB_CLAUDE_EXIT=0

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

    # Publishing is off for the suite at large and turned on by the tests that are about
    # it. Most tests here are about the quota guard and the lock, and a network write at
    # the end of every one of them would be a second subject they never asked to test.
    export WORK_ARCS_PUBLISH=0
    # No real backoff: the retry is worth proving, the fifteen seconds are not.
    export WORK_ARCS_PUBLISH_RETRY_BASE=0
    frames_ok
}

# What the artifact API says the artifact currently is. The title and favicon matter
# because deploy requires both and the script is supposed to echo back what is already
# there rather than invent them; the version matters because it becomes baseVersion.
frames_ok() {
    cat >"$STUB_FRAMES" <<EOF
{"frames": [
  {"slug": "$STUB_SLUG", "title": "Work Arcs", "favicon": "🧭",
   "description": "Work Arcs", "version": "v-old"},
  {"slug": "99999999-9999-9999-9999-999999999999", "title": "Something Else",
   "favicon": "📎", "version": "v-other"}
]}
EOF
}

# A page with bytes in it. pipeline_ok writes an empty one, which is fine for the tests
# that only care that the pipeline ran and wrong for every test about publishing: an
# empty page is refused before it reaches the network.
pipeline_with_page() {
    make_pipeline 'echo "  page: built"; printf "<h1>arcs</h1>" >"$XDG_STATE_HOME/work-arcs/page.html"; exit 0'
}

publishing_on() {
    export WORK_ARCS_PUBLISH=1
    pipeline_with_page
}

deploy_calls() { count_calls deploy; }
deploy_request() { cat "$STUB_DIR/deploy-request-${1:-1}.json"; }

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

@test "with publishing off the run still says how to publish by hand" {
    run "$REFRESH"
    grep -q "publish: off (WORK_ARCS_PUBLISH=0)" "$LOG"
    grep -q "publish .* to $ARTIFACT_URL" "$LOG"
    [ "$(deploy_calls)" = 0 ]
}

@test "a successful run stamps the state file" {
    run "$REFRESH"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.built_at | type' "$STATE_JSON")" = "number" ]
    [ "$(jq -r '.five_hour' "$STATE_JSON")" = "20" ]
    [ "$(jq -r '.page' "$STATE_JSON")" = "$STATE/page.html" ]
}

# write_state does not own published_at -- stamp_published does, and it runs after. So a
# rebuild that does not publish must leave the last publish's stamp standing rather than
# erasing it or claiming this build was the published one.
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
    grep -q "quota ok after minting a fresh access token: 5h 20%" "$LOG"
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
# With the fallback switched off, a refused mint is the end of it -- and must not read like
# a network fault, which is the sentence that hid this for eight days.
@test "a refused mint says the token expired, not that the endpoint was unreadable" {
    STUB_USAGE_CODES=401 STUB_TOKEN_CODE=400 WORK_ARCS_REFRESH_SESSION_FALLBACK=0 \
        run "$REFRESH"
    [ "$status" -eq 3 ]
    ! ran_pipeline
    grep -q "the access token is expired and refreshing it was refused (token endpoint HTTP 400" "$LOG"
    grep -q "run any claude session to refresh it" "$LOG"
    ! grep -q "the usage endpoint could not be read" "$LOG"
}

@test "a token response with no access token in it is a refused mint" {
    echo '{"error":"invalid_grant"}' >"$STUB_TOKEN_RESP"
    STUB_USAGE_CODES=401 WORK_ARCS_REFRESH_SESSION_FALLBACK=0 run "$REFRESH"
    [ "$status" -eq 3 ]
    grep -q "refreshing it was refused" "$LOG"
}

# --- the session fallback --------------------------------------------------------------
#
# Minting a token directly has never been observed to work from this machine -- the token
# endpoint answers 429 to this client while Claude Code's own refresh, three minutes apart,
# succeeded. What has been observed working is a live session refreshing the credential,
# which is why the same quota check passed by hand at 10:00 on a morning it failed at
# 07:10. So the refused mint falls through to the cheapest session there is.

@test "a refused mint falls through to a claude session and the run goes ahead" {
    STUB_CLAUDE_REFRESHES=1
    STUB_USAGE_CODES="401 200" STUB_TOKEN_CODE=429 run "$REFRESH"
    [ "$status" -eq 0 ]
    ran_pipeline
    grep -q "quota ok after a claude session refreshed the access token" "$LOG"
    grep -q "running the cheapest claude session to refresh it instead" "$LOG"
}

# The token the retry carries has to come from re-reading the file the session rewrote,
# not from the variable holding the one that already 401'd.
@test "the retry after a session carries the token the session wrote" {
    STUB_CLAUDE_REFRESHES=1
    STUB_USAGE_CODES="401 200" STUB_TOKEN_CODE=429 run "$REFRESH"
    [ "$status" -eq 0 ]
    [[ "$(nth_usage_auth 1)" == *"Bearer stale-token"* ]]
    [[ "$(nth_usage_auth 2)" == *"Bearer session-token"* ]]
}

# THE ONE THAT MATTERS BEYOND THIS FILE. A bare `claude -p` starts a real session: the Stop
# hook notifies, and the transcript joins the corpus work-arcs and arc-cluster read. Every
# morning the token went stale would otherwise show up on the page as work Kyle did, and
# arc-backfill would feed it back as a prompt. lib/headless_claude puts it in the one
# project directory every consumer skips.
@test "the fallback session is isolated from the corpus it would otherwise pollute" {
    STUB_CLAUDE_REFRESHES=1
    STUB_USAGE_CODES="401 200" STUB_TOKEN_CODE=429 run "$REFRESH"
    [ "$status" -eq 0 ]
    grep -q "^cwd=.*/claude-headless$" "$STUB_DIR/claude-calls"
    grep -q "^quiet=1$" "$STUB_DIR/claude-calls"
}

@test "the fallback session is the cheapest model, not the default one" {
    STUB_CLAUDE_REFRESHES=1
    STUB_USAGE_CODES="401 200" STUB_TOKEN_CODE=429 run "$REFRESH"
    grep -q "^args=.*--model haiku" "$STUB_DIR/claude-calls"
}

@test "a fallback session that cannot run is reported as such" {
    STUB_CLAUDE_EXIT=1
    STUB_USAGE_CODES=401 STUB_TOKEN_CODE=429 run "$REFRESH"
    [ "$status" -eq 3 ]
    ! ran_pipeline
    grep -q "a claude session could not run either (claude exited 1)" "$LOG"
}

# A session can exit 0 without having refreshed anything, and that is a fourth outcome
# rather than a repeat of the third.
@test "a session that ran without refreshing anything is its own sentence" {
    STUB_USAGE_CODES="401 401" STUB_TOKEN_CODE=429 run "$REFRESH"
    [ "$status" -eq 3 ]
    grep -q "a claude session ran but the usage endpoint still answered HTTP 401" "$LOG"
}

# Nothing reaches a model on a morning the token was fine, which is almost every morning.
@test "no claude session is started when the stored token still works" {
    run "$REFRESH"
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_DIR/claude-calls" ]
}

@test "no claude session is started when minting a token worked" {
    STUB_USAGE_CODES="401 200" run "$REFRESH"
    [ "$status" -eq 0 ]
    [ ! -f "$STUB_DIR/claude-calls" ]
}

# A network failure must not reach a model either: it says nothing about the credential.
@test "no claude session is started for an unreachable endpoint" {
    STUB_USAGE_CODES="000 000 000" run "$REFRESH"
    [ "$status" -eq 3 ]
    [ ! -f "$STUB_DIR/claude-calls" ]
}

# Nothing to refresh with is not a network round trip, and must not be reported as one.
# The token endpoint answers in two shapes and the log has to read both. The flat OAuth
# one is a refused grant; the nested Anthropic one is what a 429 looks like, which turned
# up while this was being tested and arrived in the log as a bare status code until the
# reader handled it. 429 means try later and invalid_grant means re-login: a log that
# cannot tell them apart sends the next reader to the wrong place, which is the whole bug.
@test "a nested rate-limit error is named in the log, not just its status" {
    cat >"$STUB_TOKEN_RESP" <<'EOF'
{"error": {"type": "rate_limit_error", "message": "Rate limited. Please try again later."}}
EOF
    STUB_USAGE_CODES=401 STUB_TOKEN_CODE=429 run "$REFRESH"
    [ "$status" -eq 3 ]
    grep -q "token endpoint HTTP 429, rate_limit_error: Rate limited" "$LOG"
}

@test "a flat OAuth error is named in the log too" {
    cat >"$STUB_TOKEN_RESP" <<'EOF'
{"error": "invalid_grant", "error_description": "Refresh token not found"}
EOF
    STUB_USAGE_CODES=401 STUB_TOKEN_CODE=400 run "$REFRESH"
    [ "$status" -eq 3 ]
    grep -q "token endpoint HTTP 400, invalid_grant: Refresh token not found" "$LOG"
}

@test "a token endpoint that answers with no body at all still logs its status" {
    : >"$STUB_TOKEN_RESP"
    STUB_USAGE_CODES=401 STUB_TOKEN_CODE=503 run "$REFRESH"
    [ "$status" -eq 3 ]
    grep -q "token endpoint HTTP 503)" "$LOG"
}

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
    [[ "$output" == *"after a token refresh"* ]]
}

@test "--check-refresh says when the stored token can still mint one" {
    run "$REFRESH" --check-refresh
    [ "$status" -eq 0 ]
    [[ "$output" == *"minted a new access token"* ]]
    [ "$(usage_calls)" -eq 0 ]
}

# A diagnostic that leaks the thing it is diagnosing is worse than no diagnostic: this gets
# run in a terminal and pasted into messages.
@test "--check-refresh never prints a token" {
    run "$REFRESH" --check-refresh
    [ "$status" -eq 0 ]
    [[ "$output" != *"fresh-token"* ]]
    [[ "$output" != *"stored-refresh"* ]]
}

@test "--check-refresh names why the endpoint refused" {
    cat >"$STUB_TOKEN_RESP" <<'EOF'
{"error": {"type": "rate_limit_error", "message": "Rate limited. Please try again later."}}
EOF
    STUB_TOKEN_CODE=429 run "$REFRESH" --check-refresh
    [ "$status" -eq 4 ]
    [[ "$output" == *"HTTP 429, rate_limit_error: Rate limited"* ]]
}

@test "--check-refresh does not run the pipeline" {
    run "$REFRESH" --check-refresh
    ! ran_pipeline
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
    run "$REFRESH" --rebuild-everything
    [ "$status" -eq 2 ]
    ! ran_pipeline
}

# --- publishing ----------------------------------------------------------------------
#
# The run used to stop one step short: it built the page and logged an instruction telling
# a person to open a session and finish the job. These are about the step that replaced it.

@test "a successful run publishes the page it just built" {
    publishing_on
    run "$REFRESH"
    [ "$status" -eq 0 ]
    [ "$(deploy_calls)" = 1 ]
    grep -q "published: $ARTIFACT_URL" "$LOG"
    ! notified
}

@test "the publish carries the slug from the artifact URL" {
    publishing_on
    run "$REFRESH"
    [ "$(deploy_request | jq -r '.slug')" = "$STUB_SLUG" ]
}

# Inventing these would rename the page and change the icon Kyle finds the tab by, so they
# are read back from the artifact rather than decided here.
@test "the publish echoes back the artifact's own title and favicon" {
    publishing_on
    run "$REFRESH"
    [ "$(deploy_request | jq -r '.title')" = "Work Arcs" ]
    [ "$(deploy_request | jq -r '.favicon')" = "🧭" ]
}

@test "the publish sends the page as the content" {
    publishing_on
    run "$REFRESH"
    [ "$(deploy_request | jq -r '.content')" = "<h1>arcs</h1>" ]
}

# A page that publishes itself is refused a blind overwrite outright: "this artifact
# self-publishes — provide the baseVersion you edited from". So the precondition is not
# optional any more, and where the listing does not carry a version the boot route does.
@test "a publish with no version in the listing reads one from the boot route" {
    publishing_on
    echo '{"frames":[{"slug":"'"$STUB_SLUG"'","title":"Work Arcs","favicon":"X"}]}' \
        >"$STUB_FRAMES"
    run "$REFRESH"
    [ "$(jq -r '.baseVersion' "$STUB_DIR/deploy-request-1.json")" = "1787706300-d2fa" ]
}

# Superseding means rereading the version and publishing ON TOP of it, never dropping the
# precondition -- which the control plane refuses for a self-publishing page, and is right
# to: the version it is protecting is one somebody's click made.
@test "an artifact that moved is superseded on top of the winner's version" {
    publishing_on
    echo '{"ver":"newer-1","assetToken":"tok.1.2.3"}' >"$STUB_BOOT"
    STUB_DEPLOY_CODES="409 200" run "$REFRESH"
    [ "$(deploy_calls)" = 2 ]
    [ "$(jq -r '.baseVersion' "$STUB_DIR/deploy-request-2.json")" = "newer-1" ]
    [ "$(jq -r 'has("force")' "$STUB_DIR/deploy-request-2.json")" = "false" ]
    grep -q "superseding on top of version newer-1" "$LOG"
}

@test "the publish sends the artifact's version as the precondition" {
    publishing_on
    run "$REFRESH"
    [ "$(deploy_request | jq -r '.baseVersion')" = "v-old" ]
}

# The frame list has more than one artifact in it and only one of them is this page.
@test "the publish reads the record for its own slug and not the first one" {
    publishing_on
    run "$REFRESH"
    [ "$(deploy_request | jq -r '.title')" != "Something Else" ]
}

@test "a published run stamps published_at and the new version" {
    publishing_on
    run "$REFRESH"
    [ "$(jq -r '.published_at | type' "$STATE_JSON")" = "number" ]
    [ "$(jq -r '.published_version' "$STATE_JSON")" = "v-new" ]
}

# X-Frame-CP is what makes the gateway match the route at all. Without it the request 404s
# in a way that looks exactly like a wrong path, so it is worth a test that names it.
@test "the publish sends the frame routing headers" {
    publishing_on
    run "$REFRESH"
    grep -q "^X-Frame-CP: go$" "$STUB_DIR/deploy-headers"
    grep -q "^X-Frame-Surface: code$" "$STUB_DIR/deploy-headers"
}

# The first live run 403'd on curl's own User-Agent -- not a 401, so the credential was
# fine, and not a 404, so the route matched. Both calls need it, and the read is the one
# that failed, so both are checked.
@test "every frame call claims to be the CLI" {
    publishing_on
    run "$REFRESH"
    grep -q "^User-Agent: claude-cli/.* (external, cli)$" "$STUB_DIR/frames-headers"
    grep -q "^User-Agent: claude-cli/.* (external, cli)$" "$STUB_DIR/deploy-headers"
}

@test "a 403 on the read points at the headers rather than the login" {
    publishing_on
    STUB_FRAMES_CODE=403 run "$REFRESH"
    grep -q "HTTP 403" "$LOG"
    grep -q "suspect the client headers" "$LOG"
    [ "$(deploy_calls)" = 0 ]
}

@test "the publish uses the token the quota check already proved" {
    publishing_on
    run "$REFRESH"
    # One usage call and one deploy, both on the stored token: proving the credential
    # again for the write would be a second mint for no reason.
    [ "$(token_calls)" = 0 ]
    grep -q "^deploy Authorization: Bearer stale-token$" "$STUB_DIR/calls"
}

@test "a publish on a morning the token was stale uses the refreshed one" {
    publishing_on
    STUB_USAGE_CODES="401 200" run "$REFRESH"
    grep -q "^deploy Authorization: Bearer fresh-token$" "$STUB_DIR/calls"
}

# --- publishing, when it does not work ------------------------------------------------

@test "an artifact URL with no slug in it is refused before anything is sent" {
    publishing_on
    echo 'WORK_ARCS_ARTIFACT_URL=https://example.invalid/artifact' >"$FAKE_REPO/.env"
    run "$REFRESH"
    [ "$(deploy_calls)" = 0 ]
    grep -q "not an artifact link" "$LOG"
    grep -q "would create a second artifact" "$LOG"
}

@test "an empty page is refused before anything is sent" {
    export WORK_ARCS_PUBLISH=1
    pipeline_ok
    run "$REFRESH"
    [ "$(deploy_calls)" = 0 ]
    grep -q "missing or empty" "$LOG"
}

# The build succeeded and the page on disk is good; only the upload failed. The run says
# so out loud, because a page nobody can see is the failure this whole section prevents.
@test "a failed publish notifies and points at the manual route" {
    publishing_on
    STUB_DEPLOY_CODES=500 run "$REFRESH"
    notified
    grep -q "the page on disk is good" "$LOG"
}

@test "a failed publish does not stamp published_at" {
    publishing_on
    STUB_DEPLOY_CODES=500 run "$REFRESH"
    [ "$(jq -r '.published_at' "$STATE_JSON")" = "null" ]
}

# A plan cap will still be a plan cap in ten seconds, which is what separates this 429
# from the 503 below.
@test "a publish cap is not retried" {
    publishing_on
    STUB_DEPLOY_CODES="429 200" run "$REFRESH"
    [ "$(deploy_calls)" = 1 ]
    grep -q "publish cap" "$LOG"
}

@test "a busy render service is retried and then succeeds" {
    publishing_on
    STUB_DEPLOY_CODES="503 200" run "$REFRESH"
    [ "$status" -eq 0 ]
    [ "$(deploy_calls)" = 2 ]
    grep -q "render service is busy" "$LOG"
    grep -q "published:" "$LOG"
}

@test "a render service that stays busy gives up rather than looping" {
    publishing_on
    STUB_DEPLOY_CODES=503 run "$REFRESH"
    [ "$(deploy_calls)" = 3 ]
    grep -q "stayed busy across 3 attempts" "$LOG"
}

# Something else published between this run's read and its write. Nothing of that version
# survives in what we are sending -- the page is rebuilt whole every run, and anything
# acknowledged on the live one reached the stores before the rebuild started -- so the
# default is to supersede it, and to say so.
#
# The second attempt used to drop the precondition and force. It cannot any more, and the
# reason is a good one: a page that publishes itself is refused a blind overwrite outright,
# because the version being overwritten is one somebody's click made. So superseding is
# rereading the winner's version and publishing on top of it.
@test "an artifact that moved underneath the run is superseded" {
    publishing_on
    echo '{"ver":"v-newer","assetToken":"tok.1.2.3"}' >"$STUB_BOOT"
    STUB_DEPLOY_CODES="409 200" run "$REFRESH"
    [ "$status" -eq 0 ]
    [ "$(deploy_calls)" = 2 ]
    grep -q "moved since this run read it" "$LOG"
    [ "$(deploy_request 1 | jq -r '.baseVersion')" = "v-old" ]
    [ "$(deploy_request 2 | jq -r '.baseVersion')" = "v-newer" ]
    [ "$(deploy_request 2 | jq -r 'has("force")')" = "false" ]
}

@test "superseding can be turned off, and then a conflict is a failure" {
    publishing_on
    STUB_DEPLOY_CODES="409 200" WORK_ARCS_PUBLISH_SUPERSEDE=0 run "$REFRESH"
    [ "$(deploy_calls)" = 1 ]
    grep -q "refused with HTTP 409" "$LOG"
}

@test "an artifact this login cannot see is named as such" {
    publishing_on
    echo '{"frames": []}' >"$STUB_FRAMES"
    run "$REFRESH"
    [ "$(deploy_calls)" = 0 ]
    grep -q "may belong to another login" "$LOG"
}

# --- --publish -------------------------------------------------------------------------

@test "--publish uploads the page on disk without rebuilding it" {
    export WORK_ARCS_PUBLISH=1
    printf '<h1>arcs</h1>' >"$STATE/page.html"
    run "$REFRESH" --publish
    [ "$status" -eq 0 ]
    [ "$(deploy_calls)" = 1 ]
    # The expensive half did not run: no build line, and no quota read to gate one.
    ! grep -q "refreshed in" "$LOG"
    [ "$(usage_calls)" = 0 ]
}

@test "--publish reports a failure in its exit status" {
    export WORK_ARCS_PUBLISH=1
    printf '<h1>arcs</h1>' >"$STATE/page.html"
    STUB_DEPLOY_CODES=500 run "$REFRESH" --publish
    [ "$status" -eq 1 ]
}

# --- reading the published page back ---------------------------------------------------
#
# THE LOOP THIS SECTION EXISTS FOR. Every ✕ and every answer on the published page was
# recorded honestly in the browser's localStorage, where nothing in this pipeline could
# see it, and reached the stores only through a download the reader then moved into
# ~/.local/state/work-arcs by hand -- which has never once been done. So the brief, the
# lede, the counts and the queue went on repeating what had already been dealt with.
#
# What follows pins the two rules the read-back is held to, and they are the same rule
# looked at from either end: a lost acknowledgement must never be quiet, and a read-back
# that fails must never cost the morning its page.

seed_of() { cat "$STUB_DIR/seed.json" 2>/dev/null; }
ingest_calls() { grep -c '^work-arcs --ingest-acks' "$STUB_DIR/calls" 2>/dev/null || true; }

published_page_with() {
    printf '<!-- frame-runtime --><head></head><!-- /frame-runtime --><title>Work Arcs</title><script type="application/json" id="ackseed">%s</script>\n' \
        "$1" >"$STUB_PAGE"
}

@test "the page is read back and its seed handed to work-arcs" {
    published_page_with '{"dismissed":{"abc123":{"ref":"UL-1","at":9,"note":"fine"}}}'
    run "$REFRESH"
    [ "$status" -eq 0 ]
    [ "$(ingest_calls)" = 1 ]
    seed_of | grep -q '"abc123"'
}

# The order is the whole feature. work-arcs prunes, counts and asks its questions off these
# stores, so a judgement adopted after the build would be adopted into a page that had
# already ignored it and would first show up a day late.
@test "the read-back happens before the rebuild, not after" {
    run "$REFRESH"
    [ "$status" -eq 0 ]
    ran_pipeline
    local ingest build
    ingest="$(grep -n 'ingest:' "$LOG" | head -1 | cut -d: -f1)"
    build="$(grep -n 'refreshed in' "$LOG" | head -1 | cut -d: -f1)"
    [ -n "$ingest" ]
    [ -n "$build" ]
    [ "$ingest" -lt "$build" ]
}

@test "a read-back that fails is loud and does not cost the page" {
    STUB_PAGE_CODE=500 run "$REFRESH"
    [ "$status" -eq 0 ]
    ran_pipeline
    grep -q "ingest: could not read the published page" "$LOG"
    [ "$(jq -r '.ingest_ok' "$STATE_JSON")" = "false" ]
    [ "$(jq -r '.ingest' "$STATE_JSON")" != "null" ]
}

# Loud in the log and in the state file, and deliberately NOT a notification. The
# notification budget is the whole reason a notification means anything, and this is a step
# that fails on any morning the network is slow -- costing that morning's clicks and
# nothing else, because the page still holds them for the next run.
@test "a failed read-back is not worth waking anybody for" {
    STUB_PAGE_CODE=500 run "$REFRESH"
    [ "$status" -eq 0 ]
    ! notified
}

@test "work-arcs refusing the seed is reported, and the build still runs" {
    STUB_INGEST_EXIT=1 STUB_INGEST_MSG="the page's confirmed is a list" run "$REFRESH"
    [ "$status" -eq 0 ]
    ran_pipeline
    grep -q "the page's confirmed is a list" "$LOG"
    [ "$(jq -r '.ingest_ok' "$STATE_JSON")" = "false" ]
}

# A page published before any of this existed carries no such block, and the rebuild this
# run is about to do puts one there. Not a failure, and it must not read as one.
@test "a page with no seed block yet is not a failure" {
    printf '<!-- frame-runtime --><head></head><!-- /frame-runtime --><title>Work Arcs</title>nothing here\n' >"$STUB_PAGE"
    run "$REFRESH"
    [ "$status" -eq 0 ]
    [ "$(ingest_calls)" = 0 ]
    grep -q "carries no seed block yet" "$LOG"
    [ "$(jq -r '.ingest_ok' "$STATE_JSON")" = "true" ]
}

# The read-back is off for a machine that is not the one Kyle acknowledges rows on -- a
# second checkout, a test run -- where adopting whatever somebody else is clicking into
# these stores would be worse than adopting nothing.
@test "the read-back can be turned off, and says so" {
    WORK_ARCS_INGEST=0 run "$REFRESH"
    [ "$status" -eq 0 ]
    [ "$(ingest_calls)" = 0 ]
    grep -q "ingest: off" "$LOG"
}

@test "with no artifact link there is nothing to read back" {
    : >"$FAKE_REPO/.env"
    run "$REFRESH"
    [ "$status" -eq 0 ]
    [ "$(ingest_calls)" = 0 ]
    grep -q "no artifact link to read back" "$LOG"
}

# Three routes answer three different questions, and picking the wrong one costs a round of
# debugging: the capability route says what the artifact may DO, the boot route says which
# version is live and hands out a token, and only the content host has the page.
@test "the page is read from the content host, with the boot token" {
    run "$REFRESH"
    grep -q '^bootread' "$STUB_DIR/calls"
    grep -q '^pageread .*claudeusercontent.com' "$STUB_DIR/calls"
    grep -q '^pageread .*/_f/1787706300-d2fa/index.html' "$STUB_DIR/calls"
}

# The OAuth bearer is not sent to the content host: different host, would not be accepted,
# and a credential does not go anywhere it is not needed.
@test "the content fetch carries the token and not the login" {
    run "$REFRESH"
    ! grep '^pageread' "$STUB_DIR/calls" | grep -q "Bearer"
}

# A public (non-member) serve gets no token, and the page is not readable that way. Not a
# transient failure, and no number of retries changes it.
@test "a boot response with no token is named rather than retried" {
    echo '{"ver":"1787706300-d2fa"}' >"$STUB_BOOT"
    run "$REFRESH"
    [ "$status" -eq 0 ]
    grep -q "ingest: could not read the published page" "$LOG"
    ! grep -q '^pageread' "$STUB_DIR/calls"
}

# --- what the published page is allowed to do -------------------------------------------
#
# A declaration is a FULL SET: anything stored and not restated is revoked. So a republish
# that quietly omitted this would leave every ✕ on the page local again -- the exact
# failure the loop above was built to end, wearing the face of a feature that works.

@test "every publish restates what the page may do" {
    publishing_on
    run "$REFRESH"
    [ "$(deploy_calls)" = 1 ]
    [ "$(jq -r '.capabilities.artifact | type' "$STUB_DIR/deploy-request-1.json")" = "object" ]
    [ "$(jq -r '.capabilities.downloads | type' "$STUB_DIR/deploy-request-1.json")" = "object" ]
}

# The two travel together or neither travels: the artifact API answers a declaration with
# no contract "capabilities requires contract". Since the page's ability to save itself
# rests on the declaration, the contract is part of the declaration.
@test "a declaration always carries the contract it needs" {
    publishing_on
    run "$REFRESH"
    [ "$(jq -r '.contract' "$STUB_DIR/deploy-request-1.json")" = "0.2.23" ]
}

# A version and never `latest`: `latest` would move the runtime under a live page whenever
# the platform released one, and the page's code is written against a contract it can name.
@test "the contract is a version, and a run can be asked for another" {
    publishing_on
    WORK_ARCS_PUBLISH_CONTRACT=0.3.0 run "$REFRESH"
    [ "$(jq -r '.contract' "$STUB_DIR/deploy-request-1.json")" = "0.3.0" ]
}

@test "the contract can be left off entirely along with the declaration" {
    publishing_on
    WORK_ARCS_PUBLISH_CAPABILITIES= WORK_ARCS_PUBLISH_CONTRACT= run "$REFRESH"
    [ "$(jq -r 'has("contract")' "$STUB_DIR/deploy-request-1.json")" = "false" ]
    [ "$(jq -r 'has("capabilities")' "$STUB_DIR/deploy-request-1.json")" = "false" ]
}

# A request that never reaches the host answers 000, and `HTTP 000 —` with nothing after it
# is a log line that ends an investigation rather than starting one.
@test "a request that never reached the host says what curl said" {
    publishing_on
    STUB_DEPLOY_CODES=000 run "$REFRESH"
    grep -q "never reached the host" "$LOG"
}

# A control plane that does not know the field must not cost the publish: a page nobody can
# see is worse than a page that cannot save itself. Said out loud either way.
@test "a control plane that refuses the declaration still gets the page" {
    publishing_on
    STUB_DEPLOY_CODES="400 200" STUB_DEPLOY_MSG="unknown field capabilities" run "$REFRESH"
    [ "$(deploy_calls)" = 2 ]
    [ "$(jq -r 'has("capabilities")' "$STUB_DIR/deploy-request-2.json")" = "false" ]
    grep -q "refused the capability declaration" "$LOG"
    grep -q "will not be able to save itself" "$LOG"
}

@test "the declaration can be cleared entirely" {
    publishing_on
    WORK_ARCS_PUBLISH_CAPABILITIES= run "$REFRESH"
    [ "$(jq -r 'has("capabilities")' "$STUB_DIR/deploy-request-1.json")" = "false" ]
}

# --- --ingest and --capabilities ---------------------------------------------------------

@test "--ingest reads the page back without rebuilding it" {
    published_page_with '{"dismissed":{"zzz999":1}}'
    run "$REFRESH" --ingest
    [ "$status" -eq 0 ]
    ! ran_pipeline
    seed_of | grep -q 'zzz999'
}

@test "--ingest reports a failure in its exit status" {
    STUB_PAGE_CODE=500 run "$REFRESH" --ingest
    [ "$status" -eq 1 ]
}

@test "--capabilities says what the artifact may do and on what contract" {
    run "$REFRESH" --capabilities
    [ "$status" -eq 0 ]
    [[ "$output" == *"0.2.23"* ]]
    [[ "$output" == *"artifact"* ]]
}

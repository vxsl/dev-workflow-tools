#!/usr/bin/env bats
# Tests for arc-standup-notify -- the gate, and only the gate.
#
# The composition is arc-standup's and is tested in standup.bats; nothing here asserts a
# word of the prose. What is pinned is the decision to interrupt somebody, which has two
# failure directions and they are not symmetrical.
#
# Speaking when it should not is the expensive one. This is a notification that arrives
# uninvited on a working machine, and the thing being avoided is a status bot: one wrong
# interruption is worth more than several missed ones, because the first one that is not
# wanted is the one that gets the timer disabled. So the refusals are pinned at every edge
# -- the wrong quarter hour, the wrong day, the minute the standup starts, a second time
# on the same morning, an empty block, and prep composed for a meeting that has been and
# gone.
#
# Staying silent when it should speak is the cheaper failure and still a failure, because
# silence here is indistinguishable from the feature not existing. Every refusal writes a
# sentence to refresh.log saying which gate closed, and those lines are asserted: an
# unexplained silence is the exact bug this workstream keeps rediscovering.
#
# The cadence is never hard-coded in a schedule. What decides is arc-standup's own
# cadence(), read from STANDUP_DAYS/STANDUP_TIME/STANDUP_TZ, so a test that moves the
# cadence has to move what the program does -- and one below does exactly that.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

setup() {
    setup_temp_dir

    export HOME="$TEST_TMPDIR/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    export XDG_CONFIG_HOME="$HOME/.config"
    STATE="$XDG_STATE_HOME/work-arcs"
    mkdir -p "$STATE" "$HOME/bin"

    LOG="$STATE/refresh.log"
    SIDECAR="$STATE/standup.json"
    MARKER="$STATE/standup-notified.json"

    # A copy rather than the real checkout, so the program parses a fixture .env and Kyle's
    # is never read into a test -- it carries a real artifact URL and real tokens.
    FAKE_REPO="$TEST_TMPDIR/repo"
    mkdir -p "$FAKE_REPO/bin"
    cp "$REPO_ROOT/bin/arc-standup-notify" "$FAKE_REPO/bin/"
    cp "$REPO_ROOT/bin/arc-standup" "$FAKE_REPO/bin/"
    cp -r "$REPO_ROOT/lib" "$FAKE_REPO/lib"
    cp -r "$REPO_ROOT/systemd" "$FAKE_REPO/systemd"
    NOTIFY_CMD="$FAKE_REPO/bin/arc-standup-notify"
    echo 'WORK_ARCS_ARTIFACT_URL="https://example.invalid/artifact"' >"$FAKE_REPO/.env"

    # The cadence every test assumes unless it says otherwise, set rather than defaulted so
    # a change to the default cannot quietly rewrite what these assertions mean.
    export STANDUP_DAYS="mon,wed,fri"
    export STANDUP_TIME="10:30"
    export STANDUP_TZ="America/Los_Angeles"

    export NOTIFY_LOG="$TEST_TMPDIR/notify.log"
    export WORK_ARCS_NOTIFY="$HOME/bin/notify-stub"
    cat >"$WORK_ARCS_NOTIFY" <<'EOF'
#!/bin/sh
printf '=== %s\n%s\n' "$1" "$2" >>"$NOTIFY_LOG"
EOF
    chmod +x "$WORK_ARCS_NOTIFY"

    # Wednesday 2026-08-26 is a standup day; Tuesday the 25th is not. Both are in daylight
    # time, which is the offset every instant below carries.
    WED_BEFORE="2026-08-26T10:16:00-07:00"
    WED_MORNING="2026-08-26T07:10:00-07:00"
    WED_AT="2026-08-26T10:30:00-07:00"
    WED_AFTER="2026-08-26T10:31:00-07:00"
    TUE_BEFORE="2026-08-25T10:16:00-07:00"
}

teardown() {
    teardown_temp_dir
}

# A sidecar of the shape bin/arcs writes: the composed block, and the standup it was
# composed for. $1 is that standup's instant, $2 the emptiness flag.
write_sidecar() {
    local target="${1:-2026-08-26T10:30:00-07:00}" empty="${2:-false}"
    python3 - "$SIDECAR" "$target" "$empty" <<'PY'
import json, sys
path, target, empty = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
text = ("FOR WEDNESDAY'S STANDUP - since Monday 10:30\n\nMOVED\n"
        "  UL-1852 landed !10406 & the geo_filter migration\n"
        "  DE-2585 is in review !10412\n")
json.dump({
    "v": 1,
    "for": {"iso": target, "day": "Wednesday", "when": "Wednesday 10:30"},
    "since": {"iso": "2026-08-24T10:30:00-07:00", "day": "Monday",
              "when": "Monday 10:30"},
    "beats": [{"kind": "moved", "lead": "moved", "items": [
        {"text": "UL-1852 landed !10406 & the geo_filter migration"},
        {"text": "DE-2585 is in review !10412"}]}],
    "empty": empty,
    "note": "",
    "built_at": 1787670600,
    "text": "" if empty else text,
}, open(path, "w"))
PY
}

notified() {
    [ -s "$NOTIFY_LOG" ]
}

# --- speaking ------------------------------------------------------------------------

@test "the prep arrives in the quarter hour before the standup" {
    write_sidecar
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    notified
    grep -q "UL-1852 landed" "$NOTIFY_LOG"
    grep -q "standup-notify: delivered" "$LOG"
}

@test "the summary says which standup and how long is left" {
    write_sidecar
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    grep -q "=== Standup in 14 min — Wednesday 10:30" "$NOTIFY_LOG"
}

@test "the delivered block is the sidecar's own composition" {
    write_sidecar
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    # Every line the composition carries, in it, unrewritten -- the point of the sidecar is
    # that nothing downstream of arc-standup gets to be a second author for this string.
    grep -q "FOR WEDNESDAY'S STANDUP - since Monday 10:30" "$NOTIFY_LOG"
    grep -q "DE-2585 is in review !10412" "$NOTIFY_LOG"
}

@test "a plain-text surface is handed the ampersand unescaped" {
    write_sidecar
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    grep -q "10406 & the geo_filter" "$NOTIFY_LOG"
}

@test "a markup surface is handed it escaped, or dunst renders none of the block" {
    write_sidecar
    export WORK_ARCS_NOTIFY_MARKUP=1
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    grep -q "10406 &amp; the geo_filter" "$NOTIFY_LOG"
}

@test "the page is reachable from the popup, from .env and not from the environment" {
    write_sidecar
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    grep -q "https://example.invalid/artifact" "$NOTIFY_LOG"
}

# --- staying quiet -------------------------------------------------------------------

@test "the morning build does not notify at build time" {
    write_sidecar
    run "$NOTIFY_CMD" --at "$WED_MORNING"
    [ "$status" -eq 3 ]
    ! notified
    grep -q "standup-notify: said nothing" "$LOG"
    grep -q "15 minutes before one" "$LOG"
}

@test "the minute the standup starts is outside the window" {
    write_sidecar
    run "$NOTIFY_CMD" --at "$WED_AT"
    [ "$status" -eq 3 ]
    ! notified
}

@test "nothing arrives after the standup has begun" {
    write_sidecar
    run "$NOTIFY_CMD" --at "$WED_AFTER"
    [ "$status" -eq 3 ]
    ! notified
}

@test "a day that is not a standup day is silent at the same time of morning" {
    write_sidecar
    run "$NOTIFY_CMD" --at "$TUE_BEFORE"
    [ "$status" -eq 3 ]
    ! notified
}

@test "prep built any time since the last standup is for the next one" {
    # The 07:10 Wednesday build and a Tuesday-afternoon build both name Wednesday 10:30,
    # because the window is the interval between two standups rather than the age of a file.
    write_sidecar "2026-08-26T10:30:00-07:00"
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    notified
}

@test "a block with nothing in it says nothing out loud" {
    write_sidecar "2026-08-26T10:30:00-07:00" true
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 3 ]
    ! notified
    grep -q "nothing to report" "$LOG"
}

# --- degrading, and saying so -----------------------------------------------------------
#
# The block failing to build is the morning its absence matters most, and the failure this
# guards against is the one this whole program was written to end arriving in a new
# costume: a person at 10:29 who has nothing, because the thing that had something never
# said it had nothing. So the moment still gets its card -- the clock, the reason, the link
# -- and the reason is on the screen rather than only in refresh.log.
#
# What makes that safe rather than a status bot is the gate order, and it is asserted from
# both sides below: the clock is consulted before the prep is looked for, so an empty state
# directory is silent every hour of the week except the one this speaks in.

@test "a build that never wrote the prep still gets the moment announced" {
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    notified
    grep -q "=== Standup in 14 min — no prep to hand over" "$NOTIFY_LOG"
    grep -q "nothing has built" "$NOTIFY_LOG"
    grep -q "https://example.invalid/artifact" "$NOTIFY_LOG"
    grep -q "handed over a pointer" "$LOG"
}

@test "a sidecar that will not parse says which failure it was, not just that one happened" {
    # A build that never ran wants arcs; a build that ran and wrote this wants looking at.
    # A person with fourteen minutes can only act on the one they can name.
    echo 'not json at all' >"$SIDECAR"
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    grep -q "will not parse" "$NOTIFY_LOG"
    ! grep -q "nothing has built" "$NOTIFY_LOG"
}

@test "prep composed for a standup that has been and gone is replaced, not delivered" {
    # A page last built before Monday's call: its window closed at a meeting already given,
    # so its notes are a record rather than a preparation. None of them reaches the screen.
    write_sidecar "2026-08-24T10:30:00-07:00"
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    grep -q "has been and gone" "$NOTIFY_LOG"
    ! grep -q "UL-1852 landed" "$NOTIFY_LOG"
    grep -q "handed over a pointer" "$LOG"
}

@test "the clock is asked before the prep, so a missing page is silent out of the window" {
    # The whole of what keeps the degradation from being a notification about a state
    # directory. Same absent sidecar as the first test in this section, wrong quarter hour.
    run "$NOTIFY_CMD" --at "$WED_MORNING"
    [ "$status" -eq 3 ]
    ! notified
    grep -q "15 minutes before one" "$LOG"
}

@test "a missing page on a day with no standup is silent" {
    run "$NOTIFY_CMD" --at "$TUE_BEFORE"
    [ "$status" -eq 3 ]
    ! notified
}

@test "a pointer spends the morning's one interruption" {
    # Having said the page did not build, saying it again four minutes later is the nagging
    # this refuses to do -- and a build that lands at 10:17 does not get to re-announce it.
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    write_sidecar
    run "$NOTIFY_CMD" --at "2026-08-26T10:20:00-07:00"
    [ "$status" -eq 3 ]
    [ "$(grep -c '^===' "$NOTIFY_LOG")" -eq 1 ]
    grep -q "already delivered" "$LOG"
}

@test "a block that built and is empty stays silent rather than degrading" {
    # The one silence that stays: this is a finished report, not a failed build, and
    # pointing at a page to say there is nothing on it is the worst ratio here.
    write_sidecar "2026-08-26T10:30:00-07:00" true
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 3 ]
    ! notified
    grep -q "nothing to report" "$LOG"
}

@test "force shows the stale block rather than a pointer, because it was asked for" {
    # --force is somebody asking to see what is there. A pointer is not an answer to that.
    write_sidecar "2026-08-24T10:30:00-07:00"
    run "$NOTIFY_CMD" --force --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    grep -q "UL-1852 landed" "$NOTIFY_LOG"
    grep -q "force past staleness" "$LOG"
}

@test "a pointer that cannot be delivered is a failure like any other" {
    export WORK_ARCS_NOTIFY="$TEST_TMPDIR/nothing-here"
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 1 ]
    [ ! -f "$MARKER" ]
}

@test "check names the pointer as its own outcome" {
    run "$NOTIFY_CMD" --check --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    [[ "$output" == "would notify with a pointer: "* ]]
    ! notified
}

# --- once, and only once --------------------------------------------------------------

@test "one standup gets one notification however often the timer fires" {
    write_sidecar
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    run "$NOTIFY_CMD" --at "2026-08-26T10:20:00-07:00"
    [ "$status" -eq 3 ]
    [ "$(grep -c '^===' "$NOTIFY_LOG")" -eq 1 ]
    grep -q "already delivered" "$LOG"
}

@test "the next standup re-arms it" {
    write_sidecar
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    write_sidecar "2026-08-28T10:30:00-07:00"
    run "$NOTIFY_CMD" --at "2026-08-28T10:16:00-07:00"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^===' "$NOTIFY_LOG")" -eq 2 ]
}

@test "force walks past the clock and the marker, and the log says it did" {
    write_sidecar
    run "$NOTIFY_CMD" --force --at "$TUE_BEFORE"
    [ "$status" -eq 0 ]
    notified
    grep -q "force past the clock" "$LOG"
}

@test "force does not spend the morning's one automatic delivery" {
    # Looking at the thing must not be the reason it never arrives.
    write_sidecar
    run "$NOTIFY_CMD" --force --at "$TUE_BEFORE"
    [ "$status" -eq 0 ]
    [ ! -f "$MARKER" ]
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^===' "$NOTIFY_LOG")" -eq 2 ]
}

# --- when the delivery itself fails ----------------------------------------------------
#
# Told apart from a refusal by the exit code, and that separation is the unit's whole
# reading of this program: 3 is a wake-up it declined and 1 is prep that was ready and did
# not reach the screen. Collapsing them would put "today is not a standup day" in
# systemctl as a failure three mornings a week, and the one morning something was actually
# broken would look exactly like the other two.

@test "a notifier that fails is a failure and not a refusal" {
    write_sidecar
    cat >"$WORK_ARCS_NOTIFY" <<'EOF'
#!/bin/sh
echo "the session bus is not there" >&2
exit 1
EOF
    chmod +x "$WORK_ARCS_NOTIFY"
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 1 ]
    ! notified
    grep -q "could not be delivered" "$LOG"
    grep -q "session bus" "$LOG"
}

@test "a failed delivery does not burn the once-a-standup marker" {
    write_sidecar
    cat >"$WORK_ARCS_NOTIFY" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$WORK_ARCS_NOTIFY"
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 1 ]
    [ ! -f "$MARKER" ]
}

@test "a notifier that is not there is a failure too" {
    write_sidecar
    export WORK_ARCS_NOTIFY="$TEST_TMPDIR/nothing-here"
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 1 ]
    grep -q "no notifier at" "$LOG"
}

@test "the unit treats a declined wake-up as success and a failed delivery as failure" {
    grep -q "^SuccessExitStatus=3$" "$REPO_ROOT/systemd/work-arcs-standup.service"
    ! grep -qE "^SuccessExitStatus=.*\b1\b" "$REPO_ROOT/systemd/work-arcs-standup.service"
}

@test "the unit does not tear the popup down the moment the run returns" {
    # The notification is a process here, not a message handed to a daemon: the default
    # control-group kill would deliver the prep and take it away in the same second.
    grep -q "^KillMode=process$" "$REPO_ROOT/systemd/work-arcs-standup.service"
}

# --- the cadence is the authority ------------------------------------------------------

@test "moving the cadence moves the gate without touching a schedule" {
    write_sidecar "2026-08-25T14:00:00-07:00"
    export STANDUP_DAYS="tue"
    export STANDUP_TIME="14:00"
    run "$NOTIFY_CMD" --at "2026-08-25T13:50:00-07:00"
    [ "$status" -eq 0 ]
    notified
}

@test "the lead time is a knob and the window follows it" {
    write_sidecar
    export STANDUP_NOTIFY_LEAD=45
    run "$NOTIFY_CMD" --at "2026-08-26T10:00:00-07:00"
    [ "$status" -eq 0 ]
    notified
}

@test "a lead time that is not a number falls back rather than failing the run" {
    write_sidecar
    export STANDUP_NOTIFY_LEAD="half an hour"
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    notified
    grep -q "could not read STANDUP_NOTIFY_LEAD" "$LOG"
}

# --- which surface gets it -------------------------------------------------------------
#
# The block is twenty-one lines and dunst caps a notification at about thirteen of them, so
# what a notification drops is the two beats a person on the call can act on. The popup
# sizes itself to its content; the notification path is the fallback for a machine with no
# GTK. These drive the real default rather than the single stub the rest of the file uses.

setup_default_surfaces() {
    mkdir -p "$HOME/bin/notification"
    unset WORK_ARCS_NOTIFY
    export POPUP_LOG="$TEST_TMPDIR/popup.log"
    cat >"$HOME/bin/notification/claude-notify.sh" <<'EOF'
#!/bin/sh
printf '=== %s\n%s\n' "$1" "$2" >>"$NOTIFY_LOG"
EOF
    chmod +x "$HOME/bin/notification/claude-notify.sh"
}

popup_stub() {
    cat >"$HOME/bin/notification/claude-notify-popup.py"
    chmod +x "$HOME/bin/notification/claude-notify-popup.py"
}

@test "the block goes to the surface that can show all of it" {
    write_sidecar
    setup_default_surfaces
    popup_stub <<'EOF'
#!/bin/sh
printf '=== %s\n%s\n' "$1" "$2" >>"$POPUP_LOG"
EOF
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    grep -q "UL-1852 landed" "$POPUP_LOG"
    [ ! -s "$NOTIFY_LOG" ]
}

@test "a popup that cannot open a display falls back, and the log says it did" {
    write_sidecar
    setup_default_surfaces
    popup_stub <<'EOF'
#!/bin/sh
echo "cannot open display" >&2
exit 1
EOF
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    grep -q "UL-1852 landed" "$NOTIFY_LOG"
    grep -q "fell back to a second notifier" "$LOG"
    grep -q "cannot open display" "$LOG"
}

@test "the fallback escapes what the first surface did not" {
    write_sidecar
    setup_default_surfaces
    popup_stub <<'EOF'
#!/bin/sh
exit 1
EOF
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    grep -q "10406 &amp; the geo_filter" "$NOTIFY_LOG"
}

@test "a delivery that worked first time says nothing about a fallback" {
    write_sidecar
    setup_default_surfaces
    popup_stub <<'EOF'
#!/bin/sh
exit 0
EOF
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 0 ]
    ! grep -q "fell back" "$LOG"
}

@test "both surfaces refusing is a failure carrying both reasons" {
    write_sidecar
    setup_default_surfaces
    rm -f "$HOME/bin/notification/claude-notify.sh"
    run "$NOTIFY_CMD" --at "$WED_BEFORE"
    [ "$status" -eq 1 ]
    grep -q "could not be delivered" "$LOG"
    grep -q "claude-notify-popup.py" "$LOG"
    grep -q "claude-notify.sh" "$LOG"
}

# --- the unit --------------------------------------------------------------------------

@test "the shipped timer does not catch up after a closed lid" {
    # The single property that separates this timer from the refresh timer beside it. A
    # missed 10:15 is a standup that has already happened; firing late is worse than not
    # firing, which is the opposite of what a missed page rebuild is worth.
    grep -q "^Persistent=false" "$REPO_ROOT/systemd/work-arcs-standup.timer"
    ! grep -q "^WakeSystem=true" "$REPO_ROOT/systemd/work-arcs-standup.timer"
}

@test "install derives the schedule from the cadence rather than from a constant" {
    export PATH="$HOME/bin:$PATH"
    export SYSTEMCTL_LOG="$TEST_TMPDIR/systemctl.log"
    cat >"$HOME/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
exit 0
EOF
    chmod +x "$HOME/bin/systemctl"
    export STANDUP_DAYS="tue,thu"
    export STANDUP_TIME="09:00"
    export STANDUP_NOTIFY_LEAD=20
    run "$NOTIFY_CMD" --install-timer
    [ "$status" -eq 0 ]
    unit="$XDG_CONFIG_HOME/systemd/user/work-arcs-standup.timer"
    grep -q "^OnCalendar=Tue,Thu 08:40 America/Los_Angeles" "$unit"
    grep -q "^Persistent=false" "$unit"
    grep -q "enable --now work-arcs-standup.timer" "$SYSTEMCTL_LOG"
}

@test "install points the service at the checkout it was run from" {
    export PATH="$HOME/bin:$PATH"
    export SYSTEMCTL_LOG="$TEST_TMPDIR/systemctl.log"
    cat >"$HOME/bin/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod +x "$HOME/bin/systemctl"
    run "$NOTIFY_CMD" --install-timer
    [ "$status" -eq 0 ]
    grep -q "^ExecStart=$FAKE_REPO/bin/arc-standup-notify$" \
        "$XDG_CONFIG_HOME/systemd/user/work-arcs-standup.service"
}

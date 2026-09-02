#!/usr/bin/env bats

# Tests for publish-changes' status move -- the arm that runs on every ticket Kyle
# ships, and until now the last inline Jira transition in this repo.
#
# NOTHING HERE REACHES JIRA. The move goes through bin/jira-transition, so what these
# tests stub is that tool: a script in a fake SCRIPT_DIR that records its argv and
# answers from fixtures. What is asserted is the conversation publish-changes has with
# it -- --list, exactly one match on the STATUS, then --transition-id -- and that every
# way that conversation can fail leaves the MR alone rather than aborting the run.
#
# The rules are lifted out of bin/publish-changes with awk and run under `set -e`, the
# way the script itself runs them, with the call site's own if/elif shape around them.
# A helper that returned non-zero in the wrong place would abort publish-changes after
# the MR already exists, so the shape is part of what is being tested.
#
# The fixtures are the three boards as measured on 2026-09-01, from a ticket in
# progress: UB reaches "MR" by transition 71, UL reaches "In Review" by 3, and DE
# offers TWO arrows onto "Peer Review" (41 and 5), which is the ambiguity this arm now
# refuses instead of resolving by list order.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    PC="$REPO_ROOT/bin/publish-changes"
    TEST_TMPDIR=$(mktemp -d)
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"

    # The fake SCRIPT_DIR. It is NOT on PATH: publish-changes calls the tool by the
    # path it sits next to, and a test that found it on PATH would prove the wrong thing.
    STUB_DIR="$TEST_TMPDIR/bin"
    mkdir -p "$STUB_DIR"

    # A curl that records and answers nothing, on PATH. If any refusal path ever falls
    # back to POSTing a transition itself, it shows up in this log.
    PATH_DIR="$TEST_TMPDIR/path"
    mkdir -p "$PATH_DIR"
    export CURL_LOG="$TEST_TMPDIR/curl.argv"
    : > "$CURL_LOG"
    cat > "$PATH_DIR/curl" <<'CURLSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
exit 0
CURLSTUB
    chmod +x "$PATH_DIR/curl"
    export PATH="$PATH_DIR:$PATH"

    export JT_LOG="$TEST_TMPDIR/jt.argv"
    : > "$JT_LOG"
    export JT_LIST_FILE="$TEST_TMPDIR/list.json"
    export JT_LIST_FAIL=""
    export JT_MOVE_FAIL=""
    export JT_MOVE_MESSAGE=""
    export JT_MOVE_STDOUT_EMPTY=""
    export JT_FROM=""
    export JT_TO=""
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# --- fixtures ------------------------------------------------------------------------

# UB from "IN PROGRESS": the review status is called "MR" and so is the arrow.
list_ub() {
    cat > "$JT_LIST_FILE" <<'EOF'
[{"id":"11","name":"To Do","to":"To Do","hasScreen":false,"required":[]},
 {"id":"21","name":"IN PROGRESS","to":"IN PROGRESS","hasScreen":false,"required":[]},
 {"id":"61","name":"QA","to":"QA","hasScreen":false,"required":[]},
 {"id":"71","name":"MR","to":"MR","hasScreen":false,"required":[]},
 {"id":"81","name":"Passed QA","to":"Passed QA","hasScreen":false,"required":[]}]
EOF
}

# UL from "In Progress": the review status is "In Review", and id 4 is the pair this
# whole change is about -- an arrow NAMED "Qualifying" that lands on "In Qualification".
list_ul() {
    cat > "$JT_LIST_FILE" <<'EOF'
[{"id":"2","name":"Backlog","to":"Backlog","hasScreen":false,"required":[]},
 {"id":"3","name":"In Review","to":"In Review","hasScreen":false,"required":[]},
 {"id":"4","name":"Qualifying","to":"In Qualification","hasScreen":false,"required":[]},
 {"id":"6","name":"Releasing","to":"Releasing","hasScreen":false,"required":[]},
 {"id":"31","name":"Done","to":"Done","hasScreen":false,"required":[]}]
EOF
}

# DE from "IN PROGRESS": two arrows land on "Peer Review", 41 and 5. The old code took
# whichever the board listed first.
list_de() {
    cat > "$JT_LIST_FILE" <<'EOF'
[{"id":"3","name":"PASSED QA","to":"PASSED QA","hasScreen":false,"required":[]},
 {"id":"11","name":"To Do","to":"To Do","hasScreen":false,"required":[]},
 {"id":"41","name":"Peer Review","to":"Peer Review","hasScreen":false,"required":[]},
 {"id":"5","name":"Ready for review","to":"Peer Review","hasScreen":false,"required":[]},
 {"id":"51","name":"QA","to":"QA","hasScreen":false,"required":[]}]
EOF
}

# The name/status split, isolated: the only arrow whose NAME says review lands nowhere
# near review, and the arrow that reaches "In Review" is called something else.
list_name_trap() {
    cat > "$JT_LIST_FILE" <<'EOF'
[{"id":"7","name":"Review requested","to":"Awaiting Triage","hasScreen":false,"required":[]},
 {"id":"9","name":"Hand it over","to":"In Review","hasScreen":false,"required":[]},
 {"id":"31","name":"Done","to":"Done","hasScreen":false,"required":[]}]
EOF
}

# A board with no review status anywhere in reach.
list_no_review() {
    cat > "$JT_LIST_FILE" <<'EOF'
[{"id":"11","name":"To Do","to":"To Do","hasScreen":false,"required":[]},
 {"id":"31","name":"Done","to":"Done","hasScreen":false,"required":[]}]
EOF
}

# --- the stub tool --------------------------------------------------------------------

# Answers --list from the fixture and --transition-id from the JT_* switches, and
# records every argv. Its stdout follows jira-transition's contract: progress goes to
# stderr, and the RESULT is the last line of stdout -- which is why it prints a line of
# noise first, so a reader that takes the whole of stdout for JSON is caught here.
stub_jt() {
    cat > "$STUB_DIR/jira-transition" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JT_LOG"
key="$1"
case "$2" in
    --list)
        if [ -n "$JT_LIST_FAIL" ]; then
            printf 'jira-transition could not reach Jira to look up %s (curl exit 7); nothing was changed.\n' "$key" >&2
            exit 1
        fi
        printf '%s is in a status (assignee: kylegm)\n' "$key" >&2
        cat "$JT_LIST_FILE"
        exit 0
        ;;
    --transition-id)
        if [ -n "$JT_MOVE_FAIL" ]; then
            printf '%s\n' "${JT_MOVE_MESSAGE:-jira-transition could not reach Jira to move $key (curl exit 7); the transition is unconfirmed, not done.}" >&2
            exit 1
        fi
        printf 'moved %s via transition %s\n' "$key" "$3" >&2
        if [ -n "$JT_MOVE_STDOUT_EMPTY" ]; then
            exit 0
        fi
        printf 'not the result line\n'
        printf '{"key":"%s","from":"%s","to":"%s","transition_id":"%s","transition_name":"n","dry_run":false,"url":"https://example.invalid/browse/%s"}\n' \
            "$key" "${JT_FROM:-IN PROGRESS}" "${JT_TO:-MR}" "$3" "$key"
        exit 0
        ;;
esac
printf 'the stub has no answer for: %s\n' "$*" >&2
exit 1
STUB
    chmod +x "$STUB_DIR/jira-transition"
}

# --- drivers --------------------------------------------------------------------------

# The real helpers, under `set -e`, wrapped in the call site's own if/elif so that a
# skip is visible as a skip and an abort is visible as a missing last line.
drive_move() {
    {
        echo 'set -e'
        printf 'SCRIPT_DIR=%q\n' "$STUB_DIR"
        awk '/^review_transitions\(\) \{/,/^\}/' "$PC"
        awk '/^move_ticket_to_review\(\) \{/,/^\}/' "$PC"
        echo 'if move_ticket_to_review "$1" "$2"; then echo MOVED; else echo SKIPPED; fi'
        echo 'echo CARRIED-ON'
    } > "$TEST_TMPDIR/drive.sh"
    bash "$TEST_TMPDIR/drive.sh" "$1" "$2"
}

# The arm itself, lifted whole, with the two halves stubbed. This is where "a draft
# does not move" and "a move that failed is not followed by an assignment" live.
drive_arm() {
    {
        echo 'set -e'
        echo 'move_ticket_to_review() { printf "MOVE %s\n" "$*"; return ${MOVE_RC:-0}; }'
        echo 'assign_ticket_to_me() { printf "ASSIGN %s\n" "$*"; }'
        echo 'key="$1"; current_status="$2"; is_draft="$3"'
        awk '/# 3\. Status transition and assignee/,/^    fi$/' "$PC"
        echo 'echo CARRIED-ON'
    } > "$TEST_TMPDIR/arm.sh"
    bash "$TEST_TMPDIR/arm.sh" "$1" "$2" "$3"
}

lift() {
    eval "$(awk "/^$1\\(\\) \\{/,/^\\}/" "$PC")"
}

jt_calls() {
    grep -c . "$JT_LOG" || true
}

# --- the defect: a transition's name is not the status it lands on --------------------

@test "the arrow is chosen by the status it reaches, not by what the arrow is called" {
    # The old code read the same regex over transition NAMES, so on this board it would
    # have sent id 7 -- "Review requested" -- and landed the ticket in "Awaiting Triage".
    stub_jt
    list_name_trap
    run drive_move UL-1974 "In Progress"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOVED"* ]]
    run cat "$JT_LOG"
    [ "${lines[0]}" = "UL-1974 --list" ]
    [ "${lines[1]}" = "UL-1974 --transition-id 9" ]
}

@test "UB: the review status is MR, and transition 71 is what gets sent" {
    stub_jt
    list_ub
    export JT_TO="MR"
    run drive_move UB-7028 "IN PROGRESS"
    [ "$status" -eq 0 ]
    run cat "$JT_LOG"
    [ "${lines[1]}" = "UB-7028 --transition-id 71" ]
}

@test "UL: the review status is In Review, and transition 3 is what gets sent" {
    stub_jt
    list_ul
    export JT_TO="In Review"
    run drive_move UL-1974 "In Progress"
    [ "$status" -eq 0 ]
    run cat "$JT_LOG"
    [ "${lines[1]}" = "UL-1974 --transition-id 3" ]
}

@test "the arrow onto In Qualification is never mistaken for the one onto In Review" {
    # UL id 4 is named "Qualifying" and lands on "In Qualification". Neither string is
    # a review status, and neither may be picked.
    stub_jt
    list_ul
    run drive_move UL-1974 "In Progress"
    [ "$status" -eq 0 ]
    run cat "$JT_LOG"
    [[ "${lines[1]}" != *"--transition-id 4"* ]]
}

@test "the whole exchange is --list then --transition-id, and nothing else" {
    stub_jt
    list_ub
    run drive_move UB-7028 "IN PROGRESS"
    [ "$status" -eq 0 ]
    [ "$(jt_calls)" = "2" ]
    # And publish-changes made no Jira call of its own alongside it.
    [ ! -s "$CURL_LOG" ]
}

# --- the refusals: skip, say why, and never take the run down with them ---------------

@test "no transition reaching review is said out loud and the run carries on" {
    stub_jt
    list_no_review
    run drive_move UL-1974 "In Progress"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
    [[ "$output" == *"CARRIED-ON"* ]]
    [[ "$output" == *"No transition from In Progress reaches a review status"* ]]
    # It says what the board could have been asked for instead.
    [[ "$output" == *"Done, To Do"* ]]
    [ "$(jt_calls)" = "1" ]
}

@test "DE's two arrows onto Peer Review are a refusal that names both, not a coin toss" {
    # Measured on DE from IN PROGRESS: 41 "Peer Review" and 5 "Ready for review" both
    # land on "Peer Review". The old code took the first one the board listed.
    stub_jt
    list_de
    run drive_move DE-2575 "IN PROGRESS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
    [[ "$output" == *"CARRIED-ON"* ]]
    [[ "$output" == *"2 transitions on DE-2575 reach review"* ]]
    [[ "$output" == *"41"* ]]
    [[ "$output" == *"5 (Ready for review"* ]]
    [[ "$output" == *"--transition-id"* ]]
    # Refused means not moved: no second call, and no curl of its own either.
    [ "$(jt_calls)" = "1" ]
    [ ! -s "$CURL_LOG" ]
}

@test "a --list that could not reach Jira is a failure, and no move is attempted" {
    stub_jt
    list_ub
    export JT_LIST_FAIL=1
    run drive_move UB-7028 "IN PROGRESS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
    [[ "$output" == *"CARRIED-ON"* ]]
    [[ "$output" == *"Could not read UB-7028's transitions"* ]]
    # The tool's own sentence is quoted, not swallowed.
    [[ "$output" == *"curl exit 7"* ]]
    [ "$(jt_calls)" = "1" ]
}

@test "a non-zero exit from the move is reported as a failure and never as a success" {
    stub_jt
    list_ub
    export JT_MOVE_FAIL=1
    run drive_move UB-7028 "IN PROGRESS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
    [[ "$output" == *"CARRIED-ON"* ]]
    [[ "$output" == *"Could not move UB-7028 to MR"* ]]
    [[ "$output" == *"unconfirmed, not done"* ]]
    [[ "$output" != *"Status: IN PROGRESS → MR"* ]]
}

@test "an exit 0 with nothing on stdout is not a transition" {
    # This is the old bug in its purest form: `curl -s` printed nothing when it never
    # reached the host, and the old code read that silence as a moved ticket. Here the
    # tool exits 0 and says nothing, and the arm still refuses to claim a move.
    stub_jt
    list_ub
    export JT_MOVE_STDOUT_EMPTY=1
    run drive_move UB-7028 "IN PROGRESS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
    [[ "$output" == *"without saying where UB-7028 landed"* ]]
    [[ "$output" != *"✓ Status"* ]]
}

@test "a missing jira-transition is said, skipped, and never worked around" {
    list_ub
    rm -f "$STUB_DIR/jira-transition"
    run drive_move UB-7028 "IN PROGRESS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIPPED"* ]]
    [[ "$output" == *"jira-transition not found"* ]]
    [[ "$output" == *"UB-7028 left in IN PROGRESS"* ]]
    # No fallback to the inline POST that used to live here.
    [ ! -s "$CURL_LOG" ]
    [ ! -s "$JT_LOG" ]
}

# --- what gets reported ---------------------------------------------------------------

@test "the move is reported from → to, taken from the tool's last line" {
    # jira-transition prints progress on stderr and the result as the LAST line of
    # stdout. A reader that took all of stdout would choke on the line before it.
    stub_jt
    list_ub
    export JT_FROM="IN PROGRESS"
    export JT_TO="MR"
    run drive_move UB-7028 "IN PROGRESS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Status: IN PROGRESS → MR"* ]]
}

@test "where the ticket actually landed beats where the transition said it would" {
    # A post-function can carry an issue past the status the arrow declared, and
    # jira-transition reads the status back. What is shown is that read-back.
    stub_jt
    list_ub
    export JT_FROM="IN PROGRESS"
    export JT_TO="Data QA"
    run drive_move UB-7028 "IN PROGRESS"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Status: IN PROGRESS → Data QA"* ]]
}

# --- the arm around it, unchanged ------------------------------------------------------

@test "a draft MR still moves nothing" {
    run drive_arm UB-7028 "IN PROGRESS" "true"
    [ "$status" -eq 0 ]
    [[ "$output" == *"draft MR, not moving to review"* ]]
    [[ "$output" != *"MOVE "* ]]
    [[ "$output" == *"CARRIED-ON"* ]]
}

@test "a ticket already in review is left alone without asking Jira anything" {
    run drive_arm UB-7028 "MR" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"already in review"* ]]
    [[ "$output" != *"MOVE "* ]]
    run drive_arm DE-2575 "Peer Review" ""
    [[ "$output" == *"already in review"* ]]
    [[ "$output" != *"MOVE "* ]]
}

@test "the assignment follows a move that happened, and only that" {
    run drive_arm UB-7028 "IN PROGRESS" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOVE UB-7028 IN PROGRESS"* ]]
    [[ "$output" == *"ASSIGN UB-7028"* ]]

    MOVE_RC=1 run drive_arm UB-7028 "IN PROGRESS" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"MOVE UB-7028"* ]]
    [[ "$output" != *"ASSIGN"* ]]
    [[ "$output" == *"CARRIED-ON"* ]]
}

# --- review_transitions, the rule on its own -------------------------------------------

@test "review_transitions matches to and never name" {
    lift review_transitions
    j='[{"id":"7","name":"Review requested","to":"Awaiting Triage"},{"id":"9","name":"Hand it over","to":"In Review"}]'
    run bash -c 'printf "%s" "$1" | jq -r .id' _ "$(review_transitions "$j")"
    [ "${lines[0]}" = "9" ]
}

@test "review_transitions knows all three boards' spellings of the same idea" {
    lift review_transitions
    for pair in 'MR|71' 'In Review|3' 'Peer Review|41'; do
        st="${pair%%|*}"
        id="${pair##*|}"
        j="[{\"id\":\"$id\",\"name\":\"whatever\",\"to\":\"$st\"}]"
        run bash -c 'printf "%s" "$1" | jq -r .id' _ "$(review_transitions "$j")"
        [ "${lines[0]}" = "$id" ]
    done
}

@test "review_transitions yields nothing when no status is a review status" {
    lift review_transitions
    [ -z "$(review_transitions '[{"id":"11","name":"To Do","to":"To Do"}]')" ]
    [ -z "$(review_transitions '[{"id":"4","name":"Qualifying","to":"In Qualification"}]')" ]
}

@test "review_transitions yields every match, so several can be refused" {
    lift review_transitions
    j='[{"id":"41","name":"Peer Review","to":"Peer Review"},{"id":"5","name":"Ready for review","to":"Peer Review"}]'
    run bash -c 'printf "%s\n" "$1" | grep -c .' _ "$(review_transitions "$j")"
    [ "${lines[0]}" = "2" ]
}

@test "a transitions payload that is not JSON yields nothing rather than blowing up" {
    lift review_transitions
    [ -z "$(review_transitions 'not json at all')" ]
    [ -z "$(review_transitions '')" ]
}

# --- structural: the inline transition is gone, not merely bypassed --------------------

@test "publish-changes POSTs no transition of its own" {
    run bash -c "grep -nE 'issue/[^\"]*/transitions' \"\$1\" || true" _ "$PC"
    [ -z "$output" ]
}

@test "no Jira write in the status arm is judged by an empty stdout" {
    run bash -c "grep -nE 'if \\[ -z \"\\\$transition_result\"' \"\$1\" || true" _ "$PC"
    [ -z "$output" ]
    run bash -c "grep -c 'mr_transition_id' \"\$1\" || true" _ "$PC"
    [ "${lines[0]}" = "0" ]
}

@test "the status regex is applied to the destination and to nothing else" {
    run bash -c "awk '/^review_transitions\\(\\) \\{/,/^\\}/' \"\$1\" | grep -c 'select(((.to)' " _ "$PC"
    [ "${lines[0]}" = "1" ]
    run bash -c "awk '/^review_transitions\\(\\) \\{/,/^\\}/' \"\$1\" | grep -c '.name | test' || true" _ "$PC"
    [ "${lines[0]}" = "0" ]
}

@test "the move helper reaches Jira only through the tool" {
    run bash -c "awk '/^move_ticket_to_review\\(\\) \\{/,/^\\}/' \"\$1\" | grep -nE 'curl|atlassian.net|JIRA_API_TOKEN' || true" _ "$PC"
    [ -z "$output" ]
}

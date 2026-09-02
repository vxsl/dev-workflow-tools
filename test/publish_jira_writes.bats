#!/usr/bin/env bats

# Tests for the two Jira WRITES publish-changes still makes itself: the QA-branch field
# PUT and the assignee PUT.
#
# NOTHING HERE REACHES JIRA. Every request goes through a curl shim on PATH that answers
# from switches and records what it was asked for. A test that set a real QA branch to
# prove it could set one would leave Kyle's board wrong every time it ran.
#
# THE DEFECT THESE PIN. Both writes used to be judged by the emptiness of curl's stdout:
#
#     local qa_field_result=$(curl -s ... -X PUT ...)
#     if [ -z "$qa_field_result" ]; then  ... reported as set ...
#
# A 204 prints nothing. A curl that never reached the host prints nothing either. So an
# outage was reported here as a QA branch that had been written and a ticket that had
# been assigned -- in green, with a tick. This is the same defect the status move was
# rewritten to remove (f0b2861), and these two were the last of its kind in the file.
#
# What is asserted is that the two outcomes now look different: the body goes to a file
# and the response CODE comes back on stdout, so success is curl's exit status plus a
# 2xx and nothing else. And that a failure is one line that says WHICH write failed and
# what Jira said, after which the run carries on -- the MR exists by the time either of
# these is reached, and a field that did not take must never unwind it.
#
# The shim honours -o and -w the way real curl does -- body to the file, code to stdout.
# A stub that printed the body to stdout would let the old bug pass.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    PC="$REPO_ROOT/bin/publish-changes"
    TEST_TMPDIR=$(mktemp -d)
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"

    export JIRA_EMAIL="test@test"
    export JIRA_API_TOKEN="notatoken"
    export JIRA_DOMAIN="example.invalid"
    export JIRA_QA_BRANCH_DOMAIN="qa.example.invalid"
    export JIRA_QA_BRANCH_FIELD="customfield_10100"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# --- the shim -------------------------------------------------------------------------

stub_curl() {
    STUB_DIR="$TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    export CURL_RECORD="$TEST_TMPDIR/curl.record"
    export CURL_ARGV="$TEST_TMPDIR/curl.argv"
    export STUB_QA_DATA="$TEST_TMPDIR/qa.data"
    export STUB_ASSIGN_DATA="$TEST_TMPDIR/assign.data"
    : > "$CURL_RECORD"
    : > "$CURL_ARGV"
    : > "$STUB_QA_DATA"
    : > "$STUB_ASSIGN_DATA"

    cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
method=GET
url=""
out=""
data=""
want_code=""
prev=""
for a in "$@"; do
    case "$prev" in
        -X) method="$a" ;;
        -o) out="$a" ;;
        -d) data="$a" ;;
        -w) want_code="$a" ;;
    esac
    case "$a" in
        https://*) url="$a" ;;
    esac
    prev="$a"
done
printf '%s %s\n' "$method" "$url" >> "$CURL_RECORD"
printf '%s\n' "$*" >> "$CURL_ARGV"

put_body() {
    if [ -n "$out" ]; then printf '%s' "$1" > "$out"; else printf '%s' "$1"; fi
}
put_code() {
    if [ -n "$want_code" ]; then printf '%s' "$1"; fi
}
answer() { put_body "$1"; put_code "${2:-200}"; }

case "$method $url" in
    "GET "*"/myself"*)   answer "$STUB_MYSELF_BODY" ; exit 0 ;;
    *" "*"/comment"*)    answer "$STUB_COMMENT_BODY" ; exit 0 ;;
    "GET "*"/editmeta"*) answer '{"fields":{}}' ; exit 0 ;;
    "GET "*"/issue/"*)   answer "$STUB_ISSUE_BODY" ; exit 0 ;;
    "PUT "*"/issue/"*)
        case "$data" in
            *'"assignee"'*)
                printf '%s' "$data" > "$STUB_ASSIGN_DATA"
                mode="$STUB_ASSIGN_MODE"; code="$STUB_ASSIGN_CODE"
                body="$STUB_ASSIGN_BODY"; rc="$STUB_ASSIGN_EXIT"
                ;;
            *)
                printf '%s' "$data" > "$STUB_QA_DATA"
                mode="$STUB_QA_MODE"; code="$STUB_QA_CODE"
                body="$STUB_QA_BODY"; rc="$STUB_QA_EXIT"
                ;;
        esac
        case "$mode" in
            connfail)
                # Real curl with -o FILE -w '%{http_code}' on a connection failure:
                # nothing in the body file, 000 on stdout, its own exit status. This is
                # the case the old empty-stdout test could not tell from a 204.
                put_body ""
                put_code "000"
                exit "${rc:-7}"
                ;;
            silent)
                # Nothing on stdout at all and exit 0 -- literally the condition the old
                # code read as a completed write.
                put_body ""
                exit 0
                ;;
            *)
                put_body "$body"
                put_code "${code:-204}"
                exit 0
                ;;
        esac
        ;;
esac
put_body '{"errorMessages":["the stub has no route for that"]}'
put_code "404"
exit 0
STUB
    chmod +x "$STUB_DIR/curl"
    PATH="$STUB_DIR:$PATH"
    export PATH

    export STUB_ISSUE_BODY='{"fields":{"status":{"name":"IN PROGRESS"}}}'
    export STUB_MYSELF_BODY='{"accountId":"5f0abc"}'
    export STUB_COMMENT_BODY='{"id":"10001"}'
    export STUB_QA_MODE=""
    export STUB_QA_CODE=204
    export STUB_QA_BODY=""
    export STUB_QA_EXIT=7
    export STUB_ASSIGN_MODE=""
    export STUB_ASSIGN_CODE=204
    export STUB_ASSIGN_BODY=""
    export STUB_ASSIGN_EXIT=7
}

# --- drivers --------------------------------------------------------------------------

# The real update_jira_ticket, under `set -e` the way the script runs it, with only the
# two things that are not this file's subject stubbed out: the credential check and the
# status move. Everything the writes touch is the code from bin/publish-changes.
drive_update() {
    {
        echo 'set -e'
        echo 'GREEN=""; RED=""; YELLOW=""; CYAN=""; BLUE=""; DIM=""; RESET=""'
        echo 'has_jira_credentials() { return 0; }'
        echo 'is_interactive() { return 1; }'
        echo 'move_ticket_to_review() { return "${MOVE_RC:-0}"; }'
        awk '/^jira_write\(\) \{/,/^\}/' "$PC"
        awk '/^jira_error_text\(\) \{/,/^\}/' "$PC"
        awk '/^jira_write_reason\(\) \{/,/^\}/' "$PC"
        awk '/^assign_ticket_to_me\(\) \{/,/^\}/' "$PC"
        awk '/^update_jira_ticket\(\) \{/,/^\}/' "$PC"
        echo 'update_jira_ticket "$1" "$2" "$3" "$4"'
        echo 'echo CARRIED-ON'
    } > "$TEST_TMPDIR/update.sh"
    bash "$TEST_TMPDIR/update.sh" "$@" 2>&1
}

drive_assign() {
    {
        echo 'set -e'
        echo 'GREEN=""; RED=""; RESET=""'
        awk '/^jira_write\(\) \{/,/^\}/' "$PC"
        awk '/^jira_error_text\(\) \{/,/^\}/' "$PC"
        awk '/^jira_write_reason\(\) \{/,/^\}/' "$PC"
        awk '/^assign_ticket_to_me\(\) \{/,/^\}/' "$PC"
        echo 'assign_ticket_to_me "$1"'
        echo 'echo CARRIED-ON'
    } > "$TEST_TMPDIR/assign.sh"
    bash "$TEST_TMPDIR/assign.sh" "$1" 2>&1
}

lift_write() {
    eval "$(awk '/^jira_write\(\) \{/,/^\}/' "$PC")"
    eval "$(awk '/^jira_error_text\(\) \{/,/^\}/' "$PC")"
    eval "$(awk '/^jira_write_reason\(\) \{/,/^\}/' "$PC")"
}

puts() {
    grep -c '^PUT ' "$CURL_RECORD" || true
}

# --- the QA branch field write ---------------------------------------------------------

@test "a 204 on the QA branch field write is the one thing reported as set" {
    stub_curl
    run drive_update UB-7028 "https://gl/mr/1" "feature/x" "draft"
    [ "$status" -eq 0 ]
    [[ "$output" == *"QA Branch: qa.example.invalid/branch/feature/x"* ]]
    [[ "$output" != *"Could not set"* ]]
    [ "$(puts)" = "1" ]
}

@test "the QA write still sends the body it always sent, byte for byte" {
    stub_curl
    run drive_update UB-7028 "https://gl/mr/1" "feature/x" "draft"
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_QA_DATA")" = '{"fields": {"customfield_10100": "qa.example.invalid/branch/feature/x"}}' ]
}

@test "the QA write asks curl for the response code instead of reading the body" {
    stub_curl
    run drive_update UB-7028 "https://gl/mr/1" "feature/x" "draft"
    [ "$status" -eq 0 ]
    run bash -c 'grep -F -- "-X PUT" "$1" | grep -cF -- "-w %{http_code}"' _ "$CURL_ARGV"
    [ "${lines[0]}" = "1" ]
    run bash -c 'grep -F -- "-X PUT" "$1" | grep -cF -- "-o "' _ "$CURL_ARGV"
    [ "${lines[0]}" = "1" ]
}

@test "a 400 names the field write, quotes Jira, and the run reaches the assignee" {
    stub_curl
    STUB_QA_CODE=400
    STUB_QA_BODY='{"errorMessages":["Field '\''customfield_10100'\'' cannot be set."],"errors":{}}'
    run drive_update UB-7028 "https://gl/mr/1" "feature/x" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"QA Branch: Could not set customfield_10100"* ]]
    [[ "$output" == *"HTTP 400"* ]]
    [[ "$output" == *"cannot be set"* ]]
    # Not reported as written, in any form.
    [[ "$output" != *"QA Branch: qa.example.invalid/branch/feature/x"* ]]
    # And the failure stopped nothing: the assignment happened and the run carried on.
    [[ "$output" == *"Assignee: Assigned to you"* ]]
    [[ "$output" == *"CARRIED-ON"* ]]
}

@test "Jira's errors map is quoted as well as its errorMessages list" {
    stub_curl
    STUB_QA_CODE=400
    STUB_QA_BODY='{"errorMessages":[],"errors":{"customfield_10100":"not on the appropriate screen"}}'
    run drive_update UB-7028 "https://gl/mr/1" "feature/x" "draft"
    [ "$status" -eq 0 ]
    [[ "$output" == *"customfield_10100: not on the appropriate screen"* ]]
    [[ "$output" == *"Could not set"* ]]
}

@test "a curl that never connected on the QA write is a failure, not a success" {
    # THE DEFECT. curl exits 7 having printed nothing, and the old code called that set.
    stub_curl
    STUB_QA_MODE=connfail
    STUB_QA_EXIT=7
    run drive_update UB-7028 "https://gl/mr/1" "feature/x" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"QA Branch: Could not set"* ]]
    [[ "$output" == *"curl exit 7"* ]]
    [[ "$output" != *"QA Branch: qa.example.invalid/branch/feature/x"* ]]
    [[ "$output" == *"CARRIED-ON"* ]]
}

@test "empty stdout with exit 0 and no code is not a written QA field" {
    # The old condition in its purest form: nothing came back, and nothing came back is
    # not a 204.
    stub_curl
    STUB_QA_MODE=silent
    run drive_update UB-7028 "https://gl/mr/1" "feature/x" "draft"
    [ "$status" -eq 0 ]
    [[ "$output" == *"QA Branch: Could not set"* ]]
    [[ "$output" == *"curl returned no HTTP code"* ]]
    [[ "$output" != *"QA Branch: qa.example.invalid/branch/feature/x"* ]]
}

@test "a QA field already holding the wanted value is still left unwritten" {
    stub_curl
    STUB_ISSUE_BODY='{"fields":{"status":{"name":"IN PROGRESS"},"customfield_10100":"qa.example.invalid/branch/feature/x"}}'
    run drive_update UB-7028 "https://gl/mr/1" "feature/x" "draft"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already set"* ]]
    [ "$(puts)" = "0" ]
}

# --- the assignee write -----------------------------------------------------------------

@test "a 204 on the assignee write is the one thing reported as assigned" {
    stub_curl
    run drive_assign UB-7028
    [ "$status" -eq 0 ]
    [[ "$output" == *"Assignee: Assigned to you"* ]]
    [[ "$output" != *"Could not assign"* ]]
    [ "$(puts)" = "1" ]
}

@test "the assignee write still sends the body it always sent, byte for byte" {
    stub_curl
    run drive_assign UB-7028
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_ASSIGN_DATA")" = '{"fields": {"assignee": {"accountId": "5f0abc"}}}' ]
}

@test "a 403 names the assignment, quotes Jira, and the run carries on" {
    stub_curl
    STUB_ASSIGN_CODE=403
    STUB_ASSIGN_BODY='{"errorMessages":["You do not have permission to assign issues."],"errors":{}}'
    run drive_assign UB-7028
    [ "$status" -eq 0 ]
    [[ "$output" == *"Assignee: Could not assign UB-7028 to you"* ]]
    [[ "$output" == *"HTTP 403"* ]]
    [[ "$output" == *"do not have permission"* ]]
    [[ "$output" != *"Assigned to you"* ]]
    [[ "$output" == *"CARRIED-ON"* ]]
}

@test "a curl that never connected on the assignee write is a failure, not a success" {
    stub_curl
    STUB_ASSIGN_MODE=connfail
    STUB_ASSIGN_EXIT=7
    run drive_assign UB-7028
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not assign UB-7028 to you"* ]]
    [[ "$output" == *"curl exit 7"* ]]
    [[ "$output" != *"Assigned to you"* ]]
    [[ "$output" == *"CARRIED-ON"* ]]
}

@test "empty stdout with exit 0 and no code is not an assignment" {
    stub_curl
    STUB_ASSIGN_MODE=silent
    run drive_assign UB-7028
    [ "$status" -eq 0 ]
    [[ "$output" == *"Could not assign UB-7028 to you"* ]]
    [[ "$output" == *"curl returned no HTTP code"* ]]
    [[ "$output" != *"Assigned to you"* ]]
}

@test "no account id means no PUT and nothing claimed, exactly as before" {
    stub_curl
    STUB_MYSELF_BODY='{}'
    run drive_assign UB-7028
    [ "$status" -eq 0 ]
    [ "$(puts)" = "0" ]
    [[ "$output" != *"Assigned to you"* ]]
    [[ "$output" == *"CARRIED-ON"* ]]
}

# --- jira_write, the rule on its own ------------------------------------------------------

@test "jira_write calls 2xx a success and every other code a failure" {
    stub_curl
    lift_write
    local url="https://${JIRA_DOMAIN}/rest/api/3/issue/UB-7028"
    for code in 200 201 204; do
        STUB_QA_CODE="$code"
        run jira_write PUT "$url" '{"fields": {"x": "y"}}'
        [ "$status" -eq 0 ]
    done
    for code in 400 401 403 404 409 500 502; do
        STUB_QA_CODE="$code"
        run jira_write PUT "$url" '{"fields": {"x": "y"}}'
        [ "$status" -ne 0 ]
    done
}

@test "jira_write fails on curl's exit status even when a code came back" {
    stub_curl
    lift_write
    STUB_QA_MODE=connfail
    STUB_QA_EXIT=28
    run jira_write PUT "https://${JIRA_DOMAIN}/rest/api/3/issue/UB-7028" '{"fields": {"x": "y"}}'
    [ "$status" -ne 0 ]
}

@test "jira_write reports curl's own exit status and not a made-up one" {
    stub_curl
    lift_write
    STUB_QA_MODE=connfail
    STUB_QA_EXIT=6
    jira_write PUT "https://${JIRA_DOMAIN}/rest/api/3/issue/UB-7028" '{"fields": {"x": "y"}}' || true
    [ "$JIRA_WRITE_RC" = "6" ]
    run jira_write_reason
    [ "${lines[0]}" = "curl exit 6" ]
}

@test "jira_error_text says nothing when the body is not JSON or carries no message" {
    stub_curl
    lift_write
    [ -z "$(jira_error_text '<html>502 Bad Gateway</html>')" ]
    [ -z "$(jira_error_text '')" ]
    [ -z "$(jira_error_text '{"errorMessages":[],"errors":{}}')" ]
}

@test "jira_write sends no Content-Type and no body when there is nothing to send" {
    stub_curl
    lift_write
    run jira_write GET "https://${JIRA_DOMAIN}/rest/api/3/myself"
    [ "$status" -eq 0 ]
    run bash -c 'grep -cF -- "-d " "$1" || true' _ "$CURL_ARGV"
    [ "${lines[0]}" = "0" ]
}

# --- structural: the empty-stdout verdict is gone, not merely bypassed ---------------------

@test "no write in update_jira_ticket is judged by the emptiness of curl's stdout" {
    # General, not a spelling check: every variable this function fills from a curl is
    # looked up, and none of them may be the subject of an emptiness test. That shape --
    # `[ -z "$something_result" ]` after a PUT -- is the whole defect.
    body=$(awk '/^update_jira_ticket\(\) \{/,/^\}/' "$PC")
    offenders=""
    for v in $(printf '%s\n' "$body" | grep -oE '[A-Za-z_][A-Za-z_0-9]*=\$\(curl' | sed -E 's/=\$\(curl$//'); do
        if printf '%s\n' "$body" | grep -qF "[ -z \"\$${v}\""; then
            offenders="$offenders $v"
        fi
    done
    [ -z "$offenders" ]
    # And the two variables that carried the defect are gone from the file entirely.
    run bash -c 'grep -c "qa_field_result" "$1" || true' _ "$PC"
    [ "${lines[0]}" = "0" ]
}

@test "no write in assign_ticket_to_me is judged by the emptiness of curl's stdout" {
    # The one emptiness test left in this function is `-n "$current_user_id"`, a guard
    # BEFORE a write -- no id, no PUT -- and never a verdict on one.
    body=$(awk '/^assign_ticket_to_me\(\) \{/,/^\}/' "$PC")
    offenders=""
    for v in $(printf '%s\n' "$body" | grep -oE '[A-Za-z_][A-Za-z_0-9]*=\$\(curl' | sed -E 's/=\$\(curl$//'); do
        if printf '%s\n' "$body" | grep -qF "[ -z \"\$${v}\""; then
            offenders="$offenders $v"
        fi
    done
    [ -z "$offenders" ]
    run bash -c 'grep -c "assign_result" "$1" || true' _ "$PC"
    [ "${lines[0]}" = "0" ]
}

@test "both writes go through jira_write and neither builds a PUT of its own" {
    run bash -c 'awk "/^update_jira_ticket\(\) \{/,/^\}/" "$1" | grep -c "jira_write PUT"' _ "$PC"
    [ "${lines[0]}" = "1" ]
    run bash -c 'awk "/^assign_ticket_to_me\(\) \{/,/^\}/" "$1" | grep -c "jira_write PUT"' _ "$PC"
    [ "${lines[0]}" = "1" ]
    # No hand-rolled PUT is left anywhere in the script.
    run bash -c 'grep -cF -- "-X PUT" "$1" || true' _ "$PC"
    [ "${lines[0]}" = "0" ]
}

@test "jira_write judges the code and curl's status, and reads no body to decide" {
    body=$(awk '/^jira_write\(\) \{/,/^\}/' "$PC")
    printf '%s\n' "$body" | grep -qF "%{http_code}"
    printf '%s\n' "$body" | grep -qF -- '-o "$body_file"'
    # curl's exit status is captured on the right of || so `local` can never mask it.
    printf '%s\n' "$body" | grep -qF 'JIRA_WRITE_CODE=$(curl'
    # The body is never what says yes.
    ! printf '%s\n' "$body" | grep -qF '[ -z "$JIRA_WRITE_BODY"'
}

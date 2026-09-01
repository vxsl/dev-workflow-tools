#!/usr/bin/env bats

# Tests for bin/jira-transition.
#
# NOTHING HERE REACHES JIRA. Every run goes through a curl shim on PATH that answers
# from fixtures and records what it was asked for, so the suite can assert the thing
# that actually matters about a write tool: that the runs which must not POST did not
# POST. A test that moved a real ticket to prove it could move a ticket would leave
# Kyle's board wrong every time it ran.
#
# The rules with judgement in them -- which transition a status name resolves to, which
# fields a transition demands, what the result JSON looks like -- are lifted verbatim
# out of the script with awk and run against fixtures, the way ticket_non_interactive
# lifts estimate_field_ids. What gets exercised is the branch, not a copy of it.
#
# The fixture list is shaped like UL's real one, measured 2026-09-01: nine transitions,
# including the pair that is the whole reason this tool exists -- id 4 is NAMED
# "Qualifying" and lands on the status "In Qualification".

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    TEST_TMPDIR=$(mktemp -d)
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    # lib/jira-curl.sh stages credentials into XDG_RUNTIME_DIR. Pointed at the test's
    # own tree so a run here can never overwrite the developer's live curl config with
    # this file's fake token.
    export XDG_RUNTIME_DIR="$TEST_TMPDIR/xdg"
    mkdir -p "$XDG_RUNTIME_DIR"
    JT="$REPO_ROOT/bin/jira-transition"
    STDOUT_FILE="$TEST_TMPDIR/stdout.txt"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# A tools tree with its own .env, so a run never depends on the developer's credentials
# and can never be pointed at a real board. No JIRA_PROJECT: the key names its own
# project, and requiring one would be this tool asking for a board it never uses.
build_fake_tools() {
    FAKE_ROOT="$TEST_TMPDIR/tools"
    mkdir -p "$FAKE_ROOT/bin"
    cp -r "$REPO_ROOT/lib" "$FAKE_ROOT/lib"
    cp "$JT" "$FAKE_ROOT/bin/jira-transition"
    cat > "$FAKE_ROOT/.env" <<'EOF'
JIRA_DOMAIN=example.invalid
JIRA_EMAIL=test@test
JIRA_API_TOKEN=notatoken
EOF
}

# UL's list, shaped as Jira returns it with expand=transitions.fields.
#   id 4  "Qualifying"       -> "In Qualification"   the name/status mismatch
#   id 31 "Ready for review" -> "Peer Review"        the same mismatch again
#   id 51 "Done"             -> "Done"               hasScreen: true
#   id 61 "Blocked"          -> "Blocked"            no screen, but a required field
write_fixtures() {
    export STUB_ISSUE="$TEST_TMPDIR/issue.json"
    export STUB_ISSUE_AFTER="$TEST_TMPDIR/issue_after.json"
    export STUB_TRANSITIONS="$TEST_TMPDIR/transitions.json"
    export STUB_RECORD="$TEST_TMPDIR/record.txt"
    export STUB_ARGV="$TEST_TMPDIR/argv.txt"
    : > "$STUB_RECORD"
    : > "$STUB_ARGV"

    cat > "$STUB_ISSUE" <<'EOF'
{"key":"UL-1797","fields":{"status":{"name":"To Do"},"assignee":{"displayName":"Kyle Grimsrud-Manz","accountId":"5f0abc"}}}
EOF
    cat > "$STUB_ISSUE_AFTER" <<'EOF'
{"key":"UL-1797","fields":{"status":{"name":"In Qualification"},"assignee":{"displayName":"Kyle Grimsrud-Manz","accountId":"5f0abc"}}}
EOF
    cat > "$STUB_TRANSITIONS" <<'EOF'
{"expand":"transitions","transitions":[
 {"id":"11","name":"To Do","to":{"name":"To Do","id":"10000"},"hasScreen":false,"fields":{}},
 {"id":"4","name":"Qualifying","to":{"name":"In Qualification","id":"10101"},"hasScreen":false,"fields":{}},
 {"id":"21","name":"In Progress","to":{"name":"In Progress","id":"3"},"hasScreen":false,"fields":{}},
 {"id":"31","name":"Ready for review","to":{"name":"Peer Review","id":"10102"},"hasScreen":false,"fields":{}},
 {"id":"41","name":"Ready for QA","to":{"name":"QA","id":"10103"},"hasScreen":false,"fields":{}},
 {"id":"51","name":"Done","to":{"name":"Done","id":"10104"},"hasScreen":true,"fields":{"resolution":{"required":true,"name":"Resolution"}}},
 {"id":"61","name":"Blocked","to":{"name":"Blocked","id":"10105"},"hasScreen":false,"fields":{"customfield_10050":{"required":true,"name":"Blocked reason"},"summary":{"required":false,"name":"Summary"}}},
 {"id":"71","name":"Deploying","to":{"name":"In Deployment","id":"10106"},"hasScreen":false,"fields":{}},
 {"id":"81","name":"Backlog","to":{"name":"Backlog","id":"10107"},"hasScreen":false,"fields":{}}
]}
EOF
}

# The shim. It honours -o/-w the way curl does -- body to the file, response code to
# stdout -- because that split is the whole point of the script under test, and a stub
# that printed the body to stdout would let the old empty-stdout-is-success bug pass.
stub_curl() {
    STUB_DIR="$TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
method=GET
url=""
out=/dev/null
data=""
prev=""
for a in "$@"; do
    case "$prev" in
        -X) method="$a" ;;
        -o) out="$a" ;;
        -d) data="$a" ;;
    esac
    case "$a" in
        https://*) url="$a" ;;
    esac
    prev="$a"
done
printf '%s %s %s\n' "$method" "$url" "$data" >> "$STUB_RECORD"
printf '%s\n' "$*" >> "$STUB_ARGV"

# A curl that never connected writes no body, prints 000, and exits with its own
# status. This is the case publish-changes could not tell from success.
if [ -n "$STUB_FAIL_METHOD" ] && [ "$method" = "$STUB_FAIL_METHOD" ]; then
    : > "$out"
    printf '000'
    exit "${STUB_FAIL_EXIT:-7}"
fi

case "$method $url" in
    "GET "*"/transitions"*)
        cat "$STUB_TRANSITIONS" > "$out"
        printf '%s' "${STUB_TRANSITIONS_CODE:-200}"
        ;;
    "GET "*"/issue/"*)
        # STUB_READBACK_CODE only applies once a POST has landed, which is how a test
        # makes the confirming GET fail while the opening one succeeded.
        if [ -f "${STUB_RECORD}.posted" ] && [ -n "$STUB_READBACK_CODE" ]; then
            printf '%s' '{"errorMessages":["Internal server error"]}' > "$out"
            printf '%s' "$STUB_READBACK_CODE"
        else
            cat "$STUB_ISSUE" > "$out"
            printf '%s' "${STUB_ISSUE_CODE:-200}"
        fi
        ;;
    "POST "*"/transitions"*)
        printf '%s' "$STUB_POST_BODY" > "$out"
        code="${STUB_POST_CODE:-204}"
        # A real 204 changes what the next GET says. Modelling that is how the test
        # can tell a status that was confirmed from one that was merely declared.
        if [ "$code" = "204" ]; then
            : > "${STUB_RECORD}.posted"
            if [ -s "$STUB_ISSUE_AFTER" ]; then
                cat "$STUB_ISSUE_AFTER" > "$STUB_ISSUE"
            fi
        fi
        printf '%s' "$code"
        ;;
    *)
        printf '%s' '{"errorMessages":["the stub has no route for that"]}' > "$out"
        printf '404'
        ;;
esac
STUB
    chmod +x "$STUB_DIR/curl"
    PATH="$STUB_DIR:$PATH"
    export PATH
    export STUB_POST_BODY=""
    export STUB_POST_CODE=204
    export STUB_ISSUE_CODE=200
    export STUB_TRANSITIONS_CODE=200
    export STUB_FAIL_METHOD=""
    export STUB_FAIL_EXIT=7
    export STUB_READBACK_CODE=""
}

fixture_world() {
    build_fake_tools
    write_fixtures
    stub_curl
}

# stdout goes to a file and stderr to the caller's stdout, so a test can assert on the
# refusal sentence and on the emptiness of stdout in the same run. "No JSON on stdout"
# is half the contract and it is invisible when the two streams are merged.
jt() {
    : > "$TEST_TMPDIR/stdout.txt"
    "$FAKE_ROOT/bin/jira-transition" "$@" 2>&1 >"$TEST_TMPDIR/stdout.txt"
}

posted() {
    grep -c '^POST ' "$STUB_RECORD" || true
}

# --- the defect this tool exists for: a transition's name is not a status name --------

@test "asking for the STATUS 'In Qualification' sends the transition NAMED 'Qualifying'" {
    # THE BUG THIS EXISTS TO PIN. publish-changes matched a regex against transition
    # names, so a caller could only ask for arrows it had memorised. UL id 4 is called
    # "Qualifying" and lands on "In Qualification"; only one of those two strings is
    # something a caller can know.
    fixture_world
    run jt UL-1797 --to "In Qualification"
    [ "$status" -eq 0 ]
    grep -q '"transition":{"id":"4"}' "$STUB_RECORD"
    run python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).read().strip().splitlines()[-1]); print(d["transition_id"], d["transition_name"])' "$TEST_TMPDIR/stdout.txt"
    [ "${lines[0]}" = "4 Qualifying" ]
}

@test "asking for the transition's own name is refused, because no status is called that" {
    fixture_world
    run jt UL-1797 --to "Qualifying"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no transition on UL-1797 reaches \"Qualifying\""* ]]
    # And it says what the caller could have asked for instead.
    [[ "$output" == *"In Qualification"* ]]
    [ "$(posted)" = "0" ]
    [ ! -s "$TEST_TMPDIR/stdout.txt" ]
}

@test "the status match is case-insensitive, because casing is the board's business" {
    fixture_world
    run jt UL-1797 --to "in qualification"
    [ "$status" -eq 0 ]
    grep -q '"transition":{"id":"4"}' "$STUB_RECORD"
}

@test "a status this board cannot reach at all is a refusal that lists what it can" {
    # UL has no ABANDONED status anywhere in its workflow. "Nothing reaches that" is a
    # real answer here, not a typo, and the refusal has to be usable as the next
    # question rather than as a dead end.
    fixture_world
    run jt UL-1797 --to "Abandoned"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Abandoned"* ]]
    [[ "$output" == *"Peer Review"* ]]
    [ "$(posted)" = "0" ]
}

@test "two transitions onto one status is a refusal, not a coin toss" {
    fixture_world
    cat > "$STUB_TRANSITIONS" <<'EOF'
{"transitions":[
 {"id":"51","name":"Done","to":{"name":"Done"},"hasScreen":false,"fields":{}},
 {"id":"52","name":"Close as duplicate","to":{"name":"Done"},"hasScreen":false,"fields":{}}
]}
EOF
    run jt UL-1797 --to "Done"
    [ "$status" -eq 1 ]
    [[ "$output" == *"51"* ]]
    [[ "$output" == *"52"* ]]
    [[ "$output" == *"--transition-id"* ]]
    [ "$(posted)" = "0" ]
}

# --- --expect: the guard against a caller acting on a stale reading -------------------

@test "--expect that does not match the live status refuses before any POST" {
    # A cockpit that looked at Jira at 09:14 and acts at 17:00 must not apply an
    # eight-hour-old decision to a status somebody has since changed.
    fixture_world
    run jt UL-1797 --to "In Qualification" --expect "In Progress"
    [ "$status" -eq 1 ]
    [ "$(posted)" = "0" ]
    [ ! -s "$TEST_TMPDIR/stdout.txt" ]
}

@test "the --expect refusal says both statuses, so the caller can show what changed" {
    fixture_world
    run jt UL-1797 --to "In Qualification" --expect "In Progress"
    [[ "$output" == *"\"To Do\""* ]]
    [[ "$output" == *"\"In Progress\""* ]]
}

@test "--expect that matches gets out of the way" {
    fixture_world
    run jt UL-1797 --to "In Qualification" --expect "To Do"
    [ "$status" -eq 0 ]
    [ "$(posted)" = "1" ]
}

# --- transitions this script cannot satisfy -------------------------------------------

@test "a transition with a screen is refused before any POST" {
    # There is nobody here to fill a screen in. Sending it anyway either fails with a
    # 400 the caller has to decode or lands the issue half-configured.
    fixture_world
    run jt UL-1797 --to "Done"
    [ "$status" -eq 1 ]
    [[ "$output" == *"screen"* ]]
    [ "$(posted)" = "0" ]
    [ ! -s "$TEST_TMPDIR/stdout.txt" ]
}

@test "a required field is refused by name, screen or no screen" {
    fixture_world
    run jt UL-1797 --to "Blocked"
    [ "$status" -eq 1 ]
    [[ "$output" == *"customfield_10050"* ]]
    # A field that is present but not required is not a reason to refuse.
    [[ "$output" != *"summary"* ]]
    [ "$(posted)" = "0" ]
}

@test "--transition-id does not buy past the screen check" {
    # Naming an id skips the name matching. It does not authorise a write that cannot
    # be satisfied, so the same refusal fires on the same transition.
    fixture_world
    run jt UL-1797 --transition-id 51
    [ "$status" -eq 1 ]
    [[ "$output" == *"screen"* ]]
    [ "$(posted)" = "0" ]
}

@test "an id the issue does not currently offer is refused, not POSTed hopefully" {
    fixture_world
    run jt UL-1797 --transition-id 999
    [ "$status" -eq 1 ]
    [[ "$output" == *"999"* ]]
    [ "$(posted)" = "0" ]
}

@test "--transition-id names the transition directly and sends exactly it" {
    fixture_world
    run jt UL-1797 --transition-id 31
    [ "$status" -eq 0 ]
    grep -q '"transition":{"id":"31"}' "$STUB_RECORD"
}

# --- the write, judged on the status code and never on an empty body ------------------

@test "a 204 yields the result contract on the last line of stdout and exit 0" {
    fixture_world
    run jt UL-1797 --to "In Qualification"
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
print(list(d))
print(d["key"], d["from"], d["to"], d["transition_id"], d["transition_name"], d["dry_run"], d["url"])' \
        "$TEST_TMPDIR/stdout.txt"
    [ "${lines[0]}" = "['key', 'from', 'to', 'transition_id', 'transition_name', 'dry_run', 'url']" ]
    [ "${lines[1]}" = "UL-1797 To Do In Qualification 4 Qualifying False https://example.invalid/browse/UL-1797" ]
}

@test "the status reported is the one read back, not the one the workflow declared" {
    # A post-function can carry the issue past the status the transition named. What a
    # caller shows its operator should be what Jira says now.
    fixture_world
    cat > "$STUB_ISSUE_AFTER" <<'EOF'
{"key":"UL-1797","fields":{"status":{"name":"In Deployment"},"assignee":null}}
EOF
    run jt UL-1797 --to "In Qualification"
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])["to"])' "$TEST_TMPDIR/stdout.txt"
    [ "${lines[0]}" = "In Deployment" ]
}

@test "a 400 carries Jira's own words to stderr, prints no JSON, and exits non-zero" {
    fixture_world
    export STUB_POST_CODE=400
    export STUB_POST_BODY='{"errorMessages":["Transition is not valid for this issue."],"errors":{}}'
    run jt UL-1797 --to "In Qualification"
    [ "$status" -eq 1 ]
    [[ "$output" == *"400"* ]]
    [[ "$output" == *"Transition is not valid for this issue."* ]]
    [ ! -s "$TEST_TMPDIR/stdout.txt" ]
}

@test "a field-level 400 is quoted too, not swallowed for having no errorMessages" {
    fixture_world
    export STUB_POST_CODE=400
    export STUB_POST_BODY='{"errorMessages":[],"errors":{"resolution":"Field resolution is required"}}'
    run jt UL-1797 --to "In Qualification"
    [ "$status" -eq 1 ]
    [[ "$output" == *"resolution: Field resolution is required"* ]]
}

@test "a curl that never connected is a refusal, which is the whole point of this tool" {
    # THE OTHER BUG THIS EXISTS TO PIN. publish-changes read an empty stdout as success,
    # and `curl -s` prints nothing on a connection failure as well as on a 204. Here the
    # POST goes out, curl exits 7 with no body, and it must NOT read as a transition.
    fixture_world
    export STUB_FAIL_METHOD=POST
    export STUB_FAIL_EXIT=7
    run jt UL-1797 --to "In Qualification"
    [ "$status" -eq 1 ]
    [[ "$output" == *"curl exit 7"* ]]
    [[ "$output" == *"unconfirmed"* ]]
    [ ! -s "$TEST_TMPDIR/stdout.txt" ]
}

@test "a curl that never connected on the first GET refuses before anything is sent" {
    fixture_world
    export STUB_FAIL_METHOD=GET
    run jt UL-1797 --to "In Qualification"
    [ "$status" -eq 1 ]
    [ "$(posted)" = "0" ]
    [ ! -s "$TEST_TMPDIR/stdout.txt" ]
}

@test "an issue that is not there is Jira's 404, said as such" {
    fixture_world
    export STUB_ISSUE_CODE=404
    run jt UL-9999 --to "In Qualification"
    [ "$status" -eq 1 ]
    [[ "$output" == *"404"* ]]
    [ "$(posted)" = "0" ]
}

@test "a 204 whose confirming GET fails still reports the move it actually made" {
    # 204 is 204. Losing the confirmation is a reason to say so out loud and fall back
    # to the target the workflow declared, not a reason to tell the caller that a
    # transition Jira has already applied did not happen.
    fixture_world
    export STUB_READBACK_CODE=500
    run jt UL-1797 --to "In Qualification"
    [ "$status" -eq 0 ]
    [[ "$output" == *"could not confirm"* ]]
    run python3 -c 'import json,sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
print(d["to"], d["dry_run"])' "$TEST_TMPDIR/stdout.txt"
    [ "${lines[0]}" = "In Qualification False" ]
}

# --- the arms that must send no write -------------------------------------------------

@test "--dry-run resolves everything, POSTs nothing, and says dry_run: true" {
    fixture_world
    run jt UL-1797 --to "In Qualification" --dry-run
    [ "$status" -eq 0 ]
    [ "$(posted)" = "0" ]
    grep -q '^GET ' "$STUB_RECORD"
    run python3 -c 'import json,sys
d = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
print(d["dry_run"], d["transition_id"], d["to"])' "$TEST_TMPDIR/stdout.txt"
    [ "${lines[0]}" = "True 4 In Qualification" ]
}

@test "--dry-run still refuses what a real run would refuse" {
    fixture_world
    run jt UL-1797 --to "Done" --dry-run
    [ "$status" -eq 1 ]
    [ ! -s "$TEST_TMPDIR/stdout.txt" ]
}

@test "--list prints the live transitions as JSON and POSTs nothing" {
    fixture_world
    run jt UL-1797 --list
    [ "$status" -eq 0 ]
    [ "$(posted)" = "0" ]
    run python3 -c 'import json,sys
rows = json.loads(open(sys.argv[1]).read().strip().splitlines()[-1])
print(len(rows))
q = [r for r in rows if r["id"] == "4"][0]
print(q["name"], "|", q["to"], "|", q["hasScreen"], "|", q["required"])
d = [r for r in rows if r["id"] == "51"][0]
print(d["hasScreen"], d["required"])' "$TEST_TMPDIR/stdout.txt"
    [ "${lines[0]}" = "9" ]
    [ "${lines[1]}" = "Qualifying | In Qualification | False | []" ]
    [ "${lines[2]}" = "True ['resolution']" ]
}

# --- refusals that happen before the first request ------------------------------------

@test "a key that is not a key is refused without a single request" {
    fixture_world
    run jt ul-1797 --list
    [ "$status" -eq 1 ]
    [[ "$output" == *"not an issue key"* ]]
    [ ! -s "$STUB_RECORD" ]
}

@test "no --to, no --transition-id and no --list is refused rather than guessed" {
    fixture_world
    run jt UL-1797
    [ "$status" -eq 1 ]
    [[ "$output" == *"will not choose a status for you"* ]]
    [ ! -s "$STUB_RECORD" ]
}

@test "--to and --transition-id together are two answers to one question" {
    fixture_world
    run jt UL-1797 --to "In Qualification" --transition-id 4
    [ "$status" -eq 1 ]
    [ ! -s "$STUB_RECORD" ]
}

@test "a flag whose value is missing gets a sentence, not a silent exit" {
    # Under set -e a bare `shift 2` with one argument left kills the script with no
    # output at all, which is the least useful thing a tool can do to a caller.
    fixture_world
    run jt UL-1797 --to
    [ "$status" -eq 1 ]
    [[ "$output" == *"--to needs a status name"* ]]
}

@test "two issue keys are refused, because this moves one issue" {
    fixture_world
    run jt UL-1797 UB-6668 --list
    [ "$status" -eq 1 ]
    [ ! -s "$STUB_RECORD" ]
}

# --- the credential, which belongs in no argv -----------------------------------------

@test "the API token never appears in a command line" {
    # Every curl here goes through lib/jira-curl.sh's 0600 config file. A -u on the
    # command line would put the token where any local user can read it out of ps.
    fixture_world
    run jt UL-1797 --to "In Qualification"
    [ "$status" -eq 0 ]
    run grep -c 'notatoken' "$STUB_ARGV"
    [ "${lines[0]}" = "0" ]
}

# --- the rules, lifted out of the script and run directly ------------------------------

lift() {
    eval "$(awk "/^$1\\(\\) \\{/,/^\\}/" "$JT")"
}

@test "transitions_matching_status matches to.name and never the transition name" {
    lift transitions_matching_status
    j='{"transitions":[{"id":"4","name":"Qualifying","to":{"name":"In Qualification"}},{"id":"5","name":"In Qualification","to":{"name":"Somewhere Else"}}]}'
    run bash -c 'printf "%s" "$1" | jq -r .id' _ "$(transitions_matching_status "$j" "In Qualification")"
    [ "${lines[0]}" = "4" ]
}

@test "transitions_matching_status yields nothing for a status no transition reaches" {
    lift transitions_matching_status
    j='{"transitions":[{"id":"4","name":"Qualifying","to":{"name":"In Qualification"}}]}'
    [ -z "$(transitions_matching_status "$j" "Abandoned")" ]
    [ -z "$(transitions_matching_status "$j" "Qualifying")" ]
}

@test "transitions_matching_status yields every match, so several can be refused" {
    lift transitions_matching_status
    j='{"transitions":[{"id":"51","name":"Done","to":{"name":"Done"}},{"id":"52","name":"Dup","to":{"name":"Done"}}]}'
    run bash -c 'printf "%s\n" "$1" | grep -c .' _ "$(transitions_matching_status "$j" "Done")"
    [ "${lines[0]}" = "2" ]
}

@test "a transitions payload that is not JSON yields nothing rather than blowing up" {
    lift transitions_matching_status
    [ -z "$(transitions_matching_status 'not json at all' "Done")" ]
    [ -z "$(transitions_matching_status '{}' "Done")" ]
}

@test "transition_required_fields names only the fields marked required" {
    lift transition_required_fields
    t='{"id":"61","fields":{"customfield_10050":{"required":true},"summary":{"required":false}}}'
    [ "$(transition_required_fields "$t")" = "customfield_10050" ]
    [ -z "$(transition_required_fields '{"id":"4","fields":{}}')" ]
    [ -z "$(transition_required_fields '{"id":"4"}')" ]
}

@test "emit_result is the contract, in the order a caller reads it" {
    lift emit_result
    run bash -c 'eval "$(awk "/^emit_result\\(\\) \\{/,/^\\}/" "$0")"
                 JIRA_DOMAIN=example.atlassian.net
                 emit_result UL-1797 "To Do" "In Qualification" 4 Qualifying false' "$JT"
    run python3 -c 'import json,sys
d = json.loads(sys.argv[1])
print(list(d))
print(d["url"], d["dry_run"], type(d["transition_id"]).__name__)' "$output"
    [ "${lines[0]}" = "['key', 'from', 'to', 'transition_id', 'transition_name', 'dry_run', 'url']" ]
    [ "${lines[1]}" = "https://example.atlassian.net/browse/UL-1797 False str" ]
}

@test "jira_error_text prefers Jira's words and falls back to the body it got" {
    lift jira_error_text
    [ "$(jira_error_text '{"errorMessages":["Issue does not exist."]}')" = "Issue does not exist." ]
    [ "$(jira_error_text '{"errors":{"resolution":"is required"}}')" = "resolution: is required" ]
    [[ "$(jira_error_text '<html>gateway timeout</html>')" == *"gateway timeout"* ]]
    [ "$(jira_error_text '')" = "no message" ]
}

# --- structural: what must not exist, asserted as not existing ------------------------

@test "there is no route from this script to a terminal" {
    # "It did not block" is also true of a run that happened to have a terminal. What
    # is asserted here is that no prompt EXISTS. Comment lines are stripped first: this
    # script argues at length about why it opens no terminal, and the words in that
    # argument cannot prompt anybody.
    run bash -c "grep -vE '^[[:space:]]*#' \"\$1\" | grep -nE 'read[[:space:]]|fzf|/dev/tty' || true" _ "$JT"
    [ -z "$output" ]
}

@test "every request is judged on the status code, never on an empty body" {
    # The publish-changes shape was: capture stdout, and if it is empty call it a
    # transition. That is indistinguishable from a curl that never connected.
    run grep -c "%{http_code}" "$JT"
    [ "${lines[0]}" -ge 1 ]
    run bash -c "grep -c 'CURL_RC' \"\$1\"" _ "$JT"
    [ "${lines[0]}" -ge 4 ]
    run bash -c "grep -nE 'if \\[ -z \"\\\$(transition|assign)_result\"' \"\$1\" || true" _ "$JT"
    [ -z "$output" ]
}

@test "the POST body carries a transition id and nothing else" {
    # publish-changes bundled a comment and a field write in with the move, so a
    # failure could not say which half failed. This one transitions, full stop.
    fixture_world
    run jt UL-1797 --to "In Qualification"
    [ "$status" -eq 0 ]
    run bash -c 'grep "^POST " "$1" | sed "s/^POST [^ ]* //"' _ "$STUB_RECORD"
    [ "${lines[0]}" = '{"transition":{"id":"4"}}' ]
}

@test "the transitions list is fetched per issue and never cached to disk" {
    # DE returns nine global entries plus one that exists only from a particular
    # status, so a list is a fact about one issue at one moment.
    run bash -c "grep -vE '^[[:space:]]*#' \"\$1\" | grep -nE 'CACHE|cache' || true" _ "$JT"
    [ -z "$output" ]
}

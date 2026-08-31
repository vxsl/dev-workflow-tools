#!/usr/bin/env bats

# Tests for create-jira-ticket's --non-interactive arm and its --estimate flag.
#
# Every step of this script used to read /dev/tty -- Step 1 through `read -e -i`, Steps
# 2-5 through fzf, Step 6 through $EDITOR -- so --summary pre-filled a prompt rather than
# answering it. That is right for a person and impossible for a caller with no terminal,
# which is what a systemd-started daemon is. --non-interactive answers every step from
# the flags and from the defaults the prompts already offer.
#
# NOTHING HERE REACHES JIRA. The refusals happen before the first curl by construction,
# and the two rules with any judgement in them -- which field id an estimate is written
# to, and what the result JSON looks like -- are lifted out of the script and run against
# fixtures, the way no_labels.bats lifts the Step 5 selection rule. A suite that filed a
# ticket to prove it could file a ticket would leave one behind every time it ran.
#
# The structural assertions are the other half: an arm that must not prompt is asserted
# to contain no prompt, because "it did not block" is also true of a run that happened to
# have a tty.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    TEST_TMPDIR=$(mktemp -d)
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    CJT="$REPO_ROOT/bin/create-jira-ticket"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# A tree with its own .env, so a run never depends on the developer's credentials and can
# never be pointed at a real board. Three projects, because the board refusal is only a
# question when more than one is configured.
build_fake_tools() {
    FAKE_ROOT="$TEST_TMPDIR/tools"
    mkdir -p "$FAKE_ROOT/bin"
    cp -r "$REPO_ROOT/lib" "$FAKE_ROOT/lib"
    cp "$CJT" "$FAKE_ROOT/bin/create-jira-ticket"
    cat > "$FAKE_ROOT/.env" <<'EOF'
JIRA_DOMAIN=example.invalid
JIRA_PROJECTS=UB,UL,DE
JIRA_EMAIL=test@test
JIRA_API_TOKEN=notatoken
EOF
}

# The estimate rule, lifted verbatim out of the script so what gets exercised is the
# branch that decides "which field id", not a copy of it.
lift_estimate_fn() {
    eval "$(awk '/^estimate_field_ids\(\) \{/,/^\}/' "$CJT")"
}

# The result-shaping rule, lifted the same way. It is the contract a caller parses, and
# until it was one function it was four copies of one jq line.
lift_emit_fn() {
    eval "$(awk '/^emit_result\(\) \{/,/^\}/' "$CJT")"
}

# --- the refusals, which all happen before the first request ------------------------

@test "--non-interactive without --summary is refused, not prompted" {
    build_fake_tools
    run timeout 20 "$FAKE_ROOT/bin/create-jira-ticket" --non-interactive --project UB \
        --dry-run </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"--summary"* ]]
}

@test "--non-interactive with several boards and none named is refused" {
    # Which board a ticket lands on is a fact about the work, not a default. Taking the
    # first entry would file somebody's ticket on the wrong team's board in silence.
    build_fake_tools
    run timeout 20 "$FAKE_ROOT/bin/create-jira-ticket" --non-interactive \
        --summary "a thing" --dry-run </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"--project"* ]]
    [[ "$output" == *"UB"* ]]
}

@test "JIRA_DEFAULT_PROJECT answers the board, so no --project is needed" {
    # Not a network test: it gets past the board question and dies on the unresolvable
    # domain, which is proof the refusal above did not fire.
    build_fake_tools
    printf 'JIRA_DEFAULT_PROJECT=UL\n' >> "$FAKE_ROOT/.env"
    run timeout 20 "$FAKE_ROOT/bin/create-jira-ticket" --non-interactive \
        --summary "a thing" --dry-run --no-labels </dev/null
    [[ "$output" != *"--non-interactive needs --project"* ]]
    # The board line is coloured, so the key and its value are not adjacent bytes. What
    # is asserted is the source it came from, which is the whole claim.
    [[ "$output" == *"JIRA_DEFAULT_PROJECT"* ]]
}

@test "--estimate takes days and refuses anything that is not a number" {
    build_fake_tools
    run timeout 20 "$FAKE_ROOT/bin/create-jira-ticket" --non-interactive --project UB \
        --summary "a thing" --estimate "a fortnight" --dry-run </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"number of days"* ]]
}

@test "a fractional estimate is a number of days too" {
    build_fake_tools
    run timeout 20 "$FAKE_ROOT/bin/create-jira-ticket" --non-interactive --project UB \
        --summary "a thing" --estimate "0.5" --dry-run </dev/null
    [[ "$output" != *"number of days"* ]]
}

# --- which field an estimate is written to ------------------------------------------

@test "the estimate field is found whatever case the board spells it in" {
    # THE BUG THIS EXISTS TO PIN. UL's field is named "Estimate (in Days)" and UB's is
    # "Estimate (in days)". An exact-name match resolves one board and misses the other,
    # silently, and the ticket lands with no estimate on it.
    lift_estimate_fn
    lower='{"customfield_10137":{"name":"Estimate (in days)"},"summary":{"name":"Summary"}}'
    upper='{"customfield_10314":{"name":"Estimate (in Days)"},"summary":{"name":"Summary"}}'
    [ "$(estimate_field_ids "$lower")" = "customfield_10137" ]
    [ "$(estimate_field_ids "$upper")" = "customfield_10314" ]
}

@test "a screen with no estimate field yields nothing rather than a guess" {
    lift_estimate_fn
    meta='{"summary":{"name":"Summary"},"customfield_10999":{"name":"Story Points"}}'
    [ -z "$(estimate_field_ids "$meta")" ]
}

@test "two fields of that name yield both, so the caller can refuse to choose" {
    # Jira holds several fields displaying as "Estimate (in days)". One per create screen
    # is what has been observed; two would be a board this script must not write to on a
    # coin toss.
    lift_estimate_fn
    meta='{"customfield_1":{"name":"Estimate (in days)"},"customfield_2":{"name":"Estimate (in Days)"}}'
    run bash -c 'eval "$(awk "/^estimate_field_ids\\(\\) \\{/,/^\\}/" "$0")"; estimate_field_ids "$1" | wc -l' "$CJT" "$meta"
    [ "${lines[0]}" = "2" ]
}

@test "a createmeta call that failed yields nothing, and does not blow up" {
    lift_estimate_fn
    [ -z "$(estimate_field_ids '{}')" ]
    [ -z "$(estimate_field_ids 'not json at all')" ]
}

# --- what the caller reads back -------------------------------------------------------

@test "the result names the estimate and the field it went into" {
    lift_emit_fn
    OUTPUT_FILE="" ESTIMATE=4 estimate_id=customfield_10137 estimate_error=""
    run bash -c 'eval "$(awk "/^emit_result\\(\\) \\{/,/^\\}/" "$0")"
                 OUTPUT_FILE="" ESTIMATE=4 estimate_id=customfield_10137 estimate_error=""
                 emit_result UB-1234 "a thing" "a body"' "$CJT"
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["key"], d["estimate"], d["estimate_field"], "estimate_error" in d)' "$output"
    [ "${lines[0]}" = "UB-1234 4 customfield_10137 False" ]
}

@test "an estimate that could not be written comes back as the reason, not as a zero" {
    # A zero would be a claim that this work is estimated at no days. Absence plus a
    # reason is the honest shape, and it is what lets a caller tell "no estimate wanted"
    # from "wanted and not set".
    run bash -c 'eval "$(awk "/^emit_result\\(\\) \\{/,/^\\}/" "$0")"
                 OUTPUT_FILE="" ESTIMATE=4 estimate_id="" estimate_error="no such field"
                 emit_result UB-1234 "a thing" "a body"' "$CJT"
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["estimate_error"], "estimate" in d, "estimate_field" in d)' "$output"
    [ "${lines[0]}" = "no such field False False" ]
}

@test "with no estimate asked for, the result is the shape it has always been" {
    # Every existing caller parses {key, summary, description}. Adding a key it does not
    # know about is additive; adding one on every run would not be.
    run bash -c 'eval "$(awk "/^emit_result\\(\\) \\{/,/^\\}/" "$0")"
                 OUTPUT_FILE="" ESTIMATE="" estimate_id="" estimate_error="" JIRA_DOMAIN=""
                 emit_result UB-1234 "a thing" "a body"' "$CJT"
    run python3 -c 'import json,sys; print(sorted(json.loads(sys.argv[1])))' "$output"
    [ "${lines[0]}" = "['description', 'key', 'summary']" ]
}

@test "the result carries the ticket's url, which only this repo's .env can build" {
    # It was printed to stderr inside a box-drawing banner and nowhere a caller could
    # read it, so anything wanting to link what it had just created had to rebuild the
    # URL from a JIRA_DOMAIN it may not have.
    run bash -c 'eval "$(awk "/^emit_result\\(\\) \\{/,/^\\}/" "$0")"
                 OUTPUT_FILE="" ESTIMATE="" estimate_id="" estimate_error=""
                 JIRA_DOMAIN=example.atlassian.net
                 emit_result UB-1234 "a thing" "a body"' "$CJT"
    run python3 -c 'import json,sys; print(json.loads(sys.argv[1])["url"])' "$output"
    [ "${lines[0]}" = "https://example.atlassian.net/browse/UB-1234" ]
}

@test "--output-file gets the result and stdout stays empty" {
    run bash -c 'eval "$(awk "/^emit_result\\(\\) \\{/,/^\\}/" "$0")"
                 OUTPUT_FILE="$1" ESTIMATE=2 estimate_id=customfield_10314 estimate_error=""
                 emit_result UL-7 "a thing" "a body"' "$CJT" "$TEST_TMPDIR/out.json"
    [ -z "$output" ]
    run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["key"], d["estimate_field"])' "$TEST_TMPDIR/out.json"
    [ "${lines[0]}" = "UL-7 customfield_10314" ]
}

# --- structural: an arm that must not prompt contains no prompt ----------------------

@test "the non-interactive arm of every step reaches no tty" {
    # "It did not block" is also true of a run that happened to have a terminal. What is
    # asserted here is that there is no route from --non-interactive to one: the summary
    # arm holds no read, and neither the description arm nor any picker arm can be
    # entered with it set.
    run awk '/^if \[ "\$NON_INTERACTIVE" = true \]; then$/{f=1} f&&/^else$/{f=0} f' "$CJT"
    [ -n "$output" ]
    [[ "$output" != *'/dev/tty'* ]]
    [[ "$output" != *'$EDITOR'* ]]
    [[ "$output" != *'$FZF'* ]]
}

@test "pick() is the only route from a picker to fzf, and it refuses under the flag" {
    # The four Bug-field pickers go through it rather than through $FZF, so their defaults
    # are stated once. A fifth added later that called $FZF directly would show up here.
    run grep -c 'pick --prompt=\|| pick ' "$CJT"
    [ "$output" -ge 4 ]
    run awk '/^pick\(\) \{/,/^\}/' "$CJT"
    [[ "$output" == *'NON_INTERACTIVE'* ]]
    [[ "$output" == *'return 0'* ]]
}

@test "fzf being absent is not fatal when nothing is going to be picked" {
    # A daemon's PATH has no fzf. Turning it away for a dependency it was never going to
    # reach would be the whole feature refusing over furniture.
    build_fake_tools
    mkdir -p "$TEST_TMPDIR/emptybin"
    run env PATH="$TEST_TMPDIR/emptybin:/usr/bin:/bin" HOME="$TEST_TMPDIR/nohome" \
        timeout 20 "$FAKE_ROOT/bin/create-jira-ticket" --non-interactive --project UB \
        --summary "a thing" --dry-run --no-labels </dev/null
    [[ "$output" != *"fzf not found"* ]]
}

@test "createmeta asks for the issue type it was given and not for one with a newline on it" {
    # `echo Task | jq -sRr @uri` is "Task%0A", so every createmeta call asked Jira for an
    # issue type that does not exist, got a project with no issue types back, and returned
    # {} -- which reads exactly like "this board's screen has none of these fields". The
    # Bug prompts skipped themselves on every board for as long as that stood.
    run awk '/^get_createmeta_fields\(\) \{/,/^\}/' "$CJT"
    [[ "$output" == *"printf '%s' \"\$issuetype_name\" | jq -sRr @uri"* ]]
    [[ "$output" != *'echo "$issuetype_name" | jq'* ]]
}

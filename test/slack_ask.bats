#!/usr/bin/env bats

# slack-ask used to accept the first message you posted after its question,
# whoever it was addressed to. In a shared channel that meant "<@teammate> yep
# you are right" was read as the answer to the bot — and, being first, it beat
# the actual decision posted a moment later. These cover both halves: the
# mention gate and last-reply-wins.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "$REPO_ROOT/lib/slack.sh"
    QTS="1787272090.000000"
}

# The exchange from the reported bug: bot asks in a channel, user answers a
# teammate in the same thread.
teammate_thread() {
    cat <<'EOF'
{"messages":[
 {"ts":"1787272091.000100","user":"UKYLE","text":"<@ULOGAN> yep you are right; I forgot the layers know not to render a date picker"},
 {"ts":"1787272091.000200","user":"UKYLE","text":"approved"}
]}
EOF
}

@test "slack_channel_is_dm: D-prefixed is a DM" {
    slack_channel_is_dm "D01ABCDEF"
}

@test "slack_channel_is_dm: C- and G-prefixed are shared channels" {
    ! slack_channel_is_dm "C01R3M51BLZ"
    ! slack_channel_is_dm "G01ABCDEF"
}

@test "select_ask_reply: channel reply aimed at a teammate is not an answer" {
    result=$(select_ask_reply "$(teammate_thread)" "$QTS" UKYLE UBOTSELF)
    [ -z "$result" ]
}

@test "select_ask_reply: same thread in a DM needs no mention" {
    result=$(select_ask_reply "$(teammate_thread)" "$QTS" UKYLE "")
    [ "$result" = "approved" ]
}

@test "select_ask_reply: last mentioning reply wins, not the first" {
    json='{"messages":[
     {"ts":"1787272091.000100","user":"UKYLE","text":"<@UBOTSELF> the reasoning is X"},
     {"ts":"1787272091.000200","user":"UKYLE","text":"<@UBOTSELF> approved"}
    ]}'
    result=$(select_ask_reply "$json" "$QTS" UKYLE UBOTSELF)
    [ "$result" = "approved" ]
}

@test "select_ask_reply: the bot's mention is stripped from the answer" {
    json='{"messages":[{"ts":"1787272091.000100","user":"UKYLE","text":"<@UBOTSELF> ship it"}]}'
    result=$(select_ask_reply "$json" "$QTS" UKYLE UBOTSELF)
    [ "$result" = "ship it" ]
}

@test "select_ask_reply: legacy <@U123|name> mention form counts" {
    json='{"messages":[{"ts":"1787272091.000100","user":"UKYLE","text":"<@UBOTSELF|devbot> ship it"}]}'
    result=$(select_ask_reply "$json" "$QTS" UKYLE UBOTSELF)
    [ "$result" = "ship it" ]
}

@test "select_ask_reply: a bare mention with no words is not an answer" {
    json='{"messages":[{"ts":"1787272091.000100","user":"UKYLE","text":"<@UBOTSELF>"}]}'
    result=$(select_ask_reply "$json" "$QTS" UKYLE UBOTSELF)
    [ -z "$result" ]
}

@test "select_ask_reply: a mention from someone else is not an answer" {
    json='{"messages":[{"ts":"1787272091.000100","user":"UNEVILLE","text":"<@UBOTSELF> go ahead"}]}'
    result=$(select_ask_reply "$json" "$QTS" UKYLE UBOTSELF)
    [ -z "$result" ]
}

@test "select_ask_reply: replies older than the question are ignored" {
    json='{"messages":[{"ts":"1787272089.000000","user":"UKYLE","text":"<@UBOTSELF> stale"}]}'
    result=$(select_ask_reply "$json" "$QTS" UKYLE UBOTSELF)
    [ -z "$result" ]
}

@test "select_ask_reply: an error payload yields no answer" {
    result=$(select_ask_reply '{"ok":false,"error":"channel_not_found"}' "$QTS" UKYLE UBOTSELF)
    [ -z "$result" ]
}

# ── End-to-end, against a stub Slack API on PATH ──────────────────────────
#
# The stub answers auth.test, records what chat.postMessage was given, and
# serves conversations.replies from a file the test rewrites between polls —
# which is how the "second message still being typed" case gets exercised.

stub_slack_api() {
    STUB_DIR="$BATS_TEST_TMPDIR/stub"
    mkdir -p "$STUB_DIR"
    export REPLIES_FILE="$BATS_TEST_TMPDIR/replies.json"
    export POSTED_FILE="$BATS_TEST_TMPDIR/posted.txt"
    echo '{"messages":[]}' > "$REPLIES_FILE"
    : > "$POSTED_FILE"

    cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
    *auth.test*)
        echo '{"ok":true,"user_id":"UBOTSELF"}' ;;
    *chat.postMessage*)
        # The JSON body follows -d; record it so the test can assert on it.
        prev=""
        for a in "$@"; do
            if [ "$prev" = "-d" ]; then printf '%s\n' "$a" >> "$POSTED_FILE"; fi
            prev="$a"
        done
        echo '{"ok":true,"ts":"1787272090.000000"}' ;;
    *conversations.replies*)
        cat "$REPLIES_FILE" ;;
    *)
        echo '{"ok":false}' ; exit 22 ;;
esac
STUB
    chmod +x "$STUB_DIR/curl"
    PATH="$STUB_DIR:$PATH"
    export PATH

    export SLACK_DM_CHANNEL_ID="C01R3M51BLZ"
    export SLACK_THREAD_TS="1787200000.000000"
    export TICKET_CREATOR_BOT_TOKEN="xoxb-test"
    export SLACK_NOTIFY_USER_ID="UKYLE"
    export SLACK_ASK_POLL_INTERVAL=1
    export SLACK_ASK_TIMEOUT_SECONDS=8
}

@test "slack-ask e2e: channel question tells the user to tag the bot" {
    stub_slack_api
    run "$REPO_ROOT/bin/slack-ask" "OK with that?"
    [ "$status" -eq 0 ]
    grep -q "Reply with <@UBOTSELF> to answer" "$POSTED_FILE"
}

@test "slack-ask e2e: DM question carries no tag instruction" {
    stub_slack_api
    export SLACK_DM_CHANNEL_ID="D01ABCDEF"
    run "$REPO_ROOT/bin/slack-ask" "OK with that?"
    [ "$status" -eq 0 ]
    ! grep -q "Reply with" "$POSTED_FILE"
}

@test "slack-ask e2e: a channel reply aimed at a teammate times out, not answers" {
    stub_slack_api
    cat > "$REPLIES_FILE" <<'EOF'
{"messages":[{"ts":"1787272091.000100","user":"UKYLE","text":"<@ULOGAN> yep you are right"}]}
EOF
    run "$REPO_ROOT/bin/slack-ask" "OK with that?"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no response — timed out"* ]]
}

@test "slack-ask e2e: a mentioning reply is returned with the mention stripped" {
    stub_slack_api
    cat > "$REPLIES_FILE" <<'EOF'
{"messages":[{"ts":"1787272091.000100","user":"UKYLE","text":"<@UBOTSELF> approved"}]}
EOF
    run "$REPO_ROOT/bin/slack-ask" "OK with that?"
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "approved" ]
}

@test "slack-ask e2e: the settle poll picks up a decision typed just after" {
    stub_slack_api
    cat > "$REPLIES_FILE" <<'EOF'
{"messages":[{"ts":"1787272091.000100","user":"UKYLE","text":"<@UBOTSELF> the reasoning is X"}]}
EOF
    # Land the follow-up while slack-ask is inside its settle sleep.
    (sleep 1.5; cat > "$REPLIES_FILE" <<'EOF'
{"messages":[
 {"ts":"1787272091.000100","user":"UKYLE","text":"<@UBOTSELF> the reasoning is X"},
 {"ts":"1787272091.000200","user":"UKYLE","text":"<@UBOTSELF> approved"}
]}
EOF
    ) &
    run "$REPO_ROOT/bin/slack-ask" "OK with that?"
    wait
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "approved" ]
}

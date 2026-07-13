#!/usr/bin/env bats

# Tests for ticket-bot. The message-routing predicates that decide whether an
# incoming Slack message should engage the bot (is_dm_channel,
# strip_bot_mention, should_engage_thread_reply) are pure functions exercised
# by the bot's own --selftest, which we run here. --selftest short-circuits
# before any token validation / auth.test, so it needs no live Slack token or
# network access.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    BIN="$REPO_ROOT/bin/ticket-bot"
}

@test "ticket-bot: --selftest passes (routing-predicate unit checks)" {
    run "$BIN" --selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"SELFTEST PASSED"* ]]
}

@test "ticket-bot: --selftest needs no Slack token or network" {
    # No tokens in the environment at all — --selftest must still pass because
    # it runs before load_env / token validation / auth.test.
    TICKET_CREATOR_BOT_TOKEN="" SLACK_APP_TOKEN="" SLACK_NOTIFY_USER_ID="" \
        run "$BIN" --selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"SELFTEST PASSED"* ]]
}

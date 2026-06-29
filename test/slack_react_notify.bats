#!/usr/bin/env bats

# Tests for slack-react-notify. The daemon's behavioral core — who to notify
# (should_notify) and how the notification reads (format_notification,
# slack_text_to_plain, emojize) — is exercised by the daemon's own --selftest,
# which we run here. We also check the CLI guidance paths.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    BIN="$REPO_ROOT/bin/slack-react-notify"
}

@test "slack-react-notify: --selftest passes (pure-function unit checks)" {
    run "$BIN" --selftest
    [ "$status" -eq 0 ]
    [[ "$output" == *"SELFTEST PASSED"* ]]
}

@test "slack-react-notify: --help documents the dedicated-app setup" {
    run "$BIN" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"SLACK_REACT_APP_TOKEN"* ]]
    [[ "$output" == *"on behalf of users"* ]]
}

@test "slack-react-notify: --check reports missing tokens clearly" {
    SLACK_REACT_TOKEN="" SLACK_REACT_APP_TOKEN="" run "$BIN" --check
    [ "$status" -eq 1 ]
    [[ "$output" == *"Missing from .env"* ]]
    [[ "$output" == *"SLACK_REACT_TOKEN"* ]]
}

@test "slack-react-notify: --print-manifest emits a pasteable app manifest" {
    run "$BIN" --print-manifest
    [ "$status" -eq 0 ]
    [[ "$output" == *"event_subscriptions"* ]]
    [[ "$output" == *"user_events"* ]]
    [[ "$output" == *"reaction_added"* ]]
    [[ "$output" == *"socket_mode_enabled: true"* ]]
}

@test "slack-react-notify: --print-service systemd emits a unit" {
    run "$BIN" --print-service systemd
    [ "$status" -eq 0 ]
    [[ "$output" == *"[Service]"* ]]
    [[ "$output" == *"ExecStart="* ]]
}

@test "slack-react-notify: --print-service launchd emits a plist" {
    run "$BIN" --print-service launchd
    [ "$status" -eq 0 ]
    [[ "$output" == *"<plist version"* ]]
    [[ "$output" == *"KeepAlive"* ]]
}

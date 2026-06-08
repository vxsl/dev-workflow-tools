#!/usr/bin/env bats

# Regression tests for slack_escape: a literal '<' in a ticket title
# (e.g. "TROI < 2 weeks") corrupted the surrounding <url|text> mrkdwn link.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    source "$REPO_ROOT/lib/slack.sh"
}

@test "slack_escape: plain text unchanged" {
    result=$(slack_escape "impedance score datepicker")
    [ "$result" = "impedance score datepicker" ]
}

@test "slack_escape: less-than is escaped" {
    result=$(slack_escape "TROI < 2 weeks")
    [ "$result" = "TROI &lt; 2 weeks" ]
}

@test "slack_escape: greater-than is escaped" {
    result=$(slack_escape "count > 5")
    [ "$result" = "count &gt; 5" ]
}

@test "slack_escape: ampersand is escaped first (no double-escape)" {
    result=$(slack_escape "A & B")
    [ "$result" = "A &amp; B" ]
}

@test "slack_escape: all three together" {
    result=$(slack_escape "<a> & <b>")
    [ "$result" = "&lt;a&gt; &amp; &lt;b&gt;" ]
}

@test "slack_escape: realistic ticket title preserves link structure" {
    title=$(slack_escape "UL-1439 impedance score, range with TROI < 2 weeks")
    url="https://gitlab.example.com/x/-/merge_requests/10006"
    text="<${url}|!10006 — ${title}>"
    # The only '<' and '>' must be the link delimiters; the title's '<' is escaped.
    [ "$text" = "<${url}|!10006 — UL-1439 impedance score, range with TROI &lt; 2 weeks>" ]
}

@test "slack_escape: empty string stays empty" {
    result=$(slack_escape "")
    [ "$result" = "" ]
}

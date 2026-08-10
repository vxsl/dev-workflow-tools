#!/usr/bin/env bats

# Tests for slack-pick-thread's rendering.
#
# The picker's --render modes are what its fzf reload bindings call, and they read
# only from the cache — so seeding the cache exercises every decision the picker
# makes about a row (is it mine, what does it say, where does it point) without
# touching Slack.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    TEST_TMPDIR=$(mktemp -d)
    export SLACK_PICKER_CACHE_DIR="$TEST_TMPDIR/cache"
    mkdir -p "$SLACK_PICKER_CACHE_DIR"

    # A fresh identity file keeps load_identity off the network.
    cat > "$SLACK_PICKER_CACHE_DIR/identity" <<'EOF'
SLACK_ME=U_ME
SLACK_HOST=example.slack.com
EOF

    printf 'U_ME\tKyle\nU_OTHER\tAvery\n' > "$SLACK_PICKER_CACHE_DIR/users.tsv"
    printf 'C0PUB0001\tgeneral\n' > "$SLACK_PICKER_CACHE_DIR/channels.tsv"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# last-activity ts │ mine │ channel │ author │ replies │ text │ channel/ts
seed_threads() {
    printf '%s\n' "$@" > "$SLACK_PICKER_CACHE_DIR/threads.tsv"
}

render() {
    "$REPO_ROOT/bin/slack-pick-thread" --render "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# --- scope -------------------------------------------------------------------

@test "render mine: only threads you took part in" {
    seed_threads \
        "$(printf '1700000000.1\t1\tgeneral\tU_ME\t3\tmine\tC0PUB0001/1700000000.111111')" \
        "$(printf '1700000001.1\t0\tgeneral\tU_OTHER\t2\tsomeone elses\tC0PUB0001/1700000001.222222')"
    run render mine
    [[ "$output" == *"mine"* ]]
    [[ "$output" != *"someone elses"* ]]
}

@test "render all: every recent thread, yours marked" {
    seed_threads \
        "$(printf '1700000000.1\t1\tgeneral\tU_ME\t3\tmine\tC0PUB0001/1700000000.111111')" \
        "$(printf '1700000001.1\t0\tgeneral\tU_OTHER\t2\tsomeone elses\tC0PUB0001/1700000001.222222')"
    run render all
    [[ "$output" == *"mine"* ]]
    [[ "$output" == *"someone elses"* ]]
    [[ "$output" == *"●"* ]]
    [[ "$output" == *"·"* ]]
}

# --- the permalink -----------------------------------------------------------

@test "permalink: the timestamp loses its dot and the host keeps its own" {
    seed_threads "$(printf '1700000000.1\t1\tgeneral\tU_ME\t3\thello\tC0PUB0001/1700000000.111111')"
    run render mine
    [[ "$output" == *"https://example.slack.com/archives/C0PUB0001/p1700000000111111"* ]]
}

@test "permalink: what the picker emits is what parse_slack_url accepts" {
    seed_threads "$(printf '1700000000.1\t1\tgeneral\tU_ME\t3\thello\tC0PUB0001/1700000000.111111')"
    link=$(render mine | cut -f2)
    source "$REPO_ROOT/lib/slack.sh"
    run parse_slack_url "$link"
    [ "$status" -eq 0 ]
    parse_slack_url "$link"
    [ "$SLACK_CHANNEL" = "C0PUB0001" ]
    [ "$SLACK_THREAD_TS" = "1700000000.111111" ]
}

# --- message text ------------------------------------------------------------

@test "text: a user mention resolves to a name" {
    seed_threads "$(printf '1700000000.1\t1\tgeneral\tU_OTHER\t3\they <@U_ME> look\tC0PUB0001/1700000000.111111')"
    run render mine
    [[ "$output" == *"hey @Kyle look"* ]]
}

@test "text: an unknown user mention keeps the id rather than vanishing" {
    seed_threads "$(printf '1700000000.1\t1\tgeneral\tU_OTHER\t3\they <@U_GHOST> look\tC0PUB0001/1700000000.111111')"
    run render mine
    [[ "$output" == *"hey @U_GHOST look"* ]]
}

@test "text: a link shows its label, not its url" {
    seed_threads "$(printf '1700000000.1\t1\tgeneral\tU_ME\t3\tits testable <https://example.com/x|here>\tC0PUB0001/1700000000.111111')"
    run render mine
    [[ "$output" == *"its testable here"* ]]
    [[ "$output" != *"example.com/x"* ]]
}

@test "text: a bare link shows the url itself" {
    seed_threads "$(printf '1700000000.1\t1\tgeneral\tU_ME\t3\tsee <https://example.com/x>\tC0PUB0001/1700000000.111111')"
    run render mine
    [[ "$output" == *"see https://example.com/x"* ]]
}

@test "text: a channel reference reads as a channel" {
    seed_threads "$(printf '1700000000.1\t1\tgeneral\tU_ME\t3\tasked in <#C0PUB0001|general>\tC0PUB0001/1700000000.111111')"
    run render mine
    [[ "$output" == *"asked in #general"* ]]
}

@test "text: escaped entities come back as themselves" {
    seed_threads "$(printf '1700000000.1\t1\tgeneral\tU_ME\t3\tTROI &lt; 2 weeks &amp; rising\tC0PUB0001/1700000000.111111')"
    run render mine
    [[ "$output" == *"TROI < 2 weeks & rising"* ]]
}

@test "text: clipping happens after markup, so a long line can't strand half a link" {
    # The link sits past the 200-char display clip. Clipping the raw text first
    # would cut it mid-token and leave a bare "<https://…" on screen.
    long=$(printf 'x%.0s' {1..240})
    seed_threads "$(printf '1700000000.1\t1\tgeneral\tU_ME\t3\t%s <https://example.com/y|tail>\tC0PUB0001/1700000000.111111' "$long")"
    run render mine
    [[ "$output" != *"<https"* ]]
}

# --- the sweep ---------------------------------------------------------------
#
# What a channel's history turns into: which messages count as threads, which
# threads count as yours, and where a row's text comes from when the message
# never carried any.

stub_slack() {
    STUB_BIN="$TEST_TMPDIR/stubs"
    mkdir -p "$STUB_BIN"
    cat > "$TEST_TMPDIR/history.json" <<'EOF'
{"ok":true,"messages":[
 {"ts":"1700000000.000100","reply_count":2,"latest_reply":"1700000500.000100",
  "user":"U_ME","text":"i started this one"},
 {"ts":"1700000001.000100","reply_count":3,"latest_reply":"1700000600.000100",
  "user":"U_OTHER","reply_users":["U_ME"],"text":"you replied in this one"},
 {"ts":"1700000002.000100","reply_count":1,"latest_reply":"1700000700.000100",
  "user":"U_OTHER","text":"hey <@U_ME> look at this one"},
 {"ts":"1700000003.000100","reply_count":4,"latest_reply":"1700000800.000100",
  "user":"U_OTHER","text":"nothing to do with you"},
 {"ts":"1700000004.000100","reply_count":1,"latest_reply":"1700000900.000100",
  "user":"U_ME","text":"","files":[{"name":"shot.png"}]},
 {"ts":"1700000005.000100","user":"U_ME","text":"a message nobody replied to"}
]}
EOF
    cat > "$STUB_BIN/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *auth.test*)             echo '{"ok":true,"user_id":"U_ME","url":"https://example.slack.com/"}' ;;
    *users.list*)            echo '{"ok":true,"members":[{"id":"U_ME","name":"kyle","real_name":"Kyle"}]}' ;;
    *users.conversations*)   echo '{"ok":true,"channels":[{"id":"C0PUB0001","name":"general"}]}' ;;
    *conversations.history*) cat "$TEST_TMPDIR/history.json" ;;
    *)                       echo '{}' ;;
esac
EOF
    chmod +x "$STUB_BIN/curl"
    export PATH="$STUB_BIN:$PATH"
}

sweep() {
    stub_slack
    "$REPO_ROOT/bin/slack-pick-thread" --warm 2>/dev/null
}

@test "sweep: a message with no replies is not a thread" {
    sweep
    run cut -f6 "$SLACK_PICKER_CACHE_DIR/threads.tsv"
    [[ "$output" != *"a message nobody replied to"* ]]
    [ "$(wc -l < "$SLACK_PICKER_CACHE_DIR/threads.tsv")" -eq 5 ]
}

@test "sweep: a thread is yours if you started it, replied to it, or are named in it" {
    sweep
    mine=$(awk -F'\t' '$2=="1" {print $6}' "$SLACK_PICKER_CACHE_DIR/threads.tsv")
    [[ "$mine" == *"i started this one"* ]]
    [[ "$mine" == *"you replied in this one"* ]]
    [[ "$mine" == *"look at this one"* ]]
    [[ "$mine" != *"nothing to do with you"* ]]
}

@test "sweep: an uncaptioned upload is described by its file name" {
    # Otherwise the row is blank, and a blank row is one you cannot pick out.
    sweep
    run awk -F'\t' '$6=="" {n++} END {print n+0}' "$SLACK_PICKER_CACHE_DIR/threads.tsv"
    [ "$output" = "0" ]
    run cut -f6 "$SLACK_PICKER_CACHE_DIR/threads.tsv"
    [[ "$output" == *"shot.png"* ]]
}

@test "sweep: newest activity first" {
    sweep
    run cut -f1 "$SLACK_PICKER_CACHE_DIR/threads.tsv"
    [ "${lines[0]}" = "1700000900.000100" ]
    [ "${lines[-1]}" = "1700000500.000100" ]
}

# --- availability ------------------------------------------------------------

@test "unknown arguments are refused as unavailable, not as a cancel" {
    # Exit 2 is the caller's cue to fall back to a paste prompt; exit 1 would
    # read as "the user declined to post".
    run "$REPO_ROOT/bin/slack-pick-thread" --nonsense
    [ "$status" -eq 2 ]
}

@test "publish-changes treats an unavailable picker as a fallback, not a refusal" {
    # The contract is exit-code shaped, so assert the caller reads it that way.
    run grep -A2 'picker_rc=\$?' "$REPO_ROOT/bin/publish-changes"
    [[ "$output" == *"case \"\$picker_rc\""* ]]
    run grep -c 'SLACK_PICKER:-1' "$REPO_ROOT/bin/publish-changes"
    [ "$output" = "1" ]
}

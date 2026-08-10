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

    # A token of our own, so the repo's real .env one is never the one under test.
    # .env sets SLACK_REACT_TOKEN, not SLACK_USER_TOKEN, so this one wins.
    export SLACK_USER_TOKEN="test-token"
    TOKEN_FP=$(printf '%s' "$SLACK_USER_TOKEN" | sha256sum | cut -c1-16)

    # A fresh identity keeps load_identity off the network — but only if its
    # fingerprint matches, which is the same rule that makes a rotated token
    # re-check its scopes instead of trusting yesterday's answer.
    cat > "$SLACK_PICKER_CACHE_DIR/identity" <<EOF
SLACK_ME=U_ME
SLACK_HOST=example.slack.com
SLACK_WHO=tester
SLACK_TEAM=TestTeam
SLACK_TOKEN_FP=$TOKEN_FP
SLACK_SCOPES="channels:read channels:history groups:read groups:history users:read"
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
    _stub_slack "channels:read channels:history groups:read groups:history users:read"
}

stub_slack_scopes() { _stub_slack "$1"; }

_stub_slack() {
    local scopes="$1"
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
echo "\$*" >> "$TEST_TMPDIR/seen-args.log"
# Honour -D <file>: the granted scopes arrive as a response header, which is the
# only way to ask what a token may do without trying it and reading the error.
hdr=""; prev=""
for a in "\$@"; do
    [ "\$prev" = "-D" ] && hdr="\$a"
    prev="\$a"
done
[ -n "\$hdr" ] && printf 'HTTP/1.1 200 OK\r\nx-oauth-scopes: %s\r\n\r\n' "$(printf '%s' "$scopes" | tr ' ' ',')" > "\$hdr"
case "\$*" in
    *auth.test*)             echo '{"ok":true,"user_id":"U_ME","user":"tester","team":"TestTeam","url":"https://example.slack.com/"}' ;;
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

# --- search ------------------------------------------------------------------
#
# With search:read the list is two calls and the answer is the question, rather
# than 66 calls reconstructing it. A reply's permalink carries ?thread_ts=<root>,
# which is how each message names the thread it belongs to without a call to ask.

stub_search() {
    STUB_BIN="$TEST_TMPDIR/stubs"
    mkdir -p "$STUB_BIN"
    # from:@me returns only my messages; the mention query only other people's —
    # which is what Slack does, and what keeps the marker deterministic.
    cat > "$TEST_TMPDIR/mine.json" <<'EOF'
{"ok":true,"messages":{"total":2,"matches":[
 {"ts":"1700000500.000100","user":"U_ME","text":"my first word in it",
  "channel":{"id":"C0PUB0001","name":"general","is_channel":true},
  "permalink":"https://example.slack.com/archives/C0PUB0001/p1700000500000100?thread_ts=1700000000.111111"},
 {"ts":"1700000600.000100","user":"U_ME","text":"my later word in the same thread",
  "channel":{"id":"C0PUB0001","name":"general","is_channel":true},
  "permalink":"https://example.slack.com/archives/C0PUB0001/p1700000600000100?thread_ts=1700000000.111111"}
]}}
EOF
    cat > "$TEST_TMPDIR/named.json" <<'EOF'
{"ok":true,"messages":{"total":2,"matches":[
 {"ts":"1700000700.000100","user":"U_OTHER","text":"hey <@U_ME> look at this",
  "channel":{"id":"C0PUB0001","name":"general","is_channel":true},
  "permalink":"https://example.slack.com/archives/C0PUB0001/p1700000700000100?thread_ts=1700000222.333333"},
 {"ts":"1700000800.000100","user":"U_OTHER","text":"","files":[{"name":"shot.png"}],
  "channel":{"id":"D0DM00001","name":"U_OTHER","is_im":true},
  "permalink":"https://example.slack.com/archives/D0DM00001/p1700000800000100"}
]}}
EOF
    cat > "$STUB_BIN/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TEST_TMPDIR/seen-args.log"
case "\$*" in
    *search.messages*from:*) cat "$TEST_TMPDIR/mine.json" ;;
    *search.messages*)       cat "$TEST_TMPDIR/named.json" ;;
    *users.list*)            echo '{"ok":true,"members":[{"id":"U_ME","name":"kyle","real_name":"Kyle"},{"id":"U_OTHER","name":"avery","real_name":"Avery"}]}' ;;
    *)                       echo '{}' ;;
esac
EOF
    chmod +x "$STUB_BIN/curl"
    export PATH="$STUB_BIN:$PATH"
    with_scopes "channels:read channels:history groups:read groups:history users:read search:read"
    rm -f "$SLACK_PICKER_CACHE_DIR/threads.tsv"
}

@test "search: the channel sweep is not used at all" {
    stub_search
    "$REPO_ROOT/bin/slack-pick-thread" --warm 2>/dev/null
    run cat "$TEST_TMPDIR/seen-args.log"
    [[ "$output" != *"conversations.history"* ]]
    [[ "$output" != *"users.conversations"* ]]
    [ "$(grep -c search.messages "$TEST_TMPDIR/seen-args.log")" -eq 2 ]
}

@test "search: a thread is one row however much you said in it" {
    stub_search
    "$REPO_ROOT/bin/slack-pick-thread" --warm 2>/dev/null
    # Two of my messages share a thread root, so they are one place to post.
    [ "$(wc -l < "$SLACK_PICKER_CACHE_DIR/threads.tsv")" -eq 3 ]
    run cut -f7 "$SLACK_PICKER_CACHE_DIR/threads.tsv"
    [[ "$output" == *"C0PUB0001/1700000000.111111"* ]]
    # ...dated by the most recent of them, not the first.
    run grep -c "^1700000600.000100" "$SLACK_PICKER_CACHE_DIR/threads.tsv"
    [ "$output" = "1" ]
}

@test "search: the thread root comes from the permalink, not the message" {
    stub_search
    "$REPO_ROOT/bin/slack-pick-thread" --warm 2>/dev/null
    run render mine
    # The row points at the thread root, never at my reply inside it.
    [[ "$output" == *"/p1700000000111111"* ]]
    [[ "$output" != *"/p1700000600000100"* ]]
}

@test "search: a message with no thread_ts stands as its own thread" {
    stub_search
    "$REPO_ROOT/bin/slack-pick-thread" --warm 2>/dev/null
    run cut -f7 "$SLACK_PICKER_CACHE_DIR/threads.tsv"
    [[ "$output" == *"D0DM00001/1700000800.000100"* ]]
}

@test "search: the marker says whose words the row shows" {
    stub_search
    "$REPO_ROOT/bin/slack-pick-thread" --warm 2>/dev/null
    run render mine
    [[ "$output" == *"● "*"my later word"* ]]
    [[ "$output" == *"◐ "*"look at this"* ]]
}

@test "search: a DM is named after the person, not their user id" {
    stub_search
    "$REPO_ROOT/bin/slack-pick-thread" --warm 2>/dev/null
    run render mine
    [[ "$output" == *"@Avery"* ]]
    [[ "$output" != *"#U_OTHER"* ]]
}

@test "search: an uncaptioned upload is still described" {
    stub_search
    "$REPO_ROOT/bin/slack-pick-thread" --warm 2>/dev/null
    run render mine
    [[ "$output" == *"shot.png"* ]]
}

@test "search: a workspace query is a view, and does not become your thread list" {
    # Persisting it would leave the next picker opening on a one-off search for
    # the rest of the cache's life.
    stub_search
    "$REPO_ROOT/bin/slack-pick-thread" --warm 2>/dev/null
    before=$(md5sum < "$SLACK_PICKER_CACHE_DIR/threads.tsv")
    run "$REPO_ROOT/bin/slack-pick-thread" --render-query "some words"
    [ "$status" -eq 0 ]
    [ "$(md5sum < "$SLACK_PICKER_CACHE_DIR/threads.tsv")" = "$before" ]
}

@test "search: without the scope, the sweep is what runs" {
    with_scopes "channels:read channels:history groups:read groups:history users:read"
    rm -f "$SLACK_PICKER_CACHE_DIR/threads.tsv" "$SLACK_PICKER_CACHE_DIR/channels.tsv"
    stub_slack
    "$REPO_ROOT/bin/slack-pick-thread" --warm 2>/dev/null || true
    run cat "$TEST_TMPDIR/seen-args.log"
    [[ "$output" == *"conversations.history"* ]]
    [[ "$output" != *"search.messages"* ]]
}

# --- scopes ------------------------------------------------------------------
#
# A missing scope makes Slack answer every call with missing_scope. Each answer
# is discarded, the sweep ends with nothing, and the picker reports that you have
# no threads — which is why this is checked up front and said out loud.

# Re-seed the identity with a given scope set, keeping the fingerprint valid so
# nothing goes to the network.
with_scopes() {
    cat > "$SLACK_PICKER_CACHE_DIR/identity" <<EOF
SLACK_ME=U_ME
SLACK_HOST=example.slack.com
SLACK_WHO=tester
SLACK_TEAM=TestTeam
SLACK_TOKEN_FP=$TOKEN_FP
SLACK_SCOPES="$1"
EOF
}

@test "scopes: a token that cannot read history is refused, loudly and by name" {
    with_scopes "channels:read users:read"
    run "$REPO_ROOT/bin/slack-pick-thread"
    [ "$status" -eq 2 ]
    [[ "$output" == *"missing scopes it needs"* ]]
    [[ "$output" == *"channels:history"* ]]
    # Names the variable to fix, since two different tokens can end up here.
    [[ "$output" == *"SLACK_USER_TOKEN"* ]]
}

@test "scopes: refusing is exit 2, so the caller falls back to pasting" {
    with_scopes "channels:read"
    run "$REPO_ROOT/bin/slack-pick-thread"
    # Not 1 — that means "the user declined to post".
    [ "$status" -eq 2 ]
    [[ "$output" == *"paste a Slack URL instead"* ]]
}

@test "scopes: --check names what is missing and exits 2" {
    stub_slack_scopes "channels:read users:read"
    run "$REPO_ROOT/bin/slack-pick-thread" --check
    [ "$status" -eq 2 ]
    [[ "$output" == *"channels:history"* ]]
}

@test "scopes: even a render reload refuses, rather than redrawing an empty list" {
    with_scopes "channels:read users:read"
    run "$REPO_ROOT/bin/slack-pick-thread" --render mine
    [ "$status" -eq 2 ]
}

@test "scopes: a complete token is not refused" {
    with_scopes "channels:read channels:history groups:read groups:history users:read"
    seed_threads "$(printf '1700000000.1\t1\tgeneral\tU_ME\t3\thello\tC0PUB0001/1700000000.111111')"
    run render mine
    [ "$status" -eq 0 ]
    [[ "$output" == *"hello"* ]]
}

@test "scopes: without the private ones, only public channels are asked for" {
    # Requesting private_channel without groups:read fails the whole call and
    # takes the public channels down with it, so the question has to narrow.
    with_scopes "channels:read channels:history users:read"
    rm -f "$SLACK_PICKER_CACHE_DIR/channels.tsv"
    stub_slack
    "$REPO_ROOT/bin/slack-pick-thread" --warm 2>/dev/null || true
    run cat "$TEST_TMPDIR/seen-args.log"
    [[ "$output" == *"types=public_channel"* ]]
    [[ "$output" != *"private_channel"* ]]
}

@test "scopes: with the private ones, private channels are asked for too" {
    with_scopes "channels:read channels:history groups:read groups:history users:read"
    rm -f "$SLACK_PICKER_CACHE_DIR/channels.tsv"
    stub_slack
    "$REPO_ROOT/bin/slack-pick-thread" --warm 2>/dev/null || true
    run cat "$TEST_TMPDIR/seen-args.log"
    [[ "$output" == *"types=public_channel,private_channel"* ]]
}

@test "scopes: a bot token is refused, however well scoped it is" {
    # The trap this closes: bot and user tokens use the SAME scope names, so a
    # bot token passes a check that only reads scopes — and then sweeps the
    # channels the BOT is in and calls the result yours.
    cat > "$SLACK_PICKER_CACHE_DIR/identity" <<EOF
SLACK_ME=U_BOT
SLACK_HOST=example.slack.com
SLACK_WHO=dev-workflow-bot
SLACK_TEAM=TestTeam
SLACK_BOT_ID=B0123BOT
SLACK_TOKEN_FP=$TOKEN_FP
SLACK_SCOPES="channels:read channels:history groups:read groups:history users:read"
EOF
    run "$REPO_ROOT/bin/slack-pick-thread"
    [ "$status" -eq 2 ]
    [[ "$output" == *"is a bot token"* ]]
    [[ "$output" == *"User OAuth Token"* ]]
}

@test "scopes: a rotated token re-checks instead of trusting the cached answer" {
    # Cached identity says the scopes are fine, but it was written for a token
    # that is no longer the one in play — so it must not be believed.
    with_scopes "channels:read channels:history groups:read groups:history users:read"
    sed -i "s/^SLACK_TOKEN_FP=.*/SLACK_TOKEN_FP=stale000000000/" "$SLACK_PICKER_CACHE_DIR/identity"
    stub_slack_scopes "channels:read"
    run "$REPO_ROOT/bin/slack-pick-thread"
    [ "$status" -eq 2 ]
    [[ "$output" == *"channels:history"* ]]
}

# --- availability ------------------------------------------------------------

@test "the token comes from SLACK_USER_TOKEN alone, never another app's" {
    # A token is issued per app install. Falling back to the reaction-notifier's
    # would make this tool work or break according to an app you aren't
    # configuring, and report that app's scopes when you went looking for why.
    run grep -c "SLACK_REACT_TOKEN" "$REPO_ROOT/bin/slack-pick-thread"
    [ "$output" = "0" ]
}

@test "no token at all is a quiet skip, not a misconfiguration" {
    # Pasting still works, so an unconfigured picker must not shout on every run.
    SLACK_USER_TOKEN="" run "$REPO_ROOT/bin/slack-pick-thread"
    [ "$status" -eq 2 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *"SLACK_USER_TOKEN not set"* ]]
}

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

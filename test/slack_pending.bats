#!/usr/bin/env bats

# Tests for the resumable Slack post.
#
# Once the MR exists, the only thing a run can still lose is where in Slack it
# should be announced — that answer lives in a prompt and nowhere else. So the
# outstanding post is written down before the prompt, and a re-run serves it
# without redoing the push or the MR.
#
# The stubs here matter: publish-changes sources the repo's real .env, which
# carries a live Slack bot token, so `curl` is stubbed in every test that can
# reach the Slack API.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    TEST_TMPDIR=$(mktemp -d)
    PUSH_LOG="$TEST_TMPDIR/push.log"
    GLAB_LOG="$TEST_TMPDIR/glab.log"
    CURL_LOG="$TEST_TMPDIR/curl.log"

    # Both scripts key their caches off $HOME.
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"

    STUB_BIN="$TEST_TMPDIR/stubs"
    mkdir -p "$STUB_BIN"
    export PATH="$STUB_BIN:$PATH"

    GIT_REPO="$TEST_TMPDIR/repo"
    mkdir -p "$GIT_REPO"
    git init -q -b main "$GIT_REPO"
    git -C "$GIT_REPO" config user.email test@test
    git -C "$GIT_REPO" config user.name test
    git -C "$GIT_REPO" commit -q --allow-empty -m "initial"
    git -C "$GIT_REPO" remote add origin "$TEST_TMPDIR/remote.git"

    THREAD_URL="https://example.slack.com/archives/C0123ABCD/p1700000000000100"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# --- stubs -------------------------------------------------------------------

stub_git_push() {
    local real_git
    real_git=$(command -v git)
    cat > "$STUB_BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then
    echo "push \$*" >> "$PUSH_LOG"
    exit 0
fi
exec "$real_git" "\$@"
EOF
    chmod +x "$STUB_BIN/git"
}

# Records every glab subcommand. `auth status` and `mr list` succeed (the latter
# with no MRs, so an unguarded run would go on to create one); the rest fail
# harmlessly, which is enough to tell "created an MR" from "didn't".
stub_glab() {
    cat > "$STUB_BIN/glab" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GLAB_LOG"
case "\$1 \$2" in
    "auth status") exit 0 ;;
    "mr list") echo '[]'; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$STUB_BIN/glab"
}

# Slack API stub. Answers conversations.info as "bot is in the channel" and
# chat.postMessage as sent, and logs each call so a test can assert on what was
# announced. Anything else (Jira) gets an empty object.
stub_curl() {
    cat > "$STUB_BIN/curl" <<EOF
#!/usr/bin/env bash
args="\$*"
echo "\$args" >> "$CURL_LOG"
case "\$args" in
    *conversations.info*) echo '{"ok":true,"channel":{"is_member":true}}' ;;
    *chat.postMessage*)   echo '{"ok":true}' ;;
    *)                    echo '{}' ;;
esac
exit 0
EOF
    chmod +x "$STUB_BIN/curl"
}

# Write a pending record for $1 at the branch's current HEAD.
write_pending() {
    local branch="${1:-main}"
    local post_ticket="${2:-false}"
    local slack_url="${3:-}"
    ( cd "$GIT_REPO" && \
      PENDING_SLACK_DIR="$HOME/.cache/publish-changes/pending-slack" \
      bash -c "source '$REPO_ROOT/lib/slack.sh'; \
               save_pending_slack '$branch' 'https://gl.test/mr/42' 'a title' \
                                  'PROJ-1' 'a summary' '$post_ticket' '$slack_url'" )
}

pending_file() {
    ( cd "$GIT_REPO" && \
      bash -c "source '$REPO_ROOT/lib/slack.sh'; pending_slack_file" )
}

# --- the record --------------------------------------------------------------

@test "pending record: saved and loaded back for the same branch and commit" {
    write_pending main
    cd "$GIT_REPO"
    source "$REPO_ROOT/lib/slack.sh"
    run load_pending_slack main
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r .mr_url)" = "https://gl.test/mr/42" ]
    [ "$(echo "$output" | jq -r .mr_title)" = "a title" ]
}

@test "pending record: a record for another branch does not apply here" {
    write_pending some-other-branch
    cd "$GIT_REPO"
    source "$REPO_ROOT/lib/slack.sh"
    run load_pending_slack main
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "pending record: a moved HEAD means there is work the MR has not seen" {
    write_pending main
    cd "$GIT_REPO"
    git commit -q --allow-empty -m "later work"
    source "$REPO_ROOT/lib/slack.sh"
    run load_pending_slack main
    [ "$status" -ne 0 ]
}

@test "pending record: a moved HEAD does not destroy the record" {
    write_pending main
    cd "$GIT_REPO"
    git commit -q --allow-empty -m "later work"
    # The normal flow ends at the same prompt and clears it there — losing the
    # record here would strand the MR link if that run were interrupted too.
    [ -f "$(pending_file)" ]
}

@test "pending record: clearing removes it" {
    write_pending main
    cd "$GIT_REPO"
    source "$REPO_ROOT/lib/slack.sh"
    clear_pending_slack
    run load_pending_slack main
    [ "$status" -ne 0 ]
}

@test "pending record: sibling worktrees keep separate records" {
    write_pending main
    git -C "$GIT_REPO" worktree add -q -b side "$TEST_TMPDIR/side" >/dev/null 2>&1
    cd "$TEST_TMPDIR/side"
    source "$REPO_ROOT/lib/slack.sh"
    run load_pending_slack side
    [ "$status" -ne 0 ]
}

# --- publish-changes ---------------------------------------------------------

@test "publish-changes: a pending post is served without re-pushing or re-creating the MR" {
    stub_git_push
    stub_glab
    stub_curl
    write_pending main false
    cd "$GIT_REPO"

    run "$REPO_ROOT/bin/publish-changes" \
        --branch main --target main --no-jira --no-draft-prompt \
        --slack-url "$THREAD_URL"

    [ "$status" -eq 0 ]
    [[ "$output" == *"only its Slack post is outstanding"* ]]
    [ ! -f "$PUSH_LOG" ]
    [[ "$(cat "$GLAB_LOG")" != *"mr create"* ]]
    [[ "$(cat "$CURL_LOG")" == *chat.postMessage* ]]
}

@test "publish-changes: a served post stops being pending" {
    stub_git_push
    stub_glab
    stub_curl
    write_pending main false
    cd "$GIT_REPO"

    run "$REPO_ROOT/bin/publish-changes" \
        --branch main --target main --no-jira --no-draft-prompt \
        --slack-url "$THREAD_URL"

    [ "$status" -eq 0 ]
    [ ! -f "$(pending_file)" ]
}

@test "publish-changes: a post that fails stays pending" {
    stub_git_push
    stub_glab
    # No curl stub for chat.postMessage success: make every Slack call fail.
    cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo '{"ok":false,"error":"stubbed_failure"}'
exit 0
EOF
    chmod +x "$STUB_BIN/curl"
    write_pending main false
    cd "$GIT_REPO"

    run "$REPO_ROOT/bin/publish-changes" \
        --branch main --target main --no-jira --no-draft-prompt \
        --slack-url "$THREAD_URL"

    [[ "$output" == *"Left pending"* ]]
    [ -f "$(pending_file)" ]
}

@test "publish-changes: the pending record carries the MR url out to --output-url callers" {
    stub_git_push
    stub_glab
    stub_curl
    write_pending main false
    cd "$GIT_REPO"

    run "$REPO_ROOT/bin/publish-changes" \
        --branch main --target main --no-jira --no-draft-prompt --output-url \
        --slack-url "$THREAD_URL"

    [ "$status" -eq 0 ]
    [[ "${lines[-1]}" == "https://gl.test/mr/42" ]]
}

@test "publish-changes: a branch with new commits takes the normal path, pending record or not" {
    stub_git_push
    stub_glab
    stub_curl
    write_pending main false
    cd "$GIT_REPO"
    git commit -q --allow-empty -m "later work"

    run "$REPO_ROOT/bin/publish-changes" \
        --branch main --target main --no-jira --no-draft-prompt \
        --slack-url "$THREAD_URL"

    [[ "$output" != *"only its Slack post is outstanding"* ]]
    [ -f "$PUSH_LOG" ]
}

@test "publish-changes: asking where to post is one prompt, not a y/N gate in front of one" {
    # The prompt text is the contract: a gate answered with a keystroke in front
    # of the paste is one more thing to fumble at the end of a long run.
    run grep -c "Post MR link to Slack?" "$REPO_ROOT/bin/publish-changes"
    [ "$output" = "0" ]
    run grep -c "Enter to skip" "$REPO_ROOT/bin/publish-changes"
    [ "$output" = "1" ]
}

# --- oneshot -----------------------------------------------------------------

@test "oneshot: a pending post is handed to publish-changes instead of rerunning the pipeline" {
    stub_git_push
    stub_glab
    stub_curl
    write_pending main false
    cd "$GIT_REPO"

    run "$REPO_ROOT/bin/oneshot"

    [ "$status" -eq 0 ]
    [[ "$output" == *"only its Slack post is outstanding"* ]]
    [[ "$output" == *"=== Done ==="* ]]
    # Nothing was staged and the MR is up: no commit, no push, no MR.
    [ ! -f "$PUSH_LOG" ]
    [[ "$(cat "$GLAB_LOG")" != *"mr create"* ]]
}

@test "oneshot: staged changes mean there is more to do than the Slack post" {
    stub_git_push
    stub_glab
    stub_curl
    write_pending main false
    cd "$GIT_REPO"
    echo change > file.txt
    git add file.txt

    run "$REPO_ROOT/bin/oneshot"

    [[ "$output" != *"only its Slack post is outstanding"* ]]
}

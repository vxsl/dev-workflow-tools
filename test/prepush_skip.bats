#!/usr/bin/env bats

# Tests for --no-autofix and --no-verify in oneshot and publish-changes.
#
# --no-autofix suppresses the hook's prettier/eslint stage (which rewrites files
# and commits the result) by setting SKIP_PRE_PUSH_AUTOFIX=true, leaving the
# checks running. --no-verify skips the hook outright. Both tests assert on what
# the hook/push actually saw — its environment and argv — not on script output.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    TEST_TMPDIR=$(mktemp -d)
    ENV_LOG="$TEST_TMPDIR/seen-env.log"

    # Isolate caches/state (both scripts write under $HOME/.cache).
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
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# git stub that records how `git push` was invoked — the autofix env var and the
# full argv — then short-circuits it, delegating every other subcommand to real git.
stub_git_push() {
    local real_git
    real_git=$(command -v git)
    cat > "$STUB_BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "push" ]; then
    echo "SKIP_PRE_PUSH_AUTOFIX=\${SKIP_PRE_PUSH_AUTOFIX-<unset>} argv=\$*" >> "$ENV_LOG"
    exit 0
fi
exec "$real_git" "\$@"
EOF
    chmod +x "$STUB_BIN/git"
}

# glab stub: `auth status` passes the startup check, everything else fails so the
# script stops right after the push instead of trying to create a real MR.
stub_glab() {
    cat > "$STUB_BIN/glab" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "auth" ] && exit 0
exit 1
EOF
    chmod +x "$STUB_BIN/glab"
}

# Pre-push hook that records the autofix env var and fails, so oneshot aborts at
# its pre-push step without going on to ticket selection or MR creation.
install_recording_hook() {
    local hooks="$TEST_TMPDIR/hooks"
    mkdir -p "$hooks"
    cat > "$hooks/pre-push" <<EOF
#!/usr/bin/env bash
cat >/dev/null   # drain the refs git/oneshot pipes in
echo "SKIP_PRE_PUSH_AUTOFIX=\${SKIP_PRE_PUSH_AUTOFIX:-<unset>}" >> "$ENV_LOG"
exit 1
EOF
    chmod +x "$hooks/pre-push"
    git -C "$GIT_REPO" config core.hooksPath "$hooks"
}

# --- publish-changes ---------------------------------------------------------

@test "publish-changes --no-autofix: push carries SKIP_PRE_PUSH_AUTOFIX=true" {
    stub_git_push
    stub_glab
    cd "$GIT_REPO"
    run "$REPO_ROOT/bin/publish-changes" \
        --branch main --target main --no-jira --no-draft-prompt --no-autofix
    [ -f "$ENV_LOG" ]
    [[ "$(cat "$ENV_LOG")" == "SKIP_PRE_PUSH_AUTOFIX=true "* ]]
}

@test "publish-changes without the flag: push leaves autofix enabled" {
    stub_git_push
    stub_glab
    cd "$GIT_REPO"
    run "$REPO_ROOT/bin/publish-changes" \
        --branch main --target main --no-jira --no-draft-prompt
    [ -f "$ENV_LOG" ]
    [[ "$(cat "$ENV_LOG")" == "SKIP_PRE_PUSH_AUTOFIX=<unset> "* ]]
}

@test "publish-changes --no-verify: push gets git's own --no-verify" {
    stub_git_push
    stub_glab
    cd "$GIT_REPO"
    run "$REPO_ROOT/bin/publish-changes" \
        --branch main --target main --no-jira --no-draft-prompt --no-verify
    [ -f "$ENV_LOG" ]
    [[ "$(cat "$ENV_LOG")" == *"--no-verify"* ]]
    # --no-verify skips the hook outright, so the env var isn't needed as well.
    [[ "$(cat "$ENV_LOG")" == "SKIP_PRE_PUSH_AUTOFIX=<unset> "* ]]
}

@test "publish-changes without --no-verify: push does not suppress the hook" {
    stub_git_push
    stub_glab
    cd "$GIT_REPO"
    run "$REPO_ROOT/bin/publish-changes" \
        --branch main --target main --no-jira --no-draft-prompt
    [ -f "$ENV_LOG" ]
    [[ "$(cat "$ENV_LOG")" != *"--no-verify"* ]]
}

# --- oneshot -----------------------------------------------------------------

@test "oneshot --no-autofix: pre-push hook runs with SKIP_PRE_PUSH_AUTOFIX=true" {
    install_recording_hook
    cd "$GIT_REPO"
    echo change > file.txt
    git add file.txt
    run "$REPO_ROOT/bin/oneshot" --hotfix "test hotfix" --no-autofix
    [ -f "$ENV_LOG" ]
    [ "$(cat "$ENV_LOG")" = "SKIP_PRE_PUSH_AUTOFIX=true" ]
}

@test "oneshot without the flag: pre-push hook runs with autofix enabled" {
    install_recording_hook
    cd "$GIT_REPO"
    echo change > file.txt
    git add file.txt
    run "$REPO_ROOT/bin/oneshot" --hotfix "test hotfix"
    [ -f "$ENV_LOG" ]
    # Set-but-empty is what an unflagged run passes; the hook's `!= "true"` test
    # treats it the same as unset, so autofix still runs.
    [ "$(cat "$ENV_LOG")" = "SKIP_PRE_PUSH_AUTOFIX=<unset>" ]
}

@test "oneshot --no-verify: the pre-push hook never runs" {
    install_recording_hook
    cd "$GIT_REPO"
    echo change > file.txt
    git add file.txt
    run "$REPO_ROOT/bin/oneshot" --hotfix "test hotfix" --no-verify
    # The recording hook exits 1, so its absence is what lets oneshot get past
    # Step 1.5 at all — it dies later, on a prompt with no tty.
    [ ! -f "$ENV_LOG" ]
    [[ "$output" == *"Skipping pre-push checks (--no-verify)"* ]]
}

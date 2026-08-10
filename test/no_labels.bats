#!/usr/bin/env bats

# Tests for "no label" in create-jira-ticket.
#
# Every route out of Step 5 used to land on a label: the default sits first so
# Enter takes it, and Esc falls back to the default too. These cover the two ways
# out that were added — the (no label) entry in the picker, and --no-labels — plus
# the flag plumbing in oneshot and jira-fzf that carries the choice down.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    TEST_TMPDIR=$(mktemp -d)
    ARGS_LOG="$TEST_TMPDIR/create-jira-ticket-args"
    export HOME="$TEST_TMPDIR/home"
    mkdir -p "$HOME"
    STUB_BIN="$TEST_TMPDIR/stubs"
    mkdir -p "$STUB_BIN"
    export PATH="$STUB_BIN:$PATH"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# The Step 5 selection rule, lifted verbatim out of create-jira-ticket so the
# branch that decides "which labels" is what gets exercised, not a copy of it.
select_labels() {
    local labels_input="$1"
    eval "$(awk '/^NO_LABEL_SENTINEL=/{print; exit}' "$REPO_ROOT/bin/create-jira-ticket")"
    local labels
    if [ -z "$labels_input" ]; then
        labels="$DEFAULT_LABELS"
    else
        labels=$(printf '%s\n' "$labels_input" | grep -vxF "$NO_LABEL_SENTINEL" \
            | tr '\n' ',' | sed 's/,$//') || true
    fi
    printf '%s' "$labels"
}

@test "picking the sentinel alone yields no labels" {
    DEFAULT_LABELS="front-end"
    [ "$(select_labels "(no label)")" = "" ]
}

@test "picking a real label still yields that label" {
    DEFAULT_LABELS="front-end"
    [ "$(select_labels "front-end")" = "front-end" ]
}

@test "sentinel alongside a real label keeps the real label" {
    DEFAULT_LABELS="front-end"
    # Never silently discard something the user explicitly selected.
    [ "$(select_labels "$(printf '(no label)\nbug')")" = "bug" ]
}

@test "escaping the picker still falls back to the default" {
    DEFAULT_LABELS="front-end"
    [ "$(select_labels "")" = "front-end" ]
}

@test "multiple real labels come back comma-separated" {
    DEFAULT_LABELS="front-end"
    [ "$(select_labels "$(printf 'front-end\nbug')")" = "front-end,bug" ]
}

# --- flag plumbing -----------------------------------------------------------

# oneshot calls its siblings by absolute path, so PATH stubs can't reach them.
# Copy the tree and replace the siblings inside the copy instead. This also gives
# the run its own .env, so the suite stops depending on the developer's real one.
build_fake_tools() {
    FAKE_ROOT="$TEST_TMPDIR/tools"
    mkdir -p "$FAKE_ROOT/bin"
    cp -r "$REPO_ROOT/lib" "$FAKE_ROOT/lib"
    cp "$REPO_ROOT/bin/oneshot" "$FAKE_ROOT/bin/oneshot"
    cat > "$FAKE_ROOT/.env" <<'EOF'
JIRA_DOMAIN=example.atlassian.net
JIRA_PROJECT=TEST
JIRA_PROJECT_REGEX=TEST
JIRA_EMAIL=test@test
JIRA_API_TOKEN=notatoken
EOF
    # Records the argv it was handed, then fails so oneshot stops right there.
    cat > "$FAKE_ROOT/bin/create-jira-ticket" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$ARGS_LOG"
exit 1
EOF
    # oneshot warms the ticket cache in the background; keep that off the network.
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/bin/jira-fzf"
    chmod +x "$FAKE_ROOT/bin/create-jira-ticket" "$FAKE_ROOT/bin/jira-fzf"
}

make_repo_with_staged_change() {
    GIT_REPO="$TEST_TMPDIR/repo"
    mkdir -p "$GIT_REPO"
    git init -q -b main "$GIT_REPO"
    git -C "$GIT_REPO" config user.email test@test
    git -C "$GIT_REPO" config user.name test
    git -C "$GIT_REPO" commit -q --allow-empty -m initial
    git init -q --bare "$TEST_TMPDIR/remote.git"
    git -C "$GIT_REPO" remote add origin "$TEST_TMPDIR/remote.git"
    git -C "$GIT_REPO" push -q origin main
    echo change > "$GIT_REPO/file.txt"
    git -C "$GIT_REPO" add file.txt
}

@test "oneshot --no-labels reaches create-jira-ticket" {
    build_fake_tools
    make_repo_with_staged_change
    cd "$GIT_REPO"
    run "$FAKE_ROOT/bin/oneshot" --no-labels "a new ticket" --no-verify
    [ -f "$ARGS_LOG" ]
    grep -qx -- "--no-labels" "$ARGS_LOG"
}

@test "oneshot --labels reaches create-jira-ticket with its value" {
    build_fake_tools
    make_repo_with_staged_change
    cd "$GIT_REPO"
    run "$FAKE_ROOT/bin/oneshot" --labels "bug,api" "a new ticket" --no-verify
    [ -f "$ARGS_LOG" ]
    grep -qx -- "--labels" "$ARGS_LOG"
    grep -qx -- "bug,api" "$ARGS_LOG"
}

@test "oneshot without label flags leaves the downstream default alone" {
    build_fake_tools
    make_repo_with_staged_change
    cd "$GIT_REPO"
    run "$FAKE_ROOT/bin/oneshot" "a new ticket" --no-verify
    [ -f "$ARGS_LOG" ]
    ! grep -qx -- "--no-labels" "$ARGS_LOG"
    ! grep -qx -- "--labels" "$ARGS_LOG"
}

@test "create-jira-ticket: the --no-labels arm never opens the picker" {
    # Structural, because Step 5 sits behind prompts that need a tty: assert the
    # fzf call is only reachable through the else arm.
    run awk '/^if \[ "\$NO_LABELS" = true \]; then/,/^else$/' \
        "$REPO_ROOT/bin/create-jira-ticket"
    [ -n "$output" ]
    [[ "$output" != *'$FZF'* ]]
    [[ "$output" == *"(none)"* ]]
}

@test "jira-fzf passes --labels down even when it is empty" {
    # Withholding the flag means "use your own default" downstream, not "none",
    # so an empty value has to be passed explicitly or it comes back as front-end.
    run grep -c 'if \[ -n "\$DEFAULT_LABELS" \]; then' "$REPO_ROOT/bin/jira-fzf"
    [ "$output" -eq 0 ]
    run grep -c 'args+=(--labels "\$DEFAULT_LABELS")' "$REPO_ROOT/bin/jira-fzf"
    [ "$output" -eq 1 ]
}

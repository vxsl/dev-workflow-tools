#!/usr/bin/env bats
# bin/rr.sh pane switching — getting a tmux pane onto a different worktree.
#
# The whole operation is "type into someone else's terminal", which is only safe in one
# specific state: the pane's own shell sitting at a prompt with an empty line editor. Every
# bug this file guards against is the same bug — typing before that is true.
#
# The symptom is not a clean failure. It is a pane holding
#     ea "/path/to/worktree" 2>/dev/null || echo '✗ Failed to cd to /path/to/worktree'
# unexecuted, because the `cd` went into a dying dev server and the fragment that reached
# zle afterwards was read as key bindings rather than text. Nothing reports an error; the
# dev server is simply gone and the worktree never changed.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    RR="$REPO_ROOT/bin/rr.sh"

    eval "$(sed -n '/^IDLE_PANE_SHELLS=/p' "$RR")"
    local f
    for f in pane_foreground_command pane_is_at_prompt pane_foreground_pgid \
             signal_pane_foreground wait_for_pane_prompt reclaim_pane \
             send_pane_command tmux_pane_exists switch_pane_target; do
        eval "$(sed -n "/^$f()/,/^}/p" "$RR")"
    done

    PANE=fake:0.0
    TRACE="$BATS_TEST_TMPDIR/trace"
    PASTED="$BATS_TEST_TMPDIR/pasted"
    FG="$BATS_TEST_TMPDIR/fg"
    COUNTDOWN="$BATS_TEST_TMPDIR/countdown"
    : > "$TRACE"
    : > "$PASTED"
    echo zsh > "$FG"
    echo 0 > "$COUNTDOWN"
    IN_MODE=0
    DIES_ON=keys       # keys | INT | TERM | never
    DIE_AFTER_POLLS=0  # how many more polls the program survives after its signal
}

# --- fake tmux/ps/kill, recording every call ---------------------------------

# The fake pane runs one program. It dies when it receives whatever signal DIES_ON
# names, and then takes DIE_AFTER_POLLS further polls to actually let go of the tty
# — which is the window the real bug lives in.
_fake_program_dies() {
    [ "$(cat "$FG")" = zsh ] && return
    echo "$DIE_AFTER_POLLS" > "$COUNTDOWN"
    [ "$DIE_AFTER_POLLS" -eq 0 ] && echo zsh > "$FG"
}

_fake_foreground() {
    local left
    left=$(cat "$COUNTDOWN")
    if [ "$left" -gt 0 ]; then
        echo $((left - 1)) > "$COUNTDOWN"
        [ "$left" -eq 1 ] && echo zsh > "$FG"
    fi
    cat "$FG"
}

tmux() {
    echo "tmux $*" >> "$TRACE"
    case "$1" in
        list-panes) echo "$PANE" ;;
        display-message)
            case "$*" in
                *pane_current_command*) _fake_foreground ;;
                *pane_pid*)             echo 4242 ;;
                *pane_in_mode*)         echo "$IN_MODE" ;;
            esac
            ;;
        set-buffer)  printf '%s' "${*: -1}" > "$PASTED" ;;
        send-keys)
            case "$*" in
                *C-c*) [ "$DIES_ON" = keys ] && _fake_program_dies ;;
            esac
            ;;
    esac
    return 0
}

ps() { echo 4300; }   # tpgid of the pane's foreground group

kill() {
    echo "kill $*" >> "$TRACE"
    local sig="${1#-}"
    [ "$sig" = "$DIES_ON" ] && _fake_program_dies
    return 0
}

sleep() { :; }   # the code under test is full of settle delays; tests skip them

trace_has()  { grep -q -- "$1" "$TRACE"; }
line_of()    { grep -n -- "$1" "$TRACE" | head -1 | cut -d: -f1; }
polls_before() { sed -n "1,$(line_of "$1")p" "$TRACE" | grep -c pane_current_command; }

# --- what counts as safe to type into ----------------------------------------

@test "a shell at a prompt is safe to type into; a dev server is not" {
    pane_is_at_prompt zsh
    pane_is_at_prompt bash
    pane_is_at_prompt fish
    ! pane_is_at_prompt node
    ! pane_is_at_prompt yarn
    ! pane_is_at_prompt nvim
}

# tmux reports a login shell as -zsh, and a pane whose shell was started as one would
# otherwise never look idle — the switch would always escalate to SIGTERM and then refuse.
@test "a login shell reported as -zsh is still a shell" {
    pane_is_at_prompt -zsh
    pane_is_at_prompt -bash
}

# The point of a bounded wait is that it can fail. Returning 0 on timeout would put us
# back to typing into whatever is still holding the terminal.
@test "waiting for a prompt gives up rather than pretending" {
    echo node > "$FG"
    run wait_for_pane_prompt "$PANE" 3
    [ "$status" -eq 1 ]
}

# --- the ordering that is the whole point ------------------------------------

@test "nothing is typed into the pane until the shell is actually back" {
    echo node > "$FG"
    DIE_AFTER_POLLS=8

    run switch_pane_target dev "$PANE" /tmp/wt "" 'yarn dev'
    [ "$status" -eq 0 ]

    # The paste must come after the polls that saw the program still running, not
    # after a fixed sleep that happened to be shorter than node's shutdown.
    [ "$(polls_before paste-buffer)" -ge 8 ]
}

@test "a program that swallows ^C is escalated to a real signal, in order" {
    echo node > "$FG"
    DIES_ON=TERM

    run switch_pane_target dev "$PANE" /tmp/wt "" 'yarn dev'
    [ "$status" -eq 0 ]

    # ^C first (it is what the user would press), then SIGINT, then SIGTERM
    [ "$(line_of 'send-keys.*C-c')" -lt "$(line_of 'kill -INT')" ]
    [ "$(line_of 'kill -INT')" -lt "$(line_of 'kill -TERM')" ]
}

# The failure that matters: refusing is correct, typing anyway is the reported bug.
@test "a pane that never comes back is reported, not typed into" {
    echo node > "$FG"
    DIES_ON=never

    run switch_pane_target dev "$PANE" /tmp/wt "" 'yarn dev'
    [ "$status" -eq 1 ]
    [[ "$output" == *"still busy"* ]]
    [[ "$output" == *node* ]]        # name the program holding the terminal
    ! trace_has paste-buffer
}

# --- how the command gets in --------------------------------------------------

# Sent character by character, every character is a chance for the line editor to read
# it as a binding instead of text. One bracketed paste is one widget call.
@test "the command goes in as one bracketed paste and one Enter" {
    run switch_pane_target dev "$PANE" /tmp/wt "" 'yarn dev'
    [ "$status" -eq 0 ]

    [ "$(grep -c 'paste-buffer' "$TRACE")" -eq 1 ]
    trace_has 'paste-buffer.*-p'
    [ "$(grep -c 'send-keys.*C-m' "$TRACE")" -eq 1 ]
    # the payload must never be handed to send-keys as text
    ! grep 'send-keys' "$TRACE" | grep -q '/tmp/wt'
}

# `send-keys C-c` is a keystroke, and at a zsh prompt with zsh-vi-mode loaded it is
# measurably a no-op — the junk survives and gets prefixed onto our command, which is
# how `half typed junk` + `clear; ...` ends up executing as one line.
@test "the line editor is cleared with a signal, not a ^C keystroke" {
    run switch_pane_target dev "$PANE" /tmp/wt "" 'yarn dev'
    [ "$status" -eq 0 ]
    [ "$(line_of 'kill -INT')" -lt "$(line_of 'paste-buffer')" ]
}

@test "clear, cd, pwd and the pane command arrive as a single buffer" {
    run switch_pane_target dev "$PANE" /tmp/wt "" 'yarn tsc-watch'
    [ "$status" -eq 0 ]

    local payload
    payload=$(cat "$PASTED")
    [[ "$payload" == *"clear;"* ]]
    [[ "$payload" == *'cd "/tmp/wt"'* ]]
    [[ "$payload" == *"pwd"* ]]
    [[ "$payload" == *"Failed to cd to /tmp/wt"* ]]   # a bad path still says so
    [[ "$payload" == *"yarn tsc-watch"* ]]
    # the pane command on its own line, so a failed cd cannot swallow it into a comment
    [ "$(printf '%s\n' "$payload" | wc -l)" -eq 2 ]
}

@test "a pane with no command to run still gets the cd" {
    run switch_pane_target dev "$PANE" /tmp/wt "" ""
    [ "$status" -eq 0 ]
    [[ "$(cat "$PASTED")" == *'cd "/tmp/wt"'* ]]
    [ "$(printf '%s\n' "$(cat "$PASTED")" | wc -l)" -eq 1 ]
}

# send-keys into a pane sitting in copy mode drives copy mode. The keys are consumed as
# scroll/search and the pane never moves.
@test "copy mode is cancelled before anything is sent" {
    IN_MODE=1
    run switch_pane_target dev "$PANE" /tmp/wt "" 'yarn dev'
    [ "$status" -eq 0 ]
    trace_has 'send-keys.*-X cancel'
    [ "$(line_of '\-X cancel')" -lt "$(line_of 'paste-buffer')" ]
}

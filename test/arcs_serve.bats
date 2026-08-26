#!/usr/bin/env bats
# Tests for arcs-serve -- the local cockpit daemon.
#
# This is the only program in this repo that turns an HTTP request into a command on the
# machine, so what is pinned here is not "does it serve a file". It is the three
# properties that make that safe, plus the two that make it useful:
#
#   the bind is loopback, asserted by reading /proc/net/tcp for the listening socket
#   rather than by trusting the sentence the daemon logs about itself
#
#   POST /act is 403 without the X-Arcs-Act header, and nothing runs on the way to that
#   403 -- a guard that has already resumed a session before it refuses is not a guard
#
#   no Access-Control-* header is emitted on any route, because the header guard is only
#   a guard for as long as a cross-origin preflight has nothing to succeed against
#
#   the served bytes state utf-8, which is the whole reason this is not http.server: what
#   arcs-page writes is a fragment with no meta charset, and a browser left to guess
#   turns every dash and arrow on the page into mojibake
#
#   the verbs are exactly the tmux invocations orch itself uses, asserted argv by argv,
#   because "opens a window" is true of a hundred wrong commands
#
# The seam is WORK_ARCS_TMUX_BIN and not an orch path. The todo that asked for these
# tests said to stub orch, and the same todo's own survey is why that would test nothing:
# the verbs go straight to tmux, so stubbing a binary the daemon never calls would assert
# only that the stub stayed unused. The stub here records its argv one word per line and
# takes its exit codes from the environment, so a test can put any tmux answer in front
# of the daemon without a tmux server existing.
#
# HOME is the temp dir throughout, which is not a nicety either: session_label and the
# transcript check both walk ~/.claude, and a suite that read the real one would pass or
# fail according to which sessions happened to be open on the machine running it.

load test_helper/common

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

SERVE_UUID="0696c976-3f98-482f-a98a-30417d8182c9"

setup() {
    setup_temp_dir

    export HOME="$TEST_TMPDIR/home"
    export XDG_STATE_HOME="$HOME/.local/state"
    STATE="$XDG_STATE_HOME/work-arcs"
    mkdir -p "$STATE" "$HOME/.claude/sessions" "$HOME/.claude/projects/-a-repo"

    LOG="$STATE/arcs-serve.log"
    PAGE="$STATE/page.html"

    # Non-ASCII on purpose. The em-dash and the tick are the two characters that were
    # mojibake the first time this page was opened outside the artifact runtime, so the
    # fixture is the bug.
    printf '<h1>Work Arcs</h1><p>caf\xc3\xa9 \xe2\x80\x94 \xe2\x9c\x93 done</p>\n' >"$PAGE"

    export TMUX_ARGV_LOG="$TEST_TMPDIR/tmux-argv.log"
    : >"$TMUX_ARGV_LOG"
    export WORK_ARCS_TMUX_BIN="$TEST_TMPDIR/tmux-stub"
    write_tmux_stub

    DAEMON_PID=""
}

teardown() {
    if [ -n "$DAEMON_PID" ]; then
        kill -TERM "$DAEMON_PID" 2>/dev/null || true
        wait "$DAEMON_PID" 2>/dev/null || true
    fi
    teardown_temp_dir
}

# --- the stub tmux ----------------------------------------------------------------------

# Records argv one word per line, then a line holding two dashes as a block separator, so
# an exact-argv assertion is a plain string comparison and a word containing a space could
# never be mistaken for two words. Exit codes come from the environment; each refusal
# prints the sentence the real tmux prints, so the "relayed verbatim" test has something
# real to look for.
write_tmux_stub() {
    cat >"$WORK_ARCS_TMUX_BIN" <<'STUBEOF'
#!/usr/bin/env bash
{
    for a in "$@"; do printf '%s\n' "$a"; done
    printf -- '--\n'
} >>"$TMUX_ARGV_LOG"

sock="default"
sub="$1"
if [ "$1" = "-L" ]; then sock="$2"; sub="$3"; fi

rc=0
msg=""
case "$sock/$sub" in
    default/has-session)
        rc="${STUB_DEFAULT_ORCH:-0}";  msg="no server running on /tmp/tmux-1000/default" ;;
    orch-sessions/has-session)
        rc="${STUB_SESSION_ALIVE:-0}"; msg="can't find session: $5" ;;
    orch-sessions/list-sessions)
        rc="${STUB_ORCH_SERVER:-0}";   msg="no server running on /tmp/tmux-1000/orch-sessions" ;;
    orch-sessions/new-session)
        rc="${STUB_NEW_SESSION:-0}";   msg="duplicate session: $5" ;;
    default/new-window)
        rc="${STUB_NEW_WINDOW:-0}";    msg="create window failed: index in use: 0" ;;
esac

if [ "$rc" != "0" ]; then printf '%s\n' "$msg" >&2; fi
exit "$rc"
STUBEOF
    chmod +x "$WORK_ARCS_TMUX_BIN"
}

# --- fixtures ---------------------------------------------------------------------------

# What Claude Code writes into ~/.claude/sessions: keyed by pid, with the session id as a
# field inside, which is why the daemon scans rather than looks up.
write_session_json() {
    local uuid="$1" name="$2" pid="${3:-51746}"
    printf '{"pid":%s,"sessionId":"%s","cwd":"/a/repo","name":"%s","status":"idle"}\n' \
        "$pid" "$uuid" "$name" >"$HOME/.claude/sessions/$pid.json"
}

write_transcript() {
    printf '{}\n' >"$HOME/.claude/projects/-a-repo/$1.jsonl"
}

# --- running the daemon -----------------------------------------------------------------

free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

start_daemon() {
    PORT="$(free_port)"
    BASE="http://127.0.0.1:$PORT"
    "$REPO_ROOT/bin/arcs-serve" --port "$PORT" >"$TEST_TMPDIR/daemon.out" 2>&1 &
    DAEMON_PID=$!
    local i
    for i in $(seq 1 200); do
        if curl -sf -o /dev/null "$BASE/health"; then
            # The wait-for-ready poll is itself a request, and a test counting probes
            # must not count it. Reset after the daemon is known up.
            : >"$TMUX_ARGV_LOG"
            return 0
        fi
        kill -0 "$DAEMON_PID" 2>/dev/null || break
        sleep 0.05
    done
    echo "daemon never answered on $PORT:" >&2
    cat "$TEST_TMPDIR/daemon.out" >&2
    return 1
}

act() {
    curl -s -H 'X-Arcs-Act: 1' -H 'Content-Type: application/json' \
        -X POST "$BASE/act" -d "$1"
}

act_code() {
    curl -s -o /dev/null -w '%{http_code}' -H 'X-Arcs-Act: 1' \
        -X POST "$BASE/act" -d "$1"
}

# --- what is on the wire ----------------------------------------------------------------

@test "arcs-serve: the page is served with utf-8 stated, not guessed" {
    start_daemon
    run curl -si "$BASE/"
    [ "$status" -eq 0 ]
    [[ "$output" == *"200 OK"* ]]
    # The whole reason this daemon exists rather than http.server: arcs-page emits a
    # fragment with no meta charset because the artifact runtime supplies the head.
    [[ "$output" == *"Content-Type: text/html; charset=utf-8"* ]]
}

@test "arcs-serve: the page's bytes arrive unaltered" {
    start_daemon
    curl -s "$BASE/" >"$TEST_TMPDIR/got.html"
    run cmp -s "$PAGE" "$TEST_TMPDIR/got.html"
    [ "$status" -eq 0 ]
}

@test "arcs-serve: the page is no-store, because it is rebuilt under the same path" {
    start_daemon
    run curl -si "$BASE/"
    [[ "$output" == *"Cache-Control: no-store"* ]]
}

@test "arcs-serve: a missing page is a sentence naming it, not a traceback" {
    rm -f "$PAGE"
    start_daemon
    run curl -s -w ' [%{http_code}]' "$BASE/"
    [[ "$output" == *"[503]"* ]]
    [[ "$output" == *"$PAGE"* ]]
    [[ "$output" != *"Traceback"* ]]
}

@test "arcs-serve: WORK_ARCS_PAGE moves what is served" {
    local other="$TEST_TMPDIR/elsewhere.html"
    printf 'a different page\n' >"$other"
    export WORK_ARCS_PAGE="$other"
    start_daemon
    run curl -s "$BASE/"
    [[ "$output" == *"a different page"* ]]
}

# --- health -----------------------------------------------------------------------------

@test "arcs-serve: /health answers with all four fields" {
    start_daemon
    run curl -s "$BASE/health"
    [ "$status" -eq 0 ]
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(sorted(d)); print(d["ok"], d["tmux_default"], d["tmux_orch_sessions"], bool(d["page_mtime_iso"]))' "$output"
    [[ "$output" == *"['ok', 'page_mtime_iso', 'tmux_default', 'tmux_orch_sessions']"* ]]
    [[ "$output" == *"True True True True"* ]]
}

@test "arcs-serve: /health follows the tmux probes down rather than claiming health" {
    export STUB_DEFAULT_ORCH=1
    export STUB_ORCH_SERVER=1
    start_daemon
    run curl -s "$BASE/health"
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["tmux_default"], d["tmux_orch_sessions"])' "$output"
    [[ "$output" == *"False False"* ]]
}

@test "arcs-serve: /health with no page on disk is not ok" {
    rm -f "$PAGE"
    start_daemon
    run curl -s "$BASE/health"
    run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["ok"], d["page_mtime_iso"])' "$output"
    [[ "$output" == *"False None"* ]]
}

@test "arcs-serve: /health is side-effect-free and cached, so polling it is cheap" {
    start_daemon
    curl -sf -o /dev/null "$BASE/health"
    curl -sf -o /dev/null "$BASE/health"
    curl -sf -o /dev/null "$BASE/health"
    # start_daemon's own readiness poll already paid for the probes and the answer is
    # reused for thirty seconds, so these three cost nothing at all. A page polling this
    # every second would otherwise be two subprocesses a second, forever.
    run cat "$TMUX_ARGV_LOG"
    [ -z "$output" ]
}

# --- the guard --------------------------------------------------------------------------

@test "arcs-serve: POST /act without the header is 403" {
    start_daemon
    run curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/act" \
        -d "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}"
    [ "$output" = "403" ]
}

@test "arcs-serve: nothing runs on the way to a 403" {
    write_session_json "$SERVE_UUID" "orch:dev-workflow-tools"
    start_daemon
    curl -s -o /dev/null -X POST "$BASE/act" \
        -d "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}"
    # A guard that resumed the session and then refused would not be a guard.
    run cat "$TMUX_ARGV_LOG"
    [ -z "$output" ]
}

@test "arcs-serve: a 403 leaves the keep-alive connection usable" {
    start_daemon
    # Two requests on one connection. An undrained POST body is read as the next request
    # line, which answered correctly and then complained about its own leftovers.
    run curl -s -o /dev/null -w '%{http_code} ' -X POST "$BASE/act" -d '{"verb":"open","target":"x"}' \
        --next -s -o /dev/null -w '%{http_code}' "$BASE/"
    [ "$output" = "403 200" ]
    run grep -c 'Bad request syntax' "$LOG"
    [ "$output" -eq 0 ]
}

@test "arcs-serve: no route ever emits an Access-Control header" {
    start_daemon
    local p
    for p in / /health /act /nope "/term/$SERVE_UUID"; do
        run curl -si -H 'Origin: https://claude.ai' -H 'X-Arcs-Act: 1' "$BASE$p"
        [[ "$output" != *"Access-Control"* ]]
    done
    run curl -si -H 'Origin: https://claude.ai' -H 'X-Arcs-Act: 1' -X POST "$BASE/act" \
        -d "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}"
    [[ "$output" != *"Access-Control"* ]]
    run curl -si -X OPTIONS "$BASE/act"
    [[ "$output" != *"Access-Control"* ]]
}

@test "arcs-serve: the listening socket is loopback, per the kernel and not per the log" {
    start_daemon
    # 0100007F is 127.0.0.1 little-endian; 0A is LISTEN. Anything wider than loopback
    # would be 00000000 here, and this is the one claim in the docstring that has to be
    # checked against the machine rather than against a sentence.
    run python3 - "$PORT" <<'PY'
import sys
port = int(sys.argv[1])
out = []
for line in open("/proc/net/tcp"):
    f = line.split()
    if len(f) < 4 or f[3] != "0A":
        continue
    addr, p = f[1].split(":")
    if int(p, 16) == port:
        out.append(addr)
print(",".join(out) or "NOT-LISTENING")
PY
    [ "$output" = "0100007F" ]
}

# --- open -------------------------------------------------------------------------------

@test "arcs-serve: open attaches a live session with exactly the argv orch uses" {
    write_session_json "$SERVE_UUID" "orch:dev-workflow-tools"
    start_daemon
    run act "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}"
    [[ "$output" == *'"ok": true'* ]]

    # The inner attach is spelled with the SAME tmux the daemon was told to use, which is
    # why the stub path appears in the middle of the window command.
    cat >"$TEST_TMPDIR/want" <<EOF
-L
orch-sessions
has-session
-t
$SERVE_UUID
--
-L
default
has-session
-t
orch
--
-L
default
new-window
-t
orch:
-n
orch:dev-workflow-to
$WORK_ARCS_TMUX_BIN
-L
orch-sessions
attach
-t
$SERVE_UUID
--
EOF
    run diff -u "$TEST_TMPDIR/want" "$TMUX_ARGV_LOG"
    [ "$status" -eq 0 ]
}

@test "arcs-serve: an idle session is resumed detached before it is attached" {
    export STUB_SESSION_ALIVE=1
    write_transcript "$SERVE_UUID"
    write_session_json "$SERVE_UUID" "orch:dev-workflow-tools"
    start_daemon
    run act "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}"
    [[ "$output" == *'"ok": true'* ]]
    [[ "$output" == *"resumed"* ]]

    cat >"$TEST_TMPDIR/want" <<EOF
-L
orch-sessions
has-session
-t
$SERVE_UUID
--
-L
orch-sessions
new-session
-d
-s
$SERVE_UUID
-x
200
-y
50
claude
--resume
$SERVE_UUID
--
-L
default
has-session
-t
orch
--
-L
default
new-window
-t
orch:
-n
orch:dev-workflow-to
$WORK_ARCS_TMUX_BIN
-L
orch-sessions
attach
-t
$SERVE_UUID
--
EOF
    run diff -u "$TEST_TMPDIR/want" "$TMUX_ARGV_LOG"
    [ "$status" -eq 0 ]
}

@test "arcs-serve: a dead session with no transcript is refused, not resumed" {
    export STUB_SESSION_ALIVE=1
    start_daemon
    run act "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}"
    [[ "$output" == *'"ok": false'* ]]
    [[ "$output" == *"nothing to resume"* ]]
    # A new-session here would open a window on a claude that dies immediately.
    run grep -c 'new-session' "$TMUX_ARGV_LOG"
    [ "$output" -eq 0 ]
}

@test "arcs-serve: the window is named for the session when the name is findable" {
    write_session_json "$SERVE_UUID" "orch:a-much-longer-workstream-name"
    start_daemon
    act "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}" >/dev/null
    run grep -A1 -- '^-n$' "$TMUX_ARGV_LOG"
    [[ "$output" == *"orch:a-much-longer-w"* ]]
}

@test "arcs-serve: an unnameable session falls back to the uuid head, not to nothing" {
    start_daemon
    act "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}" >/dev/null
    run grep -A1 -- '^-n$' "$TMUX_ARGV_LOG"
    [[ "$output" == *"0696c976"* ]]
}

@test "arcs-serve: open refuses a target that is not a uuid" {
    start_daemon
    run act_code '{"verb":"open","target":"; rm -rf /"}'
    [ "$output" = "400" ]
    run cat "$TMUX_ARGV_LOG"
    [ -z "$output" ]
}

@test "arcs-serve: a uuid embedded in something longer is not a uuid" {
    start_daemon
    run act_code "{\"verb\":\"open\",\"target\":\"../$SERVE_UUID\"}"
    [ "$output" = "400" ]
}

# --- opendir ----------------------------------------------------------------------------

@test "arcs-serve: opendir opens a shell in the worktree" {
    mkdir -p "$HOME/work/repo.PROJ-1"
    start_daemon
    run act "{\"verb\":\"opendir\",\"target\":\"$HOME/work/repo.PROJ-1\"}"
    [[ "$output" == *'"ok": true'* ]]

    cat >"$TEST_TMPDIR/want" <<EOF
-L
default
has-session
-t
orch
--
-L
default
new-window
-t
orch:
-c
$(cd "$HOME/work/repo.PROJ-1" && pwd -P)
--
EOF
    run diff -u "$TEST_TMPDIR/want" "$TMUX_ARGV_LOG"
    [ "$status" -eq 0 ]
}

@test "arcs-serve: opendir expands a tilde" {
    mkdir -p "$HOME/work/repo.PROJ-2"
    start_daemon
    run act '{"verb":"opendir","target":"~/work/repo.PROJ-2"}'
    [[ "$output" == *'"ok": true'* ]]
    run grep -c "repo.PROJ-2" "$TMUX_ARGV_LOG"
    [ "$output" -ge 1 ]
}

@test "arcs-serve: opendir refuses a path outside HOME" {
    start_daemon
    run act '{"verb":"opendir","target":"/etc"}'
    [[ "$output" == *'"ok": false'* ]]
    [[ "$output" == *"not under"* ]]
    run cat "$TMUX_ARGV_LOG"
    [ -z "$output" ]
}

@test "arcs-serve: opendir refuses a symlink that leaves HOME" {
    ln -s /etc "$HOME/escape"
    start_daemon
    run act "{\"verb\":\"opendir\",\"target\":\"$HOME/escape\"}"
    [[ "$output" == *'"ok": false'* ]]
    [[ "$output" == *"not under"* ]]
}

@test "arcs-serve: opendir refuses a traversal dressed up in dot-dots" {
    start_daemon
    run act "{\"verb\":\"opendir\",\"target\":\"$HOME/../../etc\"}"
    [[ "$output" == *'"ok": false'* ]]
    run cat "$TMUX_ARGV_LOG"
    [ -z "$output" ]
}

@test "arcs-serve: opendir refuses a file and a path that is not there" {
    printf 'x\n' >"$HOME/afile"
    start_daemon
    run act "{\"verb\":\"opendir\",\"target\":\"$HOME/afile\"}"
    [[ "$output" == *"not a directory"* ]]
    run act "{\"verb\":\"opendir\",\"target\":\"$HOME/never-existed\"}"
    [[ "$output" == *"not a directory"* ]]
}

@test "arcs-serve: opendir refuses a relative path rather than resolving it somewhere" {
    start_daemon
    run act_code '{"verb":"opendir","target":"work/repo"}'
    [ "$output" = "400" ]
}

# --- refusals are relayed, and no server is ever started ---------------------------------

@test "arcs-serve: a missing orch session is the answer, not a server to start" {
    export STUB_DEFAULT_ORCH=1
    write_session_json "$SERVE_UUID" "orch:dev-workflow-tools"
    start_daemon
    run act "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}"
    [[ "$output" == *'"ok": false'* ]]
    # Verbatim, from the stub standing in for tmux.
    [[ "$output" == *"no server running"* ]]
    run grep -c 'new-window' "$TMUX_ARGV_LOG"
    [ "$output" -eq 0 ]
}

@test "arcs-serve: a tmux refusal is relayed word for word" {
    export STUB_NEW_WINDOW=1
    write_session_json "$SERVE_UUID" "orch:dev-workflow-tools"
    start_daemon
    run act "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}"
    [[ "$output" == *'"ok": false'* ]]
    [[ "$output" == *"create window failed: index in use: 0"* ]]
}

@test "arcs-serve: a tmux that is not there is an answer rather than a hang" {
    export WORK_ARCS_TMUX_BIN="$TEST_TMPDIR/no-such-tmux"
    write_session_json "$SERVE_UUID" "orch:dev-workflow-tools"
    # With no tmux at all every probe fails, so the session reads as not-alive; the
    # transcript is what lets the request get as far as the invocation that is missing.
    write_transcript "$SERVE_UUID"
    start_daemon
    run act "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}"
    [[ "$output" == *'"ok": false'* ]]
    [[ "$output" == *"not found"* ]]
}

# --- the shape of the request ------------------------------------------------------------

@test "arcs-serve: an unknown verb is 400 and names the ones that exist" {
    start_daemon
    run act '{"verb":"kill","target":"whatever"}'
    [[ "$output" == *'"ok": false'* ]]
    [[ "$output" == *"open"* ]]
    [[ "$output" == *"opendir"* ]]
    run act_code '{"verb":"kill","target":"whatever"}'
    [ "$output" = "400" ]
}

@test "arcs-serve: a body that is not JSON is 400, not a traceback" {
    start_daemon
    run act 'not json at all'
    [[ "$output" == *"not JSON"* ]]
    run act_code 'not json at all'
    [ "$output" = "400" ]
}

@test "arcs-serve: a JSON body that is not an object is 400" {
    start_daemon
    run act_code '[1,2,3]'
    [ "$output" = "400" ]
}

@test "arcs-serve: a non-string target is 400 rather than a stringified one" {
    start_daemon
    run act_code '{"verb":"opendir","target":123}'
    [ "$output" = "400" ]
}

@test "arcs-serve: GET /act is 405 and says which method it wants" {
    start_daemon
    run curl -si "$BASE/act"
    [[ "$output" == *"405"* ]]
    [[ "$output" == *"Allow: POST"* ]]
}

@test "arcs-serve: nothing outside the four routes is served" {
    start_daemon
    local p
    # --path-as-is throughout, or curl resolves the dot-dots on the client and the test
    # proves something about curl instead of about the daemon.
    for p in /page.html /snapshot.json /../../etc/passwd /%2e%2e/%2e%2e/etc/passwd /index.html; do
        run curl -s --path-as-is -o /dev/null -w '%{http_code}' "$BASE$p"
        [ "$output" = "404" ]
    done
}

@test "arcs-serve: there is no directory listing" {
    start_daemon
    run curl -s "$BASE/"
    [[ "$output" != *"Directory listing"* ]]
    # --path-as-is, because curl decodes %2e and collapses the segment before the
    # request leaves the client. The daemon sees /./ , which is not the page path, so it
    # is a 404 like everything else that is not one of the four routes.
    run curl -s --path-as-is -o /dev/null -w '%{http_code}' "$BASE/%2e/"
    [ "$output" = "404" ]
}

@test "arcs-serve: a POST to a path that is not /act is 404" {
    start_daemon
    run curl -s -o /dev/null -w '%{http_code}' -H 'X-Arcs-Act: 1' -X POST "$BASE/health" -d '{}'
    [ "$output" = "404" ]
}

# --- the terminal drawer ------------------------------------------------------------------

@test "arcs-serve: /term is behind the same header, because starting a process is an act" {
    start_daemon
    run curl -s -o /dev/null -w '%{http_code}' "$BASE/term/$SERVE_UUID"
    [ "$output" = "403" ]
}

@test "arcs-serve: /term refuses a target that is not a uuid before it spawns anything" {
    start_daemon
    run curl -s -o /dev/null -w '%{http_code}' -H 'X-Arcs-Act: 1' "$BASE/term/not-a-uuid"
    [ "$output" = "400" ]
}

@test "arcs-serve: /term spawns one ttyd per session and hands back its loopback url" {
    export WORK_ARCS_TTYD_BIN="$TEST_TMPDIR/ttyd-stub"
    cat >"$WORK_ARCS_TTYD_BIN" <<'TTYDEOF'
#!/usr/bin/env bash
{
    for a in "$@"; do printf '%s\n' "$a"; done
    printf -- '--\n'
} >>"$TTYD_ARGV_LOG"
port=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-p" ]; then port="$2"; fi
    shift
done
exec python3 -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(4)
time.sleep(60)' "$port"
TTYDEOF
    chmod +x "$WORK_ARCS_TTYD_BIN"
    export TTYD_ARGV_LOG="$TEST_TMPDIR/ttyd-argv.log"
    : >"$TTYD_ARGV_LOG"
    start_daemon

    run curl -s -H 'X-Arcs-Act: 1' "$BASE/term/$SERVE_UUID"
    [[ "$output" == *'"ok": true'* ]]
    [[ "$output" == *"http://127.0.0.1:"* ]]
    local first="$output"

    # -W is write-enabled, -i lo is the bind, and the command is the same attach the
    # open verb uses.
    run cat "$TTYD_ARGV_LOG"
    [[ "$output" == *"-W"* ]]
    [[ "$output" == *"-i"* ]]
    [[ "$output" == *"lo"* ]]
    [[ "$output" == *"attach"* ]]
    [[ "$output" == *"$SERVE_UUID"* ]]

    # Asking twice is the same terminal, not a second one.
    run curl -s -H 'X-Arcs-Act: 1' "$BASE/term/$SERVE_UUID"
    [ "$output" = "$first" ]
    run grep -c -- '^--$' "$TTYD_ARGV_LOG"
    [ "$output" -eq 1 ]
}

@test "arcs-serve: a ttyd that dies immediately is reported, not redirected to" {
    export WORK_ARCS_TTYD_BIN="$TEST_TMPDIR/ttyd-dead"
    printf '#!/usr/bin/env bash\nexit 3\n' >"$WORK_ARCS_TTYD_BIN"
    chmod +x "$WORK_ARCS_TTYD_BIN"
    start_daemon
    run curl -s -H 'X-Arcs-Act: 1' "$BASE/term/$SERVE_UUID"
    [[ "$output" == *'"ok": false'* ]]
    [[ "$output" == *"exited immediately"* ]]
}

@test "arcs-serve: the concurrent terminal cap is enforced" {
    export WORK_ARCS_TERM_MAX=1
    export WORK_ARCS_TTYD_BIN="$TEST_TMPDIR/ttyd-stub2"
    cat >"$WORK_ARCS_TTYD_BIN" <<'TTYDEOF2'
#!/usr/bin/env bash
port=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-p" ]; then port="$2"; fi
    shift
done
exec python3 -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(4)
time.sleep(60)' "$port"
TTYDEOF2
    chmod +x "$WORK_ARCS_TTYD_BIN"
    start_daemon
    run curl -s -H 'X-Arcs-Act: 1' "$BASE/term/$SERVE_UUID"
    [[ "$output" == *'"ok": true'* ]]
    run curl -s -H 'X-Arcs-Act: 1' "$BASE/term/11111111-2222-3333-4444-555555555555"
    [[ "$output" == *'"ok": false'* ]]
    [[ "$output" == *"the cap"* ]]
}

# --- the log ------------------------------------------------------------------------------

@test "arcs-serve: the bind it logs is the one the kernel gave it" {
    start_daemon
    run grep -c "listening on 127.0.0.1:$PORT" "$LOG"
    [ "$output" -eq 1 ]
}

@test "arcs-serve: an act writes a line saying what it did" {
    write_session_json "$SERVE_UUID" "orch:dev-workflow-tools"
    start_daemon
    act "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}" >/dev/null
    run grep -c "act open $SERVE_UUID" "$LOG"
    [ "$output" -eq 1 ]
}

@test "arcs-serve: a refusal writes a line saying what was refused" {
    export STUB_DEFAULT_ORCH=1
    write_session_json "$SERVE_UUID" "orch:dev-workflow-tools"
    start_daemon
    act "{\"verb\":\"open\",\"target\":\"$SERVE_UUID\"}" >/dev/null
    run grep -c "refused" "$LOG"
    [ "$output" -ge 1 ]
}

@test "arcs-serve: the log is ring-trimmed to the configured size" {
    export WORK_ARCS_SERVE_LOG_LINES=5
    local i
    for i in $(seq 1 200); do printf 'old line %s\n' "$i" >>"$LOG"; done
    start_daemon
    # Trimmed on start, so the 200 stale lines are gone and the bind line survives.
    run wc -l <"$LOG"
    [ "$output" -le 6 ]
    run grep -c "listening on" "$LOG"
    [ "$output" -eq 1 ]
}

@test "arcs-serve: per-request access lines do not bury the acts" {
    start_daemon
    local i
    for i in $(seq 1 10); do curl -sf -o /dev/null "$BASE/" || true; done
    run wc -l <"$LOG"
    [ "$output" -eq 1 ]
}

# --- stopping ------------------------------------------------------------------------------

@test "arcs-serve: SIGTERM stops it rather than deadlocking the serve loop" {
    start_daemon
    kill -TERM "$DAEMON_PID"
    local i
    for i in $(seq 1 60); do
        kill -0 "$DAEMON_PID" 2>/dev/null || break
        sleep 0.05
    done
    run kill -0 "$DAEMON_PID"
    [ "$status" -ne 0 ]
    DAEMON_PID=""
    run grep -c "stopping" "$LOG"
    [ "$output" -eq 1 ]
}

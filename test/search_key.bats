#!/usr/bin/env bats
# The hidden search field on every rr row.
#
# rr's columns are fixed-width: a branch gets 23 chars, a title 40, a status 14. Anything
# longer is cut and given an ellipsis. fzf, by default, can only match what is on the
# line — so "UB-1500-perf-s..." was a branch you could see and could not find, and
# "IN QUALIF..." was a status you could not filter by. The fix is a trailing field
# carrying the full untruncated branch, title, status and assignee, which fzf searches
# via --nth but never displays.
#
# The rendering loop exists twice — once for the streaming first paint, once for the
# ctrl-r/ctrl-l reload path — with seven printf variants each for the row tiers. So the
# thing worth testing is not "does one row have a search key" but "does every row from
# both loops have one, with the full values in it".

load test_helper/common

setup() {
    export JIRA_PROJECT_REGEX="(UB|UL|TEST)"
    export JIRA_ME=""
    export RR_PANE_MGMT_ENABLED="false"
    export PANE_COUNT=0

    # The real column widths and the real indent, not a copy of them — the indent
    # arithmetic is exactly what these tests are checking.
    eval "$(sed -n '/^TITLE_MAX_LENGTH=/,/^unset _rr_term_cols$/p' "$REPO_ROOT/bin/rr.sh")"
    eval "$(sed -n '/^build_search_key()/,/^}/p' "$REPO_ROOT/bin/rr.sh")"
    eval "$(grep '^printf -v SEARCH_KEY_INDENT' "$REPO_ROOT/bin/rr.sh")"
}

# Stubs for the helpers the render loop calls, so it can run outside a git repo.
define_render_stubs() {
    truncate() {
        if [ ${#1} -gt "$2" ]; then echo "${1:0:$(($2-3))}..."; else echo "$1"; fi
    }
    convert_timestamp_to_relative() { echo "checked: 1 hour ago"; }
    format_status() { printf "%-${STATUS_MAX_LENGTH}s" "${1:0:$STATUS_MAX_LENGTH}"; }
    render_wt_indicator() { WT_INDICATOR_DISPLAY=" ⊙  "; WT_BRANCH_SGR=""; }
    resolve_current_branch() { echo "__none__"; }
    get_pane_current_dir() { echo ""; }
}

# Extract one of the two rendering loops from rr.sh and run the given rows through it.
# Args: $1 = "reload" (4-space-indented loop) or "stream" (8-space-indented loop)
# Rows arrive on stdin as the 11-field tab-separated form the loop reads.
render_via() {
    local which="$1" body
    if [ "$which" = "reload" ]; then
        body=$(awk '
            /^    while IFS=/ && /read -r branch title status author/ { f=1 }
            f { print }
            f && /^    done\)"$/ { exit }
        ' "$REPO_ROOT/bin/rr.sh" | sed '$ s/done)"/done/')
    else
        body=$(awk '
            /^        while IFS=/ && /read -r branch title status author/ { f=1 }
            f { print }
            f && /^        done$/ { exit }
        ' "$REPO_ROOT/bin/rr.sh")
    fi
    [ -n "$body" ] || { echo "could not extract the $which render loop" >&2; return 1; }

    define_render_stubs
    # The streaming loop hoists these out of the loop for speed; supply them.
    local _current_branch_name="__none__" _jira_me_lower="" _format_now_sec=1770000000
    declare -A _seen_branches=()
    declare -A _pane_dirs=() _pane_ind_width=()
    declare -A _status_fmt=()
    eval "_render() {
        local _current_branch_name=\"__none__\" _jira_me_lower=\"\" _format_now_sec=1770000000
        declare -A _seen_branches=() _pane_dirs=() _pane_ind_width=() _status_fmt=()
        $body
    }"
    _render
}

# The 11 tab-separated fields the render loops read:
# branch(display, pre-truncated) title status author time_info commit_info
# full_branch assignee wt_indicator wt_path wt_status
row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# The search key is the last │-delimited field of a rendered row.
search_key_of() {
    strip_ansi | awk -F'│' '{ gsub(/^[ \t]+|[ \t]+$/, "", $NF); print $NF }'
}

# SEARCH_KEY without the indent that parks it off screen.
key_text() {
    local t="$SEARCH_KEY"
    printf '%s' "${t#"${t%%[![:space:]]*}"}"
}

# --- build_search_key ---

@test "build_search_key: joins branch, title, status and assignee" {
    build_search_key "UB-1500-perf-sync-repro" "Floating map marker" "In Review" "Logan Wenzel"
    [ "$(key_text)" = "UB-1500-perf-sync-repro Floating map marker In Review Logan Wenzel" ]
}

@test "build_search_key: the TICKET: prefix on a branchless row is not searchable text" {
    build_search_key "TICKET:UL-1692" "neighborhoods dual map" "To Do" "<UNASSIGNED>"
    [[ "$(key_text)" == UL-1692* ]]
    [[ "$SEARCH_KEY" != *TICKET* ]]
}

@test "build_search_key: the REMOTE: prefix is stripped too" {
    build_search_key "REMOTE:dove-boot-playwright" "" "" ""
    [[ "$(key_text)" == dove-boot-playwright* ]]
    [[ "$SEARCH_KEY" != *REMOTE* ]]
}

@test "build_search_key: the <EMPTY>/<UNASSIGNED> sentinels are not searchable text" {
    build_search_key "dove-boot-churn" "<EMPTY>" "<EMPTY>" "<UNASSIGNED>"
    [[ "$SEARCH_KEY" != *EMPTY* ]]
    [[ "$SEARCH_KEY" != *UNASSIGNED* ]]
    [[ "$SEARCH_KEY" == *dove-boot-churn* ]]
}

@test "build_search_key: a │ in a title cannot split the field in two" {
    build_search_key "UB-1" "charts │ per client" "Done" "Kyle"
    [[ "$SEARCH_KEY" != *"│"* ]]
    [[ "$SEARCH_KEY" == *"charts   per client"* ]]
}

# --- the rendered rows ---

@test "reload render: the branch is findable past the ellipsis" {
    local out
    out=$(row "UB-1500-perf-s..." "Floating map marker - Prod" "Done" "kyle" \
              "checked:1770000000" "committed: 1 hour ago" \
              "UB-1500-perf-sync-repro" "Kyle Grimsrud-Manz" "" "" "" | render_via reload)

    # The visible branch column is still truncated...
    echo "$out" | strip_ansi | grep -q 'UB-1500-perf-s\.\.\.'
    # ...but the whole name is on the line for fzf to match.
    [[ "$(echo "$out" | search_key_of)" == *"UB-1500-perf-sync-repro"* ]]
}

@test "stream render: the branch is findable past the ellipsis" {
    local out
    out=$(row "UB-1500-perf-s..." "Floating map marker - Prod" "Done" "kyle" \
              "checked:1770000000" "committed: 1 hour ago" \
              "UB-1500-perf-sync-repro" "Kyle Grimsrud-Manz" "" "" "" | render_via stream)

    echo "$out" | strip_ansi | grep -q 'UB-1500-perf-s\.\.\.'
    [[ "$(echo "$out" | search_key_of)" == *"UB-1500-perf-sync-repro"* ]]
}

@test "a title longer than the column is findable in full" {
    local title="Curated view segmentation workspace for regional partners"
    local out
    for loop in reload stream; do
        out=$(row "UL-1670-v2" "$title" "In Qualification" "Logan Wenzel" \
                  "checked:1770000000" "committed: 2 hours ago" \
                  "UL-1670-v2" "Logan Wenzel" "" "" "" | render_via "$loop")
        # Truncated on screen, whole in the search key.
        echo "$out" | strip_ansi | grep -q 'workspace f\.\.\.'
        [[ "$(echo "$out" | search_key_of)" == *"regional partners"* ]] \
            || { echo "$loop loop lost the full title" >&2; return 1; }
    done
}

@test "a status longer than the column is findable in full" {
    local out
    for loop in reload stream; do
        out=$(row "UL-1670-v2" "Curated view" "In Qualification" "Logan Wenzel" \
                  "checked:1770000000" "committed: 2 hours ago" \
                  "UL-1670-v2" "Logan Wenzel" "" "" "" | render_via "$loop")
        [[ "$(echo "$out" | search_key_of)" == *"In Qualification"* ]] \
            || { echo "$loop loop lost the full status" >&2; return 1; }
    done
}

@test "every row tier carries a search key, in both render loops" {
    # One row per branch of the printf cascade: auto, remote, branchless-abandoned,
    # branchless, mine-authoritative, mine-variant, and plain.
    local rows
    rows=$(
        row "auto-branch"  "auto title"   "To Do"     "bot"  "checked:1770000000" "committed: 1 hour ago" "auto-branch-full-name"    "Kyle" "WT_AUTO" "/tmp/wt" ""
        row "remote-br"    "remote title" "In Review" "kyle" "checked:1770000000" "committed: 1 hour ago" "REMOTE:remote-branch-full" "Kyle" "" "" ""
        row "UL-9-dead"    "dead title"   "Abandoned" "<UNASSIGNED>" "updated:1770000000" "<NO BRANCH>"    "TICKET:UL-9"               "<UNASSIGNED>" "" "" ""
        row "UL-8-open"    "open title"   "To Do"     "<UNASSIGNED>" "updated:1770000000" "<NO BRANCH>"    "TICKET:UL-8"               "<UNASSIGNED>" "" "" ""
        row "UB-1"         "mine title"   "In Review" "kyle" "checked:1770000000" "committed: 1 hour ago" "UB-1"                      "Kyle" "WT" "/tmp/wt" "CLEAN"
        row "UB-1-wip"     "variant"      "In Review" "kyle" "checked:1770000000" "committed: 1 hour ago" "UB-1-wip"                  "Kyle" "" "" ""
        row "someone-else" "their title"  "QA"        "dev"  "checked:1770000000" "committed: 1 hour ago" "someone-else-branch-full"  "Other Dev" "" "" ""
    )

    local loop out n_rows n_keys
    n_rows=$(echo "$rows" | wc -l)
    for loop in reload stream; do
        # JIRA_ME set so the ★/· tiers are reachable
        out=$(echo "$rows" | JIRA_ME="Kyle" render_via "$loop")
        n_keys=$(echo "$out" | search_key_of | grep -c '[^[:space:]]')
        [ "$n_keys" -eq "$n_rows" ] \
            || { echo "$loop loop: $n_keys of $n_rows rows had a search key" >&2
                 echo "$out" | strip_ansi >&2; return 1; }
        # And the key holds the full branch, not the truncated display one.
        echo "$out" | search_key_of | grep -q 'remote-branch-full'
        echo "$out" | search_key_of | grep -q 'someone-else-branch-full'
    done
}

# --- the wiring that makes the field do anything ---
#
# fzf will not match a field it does not display, so --with-nth has to include the
# search key. --nth then indexes the *transformed* line (fzf(1): "when you use this
# option with --with-nth, the field index expressions are calculated against the
# transformed lines"), which is a different numbering — easy to get wrong, and wrong
# silently: search just quietly goes back to matching only what fits on screen.

fzf_opt() {
    grep -o -- "$1=[^ \\\\]*" "$REPO_ROOT/bin/rr.sh" | head -1 | sed "s/$1=//"
}

@test "--with-nth displays the search key's field, or fzf cannot match it" {
    local with_nth field_count
    with_nth=$(fzf_opt --with-nth)
    field_count=$(row "UB-1" "t" "s" "a" "checked:1770000000" "c" "UB-1-full" "Kyle" "" "" "" \
        | render_via reload | strip_ansi | awk -F'│' '{ print NF }')

    [ "${with_nth##*,}" -eq "$field_count" ] \
        || { echo "--with-nth ends at ${with_nth##*,} but the search key is field $field_count" >&2
             return 1; }
}

@test "--nth indexes the transformed line, and lands on the search key" {
    local with_nth nth transformed_fields
    with_nth=$(fzf_opt --with-nth)
    nth=$(fzf_opt --nth)

    # The transformed line has one field per --with-nth entry; the search key is last.
    transformed_fields=$(awk -F, '{ print NF }' <<< "$with_nth")

    [ "${nth##*,}" -eq "$transformed_fields" ] \
        || { echo "--nth ends at ${nth##*,}, but --with-nth builds a $transformed_fields-field line" >&2
             return 1; }
    # The time and commit columns stay out of scope: "ago"/"committed" are on every row.
    [[ "$nth" != *5* ]] && [[ "$nth" != *6* ]]
}

@test "fzf is told not to scroll or mark the off-screen field" {
    # Without these two the trick shows: fzf hscrolls to reveal a match inside the key,
    # and paints an overflow marker on every row.
    grep -q -- "--no-hscroll" "$REPO_ROOT/bin/rr.sh"
    grep -qE -- "--ellipsis=( |\\\\|$)" "$REPO_ROOT/bin/rr.sh"
}

@test "the search key starts past the width of a rendered row" {
    # ROW_VISUAL_WIDTH is the arithmetic the indent is built from. If it drifts from
    # what the printfs actually emit, the key creeps back on screen.
    local visible
    visible=$(row "UB-1" "a title" "In Review" "Kyle" "checked:1770000000" "committed: 1 hour ago" \
                  "UB-1-full" "Kyle" "" "" "" \
        | render_via reload | strip_ansi \
        | awk -F'│' '{ n=0; for (i=1; i<=6; i++) n += length($i); print n + 6 }')

    [ "$visible" -eq "$ROW_VISUAL_WIDTH" ] \
        || { echo "rows render $visible columns wide, ROW_VISUAL_WIDTH says $ROW_VISUAL_WIDTH" >&2
             return 1; }
    [ "$SEARCH_KEY_COLUMN" -gt "$ROW_VISUAL_WIDTH" ]
}

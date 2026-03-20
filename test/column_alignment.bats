#!/usr/bin/env bats
# Tests for column alignment in formatted rr.sh output.
#
# Verifies that all │-delimited columns align consistently across
# different row types (★ yours, · variant, + branchless, ↑ remote, etc).

load test_helper/common

# --- Helpers ---

# Strip ANSI escape sequences from stdin
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

# Assert that all │-delimited columns have consistent display widths across lines.
# Uses python for correct Unicode width measurement.
# Args: $1 = optional label for error messages
assert_column_widths_consistent() {
    local label="${1:-output}"

    _ALIGN_LABEL="$label" python3 -c "
import unicodedata, sys, re, os

label = os.environ.get('_ALIGN_LABEL', 'output')

def dw(s):
    return sum(2 if unicodedata.east_asian_width(c) in ('F','W') else 1 for c in s)

def strip_ansi(s):
    return re.sub(r'\033\[[0-9;]*m', '', s)

lines = sys.stdin.read().strip().split('\n')
ref_widths = None
ref_line = None
errors = []

for i, raw_line in enumerate(lines, 1):
    plain = strip_ansi(raw_line)
    if '│' not in plain:
        continue

    cols = plain.split('│')
    widths = [dw(c) for c in cols[:-1]]

    if ref_widths is None:
        ref_widths = widths
        ref_line = i
    elif widths != ref_widths:
        errors.append(f'  line {i}: widths={widths} (expected {ref_widths} from line {ref_line})')
        errors.append(f'    -> {plain}')

if errors:
    print(f'Column misalignment in {label}:', file=sys.stderr)
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
elif ref_widths is None:
    print(f'No delimited lines found in {label}', file=sys.stderr)
    sys.exit(1)
else:
    print(f'{label}: all lines aligned at column widths {ref_widths}')
" <<< "$(cat)"
}

# --- Tests ---

# Source enough of rr.sh to get format_status and column width constants
source_rr_formatting() {
    local repo_root="$REPO_ROOT"

    export JIRA_PROJECT="TEST"
    export JIRA_ME="testuser"
    export TITLE_MAX_LENGTH=40
    export BRANCH_MAX_LENGTH=23
    export STATUS_MAX_LENGTH=14
    export ASSIGNEE_MAX_LENGTH=15
    export COMMIT_MAX_LENGTH=26

    # Source format_status from rr.sh (extract just that function)
    eval "$(sed -n '/^format_status()/,/^}/p' "$repo_root/bin/rr.sh")"
    # Source truncate
    truncate() {
        local str=$1 max_length=$2
        if [ ${#str} -gt $max_length ]; then
            echo "${str:0:$((max_length-3))}..."
        else
            echo "$str"
        fi
    }
}

@test "format_status: all statuses produce consistent width" {
    source_rr_formatting

    local statuses=("In Progress" "Done" "Closed" "QA" "MR" "Code Review"
                     "Paused" "Blocked" "To Do" "Backlog" "Open"
                     "Abandoned" "Cancelled" "Won't Do"
                     "Passed QA" "Development" "On Hold" "New"
                     "Some Custom Status")

    local rendered_lines=""
    for s in "${statuses[@]}"; do
        rendered_lines+="$(format_status "$s")"$'\n'
    done

    # Check all lines have the expected display width
    local result
    result=$(echo "$rendered_lines" | _ALIGN_EXPECTED="$STATUS_MAX_LENGTH" python3 -c "
import unicodedata, sys, re, os

expected = int(os.environ['_ALIGN_EXPECTED'])

def dw(s):
    return sum(2 if unicodedata.east_asian_width(c) in ('F','W') else 1 for c in s)

def strip_ansi(s):
    return re.sub(r'\033\[[0-9;]*m', '', s)

failures = []
for line in sys.stdin:
    line = line.rstrip('\n')
    if not line:
        continue
    plain = strip_ansi(line)
    w = dw(plain)
    if w != expected:
        failures.append(f\"  '{plain}' -> width {w} (expected {expected})\")

if failures:
    print('Status width mismatches:', file=sys.stderr)
    for f in failures:
        print(f, file=sys.stderr)
    sys.exit(1)
else:
    print(f'All statuses have width {expected}')
" 2>&1)

    if [ $? -ne 0 ]; then
        echo "$result" >&2
        return 1
    fi
}

@test "help dialog: example rows have consistent column alignment" {
    # Extract the echo lines from show_help and evaluate them
    local repo_root="$REPO_ROOT"
    local help_output

    # Run the help-dialog echo lines in isolation
    help_output=$(
        # Stub out variables that show_help references
        export RR_PANE_MGMT_ENABLED="false"
        export PANE_COUNT=0

        # Extract and run just the ROW TYPES section
        sed -n '/ROW TYPES/,/if \[ "\$RR_PANE_MGMT_ENABLED"/p' "$repo_root/bin/rr.sh" |
            grep 'echo -e' |
            while IFS= read -r line; do
                eval "$line"
            done
    )

    echo "$help_output" | assert_column_widths_consistent "help dialog"
}

@test "simulated rows: all row types produce aligned columns" {
    source_rr_formatting

    local branch_width=$((BRANCH_MAX_LENGTH - 2))
    local branch_wt_width=$((BRANCH_MAX_LENGTH - 2 - 4))

    # Simulate what the formatting loop produces for each row type
    # Using the exact same printf patterns from rr.sh

    local rows=()

    # ★ authoritative with worktree (clean)
    local db
    db=$(printf "\033[38;5;141m★ %-${branch_wt_width}s\033[0m%s" "UB-1234" "$(printf ' \033[38;5;250m⊙\033[0m  ')")
    rows+=("$(printf "%s │ \033[38;5;141m%-${TITLE_MAX_LENGTH}s\033[0m │ %s │ \033[38;5;109m%-15s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │" \
        "$db" "fix the thing" "$(format_status "In Progress")" "kylegm" "checked: 2 hours ago" "abc1234 fix stuff")")

    # ★ authoritative with worktree (dirty)
    db=$(printf "\033[38;5;141m★ %-${branch_wt_width}s\033[0m%s" "UB-5678" "$(printf ' \033[38;5;250m⊙\033[38;5;214m !\033[0m')")
    rows+=("$(printf "%s │ \033[38;5;141m%-${TITLE_MAX_LENGTH}s\033[0m │ %s │ \033[38;5;109m%-15s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │" \
        "$db" "another ticket" "$(format_status "MR")" "kylegm" "checked: 5 hours ago" "def5678 update")")

    # · variant with worktree
    db=$(printf "\033[38;5;244m· \033[38;5;103m%-${branch_wt_width}s\033[0m%s" "UB-1234-wip" "$(printf ' \033[38;5;250m⊙\033[0m  ')")
    rows+=("$(printf "%s │ \033[38;5;103m%-${TITLE_MAX_LENGTH}s\033[0m │ %s │ \033[38;5;244m%-15s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │" \
        "$db" "fix the thing" "$(format_status "In Progress")" "kylegm" "checked: 3 hours ago" "bbb2222 wip")")

    # Normal (not mine, no worktree)
    db=$(printf "  \033[38;5;250m%-${branch_width}s\033[0m" "UB-9999")
    rows+=("$(printf "%s │ \033[38;5;109m%-${TITLE_MAX_LENGTH}s\033[0m │ %s │ \033[38;5;244m%-15s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │" \
        "$db" "someone else ticket" "$(format_status "QA")" "otherdev" "checked: 1 day ago" "ccc3333 stuff")")

    # + branchless
    db=$(printf "\033[38;5;71m+ \033[38;5;71m%-${branch_width}s\033[0m" "UB-4444")
    rows+=("$(printf "%s │ \033[38;5;71m%-${TITLE_MAX_LENGTH}s\033[0m │ %s │ \033[38;5;244m%-15s\033[0m │ \033[2;37m%-26s\033[0m │ \033[38;5;241m%-${COMMIT_MAX_LENGTH}s\033[0m │" \
        "$db" "new ticket" "$(format_status "To Do")" "kylegm" "updated: 2 days ago" "no branch")")

    # + abandoned (dimmed)
    db=$(printf "\033[2m+ \033[2m%-${branch_width}s\033[0m" "UB-3333")
    rows+=("$(printf "%s │ \033[2m%-${TITLE_MAX_LENGTH}s\033[0m │ %s │ \033[2m%-15s\033[0m │ \033[2m%-26s\033[0m │ \033[2m%-${COMMIT_MAX_LENGTH}s\033[0m │" \
        "$db" "old ticket" "$(format_status "Abandoned")" "kylegm" "updated: 3 months ago" "no branch")")

    # ↑ remote
    db=$(printf "\033[38;5;67m↑ \033[38;5;67m%-${branch_width}s\033[0m" "UB-2222")
    rows+=("$(printf "%s │ \033[38;5;67m%-${TITLE_MAX_LENGTH}s\033[0m │ %s │ \033[38;5;244m%-15s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │" \
        "$db" "remote ticket" "$(format_status "In Progress")" "otherdev" "updated: 1 day ago" "eee5555 remote")")

    # Feed all rows through alignment checker
    printf '%s\n' "${rows[@]}" | assert_column_widths_consistent "simulated rows"
}

#!/usr/bin/env bash
# Preview script for rr - called by fzf with the full selected line as $1

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$(type -P "$0" || echo "$0")")")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
    source "$SCRIPT_DIR/../.env"
fi

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g' | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'; }
trim() { echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# Split the fzf line on │ delimiter
IFS='│' read -ra fields <<< "$1"

full_branch=$(trim "${fields[6]}")
full_title=$(trim "${fields[7]}")
raw_status=$(trim "$(echo "${fields[2]}" | strip_ansi)")
raw_assignee=$(trim "$(echo "${fields[3]}" | strip_ansi)")
raw_time=$(trim "$(echo "${fields[4]}" | strip_ansi)")
raw_commit=$(trim "$(echo "${fields[5]}" | strip_ansi)")

# Strip REMOTE:/TICKET: prefix
branch="${full_branch#REMOTE:}"
branch="${branch#TICKET:}"

# Extract JIRA ticket number
ticket=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | head -1)

jira_url=""
[ -n "$ticket" ] && [ -n "$JIRA_DOMAIN" ] && jira_url="https://${JIRA_DOMAIN}/browse/${ticket}"

# Colors
DIM='\033[2m'
RESET='\033[0m'
CYAN='\033[38;5;74m'
MUTED='\033[38;5;244m'
BRANCH_COL='\033[38;5;250m'
TITLE_COL='\033[38;5;109m'
URL_COL='\033[38;5;68m'

# Status colors (match the main list)
format_status_color() {
    case "$1" in
        "In Progress"|"In Review"|"In Development") echo '\033[38;5;214m' ;;
        "Done"|"Closed"|"Released")                 echo '\033[38;5;71m'  ;;
        "To Do"|"Backlog"|"Open")                   echo '\033[38;5;244m' ;;
        *)                                          echo '\033[38;5;250m' ;;
    esac
}

W=$(tput cols 2>/dev/null || echo 100)

# Line 1: full branch
printf "  ${BRANCH_COL}%s${RESET}\n" "$branch"

# Line 2: full title (or note if absent)
if [ -z "$full_title" ] || [ "$full_title" = "<EMPTY>" ]; then
    printf "  ${MUTED}no JIRA ticket${RESET}\n"
else
    printf "  ${TITLE_COL}%s${RESET}\n" "$full_title"
fi

# Line 3: JIRA URL (only if ticket found)
if [ -n "$jira_url" ]; then
    printf "  ${URL_COL}%s${RESET}\n" "$jira_url"
fi

# Line 4: status · assignee · time · commit
status_color=$(format_status_color "$raw_status")
meta=""
[ -n "$raw_status" ]   && meta="${status_color}${raw_status}${RESET}"
[ -n "$raw_assignee" ] && [ "$raw_assignee" != "<UNASSIGNED>" ] && meta="${meta}${MUTED}  ·  ${RESET}${MUTED}${raw_assignee}${RESET}"
[ -n "$raw_time" ]     && meta="${meta}${MUTED}  ·  ${RESET}${DIM}${raw_time}${RESET}"
[ -n "$raw_commit" ] && [ "$raw_commit" != "no branch" ] && meta="${meta}${MUTED}  ·  ${RESET}${DIM}${raw_commit}${RESET}"
[ -n "$meta" ] && printf "  %b\n" "$meta"

#!/usr/bin/env bash
# Shared ticket selection functions for oneshot and publish-changes
#
# Requires callers to have set:
#   $FZF, $JIRA_EMAIL, $JIRA_API_TOKEN, $JIRA_DOMAIN, $JIRA_PROJECT
#   $TICKETS_CACHE, $SCRIPT_DIR
#   Color vars: $RED, $GREEN, $CYAN, $BLUE, $DIM, $RESET

# Prevent multiple loads
if [ -n "$TICKET_SELECTION_LOADED" ]; then
    return 0
fi
TICKET_SELECTION_LOADED=1

# Refresh ticket cache if missing or stale, delegating to jira-fzf --fetch-only.
# If the caller already started a background fetch (TICKET_FETCH_PID), waits for
# it instead of launching a new one.
refresh_tickets_cache_if_needed() {
    if [ -n "$TICKET_FETCH_PID" ]; then
        # If cache already has data, let the background fetch finish silently
        if [ -f "$TICKETS_CACHE" ]; then
            return 0
        fi
        # Cache is missing — wait for the background fetch before opening fzf
        if kill -0 "$TICKET_FETCH_PID" 2>/dev/null; then
            echo -e "  ${DIM}Fetching tickets...${RESET}" >&2
            wait "$TICKET_FETCH_PID" 2>/dev/null || true
        fi
        return 0
    fi

    local cache_ttl=300  # 5 minutes
    if [ -f "$TICKETS_CACHE" ]; then
        local cache_age=$(($(date +%s) - $(stat -c %Y "$TICKETS_CACHE" 2>/dev/null || echo 0)))
        if [ $cache_age -lt $cache_ttl ]; then
            return 0
        fi
    fi

    echo -e "  ${DIM}Fetching tickets...${RESET}" >&2
    "$SCRIPT_DIR/jira-fzf" --fetch-only
}

# Get cached tickets for fzf selection
get_cached_tickets() {
    if [ -f "$TICKETS_CACHE" ]; then
        jq -r '.issues[] | .key + "\t" + .fields.summary' "$TICKETS_CACHE" 2>/dev/null
    fi
}

# Select ticket interactively (or create new)
# Prints one of: ticket key, NEW, TITLE:<title>, SLACK:<url>, HOTFIX, or empty
select_ticket_or_slack() {
    echo -e "${CYAN}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${RESET}" >&2
    echo -e "${CYAN}┃${RESET} ${BLUE}Select ticket${RESET} or create new                            ${CYAN}┃${RESET}" >&2
    echo -e "${CYAN}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${RESET}" >&2

    refresh_tickets_cache_if_needed

    local selection
    selection=$( { echo -e "NEW\t✨ Create new ticket"; echo -e "HOTFIX\t🔥 Hotfix (no ticket needed)"; get_cached_tickets; } | $FZF \
        --prompt="  🎫 Ticket > " \
        --height=20 \
        --reverse \
        --border=rounded \
        --delimiter='\t' \
        --with-nth=1,2 \
        --preview='key=$(echo {} | cut -f1); if [ "$key" = "NEW" ]; then echo "Create a new Jira ticket"; else curl -s -u "'"${JIRA_EMAIL}:${JIRA_API_TOKEN}"'" "https://'"${JIRA_DOMAIN}"'/rest/api/3/issue/${key}?fields=summary,status,assignee" 2>/dev/null | jq -r "\"Status: \" + .fields.status.name + \"\nAssignee: \" + (.fields.assignee.displayName // \"Unassigned\") + \"\n\n\" + .fields.summary" 2>/dev/null || echo "Loading..."; fi' \
        --preview-window=right:40%:wrap \
        --header="Enter: select │ Type ticket title or paste Slack URL" \
        --print-query)

    local query=$(echo "$selection" | head -1)
    local selected=$(echo "$selection" | tail -1)

    if [[ "$query" =~ ^https://.*slack\.com/archives/([A-Z0-9]+)/p([0-9]+) ]]; then
        echo "SLACK:$query"
        return 0
    fi

    if [[ "$selected" =~ ^HOTFIX ]]; then
        echo "HOTFIX"
        return 0
    fi

    if [[ "$selected" =~ ^NEW ]]; then
        echo "NEW"
        return 0
    fi

    if [ -n "$selected" ] && [ "$selected" != "$query" ]; then
        echo "$selected" | cut -f1
    elif [[ "$query" =~ ^${JIRA_PROJECT}-[0-9]+$ ]]; then
        echo "$query"
    elif [[ "$query" =~ ^[0-9]+$ ]]; then
        echo "${JIRA_PROJECT}-$query"
    elif [ -n "$query" ]; then
        echo "TITLE:$query"
    else
        echo ""
    fi
}

# Resolve a ticket selection (output of select_ticket_or_slack) to an actual ticket key.
# Creates a new ticket if selection is NEW or TITLE:...; skips HOTFIX/SLACK.
# Prints the resolved key to stdout, or nothing if cancelled/skipped.
resolve_ticket_selection() {
    local selection="$1"

    [ -z "$selection" ] && return 0
    [[ "$selection" =~ ^HOTFIX ]] && return 0
    [[ "$selection" =~ ^SLACK: ]] && return 0

    if [ "$selection" = "NEW" ] || [[ "$selection" =~ ^TITLE:(.+)$ ]]; then
        local flags=()
        if [[ "$selection" =~ ^TITLE:(.+)$ ]]; then
            flags+=(--summary "${BASH_REMATCH[1]}")
        fi
        local result_file
        result_file=$(mktemp)
        trap "rm -f '$result_file'" EXIT
        if ! "$SCRIPT_DIR/create-jira-ticket" "${flags[@]}" --output-file "$result_file"; then
            echo -e "  ${RED}✗ Failed to create ticket${RESET}" >&2
            rm -f "$result_file"
            return 0
        fi
        local key
        key=$(jq -r '.key // empty' < "$result_file")
        rm -f "$result_file"
        [[ "$key" =~ ^[A-Z]+-[0-9]+$ ]] && echo "$key"
    else
        echo "$selection" | tr '[:lower:]' '[:upper:]'
    fi
}

# Interactively collect additional ticket keys (fzf loop, y/N gated).
# Appends resolved keys to the named array variable passed as $1.
# Usage: prompt_additional_tickets EXTRA_TICKET_KEYS
prompt_additional_tickets() {
    local -n _arr="$1"
    printf "  ${DIM}Link additional tickets to this MR?${RESET} ${DIM}(y/N)${RESET} " >&2
    read -r -n 1 _add_more < /dev/tty 2>/dev/null || _add_more=""
    echo "" >&2
    while [[ "$_add_more" =~ ^[Yy]$ ]]; do
        local _sel _key
        _sel=$(select_ticket_or_slack)
        _key=$(resolve_ticket_selection "$_sel")
        if [ -n "$_key" ]; then
            _arr+=("$_key")
            echo -e "  ${GREEN}✓${RESET} Added: ${CYAN}${_key}${RESET}" >&2
        fi
        echo "" >&2
        printf "  ${DIM}Add another?${RESET} ${DIM}(y/N)${RESET} " >&2
        read -r -n 1 _add_more < /dev/tty 2>/dev/null || _add_more=""
        echo "" >&2
    done
}

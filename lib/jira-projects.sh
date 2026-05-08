#!/usr/bin/env bash
# Multi-project Jira config helper.
#
# Source this AFTER sourcing .env. Reads JIRA_PROJECTS (comma-separated, e.g.
# "UB,UL") with fallback to legacy single-project JIRA_PROJECT, and exports
# the helpers used across rr/oneshot/jira-fzf for ticket detection and JQL.
#
# Exports:
#   JIRA_PROJECT          Primary project key (first in list). Used as default
#                         when a script needs to pick one — e.g. ticket
#                         creation defaults, header display.
#   JIRA_PROJECT_REGEX    Bash/grep alternation, e.g. "(UB|UL)". Drop-in
#                         replacement for "${JIRA_PROJECT}" inside ticket
#                         extraction patterns: ${JIRA_PROJECT_REGEX}-[0-9]+
#   JIRA_PROJECT_JQL_LIST JQL-friendly comma list, e.g. "UB, UL". Use as:
#                         project IN (${JIRA_PROJECT_JQL_LIST})
#
# Also leaves JIRA_PROJECT_LIST as a bash array for callers that need to
# iterate (not exported — bash can't export arrays).

if [ -n "${JIRA_PROJECTS_LOADED:-}" ]; then
    return 0
fi
JIRA_PROJECTS_LOADED=1

# Build project list: prefer JIRA_PROJECTS, fall back to legacy JIRA_PROJECT
if [ -n "${JIRA_PROJECTS:-}" ]; then
    IFS=',' read -ra JIRA_PROJECT_LIST <<< "$JIRA_PROJECTS"
    for i in "${!JIRA_PROJECT_LIST[@]}"; do
        JIRA_PROJECT_LIST[$i]="$(echo "${JIRA_PROJECT_LIST[$i]}" | tr -d '[:space:]')"
    done
elif [ -n "${JIRA_PROJECT:-}" ]; then
    JIRA_PROJECT_LIST=("$JIRA_PROJECT")
else
    JIRA_PROJECT_LIST=()
fi

if [ ${#JIRA_PROJECT_LIST[@]} -gt 0 ]; then
    JIRA_PROJECT="${JIRA_PROJECT_LIST[0]}"
    JIRA_PROJECT_REGEX="($(IFS='|'; echo "${JIRA_PROJECT_LIST[*]}"))"
    JIRA_PROJECT_JQL_LIST="$(IFS=,; set -- "${JIRA_PROJECT_LIST[@]}"; echo "$*" | sed 's/,/, /g')"
    # Display form: "UB+UL" for headers/banners
    JIRA_PROJECT_DISPLAY="$(IFS=+; echo "${JIRA_PROJECT_LIST[*]}")"
else
    JIRA_PROJECT_REGEX=""
    JIRA_PROJECT_JQL_LIST=""
    JIRA_PROJECT_DISPLAY=""
fi

export JIRA_PROJECT JIRA_PROJECT_REGEX JIRA_PROJECT_JQL_LIST JIRA_PROJECT_DISPLAY

# Resolve a bare ticket number (e.g. "1234") to a fully-qualified key.
# Tries each configured project (cache first, then a parallel Jira lookup).
# - 0 hits  → echoes "{primary}-{n}" (preserves legacy behavior; downstream
#             code surfaces the not-found error)
# - 1 hit   → echoes that key
# - 2+ hits → fzf-picks (or falls back to the primary-board hit if no fzf)
#
# Requires (when API lookup is needed): JIRA_DOMAIN, JIRA_EMAIL,
# JIRA_API_TOKEN. Optional: TICKETS_CACHE (skipped if missing), FZF.
disambiguate_ticket_number() {
    local n="$1"
    local cache="${TICKETS_CACHE:-$HOME/.cache/jira-fzf/tickets.json}"
    local found_keys=()
    local need_api_keys=()

    for proj in "${JIRA_PROJECT_LIST[@]}"; do
        local key="${proj}-${n}"
        if [ -f "$cache" ] && jq -e --arg k "$key" '.issues[]? | select(.key == $k)' "$cache" >/dev/null 2>&1; then
            found_keys+=("$key")
        else
            need_api_keys+=("$key")
        fi
    done

    if [ ${#need_api_keys[@]} -gt 0 ] && [ -n "${JIRA_DOMAIN:-}" ] && [ -n "${JIRA_EMAIL:-}" ] && [ -n "${JIRA_API_TOKEN:-}" ]; then
        local tmpdir
        tmpdir=$(mktemp -d)
        local pids=()
        for key in "${need_api_keys[@]}"; do
            (
                local code
                code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                    -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
                    "https://${JIRA_DOMAIN}/rest/api/3/issue/${key}?fields=summary" 2>/dev/null)
                [ "$code" = "200" ] && echo "$key" > "$tmpdir/$key"
            ) &
            pids+=($!)
        done
        wait "${pids[@]}" 2>/dev/null || true
        for key in "${need_api_keys[@]}"; do
            [ -f "$tmpdir/$key" ] && found_keys+=("$key")
        done
        rm -rf "$tmpdir"
    fi

    if [ ${#found_keys[@]} -eq 0 ]; then
        echo "${JIRA_PROJECT}-${n}"
    elif [ ${#found_keys[@]} -eq 1 ]; then
        echo "${found_keys[0]}"
    else
        local choice=""
        if [ -n "${FZF:-}" ] && [ -t 2 ]; then
            choice=$(printf '%s\n' "${found_keys[@]}" | $FZF \
                --prompt="  🎯 Ticket #${n} exists in multiple boards > " \
                --height=10 --reverse --border=rounded \
                --header="Pick which board's ticket to use" </dev/tty)
        fi
        if [ -z "$choice" ]; then
            for k in "${found_keys[@]}"; do
                [[ "$k" == "${JIRA_PROJECT}-"* ]] && choice="$k" && break
            done
            [ -z "$choice" ] && choice="${found_keys[0]}"
        fi
        echo "$choice"
    fi
}

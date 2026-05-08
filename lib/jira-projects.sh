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
else
    JIRA_PROJECT_REGEX=""
    JIRA_PROJECT_JQL_LIST=""
fi

export JIRA_PROJECT JIRA_PROJECT_REGEX JIRA_PROJECT_JQL_LIST

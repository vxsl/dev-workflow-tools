#!/usr/bin/env bash
# Jira credential handling for curl.
#
# Why this exists: passing credentials as `curl -u "$EMAIL:$TOKEN"` puts the
# API token in the process argv, where any local user can read it out of
# `ps`. That was bad enough for the short-lived curl calls, but the fzf
# pickers interpolated the token into their *own* --preview argv at build
# time, so the token sat in a long-lived process's command line for as long
# as the picker stayed open (observed: 4+ hours).
#
# Instead we write the credentials once to a 0600 file in the user's runtime
# dir (tmpfs, wiped on logout) and hand curl `-K "$JIRA_CURL_CONF"`. The path
# is not a secret, so it is safe to interpolate into a preview command, and
# the credentials never touch any argv.
#
# Callers: source this, then call jira_curl_conf_init once before use.
# Requires JIRA_EMAIL and JIRA_API_TOKEN to already be set (from .env).

if [ -n "${JIRA_CURL_LOADED:-}" ]; then
    return 0
fi
JIRA_CURL_LOADED=1

jira_curl_conf_init() {
    # Already built this run and still present? Nothing to do.
    if [ -n "${JIRA_CURL_CONF:-}" ] && [ -f "${JIRA_CURL_CONF}" ]; then
        return 0
    fi

    if [ -z "${JIRA_EMAIL:-}" ] || [ -z "${JIRA_API_TOKEN:-}" ]; then
        return 1
    fi

    local dir="${XDG_RUNTIME_DIR:-/tmp}/dev-workflow-tools"
    [ -n "${XDG_RUNTIME_DIR:-}" ] || dir="/tmp/dev-workflow-tools-$(id -u)"

    mkdir -p "$dir" 2>/dev/null || return 1
    chmod 700 "$dir" 2>/dev/null

    local conf="$dir/jira-curl.conf"

    # Create empty and lock down permissions BEFORE writing the secret, so the
    # token is never briefly readable through a default-umask window.
    : >"$conf" 2>/dev/null || return 1
    chmod 600 "$conf" 2>/dev/null || return 1
    printf 'user = "%s:%s"\n' "$JIRA_EMAIL" "$JIRA_API_TOKEN" >"$conf" || return 1

    JIRA_CURL_CONF="$conf"
    export JIRA_CURL_CONF
    return 0
}

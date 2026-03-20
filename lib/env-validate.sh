#!/bin/sh
# Environment Variable Validation Library
# Provides clear, consistent error messages when required env vars are missing.
#
# Usage:
#   source "$SCRIPT_DIR/../lib/env-validate.sh"
#   require_env JIRA_DOMAIN JIRA_PROJECT           # Fatal: exits if missing
#   warn_env "Jira API features" JIRA_EMAIL JIRA_API_TOKEN  # Warning: sets ENV_WARNINGS
#
# After calling warn_env, check $ENV_WARNINGS for a displayable warning string.
# This lets the caller decide HOW to show it (stderr, fzf header, etc).

# Prevent multiple loads
if [ -n "${ENV_VALIDATE_LOADED:-}" ]; then
    return 0
fi
ENV_VALIDATE_LOADED=1

# Accumulated warnings — callers read this to display however they want
ENV_WARNINGS=""

# Resolve the repo root relative to this library (lib/ -> repo root)
_ENV_VALIDATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
_ENV_VALIDATE_REPO_DIR="$(cd "$_ENV_VALIDATE_LIB_DIR/.." 2>/dev/null && pwd)"

# Flag if .env file is missing
if [ ! -f "$_ENV_VALIDATE_REPO_DIR/.env" ]; then
    ENV_WARNINGS="⚠ No .env file — run: cp .env.example .env"
fi

# require_env VAR1 VAR2 ...
# Exits with error if any of the listed variables are empty/unset.
# Shows a formatted box listing all missing vars.
require_env() {
    local count=0
    local missing_names=""

    for var_name in "$@"; do
        eval "val=\${$var_name:-}"
        if [ -z "$val" ]; then
            count=$((count + 1))
            missing_names="${missing_names} ${var_name}"
        fi
    done

    if [ "$count" -gt 0 ]; then
        echo "" >&2
        if [ -n "$ENV_WARNINGS" ]; then
            echo "  $ENV_WARNINGS" >&2
            echo "" >&2
        fi
        echo "╭─────────────────────────────────────────────────────────────╮" >&2
        echo "│  ✗  Missing Required Configuration                         │" >&2
        echo "├─────────────────────────────────────────────────────────────┤" >&2
        echo "│                                                             │" >&2
        echo "│  The following environment variables must be set:           │" >&2
        echo "│                                                             │" >&2
        for var_name in "$@"; do
            eval "val=\${$var_name:-}"
            if [ -z "$val" ]; then
                printf "│    %-57s│\n" "$var_name" >&2
            fi
        done
        echo "│                                                             │" >&2
        echo "│  Set them in .env or export them in your shell.            │" >&2
        echo "│  See .env.example for a complete template.                 │" >&2
        echo "│                                                             │" >&2
        echo "╰─────────────────────────────────────────────────────────────╯" >&2
        echo "" >&2
        exit 1
    fi
}

# warn_env FEATURE_LABEL VAR1 VAR2 ...
# Appends to ENV_WARNINGS if any vars are missing.
# Does NOT exit or print — the caller decides how to display.
warn_env() {
    local feature="$1"
    shift

    local missing_names=""

    for var_name in "$@"; do
        eval "val=\${$var_name:-}"
        if [ -z "$val" ]; then
            missing_names="${missing_names} ${var_name}"
        fi
    done

    if [ -n "$missing_names" ]; then
        local msg="⚠ ${feature}: set${missing_names} in .env"
        if [ -n "$ENV_WARNINGS" ]; then
            ENV_WARNINGS="${ENV_WARNINGS}
${msg}"
        else
            ENV_WARNINGS="$msg"
        fi
        return 1
    fi
    return 0
}

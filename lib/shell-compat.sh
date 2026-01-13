#!/bin/sh
# Shell Compatibility Module
# Provides 3 helper functions to make the dev-workflow-tools cross-compatibile for both bash and zsh
#
# This library provides wrapper functions to handle differences between
# bash and zsh, allowing scripts to work in both shells without modification.
#
# Usage:
#   source "$SCRIPT_DIR/../lib/shell-compat.sh"
#
# Functions:
#   shell_get_match INDEX          - Get regex capture group from last match
#   shell_get_pipe_status INDEX    - Get exit status from pipeline command
#   shell_read_prompt PROMPT VAR [OPTS] - Read user input with prompt

# Prevent multiple loads
if [ -n "$SHELL_COMPAT_LOADED" ]; then
    return 0
fi
export SHELL_COMPAT_LOADED=1

# Detect shell type
if [ -n "$BASH_VERSION" ]; then
    export SHELL_TYPE="bash"
elif [ -n "$ZSH_VERSION" ]; then
    export SHELL_TYPE="zsh"
else
    echo "Error: Unsupported shell (requires bash or zsh)" >&2
    return 1
fi

# ============================================================================
# Compatibility Functions
# ============================================================================

# Get regex match capture group
# In bash: uses BASH_REMATCH array
# In zsh: uses match array
shell_get_match() {
    local index="$1"
    if [ "$SHELL_TYPE" = "bash" ]; then
        echo "${BASH_REMATCH[$index]}"
    else
        echo "${match[$index]}"
    fi
}

# Get pipeline command exit status
# In bash: uses PIPESTATUS array (0-indexed)
# In zsh: uses pipestatus array (1-indexed)
shell_get_pipe_status() {
    local index="$1"
    if [ "$SHELL_TYPE" = "bash" ]; then
        echo "${PIPESTATUS[$index]}"
    else
        # zsh pipestatus is 1-indexed
        echo "${pipestatus[$((index + 1))]}"
    fi
}

# Read user input with prompt (cross-shell compatible)
# In bash: uses read -p for prompt
# In zsh: uses read "?prompt" syntax
# Args:
#   $1 - Prompt string to display
#   $2 - Variable name to store input
#   $3 - Optional: "-k 1" for single character read
shell_read_prompt() {
    local prompt="$1"
    local var_name="$2"
    local opts="${3:-}"
    
    if [ "$SHELL_TYPE" = "bash" ]; then
        if [[ "$opts" == *"-k"* ]]; then
            # Single character read in bash
            eval "read -p \"\$prompt\" -n 1 -r \$var_name < /dev/tty"
        else
            # Normal read in bash
            eval "read -p \"\$prompt\" -r \$var_name < /dev/tty"
        fi
    else
        if [[ "$opts" == *"-k"* ]]; then
            # Single character read in zsh
            eval "read -k 1 \"?\$prompt\" \$var_name < /dev/tty"
        else
            # Normal read in zsh
            eval "read \"?\$prompt\" \$var_name < /dev/tty"
        fi
    fi
}

# ============================================================================
# Initialization Complete
# ============================================================================

# Export functions for subshells (if needed)
if [ "$SHELL_TYPE" = "bash" ]; then
    export -f shell_get_match 2>/dev/null || true
    export -f shell_get_pipe_status 2>/dev/null || true
    export -f shell_read_prompt 2>/dev/null || true
fi

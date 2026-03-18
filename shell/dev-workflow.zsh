# dev-workflow-tools shell integration for Zsh
# Source this file from your .zshrc:
#   source ~/bin/dev-workflow-tools/shell/dev-workflow.zsh

# Detect the dev-workflow-tools directory
if [[ -z "$DEV_WORKFLOW_TOOLS_DIR" ]]; then
    DEV_WORKFLOW_TOOLS_DIR="${0:A:h:h}"
fi

# Add dev-workflow-tools/bin to PATH if not already there
if [[ ! "$PATH" =~ "$DEV_WORKFLOW_TOOLS_DIR/bin" ]]; then
    export PATH="$DEV_WORKFLOW_TOOLS_DIR/bin:$PATH"
fi

# ============================================================================
# Git Commit Message History Widget (Ctrl+G)
# ============================================================================
# Interactive fzf widget for selecting past commit messages
# Supports conventional commit types via Ctrl+F/X/R/O shortcuts

gcm-widget() {
    local output query selection msg branch
    
    branch=$(git branch --show-current 2>/dev/null || echo "detached")
    
    output=$(tac ~/.gcm_history 2>/dev/null | awk '!seen[$0]++' | awk '{
        # Recency gradient: green -> yellow -> red -> dim
        if (NR <= 5) printf "\033[92m%s\033[0m\n", $0        # bright green (most recent)
        else if (NR <= 15) printf "\033[32m%s\033[0m\n", $0  # green
        else if (NR <= 30) printf "\033[33m%s\033[0m\n", $0  # yellow
        else if (NR <= 50) printf "\033[31m%s\033[0m\n", $0  # red
        else printf "\033[90m%s\033[0m\n", $0                # dim gray
    }' | fzf \
            --ansi \
            --height=60% \
            --reverse \
            --print-query \
            --header=$'🌿 '"$branch"$' │ \e[33mc-f\e[0m feat \e[33mc-x\e[0m fix \e[33mc-r\e[0m refactor \e[33mc-o\e[0m chore' \
            --bind='ctrl-f:transform-query(echo "feat: {q}")' \
            --bind='ctrl-x:transform-query(echo "fix: {q}")' \
            --bind='ctrl-r:transform-query(echo "refactor: {q}")' \
            --bind='ctrl-o:transform-query(echo "chore: {q}")')
    
    query=$(printf '%s' "$output" | head -1)
    selection=$(printf '%s' "$output" | sed -n '2p')
    
    if [[ -n "$selection" ]]; then
        # Strip ANSI color codes from selection
        msg=$(printf '%s' "$selection" | sed 's/\x1b\[[0-9;]*m//g')
    elif [[ -n "$query" ]]; then
        msg="$query"
    fi
    
    if [[ -n "$msg" ]]; then
        BUFFER="gcm \"$msg\""
        zle accept-line
    else
        zle reset-prompt
    fi
}
zle -N gcm-widget
bindkey -M viins '^G' gcm-widget
bindkey -M vicmd '^G' gcm-widget

# ============================================================================
# Git Commit Functions
# ============================================================================
# Save commit messages to history for reuse in gcm-widget

# Commit without verification (skips hooks)
function nvgcm() {
    local msg="$*"
    echo "$msg" >> ~/.gcm_history
    git commit --message="$msg" --no-verify
}

# Standard commit with message history
function gcm() {
    local msg="$*"
    if [[ -z "$msg" ]]; then
        git commit
    else
        echo "$msg" >> ~/.gcm_history
        git commit --message="$msg"
    fi
}

# ============================================================================
# Git Workflow Aliases
# ============================================================================
# Core workflow commands for day-to-day development

# Branch Management
alias w="wt select"  # Interactive worktree switcher
# alias cw="source create-wt"
alias gcb="git checkout -b"                   # Create and checkout new branch
alias gc="git for-each-ref --sort=-committerdate refs/heads/ --format='%(align:left,40)%(refname:short)%(end)%(committerdate:relative)' | fzf --preview 'git log -p main..{1} --color=always' | cut -c1-40 | xargs git switch"

# Interactive branch/worktree switcher with Jira integration
r() {
    local output
    output=$("$DEV_WORKFLOW_TOOLS_DIR/bin/rr.sh" "$@" 2>&1)
    local exit_code=$?

    # Extract directives
    local target_dir=$(echo "$output" | grep "RR_CD:" | head -1 | sed 's/.*RR_CD://' | tr -d '\r\n')
    local target_branch=$(echo "$output" | grep "RR_SWITCH:" | head -1 | sed 's/.*RR_SWITCH://' | tr -d '\r\n')

    # Print all output except directive lines
    echo "$output" | grep -v "RR_CD:" | grep -v "RR_SWITCH:"

    # Handle CD directive first
    if [ -n "$target_dir" ]; then
        if [ -d "$target_dir" ]; then
            cd "$target_dir"
            echo ""
            echo "→ Switched to: $target_dir"
            # Optionally open/focus Cursor at the new worktree (acts like GitLens worktree switch)
            if [ "${RR_CURSOR_SWITCH:-false}" = "true" ] && command -v cursor >/dev/null 2>&1; then
                cursor "$target_dir" >/dev/null 2>&1 &
            fi
        else
            echo "Error: Invalid directory: $target_dir" >&2
            return 1
        fi
    fi

    # Handle SWITCH directive after CD
    if [ -n "$target_branch" ]; then
        echo "→ Switching to branch: $target_branch"
        git switch "$target_branch"
    fi

    return $exit_code
}

# Commit Operations
alias wip="git commit -m \"wip --no-verify\" --no-verify"  # Quick WIP commit (no hooks)
alias gca="git commit --amend --no-edit"      # Amend last commit without editing message
alias reword="git commit --amend"             # Amend commit message

# Reset Operations
alias rhom="git fetch --all && git reset --hard origin/main"      # Hard reset to origin/main
alias rho="git reset --hard origin/@{u}"      # Hard reset to upstream
alias gr="git reset --hard @{u}"              # Hard reset to upstream (short)
alias gru="git reset --hard @{u}"             # Hard reset to upstream (alt)
alias gfgru="git fetch --all && git reset --hard @{u}"
alias so="git reset --soft HEAD~1; git reset; s"    # Soft reset + unstage
alias soft="git reset --soft HEAD~1; git reset; s"  # Soft reset + unstage (verbose)

# Stash Operations  
alias gs="git stash"                          # Stash changes
alias gsk="git stash -uk"                     # Stash including untracked files
alias gsp="git stash pop"                     # Pop stash
alias swip="git add -A; wip; s"              # Add all + WIP commit + status

# Fetch & Pull Operations
alias p="git pull"                            # Pull changes
alias pull="git pull"                         # Pull changes (verbose)
alias gf="git fetch --all"                    # Fetch all remotes
alias gfpa="git fetch --prune; git fetch --all"  # Fetch with prune
alias gfmm="git fetch origin master:master"   # Fetch master directly
alias gfpamm="git fetch --prune; git fetch --all; gfmm"  # Full fetch with master

# Rebase Operations
alias grc="git rebase --con"                  # Continue rebase (typo-friendly)
alias gra="git rebase --abort"                # Abort rebase
alias grom="git rebase origin/main"           # Rebase onto origin/main
alias gfgrom="git fetch --all && git rebase origin/main"  # Fetch + rebase origin/main
alias grmm="gfpa; gfmm; git rebase master"   # Full fetch + rebase master

# Cherry-pick Operations
alias gcpc="git cherry-pick --continue"       # Continue cherry-pick
alias gcpa="git cherry-pick --abort"          # Abort cherry-pick

# Push Operations
alias push="git push"                         # Push changes
alias mush="git push"                         # Push changes (fat-finger friendly)

# Status & Info
alias gds="git-branch-status"                 # Branch status (if available)

# Jira + GitLab Integration Scripts
alias os="oneshot"                        # One-shot commit workflow with Jira integration

# misc 
alias c="claude"

# ============================================================================
# Worktree Prompt Integration
# ============================================================================
# For p10k users: source ~/bin/dev-workflow-tools/shell/p10k-worktree.zsh
# AFTER .p10k.zsh in your .zshrc for automatic worktree indicator

# ============================================================================
# Configuration
# ============================================================================
# Set these in your .zshrc before sourcing this file to customize behavior:
#   DEV_WORKFLOW_TOOLS_DIR - Override auto-detection of tools directory
#   JIRA_EMAIL            - Your Jira email (or set in .env)
#   JIRA_API_TOKEN        - Your Jira API token (or set in .env)

# Load environment variables from .env if it exists
if [[ -f "$DEV_WORKFLOW_TOOLS_DIR/.env" ]]; then
    set -a
    source "$DEV_WORKFLOW_TOOLS_DIR/.env"
    set +a
elif [[ -f "$DEV_WORKFLOW_TOOLS_DIR/../.env" ]]; then
    # Fallback: check parent directory (~/bin/.env)
    set -a
    source "$DEV_WORKFLOW_TOOLS_DIR/../.env"
    set +a
fi

# ============================================================================
# Worktree Navigation
# ============================================================================

# cw - jump to subdirectory within current git worktree
# Usage: cw [subdir]
# Example: cw client/web
# If no subdir provided, goes to git root
cw() {
    local git_root subdir target_dir

    git_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$git_root" ]; then
        echo "✗ Not in a git repository" >&2
        return 1
    fi

    if [ -n "$1" ]; then
        subdir="$1"
        target_dir="$git_root/$subdir"

        if [ ! -d "$target_dir" ]; then
            echo "✗ Directory '$subdir' does not exist in git root" >&2
            return 1
        fi

        cd "$target_dir"
    else
        cd "$git_root"
    fi
}

# Completion for cw - suggest directories in git root
_cw_completion() {
    local git_root

    git_root=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -z "$git_root" ]; then
        return
    fi

    # Find directories relative to git root
    local -a dirs
    dirs=("${(@f)$(cd "$git_root" && find . -maxdepth 3 -type d -not -path '*/.*' 2>/dev/null | sed 's|^\./||' | sort)}")

    _describe 'directory' dirs
}

compdef _cw_completion cw

# ============================================================================
# Completion
# ============================================================================
# Add completion for our custom commands (if needed in future)
























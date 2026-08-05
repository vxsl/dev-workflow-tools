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
alias gcb="git checkout -b"                   # Create and checkout new branch
alias gc="git for-each-ref --sort=-committerdate refs/heads/ --format='%(align:left,40)%(refname:short)%(end)%(committerdate:relative)' | fzf --preview 'git log -p main..{1} --color=always' | cut -c1-40 | xargs git switch"

# Interactive branch/worktree switcher with Jira integration
r() {
    local output
    output=$("$DEV_WORKFLOW_TOOLS_DIR/bin/rr.sh" "$@")
    local exit_code=$?

    # Extract directives
    local target_dir=$(echo "$output" | grep "RR_CD:" | head -1 | sed 's/.*RR_CD://' | tr -d '\r\n')
    local target_branch=$(echo "$output" | grep "RR_SWITCH:" | head -1 | sed 's/.*RR_SWITCH://' | tr -d '\r\n')

    # Print any non-directive stdout
    echo "$output" | grep -v "RR_CD:" | grep -v "RR_SWITCH:"

    # Handle CD directive first
    if [ -n "$target_dir" ]; then
        if [ -d "$target_dir" ]; then
            cd "$target_dir"
            echo ""
            echo "→ Switched to: $target_dir"
            # ctrl+enter in fzf writes a flag file → open in Cursor
            local cursor_flag="$HOME/.cache/rr/cursor_flag"
            if [ -f "$cursor_flag" ]; then
                rm -f "$cursor_flag"
                if command -v cursor >/dev/null 2>&1; then
                    cursor -r "$target_dir" >/dev/null 2>&1 &
                fi
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

# Push Operations — git-push-autofix retries if pre-push hook adds autofix commits
alias push="git-push-autofix"                 # Push changes
alias mush="git-push-autofix"                 # Push changes (fat-finger friendly)

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
# Ref Picker (Ctrl+B, and Tab where a ref is the only sensible argument)
# ============================================================================
# `git rebase <TAB>` is the case this exists for. Git's own completion offers 370
# alphabetised branch names, which is the wrong index entirely: what you remember is the
# ticket ("the AOI fill one"), and the branch name is the thing you are trying to look up.
# bin/fzref answers the question the other way round — see its header for the row format
# and for why the accept key, not the tool, decides which of a ref's three names you get.
#
# Two ways in, because they fail differently:
#   Ctrl+B  always opens the picker and replaces the word at the cursor. Predictable.
#   Tab     opens it only where a ref is the *only* thing that could go there, and falls
#           through to normal completion everywhere else.

# Git subcommands whose arguments are refs and cannot be anything else. Tab takes over
# unconditionally here, even on an empty word.
_FZREF_REF_ONLY=(rebase merge switch cherry-pick revert)

# Subcommands that take a ref OR a path. Tab only takes over when the partial word already
# looks like a ref (i.e. some ref starts with it) — otherwise `git diff src/<TAB>` would
# stop completing filenames, which is a much worse trade than not helping at all.
_FZREF_REF_OR_PATH=(checkout diff log show reset restore bisect)

# Global git options that swallow the word after them. Without this, `git -C /elsewhere
# rebase` looks like the subcommand is "/elsewhere".
_FZREF_GIT_OPTS_WITH_VALUE=(-C -c --git-dir --work-tree --namespace --exec-path --config-env)

# Flags that turn `git branch` from "name a branch to create" into "name one that exists".
_FZREF_BRANCH_REF_FLAGS=(-d -D --delete -m -M --move -c -C --copy -f --force --set-upstream-to --edit-description)

# The word the cursor is in, and the offsets that delimit it, so a replacement can put
# back exactly that span. Sets REPLY / _fzref_from / _fzref_to.
_fzref_word_at_cursor() {
    local left="${LBUFFER##* }" right="${RBUFFER%% *}"
    # A newline is as much a word boundary as a space, and a multi-line buffer is normal
    # once a command has a `\` continuation in it.
    left="${left##*$'\n'}"; right="${right%%$'\n'*}"
    _fzref_from=$(( ${#LBUFFER} - ${#left} ))
    _fzref_to=$(( ${#LBUFFER} + ${#right} ))
    REPLY="$left$right"
}

# Splice a token into the buffer in place of the word at the cursor, leaving the cursor
# just after it plus a space — so the next argument can be typed without reaching for
# anything. Quoted only when it has to be: a branch name with a slash in it needs no
# quoting, and `git rebase 'origin/main'` in your history is noise.
_fzref_replace_word() {
    local token="$1"
    [[ "$token" == *[\ \'\"\$\`\(\)\|\&\;\<\>]* ]] && token="${(q)token}"
    BUFFER="${BUFFER[1,_fzref_from]}${token}${BUFFER[_fzref_to+1,-1]}"
    CURSOR=$(( _fzref_from + ${#token} ))
    # Only add the trailing space if we are at the end of the line; mid-line it would be
    # inserting a space someone did not ask for.
    if (( CURSOR == ${#BUFFER} )); then
        BUFFER="$BUFFER "
        CURSOR=$(( CURSOR + 1 ))
    fi
}

# Run the picker with the partial word as its query and splice the result in.
# Returns non-zero when nothing was picked, so callers can decide whether to fall back.
_fzref_pick_into_buffer() {
    local word token
    _fzref_word_at_cursor
    word="$REPLY"

    token=$("$DEV_WORKFLOW_TOOLS_DIR/bin/fzref" --query "$word" --width "$COLUMNS" 2>/dev/null)
    if [[ -n "$token" ]]; then
        _fzref_replace_word "$token"
        return 0
    fi
    return 1
}

fzref-widget() {
    _fzref_pick_into_buffer
    zle reset-prompt
}
zle -N fzref-widget
bindkey -M viins '^B' fzref-widget
bindkey -M vicmd '^B' fzref-widget

# Does the command being typed want a ref where the cursor is?
# Sets REPLY to "only" (take Tab over outright) or "maybe" (only if the word already looks
# like a ref); returns 1 when a ref is not on the table at all.
#
# Reads the words BEFORE the cursor only, and keys off the subcommand rather than the
# argument index wherever it can — that way `git rebase --onto main <TAB>` still works
# without this file having to know every option git has.
_fzref_tab_context() {
    local -a words
    words=(${(z)LBUFFER})
    (( ${#words} )) || return 1

    # Drop the partial word the cursor is inside — it is the thing being completed, not
    # context. Only when the cursor is mid-word: a trailing space means a fresh argument.
    #
    # `("${(@)words[1,-2]}")` and not `("${words[1,-2]}")`: the second joins the whole
    # slice into ONE word, so every mid-word Tab saw a one-element array and fell through.
    if [[ "$LBUFFER" != *' ' && "$LBUFFER" != *$'\n' ]]; then
        words=("${(@)words[1,-2]}")
    fi
    (( ${#words} )) || return 1

    local cmd="${words[1]}" w skip_next=0
    # The words that are neither options nor option values, in order — so bare[2] is the
    # subcommand and bare[3..] are its positional arguments.
    local -a bare=() flags=()
    for w in "${words[@]}"; do
        if (( skip_next )); then skip_next=0; continue; fi
        if [[ "$w" == -* ]]; then
            flags+=("$w")
            (( ${_FZREF_GIT_OPTS_WITH_VALUE[(Ie)$w]} )) && skip_next=1
            continue
        fi
        bare+=("$w")
    done

    case "$cmd" in
        git|g) ;;
        # create-wt takes a ticket or branch and nothing else.
        create-wt) REPLY=only; return 0 ;;
        *) return 1 ;;
    esac

    (( ${#bare} >= 2 )) || return 1
    local sub="${bare[2]}"
    # Positional arguments to the subcommand already typed, cursor's own word excluded.
    local argn=$(( ${#bare} - 2 ))

    (( ${_FZREF_REF_ONLY[(Ie)$sub]} ))    && { REPLY=only;  return 0 }
    (( ${_FZREF_REF_OR_PATH[(Ie)$sub]} )) && { REPLY=maybe; return 0 }

    case "$sub" in
        # Bare `git branch <TAB>` is naming a branch to CREATE — hijacking that would be
        # actively wrong. With -d/-m/-f it is naming one that exists.
        branch)
            for w in "${flags[@]}"; do
                (( ${_FZREF_BRANCH_REF_FLAGS[(Ie)$w]} )) && { REPLY=only; return 0 }
            done
            return 1
            ;;
        # `git worktree add <path> <ref>`: the first positional is a path, the second is
        # the ref. Anything else under worktree names a path.
        worktree)
            [[ "${bare[3]:-}" == add ]] && (( argn >= 2 )) && { REPLY=only; return 0 }
            return 1
            ;;
        # First positional is the remote; the refspecs come after it. argn counts what is
        # already typed, so argn==1 means "the remote is in, the cursor is on the refspec".
        push|pull|fetch)
            (( argn >= 1 )) && { REPLY=only; return 0 }
            return 1
            ;;
    esac
    return 1
}

# Is there any ref starting with this word? The gate for the ref-or-path commands, and
# for-each-ref with a glob rather than fzref's full pipeline because the answer is needed
# before deciding to spend anything.
_fzref_word_is_reflike() {
    local word="$1"
    [[ -n "$word" ]] || return 1
    # An existing file wins: you meant the file.
    [[ -e "$word" ]] && return 1
    # Four patterns, because a partial ref can be any of four shapes: a branch prefix, an
    # already-remote-qualified name (`origin/UL-17`), the tail of a namespaced branch
    # (`aoi-filter` for fix/aoi-filter-cancellation), and the same on a remote.
    local hit
    hit=$(git for-each-ref --count=1 --format='%(refname:short)' \
            "refs/heads/${word}*" "refs/heads/*/${word}*" \
            "refs/remotes/${word}*" "refs/remotes/*/${word}*" 2>/dev/null)
    [[ -n "$hit" ]]
}

# The Tab hook. Returns 0 if it handled the key, 1 to let normal completion run.
# Called from the Tab dispatcher in ~/.zshrc, guarded there by $+functions so that file
# keeps working with this one unsourced.
_fzref_tab_try() {
    git rev-parse --git-dir >/dev/null 2>&1 || return 1
    _fzref_tab_context || return 1
    local want="$REPLY"

    if [[ "$want" == maybe ]]; then
        _fzref_word_at_cursor
        _fzref_word_is_reflike "$REPLY" || return 1
    fi

    _fzref_pick_into_buffer
    zle reset-prompt
    return 0
}

# ============================================================================
# Completion
# ============================================================================
# Add completion for our custom commands (if needed in future)
























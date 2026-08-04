# Inject worktree segment into p10k
#
# Source this AFTER .p10k.zsh in your .zshrc -- and make sure nothing sources .p10k.zsh
# again afterwards. It assigns POWERLEVEL9K_LEFT_PROMPT_ELEMENTS wholesale, so a second
# source silently drops the element injected below and the segment never appears. (The
# stock p10k footer line at the bottom of a generated .zshrc is exactly that second
# source; delete it if the config is already sourced further up.)

# Palette, key and hash are shared with fzedit's ⊙ worktree rows, so a worktree is the
# same colour in the prompt as it is in the picker. See lib/worktree-colour.sh for why
# that sharing is worth a file of its own.
source "${0:A:h}/../lib/worktree-colour.sh"

# p10k wants a named style per colour, resolved before it initialises, so unroll the
# palette into one COLOR<n> style each. Black text on every one of them: the palette is
# deliberately all light colours so that it can also be used as a foreground tint.
() {
    local -i i=0
    local c
    for c in ${=WTC_PALETTE}; do
        typeset -g "POWERLEVEL9K_WORKTREE_COLOR${i}_FOREGROUND=0"
        typeset -g "POWERLEVEL9K_WORKTREE_COLOR${i}_BACKGROUND=$c"
        (( i++ ))
    done
}

# Mismatch worktree state: bright white on bold red — impossible to miss
typeset -g POWERLEVEL9K_WORKTREE_MISMATCH_FOREGROUND=255
typeset -g POWERLEVEL9K_WORKTREE_MISMATCH_BACKGROUND=196

# Define the worktree segment
function prompt_worktree() {
    local git_dir=$(git rev-parse --git-dir 2>/dev/null) || return

    if [[ "$git_dir" == *"/worktrees/"* ]]; then
        # git's own name for this worktree -- the directory under .git/worktrees -- which
        # is also the colour key fzedit uses. See lib/worktree-colour.sh.
        local wt_name=${git_dir:t}
        wtc_colour "$wt_name"

        # Detect mismatch: extract expected branch from worktree dir name,
        # compare with actually checked-out branch
        local toplevel=$(git rev-parse --show-toplevel 2>/dev/null)
        local wt_basename=${toplevel:t}
        local expected_branch=""
        if [[ "$wt_basename" == *.* ]]; then
            expected_branch="${wt_basename##*.}"
        fi

        if [[ -n "$expected_branch" ]]; then
            local actual_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
            # Skip mismatch check during rebase/bisect/etc (detached HEAD)
            if [[ "$actual_branch" == "HEAD" ]]; then
                :  # detached HEAD — not a mismatch, just a transient state
            elif [[ -n "$actual_branch" && "$actual_branch" != "$expected_branch"* && "$expected_branch" != "$actual_branch"* ]]; then
                local expected_display="$expected_branch"
                [[ "$expected_branch" =~ ^([A-Z]+-[0-9]+) ]] && expected_display="${match[1]}"
                p10k segment -s "MISMATCH" -t "⚠ WRONG BRANCH: $actual_branch (expected $expected_display)"
                return
            fi
        fi

        # Show just the ticket ID if present (full path is already in the dir segment)
        local display="$wt_name"
        if [[ -n "$expected_branch" ]]; then
            # Extract ticket ID (e.g., UB-6709 from UB-6709-add-custom-trimet-...)
            local ticket_id=""
            [[ "$expected_branch" =~ ^([A-Z]+-[0-9]+) ]] && ticket_id="${match[1]}"
            [[ -n "$ticket_id" ]] && display="$ticket_id"
        fi

        # Normal — no mismatch
        p10k segment -s "COLOR$WTC_SLOT" -t "⊙ $display"
    fi
}

# Inject into left prompt elements if not already there
if (( ${+POWERLEVEL9K_LEFT_PROMPT_ELEMENTS} )); then
    if [[ ! " ${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[@]} " =~ " worktree " ]]; then
        POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(worktree "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[@]}")
    fi
fi

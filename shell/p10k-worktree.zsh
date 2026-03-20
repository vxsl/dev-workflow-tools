# Inject worktree segment into p10k
# Source this AFTER .p10k.zsh in your .zshrc

# Color palette for worktrees (vibrant, distinct colors)
typeset -g -a WORKTREE_COLORS=(
    220  # Yellow/Orange
    81   # Bright Cyan
    141  # Purple
    114  # Green
    167  # Red/Pink
    214  # Orange
    109  # Blue
    173  # Brown/Orange
    117  # Light Blue
    205  # Pink
)

# Define colors for each state (p10k requires these to be set globally)
# Normal worktree colors (COLOR0-COLOR9): vibrant background, black foreground
typeset -g POWERLEVEL9K_WORKTREE_COLOR0_FOREGROUND=0
typeset -g POWERLEVEL9K_WORKTREE_COLOR0_BACKGROUND=220
typeset -g POWERLEVEL9K_WORKTREE_COLOR1_FOREGROUND=0
typeset -g POWERLEVEL9K_WORKTREE_COLOR1_BACKGROUND=81
typeset -g POWERLEVEL9K_WORKTREE_COLOR2_FOREGROUND=0
typeset -g POWERLEVEL9K_WORKTREE_COLOR2_BACKGROUND=141
typeset -g POWERLEVEL9K_WORKTREE_COLOR3_FOREGROUND=0
typeset -g POWERLEVEL9K_WORKTREE_COLOR3_BACKGROUND=114
typeset -g POWERLEVEL9K_WORKTREE_COLOR4_FOREGROUND=0
typeset -g POWERLEVEL9K_WORKTREE_COLOR4_BACKGROUND=167
typeset -g POWERLEVEL9K_WORKTREE_COLOR5_FOREGROUND=0
typeset -g POWERLEVEL9K_WORKTREE_COLOR5_BACKGROUND=214
typeset -g POWERLEVEL9K_WORKTREE_COLOR6_FOREGROUND=0
typeset -g POWERLEVEL9K_WORKTREE_COLOR6_BACKGROUND=109
typeset -g POWERLEVEL9K_WORKTREE_COLOR7_FOREGROUND=0
typeset -g POWERLEVEL9K_WORKTREE_COLOR7_BACKGROUND=173
typeset -g POWERLEVEL9K_WORKTREE_COLOR8_FOREGROUND=0
typeset -g POWERLEVEL9K_WORKTREE_COLOR8_BACKGROUND=117
typeset -g POWERLEVEL9K_WORKTREE_COLOR9_FOREGROUND=0
typeset -g POWERLEVEL9K_WORKTREE_COLOR9_BACKGROUND=205

# Mismatch worktree state: bright white on bold red — impossible to miss
typeset -g POWERLEVEL9K_WORKTREE_MISMATCH_FOREGROUND=255
typeset -g POWERLEVEL9K_WORKTREE_MISMATCH_BACKGROUND=196

# Define the worktree segment
function prompt_worktree() {
    local git_dir=$(git rev-parse --git-dir 2>/dev/null) || return

    if [[ "$git_dir" == *"/worktrees/"* ]]; then
        # Extract worktree name from git directory path
        local wt_name=$(basename "$git_dir")

        # Hash the worktree name to get a consistent color index (0-9)
        local hash=$(( $(printf "%s" "$wt_name" | cksum | cut -d' ' -f1) ))
        local color_index=$(( hash % ${#WORKTREE_COLORS[@]} ))

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
        p10k segment -s "COLOR$color_index" -t "⊙ $display"
    fi
}

# Inject into left prompt elements if not already there
if (( ${+POWERLEVEL9K_LEFT_PROMPT_ELEMENTS} )); then
    if [[ ! " ${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[@]} " =~ " worktree " ]]; then
        POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(worktree "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[@]}")
    fi
fi

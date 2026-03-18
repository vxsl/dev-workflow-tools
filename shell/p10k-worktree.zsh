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

# Define the worktree segment
function prompt_worktree() {
    local git_dir=$(git rev-parse --git-dir 2>/dev/null) || return

    if [[ "$git_dir" == *"/worktrees/"* ]]; then
        # Extract worktree name from git directory path
        local wt_name=$(basename "$git_dir")

        # Hash the worktree name to get a consistent color index (0-9)
        local hash=$(( $(printf "%s" "$wt_name" | cksum | cut -d' ' -f1) ))
        local color_index=$(( hash % ${#WORKTREE_COLORS[@]} ))

        # Use state to select color
        p10k segment -s "COLOR$color_index" -t "⊙ WORKTREE: $wt_name"
    fi
}

# Inject into left prompt elements if not already there
if (( ${+POWERLEVEL9K_LEFT_PROMPT_ELEMENTS} )); then
    if [[ ! " ${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[@]} " =~ " worktree " ]]; then
        POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(worktree "${POWERLEVEL9K_LEFT_PROMPT_ELEMENTS[@]}")
    fi
fi

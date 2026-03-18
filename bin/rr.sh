#!/usr/bin/env bash

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$(readlink -f "$0")"
AUTO_CLEAR_SCRIPT="$SCRIPT_DIR/rr-auto-clear.sh"
if [ -f "$SCRIPT_DIR/../.env" ]; then
    source "$SCRIPT_DIR/../.env"
fi

# Configuration
REFLOG_COUNT=50
DISPLAY_COUNT=10
SORT_BY_COMMIT=false
JIRA_DOMAIN="${JIRA_DOMAIN}"
JIRA_PROJECT="${JIRA_PROJECT}"
JIRA_ME="${JIRA_ME:-}"  # Your JIRA username - used to highlight your assigned branches
RR_REMOTE_MAX_AGE_DAYS="${RR_REMOTE_MAX_AGE_DAYS:-90}"  # Max age of remote-only branches to show (0 = no limit)

# Validate required environment variables
if [ -z "$JIRA_DOMAIN" ] || [ -z "$JIRA_PROJECT" ]; then
    echo "╭─────────────────────────────────────────────────────────────╮" >&2
    echo "│  ⚠  Missing Required Configuration                         │" >&2
    echo "├─────────────────────────────────────────────────────────────┤" >&2
    echo "│                                                             │" >&2
    echo "│  JIRA_DOMAIN and JIRA_PROJECT must be set.                 │" >&2
    echo "│                                                             │" >&2
    echo "│  Create a .env file in your project root with:             │" >&2
    echo "│                                                             │" >&2
    echo "│    JIRA_DOMAIN=your-company.atlassian.net                  │" >&2
    echo "│    JIRA_PROJECT=PROJ                                       │" >&2
    echo "│    JIRA_ME=your-username                                   │" >&2
    echo "│                                                             │" >&2
    echo "│  See .env.example for a complete template.                 │" >&2
    echo "│                                                             │" >&2
    echo "╰─────────────────────────────────────────────────────────────╯" >&2
    exit 1
fi

# Cache directory
CACHE_DIR="$HOME/.cache/rr"
WORKTREE_ACCESS_LOG="$CACHE_DIR/worktree_access.log"
JIRA_ASSIGNED_CACHE="$HOME/.jira_assigned_cache"
JIRA_ACTIVE_CACHE="$HOME/.jira_active_cache"

# Pane management configuration - parse RR_PANE_N_* variables
RR_PANE_MGMT_ENABLED="${RR_PANE_MGMT_ENABLED:-false}"
declare -A PANE_IDS PANE_DIRS PANE_COMMANDS PANE_LABELS PANE_INDICATORS PANE_KEYS KEY_TO_PANE_MAP
PANE_COUNT=0

if [ "$RR_PANE_MGMT_ENABLED" = "true" ]; then
    for i in {1..20}; do
        pane_id_var="RR_PANE_${i}_ID"
        pane_id="${!pane_id_var}"

        if [ -n "$pane_id" ]; then
            PANE_IDS[$i]="$pane_id"

            pane_dir_var="RR_PANE_${i}_DIR"
            PANE_DIRS[$i]="${!pane_dir_var:-}"

            pane_cmd_var="RR_PANE_${i}_COMMAND"
            PANE_COMMANDS[$i]="${!pane_cmd_var:-}"

            pane_label_var="RR_PANE_${i}_LABEL"
            PANE_LABELS[$i]="${!pane_label_var:-pane$i}"

            pane_indicator_var="RR_PANE_${i}_INDICATOR"
            PANE_INDICATORS[$i]="${!pane_indicator_var:-●}"

            pane_key_var="RR_PANE_${i}_KEY"
            pane_key="${!pane_key_var:-}"
            if [ -n "$pane_key" ]; then
                PANE_KEYS[$i]="$pane_key"
                KEY_TO_PANE_MAP[$pane_key]=$i
            fi

            PANE_COUNT=$((PANE_COUNT + 1))
        fi
    done
fi

# Ensure we're in a git repository
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Not in a git repository"
    exit 1
fi

# Get git repository root (main worktree, not current worktree)
# Use worktree list to find the main worktree path
GIT_ROOT=$(git worktree list --porcelain | grep -m1 '^worktree ' | cut -d' ' -f2)

TITLE_MAX_LENGTH=40  # Adjust this value to change title length
BRANCH_MAX_LENGTH=23  # Reduced to make room for worktree indicator
STATUS_MAX_LENGTH=14  # Adjust this value to change status length
ASSIGNEE_MAX_LENGTH=15  # Width for assignee column
COMMIT_MAX_LENGTH=26  # Width for commit info column

# Build worktree map: branch -> worktree path
declare -A WORKTREE_MAP
build_worktree_map() {
    local current_wt_path=""
    local current_branch=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^worktree[[:space:]](.+)$ ]]; then
            # Save previous worktree if we have one
            if [[ -n "$current_branch" && -n "$current_wt_path" ]]; then
                WORKTREE_MAP["$current_branch"]="$current_wt_path"
                # Also map eponymous branch so navigation works even with guest branches
                local _epo; _epo=$(get_eponymous_branch "$current_wt_path")
                if [ -n "$_epo" ] && [ "$_epo" != "$current_branch" ] && [ "$current_wt_path" != "$GIT_ROOT" ]; then
                    WORKTREE_MAP["$_epo"]="$current_wt_path"
                fi
            fi
            # Start new worktree
            current_wt_path="${BASH_REMATCH[1]}"
            current_branch=""
        elif [[ "$line" =~ ^branch[[:space:]]refs/heads/(.+)$ ]]; then
            current_branch="${BASH_REMATCH[1]}"
        elif [[ "$line" == "detached" ]]; then
            # Handle detached HEAD (e.g., during rebase)
            # Try to determine the branch name from rebase metadata or worktree path

            # Check for rebase metadata
            if [ -f "$current_wt_path/.git/rebase-merge/head-name" ]; then
                local head_name=$(cat "$current_wt_path/.git/rebase-merge/head-name" 2>/dev/null)
                if [[ "$head_name" =~ refs/heads/(.+)$ ]]; then
                    current_branch="${BASH_REMATCH[1]}"
                fi
            elif [ -f "$current_wt_path/.git/rebase-apply/head-name" ]; then
                local head_name=$(cat "$current_wt_path/.git/rebase-apply/head-name" 2>/dev/null)
                if [[ "$head_name" =~ refs/heads/(.+)$ ]]; then
                    current_branch="${BASH_REMATCH[1]}"
                fi
            fi

            # Fall back to inferring from worktree directory name
            # Pattern: repo.BRANCH-NAME or just BRANCH-NAME
            if [ -z "$current_branch" ] && [ -n "$current_wt_path" ]; then
                local wt_basename=$(basename "$current_wt_path")
                # Try to extract branch name after last dot (e.g., ul.UB-6227 -> UB-6227)
                if [[ "$wt_basename" =~ \.([^.]+)$ ]]; then
                    current_branch="${BASH_REMATCH[1]}"
                # Or use the whole basename if no dot
                else
                    current_branch="$wt_basename"
                fi
            fi
        fi
    done < <(git worktree list --porcelain 2>/dev/null)

    # Don't forget the last worktree
    if [[ -n "$current_branch" && -n "$current_wt_path" ]]; then
        WORKTREE_MAP["$current_branch"]="$current_wt_path"
        # Also map eponymous branch (inferred from path name) so navigation works
        # even when a different branch is checked out in this worktree
        local _epo; _epo=$(get_eponymous_branch "$current_wt_path")
        if [ -n "$_epo" ] && [ "$_epo" != "$current_branch" ] && [ "$current_wt_path" != "$GIT_ROOT" ]; then
            WORKTREE_MAP["$_epo"]="$current_wt_path"
        fi
    fi
}

# Get the eponymous branch name for a worktree path (inferred from directory name)
# e.g. /path/ul.UB-6506 -> UB-6506, /path/my-feature -> my-feature
get_eponymous_branch() {
    local wt_path="$1"
    local wt_basename
    wt_basename=$(basename "$wt_path")
    if [[ "$wt_basename" =~ \.([^.]+)$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$wt_basename"
    fi
}

# Get worktree path for a branch
get_worktree_path() {
    local branch="$1"
    echo "${WORKTREE_MAP[$branch]:-}"
}

# Get the actual git directory for a worktree (resolves .git file to actual gitdir)
get_worktree_gitdir() {
    local wt_path="$1"
    if [ -f "$wt_path/.git" ]; then
        # .git is a file in worktrees - extract gitdir path
        grep '^gitdir:' "$wt_path/.git" 2>/dev/null | cut -d' ' -f2
    elif [ -d "$wt_path/.git" ]; then
        # Main repo - .git is a directory
        echo "$wt_path/.git"
    fi
}

# Record that a worktree was accessed (for navigation tracking)
record_worktree_access() {
    local wt_path="$1"
    local timestamp=$(date +%s)

    # Update or append the access time for this worktree
    # Format: timestamp<TAB>worktree_path
    if [ -f "$WORKTREE_ACCESS_LOG" ]; then
        # Remove old entry for this worktree and append new one
        grep -v "	$wt_path$" "$WORKTREE_ACCESS_LOG" > "$WORKTREE_ACCESS_LOG.tmp" 2>/dev/null || true
        echo -e "$timestamp\t$wt_path" >> "$WORKTREE_ACCESS_LOG.tmp"
        mv "$WORKTREE_ACCESS_LOG.tmp" "$WORKTREE_ACCESS_LOG"
    else
        echo -e "$timestamp\t$wt_path" > "$WORKTREE_ACCESS_LOG"
    fi
}

# Get the last navigation time for a worktree from access log
get_worktree_navigation_time() {
    local wt_path="$1"

    if [ -f "$WORKTREE_ACCESS_LOG" ]; then
        # Find the timestamp for this worktree
        grep "	$wt_path$" "$WORKTREE_ACCESS_LOG" 2>/dev/null | tail -1 | cut -f1
    fi
}

# Navigate to a worktree and record the access
navigate_to_worktree() {
    local wt_path="$1"
    record_worktree_access "$wt_path"
    # If stdout was redirected to tty (interactive prompt flows), write to the
    # saved fd so the shell wrapper can still receive the RR_CD directive.
    if [ -n "$rr_stdout" ]; then
        echo "RR_CD:$wt_path" >&"$rr_stdout"
    else
        echo "RR_CD:$wt_path"
    fi
}

# ============================================================================
# Pane Management Functions
# ============================================================================

# Get the current working directory of a tmux pane
get_pane_current_dir() {
    local pane_id="$1"
    if tmux_pane_exists "$pane_id"; then
        local numeric_id=$(tmux display-message -p -t "$pane_id" '#{pane_id}' 2>/dev/null)

        # Try to get path from child tmux session (for nested tmux)
        # Child sessions are named like "%10_child" where %10 is the parent pane ID
        local child_path=$(tmux display-message -p -t "${numeric_id}_child:" '#{pane_current_path}' 2>/dev/null)

        if [ -n "$child_path" ]; then
            echo "$child_path"
        else
            # No child session, get path from the pane directly
            tmux display-message -p -t "$pane_id" '#{pane_current_path}' 2>/dev/null || echo ""
        fi
    else
        echo ""
    fi
}

# Trim path to show only meaningful part
trim_path() {
    local path="$1"

    # If empty, return empty
    [ -z "$path" ] && echo "" && return

    # Try to find worktree base (parent of git root)
    local worktree_base=""
    if [ -n "$GIT_ROOT" ]; then
        # Use full path to dirname to avoid any potential conflicts
        worktree_base=$(/usr/bin/dirname "$GIT_ROOT")

        # If path starts with worktree base, trim that part
        if [[ "$path" == "$worktree_base/"* ]]; then
            path="${path#$worktree_base/}"
        # Otherwise if path starts with git root, trim that part
        elif [[ "$path" == "$GIT_ROOT/"* ]]; then
            path="${path#$GIT_ROOT/}"
        fi
    fi

    # Show only the first component (worktree name)
    # This is the most distinguishing information
    path=$(echo "$path" | cut -d'/' -f1)

    # If empty, show "."
    [ -z "$path" ] && path="."

    echo "$path"
}

# Check if a tmux pane exists
tmux_pane_exists() {
    local pane_id="$1"

    # Check if tmux is available
    if ! command -v tmux &>/dev/null; then
        echo "✗ tmux is not installed" >&2
        return 1
    fi

    tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index}" 2>/dev/null | grep -q "^${pane_id}$"
}

# Send commands to a tmux pane to switch to a new worktree
switch_pane_target() {
    local pane_type="$1"
    local pane_id="$2"
    local wt_path="$3"
    local subdir="$4"       # Optional subdirectory within worktree
    local command="$5"

    if [ -z "$pane_id" ] || [ -z "$wt_path" ]; then
        echo "✗ Pane ID or worktree path is empty" >&2
        return 1
    fi

    # Check if tmux pane exists
    if ! tmux_pane_exists "$pane_id"; then
        echo "✗ Tmux pane '$pane_id' not found" >&2
        echo "  Make sure the tmux session is running" >&2
        return 1
    fi

    # Determine target directory
    local target_dir="$wt_path"
    if [ -n "$subdir" ]; then
        target_dir="$wt_path/$subdir"
        if [ ! -d "$target_dir" ]; then
            echo "✗ Subdirectory '$subdir' does not exist in worktree" >&2
            return 1
        fi
    fi

    # Kill current process in the pane (send Ctrl-C)
    tmux send-keys -t "$pane_id" C-c 2>/dev/null || true
    sleep 0.5

    # Clear the pane
    tmux send-keys -t "$pane_id" "clear" C-m 2>/dev/null || true
    sleep 0.2

    # Change directory to target with error checking
    tmux send-keys -t "$pane_id" "cd \"$target_dir\" 2>/dev/null || echo '✗ Failed to cd to $target_dir'" C-m 2>/dev/null || true
    sleep 0.3

    # Verify the directory change worked by checking PWD
    tmux send-keys -t "$pane_id" "pwd" C-m 2>/dev/null || true
    sleep 0.1

    # Run the command if provided
    if [ -n "$command" ]; then
        tmux send-keys -t "$pane_id" "$command" C-m 2>/dev/null || true
    fi

    local display_path="$wt_path"
    [ -n "$subdir" ] && display_path="$wt_path/$subdir"
    echo "✓ Switched $pane_type to: $display_path" >&2
}

# Copy files to a new worktree, respecting WT_FILES_TO_COPY, WORKTREE_COPY_EXCLUDE,
# VSCODE_WORKSPACE_SETTINGS, and POST_WORKTREE_HOOK env vars
copy_worktree_files() {
    local src_root="$1"
    local dst_root="$2"

    # Determine files to copy: use WT_FILES_TO_COPY env var or fall back to defaults
    local files_to_copy_str="${WT_FILES_TO_COPY:-client/web/.env client/web/ulweb/pkg client/web/.cursor client/web/.vscode}"

    local copied_count=0
    for file in $files_to_copy_str; do
        local src="$src_root/$file"
        local dst="$dst_root/$file"
        if [ -e "$src" ] && [ ! -e "$dst" ]; then
            if [ -n "$WORKTREE_COPY_EXCLUDE" ] && [ -d "$src" ]; then
                local exclude_args=""
                for pattern in $WORKTREE_COPY_EXCLUDE; do
                    exclude_args="$exclude_args --exclude=$pattern"
                done
                rsync -a $exclude_args "$src/" "$dst/" 2>/dev/null && ((copied_count++))
            else
                cp -r "$src" "$dst" 2>/dev/null && ((copied_count++))
            fi
        fi
    done

    if [ $copied_count -gt 0 ]; then
        echo "✓ Copied $copied_count file(s) to worktree" >&2
    fi

    # Inject VS Code workspace settings (if configured)
    if [ -n "$VSCODE_WORKSPACE_SETTINGS" ]; then
        local vscode_dir="$dst_root/client/web/.vscode"
        local vscode_settings="$vscode_dir/settings.json"
        mkdir -p "$vscode_dir"
        if [ -f "$vscode_settings" ]; then
            python3 -c "
import json
new_settings = json.loads('$VSCODE_WORKSPACE_SETTINGS')
with open('$vscode_settings', 'r') as f:
    settings = json.load(f)
settings.update(new_settings)
with open('$vscode_settings', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
" 2>/dev/null && echo "✓ Merged VS Code workspace settings" >&2
        else
            echo "$VSCODE_WORKSPACE_SETTINGS" | python3 -c "
import json, sys
settings = json.load(sys.stdin)
print(json.dumps(settings, indent=2))
" 2>/dev/null > "$vscode_settings" && echo "✓ Created VS Code workspace settings" >&2
        fi
    fi

    # Run post-worktree hook (if configured)
    if [ -n "$POST_WORKTREE_HOOK" ] && [ -x "$POST_WORKTREE_HOOK" ]; then
        echo "Running post-worktree hook: $POST_WORKTREE_HOOK" >&2
        "$POST_WORKTREE_HOOK" "$dst_root" >&2
    fi
}

# Create a worktree for a branch
# Returns: 0 on success, 1 on failure
create_worktree() {
    local branch="$1"

    # Check if branch is already checked out somewhere
    local existing_wt=$(git worktree list --porcelain | grep -B2 "^branch refs/heads/$branch$" | grep "^worktree " | cut -d' ' -f2)
    if [ -n "$existing_wt" ]; then
        echo "✓ Branch '$branch' already has a worktree at: $existing_wt" >&2
        return 0
    fi

    # Create worktree
    local repo_name=$(basename "$GIT_ROOT")

    # Try to get JIRA title and include it in the path
    local ticket=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | head -1)
    local wt_name="$branch"
    if [ -n "$ticket" ]; then
        local jira_title=$(get_jira_title "$ticket")
        if [ -n "$jira_title" ]; then
            local sanitized_title=$(sanitize_title_for_path "$jira_title" 40)
            wt_name="$branch-$sanitized_title"
        fi
    fi

    local wt_path="$GIT_ROOT/../$repo_name.$wt_name"

    echo "Creating worktree for branch '$branch' at '$wt_path'..." >&2
    if git worktree add "$wt_path" "$branch" 2>&1 >&2; then
        echo "✓ Worktree created successfully!" >&2

        copy_worktree_files "$GIT_ROOT" "$wt_path"

        return 0
    else
        echo "✗ Failed to create worktree" >&2
        return 1
    fi
}

# Switch a pane to a branch, creating worktree if needed
# Returns: 0 on success, 1 on failure, 2 if user cancelled
switch_pane_to_branch() {
    local pane_num="$1"
    local branch="$2"

    # Strip REMOTE: prefix if present
    local is_remote=false
    if [[ "$branch" == REMOTE:* ]]; then
        branch="${branch#REMOTE:}"
        is_remote=true
    fi

    # Get pane configuration
    local pane_id="${PANE_IDS[$pane_num]}"
    local pane_dir="${PANE_DIRS[$pane_num]}"
    local pane_cmd="${PANE_COMMANDS[$pane_num]}"
    local pane_label="${PANE_LABELS[$pane_num]}"

    # Find worktree path (use pre-built map instead of slow git call)
    local wt_path=$(get_worktree_path "$branch")

    if [ -z "$wt_path" ]; then
        # No worktree - offer to create one
        echo "" >&2
        echo "Branch '$branch' does not have a worktree yet." >&2
        echo "" >&2

        # Use fzf to prompt
        local opt1="● Create worktree for '$branch' and switch pane"
        local opt2="○ Cancel"

        local choice=$(printf '%s\n%s\n' "$opt1" "$opt2" | fzf --ansi --height=5 --reverse --header="Switch $pane_label pane to '$branch'?" --header-first 2>/dev/tty)

        if echo "$choice" | grep -q "Create worktree"; then
            # Create local tracking branch first if this is a remote-only branch
            if [ "$is_remote" = true ] && ! git show-ref --verify --quiet "refs/heads/$branch"; then
                echo "Creating local branch '$branch' tracking 'origin/$branch'..." >&2
                git branch "$branch" "origin/$branch" 2>&1 || {
                    echo "✗ Failed to create local tracking branch" >&2
                    return 1
                }
            fi
            # Create worktree
            echo "Creating worktree for '$branch'..." >&2
            if create_worktree "$branch"; then
                # Get the newly created worktree path
                wt_path=$(git worktree list --porcelain | grep -B2 "^branch refs/heads/$branch$" | grep "^worktree " | cut -d' ' -f2)

                if [ -z "$wt_path" ]; then
                    echo "✗ Failed to find worktree after creation" >&2
                    return 1
                fi
            else
                echo "✗ Failed to create worktree" >&2
                return 1
            fi
        else
            return 2  # User cancelled
        fi
    fi

    # Switch the pane
    echo "Switching $pane_label to: $wt_path" >&2
    if switch_pane_target "pane_$pane_num" "$pane_id" "$wt_path" "$pane_dir" "$pane_cmd"; then
        return 0
    else
        return 1
    fi
}

# Smart git switch that handles worktree conflicts gracefully
# Returns: 0 on success, 1 on failure, 2 if worktree exists and RR_CD was output
smart_git_switch() {
    local branch="$1"
    local create_flag="$2"  # Optional: "-c" to create branch
    local tracking_branch="$3"  # Optional: branch to track (e.g., "origin/branch")

    # Try git switch
    local switch_output
    local switch_exit_code

    if [ -n "$create_flag" ] && [ -n "$tracking_branch" ]; then
        switch_output=$(git switch "$create_flag" "$branch" "$tracking_branch" 2>&1)
    else
        switch_output=$(git switch "$branch" 2>&1)
    fi
    switch_exit_code=$?

    # If successful, return
    if [ $switch_exit_code -eq 0 ]; then
        return 0
    fi

    # Check if error is about worktree conflict
    if echo "$switch_output" | grep -q "already used by worktree at"; then
        # Extract worktree path from error message
        # Error format: "fatal: 'branch' is already used by worktree at '/path/to/worktree'"
        local wt_path=$(echo "$switch_output" | grep -oP "already used by worktree at '\K[^']+")

        if [ -n "$wt_path" ] && [ -d "$wt_path" ]; then
            echo "Branch '$branch' is already checked out in worktree at: $wt_path" >&2
            echo "Switching to existing worktree..." >&2
            navigate_to_worktree "$wt_path"
            return 2  # Special return code to indicate RR_CD was output
        fi
    fi

    # Otherwise, show the original error and fail
    echo "$switch_output" >&2
    return 1
}

# Get last access time for a worktree

# Truncate string with ellipsis
truncate() {
    local str=$1
    local max_length=$2
    if [ ${#str} -gt $max_length ]; then
        echo "${str:0:$((max_length-3))}..."
    else
        echo "$str"
    fi
}

# Convert timestamp to human-readable relative time
# Input: "checked:1770827880" or "updated:1770827880"
# Output: "checked: 8 hours ago" or "updated: 8 hours ago"
convert_timestamp_to_relative() {
    local time_field="$1"

    # Parse prefix and timestamp
    if [[ "$time_field" =~ ^(checked|updated):([0-9]+)$ ]]; then
        local prefix="${BASH_REMATCH[1]}"
        local timestamp="${BASH_REMATCH[2]}"

        local now_sec=$(date +%s)
        local diff_sec=$((now_sec - timestamp))

        local relative=""
        if [ $diff_sec -lt 60 ]; then
            relative="seconds ago"
        elif [ $diff_sec -lt 3600 ]; then
            local minutes=$((diff_sec / 60))
            if [ $minutes -eq 1 ]; then
                relative="1 minute ago"
            else
                relative="$minutes minutes ago"
            fi
        elif [ $diff_sec -lt 86400 ]; then
            local hours=$((diff_sec / 3600))
            if [ $hours -eq 1 ]; then
                relative="1 hour ago"
            else
                relative="$hours hours ago"
            fi
        elif [ $diff_sec -lt 2592000 ]; then
            local days=$((diff_sec / 86400))
            if [ $days -eq 1 ]; then
                relative="1 day ago"
            else
                relative="$days days ago"
            fi
        else
            local months=$((diff_sec / 2592000))
            if [ $months -eq 1 ]; then
                relative="1 month ago"
            else
                relative="$months months ago"
            fi
        fi

        echo "${prefix}: ${relative}"
    else
        # Already in human-readable format or invalid - return as-is
        echo "$time_field"
    fi
}

# Function to show help page
show_help() {
    clear
    echo -e "\033[38;5;141m┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[38;5;141m┃\033[0m            \033[1mRR - Recent Branches Helper\033[0m            \033[38;5;141m┃\033[0m"
    echo -e "\033[38;5;141m┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""
    echo -e "\033[1;36mNAVIGATION\033[0m"
    echo -e "  \033[32m↑/↓ j/k\033[0m      Navigate     \033[32mEnter\033[0m     Switch/navigate to worktree"
    echo -e "  \033[32mCtrl-D/U\033[0m     Scroll        \033[32mEsc/^C\033[0m    Exit"
    echo ""
    echo -e "\033[1;36mSEARCH & VIEW\033[0m"
    echo -e "  \033[32mType\033[0m         Filter by name/status/author"
    echo -e "  \033[32mCtrl-L\033[0m       Load more branches"
    echo -e "  \033[32mCtrl-R\033[0m       Refresh (shows summary for ~2.5s, auto-clears)"
    echo ""
    echo -e "\033[1;36mWORKTREE MANAGEMENT\033[0m"
    echo -e "  \033[33mF2\033[0m           Create worktree for branch"
    echo -e "  \033[33mF3\033[0m           Create NEW branch + worktree"
    echo -e "  \033[33mF8\033[0m           Delete worktree"
    echo ""

    # Add pane management help if enabled
    if [ "$RR_PANE_MGMT_ENABLED" = "true" ] && [ "$PANE_COUNT" -gt 0 ]; then
        echo -e "\033[1;36mTMUX PANE MANAGEMENT\033[0m"
        for i in "${!PANE_IDS[@]}"; do
            local key="${PANE_KEYS[$i]}"
            local label="${PANE_LABELS[$i]}"
            local indicator="${PANE_INDICATORS[$i]}"
            [ -n "$key" ] && echo -e "  \033[33m${key^^}\033[0m           Switch pane: $label  $indicator"
        done
        echo -e "  \033[33mF6\033[0m           Switch ALL panes to selected branch"
        echo -e "  \033[33mAlt-Enter\033[0m    Switch branch + ALL panes at once"
        echo -e "  \033[33mF7\033[0m           Switch ALL panes to CURRENT worktree/directory"
        echo ""
    fi

    echo -e "\033[1;36mVISUAL INDICATORS\033[0m"
    echo -e "  \033[38;5;141m★\033[0m Your branch   \033[38;5;244m·\033[0m Variant   \033[38;5;220m⊙\033[0m   Worktree (clean)   \033[38;5;214m⊙ !\033[0m Worktree (dirty)"
    echo -e "  \033[38;5;71m+\033[0m Unstarted ticket (no branch yet)   \033[38;5;67m↑\033[0m Remote-only branch (no local checkout)"
    if [ "$RR_PANE_MGMT_ENABLED" = "true" ] && [ "$PANE_COUNT" -gt 0 ]; then
        echo -n "  "
        for i in "${!PANE_IDS[@]}"; do
            echo -n "${PANE_INDICATORS[$i]} ${PANE_LABELS[$i]}  "
        done
        echo ""
    fi
    echo ""
    echo -e "\033[2mPress\033[0m \033[1mq\033[0m\033[2m, \033[0m\033[1mEsc\033[0m\033[2m, or\033[0m \033[1mEnter\033[0m \033[2mto close\033[0m"

    # Wait for specific keys to close
    while true; do
        read -rsn1 key
        case "$key" in
            q|$'\e'|'') break ;;  # q, Esc, or Enter
        esac
    done
}

# Parse command line arguments
FORCE_REFRESH=false
GENERATE_MORE_MODE=false
FULL_HEIGHT=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -c|--commit-sort) SORT_BY_COMMIT=true ;;
        -n|--number) REFLOG_COUNT="$2"; shift ;;
        -r|--refresh) FORCE_REFRESH=true ;;
        -f|--full) FULL_HEIGHT=true ;;
        -m|--me) JIRA_ME="$2"; shift ;;
        --show-help) show_help; exit 0 ;;
        --reload-refresh)
            # Refresh cache and output data (for fzf reload)
            # Save old cache snapshots for delta calculation
            TEMP_DIR=$(mktemp -d)
            [ -f ~/.jira_cache ] && cp ~/.jira_cache "$TEMP_DIR/old_jira.cache"
            [ -f ~/.jira_status_cache ] && cp ~/.jira_status_cache "$TEMP_DIR/old_status.cache"
            [ -f ~/.jira_assignee_cache ] && cp ~/.jira_assignee_cache "$TEMP_DIR/old_assignee.cache"
            [ -f "$CACHE_DIR/branch_list_50.cache" ] && cp "$CACHE_DIR/branch_list_50.cache" "$TEMP_DIR/old_branches.cache"

            # Delete all caches to force full refresh
            rm -f ~/.jira_cache ~/.jira_status_cache ~/.jira_assignee_cache
            rm -f "$JIRA_ASSIGNED_CACHE" "$JIRA_ACTIVE_CACHE"
            rm -f "$CACHE_DIR"/branch_list_*.cache "$CACHE_DIR"/reflog_*.cache

            FORCE_REFRESH=true
            GENERATE_MORE_MODE=true
            SHOW_REFRESH_SUMMARY=true

            # Export temp dir for use in summary
            export REFRESH_TEMP_DIR="$TEMP_DIR"
            ;;
        --reload-normal)
            # Just output normal data (for clearing refresh summary)
            GENERATE_MORE_MODE=true
            ;;
        --generate-more) 
            # Special mode for fzf reload - increase reflog count to fetch more branches
            shift
            CURRENT_COUNT="$1"
            if [ -z "$CURRENT_COUNT" ]; then
                CURRENT_COUNT=$REFLOG_COUNT
            fi
            
            # Double the reflog count to fetch more branches
            REFLOG_COUNT=$((CURRENT_COUNT * 2))
            GENERATE_MORE_MODE=true
            ;;
        --process-action)
            # Process an action immediately (for background execution from fzf)
            shift
            ACTION_STRING="$1"
            PROCESS_ACTION_MODE=true
            ;;
        *) echo "Unknown parameter: $1";
           echo "Usage: $0 [-c|--commit-sort] [-n|--number LINES] [-r|--refresh] [-m|--me NAME]"
           echo "  -c, --commit-sort    Sort by commit date instead of checkout time"
           echo "  -n, --number LINES   Number of reflog entries to process (default: 50)"
           echo "  -r, --refresh        Force refresh cache"
           echo "  -f, --full           Use full terminal height"
           echo "  -m, --me NAME        Your JIRA display name to highlight your assigned tickets"
           exit 1 ;;
    esac
    shift
done

# Set cache files based on final REFLOG_COUNT value
CACHE_FILE="$CACHE_DIR/branch_list_${REFLOG_COUNT}.cache"
REFLOG_CACHE="$CACHE_DIR/reflog_${REFLOG_COUNT}.cache"

# Generate TSV rows for all non-main worktrees instantly (no reflog parsing needed).
# Outputs rows for the eponymous branch of each worktree; if a different branch is
# currently checked out, the wt_indicator is set to "WT_MISMATCH:<actual_branch>".
# Writes eponymous branch names to claimed_file so generate_branch_data can skip them.
generate_worktree_data() {
    local claimed_file="${1:-}"
    local main_wt="$GIT_ROOT"
    local current_wt="" current_actual_branch="" current_is_bare=false

    _emit_worktree_data_row() {
        local wt_path="$1"
        local actual_branch="$2"

        local eponymous_branch
        eponymous_branch=$(get_eponymous_branch "$wt_path")

        # JIRA data from in-memory cache (instant)
        local ticket
        ticket=$(echo "$eponymous_branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | head -1)
        local title="<EMPTY>" jira_status="<EMPTY>" jira_assignee="<UNASSIGNED>"
        if [ -n "$ticket" ]; then
            title="${JIRA_TITLE_CACHE[$ticket]:-<EMPTY>}"
            jira_status="${JIRA_STATUS_CACHE[$ticket]:-<EMPTY>}"
            jira_assignee="${JIRA_ASSIGNEE_CACHE[$ticket]:-<UNASSIGNED>}"
        fi

        # Dirty status
        local wt_status="CLEAN"
        if ! git -C "$wt_path" diff --quiet HEAD 2>/dev/null || \
           ! git -C "$wt_path" diff --quiet --cached 2>/dev/null; then
            wt_status="DIRTY"
        fi

        # Commit info + author + timestamp in one git call (%cr = human-readable relative time)
        local log_line
        log_line=$(git -C "$wt_path" log -1 --format="%ct|%cr|%an" 2>/dev/null)
        local commit_time="${log_line%%|*}"
        local _rest="${log_line#*|}"
        local commit_relative="${_rest%%|*}"
        local author="${_rest#*|}"
        author="${author:0:15}"

        # Navigation timestamp (from access log) takes priority over commit time
        local nav_time
        nav_time=$(get_worktree_navigation_time "$wt_path")
        local time_info
        if [ -n "$nav_time" ]; then
            time_info="checked:$nav_time"
        elif [ -n "$commit_time" ]; then
            time_info="checked:$commit_time"
        else
            time_info=""
        fi

        # Mismatch indicator
        local wt_indicator="WT"
        if [ -n "$actual_branch" ] && [ "$actual_branch" != "$eponymous_branch" ]; then
            wt_indicator="WT_MISMATCH:$actual_branch"
        fi

        local truncated_branch
        truncated_branch=$(truncate "$eponymous_branch" $BRANCH_MAX_LENGTH)

        # Extract sort timestamp from time_info (checked:TIMESTAMP format)
        local sort_ts=0
        [[ "$time_info" =~ :([0-9]+)$ ]] && sort_ts="${BASH_REMATCH[1]}"

        local _row
        _row=$(printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
            "$truncated_branch" "$title" "$jira_status" "$author" \
            "$time_info" "committed: ${commit_relative:-unknown}" \
            "$eponymous_branch" "$jira_assignee" "$wt_indicator" "$wt_path" "$wt_status")

        # Accumulate with sort key prefix; output is sorted at the end
        if [ -z "$_collected_rows" ]; then
            _collected_rows="${sort_ts}"$'\t'"${_row}"
        else
            _collected_rows="${_collected_rows}"$'\n'"${sort_ts}"$'\t'"${_row}"
        fi

        # Write to claimed file immediately (order doesn't matter for dedup)
        [ -n "$claimed_file" ] && echo "$eponymous_branch" >> "$claimed_file"
    }

    local _collected_rows=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^worktree[[:space:]](.+)$ ]]; then
            if [ -n "$current_wt" ] && [ "$current_wt" != "$main_wt" ] && [ "$current_is_bare" = false ]; then
                _emit_worktree_data_row "$current_wt" "$current_actual_branch"
            fi
            current_wt="${BASH_REMATCH[1]}"
            current_actual_branch=""
            current_is_bare=false
        elif [[ "$line" =~ ^branch[[:space:]]refs/heads/(.+)$ ]]; then
            current_actual_branch="${BASH_REMATCH[1]}"
        elif [[ "$line" == "bare" ]]; then
            current_is_bare=true
        fi
    done < <(git worktree list --porcelain 2>/dev/null)

    # Emit last entry
    if [ -n "$current_wt" ] && [ "$current_wt" != "$main_wt" ] && [ "$current_is_bare" = false ]; then
        _emit_worktree_data_row "$current_wt" "$current_actual_branch"
    fi

    # Output rows sorted by timestamp descending (most recently accessed first)
    [ -n "$_collected_rows" ] && echo "$_collected_rows" | sort -t$'\t' -k1,1nr | cut -f2-

    unset -f _emit_worktree_data_row
}

# Function to generate branch data for a specific count
generate_branch_data() {
    local count="$1"
    local claimed_file="${2:-}"
    local temp_cache_file
    local temp_reflog_cache

    # Load claimed branches (already output by generate_worktree_data) into a set
    declare -A _wt_claimed=()
    if [ -n "$claimed_file" ] && [ -s "$claimed_file" ]; then
        while IFS= read -r _cb; do
            _wt_claimed["$_cb"]=1
        done < "$claimed_file"
    fi

    temp_cache_file="$CACHE_DIR/branch_list_${count}.cache"
    temp_reflog_cache="$CACHE_DIR/reflog_${count}.cache"
    
    # Check if we have valid cache for this count
    if [[ "$FORCE_REFRESH" == false ]] && [[ -f "$temp_cache_file" ]] && [[ -s "$temp_cache_file" ]] && [[ -f "$temp_reflog_cache" ]]; then
        local cache_mtime=$(stat -c %Y "$temp_cache_file" 2>/dev/null || stat -f %m "$temp_cache_file" 2>/dev/null)

        # Check if access log changed (always check this, even for fresh cache)
        local access_log_changed=false
        if [ -f "$WORKTREE_ACCESS_LOG" ] && [ -n "$cache_mtime" ]; then
            local log_mtime=$(stat -c %Y "$WORKTREE_ACCESS_LOG" 2>/dev/null || stat -f %m "$WORKTREE_ACCESS_LOG" 2>/dev/null)
            if [ -n "$log_mtime" ] && [ "$log_mtime" -gt "$cache_mtime" ]; then
                access_log_changed=true
            fi
        fi

        # Fast path: if cache is recent AND (access log unchanged OR cache very fresh)
        if [ -n "$cache_mtime" ]; then
            local now=$(date +%s)
            local cache_age=$((now - cache_mtime))

            # Use cache if:
            # 1. Access log hasn't changed and cache < 60 seconds, OR
            # 2. Cache is very fresh (< 2 seconds) regardless of access log
            if [ "$access_log_changed" = false ] && [ "$cache_age" -lt 60 ]; then
                # Nothing changed - use cache
                if [ ${#_wt_claimed[@]} -gt 0 ]; then
                    awk -F'\t' 'NR==FNR{skip[$1]=1; next} !skip[$7]' "$claimed_file" "$temp_cache_file"
                else
                    cat "$temp_cache_file"
                fi
                return
            elif [ "$cache_age" -lt 2 ]; then
                # Cache is very fresh - use it even if access log changed
                # (handles rapid successive rr calls during navigation)
                if [ ${#_wt_claimed[@]} -gt 0 ]; then
                    awk -F'\t' 'NR==FNR{skip[$1]=1; next} !skip[$7]' "$claimed_file" "$temp_cache_file"
                else
                    cat "$temp_cache_file"
                fi
                return
            fi
        fi

        # Smart check: only invalidate if branches changed
        # Get list of all branch refs with their commit hashes
        local current_branches_hash
        current_branches_hash=$(git for-each-ref --format='%(refname) %(objectname)' refs/heads/ | sort | sha256sum | cut -d' ' -f1)

        local cached_branches_hash
        cached_branches_hash=$(cat "$temp_reflog_cache" 2>/dev/null)

        if [[ "$current_branches_hash" == "$cached_branches_hash" ]]; then
            if [ "$access_log_changed" = false ]; then
                # Branches and access log both unchanged - use cache
                if [ ${#_wt_claimed[@]} -gt 0 ]; then
                    awk -F'\t' 'NR==FNR{skip[$1]=1; next} !skip[$7]' "$claimed_file" "$temp_cache_file"
                else
                    cat "$temp_cache_file"
                fi
                return
            else
                # Access log changed, branches haven't - smart update timestamps only
                # This is fast because we skip JIRA fetches
                local updated_cache=""
                while IFS=$'\t' read -r branch title status author time_info commit_info full_branch assignee wt_indicator wt_path wt_status; do
                    # Skip branches claimed by generate_worktree_data
                    [ -n "${_wt_claimed[$full_branch]+x}" ] && continue
                    local sort_timestamp=0

                    # Extract existing timestamp from time_info for sorting
                    if [[ "$time_info" =~ :([0-9]+)$ ]]; then
                        sort_timestamp="${BASH_REMATCH[1]}"
                    fi

                    # Recalculate timestamp for worktrees
                    if [ "$wt_indicator" = "WT" ] && [ -n "$wt_path" ]; then
                        local wt_timestamp=0

                        # If we're currently in this worktree, use NOW
                        if [ "$PWD" = "$wt_path" ] || [[ "$PWD" == "$wt_path"/* ]]; then
                            wt_timestamp=$(date +%s)
                        else
                            # Check navigation log
                            local nav_time=$(get_worktree_navigation_time "$wt_path")
                            [ -n "$nav_time" ] && wt_timestamp=$nav_time

                            # Check HEAD mtime
                            local gitdir=$(get_worktree_gitdir "$wt_path")
                            if [ -n "$gitdir" ] && [ -f "$gitdir/HEAD" ]; then
                                local head_mtime=$(stat -c %Y "$gitdir/HEAD" 2>/dev/null || stat -f %m "$gitdir/HEAD" 2>/dev/null)
                                [ -n "$head_mtime" ] && [ "$head_mtime" -gt "$wt_timestamp" ] && wt_timestamp=$head_mtime
                            fi
                        fi

                        if [ "$wt_timestamp" -gt 0 ]; then
                            time_info="checked:$wt_timestamp"
                            sort_timestamp="$wt_timestamp"
                        fi
                    fi

                    # Prepend sort_timestamp for sorting
                    local line=$(printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                        "$sort_timestamp" "$branch" "$title" "$status" "$author" "$time_info" "$commit_info" "$full_branch" "$assignee" "$wt_indicator" "$wt_path" "$wt_status")
                    if [ -z "$updated_cache" ]; then
                        updated_cache="$line"
                    else
                        updated_cache="${updated_cache}"$'\n'"${line}"
                    fi
                done < "$temp_cache_file"

                # Sort by timestamp and strip it
                updated_cache=$(echo "$updated_cache" | sort -t$'\t' -k1,1nr | cut -f2-)

                # Write updated cache and return it
                echo "$updated_cache" > "$temp_cache_file"
                echo "$updated_cache"
                return
            fi
        fi
        # Branches changed - full regenerate
    fi
    
    # Generate fresh data
    if [ "$SORT_BY_COMMIT" = true ]; then
        branch_list=$(git for-each-ref --sort='-committerdate' refs/heads/ \
            --format='%(refname:short)%09%(committerdate:unix)%09%(committerdate:relative)' | head -n "$count")
    else
        # Search through more reflog entries to find the requested number of unique branches
        local search_count=$(( count * 10 ))
        if [ $search_count -lt 5000 ]; then
            search_count=5000
        fi

        # If in a worktree, use the main repo's reflog for better history
        local reflog_git_dir=""
        if git rev-parse --git-common-dir >/dev/null 2>&1; then
            local common_dir=$(git rev-parse --git-common-dir)
            if [[ "$common_dir" != ".git" ]]; then
                # We're in a worktree, use the main repo's reflog
                reflog_git_dir="--git-dir=$common_dir"
            fi
        fi

        # Get both relative time and unix timestamp for each checkout
        branch_list=$(
            paste -d$'\t' \
                <(git $reflog_git_dir reflog -n "$search_count" --date=unix | grep 'checkout: moving' | sed -E 's/^[a-f0-9]+ HEAD@\{([0-9]+)\}: checkout: moving from .* to ([^ ]+).*$/\2\t\1/') \
                <(git $reflog_git_dir reflog -n "$search_count" --date=relative | grep 'checkout: moving' | sed -E 's/^[a-f0-9]+ HEAD@\{([^}]+)\}: checkout: moving from .* to ([^ ]+).*$/\1/') |
            awk -F'\t' '!seen[$1]++ { print $1"\t"$2"\t"$3 }' |
            head -n "$count"
        )

        # If we got very few branches from reflog, supplement with all branches by commit date
        local reflog_count=$(echo "$branch_list" | grep -c '^' || echo 0)
        if [ "$reflog_count" -lt 3 ]; then
            # Get all branches sorted by commit date and merge with reflog results
            local all_branches=$(git for-each-ref --sort='-committerdate' refs/heads/ \
                --format='%(refname:short)%09%(committerdate:unix)%09%(committerdate:relative)')
            # Combine: reflog branches first (preserving order), then fill with commit-sorted branches
            branch_list=$(echo -e "$branch_list\n$all_branches" | awk '!seen[$1]++ { print $0 }' | head -n "$count")
        fi

        # Always ensure all worktree branches are included (important for branches in detached HEAD state during rebase)
        local worktree_branches=""
        for wt_branch in "${!WORKTREE_MAP[@]}"; do
            # Add worktree branch with unix timestamp and relative time if not already in list
            if ! echo "$branch_list" | grep -q "^$wt_branch	"; then
                # Get unix timestamp from most recent access (navigation or git work)
                local wt_path="${WORKTREE_MAP[$wt_branch]}"
                local wt_unix_time=0

                # If we're currently in this worktree, use NOW
                if [ "$PWD" = "$wt_path" ] || [[ "$PWD" == "$wt_path"/* ]]; then
                    wt_unix_time=$(date +%s)
                else
                    # Check navigation log
                    local nav_time=$(get_worktree_navigation_time "$wt_path")
                    [ -n "$nav_time" ] && wt_unix_time=$nav_time

                    # Check HEAD mtime (git operations)
                    local gitdir=$(get_worktree_gitdir "$wt_path")
                    if [ -n "$gitdir" ] && [ -f "$gitdir/HEAD" ]; then
                        local head_mtime=$(stat -c %Y "$gitdir/HEAD" 2>/dev/null || stat -f %m "$gitdir/HEAD" 2>/dev/null)
                        [ -n "$head_mtime" ] && [ "$head_mtime" -gt "$wt_unix_time" ] && wt_unix_time=$head_mtime
                    fi

                    # Fallback to commit time if no access time available
                    if [ "$wt_unix_time" -eq 0 ]; then
                        wt_unix_time=$(git log -1 --pretty=format:'%ct' "refs/heads/$wt_branch" 2>/dev/null || echo "0")
                    fi
                fi

                local wt_time=$(git log -1 --pretty=format:'%cr' "refs/heads/$wt_branch" 2>/dev/null || echo "unknown")
                worktree_branches="${worktree_branches}${wt_branch}	${wt_unix_time}	${wt_time}"$'\n'
            fi
        done
        if [ -n "$worktree_branches" ]; then
            branch_list=$(echo -e "$branch_list\n$worktree_branches" | grep -v '^$')
        fi
    fi
    
    # First pass: collect all tickets to fetch JIRA data in batch
    declare -A tickets_to_fetch
    while read -r branch rest; do
        local ref_path="refs/heads/$branch"

        # Skip entries that aren't actual branches
        if ! git show-ref --verify --quiet "$ref_path"; then
            continue
        fi

        # Extract JIRA ticket
        ticket=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]')
        if [ -n "$ticket" ]; then
            tickets_to_fetch["$ticket"]=1
        fi
    done <<< "$branch_list"
    
    # Batch fetch JIRA data for all tickets that aren't cached
    local _fetch_pids=()
    for ticket in "${!tickets_to_fetch[@]}"; do
        # Check if already cached
        if ! grep -q "^$ticket:" ~/.jira_cache 2>/dev/null || \
           ! grep -q "^$ticket:" ~/.jira_status_cache 2>/dev/null || \
           ! grep -q "^$ticket:" ~/.jira_assignee_cache 2>/dev/null; then
            # Fetch in background to parallelize
            (
                response=$(curl -s --max-time 8 -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
                    "https://${JIRA_DOMAIN}/rest/api/2/issue/${ticket}" \
                    -H "Content-Type: application/json" 2>/dev/null)

                if [ $? -eq 0 ] && [ -n "$response" ]; then
                    title=$(echo "$response" | jq -r '.fields.summary // empty' 2>/dev/null)
                    status=$(echo "$response" | jq -r '.fields.status.name // empty' 2>/dev/null)
                    assignee=$(echo "$response" | jq -r '.fields.assignee.displayName // empty' 2>/dev/null)

                    [ -n "$title" ] && echo "$ticket:$title" >> ~/.jira_cache
                    [ -n "$status" ] && echo "$ticket:$status" >> ~/.jira_status_cache
                    [ -n "$assignee" ] && echo "$ticket:$assignee" >> ~/.jira_assignee_cache
                fi
            ) &
            _fetch_pids+=($!)
        fi
    done
    # Wait for JIRA fetches, but kill stragglers after 3s so selecting a branch is never
    # held up by in-flight network requests.
    if [ ${#_fetch_pids[@]} -gt 0 ]; then
        ( sleep 3 && kill "${_fetch_pids[@]}" 2>/dev/null ) &
        local _killer_pid=$!
        wait "${_fetch_pids[@]}" 2>/dev/null
        kill "$_killer_pid" 2>/dev/null
        wait "$_killer_pid" 2>/dev/null
    fi

    # Reload caches to pick up newly fetched data
    load_jira_caches

    # Pre-sort branch_list by final sort timestamp before streaming.
    # Worktree access times are already available in WORKTREE_ACCESS_LOG and WORKTREE_MAP,
    # so we can compute the same sort order as before—upfront—and then stream each line
    # in correct order without needing a post-hoc sort.
    declare -A _presort_nav_times
    if [ -f "$WORKTREE_ACCESS_LOG" ]; then
        while IFS=$'\t' read -r ts wt_path; do
            [ -n "$ts" ] && [ -n "$wt_path" ] && _presort_nav_times["$wt_path"]="$ts"
        done < "$WORKTREE_ACCESS_LOG"
    fi

    local _presorted=""
    while IFS=$'\t' read -r branch unix_time rest; do
        local _sort_ts="${unix_time:-0}"
        local _wt_path="${WORKTREE_MAP[$branch]:-}"
        if [ -n "$_wt_path" ]; then
            if [ "$PWD" = "$_wt_path" ] || [[ "$PWD" == "$_wt_path/"* ]]; then
                _sort_ts=$(date +%s)
            else
                local _nav_ts="${_presort_nav_times[$_wt_path]:-0}"
                [ "$_nav_ts" -gt "$_sort_ts" ] && _sort_ts="$_nav_ts"
                local _gitdir
                _gitdir=$(get_worktree_gitdir "$_wt_path")
                if [ -n "$_gitdir" ] && [ -f "$_gitdir/HEAD" ]; then
                    local _head_mtime
                    _head_mtime=$(stat -c %Y "$_gitdir/HEAD" 2>/dev/null || stat -f %m "$_gitdir/HEAD" 2>/dev/null)
                    [ -n "$_head_mtime" ] && [ "$_head_mtime" -gt "$_sort_ts" ] && _sort_ts="$_head_mtime"
                fi
            fi
        fi
        if [ -z "$_presorted" ]; then
            _presorted="${_sort_ts}"$'\t'"${branch}"$'\t'"${unix_time}"$'\t'"${rest}"
        else
            _presorted="${_presorted}"$'\n'"${_sort_ts}"$'\t'"${branch}"$'\t'"${unix_time}"$'\t'"${rest}"
        fi
    done <<< "$branch_list"
    branch_list=$(echo "$_presorted" | sort -t$'\t' -k1,1nr | cut -f2-)

    # Second pass: format output with cached data, streaming each line immediately.
    # branch_list is already in final sort order from the pre-sort above.
    while IFS=$'\t' read -r branch unix_time rest; do
        # Skip branches claimed by generate_worktree_data
        [ -n "${_wt_claimed[$branch]+x}" ] && continue

        local ref_path="refs/heads/$branch"

        # Skip entries that aren't actual branches
        if ! git show-ref --verify --quiet "$ref_path"; then
            continue
        fi

        # Get commit info in one git call
        IFS='|' read -r last_commit author <<< "$(git log -1 --pretty=format:'%cr|%an' "$ref_path" 2>/dev/null)"
        author="${author:0:15}"

        # Extract JIRA ticket (case-insensitive) and normalize to uppercase
        ticket=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]')
        jira_title=$(get_jira_title "$ticket")
        jira_status=$(get_jira_status "$ticket")
        jira_assignee=$(get_jira_assignee "$ticket")
        if [ ! -z "$jira_title" ]; then
            # Don't truncate here - store full title for fzf search
            # Truncation happens only at display time
            title="$jira_title"
        else
            title="<EMPTY>"
        fi
        if [ -z "$jira_status" ]; then
            jira_status="<EMPTY>"
        fi
        if [ -z "$jira_assignee" ]; then
            jira_assignee="<UNASSIGNED>"
        fi

        # Check if branch has a worktree and its status
        wt_path=$(get_worktree_path "$branch")
        wt_status=""

        if [ -n "$wt_path" ]; then
            wt_indicator="WT"
            # Quick check for uncommitted changes in worktree
            if [ -d "$wt_path" ]; then
                if ! (cd "$wt_path" && git diff-index --quiet HEAD 2>/dev/null); then
                    wt_status="DIRTY"
                else
                    wt_status="CLEAN"
                fi
            fi

            # For worktrees, get unix timestamp of last access
            # Get unix timestamp for sorting
            local wt_timestamp=0

            # If we're currently in this worktree, use NOW
            if [ "$PWD" = "$wt_path" ] || [[ "$PWD" == "$wt_path"/* ]]; then
                wt_timestamp=$(date +%s)
            else
                # Check navigation log
                local nav_time=$(get_worktree_navigation_time "$wt_path")
                [ -n "$nav_time" ] && wt_timestamp=$nav_time

                # Check HEAD mtime (git operations)
                local gitdir=$(get_worktree_gitdir "$wt_path")
                if [ -n "$gitdir" ] && [ -f "$gitdir/HEAD" ]; then
                    local head_mtime=$(stat -c %Y "$gitdir/HEAD" 2>/dev/null || stat -f %m "$gitdir/HEAD" 2>/dev/null)
                    [ -n "$head_mtime" ] && [ "$head_mtime" -gt "$wt_timestamp" ] && wt_timestamp=$head_mtime
                fi
            fi

            # Store timestamp in time_info for conversion at display time
            if [ "$wt_timestamp" -gt 0 ]; then
                time_info="checked:$wt_timestamp"
            else
                # Fallback to main repo reflog time
                time_info="checked:$unix_time"
            fi
        else
            wt_indicator=""
            # Use main repo reflog time for non-worktree branches
            time_info="checked:$unix_time"
        fi

        truncated_branch=$(truncate "$branch" $BRANCH_MAX_LENGTH)
        # Emit line directly — branch_list is already pre-sorted, no timestamp prefix needed
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$truncated_branch" "$title" "$jira_status" "$author" "$time_info" "committed: $last_commit" "$branch" "$jira_assignee" "$wt_indicator" "$wt_path" "$wt_status"
    done <<< "$branch_list" | tee "${temp_cache_file}.streaming.$$"

    # Atomically replace the cache only if the stream completed naturally.
    # If the pipeline was killed mid-stream (e.g. fzf killed by ctrl-r before all branches
    # were loaded), the rename never runs and the previous complete cache is preserved.
    # This prevents ctrl-r from seeing a truncated cache and reporting false "new branches".
    mv "${temp_cache_file}.streaming.$$" "$temp_cache_file" 2>/dev/null || true

    # Write hot cache with top N rows for instant display on next run (stale-while-revalidate)
    local hot_cache_file="$CACHE_DIR/hot_${count}.cache"
    head -n "${RR_HOT_CACHE_N:-25}" "$temp_cache_file" > "$hot_cache_file" 2>/dev/null || true

    # Cache the branch state (not HEAD, so switching branches doesn't invalidate)
    git for-each-ref --format='%(refname) %(objectname)' refs/heads/ | sort | sha256sum | cut -d' ' -f1 > "$temp_reflog_cache"
}

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Please install jq first."
    exit 1
fi

# Load all JIRA caches into associative arrays for fast lookup
declare -A JIRA_TITLE_CACHE
declare -A JIRA_STATUS_CACHE
declare -A JIRA_ASSIGNEE_CACHE

load_jira_caches() {
    # Load title cache
    if [ -f ~/.jira_cache ]; then
        while IFS=: read -r ticket title; do
            JIRA_TITLE_CACHE["$ticket"]="$title"
        done < ~/.jira_cache
    fi
    
    # Load status cache
    if [ -f ~/.jira_status_cache ]; then
        while IFS=: read -r ticket status; do
            JIRA_STATUS_CACHE["$ticket"]="$status"
        done < ~/.jira_status_cache
    fi
    
    # Load assignee cache
    if [ -f ~/.jira_assignee_cache ]; then
        while IFS=: read -r ticket assignee; do
            JIRA_ASSIGNEE_CACHE["$ticket"]="$assignee"
        done < ~/.jira_assignee_cache
    fi
}

# Function to get JIRA ticket title
get_jira_title() {
    local ticket=$1
    if [[ $ticket =~ ^${JIRA_PROJECT}-[0-9]+$ ]]; then
        echo "${JIRA_TITLE_CACHE[$ticket]}"
    fi
}

# Function to sanitize JIRA title for use in filesystem paths
sanitize_title_for_path() {
    local title="$1"
    local max_length="${2:-40}"  # Default max length 40 chars

    # Convert to lowercase, replace spaces and special chars with hyphens
    local sanitized=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/-\+/-/g' | sed 's/^-\+//g' | sed 's/-\+$//g')

    # Truncate to max length
    if [ ${#sanitized} -gt $max_length ]; then
        sanitized="${sanitized:0:$max_length}"
        # Remove trailing hyphen if truncation created one
        sanitized=$(echo "$sanitized" | sed 's/-\+$//g')
    fi

    echo "$sanitized"
}

# Function to get JIRA ticket status
get_jira_status() {
    local ticket=$1
    if [[ $ticket =~ ^${JIRA_PROJECT}-[0-9]+$ ]]; then
        echo "${JIRA_STATUS_CACHE[$ticket]}"
    fi
}

# Function to get JIRA ticket assignee
get_jira_assignee() {
    local ticket=$1
    if [[ $ticket =~ ^${JIRA_PROJECT}-[0-9]+$ ]]; then
        echo "${JIRA_ASSIGNEE_CACHE[$ticket]}"
    fi
}

# Fetch tickets assigned to current user from JIRA (with 5-min TTL cache)
# Returns TSV: TICKET\tTITLE\tSTATUS\tASSIGNEE\tUNIX_TIMESTAMP
fetch_assigned_jira_tickets() {
    local cache_ttl=300  # 5 minutes

    # Need JIRA credentials to fetch
    if [ -z "$JIRA_EMAIL" ] || [ -z "$JIRA_API_TOKEN" ]; then
        [ -f "$JIRA_ASSIGNED_CACHE" ] && cat "$JIRA_ASSIGNED_CACHE"
        return
    fi

    # Check if cache is fresh (skip if FORCE_REFRESH)
    if [ "${FORCE_REFRESH:-false}" != "true" ] && [ -f "$JIRA_ASSIGNED_CACHE" ]; then
        local cache_mtime
        cache_mtime=$(stat -c %Y "$JIRA_ASSIGNED_CACHE" 2>/dev/null || stat -f %m "$JIRA_ASSIGNED_CACHE" 2>/dev/null)
        if [ -n "$cache_mtime" ]; then
            local cache_age=$(( $(date +%s) - cache_mtime ))
            if [ "$cache_age" -lt "$cache_ttl" ]; then
                cat "$JIRA_ASSIGNED_CACHE"
                return
            fi
        fi
    fi

    # Fetch from JIRA using JQL (v3 API with POST)
    local jql="assignee = currentUser() AND status NOT IN (Done, Closed) AND project = ${JIRA_PROJECT} ORDER BY updated DESC"
    local response
    response=$(curl -s --max-time 10 -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        -X POST \
        "https://${JIRA_DOMAIN}/rest/api/3/search/jql" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{\"jql\":\"${jql}\",\"maxResults\":100,\"fields\":[\"summary\",\"status\",\"assignee\",\"updated\"]}" \
        2>/dev/null)

    if [ -z "$response" ]; then
        [ -f "$JIRA_ASSIGNED_CACHE" ] && cat "$JIRA_ASSIGNED_CACHE"
        return
    fi

    # Parse response into TSV rows
    local raw
    raw=$(echo "$response" | jq -r '.issues[]? | (.key) + "\t" + ((.fields.summary // "") | gsub("[\n\r\t]"; " ")) + "\t" + (.fields.status.name // "") + "\t" + (.fields.assignee.displayName // "") + "\t" + (.fields.updated // "")' 2>/dev/null)

    if [ -z "$raw" ]; then
        [ -f "$JIRA_ASSIGNED_CACHE" ] && cat "$JIRA_ASSIGNED_CACHE"
        return
    fi

    # Convert ISO timestamps to Unix timestamps
    local converted=""
    while IFS=$'\t' read -r key title status assignee updated; do
        [ -z "$key" ] && continue
        local ts
        ts=$(date -d "$updated" +%s 2>/dev/null)
        [ -z "$ts" ] && ts=$(date +%s)
        local status_val="${status:-<EMPTY>}"
        local assignee_val="${assignee:-<UNASSIGNED>}"
        local line="${key}"$'\t'"${title}"$'\t'"${status_val}"$'\t'"${assignee_val}"$'\t'"${ts}"
        if [ -z "$converted" ]; then
            converted="$line"
        else
            converted="${converted}"$'\n'"$line"
        fi
    done <<< "$raw"

    echo "$converted" | tee "$JIRA_ASSIGNED_CACHE"
}

# Fetch all active tickets in the project updated within 6 months (with 5-min TTL cache)
# Returns TSV: TICKET\tTITLE\tSTATUS\tASSIGNEE\tUNIX_TIMESTAMP
fetch_all_active_jira_tickets() {
    local cache_ttl=300  # 5 minutes

    # Need JIRA credentials to fetch
    if [ -z "$JIRA_EMAIL" ] || [ -z "$JIRA_API_TOKEN" ]; then
        [ -f "$JIRA_ACTIVE_CACHE" ] && cat "$JIRA_ACTIVE_CACHE"
        return
    fi

    # Check if cache is fresh (skip if FORCE_REFRESH)
    if [ "${FORCE_REFRESH:-false}" != "true" ] && [ -f "$JIRA_ACTIVE_CACHE" ]; then
        local cache_mtime
        cache_mtime=$(stat -c %Y "$JIRA_ACTIVE_CACHE" 2>/dev/null || stat -f %m "$JIRA_ACTIVE_CACHE" 2>/dev/null)
        if [ -n "$cache_mtime" ]; then
            local cache_age=$(( $(date +%s) - cache_mtime ))
            if [ "$cache_age" -lt "$cache_ttl" ]; then
                cat "$JIRA_ACTIVE_CACHE"
                return
            fi
        fi
    fi

    # Fetch from JIRA using JQL (v3 API with POST)
    local jql="project = ${JIRA_PROJECT} AND status NOT IN (Done, Closed) AND updated >= \"-180d\" ORDER BY updated DESC"
    local response
    response=$(curl -s --max-time 10 -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
        -X POST \
        "https://${JIRA_DOMAIN}/rest/api/3/search/jql" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d "{\"jql\":\"${jql}\",\"maxResults\":200,\"fields\":[\"summary\",\"status\",\"assignee\",\"updated\"]}" \
        2>/dev/null)

    if [ -z "$response" ]; then
        [ -f "$JIRA_ACTIVE_CACHE" ] && cat "$JIRA_ACTIVE_CACHE"
        return
    fi

    # Parse response into TSV rows
    local raw
    raw=$(echo "$response" | jq -r '.issues[]? | (.key) + "\t" + ((.fields.summary // "") | gsub("[\n\r\t]"; " ")) + "\t" + (.fields.status.name // "") + "\t" + (.fields.assignee.displayName // "") + "\t" + (.fields.updated // "")' 2>/dev/null)

    if [ -z "$raw" ]; then
        [ -f "$JIRA_ACTIVE_CACHE" ] && cat "$JIRA_ACTIVE_CACHE"
        return
    fi

    # Convert ISO timestamps to Unix timestamps
    local converted=""
    while IFS=$'\t' read -r key title status assignee updated; do
        [ -z "$key" ] && continue
        local ts
        ts=$(date -d "$updated" +%s 2>/dev/null)
        [ -z "$ts" ] && ts=$(date +%s)
        local status_val="${status:-<EMPTY>}"
        local assignee_val="${assignee:-<UNASSIGNED>}"
        local line="${key}"$'\t'"${title}"$'\t'"${status_val}"$'\t'"${assignee_val}"$'\t'"${ts}"
        if [ -z "$converted" ]; then
            converted="$line"
        else
            converted="${converted}"$'\n'"$line"
        fi
    done <<< "$raw"

    echo "$converted" | tee "$JIRA_ACTIVE_CACHE"
}

# Generate TSV rows for JIRA tickets that don't have an associated local branch.
# Assigned-to-me tickets appear first, then all other active tickets below.
generate_branchless_ticket_data() {
    local existing_data="$1"

    # Extract ticket IDs already represented in branch data (from full_branch field - column 7)
    local existing_tickets=""
    if [ -n "$existing_data" ]; then
        existing_tickets=$(echo "$existing_data" | cut -f7 | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | sort -u)
    else
        # No data passed; query git directly - always reflects current state, unlike cache file
        existing_tickets=$(git branch 2>/dev/null | sed 's/^[* ]*//' | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | sort -u)
    fi

    # Fetch assigned tickets and all active tickets
    local assigned all_active
    assigned=$(fetch_assigned_jira_tickets)
    all_active=$(fetch_all_active_jira_tickets)

    [ -z "$assigned" ] && [ -z "$all_active" ] && return

    # Build set of assigned ticket IDs for dedup
    local assigned_ids=""
    if [ -n "$assigned" ]; then
        assigned_ids=$(echo "$assigned" | cut -f1 | sort -u)
    fi

    # Helper to emit a branchless row
    _emit_branchless_row() {
        local ticket="$1" title="$2" status="$3" assignee="$4" updated_ts="$5"

        [ -z "$ticket" ] && return
        [[ ! "$ticket" =~ ^${JIRA_PROJECT}-[0-9]+$ ]] && return

        # Skip if this ticket already has a branch
        echo "$existing_tickets" | grep -qx "$ticket" && return

        # Update in-memory caches so worktree creation can use them
        if [ -z "${JIRA_TITLE_CACHE[$ticket]}" ]; then
            JIRA_TITLE_CACHE["$ticket"]="$title"
            [ -n "$title" ] && echo "$ticket:$title" >> ~/.jira_cache
        fi
        if [ -z "${JIRA_STATUS_CACHE[$ticket]}" ]; then
            JIRA_STATUS_CACHE["$ticket"]="$status"
            [ -n "$status" ] && echo "$ticket:$status" >> ~/.jira_status_cache
        fi
        if [ -z "${JIRA_ASSIGNEE_CACHE[$ticket]}" ]; then
            JIRA_ASSIGNEE_CACHE["$ticket"]="$assignee"
            [ -n "$assignee" ] && echo "$ticket:$assignee" >> ~/.jira_assignee_cache
        fi

        local truncated_ticket
        truncated_ticket=$(truncate "$ticket" $BRANCH_MAX_LENGTH)

        local author_display="${assignee:0:15}"
        [ -z "$author_display" ] && author_display="<UNASSIGNED>"
        local assignee_display="${assignee:-<UNASSIGNED>}"
        local status_display="${status:-<EMPTY>}"

        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$truncated_ticket" "$title" "$status_display" "$author_display" \
            "updated:$updated_ts" "<NO BRANCH>" \
            "TICKET:$ticket" "$assignee_display" "" "" ""
    }

    # Section 1: assigned-to-me tickets without branches
    if [ -n "$assigned" ]; then
        while IFS=$'\t' read -r ticket title status assignee updated_ts; do
            [ "$status" = "<EMPTY>" ] && status=""
            [ "$assignee" = "<UNASSIGNED>" ] && assignee=""
            _emit_branchless_row "$ticket" "$title" "$status" "$assignee" "$updated_ts"
        done <<< "$assigned"
    fi

    # Section 2: all other active tickets without branches (not in assigned set)
    if [ -n "$all_active" ]; then
        while IFS=$'\t' read -r ticket title status assignee updated_ts; do
            [ "$status" = "<EMPTY>" ] && status=""
            [ "$assignee" = "<UNASSIGNED>" ] && assignee=""

            # Skip if already shown in assigned section
            echo "$assigned_ids" | grep -qx "$ticket" && continue

            _emit_branchless_row "$ticket" "$title" "$status" "$assignee" "$updated_ts"
        done <<< "$all_active"
    fi
}

# Generate TSV rows for branches that exist on origin but not locally.
# These appear at the bottom of the list as a "remote discovery" section.
# Uses only in-memory JIRA cache (no blocking fetches).
generate_remote_only_data() {
    # One bulk call for local branch names (for dedup via awk)
    local local_branches
    local_branches=$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)

    # Compute cutoff timestamp (0 means no limit)
    local cutoff_ts=0
    if [ "${RR_REMOTE_MAX_AGE_DAYS:-0}" -gt 0 ] 2>/dev/null; then
        cutoff_ts=$(( $(date +%s) - RR_REMOTE_MAX_AGE_DAYS * 86400 ))
    fi

    # One bulk call for all remote branches with full info.
    # awk filters out branches that exist locally and are older than the age limit —
    # no per-branch git calls. Output is streamed directly via printf so SIGPIPE
    # propagates immediately when fzf exits.
    git for-each-ref --sort='-committerdate' refs/remotes/origin/ \
        --format='%(refname:short)%09%(committerdate:unix)%09%(committername)%09%(committerdate:relative)' 2>/dev/null |
    sed 's/^origin\///' |
    grep -v '^HEAD' |
    awk -v local_branches="$local_branches" -v cutoff="$cutoff_ts" '
        BEGIN {
            n = split(local_branches, arr, "\n")
            for (i = 1; i <= n; i++) local_set[arr[i]] = 1
        }
        {
            if (local_set[$1]) next
            if (cutoff > 0 && $2 < cutoff) next
            print
        }
    ' |
    while IFS=$'\t' read -r branch unix_time author rel_time; do
        [ -z "$branch" ] && continue
        author="${author:0:15}"

        local ticket
        ticket=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]')
        local jira_title jira_status jira_assignee
        jira_title=$(get_jira_title "$ticket")
        jira_status=$(get_jira_status "$ticket")
        jira_assignee=$(get_jira_assignee "$ticket")

        local truncated_branch
        truncated_branch=$(truncate "$branch" $BRANCH_MAX_LENGTH)

        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$truncated_branch" "${jira_title:-<EMPTY>}" "${jira_status:-<EMPTY>}" "$author" \
            "updated:$unix_time" "committed: $rel_time" \
            "REMOTE:$branch" "${jira_assignee:-<UNASSIGNED>}" "" "" ""
    done
}

# Function to format status with color/emoji - returns padded colored string
format_status() {
    local status=$1
    local status_lower=$(echo "$status" | tr '[:upper:]' '[:lower:]')
    local status_upper=$(echo "$status" | tr '[:lower:]' '[:upper:]')
    local icon color text
    
    case "$status_lower" in
        *"done"*|*"closed"*|*"resolved"*)
            # Mellow green - completed
            icon="✓" color="38;5;114" text="$status_upper"
            ;;
        *"passed qa"*|*"qa passed"*)
            # Mellow cyan - passed QA
            icon="◆" color="38;5;81" text="$status_upper"
            ;;
        *"qa"*|*"testing"*|*"test"*)
            # Mellow blue - in QA/testing
            icon="◇" color="38;5;109" text="$status_upper"
            ;;
        *"progress"*|*"dev"*|*"development"*)
            # Mellow yellow - actively working
            icon="●" color="38;5;221" text="$status_upper"
            ;;
        *"mr"*|*"review"*|*"code review"*|*"pull request"*|*"pr"*)
            # Mellow cyan - merge request/code review
            icon="⬡" color="38;5;81" text="$status_upper"
            ;;
        *"paused"*|*"on hold"*|*"hold"*)
            # Mellow orange - paused work
            icon="◐" color="38;5;173" text="$status_upper"
            ;;
        *"blocked"*|*"impediment"*)
            # Mellow red - blocked
            icon="✗" color="38;5;167" text="$status_upper"
            ;;
        *"todo"*|*"to do"*|*"backlog"*|*"open"*|*"new"*)
            # Light gray - not started
            icon="○" color="38;5;250" text="$status_upper"
            ;;
        *)
            if [ -z "$status" ]; then
                printf "%-${STATUS_MAX_LENGTH}s" ""
                return
            else
                icon="·" color="38;5;244" text="$status_upper"
            fi
            ;;
    esac
    
    # Truncate text to fit, accounting for icon + space
    local max_text_len=$((STATUS_MAX_LENGTH - 2))
    local truncated_text=$(truncate "$text" $max_text_len)
    local text_len=${#truncated_text}
    local pad_len=$((STATUS_MAX_LENGTH - text_len - 2))
    local padding=""
    [ $pad_len -gt 0 ] && padding=$(printf "%${pad_len}s" "")
    
    echo -e "\033[${color}m${icon} ${truncated_text}${padding}\033[0m"
}

# Cache format version — bump this whenever the TSV field layout changes.
# On mismatch, all branch_list / reflog caches are deleted and regenerated.
CACHE_FORMAT_VERSION="v3"

# Cache management functions
ensure_cache_dir() {
    mkdir -p "$CACHE_DIR"
    local ver_file="$CACHE_DIR/.cache_format_version"
    if [ "$(cat "$ver_file" 2>/dev/null)" != "$CACHE_FORMAT_VERSION" ]; then
        rm -f "$CACHE_DIR"/branch_list_*.cache "$CACHE_DIR"/reflog_*.cache
        echo "$CACHE_FORMAT_VERSION" > "$ver_file"
    fi
}


# Function to show current checkout state
get_current_state() {
    local current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    local current_location="$PWD"

    # Check if in a worktree and get badge
    local location_type="main repo"
    local location_display=""
    local wt_badge=""
    if git rev-parse --git-common-dir >/dev/null 2>&1; then
        local common_dir=$(git rev-parse --git-common-dir)
        if [[ "$common_dir" != ".git" ]]; then
            location_type="worktree"
            location_display=" @ \033[38;5;81m${PWD/$HOME/~}\033[0m"

            wt_badge=" \033[38;5;250m⊙\033[0m"
        fi
    fi

    # Check for uncommitted changes
    local status_icon=""
    local change_count=0
    if ! git diff-index --quiet HEAD 2>/dev/null; then
        local modified=$(git diff --name-only 2>/dev/null | wc -l)
        local staged=$(git diff --cached --name-only 2>/dev/null | wc -l)
        change_count=$((modified + staged))
        if [ $change_count -gt 0 ]; then
            status_icon=" \033[38;5;214m⚠ ${change_count} uncommitted\033[0m"
        fi
    else
        status_icon=" \033[38;5;34m✓\033[0m"
    fi

    # Get JIRA title for current branch
    local jira_display=""
    local ticket=$(echo "$current_branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | head -1)
    if [ -n "$ticket" ]; then
        local jira_title=$(get_jira_title "$ticket")
        if [ -n "$jira_title" ]; then
            # Truncate title if too long (max 45 chars to prevent line overflow)
            if [ ${#jira_title} -gt 45 ]; then
                jira_title="${jira_title:0:42}..."
            fi
            jira_display=" \033[2m-\033[0m \033[1;96m${jira_title}\033[0m"
        fi
    fi

    # Simplified header - full details are in the current branch row below
    if [[ "$location_type" = "worktree" ]]; then
        echo -e "╭─ \033[2m@\033[0m \033[38;5;81m${PWD/$HOME/~}\033[0m"
    else
        echo -e "╭─ \033[2mmain repository\033[0m"
    fi
}

# Function to format current branch as a row (matching column structure)
format_current_branch_as_row() {
    local current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
    local current_location="$PWD"

    # Get JIRA info for current branch
    local ticket=$(echo "$current_branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | head -1)
    local jira_title=""
    local jira_status=""
    local jira_assignee=""

    if [ -n "$ticket" ]; then
        jira_title=$(get_jira_title "$ticket")
        jira_status=$(get_jira_status "$ticket")
        jira_assignee=$(get_jira_assignee "$ticket")
    fi

    # Check for uncommitted changes and worktree status
    local wt_indicator=""
    local wt_display=""
    local wt_visual_width=0
    local branch_width=$((BRANCH_MAX_LENGTH-2))

    # Check if in a worktree
    if git rev-parse --git-common-dir >/dev/null 2>&1; then
        local common_dir=$(git rev-parse --git-common-dir)
        if [[ "$common_dir" != ".git" ]]; then
            wt_indicator="WT"
            local wt_path="$PWD"

            if ! git diff-index --quiet HEAD 2>/dev/null; then
                wt_display=$(printf ' \033[38;5;250m⊙\033[38;5;214m !\033[0m')
            else
                wt_display=$(printf ' \033[38;5;250m⊙\033[0m  ')
            fi
            # " ⊙ !" or " ⊙  " = space(1) + ⊙(1) + space(1) + !(1) or space(1) = 4 visual cols
            wt_visual_width=4

            # Add pane indicators if enabled
            if [ "$RR_PANE_MGMT_ENABLED" = "true" ] && [ "$PANE_COUNT" -gt 0 ]; then
                for i in "${!PANE_IDS[@]}"; do
                    pane_current_dir=$(get_pane_current_dir "${PANE_IDS[$i]}")
                    # Check if pane is in this worktree (exact match or subdirectory with / separator)
                    if [ -n "$pane_current_dir" ] && ( [ "$pane_current_dir" = "$wt_path" ] || [[ "$pane_current_dir" == "$wt_path/"* ]] ); then
                        indicator="${PANE_INDICATORS[$i]}"
                        wt_display="${wt_display}$(printf '\033[38;5;114m%s\033[0m' "$indicator")"
                        indicator_width=$(echo -n "$indicator" | wc -L)
                        wt_visual_width=$((wt_visual_width + indicator_width))
                    fi
                done
            fi

            branch_width=$((BRANCH_MAX_LENGTH - 2 - wt_visual_width))
        fi
    fi

    # Get commit info (last commit time)
    local raw_commit=$(git log -1 --format="%ar" 2>/dev/null || echo "")
    local commit_info="$(printf "%-${COMMIT_MAX_LENGTH}s" "committed: $raw_commit")"

    # Format title
    local display_title=""
    if [ -z "$jira_title" ]; then
        display_title="$(printf "%-${TITLE_MAX_LENGTH}s" "")"
    else
        truncated_title=$(truncate "$jira_title" $TITLE_MAX_LENGTH)
        display_title="$(printf "%-${TITLE_MAX_LENGTH}s" "$truncated_title")"
    fi

    # Format status with color (matching data rows)
    local display_status
    if [ -z "$jira_status" ]; then
        display_status="$(printf "%-${STATUS_MAX_LENGTH}s" "")"
    else
        display_status="$(format_status "$jira_status")"
    fi

    # Format assignee
    local display_assignee="$(printf "%-${ASSIGNEE_MAX_LENGTH}s" "${jira_assignee:-}")"

    local time_info="$(printf "%-26s" "")"

    # Style as "current branch" marker: gray bg + bold, but warm amber tones
    # instead of the cool purple/blue used by real rows — clearly distinct at a glance
    local bg=$'\033[48;5;17m'           # dark navy background (clearly distinct from plain rows)
    local bold=$'\033[1m'
    local amber=$'\033[38;5;179m'      # muted warm amber for branch + title (vs purple 141 in real rows)
    local warm_tan=$'\033[38;5;137m'   # slightly more muted tan for assignee
    local dim_gray=$'\033[2;37m'       # dim gray for time/commit (same as real rows)

    local branch_display
    branch_display=$(truncate "$current_branch" $branch_width)
    local display_branch="${bg}${bold}${amber}★ $(printf "%-${branch_width}s" "$branch_display")${wt_display}"

    # Print row with gray background and amber palette
    echo -e "${display_branch}${bg} │ ${bg}${bold}${amber}$(printf "%-${TITLE_MAX_LENGTH}s" "$display_title")${bg} │ ${bg}${display_status}${bg} │ ${bg}${bold}${warm_tan}$(printf "%-${ASSIGNEE_MAX_LENGTH}s" "$display_assignee")${bg} │ ${bg}${bold}${dim_gray}${time_info}${bg} │ ${bg}${bold}${dim_gray}${commit_info}${bg} │"$'\033[0m'
}

# Function to show help page
# Function to generate dynamic header text with colors
get_header_text() {
    # Build pane status display if pane management is enabled
    local pane_status=""
    if [ "$RR_PANE_MGMT_ENABLED" = "true" ] && [ "$PANE_COUNT" -gt 0 ]; then
        for i in "${!PANE_IDS[@]}"; do
            local pane_id="${PANE_IDS[$i]}"
            local indicator="${PANE_INDICATORS[$i]}"
            local current_dir=$(get_pane_current_dir "$pane_id")

            if [ -n "$current_dir" ]; then
                local trimmed_dir=$(trim_path "$current_dir")
                pane_status="${pane_status}${indicator}\033[2m:\033[0m\033[1;38;5;114m${trimmed_dir}\033[0m  "
            else
                pane_status="${pane_status}${indicator}:\033[38;5;240m✗\033[0m  "
            fi
        done
        # Add separator if we have pane status
        [ -n "$pane_status" ] && pane_status="│ ${pane_status}"
    fi

    # Build keybinding help text (compact - press ? for full help)
    local base_keys="?: help │ C-R: refresh"
    local pane_keys=""

    # Add pane management keys if enabled (these are the most important)
    if [ "$RR_PANE_MGMT_ENABLED" = "true" ] && [ "$PANE_COUNT" -gt 0 ]; then
        for i in "${!PANE_KEYS[@]}"; do
            local key="${PANE_KEYS[$i]}"
            local label="${PANE_LABELS[$i]}"
            [ -n "$key" ] && pane_keys="${pane_keys} │ ${key^^}: ${label}"
        done
        pane_keys="${pane_keys} │ F6: all │ F7: curr │ A-↵: switch+all"
    fi

    local keys_display="${base_keys}${pane_keys}"

    echo -e "╰─ \033[1;38;5;109m📁 rr\033[0m  ${pane_status}\033[2m│ ${keys_display}\033[0m"

    # Show current branch as final line (formatted row matching column structure)
    format_current_branch_as_row
}

# Function to get branch list sorted by checkout time (default)
get_branches_by_checkout() {
    git reflog -n "$REFLOG_COUNT" --date=relative | 
    grep 'checkout: moving' | 
    sed -E 's/^[a-f0-9]+ HEAD@\{([^}]+)\}: checkout: moving from .* to ([^ ]+).*$/\2\t\1/' | 
    awk '!seen[$1]++ { print $0 }'
}

# Function to get branch list sorted by commit time
get_branches_by_commit() {
    git for-each-ref --sort='-committerdate' refs/heads/ \
        --format='%(refname:short)%09%(committerdate:relative)' |
    head -n "$REFLOG_COUNT"
}

# Helper function to update loading progress
# Renders a minimal fzf-integrated status line: blank / prompt / status
update_loading_progress() {
    local stage="$1"
    local labels=("reflog" "jira" "worktrees" "branches")
    local parts=""

    for i in "${!labels[@]}"; do
        local n=$((i + 1))
        if [ "$n" -lt "$stage" ]; then
            parts="${parts}\033[38;5;114m✓\033[0m ${labels[$i]}  "
        elif [ "$n" -eq "$stage" ]; then
            parts="${parts}\033[38;5;141m●\033[0m ${labels[$i]}  "
        else
            parts="${parts}\033[38;5;240m○ ${labels[$i]}\033[0m  "
        fi
    done

    {
        tput rc
        printf "\033[K\n"
        printf "  \033[2m>\033[0m\033[K\n"
        printf "  \033[38;5;240m╰─\033[0m \033[1;38;5;141mrr\033[0m  %b\033[K\n" "$parts"
        printf "\033[K"
    } > /dev/tty 2>&1
}

# Update the status line in-place with a branch generation progress bar (row 2)
update_branch_progress() {
    local current="$1"
    local total="$2"
    local bar_width=8
    local bar_filled=0

    if [ "$total" -gt 0 ] 2>/dev/null; then
        bar_filled=$(( (current * bar_width) / total ))
        [ "$bar_filled" -gt "$bar_width" ] && bar_filled=$bar_width
    fi

    local bar="" i
    for ((i=0; i<bar_width; i++)); do
        if [ "$i" -lt "$bar_filled" ]; then
            bar="${bar}█"
        else
            bar="${bar}░"
        fi
    done

    local count_str="${current}/${total}"

    {
        tput rc
        tput cud 2
        printf "  \033[38;5;240m╰─\033[0m \033[1;38;5;141mrr\033[0m  \033[38;5;114m✓\033[0m reflog  \033[38;5;114m✓\033[0m jira  \033[38;5;114m✓\033[0m worktrees  \033[38;5;141m●\033[0m branches  \033[2m[${bar}]  ${count_str}\033[0m\033[K"
    } > /dev/tty 2>&1
}

# Initialize cache (must happen before loading UI for GENERATE_MORE_MODE check)
ensure_cache_dir

# Show initial loading UI and run initialization stages with progress
if [ "$GENERATE_MORE_MODE" != true ]; then
    { printf '\n\n\n\n'; tput cuu 4; tput sc; } > /dev/tty 2>&1
    update_loading_progress 1

    # Load JIRA caches
    load_jira_caches
    update_loading_progress 2

    # Build worktree map
    build_worktree_map
    update_loading_progress 3
else
    # For reload mode, just run silently
    load_jira_caches
    build_worktree_map
fi

# Show stage 4 progress before the (potentially slow) branch data generation
if [ "$GENERATE_MORE_MODE" != true ]; then
    update_loading_progress 4
fi

# If in process-action mode, handle the action and exit
if [ "$PROCESS_ACTION_MODE" = true ]; then
    if [[ "$ACTION_STRING" =~ ^SET_ALL_PANES: ]]; then
        branch=$(echo "$ACTION_STRING" | sed 's/^SET_ALL_PANES://' | tr -d '\n\r' | sed "s/^[[:space:]'\"]*//;s/[[:space:]'\"]*$//")
        # Strip REMOTE: prefix and create local tracking branch if needed
        if [[ "$branch" == REMOTE:* ]]; then
            branch="${branch#REMOTE:}"
            if ! git show-ref --verify --quiet "refs/heads/$branch"; then
                git branch "$branch" "origin/$branch" >/dev/null 2>&1
            fi
        fi

        if [ "$RR_PANE_MGMT_ENABLED" != "true" ] || [ "$PANE_COUNT" -eq 0 ]; then
            notify-send "Pane management not enabled" &
            exit 1
        fi

        if [ -n "$branch" ]; then
            for i in "${!PANE_IDS[@]}"; do
                switch_pane_to_branch "$i" "$branch" >/dev/null 2>&1 &
            done
        fi
        exit 0
    elif [[ "$ACTION_STRING" =~ ^SET_PANE_([0-9]+): ]]; then
        pane_num="${BASH_REMATCH[1]}"
        branch=$(echo "$ACTION_STRING" | sed "s/^SET_PANE_${pane_num}://" | tr -d '\n\r' | sed "s/^[[:space:]'\"]*//;s/[[:space:]'\"]*$//")

        if [ -n "$branch" ]; then
            switch_pane_to_branch "$pane_num" "$branch" >/dev/null 2>&1 &
        fi
        exit 0
    fi
    exit 0
fi

# GENERATE_MORE_MODE: collect all data (streaming captured by $(...)) then format for fzf reload
if [ "$GENERATE_MORE_MODE" = true ]; then
    _wt_claimed_file=$(mktemp)
    _wt_data=$(generate_worktree_data "$_wt_claimed_file")
    processed_data=$(generate_branch_data "$REFLOG_COUNT" "$_wt_claimed_file")
    rm -f "$_wt_claimed_file"
    # Merge-sort worktree data and branch data by access timestamp (field 5)
    # so the combined list has correct sort order across both sources.
    if [ -n "$_wt_data" ]; then
        if [ -n "$processed_data" ]; then
            processed_data=$(printf '%s\n%s' "$_wt_data" "$processed_data" | awk -F'\t' '{
                ts = 0; n = split($5, a, ":")
                if (n >= 2 && a[n] ~ /^[0-9]+$/) ts = a[n]
                print ts "\t" $0
            }' | sort -t$'\t' -k1,1nr | cut -f2-)
        else
            processed_data="$_wt_data"
        fi
    fi

    # Append branchless JIRA tickets
    if [ -n "$JIRA_EMAIL" ] && [ -n "$JIRA_API_TOKEN" ]; then
        branchless_data=$(generate_branchless_ticket_data "$processed_data")
        if [ -n "$branchless_data" ]; then
            if [ -n "$processed_data" ]; then
                processed_data="${processed_data}"$'\n'"${branchless_data}"
            else
                processed_data="$branchless_data"
            fi
        fi
    fi

    # Append remote-only branches (exist on origin but not locally)
    remote_data=$(generate_remote_only_data)
    if [ -n "$remote_data" ]; then
        if [ -n "$processed_data" ]; then
            processed_data="${processed_data}"$'\n'"${remote_data}"
        else
            processed_data="$remote_data"
        fi
    fi

    # Format and output for fzf reload
    # Show refresh summary if this was a refresh operation (replaces normal header)
    if [ "$SHOW_REFRESH_SUMMARY" = true ] && [ -n "$REFRESH_TEMP_DIR" ]; then
        # Calculate granular deltas
        NEW_BRANCHES=0
        STATUS_CHANGES=0
        ASSIGNEE_CHANGES=0
        NEW_TICKETS=0

        # Count new branches (in new but not in old) - compare full branch names (field 7)
        if [ -f "$REFRESH_TEMP_DIR/old_branches.cache" ]; then
            NEW_BRANCHES=$(comm -13 <(cut -f7 "$REFRESH_TEMP_DIR/old_branches.cache" 2>/dev/null | sort) <(echo "$processed_data" | cut -f7 | sort) | wc -l)
        else
            NEW_BRANCHES=$(echo "$processed_data" | wc -l)
        fi

        # Count status changes (tickets with different status)
        if [ -f "$REFRESH_TEMP_DIR/old_status.cache" ] && [ -f ~/.jira_status_cache ]; then
            while IFS=: read -r ticket old_status; do
                new_status=$(grep "^$ticket:" ~/.jira_status_cache 2>/dev/null | cut -d: -f2)
                [ -n "$new_status" ] && [ "$old_status" != "$new_status" ] && ((STATUS_CHANGES++))
            done < "$REFRESH_TEMP_DIR/old_status.cache"
        fi

        # Count assignee changes (tickets with different assignee)
        if [ -f "$REFRESH_TEMP_DIR/old_assignee.cache" ] && [ -f ~/.jira_assignee_cache ]; then
            while IFS=: read -r ticket old_assignee; do
                new_assignee=$(grep "^$ticket:" ~/.jira_assignee_cache 2>/dev/null | cut -d: -f2)
                [ -n "$new_assignee" ] && [ "$old_assignee" != "$new_assignee" ] && ((ASSIGNEE_CHANGES++))
            done < "$REFRESH_TEMP_DIR/old_assignee.cache"
        fi

        # Count new JIRA tickets fetched
        if [ -f "$REFRESH_TEMP_DIR/old_jira.cache" ] && [ -f ~/.jira_cache ]; then
            NEW_TICKETS=$(comm -13 <(cut -d: -f1 "$REFRESH_TEMP_DIR/old_jira.cache" | sort) <(cut -d: -f1 ~/.jira_cache | sort) | wc -l)
        elif [ -f ~/.jira_cache ]; then
            NEW_TICKETS=$(wc -l < ~/.jira_cache)
        fi

        # Build summary parts
        SUMMARY_PARTS=()
        [ "$NEW_BRANCHES" -gt 0 ] && SUMMARY_PARTS+=("\033[1;32m↑${NEW_BRANCHES}\033[0m new branch$( [ $NEW_BRANCHES -gt 1 ] && echo es || echo '')")
        [ "$NEW_TICKETS" -gt 0 ] && SUMMARY_PARTS+=("\033[1;32m↑${NEW_TICKETS}\033[0m new ticket$( [ $NEW_TICKETS -gt 1 ] && echo s || echo '')")
        [ "$STATUS_CHANGES" -gt 0 ] && SUMMARY_PARTS+=("\033[1;96m↻${STATUS_CHANGES}\033[0m status update$( [ $STATUS_CHANGES -gt 1 ] && echo s || echo '')")
        [ "$ASSIGNEE_CHANGES" -gt 0 ] && SUMMARY_PARTS+=("\033[1;96m↻${ASSIGNEE_CHANGES}\033[0m assignee change$( [ $ASSIGNEE_CHANGES -gt 1 ] && echo s || echo '')")

        # Format summary header (must be 3 lines to match --header-lines=3)
        echo -e "╭─ \033[1;32m✓ Cache Refreshed\033[0m"

        if [ ${#SUMMARY_PARTS[@]} -gt 0 ]; then
            SUMMARY=$(IFS=" │ "; echo -e "${SUMMARY_PARTS[*]}")
            echo -e "╰─ ${SUMMARY}"
        else
            echo -e "╰─ \033[2mNo changes detected\033[0m"
        fi

        # Add current branch row as third header line (same as normal mode)
        format_current_branch_as_row

        # Cleanup temp directory
        rm -rf "$REFRESH_TEMP_DIR"

        # Launch auto-clear script in background
        "$AUTO_CLEAR_SCRIPT" &
    else
        # Normal header output
        get_header_text
    fi

    # Buffer all formatted output before writing to stdout so fzf receives it atomically.
    # This prevents the spinner/partial-list flash during ctrl-r reload.
    printf "%s" "$(echo "$processed_data" |
    while IFS=$'\t' read -r branch title status author time_info commit_info full_branch assignee wt_indicator wt_path wt_status; do
        # Convert timestamp to human-readable format
        time_info=$(convert_timestamp_to_relative "$time_info")

        if [ -z "$title" ] || [ "$title" = " " ] || [ "$title" = "<EMPTY>" ]; then
            display_title="$(printf "%-${TITLE_MAX_LENGTH}s" "")"
        else
            # Truncate if needed (adds ... for long titles), then pad to exact width
            truncated_title=$(truncate "$title" $TITLE_MAX_LENGTH)
            display_title="$(printf "%-${TITLE_MAX_LENGTH}s" "$truncated_title")"
        fi
        if [ -z "$status" ] || [ "$status" = "<EMPTY>" ]; then
            display_status="$(printf "%-${STATUS_MAX_LENGTH}s" "")"
        else
            display_status="$(format_status "$status")"
        fi
        if [ -z "$assignee" ] || [ "$assignee" = "<UNASSIGNED>" ]; then
            display_assignee="$(printf "%-15s" "")"
        else
            display_assignee="$(printf "%-15s" "$assignee")"
        fi
        # Check if assigned to me AND branch is authoritative (exact ticket match)
        assignee_lower=$(echo "$assignee" | tr '[:upper:]' '[:lower:]')
        jira_me_lower=$(echo "$JIRA_ME" | tr '[:upper:]' '[:lower:]')
        # Extract ticket from branch name and check if branch IS the ticket (not a variant like -wip, -good)
        ticket_from_branch=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | head -1)
        branch_upper=$(echo "$branch" | tr '[:lower:]' '[:upper:]')
        is_authoritative=false
        [ "$branch_upper" = "$ticket_from_branch" ] && is_authoritative=true
        
        # Pad branch for display (with star/dot/spaces and worktree indicator)
        # Worktree indicator: ⊙  (clean), ⊙! (dirty), ⊙≠ (mismatch - different branch checked out)
        wt_display=""
        branch_width=$((BRANCH_MAX_LENGTH-2))
        _wt_mismatch_branch=""
        [[ "$wt_indicator" == "WT_MISMATCH:"* ]] && _wt_mismatch_branch="${wt_indicator#WT_MISMATCH:}"
        if [ "$wt_indicator" = "WT" ] || [ -n "$_wt_mismatch_branch" ]; then
            if [ -n "$_wt_mismatch_branch" ]; then
                wt_display=$(printf ' \033[38;5;214m⊙≠\033[0m ')
            elif [ "$wt_status" = "DIRTY" ]; then
                wt_display=$(printf ' \033[38;5;250m⊙\033[38;5;214m !\033[0m')
            else
                wt_display=$(printf ' \033[38;5;250m⊙\033[0m  ')
            fi
            # " ⊙≠ " / " ⊙ !" / " ⊙  " = 4 visual cols each
            wt_visual_width=4

            # Add pane indicators if enabled (based on real-time current directory)
            if [ "$RR_PANE_MGMT_ENABLED" = "true" ] && [ "$PANE_COUNT" -gt 0 ]; then
                for i in "${!PANE_IDS[@]}"; do
                    pane_current_dir=$(get_pane_current_dir "${PANE_IDS[$i]}")
                    # Check if pane is in this worktree (exact match or subdirectory with / separator)
                    if [ -n "$pane_current_dir" ] && ( [ "$pane_current_dir" = "$wt_path" ] || [[ "$pane_current_dir" == "$wt_path/"* ]] ); then
                        indicator="${PANE_INDICATORS[$i]}"
                        wt_display="${wt_display}$(printf '\033[38;5;114m%s\033[0m' "$indicator")"
                        # Calculate visual width of this indicator (use wc -L)
                        indicator_width=$(echo -n "$indicator" | wc -L)
                        wt_visual_width=$((wt_visual_width + indicator_width))
                    fi
                done
            fi

            # Calculate branch width: total - star(2) - wt_visual_width
            branch_width=$((BRANCH_MAX_LENGTH - 2 - wt_visual_width))
        fi

        # Skip the current branch - you're already on it
        current_branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ "$branch" = "$current_branch_name" ]; then
            continue
        fi

        # Show the title (worktree badge is now in the branch column)
        title_column="$display_title"

        # Truncate branch to correct width (handles pre-truncated branches with "...")
        branch_display=$(truncate "$branch" $branch_width)

        # Detect row type from full_branch prefix
        is_branchless=false
        is_remote=false
        [[ "$full_branch" == TICKET:* ]] && is_branchless=true
        [[ "$full_branch" == REMOTE:* ]] && is_remote=true

        display_branch=""
        if [ "$is_remote" = true ]; then
            # Remote-only branch - dim steel blue with ↑ prefix
            display_branch=$(printf "\033[38;5;67m↑ \033[38;5;67m%-${branch_width}s\033[0m" "$branch_display")
            printf "%s │ \033[38;5;67m%s\033[0m │ %s │ \033[38;5;244m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │ %s │ %s\n" \
                "$display_branch" "$title_column" "$display_status" "$display_assignee" "$time_info" "$commit_info" "$full_branch" "$title"
        elif [ "$is_branchless" = true ]; then
            # Branchless ticket - use + prefix with green color
            display_branch=$(printf "\033[38;5;71m+ \033[38;5;71m%-${branch_width}s\033[0m" "$branch_display")
            printf "%s │ \033[38;5;71m%s\033[0m │ %s │ \033[38;5;244m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[38;5;241m%-${COMMIT_MAX_LENGTH}s\033[0m │ %s │ %s\n" \
                "$display_branch" "$title_column" "$display_status" "$display_assignee" "$time_info" "no branch" "$full_branch" "$title"
        elif [ -n "$JIRA_ME" ] && [ "$assignee_lower" = "$jira_me_lower" ]; then
            if [ "$is_authoritative" = true ]; then
                # Authoritative branch assigned to me - full star, bright purple
                display_branch=$(printf "\033[38;5;141m★ %-${branch_width}s\033[0m%s" "$branch_display" "$wt_display")
                printf "%s │ \033[38;5;141m%s\033[0m │ %s │ \033[38;5;109m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │ %s │ %s\n" \
                    "$display_branch" "$title_column" "$display_status" "$display_assignee" "$time_info" "$commit_info" "$full_branch" "$title"
            else
                # Variant branch assigned to me - dim dot, grayed purple (103)
                display_branch=$(printf "\033[38;5;244m· \033[38;5;103m%-${branch_width}s\033[0m%s" "$branch_display" "$wt_display")
                printf "%s │ \033[38;5;103m%s\033[0m │ %s │ \033[38;5;244m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │ %s │ %s\n" \
                    "$display_branch" "$title_column" "$display_status" "$display_assignee" "$time_info" "$commit_info" "$full_branch" "$title"
            fi
        else
            # Normal formatting with 2-space indent for alignment
            display_branch=$(printf "  \033[38;5;250m%-${branch_width}s\033[0m%s" "$branch_display" "$wt_display")
            printf "%s │ \033[38;5;109m%s\033[0m │ %s │ \033[38;5;244m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │ %s │ %s\n" \
                "$display_branch" "$title_column" "$display_status" "$display_assignee" "$time_info" "$commit_info" "$full_branch" "$title"
        fi
    done)"
    exit 0
fi

# Normal mode: erase loading UI then stream branch data directly into fzf.
# generate_branch_data now pre-sorts branch_list by worktree access times and streams
# each line immediately, so fzf opens as soon as the first branch is processed.
{ tput rc; printf '\033[J'; } > /dev/tty 2>&1
header_text=$(get_header_text)

# Use a FIFO to decouple the data+format pipeline from fzf.
# $() will return as soon as fzf exits — it won't wait for JIRA fetches or sort buffers.
_data_fifo=$(mktemp -u)
mkfifo "$_data_fifo"

{
    # Output header as first line
    echo "$header_text"

        # Stream branch data (and branchless tickets after) through the display formatter.
        # generate_worktree_data runs first for instant worktree rows; generate_branch_data
        # skips those branches. generate_branchless_ticket_data appends unstarted tickets.
        _wt_claimed_file=$(mktemp)
        {
            # Hot micro-cache: output top N rows from previous run immediately, bypassing
            # the sort buffer below. This lets fzf show recent branches before data loads.
            # The format loop deduplicates so these rows won't appear twice.
            # Skip the hot cache when the access log has been updated since the hot cache
            # was written — stale hot cache would show wrong sort order for recently
            # accessed worktrees (the hot cache positions "win" via dedup).
            _hot_cache="$CACHE_DIR/hot_${REFLOG_COUNT}.cache"
            if [[ -f "$_hot_cache" ]]; then
                _hot_ok=true
                if [[ -f "$WORKTREE_ACCESS_LOG" ]]; then
                    _hot_mtime=$(stat -c %Y "$_hot_cache" 2>/dev/null || stat -f %m "$_hot_cache" 2>/dev/null)
                    _log_mtime=$(stat -c %Y "$WORKTREE_ACCESS_LOG" 2>/dev/null || stat -f %m "$WORKTREE_ACCESS_LOG" 2>/dev/null)
                    if [[ -n "$_log_mtime" ]] && [[ -n "$_hot_mtime" ]] && [[ "$_log_mtime" -gt "$_hot_mtime" ]]; then
                        _hot_ok=false
                    fi
                fi
                [[ "$_hot_ok" = true ]] && cat "$_hot_cache"
            fi

            # Worktrees and regular branches are sorted together by checkout/access time.
            # Branchless tickets and remote-only branches are appended after.
            {
                generate_worktree_data "$_wt_claimed_file"
                generate_branch_data "$REFLOG_COUNT" "$_wt_claimed_file"
            } | awk -F'\t' '{
                ts = 0; n = split($5, a, ":")
                if (n >= 2 && a[n] ~ /^[0-9]+$/) ts = a[n]
                print ts "\t" $0
            }' | sort -t$'\t' -k1,1nr | cut -f2-
            if [ -n "$JIRA_EMAIL" ] && [ -n "$JIRA_API_TOKEN" ]; then
                generate_branchless_ticket_data ""
            fi
            generate_remote_only_data
            rm -f "$_wt_claimed_file"
        } |
        # Use │ as delimiter with proper column spacing
        {
        declare -A _seen_branches=()
        # Hoist loop-invariants outside: saves 1 git call + 1 tr call per row
        _current_branch_name=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        _jira_me_lower="${JIRA_ME,,}"
        _format_now_sec=$(date +%s)
        while IFS=$'\t' read -r branch title status author time_info commit_info full_branch assignee wt_indicator wt_path wt_status; do
            # Dedup: hot cache rows appear first; skip when the sort pipeline re-emits them
            if [[ -n "${_seen_branches[$full_branch]+x}" ]]; then continue; fi
            _seen_branches["$full_branch"]=1

            # Skip the current branch early (avoids all formatting work below)
            if [ "$branch" = "$_current_branch_name" ]; then continue; fi

            # Convert timestamp to human-readable format (inline, no subshell)
            if [[ "$time_info" =~ ^(checked|updated):([0-9]+)$ ]]; then
                _ts_prefix="${BASH_REMATCH[1]}"
                _ts_diff=$(( _format_now_sec - BASH_REMATCH[2] ))
                if   (( _ts_diff < 60 ));      then _ts_rel="seconds ago"
                elif (( _ts_diff < 3600 ));    then _ts_m=$((_ts_diff/60));   ((_ts_m==1)) && _ts_rel="1 minute ago"  || _ts_rel="$_ts_m minutes ago"
                elif (( _ts_diff < 86400 ));   then _ts_h=$((_ts_diff/3600)); ((_ts_h==1)) && _ts_rel="1 hour ago"    || _ts_rel="$_ts_h hours ago"
                elif (( _ts_diff < 2592000 )); then _ts_d=$((_ts_diff/86400)); ((_ts_d==1)) && _ts_rel="1 day ago"    || _ts_rel="$_ts_d days ago"
                else                                _ts_mo=$((_ts_diff/2592000)); ((_ts_mo==1)) && _ts_rel="1 month ago" || _ts_rel="$_ts_mo months ago"
                fi
                time_info="${_ts_prefix}: ${_ts_rel}"
            fi

            # Ensure title field is exactly TITLE_MAX_LENGTH characters (no subshell)
            if [ -z "$title" ] || [ "$title" = " " ] || [ "$title" = "<EMPTY>" ]; then
                printf -v display_title "%-${TITLE_MAX_LENGTH}s" ""
            else
                # Truncate if needed (inline, no subshell), then pad to exact width
                if (( ${#title} > TITLE_MAX_LENGTH )); then
                    printf -v display_title "%-${TITLE_MAX_LENGTH}s" "${title:0:$((TITLE_MAX_LENGTH-3))}..."
                else
                    printf -v display_title "%-${TITLE_MAX_LENGTH}s" "$title"
                fi
            fi
            # Format status with color
            if [ -z "$status" ] || [ "$status" = "<EMPTY>" ]; then
                printf -v display_status "%-${STATUS_MAX_LENGTH}s" ""
            else
                display_status="$(format_status "$status")"
            fi
            # Ensure assignee field is exactly 15 characters (no subshell)
            if [ -z "$assignee" ] || [ "$assignee" = "<UNASSIGNED>" ]; then
                printf -v display_assignee "%-15s" ""
            else
                printf -v display_assignee "%-15s" "$assignee"
            fi
            # Check if assigned to me AND branch is authoritative (bash builtins, no fork)
            assignee_lower="${assignee,,}"
            # Extract ticket from branch name using bash regex (no grep/tr/head pipeline)
            ticket_from_branch=""
            if [[ "$branch" =~ (${JIRA_PROJECT}-[0-9]+) ]]; then
                ticket_from_branch="${BASH_REMATCH[1]^^}"
            fi
            branch_upper="${branch^^}"
            is_authoritative=false
            [ "$branch_upper" = "$ticket_from_branch" ] && is_authoritative=true
            
            # Pad branch for display (with star/dot/spaces and worktree indicator)
            # Worktree indicator: ⊙  (clean), ⊙! (dirty), ⊙≠ (mismatch - different branch checked out)
            wt_display=""
            branch_width=$((BRANCH_MAX_LENGTH-2))
            _wt_mismatch_branch=""
            [[ "$wt_indicator" == "WT_MISMATCH:"* ]] && _wt_mismatch_branch="${wt_indicator#WT_MISMATCH:}"
            if [ "$wt_indicator" = "WT" ] || [ -n "$_wt_mismatch_branch" ]; then
                if [ -n "$_wt_mismatch_branch" ]; then
                    wt_display=$(printf ' \033[38;5;214m⊙≠\033[0m ')
                elif [ "$wt_status" = "DIRTY" ]; then
                    wt_display=$(printf ' \033[38;5;250m⊙\033[38;5;214m !\033[0m')
                else
                    wt_display=$(printf ' \033[38;5;250m⊙\033[0m  ')
                fi
                # " ⊙≠ " / " ⊙ !" / " ⊙  " = 4 visual cols each
                wt_visual_width=4

                # Add pane indicators if enabled (based on real-time current directory)
                if [ "$RR_PANE_MGMT_ENABLED" = "true" ] && [ "$PANE_COUNT" -gt 0 ]; then
                    for i in "${!PANE_IDS[@]}"; do
                        pane_current_dir=$(get_pane_current_dir "${PANE_IDS[$i]}")
                        # Check if pane is in this worktree (exact match or subdirectory with / separator)
                        if [ -n "$pane_current_dir" ] && ( [ "$pane_current_dir" = "$wt_path" ] || [[ "$pane_current_dir" == "$wt_path/"* ]] ); then
                            indicator="${PANE_INDICATORS[$i]}"
                            wt_display="${wt_display}$(printf '\033[38;5;114m%s\033[0m' "$indicator")"
                            # Calculate visual width of this indicator (use wc -L)
                            indicator_width=$(echo -n "$indicator" | wc -L)
                            wt_visual_width=$((wt_visual_width + indicator_width))
                        fi
                    done
                fi

                # Calculate branch width: total - star(2) - wt_visual_width
                branch_width=$((BRANCH_MAX_LENGTH - 2 - wt_visual_width))
            fi

            # Truncate branch to correct width (inline, no subshell)
            if (( ${#branch} > branch_width )); then
                branch_display="${branch:0:$((branch_width-3))}..."
            else
                branch_display="$branch"
            fi

            # Detect row type from full_branch prefix
            is_branchless=false
            is_remote=false
            [[ "$full_branch" == TICKET:* ]] && is_branchless=true
            [[ "$full_branch" == REMOTE:* ]] && is_remote=true

            display_branch=""
            if [ "$is_remote" = true ]; then
                # Remote-only branch - dim steel blue with ↑ prefix
                display_branch=$(printf "\033[38;5;67m↑ \033[38;5;67m%-${branch_width}s\033[0m" "$branch_display")
                printf "%s │ \033[38;5;67m%s\033[0m │ %s │ \033[38;5;244m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │ %s │ %s\n" \
                    "$display_branch" "$display_title" "$display_status" "$display_assignee" "$time_info" "$commit_info" "$full_branch" "$title"
            elif [ "$is_branchless" = true ]; then
                # Branchless ticket - use + prefix with green color
                display_branch=$(printf "\033[38;5;71m+ \033[38;5;71m%-${branch_width}s\033[0m" "$branch_display")
                printf "%s │ \033[38;5;71m%s\033[0m │ %s │ \033[38;5;244m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[38;5;241m%-${COMMIT_MAX_LENGTH}s\033[0m │ %s │ %s\n" \
                    "$display_branch" "$display_title" "$display_status" "$display_assignee" "$time_info" "no branch" "$full_branch" "$title"
            elif [ -n "$JIRA_ME" ] && [ "$assignee_lower" = "$_jira_me_lower" ]; then
                if [ "$is_authoritative" = true ]; then
                    # Authoritative branch assigned to me - full star, bright purple
                    display_branch=$(printf "\033[38;5;141m★ %-${branch_width}s\033[0m%s" "$branch_display" "$wt_display")
                    printf "%s │ \033[38;5;141m%s\033[0m │ %s │ \033[38;5;109m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │ %s │ %s\n" \
                        "$display_branch" "$display_title" "$display_status" "$display_assignee" "$time_info" "$commit_info" "$full_branch" "$title"
                else
                    # Variant branch assigned to me - dim dot, grayed purple (103)
                    display_branch=$(printf "\033[38;5;244m· \033[38;5;103m%-${branch_width}s\033[0m%s" "$branch_display" "$wt_display")
                    printf "%s │ \033[38;5;103m%s\033[0m │ %s │ \033[38;5;244m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │ %s │ %s\n" \
                        "$display_branch" "$display_title" "$display_status" "$display_assignee" "$time_info" "$commit_info" "$full_branch" "$title"
                fi
            else
                # Normal formatting with 2-space indent for alignment
                display_branch=$(printf "  \033[38;5;250m%-${branch_width}s\033[0m%s" "$branch_display" "$wt_display")
                printf "%s │ \033[38;5;109m%s\033[0m │ %s │ \033[38;5;244m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%-${COMMIT_MAX_LENGTH}s\033[0m │ %s │ %s\n" \
                    "$display_branch" "$display_title" "$display_status" "$display_assignee" "$time_info" "$commit_info" "$full_branch" "$title"
            fi
        done
        }
} > "$_data_fifo" 2>/dev/null &
_gen_pid=$!

# fzf reads from the FIFO — $() returns the instant fzf exits, without waiting for generators
selected_line=$(
    {
        # Build dynamic pane keybindings
        pane_bindings=""
        if [ "$RR_PANE_MGMT_ENABLED" = "true" ] && [ "$PANE_COUNT" -gt 0 ]; then
            for i in "${!PANE_KEYS[@]}"; do
                key="${PANE_KEYS[$i]}"
                if [ -n "$key" ]; then
                    pane_bindings="$pane_bindings --bind '${key}:execute-silent($SCRIPT_PATH --process-action \"SET_PANE_${i}:{7}\" </dev/null >/dev/null 2>/dev/null &)'"
                fi
            done
            # alt-enter: switch branch (accept) + switch ALL panes synchronously (with visible output)
            pane_bindings="$pane_bindings --bind 'alt-enter:execute-silent(echo \"SET_ALL_PANES:{7}\" > ~/.cache/rr/action)+accept'"
        fi

        eval "fzf --ansi \
            --no-sort \
            --reverse \
            --height=$($FULL_HEIGHT && echo "100%" || echo $((DISPLAY_COUNT + 7))) \
            --bind 'ctrl-d:half-page-down,ctrl-u:half-page-up' \
            --bind \"ctrl-l:reload($0 --generate-more $REFLOG_COUNT${JIRA_ME:+ -m \\\"$JIRA_ME\\\"})\" \
            --bind \"ctrl-r:reload($0 --reload-refresh${JIRA_ME:+ -m \\\"$JIRA_ME\\\"})\" \
            --bind \"f9:reload($0 --reload-normal${JIRA_ME:+ -m \\\"$JIRA_ME\\\"})\" \
            --bind \"?:execute($SCRIPT_PATH --show-help)\" \
            --bind \"f1:execute($SCRIPT_PATH --show-help)\" \
            --bind 'f2:execute-silent(echo \"CREATE_WT:{7}\" > ~/.cache/rr/action)+abort' \
            --bind 'f3:execute-silent(echo \"CREATE_NEW_WT:\" > ~/.cache/rr/action)+abort' \
            $pane_bindings \
            --bind 'f6:execute-silent($SCRIPT_PATH --process-action \"SET_ALL_PANES:{7}\" </dev/null >/dev/null 2>/dev/null &)' \
            --bind 'f7:execute-silent(echo \"SET_ALL_PANES_CURRENT:\" > ~/.cache/rr/action)+abort' \
            --bind 'f8:execute-silent(echo \"REMOVE_WT:{7}\" > ~/.cache/rr/action)+abort' \
            --delimiter='│' \
            --with-nth=1,2,3,4,5,6 \
            --nth=1,2,3,4,8 \
            --tiebreak=begin,length,index \
            --header-lines=2 \
            --preview '$SCRIPT_DIR/rr-preview.sh {}' \
            --preview-window='bottom:4:nohidden:wrap:border-top'"
    } < "$_data_fifo")

# Kill the background data pipeline and clean up — do it in the background so
# navigation is not held up waiting for JIRA fetches or sort buffers to die.
{ kill "$_gen_pid" 2>/dev/null; wait "$_gen_pid" 2>/dev/null; rm -f "$_data_fifo"; } >/dev/null 2>/dev/null &

# Check if user requested a worktree action via keybinding
ACTION_FILE="$CACHE_DIR/action"
if [ -f "$ACTION_FILE" ]; then
    action_line=$(cat "$ACTION_FILE")
    rm -f "$ACTION_FILE"

    # Extract action and branch from the line
    if [[ "$action_line" =~ ^CREATE_WT: ]]; then
        # Extract branch name - it's now the clean full branch name from field 7
        branch=$(echo "$action_line" | sed 's/^CREATE_WT://' | tr -d '\n\r' | sed "s/^[[:space:]'\"]*//;s/[[:space:]'\"]*$//")

        # Handle remote-only branch - ensure local tracking branch exists first
        if [[ "$branch" == REMOTE:* ]]; then
            branch="${branch#REMOTE:}"
            if ! git show-ref --verify --quiet "refs/heads/$branch"; then
                echo "Creating local branch '$branch' tracking 'origin/$branch'..." >&2
                git branch "$branch" "origin/$branch" 2>&1 || {
                    echo "✗ Failed to create local tracking branch" >&2
                    exit 1
                }
            fi
        fi

        # Handle branchless ticket - create new branch from main then worktree
        if [[ "$branch" == TICKET:* ]]; then
            ticket_id="${branch#TICKET:}"
            exec {rr_stdout}>&1
            exec < /dev/tty > /dev/tty 2>&1
            clear
            echo ""
            echo "$(tput setaf 71)+ $(tput sgr0) $(tput dim)Create branch + worktree for ticket ${ticket_id}$(tput sgr0)"
            echo ""

            # Determine base branch
            default_branch="main"
            if ! git show-ref --verify --quiet refs/heads/main; then
                if git show-ref --verify --quiet refs/heads/master; then
                    default_branch="master"
                else
                    echo "✗ Cannot find main/master branch to base new branch on"
                    exit 1
                fi
            fi

            # Build worktree name
            load_jira_caches
            repo_name=$(basename "$GIT_ROOT")
            jira_title=$(get_jira_title "$ticket_id")
            wt_name="$ticket_id"
            if [ -n "$jira_title" ]; then
                sanitized_title=$(sanitize_title_for_path "$jira_title" 40)
                wt_name="$ticket_id-$sanitized_title"
            fi
            wt_path="$GIT_ROOT/../$repo_name.$wt_name"

            echo "Creating branch '$ticket_id' from '$default_branch'..."
            echo "Creating worktree at '$wt_path'..."

            if git worktree add -b "$ticket_id" "$wt_path" "$default_branch" 2>&1; then
                echo "✓ Branch and worktree created successfully!"

                copy_worktree_files "$GIT_ROOT" "$wt_path"

                navigate_to_worktree "$wt_path"
                exit 0
            else
                echo "✗ Failed to create branch and worktree"
                exit 1
            fi
        fi

        if [ -n "$branch" ]; then
            # Check if branch is already checked out somewhere
            current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
            if [ "$branch" = "$current_branch" ]; then
                # User wants to move current work to a worktree
                echo "Moving branch '$branch' from main repo to worktree..."

                # Check for uncommitted changes in current location
                if ! git diff-index --quiet HEAD 2>/dev/null; then
                    echo ""
                    echo "✗ Cannot create worktree: You have uncommitted changes in the current repo"
                    echo ""
                    echo "  Why? Creating a worktree requires switching the main repo to a different branch"
                    echo "       (usually 'main'), which would lose your uncommitted work."
                    echo ""
                    echo "  Fix: Commit or stash your changes first:"
                    echo "       git add . && git commit -m 'wip'"
                    echo "       OR"
                    echo "       git stash"
                    echo ""
                    exit 1
                fi

                # Determine default branch to switch to
                default_branch="main"
                if ! git show-ref --verify --quiet refs/heads/main; then
                    if git show-ref --verify --quiet refs/heads/master; then
                        default_branch="master"
                    else
                        echo "✗ No main/master branch found. Please switch to a different branch first."
                        exit 1
                    fi
                fi

                # Create worktree first (before switching away from branch)
                repo_name=$(basename "$GIT_ROOT")

                # Try to get JIRA title and include it in the path
                ticket=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | head -1)
                wt_name="$branch"
                if [ -n "$ticket" ]; then
                    jira_title=$(get_jira_title "$ticket")
                    if [ -n "$jira_title" ]; then
                        sanitized_title=$(sanitize_title_for_path "$jira_title" 40)
                        wt_name="$branch-$sanitized_title"
                    fi
                fi

                wt_path="$GIT_ROOT/../$repo_name.$wt_name"

                # Switch main repo to default branch
                echo "Switching main repo to '$default_branch'..."
                git switch "$default_branch" 2>&1 || exit 1

                # Now create the worktree
                echo "Creating worktree at '$wt_path'..."
                if git worktree add "$wt_path" "$branch" 2>&1; then
                    echo "✓ Worktree created successfully!"

                    copy_worktree_files "$GIT_ROOT" "$wt_path"

                    navigate_to_worktree "$wt_path"
                    exit 0
                else
                    echo "✗ Failed to create worktree" >&2
                    # Try to switch back to original branch
                    smart_git_switch "$branch" 2>/dev/null
                    exit 1
                fi
            fi

            # Check if branch is checked out in another worktree
            existing_wt=$(git worktree list --porcelain | grep -B2 "^branch refs/heads/$branch$" | grep "^worktree " | cut -d' ' -f2)
            if [ -n "$existing_wt" ]; then
                echo "Branch '$branch' already has a worktree at: $existing_wt"
                echo "Switching to existing worktree..."
                echo "RR_CD:$existing_wt"
                exit 0
            fi

            # Create worktree
            repo_name=$(basename "$GIT_ROOT")

            # Try to get JIRA title and include it in the path
            ticket=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | head -1)
            wt_name="$branch"
            if [ -n "$ticket" ]; then
                jira_title=$(get_jira_title "$ticket")
                if [ -n "$jira_title" ]; then
                    sanitized_title=$(sanitize_title_for_path "$jira_title" 40)
                    wt_name="$branch-$sanitized_title"
                fi
            fi

            wt_path="$GIT_ROOT/../$repo_name.$wt_name"

            echo "Creating worktree for branch '$branch' at '$wt_path'..."
            if git worktree add "$wt_path" "$branch" 2>&1; then
                echo "✓ Worktree created successfully!"

                copy_worktree_files "$GIT_ROOT" "$wt_path"

                navigate_to_worktree "$wt_path"
                exit 0
            else
                echo "✗ Failed to create worktree" >&2
                exit 1
            fi
        fi
    elif [[ "$action_line" =~ ^CREATE_NEW_WT: ]]; then
        # Create a new branch + worktree
        exec {rr_stdout}>&1
        exec < /dev/tty > /dev/tty 2>&1
        clear
        echo ""
        echo "$(tput setaf 141)⊙$(tput sgr0) $(tput dim)Create new branch + worktree$(tput sgr0)"
        read -p "$(tput bold)Branch name:$(tput sgr0) " branch
        echo ""

        # Trim whitespace
        branch=$(echo "$branch" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")

        if [ -z "$branch" ]; then
            echo "✗ No branch name provided, aborting" >&2
            exit 1
        fi

        # Check if branch already exists
        if git show-ref --verify --quiet "refs/heads/$branch"; then
            echo "✗ Branch '$branch' already exists. Use F2 to create a worktree for it." >&2
            exit 1
        fi

        # Capture current HEAD as base point for the new branch
        current_branch=$(git branch --show-current 2>/dev/null)
        current_commit=$(git rev-parse HEAD 2>/dev/null)
        base_point="${current_branch:-$current_commit}"

        # Stash uncommitted changes (including untracked files) so they carry over
        stash_ref=""
        stash_msg="rr-new-wt-$$"
        git stash push -m "$stash_msg" -u --quiet 2>/dev/null
        stash_ref=$(git stash list 2>/dev/null | grep "$stash_msg" | head -1 | cut -d: -f1)
        if [ -n "$stash_ref" ]; then
            echo "✓ Stashed uncommitted changes (will apply in new worktree)"
        fi

        # Create worktree with new branch based on current HEAD
        repo_name=$(basename "$GIT_ROOT")

        # Try to get JIRA title and include it in the path
        ticket=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | head -1)
        wt_name="$branch"
        if [ -n "$ticket" ]; then
            jira_title=$(get_jira_title "$ticket")
            if [ -n "$jira_title" ]; then
                sanitized_title=$(sanitize_title_for_path "$jira_title" 40)
                wt_name="$branch-$sanitized_title"
            fi
        fi

        wt_path="$GIT_ROOT/../$repo_name.$wt_name"

        echo "Creating new branch '$branch' based on '$base_point'..."
        echo "Creating worktree at '$wt_path'..."

        if git worktree add -b "$branch" "$wt_path" "$base_point" 2>&1; then
            echo "✓ Worktree created successfully!"

            # Apply stashed changes in the new worktree
            if [ -n "$stash_ref" ]; then
                echo "Applying uncommitted changes to new worktree..."
                if (cd "$wt_path" && git stash apply "$stash_ref" 2>&1); then
                    git stash drop "$stash_ref" 2>/dev/null
                    echo "✓ Uncommitted changes moved to new worktree"
                else
                    echo "⚠ Could not apply changes cleanly. They remain in stash: $stash_ref" >&2
                fi
            fi

            copy_worktree_files "$GIT_ROOT" "$wt_path"

            navigate_to_worktree "$wt_path"
            exit 0
        else
            # Restore stash if worktree creation failed
            if [ -n "$stash_ref" ]; then
                git stash pop "$stash_ref" 2>/dev/null
            fi
            echo "✗ Failed to create worktree" >&2
            exit 1
        fi
    elif [[ "$action_line" =~ ^REMOVE_WT: ]]; then
        # Extract branch name - it's now the clean full branch name from field 7
        branch=$(echo "$action_line" | sed 's/^REMOVE_WT://' | tr -d '\n\r' | sed "s/^[[:space:]'\"]*//;s/[[:space:]'\"]*$//")

        if [ -n "$branch" ]; then
            # Find worktree path
            wt_path=$(git worktree list --porcelain | grep -B2 "^branch refs/heads/$branch$" | grep "^worktree " | cut -d' ' -f2)

            if [ -n "$wt_path" ] && [ "$wt_path" != "$GIT_ROOT" ]; then
                echo "Removing worktree for branch '$branch' at '$wt_path'..."
                if git worktree remove "$wt_path" 2>&1; then
                    echo "✓ Worktree removed successfully!"
                    exit 0
                else
                    echo "✗ Failed to remove worktree" >&2
                    exit 1
                fi
            else
                echo "✗ Cannot remove main worktree or worktree not found" >&2
                exit 1
            fi
        fi
    elif [[ "$action_line" =~ ^SET_PANE_([0-9]+): ]]; then
        # Generic pane switching - extract pane number
        pane_num="${BASH_REMATCH[1]}"

        # Check if pane management is enabled
        if [ "$RR_PANE_MGMT_ENABLED" != "true" ] || [ "$PANE_COUNT" -eq 0 ]; then
            echo "✗ Pane management is not enabled in .env" >&2
            echo "  Set RR_PANE_MGMT_ENABLED=true and configure RR_PANE_N_* variables" >&2
            exit 1
        fi

        # Check if this pane exists
        if [ -z "${PANE_IDS[$pane_num]}" ]; then
            echo "✗ Pane $pane_num is not configured" >&2
            exit 1
        fi

        # Extract branch name
        branch=$(echo "$action_line" | sed "s/^SET_PANE_${pane_num}://" | tr -d '\n\r' | sed "s/^[[:space:]'\"]*//;s/[[:space:]'\"]*$//")

        if [ -n "$branch" ]; then
            # Use the new helper that handles worktree creation
            if switch_pane_to_branch "$pane_num" "$branch"; then
                exit 0
            else
                result=$?
                [ $result -eq 2 ] && exit 0  # User cancelled
                exit 1
            fi
        fi
    elif [[ "$action_line" =~ ^SET_ALL_PANES: ]]; then
        # Switch all panes to selected branch
        branch=$(echo "$action_line" | sed "s/^SET_ALL_PANES://" | tr -d '\n\r' | sed "s/^[[:space:]'\"]*//;s/[[:space:]'\"]*$//")

        # Strip REMOTE: prefix and create local tracking branch if needed
        if [[ "$branch" == REMOTE:* ]]; then
            branch="${branch#REMOTE:}"
            if ! git show-ref --verify --quiet "refs/heads/$branch"; then
                echo "Creating local branch '$branch' tracking 'origin/$branch'..." >&2
                git branch "$branch" "origin/$branch" 2>&1 || {
                    echo "✗ Failed to create local tracking branch" >&2
                    exit 1
                }
            fi
        fi

        # Check if pane management is enabled
        if [ "$RR_PANE_MGMT_ENABLED" != "true" ] || [ "$PANE_COUNT" -eq 0 ]; then
            echo "✗ Pane management is not enabled in .env" >&2
            echo "  Set RR_PANE_MGMT_ENABLED=true and configure RR_PANE_N_* variables" >&2
            exit 1
        fi

        if [ -n "$branch" ]; then
            echo "Switching ALL panes to branch: $branch" >&2
            echo "" >&2

            # If no worktree exists yet, create it once before looping panes
            wt_check=$(git worktree list --porcelain | grep -B2 "^branch refs/heads/$branch$" | grep "^worktree " | cut -d' ' -f2)
            if [ -z "$wt_check" ]; then
                opt1="● Create worktree for '$branch' and switch all panes"
                opt2="○ Cancel"
                choice=$(printf '%s\n%s\n' "$opt1" "$opt2" | fzf --ansi --height=5 --reverse --header="No worktree for '$branch' — create one?" --header-first 2>/dev/tty)
                if echo "$choice" | grep -q "Create worktree"; then
                    echo "Creating worktree for '$branch'..." >&2
                    if ! create_worktree "$branch"; then
                        echo "✗ Failed to create worktree" >&2
                        exit 1
                    fi
                else
                    exit 0
                fi
            fi

            success_count=0
            fail_count=0
            cancelled=false

            # Loop through all configured panes
            for i in "${!PANE_IDS[@]}"; do
                if switch_pane_to_branch "$i" "$branch"; then
                    ((success_count++))
                else
                    result=$?
                    if [ $result -eq 2 ]; then
                        cancelled=true
                        break
                    fi
                    ((fail_count++))
                fi
            done

            echo "" >&2
            if [ "$cancelled" = true ]; then
                echo "⚠ Pane switching cancelled — switching current shell only" >&2
            elif [ $fail_count -eq 0 ]; then
                echo "✓ Switched $success_count pane(s) to '$branch' — switching current shell too" >&2
            else
                echo "⚠ Switched $success_count pane(s), failed $fail_count — switching current shell too" >&2
            fi
            echo "" >&2
            # Fall through to normal branch switching below
        fi
    elif [[ "$action_line" =~ ^SET_ALL_PANES_CURRENT: ]]; then
        # Switch all panes to current directory/worktree

        # Check if pane management is enabled
        if [ "$RR_PANE_MGMT_ENABLED" != "true" ] || [ "$PANE_COUNT" -eq 0 ]; then
            echo "✗ Pane management is not enabled in .env" >&2
            echo "  Set RR_PANE_MGMT_ENABLED=true and configure RR_PANE_N_* variables" >&2
            exit 1
        fi

        # Get current directory's git toplevel (works for both main repo and worktrees)
        current_wt_path=$(git rev-parse --show-toplevel 2>/dev/null)

        if [ -z "$current_wt_path" ]; then
            echo "✗ Not in a git repository" >&2
            exit 1
        fi

        # Check if this is a worktree (not the main repo)
        if [ "$current_wt_path" = "$GIT_ROOT" ]; then
            # In main repo - get the branch and find/create worktree
            current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

            if [ -z "$current_branch" ] || [ "$current_branch" = "HEAD" ]; then
                echo "✗ Could not determine current branch" >&2
                exit 1
            fi

            echo "In main repo on branch '$current_branch'" >&2
            echo "Switching ALL panes to branch: $current_branch" >&2
            echo "" >&2

            success_count=0
            fail_count=0
            cancelled=false

            # Loop through all configured panes
            for i in "${!PANE_IDS[@]}"; do
                if switch_pane_to_branch "$i" "$current_branch"; then
                    ((success_count++))
                else
                    result=$?
                    if [ $result -eq 2 ]; then
                        cancelled=true
                        break
                    fi
                    ((fail_count++))
                fi
            done

            echo "" >&2
            if [ "$cancelled" = true ]; then
                echo "⚠ Operation cancelled by user" >&2
                exit 0
            elif [ $fail_count -eq 0 ]; then
                echo "✓ Successfully switched $success_count pane(s) to '$current_branch'" >&2
                exit 0
            else
                echo "⚠ Switched $success_count pane(s), failed $fail_count" >&2
                exit 1
            fi
        else
            # In a worktree - switch all panes to this worktree directory
            wt_display=$(basename "$current_wt_path")
            echo "Switching ALL panes to CURRENT worktree: $wt_display" >&2
            echo "" >&2

            success_count=0
            fail_count=0

            # Loop through all configured panes
            for i in "${!PANE_IDS[@]}"; do
                pane_id="${PANE_IDS[$i]}"
                pane_dir="${PANE_DIRS[$i]}"
                pane_cmd="${PANE_COMMANDS[$i]}"
                pane_label="${PANE_LABELS[$i]}"

                echo "Switching $pane_label to: $current_wt_path" >&2
                if switch_pane_target "pane_$i" "$pane_id" "$current_wt_path" "$pane_dir" "$pane_cmd"; then
                    ((success_count++))
                else
                    ((fail_count++))
                fi
            done

            echo "" >&2
            if [ $fail_count -eq 0 ]; then
                echo "✓ Successfully switched $success_count pane(s) to '$wt_display'" >&2
                exit 0
            else
                echo "⚠ Switched $success_count pane(s), failed $fail_count" >&2
                exit 1
            fi
        fi
    fi
fi

# Extract the full branch name from field 7 (hidden in fzf display but always present)
is_remote_selection=false
if [ -n "$selected_line" ]; then
    field7=$(echo "$selected_line" | cut -d'│' -f7 | tr -d '\n\r' | sed "s/^[[:space:]'\"]*//;s/[[:space:]'\"]*$//")

    if [[ "$field7" == TICKET:* ]]; then
        branch="${field7#TICKET:}"
        # Write CREATE_WT action to action file and process it
        mkdir -p "$CACHE_DIR"
        echo "CREATE_WT:TICKET:$branch" > "$CACHE_DIR/action"
        exec "$0"
    elif [[ "$field7" == REMOTE:* ]]; then
        branch="${field7#REMOTE:}"
        is_remote_selection=true
    else
        branch="$field7"
    fi
fi

# Only switch if a branch was selected
if [ -n "$branch" ]; then
    # Check if branch has a worktree
    wt_path=$(get_worktree_path "$branch")

    if [ -n "$wt_path" ]; then
        # Branch has a worktree - cd to it and preserve relative path
        # Get current relative path within git repo
        current_rel_path=$(git rev-parse --show-prefix 2>/dev/null || echo "")

        # Construct target path
        record_worktree_access "$wt_path"
        if [ -n "$current_rel_path" ]; then
            target_path="$wt_path/$current_rel_path"
            # Check if the relative path exists in the target worktree
            if [ -d "$target_path" ]; then
                echo "RR_CD:$target_path"
            else
                navigate_to_worktree "$wt_path"
            fi
        else
            navigate_to_worktree "$wt_path"
        fi
    else
        # No worktree for target branch - need to decide what to do

        # Check if we're in a worktree (not the main repo)
        current_wt_path=$(git rev-parse --show-toplevel 2>/dev/null)
        is_in_worktree=false
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
        expected_branch=""

        # Detect if current location is a worktree (not main repo)
        if [ "$current_wt_path" != "$GIT_ROOT" ]; then
            is_in_worktree=true

            # Extract expected branch from worktree name (e.g., "ul.UB-6380" -> "UB-6380")
            wt_basename=$(basename "$current_wt_path")
            if [[ "$wt_basename" =~ \. ]]; then
                expected_branch="${wt_basename##*.}"
            fi
        fi

        # If switching to the worktree's expected branch, allow it (fixes the worktree)
        # Otherwise, if in a worktree trying to switch to a different branch, ask what to do
        if [ "$is_in_worktree" = true ] && [ "$branch" = "$expected_branch" ]; then
            # Switching to expected branch - allow without prompting (fixes worktree)
            if [ "$is_remote_selection" = true ] && ! git show-ref --verify --quiet "refs/heads/$branch"; then
                echo "Creating local branch '$branch' tracking 'origin/$branch'..." >&2
                smart_git_switch "$branch" "-c" "origin/$branch"
                [ $? -eq 2 ] && exit 0  # If RR_CD was output, exit
            else
                smart_git_switch "$branch"
                [ $? -eq 2 ] && exit 0  # If RR_CD was output, exit
            fi
        elif [ "$is_in_worktree" = true ] && [ "$branch" != "$current_branch" ]; then
            # Check main repo status
            main_repo_clean=true
            main_repo_status=""
            current_pwd="$PWD"
            cd "$GIT_ROOT" 2>/dev/null
            if ! git diff-index --quiet HEAD 2>/dev/null; then
                main_repo_clean=false
                main_repo_status=" \033[38;5;167m✗ has uncommitted changes - must commit/stash first\033[0m"
            fi
            main_repo_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
            cd "$current_pwd" 2>/dev/null

            # 'main' always goes directly to main repo without prompting
            if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
                choice_num="2"
            else
            # Build options with smart styling
            wt_basename=$(basename "$current_wt_path")

            # Option 1: Create new worktree (recommended - bright green)
            opt1=$(echo -e "\033[38;5;114m● Create new worktree for '$branch' and go there\033[0m")

            # Option 2: Go to main repo (conditional based on cleanliness and current branch)
            if [ "$main_repo_branch" = "$branch" ]; then
                # Already on target branch - can always navigate there regardless of dirty state
                if [ "$main_repo_clean" = true ]; then
                    opt2=$(echo -e "○ Go to main repo \033[2m(already on '$branch')\033[0m")
                else
                    opt2=$(echo -e "○ Go to main repo \033[2m(already on '$branch', has uncommitted changes)\033[0m")
                fi
            elif [ "$main_repo_clean" = true ]; then
                opt2=$(echo -e "○ Go to main repo and switch to '$branch' \033[2m(currently on '$main_repo_branch')\033[0m")
            else
                opt2=$(echo -e "\033[2m○ Go to main repo and switch to '$branch' \033[38;5;167m✗ can't switch - main repo has uncommitted changes\033[0m")
            fi

            # Option 3: Switch current worktree (discouraged - dim gray)
            opt3=$(echo -e "\033[2;38;5;244m○ Switch current worktree to '$branch' (breaks naming)\033[0m")

            choice=$(printf '%s\n%s\n%s\n' "$opt1" "$opt2" "$opt3" | fzf --ansi --height=9 --reverse --header="In worktree '$wt_basename' (on '$current_branch') → switching to '$branch'" --header-first)

            # Determine which option was selected based on content
            if echo "$choice" | grep -q "Create new worktree"; then
                choice_num="1"
            elif echo "$choice" | grep -q "Go to main repo"; then
                choice_num="2"
            elif echo "$choice" | grep -q "Switch current worktree"; then
                choice_num="3"
            else
                choice_num=""
            fi
            fi  # end non-main branch prompt

            case "$choice_num" in
                1)
                    # Create new worktree
                    repo_name=$(basename "$GIT_ROOT")

                    # Try to get JIRA title and include it in the path
                    ticket=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | head -1)
                    wt_name="$branch"
                    if [ -n "$ticket" ]; then
                        jira_title=$(get_jira_title "$ticket")
                        if [ -n "$jira_title" ]; then
                            sanitized_title=$(sanitize_title_for_path "$jira_title" 40)
                            wt_name="$branch-$sanitized_title"
                        fi
                    fi

                    new_wt_path="$GIT_ROOT/../$repo_name.$wt_name"

                    echo "Creating worktree for branch '$branch' at '$new_wt_path'..." >&2
                    if git worktree add "$new_wt_path" "$branch" 2>&1; then
                        echo "✓ Worktree created successfully!" >&2

                        copy_worktree_files "$GIT_ROOT" "$new_wt_path"

                        echo "RR_CD:$new_wt_path"
                        exit 0
                    else
                        echo "✗ Failed to create worktree" >&2
                        exit 1
                    fi
                    ;;
                2)
                    # Go to main repo and switch there (if needed)
                    if [ "$main_repo_branch" != "$branch" ]; then
                        if [ "$main_repo_clean" = false ]; then
                            echo ""
                            echo "✗ Cannot switch: The main repo (at $GIT_ROOT) has uncommitted changes" >&2
                            echo ""
                            echo "  Fix: Go to the main repo and commit or stash first:" >&2
                            echo "       cd $GIT_ROOT" >&2
                            echo "       git add . && git commit -m 'wip'  # or: git stash" >&2
                            echo ""
                            exit 1
                        fi
                        echo "RR_SWITCH:$branch" >&2
                    fi
                    echo "RR_CD:$GIT_ROOT"
                    exit 0
                    ;;
                3)
                    # Switch current worktree (original behavior)
                    if [ "$is_remote_selection" = true ] && ! git show-ref --verify --quiet "refs/heads/$branch"; then
                        echo "Creating local branch '$branch' tracking 'origin/$branch'..." >&2
                        smart_git_switch "$branch" "-c" "origin/$branch"
                        [ $? -eq 2 ] && exit 0  # If RR_CD was output, exit
                    else
                        smart_git_switch "$branch"
                        [ $? -eq 2 ] && exit 0  # If RR_CD was output, exit
                    fi
                    ;;
                "")
                    # User cancelled fzf
                    exit 0
                    ;;
                *)
                    echo "Invalid choice, aborting." >&2
                    exit 1
                    ;;
            esac
        else
            # In main repo or other cases - proceed with normal switch
            if [ "$is_remote_selection" = true ] && ! git show-ref --verify --quiet "refs/heads/$branch"; then
                # Remote-only branch - create local tracking branch
                echo "Creating local branch '$branch' tracking 'origin/$branch'..." >&2
                smart_git_switch "$branch" "-c" "origin/$branch"
                [ $? -eq 2 ] && exit 0  # If RR_CD was output, exit
            else
                smart_git_switch "$branch"
                [ $? -eq 2 ] && exit 0  # If RR_CD was output, exit
            fi
        fi
    fi
fi

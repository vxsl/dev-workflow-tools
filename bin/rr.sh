#!/usr/bin/env bash

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
    source "$SCRIPT_DIR/../.env"
fi

# Configuration
REFLOG_COUNT=50
DISPLAY_COUNT=10
SORT_BY_COMMIT=false
SEARCH_ORIGIN=false
JIRA_DOMAIN="${JIRA_DOMAIN}"
JIRA_PROJECT="${JIRA_PROJECT}"
JIRA_ME="${JIRA_ME:-}"  # Your JIRA display name - must match exactly (case-insensitive)

# Validate required environment variables
if [ -z "$JIRA_DOMAIN" ] || [ -z "$JIRA_PROJECT" ]; then
    echo "Error: JIRA_DOMAIN and JIRA_PROJECT must be set in .env or environment" >&2
    exit 1
fi

# Cache directory
CACHE_DIR="$HOME/.cache/rr"
STATE_FILE="$CACHE_DIR/current_mode"

# Ensure we're in a git repository
if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Error: Not in a git repository"
    exit 1
fi

TITLE_MAX_LENGTH=40  # Adjust this value to change title length
BRANCH_MAX_LENGTH=25  # Adjust this value to change branch name length
STATUS_MAX_LENGTH=14  # Adjust this value to change status length

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

# Parse command line arguments
FORCE_REFRESH=false
GENERATE_MORE_MODE=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -c|--commit-sort) SORT_BY_COMMIT=true ;;
        -n|--number) REFLOG_COUNT="$2"; shift ;;
        -r|--refresh) FORCE_REFRESH=true ;;
        -o|--origin) SEARCH_ORIGIN=true ;;
        -m|--me) JIRA_ME="$2"; shift ;;
        --generate-more) 
            # Special mode for fzf reload - increase reflog count to fetch more branches
            shift
            CURRENT_COUNT="$1"
            if [ -z "$CURRENT_COUNT" ]; then
                CURRENT_COUNT=$REFLOG_COUNT
            fi
            
            # Double the reflog count to fetch more branches
            REFLOG_COUNT=$((CURRENT_COUNT * 2))
            
            # Check current mode from state file
            current_mode=$(cat ~/.cache/rr/current_mode 2>/dev/null || echo "local")
            if [ "$current_mode" = "origin" ]; then
                SEARCH_ORIGIN=true
            else
                SEARCH_ORIGIN=false
            fi
            
            GENERATE_MORE_MODE=true
            ;;
        --toggle-origin)
            # Toggle between origin and local mode
            shift
            DISPLAY_COUNT="$1"
            
            if [ -z "$DISPLAY_COUNT" ]; then
                DISPLAY_COUNT=10
            fi
            
            # Read current mode from state file
            current_mode=$(cat "$STATE_FILE" 2>/dev/null || echo "local")
            
            # Toggle based on current mode
            if [ "$current_mode" = "origin" ]; then
                SEARCH_ORIGIN=false
                echo "local" > "$STATE_FILE"
                echo "# Switched to local reflog mode" >&2
            else
                SEARCH_ORIGIN=true
                echo "origin" > "$STATE_FILE"
                echo "# Switched to origin branches mode" >&2
            fi
            GENERATE_MORE_MODE=true
            ;;
        *) echo "Unknown parameter: $1"; 
           echo "Usage: $0 [-c|--commit-sort] [-n|--number LINES] [-r|--refresh] [-o|--origin] [-m|--me NAME]"
           echo "  -c, --commit-sort    Sort by commit date instead of checkout time"
           echo "  -n, --number LINES   Number of reflog entries to process (default: 50)"
           echo "  -r, --refresh        Force refresh cache"
           echo "  -o, --origin         Search remote origin branches instead of reflog"
           echo "  -m, --me NAME        Your JIRA display name to highlight your assigned tickets"
           exit 1 ;;
    esac
    shift
done

# Set cache files based on final REFLOG_COUNT value and search mode
if [ "$SEARCH_ORIGIN" = true ]; then
    CACHE_FILE="$CACHE_DIR/branch_list_${REFLOG_COUNT}_origin.cache"
    REFLOG_CACHE="$CACHE_DIR/reflog_${REFLOG_COUNT}_origin.cache"
else
    CACHE_FILE="$CACHE_DIR/branch_list_${REFLOG_COUNT}.cache"
    REFLOG_CACHE="$CACHE_DIR/reflog_${REFLOG_COUNT}.cache"
fi

# Function to generate branch data for a specific count
generate_branch_data() {
    local count="$1"
    local temp_cache_file
    local temp_reflog_cache
    
    if [ "$SEARCH_ORIGIN" = true ]; then
        temp_cache_file="$CACHE_DIR/branch_list_${count}_origin.cache"
        temp_reflog_cache="$CACHE_DIR/reflog_${count}_origin.cache"
    else
        temp_cache_file="$CACHE_DIR/branch_list_${count}.cache"
        temp_reflog_cache="$CACHE_DIR/reflog_${count}.cache"
    fi
    
    # Check if we have valid cache for this count
    if [[ "$FORCE_REFRESH" == false ]] && [[ -f "$temp_cache_file" ]] && [[ -f "$temp_reflog_cache" ]]; then
        local current_reflog_hash
        current_reflog_hash=$(git reflog -n 20 | sha256sum | cut -d' ' -f1)
        local cached_reflog_hash
        cached_reflog_hash=$(cat "$temp_reflog_cache" 2>/dev/null)
        
        if [[ "$current_reflog_hash" == "$cached_reflog_hash" ]]; then
            cat "$temp_cache_file"
            return
        fi
    fi
    
    # Generate fresh data
    if [ "$SEARCH_ORIGIN" = true ]; then
        # Search remote origin branches - get all available first
        all_branches=$(git for-each-ref --sort='-committerdate' refs/remotes/origin/ \
            --format='%(refname:short)%09%(committerdate:relative)' | 
            sed 's/^origin\///' | 
            grep -v '^HEAD')
        # Only limit if we're not in generate-more mode or if we have fewer branches than requested
        total_available=$(echo "$all_branches" | wc -l)
        if [ "$total_available" -le "$count" ]; then
            branch_list="$all_branches"
        else
            branch_list=$(echo "$all_branches" | head -n "$count")
        fi
    elif [ "$SORT_BY_COMMIT" = true ]; then
        branch_list=$(git for-each-ref --sort='-committerdate' refs/heads/ \
            --format='%(refname:short)%09%(committerdate:relative)' | head -n "$count")
    else
        # Search through more reflog entries to find the requested number of unique branches
        local search_count=$(( count * 10 ))
        if [ $search_count -lt 5000 ]; then
            search_count=5000
        fi
        
        branch_list=$(git reflog -n "$search_count" --date=relative | 
            grep 'checkout: moving' | 
            sed -E 's/^[a-f0-9]+ HEAD@\{([^}]+)\}: checkout: moving from .* to ([^ ]+).*$/\2\t\1/' | 
            awk '!seen[$1]++ { print $0 }' |
            head -n "$count")
    fi
    
    processed_data=$(
        echo "$branch_list" | 
        while read -r branch rest; do
            local ref_path
            if [ "$SEARCH_ORIGIN" = true ]; then
                ref_path="refs/remotes/origin/$branch"
            else
                ref_path="refs/heads/$branch"
            fi
            
            # Skip entries that aren't actual branches (e.g. detached HEAD commits)
            if ! git show-ref --verify --quiet "$ref_path"; then
                continue
            fi
            
            last_commit=$(git log -1 --pretty=format:'%cr' "$ref_path" 2>/dev/null)
            author=$(git log -1 --pretty=format:'%an' "$ref_path" 2>/dev/null | head -c 15)
            # Extract JIRA ticket (case-insensitive) and normalize to uppercase
            ticket=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]')
            jira_title=$(get_jira_title "$ticket")
            jira_status=$(get_jira_status "$ticket")
            jira_assignee=$(get_jira_assignee "$ticket")
            if [ ! -z "$jira_title" ]; then
                title=$(truncate "$jira_title" $TITLE_MAX_LENGTH)
            else
                title="<EMPTY>"
            fi
            if [ -z "$jira_status" ]; then
                jira_status="<EMPTY>"
            fi
            if [ -z "$jira_assignee" ]; then
                jira_assignee="<UNASSIGNED>"
            fi
            
            if [ "$SEARCH_ORIGIN" = true ]; then
                time_info="updated: $rest"
            else
                time_info="checked: $rest"
            fi
            
            truncated_branch=$(truncate "$branch" $BRANCH_MAX_LENGTH)
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
                "$truncated_branch" "$title" "$jira_status" "$author" "$time_info" "committed: $last_commit" "$branch" "$jira_assignee"
        done
    )
    
    # Cache the result
    echo "$processed_data" > "$temp_cache_file"
    git reflog -n 20 | sha256sum | cut -d' ' -f1 > "$temp_reflog_cache"
    
    echo "$processed_data"
}

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed. Please install jq first."
    exit 1
fi

# Function to get JIRA ticket title
get_jira_title() {
    local ticket=$1
    if [[ $ticket =~ ^${JIRA_PROJECT}-[0-9]+$ ]]; then
        local cached_title
        cached_title=$(grep "^$ticket:" ~/.jira_cache 2>/dev/null | cut -d':' -f2-)
        
        if [ -z "$cached_title" ]; then
            local response
            response=$(curl -s -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
                "https://${JIRA_DOMAIN}/rest/api/2/issue/${ticket}" \
                -H "Content-Type: application/json")
            
            if [ $? -eq 0 ]; then
                local title
                title=$(echo "$response" | jq -r '.fields.summary // empty')
                if [ ! -z "$title" ]; then
                    echo "$ticket:$title" >> ~/.jira_cache
                    echo "$title"
                    return
                fi
            fi
        else
            echo "$cached_title"
            return
        fi
    fi
    echo ""
}

# Function to get JIRA ticket status
get_jira_status() {
    local ticket=$1
    if [[ $ticket =~ ^${JIRA_PROJECT}-[0-9]+$ ]]; then
        local cached_status
        cached_status=$(grep "^$ticket:" ~/.jira_status_cache 2>/dev/null | cut -d':' -f2-)
        
        if [ -z "$cached_status" ]; then
            local response
            response=$(curl -s -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
                "https://${JIRA_DOMAIN}/rest/api/2/issue/${ticket}" \
                -H "Content-Type: application/json")
            
            if [ $? -eq 0 ]; then
                local status
                status=$(echo "$response" | jq -r '.fields.status.name // empty')
                if [ ! -z "$status" ]; then
                    echo "$ticket:$status" >> ~/.jira_status_cache
                    echo "$status"
                    return
                fi
            fi
        else
            echo "$cached_status"
            return
        fi
    fi
    echo ""
}

# Function to get JIRA ticket assignee
get_jira_assignee() {
    local ticket=$1
    if [[ $ticket =~ ^${JIRA_PROJECT}-[0-9]+$ ]]; then
        local cached_assignee
        cached_assignee=$(grep "^$ticket:" ~/.jira_assignee_cache 2>/dev/null | cut -d':' -f2-)
        
        if [ -z "$cached_assignee" ]; then
            local response
            response=$(curl -s -u "${JIRA_EMAIL}:${JIRA_API_TOKEN}" \
                "https://${JIRA_DOMAIN}/rest/api/2/issue/${ticket}" \
                -H "Content-Type: application/json")
            
            if [ $? -eq 0 ]; then
                local assignee
                assignee=$(echo "$response" | jq -r '.fields.assignee.displayName // empty')
                if [ ! -z "$assignee" ]; then
                    echo "$ticket:$assignee" >> ~/.jira_assignee_cache
                    echo "$assignee"
                    return
                fi
            fi
        else
            echo "$cached_assignee"
            return
        fi
    fi
    echo ""
}

# Function to format status with color/emoji - returns padded colored string
format_status() {
    local status=$1
    local status_lower=$(echo "$status" | tr '[:upper:]' '[:lower:]')
    local icon color text
    
    case "$status_lower" in
        *"done"*|*"closed"*|*"resolved"*)
            # Mellow green - completed
            icon="✓" color="38;5;114" text="$status"
            ;;
        *"passed qa"*|*"qa passed"*)
            # Mellow cyan - passed QA
            icon="◆" color="38;5;81" text="$status"
            ;;
        *"qa"*|*"testing"*|*"test"*)
            # Mellow blue - in QA/testing
            icon="◇" color="38;5;109" text="$status"
            ;;
        *"progress"*|*"dev"*|*"development"*)
            # Mellow yellow - actively working
            icon="●" color="38;5;221" text="$status"
            ;;
        *"mr"*|*"review"*|*"code review"*|*"pull request"*|*"pr"*)
            # Mellow cyan - merge request/code review
            icon="⬡" color="38;5;81" text="$status"
            ;;
        *"paused"*|*"on hold"*|*"hold"*)
            # Mellow orange - paused work
            icon="◐" color="38;5;173" text="$status"
            ;;
        *"blocked"*|*"impediment"*)
            # Mellow red - blocked
            icon="✗" color="38;5;167" text="$status"
            ;;
        *"todo"*|*"to do"*|*"backlog"*|*"open"*|*"new"*)
            # Light gray - not started
            icon="○" color="38;5;250" text="$status"
            ;;
        *)
            if [ -z "$status" ]; then
                printf "%-${STATUS_MAX_LENGTH}s" ""
                return
            else
                icon="·" color="38;5;244" text="$status"
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

# Cache management functions
ensure_cache_dir() {
    mkdir -p "$CACHE_DIR"
}

is_cache_valid() {
    if [[ ! -f "$CACHE_FILE" ]] || [[ ! -f "$REFLOG_CACHE" ]]; then
        return 1
    fi
    
    # Quick check: use only the last 20 reflog entries for validation (much faster)
    local current_reflog_hash
    current_reflog_hash=$(git reflog -n 20 | sha256sum | cut -d' ' -f1)
    
    # Check if cached reflog hash matches
    local cached_reflog_hash
    cached_reflog_hash=$(cat "$REFLOG_CACHE" 2>/dev/null)
    
    [[ "$current_reflog_hash" == "$cached_reflog_hash" ]]
}

update_cache() {
    local branch_list="$1"
    echo "$branch_list" > "$CACHE_FILE"
    # Use same small sample for cache hash as validation (fast)
    git reflog -n 20 | sha256sum | cut -d' ' -f1 > "$REFLOG_CACHE"
}

get_cached_branches() {
    cat "$CACHE_FILE" 2>/dev/null
}

# Function to generate dynamic header text with colors
get_header_text() {
    # Check current mode from state file or variable
    local current_mode=$(cat "$STATE_FILE" 2>/dev/null || echo "local")
    if [ "$SEARCH_ORIGIN" = true ] || [ "$current_mode" = "origin" ]; then
        # Mellow purple for origin mode
        echo -e "\033[38;5;141m🌐 ORIGIN MODE \033[0m│ \033[2mCtrl+L: more │ Ctrl+O: toggle\033[0m"
    else
        # Mellow blue for local mode
        echo -e "\033[38;5;109m📁 LOCAL MODE  \033[0m│ \033[2mCtrl+L: more │ Ctrl+O: toggle\033[0m"
    fi
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

# Initialize cache
ensure_cache_dir

# Save current mode to state file for toggle functionality
if [ "$SEARCH_ORIGIN" = true ]; then
    echo "origin" > "$STATE_FILE"
else
    echo "local" > "$STATE_FILE"
fi

# Get the processed branch data using the new function
processed_data=$(generate_branch_data "$REFLOG_COUNT")

# If in generate-more mode, just output the formatted data and exit
if [ "$GENERATE_MORE_MODE" = true ]; then
    # Output header as first line
    get_header_text
    
    echo "$processed_data" |
    cut -f1-6,8 |
    while IFS=$'\t' read -r branch title status author time_info commit_info assignee; do
        if [ -z "$title" ] || [ "$title" = " " ] || [ "$title" = "<EMPTY>" ]; then
            display_title="$(printf "%-${TITLE_MAX_LENGTH}s" "")"
        else
            display_title="$(printf "%-${TITLE_MAX_LENGTH}s" "$title")"
        fi
        if [ -z "$status" ] || [ "$status" = "<EMPTY>" ]; then
            display_status="$(printf "%-${STATUS_MAX_LENGTH}s" "")"
        else
            display_status="$(format_status "$status")"
        fi
        if [ -z "$author" ] || [ "$author" = "<unknown>" ]; then
            display_author="$(printf "%-15s" "")"
        else
            display_author="$(printf "%-15s" "$author")"
        fi
        # Check if assigned to me AND branch is authoritative (exact ticket match)
        assignee_lower=$(echo "$assignee" | tr '[:upper:]' '[:lower:]')
        jira_me_lower=$(echo "$JIRA_ME" | tr '[:upper:]' '[:lower:]')
        # Extract ticket from branch name and check if branch IS the ticket (not a variant like -wip, -good)
        ticket_from_branch=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | head -1)
        branch_upper=$(echo "$branch" | tr '[:lower:]' '[:upper:]')
        is_authoritative=false
        [ "$branch_upper" = "$ticket_from_branch" ] && is_authoritative=true
        
        if [ -n "$JIRA_ME" ] && [ "$assignee_lower" = "$jira_me_lower" ]; then
            if [ "$is_authoritative" = true ]; then
                # Authoritative branch assigned to me - full star, bright purple
                printf "\033[38;5;141m★ %-$((BRANCH_MAX_LENGTH-2))s\033[0m │ \033[38;5;141m%s\033[0m │ %s │ \033[38;5;109m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%s\033[0m\n" \
                    "$branch" "$display_title" "$display_status" "$display_author" "$time_info" "$commit_info"
            else
                # Variant branch assigned to me - dim dot, grayed purple (103)
                printf "\033[38;5;244m· \033[38;5;103m%-$((BRANCH_MAX_LENGTH-2))s\033[0m │ \033[38;5;103m%s\033[0m │ %s │ \033[38;5;244m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%s\033[0m\n" \
                    "$branch" "$display_title" "$display_status" "$display_author" "$time_info" "$commit_info"
            fi
        else
            printf "  \033[38;5;250m%-$((BRANCH_MAX_LENGTH-2))s\033[0m │ \033[38;5;109m%s\033[0m │ %s │ \033[38;5;244m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%s\033[0m\n" \
                "$branch" "$display_title" "$display_status" "$display_author" "$time_info" "$commit_info"
        fi
    done
    exit 0
fi

# Show in fzf with clean extraction
selected_line=$(
    {
        # Output header as first line
        get_header_text
        
        echo "$processed_data" |
        # Display columns 1-6 and 8 (hide the full branch name in column 7)
        cut -f1-6,8 |
        # Use │ as delimiter with proper column spacing
        while IFS=$'\t' read -r branch title status author time_info commit_info assignee; do
            # Ensure title field is exactly TITLE_MAX_LENGTH characters  
            if [ -z "$title" ] || [ "$title" = " " ] || [ "$title" = "<EMPTY>" ]; then
                display_title="$(printf "%-${TITLE_MAX_LENGTH}s" "")"
            else
                # Truncate or pad title to exactly TITLE_MAX_LENGTH characters
                display_title="$(printf "%-${TITLE_MAX_LENGTH}s" "$title")"
            fi
            # Format status with color
            if [ -z "$status" ] || [ "$status" = "<EMPTY>" ]; then
                display_status="$(printf "%-${STATUS_MAX_LENGTH}s" "")"
            else
                display_status="$(format_status "$status")"
            fi
            # Ensure author field is exactly 15 characters
            if [ -z "$author" ] || [ "$author" = "<unknown>" ]; then
                display_author="$(printf "%-15s" "")"
            else
                display_author="$(printf "%-15s" "$author")"
            fi
            # Check if assigned to me AND branch is authoritative (exact ticket match)
            assignee_lower=$(echo "$assignee" | tr '[:upper:]' '[:lower:]')
            jira_me_lower=$(echo "$JIRA_ME" | tr '[:upper:]' '[:lower:]')
            # Extract ticket from branch name and check if branch IS the ticket (not a variant like -wip, -good)
            ticket_from_branch=$(echo "$branch" | grep -oi "${JIRA_PROJECT}-[0-9]\+" | tr '[:lower:]' '[:upper:]' | head -1)
            branch_upper=$(echo "$branch" | tr '[:lower:]' '[:upper:]')
            is_authoritative=false
            [ "$branch_upper" = "$ticket_from_branch" ] && is_authoritative=true
            
            if [ -n "$JIRA_ME" ] && [ "$assignee_lower" = "$jira_me_lower" ]; then
                if [ "$is_authoritative" = true ]; then
                    # Authoritative branch assigned to me - full star, bright purple
                    printf "\033[38;5;141m★ %-$((BRANCH_MAX_LENGTH-2))s\033[0m │ \033[38;5;141m%s\033[0m │ %s │ \033[38;5;109m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%s\033[0m\n" \
                        "$branch" "$display_title" "$display_status" "$display_author" "$time_info" "$commit_info"
                else
                    # Variant branch assigned to me - dim dot, grayed purple (103)
                    printf "\033[38;5;244m· \033[38;5;103m%-$((BRANCH_MAX_LENGTH-2))s\033[0m │ \033[38;5;103m%s\033[0m │ %s │ \033[38;5;244m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%s\033[0m\n" \
                        "$branch" "$display_title" "$display_status" "$display_author" "$time_info" "$commit_info"
                fi
            else
                # Normal formatting with 2-space indent for alignment
                printf "  \033[38;5;250m%-$((BRANCH_MAX_LENGTH-2))s\033[0m │ \033[38;5;109m%s\033[0m │ %s │ \033[38;5;244m%s\033[0m │ \033[2;37m%-26s\033[0m │ \033[2;37m%s\033[0m\n" \
                    "$branch" "$display_title" "$display_status" "$display_author" "$time_info" "$commit_info"
            fi
        done
    } |
    fzf --ansi \
        --no-sort \
        --reverse \
        --height=$((DISPLAY_COUNT + 3)) \
        --bind 'ctrl-d:half-page-down,ctrl-u:half-page-up' \
        --bind "ctrl-l:reload($0 --generate-more $REFLOG_COUNT${JIRA_ME:+ -m \"$JIRA_ME\"})" \
        --bind "ctrl-o:reload($0 --toggle-origin $DISPLAY_COUNT${JIRA_ME:+ -m \"$JIRA_ME\"})" \
        --delimiter='│' \
        --nth=1,2,3,4 \
        --header-lines=1
)

# Extract the full branch name by finding the matching line and getting field 7
if [ -n "$selected_line" ]; then
    # Extract the branch name directly from the first field (strip star/dot indicator and whitespace)
    branch=$(echo "$selected_line" | cut -d'│' -f1 | sed 's/^[★·][[:space:]]*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    
    # If the branch name is truncated (ends with ...), we need to find the full name
    if echo "$branch" | grep -q '\.\.\.$'; then
        # Get the truncated name without the ...
        truncated_name=$(echo "$branch" | sed 's/\.\.\.$//')
        
        # Re-read current mode (may have changed during fzf via Ctrl+O toggle)
        current_mode=$(cat "$STATE_FILE" 2>/dev/null || echo "local")
        if [ "$current_mode" = "origin" ]; then
            SEARCH_ORIGIN=true
        else
            SEARCH_ORIGIN=false
        fi
        
        # Regenerate processed_data to match current mode (uses cache if available)
        processed_data=$(generate_branch_data "$REFLOG_COUNT")
        
        # Find the full branch name from processed_data
        branch=$(echo "$processed_data" | cut -f7 | grep "^${truncated_name}" | head -1)
    fi
fi

# Only switch if a branch was selected
if [ -n "$branch" ]; then
    # Check if we're in origin mode by reading the state file
    current_mode=$(cat "$STATE_FILE" 2>/dev/null || echo "local")
    
    if [ "$current_mode" = "origin" ]; then
        # In origin mode - handle remote branches
        if git show-ref --verify --quiet "refs/heads/$branch"; then
            # Local branch exists, just switch to it
            git switch "$branch"
        else
            # Local branch doesn't exist, create it tracking the remote
            echo "Creating local branch '$branch' tracking 'origin/$branch'..."
            git switch -c "$branch" "origin/$branch"
        fi
    else
        # In local mode - normal switch
        git switch "$branch"
    fi
fi

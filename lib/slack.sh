#!/usr/bin/env bash
# Shared Slack helpers for oneshot and publish-changes
#
# Requires callers to have set:
#   $TICKET_CREATOR_BOT_TOKEN   (Slack bot token; functions no-op/skip without it)
#   Color vars: $RED, $GREEN, $YELLOW, $DIM, $RESET
#
# Provides:
#   parse_slack_url <url>             → sets SLACK_CHANNEL / SLACK_THREAD_TS, returns 1 if not a Slack URL
#   verify_slack_channel_access <ch>  → returns 0 if bot can post (or can't be sure), 1 if definitively blocked
#   post_to_slack <ch> <thread_ts> <ticket|mr> <url> <title>
#   save_pending_slack / load_pending_slack / clear_pending_slack — see below

# Prevent multiple loads
if [ -n "$SLACK_LIB_LOADED" ]; then
    return 0
fi
SLACK_LIB_LOADED=1

# ---------------------------------------------------------------------------
# Pending Slack post
#
# The MR is created, pushed, and linked in Jira before anyone is asked where in
# Slack it should go. Everything up to that point is durable — it's on the
# remote — but the answer to "which thread?" lives only in a prompt, and a
# closed terminal or a stray Ctrl-C there takes the MR's only link back to the
# conversation that asked for it with it.
#
# So the outstanding post gets written down before the prompt and cleared once
# it's served, either by posting or by a deliberate skip. What survives is only
# ever an interruption.
#
# Keyed on the worktree root: one unfinished post per checkout, which is as many
# as can be in flight, and it keeps sibling worktrees from stepping on each
# other. The record also carries the HEAD it was written at — see
# load_pending_slack for why that matters.
# ---------------------------------------------------------------------------

PENDING_SLACK_DIR="${PENDING_SLACK_DIR:-$HOME/.cache/publish-changes/pending-slack}"

pending_slack_file() {
    local repo_root
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    printf '%s/%s.json\n' "$PENDING_SLACK_DIR" "$(printf '%s' "$repo_root" | sed 's|/|_|g')"
}

# save_pending_slack <branch> <mr_url> <mr_title> <ticket_key> <ticket_summary>
#                    <post_ticket_link> [slack_url]
#
# post_ticket_link records whether the ticket link is still owed to the thread
# too. oneshot posts it itself when it knew the destination up front, so this is
# true only when the destination arrives late, at the prompt below.
save_pending_slack() {
    local file
    file=$(pending_slack_file) || return 1
    mkdir -p "$(dirname "$file")"
    jq -n \
        --arg branch "$1" \
        --arg head_sha "$(git rev-parse HEAD 2>/dev/null)" \
        --arg mr_url "$2" \
        --arg mr_title "$3" \
        --arg ticket_key "$4" \
        --arg ticket_summary "$5" \
        --arg post_ticket_link "$6" \
        --arg slack_url "${7:-}" \
        '{branch: $branch, head_sha: $head_sha, mr_url: $mr_url, mr_title: $mr_title,
          ticket_key: $ticket_key, ticket_summary: $ticket_summary,
          post_ticket_link: $post_ticket_link, slack_url: $slack_url,
          timestamp: now | todate}' > "$file"
}

# load_pending_slack <branch> → prints the record, or returns 1 if none applies.
#
# A record only applies to the branch it was written for, at the commit it was
# written at. A moved HEAD means there's work the MR hasn't seen yet, so the
# caller should run its normal flow — push included — rather than treat the MR
# as finished and jump to the prompt. The record isn't discarded on a mismatch;
# the normal flow ends at the same prompt and will clear it there.
load_pending_slack() {
    local file record
    file=$(pending_slack_file) || return 1
    [ -f "$file" ] || return 1
    record=$(cat "$file" 2>/dev/null) || return 1

    [ "$(printf '%s' "$record" | jq -r '.branch // empty' 2>/dev/null)" = "$1" ] || return 1
    [ "$(printf '%s' "$record" | jq -r '.head_sha // empty' 2>/dev/null)" = "$(git rev-parse HEAD 2>/dev/null)" ] || return 1

    printf '%s\n' "$record"
}

clear_pending_slack() {
    local file
    file=$(pending_slack_file) || return 0
    rm -f "$file"
}

# Escape text for Slack mrkdwn. Slack treats &, <, > as control characters
# (entity/link delimiters), so any human-supplied text — ticket titles, names —
# must HTML-entity-escape them, or a literal '<' (e.g. "TROI < 2 weeks") will
# corrupt the surrounding <url|text> link. Apply ONLY to interpolated text,
# never to the link structure itself.
# See https://api.slack.com/reference/surfaces/formatting#escaping
# sed (not bash ${//}) because bash 5.2's patsub_replacement treats a bare '&'
# in the replacement as the matched text; sed's '\&' is a portable literal '&'.
# Order matters: escape '&' first so the entities we add aren't re-escaped.
slack_escape() {
    printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# Parse a Slack URL into SLACK_CHANNEL and SLACK_THREAD_TS (global).
# Handles thread (/archives/CHANNEL/pTIMESTAMP), channel (/archives/CHANNEL),
# and client (/client/WORKSPACE/CHANNEL) URLs. Returns 1 for unrecognized URLs.
parse_slack_url() {
    local url="$1"
    if [[ "$url" =~ ^https://.*slack\.com/archives/([A-Z0-9]+)/p([0-9]+) ]]; then
        SLACK_CHANNEL=${BASH_REMATCH[1]}
        # Convert p1234567890123456 to 1234567890.123456 format
        local raw_ts=${BASH_REMATCH[2]}
        SLACK_THREAD_TS="${raw_ts:0:10}.${raw_ts:10}"
    elif [[ "$url" =~ ^https://.*slack\.com/archives/([A-Z0-9]+)/?$ ]]; then
        SLACK_CHANNEL=${BASH_REMATCH[1]}
        SLACK_THREAD_TS=""
    elif [[ "$url" =~ ^https://.*slack\.com/client/[A-Z0-9]+/([A-Z0-9]+) ]]; then
        SLACK_CHANNEL=${BASH_REMATCH[1]}
        SLACK_THREAD_TS=""
    else
        return 1
    fi
    return 0
}

# Verify Slack bot has access to channel
verify_slack_channel_access() {
    local channel="$1"

    if [ -z "$TICKET_CREATOR_BOT_TOKEN" ]; then
        return 0  # Skip if no token
    fi

    echo -e "  ${DIM}Verifying bot channel access...${RESET}" >&2

    # Try conversations.info - if we get not_in_channel error, we know for sure bot isn't there
    local response
    response=$(curl -s -G "https://slack.com/api/conversations.info" \
        -H "Authorization: Bearer ${TICKET_CREATOR_BOT_TOKEN}" \
        --data-urlencode "channel=${channel}")

    if echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
        # API call succeeded, but check if bot is actually a member
        local is_member=$(echo "$response" | jq -r '.channel.is_member // false')
        if [ "$is_member" = "true" ]; then
            echo -e "  ${GREEN}✓${RESET} Bot has channel access" >&2
            return 0
        else
            echo -e "  ${RED}✗ Bot is not a member of the channel${RESET}" >&2
            echo -e "  ${DIM}Add the bot to the channel with: /invite -> \"Add apps to this channel\"${RESET}" >&2
            return 1
        fi
    else
        local error=$(echo "$response" | jq -r '.error // "unknown error"')

        # Only fail on definitive "not in channel" errors
        case "$error" in
            not_in_channel|channel_not_found)
                echo -e "  ${RED}✗ Bot cannot access channel: ${error}${RESET}" >&2
                echo -e "  ${DIM}Add the bot to the channel with: /invite -> \"Add apps to this channel\"${RESET}" >&2
                return 1
                ;;
            missing_scope)
                # Bot token lacks scope to check membership, but that doesn't mean it can't post
                echo -e "  ${YELLOW}⚠ Cannot verify channel access (missing scope), continuing anyway${RESET}" >&2
                echo -e "  ${DIM}If posting fails later, add the bot with: /invite -> \"Add apps to this channel\"${RESET}" >&2
                return 0
                ;;
            invalid_auth|token_revoked|account_inactive)
                echo -e "  ${RED}✗ Bot token error: ${error}${RESET}" >&2
                echo -e "  ${DIM}Check TICKET_CREATOR_BOT_TOKEN${RESET}" >&2
                return 1
                ;;
            *)
                # Unknown error - warn but don't block
                echo -e "  ${YELLOW}⚠ Could not verify channel access: ${error}${RESET}" >&2
                echo -e "  ${DIM}Continuing anyway${RESET}" >&2
                return 0
                ;;
        esac
    fi
}

# Post message to Slack thread/channel
post_to_slack() {
    local channel="$1"
    local thread_ts="$2"
    local message_type="$3"  # "ticket" or "mr"
    local url="$4"
    local title="$5"

    if [ -z "$TICKET_CREATOR_BOT_TOKEN" ]; then
        echo -e "  ${YELLOW}⚠ TICKET_CREATOR_BOT_TOKEN not set, skipping Slack post${RESET}" >&2
        return 1
    fi

    # Escape human text so literal &, <, > don't corrupt the mrkdwn link.
    title=$(slack_escape "$title")

    local text
    case "$message_type" in
        ticket)
            # Neutral wording: the ticket may be newly created OR pre-existing
            # (e.g. oneshot run against an existing ticket), so don't claim it
            # "was created". Mirrors the author voice of the mr message below.
            local author_first=$(git config user.name 2>/dev/null | cut -d' ' -f1)
            local author=$(slack_escape "${author_first:-Someone}")
            if [ -n "$thread_ts" ]; then
                text=":jira: ${author} linked a ticket to this thread: <${url}|${title}>"
            else
                text=":jira: ${author} linked a ticket: <${url}|${title}>"
            fi
            ;;
        mr)
            local mr_num=$(echo "$url" | grep -oE '[0-9]+$')
            local author_first=$(git config user.name 2>/dev/null | cut -d' ' -f1)
            local author=$(slack_escape "${author_first:-Someone}")
            if [ -n "$thread_ts" ]; then
                text=":gitlab: ${author} posted an MR related to this thread: <${url}|!${mr_num} — ${title}>"
            else
                text=":gitlab: ${author} posted an MR: <${url}|!${mr_num} — ${title}>"
            fi
            ;;
        *)
            text="$url"
            ;;
    esac

    local payload
    if [ -n "$thread_ts" ]; then
        payload=$(jq -n \
            --arg channel "$channel" \
            --arg thread_ts "$thread_ts" \
            --arg text "$text" \
            '{channel: $channel, thread_ts: $thread_ts, text: $text, unfurl_links: true, mrkdwn: true}')
    else
        payload=$(jq -n \
            --arg channel "$channel" \
            --arg text "$text" \
            '{channel: $channel, text: $text, unfurl_links: true, mrkdwn: true}')
    fi

    local response
    response=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
        -H "Authorization: Bearer ${TICKET_CREATOR_BOT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload")

    if echo "$response" | jq -e '.ok == true' >/dev/null 2>&1; then
        return 0
    else
        local error=$(echo "$response" | jq -r '.error // "unknown error"')
        echo -e "  ${RED}✗ Slack API error: ${error}${RESET}" >&2
        return 1
    fi
}

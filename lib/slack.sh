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

# Prevent multiple loads
if [ -n "$SLACK_LIB_LOADED" ]; then
    return 0
fi
SLACK_LIB_LOADED=1

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

    local text
    case "$message_type" in
        ticket)
            text=$':jira: A ticket was created referencing this thread: '"<${url}|${title}>"
            ;;
        mr)
            local mr_num=$(echo "$url" | grep -oE '[0-9]+$')
            local author_first=$(git config user.name 2>/dev/null | cut -d' ' -f1)
            local author="${author_first:-Someone}"
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

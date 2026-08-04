#!/usr/bin/env bats

# Regression tests for the two ways rr silently lost Jira data.
#
# 1. Ticket extraction used "${JIRA_PROJECT_REGEX}-[0-9]\+". Under `grep -E`,
#    "\+" is a literal plus, not a quantifier, so no branch name ever matched.
#    Every branch row showed <EMPTY> / <UNASSIGNED>, and the branch-vs-branchless
#    dedup never fired.
#
# 2. The all-active-tickets request pasted a JQL string containing quotes
#    (updated >= "-180d") straight into a hand-written JSON body. Jira rejected
#    the request as malformed JSON, so the only tickets rr could ever show were
#    your own — searching for a colleague's name found nothing.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    JIRA_PROJECT_REGEX="(UB|UL|DE)"
}

# --- 1. ticket extraction -------------------------------------------------

extract_ticket() {
    echo "$1" | grep -oiE "${JIRA_PROJECT_REGEX}-[0-9]+" | tr '[:lower:]' '[:upper:]' | head -1
}

@test "ticket extraction: a bare ticket branch" {
    [ "$(extract_ticket "UL-1744")" = "UL-1744" ]
}

@test "ticket extraction: a ticket branch with a title suffix" {
    [ "$(extract_ticket "UL-1744-aoi-filter-shows-unfiltered-points")" = "UL-1744" ]
}

@test "ticket extraction: a prefixed branch" {
    [ "$(extract_ticket "feature/UB-7004-batch-update")" = "UB-7004" ]
}

@test "ticket extraction: lowercase is normalised to uppercase" {
    [ "$(extract_ticket "ub-7006-investigate")" = "UB-7006" ]
}

@test "ticket extraction: every configured project key is recognised" {
    [ "$(extract_ticket "DE-42")" = "DE-42" ]
}

@test "ticket extraction: a branch with no ticket yields nothing" {
    [ -z "$(extract_ticket "hotfix/missing-import")" ]
}

@test "ticket extraction: an unconfigured project key yields nothing" {
    [ -z "$(extract_ticket "ZZ-1234-not-our-board")" ]
}

@test "rr.sh never uses the ERE-literal '\\+' quantifier for ticket extraction" {
    # This is the shape of bug 1. If it reappears, every branch row loses its
    # title, status and assignee — a failure that is invisible unless you know
    # the ticket data should have been there.
    run grep -n '\[0-9\]\\+' "$REPO_ROOT/bin/rr.sh" "$REPO_ROOT/bin/rr-preview.sh"
    [ "$status" -ne 0 ]
}

# --- 2. JQL request body --------------------------------------------------

# Build a request body the way _jira_search_jql does.
jql_body() {
    local jql="$1" token="${2:-}"
    jq -nc --arg jql "$jql" --arg token "$token" \
        '{jql: $jql, maxResults: 100,
          fields: ["summary", "status", "assignee", "updated"]}
         + (if $token == "" then {} else {nextPageToken: $token} end)'
}

@test "jql body: a quoted relative date survives as valid JSON" {
    body=$(jql_body 'project IN (UB, UL) AND updated >= "-180d" ORDER BY updated DESC')
    echo "$body" | jq -e . >/dev/null
    [ "$(echo "$body" | jq -r .jql)" = 'project IN (UB, UL) AND updated >= "-180d" ORDER BY updated DESC' ]
}

@test "jql body: the quotes reach Jira rather than being stripped" {
    body=$(jql_body 'updated >= "-180d"')
    [[ "$(echo "$body" | jq -r .jql)" == *'"-180d"'* ]]
}

@test "jql body: maxResults and fields are set" {
    body=$(jql_body 'project = UB')
    [ "$(echo "$body" | jq -r .maxResults)" = "100" ]
    [ "$(echo "$body" | jq -r '.fields | join(",")')" = "summary,status,assignee,updated" ]
}

@test "jql body: no page token on the first page" {
    body=$(jql_body 'project = UB')
    [ "$(echo "$body" | jq -r 'has("nextPageToken")')" = "false" ]
}

@test "jql body: a page token is carried through when following pagination" {
    body=$(jql_body 'project = UB' 'CkxvbmcmT1JERVJ=')
    [ "$(echo "$body" | jq -r .nextPageToken)" = "CkxvbmcmT1JERVJ=" ]
}

@test "rr.sh builds its search bodies with jq, not string interpolation" {
    # This is the shape of bug 2. A -d "{\"jql\":\"${jql}\"...}" body breaks the
    # instant the JQL contains a quote, and the only symptom is an empty list.
    run grep -n 'd "{\\"jql\\"' "$REPO_ROOT/bin/rr.sh"
    [ "$status" -ne 0 ]
}

@test "rr.sh routes both ticket fetchers through the shared search helper" {
    run grep -c '_jira_search_jql "\$jql"' "$REPO_ROOT/bin/rr.sh"
    [ "$output" = "2" ]
}

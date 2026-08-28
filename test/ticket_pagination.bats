#!/usr/bin/env bats

# Regression tests for the three ways the ticket picker silently lost tickets.
#
# Symptom: UB-5683 existed, was DONE, and could not be selected in oneshot's
# ticket step. It was absent from the list, and typing its number found nothing.
#
# 1. Pagination checked '.isLast // true'. jq's // treats false as absent, so
#    "isLast: false" — the API saying "more pages follow" — evaluated to true
#    and the loop broke after page 0. The cache was capped at 100 tickets
#    forever, despite max_pages=10 intending 1000.
#
# 2. Once pagination actually ran, the accumulator blew up: the result set was
#    handed to jq as a command-line argument via --argjson, which is E2BIG
#    ("Argument list too long") somewhere past the second page. This bug was
#    latent the whole time — bug 1 kept the set small enough to squeak through,
#    so fixing 1 alone left the cache empty.
#
# 3. The type-to-search fallback searched 'text ~ "query*"'. Jira's text index
#    does not cover issue keys, so typing a ticket number could never surface
#    the ticket you named — the one search you are most certain about was the
#    one that could not work.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    JIRA_FZF="$REPO_ROOT/bin/jira-fzf"
    JIRA_PROJECT_LIST=(UL UB DE)
}

# --- 1. isLast --------------------------------------------------------------

# The expression get_all_tickets uses to decide whether to stop paginating.
is_last() {
    printf '%s' "$1" | jq -r 'if has("isLast") then (.isLast | tostring) else "true" end'
}

@test "isLast: 'more pages follow' does not read as 'last page'" {
    # The whole bug in one assertion.
    [ "$(is_last '{"isLast": false}')" = "false" ]
}

@test "isLast: the last page stops the loop" {
    [ "$(is_last '{"isLast": true}')" = "true" ]
}

@test "isLast: an absent key stops the loop" {
    # Conservative default: an API that stops reporting isLast must not make us
    # page forever.
    [ "$(is_last '{}')" = "true" ]
}

@test "isLast: the '// true' form is what collapsed false into true" {
    # Documents why the obvious-looking expression was wrong, so nobody
    # "simplifies" it back.
    [ "$(printf '%s' '{"isLast": false}' | jq -r '.isLast // true')" = "true" ]
}

@test "jira-fzf never uses the '// true' default on isLast" {
    # Comments are stripped first: the fix is documented in a comment that
    # names the broken expression, and that must not read as the bug itself.
    run bash -c "grep -vE '^[[:space:]]*#' '$JIRA_FZF' | grep -n 'isLast // true'"
    [ "$status" -ne 0 ]
}

# --- 2. accumulating pages --------------------------------------------------

@test "jira-fzf does not pass the accumulated result set through argv" {
    # --argjson puts the whole set on the command line. At 1000 tickets that is
    # E2BIG, and the only symptom is a zero-byte cache file.
    run bash -c "grep -vE '^[[:space:]]*#' '$JIRA_FZF' | grep -n 'argjson issues'"
    [ "$status" -ne 0 ]
}

@test "page accumulation survives a result set that would overflow argv" {
    # Build a payload comfortably past the kernel's single-argument ceiling
    # (MAX_ARG_STRLEN, 32 pages — 512K here on 16K pages) and push it through
    # the file-based accumulator the way get_all_tickets now does.
    pages_file="$BATS_TEST_TMPDIR/pages"
    : > "$pages_file"

    for page in 1 2 3 4 5 6 7 8 9 10; do
        jq -nc --arg page "$page" '{issues: [range(100) | {
            key: ("UL-" + ($page + "000") + (. | tostring)),
            fields: {summary: ("padding " + ("x" * 4000))}
        }]}' | jq -c '.issues[]' >> "$pages_file"
    done

    cache_tmp="$BATS_TEST_TMPDIR/tickets.json"
    jq -s '{issues: .}' < "$pages_file" > "$cache_tmp"

    [ "$(jq -r '.issues | length' "$cache_tmp")" = "1000" ]
    # And confirm the old shape really would have failed on this input.
    run jq -n --argjson issues "$(jq -s '.' < "$pages_file")" '{issues: $issues}'
    [ "$status" -ne 0 ]
}

@test "a fetch that comes back empty does not replace a good cache" {
    cache="$BATS_TEST_TMPDIR/tickets.json"
    printf '%s' '{"issues":[{"key":"UL-1"}]}' > "$cache"

    pages_file="$BATS_TEST_TMPDIR/empty"
    : > "$pages_file"

    cache_tmp="${cache}.$$"
    if jq -s '{issues: .}' < "$pages_file" > "$cache_tmp" 2>/dev/null \
        && [ "$(jq -r '.issues | length' "$cache_tmp" 2>/dev/null || echo 0)" -gt 0 ]; then
        mv -f "$cache_tmp" "$cache"
    else
        rm -f "$cache_tmp"
    fi

    [ "$(jq -r '.issues[0].key' "$cache")" = "UL-1" ]
    [ ! -f "$cache_tmp" ]
}

# --- 3. finding a ticket by key ---------------------------------------------

# The candidate-key logic from lookup_tickets_by_key.
key_candidates() {
    local query="$1"
    local -a keys=()

    if [[ "$query" =~ ^[0-9]+$ ]]; then
        local proj
        for proj in "${JIRA_PROJECT_LIST[@]}"; do
            keys+=("${proj}-${query}")
        done
    elif [[ "$query" =~ ^[A-Za-z]+-[0-9]+$ ]]; then
        keys+=("$(echo "$query" | tr '[:lower:]' '[:upper:]')")
    fi

    [ ${#keys[@]} -eq 0 ] && return 0
    printf '%s\n' "${keys[@]}"
}

@test "key lookup: a bare number is tried against every configured board" {
    [ "$(key_candidates 5683 | tr '\n' ' ')" = "UL-5683 UB-5683 DE-5683 " ]
}

@test "key lookup: a full key is used as given" {
    [ "$(key_candidates UB-5683)" = "UB-5683" ]
}

@test "key lookup: a lowercase key is normalised" {
    [ "$(key_candidates ub-5683)" = "UB-5683" ]
}

@test "key lookup: an ordinary text query produces no key fetches" {
    [ -z "$(key_candidates 'code splitting')" ]
}

@test "key lookup: a partial key is not guessed at" {
    [ -z "$(key_candidates 'UB-')" ]
}

@test "search_tickets_by_query consults the key lookup" {
    # text ~ cannot match an issue key, so the key path is the only thing that
    # makes a ticket number searchable. If this call goes away, the symptom is
    # a picker that shrugs at the one query you are sure about.
    run grep -n 'key_results=$(lookup_tickets_by_key' "$JIRA_FZF"
    [ "$status" -eq 0 ]
}

@test "search_tickets_by_query still returns key hits when text search fails" {
    run grep -A2 'Text search failed' "$JIRA_FZF"
    [ "$status" -eq 0 ]
    [[ "$output" == *'echo "$key_results"'* ]]
}

# --- merging key hits with text hits ----------------------------------------

merge_results() {
    printf '%s\n%s\n' "$1" "$2" | jq -s '
        [.[0].issues[], .[1].issues[]] as $all |
        {issues: (reduce $all[] as $i ([];
            if any(.[]; .key == $i.key) then . else . + [$i] end))}
    '
}

@test "merge: the exact key match is listed first" {
    out=$(merge_results \
        '{"issues":[{"key":"UB-5683"}]}' \
        '{"issues":[{"key":"UL-1200"},{"key":"UL-1300"}]}')
    [ "$(printf '%s' "$out" | jq -r '.issues[0].key')" = "UB-5683" ]
}

@test "merge: a ticket found both ways appears once" {
    out=$(merge_results \
        '{"issues":[{"key":"UB-5683"}]}' \
        '{"issues":[{"key":"UB-5683"},{"key":"UL-1200"}]}')
    [ "$(printf '%s' "$out" | jq -r '.issues | length')" = "2" ]
    [ "$(printf '%s' "$out" | jq -r '.issues[0].key')" = "UB-5683" ]
}

@test "merge: unique_by is not used, because it would re-sort the key hit away" {
    # unique_by(.key) sorts by key. "UB-5683" would sort behind "DE-*" and
    # ahead of "UL-*" on alphabet, not relevance — burying the exact match.
    sorted=$(printf '%s' '[{"key":"UB-5683"},{"key":"DE-1"}]' | jq -r 'unique_by(.key)[0].key')
    [ "$sorted" = "DE-1" ]

    out=$(merge_results '{"issues":[{"key":"UB-5683"}]}' '{"issues":[{"key":"DE-1"}]}')
    [ "$(printf '%s' "$out" | jq -r '.issues[0].key')" = "UB-5683" ]
}

@test "merge: no text hits still yields the key hit" {
    out=$(merge_results '{"issues":[{"key":"UB-5683"}]}' '{"issues":[]}')
    [ "$(printf '%s' "$out" | jq -r '.issues | length')" = "1" ]
}

@test "merge: no key hit leaves the text results untouched" {
    out=$(merge_results '{"issues":[]}' '{"issues":[{"key":"UL-1200"},{"key":"UL-1300"}]}')
    [ "$(printf '%s' "$out" | jq -r '[.issues[].key] | join(",")')" = "UL-1200,UL-1300" ]
}

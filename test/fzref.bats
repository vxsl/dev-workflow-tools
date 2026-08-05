#!/usr/bin/env bats
# bin/fzref — the ref picker behind Ctrl+B and the contextual Tab.
#
# What is worth testing here is not "does it list branches" but the two ways this tool can
# be wrong while still looking completely fine:
#
#   1. Field drift. Rows are TSV with several fields that are legitimately empty (a branch
#      with no worktree, no upstream and no ticket has three in a row), and `read` collapses
#      runs of tab because tab is IFS whitespace. That bug shifts the *ticket* into the
#      *branch* column, and the picker then confidently hands `git rebase` the wrong ref.
#      It cannot be spotted by looking at the list; only by reading a row.
#   2. Alignment shear. Every row is padded by hand against a fixed column budget, and a
#      cell that renders one visual column wider than it counts skews every row below it.
#
# The Tab-context half lives in shell/dev-workflow.zsh and is zsh, so it is exercised by
# test/fzref_context.zsh rather than from here.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    load "$REPO_ROOT/test/test_helper/common.bash"
    FZREF="$REPO_ROOT/bin/fzref"

    setup_git_repo

    # Our own .env, not the developer's: fzref sources it with `set -a`, so exporting
    # JIRA_PROJECTS from here would simply be overwritten.
    FZREF_ENV_FILE="$TEST_TMPDIR/env"
    cat > "$FZREF_ENV_FILE" <<'EOF'
JIRA_PROJECTS="TEST,OTHER"
EOF
    export FZREF_ENV_FILE

    export FZREF_JIRA_TITLES="$TEST_TMPDIR/jira_titles"
    export FZREF_JIRA_STATUSES="$TEST_TMPDIR/jira_statuses"
    : > "$FZREF_JIRA_TITLES"
    : > "$FZREF_JIRA_STATUSES"

    export WTA_LOG="$TEST_TMPDIR/worktree_access.log"
    : > "$WTA_LOG"
}

teardown() {
    cd /
    teardown_temp_dir
}

# Field numbers in --list output, so a layout change breaks in one place.
F_SORT=1; F_KIND=2; F_WTKEY=3; F_BRANCH=4; F_REMOTE=5
F_WTPATH=6; F_TICKET=7; F_DESC=8; F_STATUS=9; F_AGE=10; F_HERE=11

field() { # field N <<< row
    awk -F'\t' -v n="$1" '{ print $n }'
}
row_for() { # row_for BRANCH  (reads --list on stdin)
    awk -F'\t' -v b="$2" '$4 == b { print; exit }'
}

# ============================================================================
# Field integrity — the tab-collapse class of bug
# ============================================================================

@test "every row has exactly the expected number of fields" {
    create_branch_at_time feature-a 1700000000
    create_branch_at_time feature-b 1700000100
    cd "$TEST_GIT_REPO"

    run bash -c "'$FZREF' --list | awk -F'\t' 'NF != 11 { bad++ } END { print bad + 0 }'"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "a branch with no worktree, no upstream and no ticket keeps its columns aligned" {
    # Three empty fields in a row is exactly the shape that collapsed. The branch name has
    # to stay in the branch field and the empties have to stay empty.
    create_branch_at_time plain-branch 1700000000
    cd "$TEST_GIT_REPO"

    local row
    row=$("$FZREF" --list | awk -F'\t' '$4 == "plain-branch" { print; exit }')
    [ -n "$row" ]
    [ "$(printf '%s' "$row" | field $F_BRANCH)" = "plain-branch" ]
    [ -z "$(printf '%s' "$row" | field $F_REMOTE)" ]
    [ -z "$(printf '%s' "$row" | field $F_WTPATH)" ]
    [ -z "$(printf '%s' "$row" | field $F_TICKET)" ]
    # The commit subject is the fallback description, and it must be in the DESC field and
    # not one column to the left.
    [ "$(printf '%s' "$row" | field $F_DESC)" = "commit on plain-branch" ]
}

@test "the accept keys resolve off the right fields for a row with every field populated" {
    create_jira_cache "$FZREF_JIRA_TITLES" "TEST-100" "do the thing"
    create_branch_at_time TEST-100 1700000000
    local wt; wt=$(create_worktree TEST-100)
    cd "$TEST_GIT_REPO"

    local stub="$TEST_TMPDIR/fakefzf"
    cat > "$stub" <<'EOF'
#!/usr/bin/env bash
rows=$(cat)
printf '%s\n' "${FAKE_KEY:-}"
printf '%s\n' "$rows" | grep -m1 -F "	${FAKE_ROW}	"
EOF
    chmod +x "$stub"
    export FZP_FZF="$stub" FAKE_ROW="TEST-100"

    FAKE_KEY=""          run "$FZREF"; [ "$output" = "TEST-100" ]
    FAKE_KEY="ctrl-t"    run "$FZREF"; [ "$output" = "TEST-100" ]
    FAKE_KEY="alt-enter" run "$FZREF"; [ "$output" = "$wt" ]
}

@test "the accept keys fall back to the branch when the field they want is empty" {
    # The failure this guards is not "no fallback" but the tab-collapse one: with the
    # fields shifted, ctrl-t on a ticketless branch returned a *neighbouring* value
    # instead of falling back, which reads as a plausible ref.
    create_branch_at_time plain-branch 1700000000
    cd "$TEST_GIT_REPO"

    local stub="$TEST_TMPDIR/fakefzf"
    cat > "$stub" <<'EOF'
#!/usr/bin/env bash
rows=$(cat)
printf '%s\n' "${FAKE_KEY:-}"
printf '%s\n' "$rows" | grep -m1 -F "	${FAKE_ROW}	"
EOF
    chmod +x "$stub"
    export FZP_FZF="$stub" FAKE_ROW="plain-branch"

    local k
    for k in "" alt-enter ctrl-r ctrl-t; do
        FAKE_KEY="$k" run "$FZREF"
        [ "$status" -eq 0 ]
        [ "$output" = "plain-branch" ] || { echo "key=$k gave $output" >&2; return 1; }
    done
}

# ============================================================================
# Alignment
# ============================================================================

@test "every rendered row is exactly the same visual width" {
    create_jira_cache "$FZREF_JIRA_TITLES" \
        "TEST-100" "a short title" \
        "TEST-200" "a title long enough that it has to be truncated with an ellipsis somewhere"
    create_jira_cache "$FZREF_JIRA_STATUSES" "TEST-100" "In Review" "TEST-200" "Done"
    create_branch_at_time TEST-100 1700000000
    create_branch_at_time TEST-200 1700000100
    create_branch_at_time plain 1700000200
    create_branch_at_time a-branch-name-quite-a-lot-longer-than-the-column-is-wide 1700000300
    create_worktree TEST-100 >/dev/null
    cd "$TEST_GIT_REPO"

    run bash -c "'$FZREF' --list | '$FZREF' --render 150 | cut -f1 \
        | perl -CS -pe 's/\\e\\[[0-9;]*m//g' \
        | awk '{ w[length(\$0)]++ } END { for (k in w) print k }' | wc -l"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "the width is the one asked for" {
    create_branch_at_time feature 1700000000
    cd "$TEST_GIT_REPO"

    run bash -c "'$FZREF' --list | '$FZREF' --render 100 | head -1 | cut -f1 \
        | perl -CS -pe 's/\\e\\[[0-9;]*m//g' | awk '{ print length(\$0) }'"
    [ "$status" -eq 0 ]
    # DW carries 2 columns of slack so a wide-glyph status icon can never overflow.
    [ "$output" = "98" ]
}

# ============================================================================
# Ordering
# ============================================================================

@test "rows come out newest-first by sort key" {
    create_branch_at_time old 1700000000
    create_branch_at_time middle 1710000000
    create_branch_at_time new 1720000000
    cd "$TEST_GIT_REPO"

    run bash -c "'$FZREF' --list | awk -F'\t' '\$2 == \"local\" { print \$1 }'"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | assert_descending_order
}

@test "a recently visited worktree outranks a newer commit elsewhere" {
    # The whole reason the sort key is max(committerdate, worktree access): the branch you
    # were reading code in ten minutes ago is a likelier argument than one whose tip
    # happens to be newer.
    create_branch_at_time visited 1700000000
    create_branch_at_time newer-commit 1710000000
    local wt; wt=$(create_worktree visited)
    printf '%s\t%s\n' 1720000000 "$wt" > "$WTA_LOG"
    cd "$TEST_GIT_REPO"

    # Relative order of the two, not "first overall": main's tip is committed at the real
    # now by setup_git_repo, so it legitimately outranks both fixed timestamps.
    local order
    order=$("$FZREF" --list | awk -F'\t' '$4 == "visited" || $4 == "newer-commit" { print $4 }')
    [ "$(printf '%s\n' "$order" | head -1)" = "visited" ]
    [ "$(printf '%s\n' "$order" | sed -n 2p)" = "newer-commit" ]
}

# ============================================================================
# Worktrees
# ============================================================================

@test "a branch checked out in a worktree carries that worktree's path and colour key" {
    create_branch_at_time TEST-100 1700000000
    local wt; wt=$(create_worktree TEST-100)
    cd "$TEST_GIT_REPO"

    local row
    row=$("$FZREF" --list | awk -F'\t' '$4 == "TEST-100" { print; exit }')
    [ "$(printf '%s' "$row" | field $F_WTPATH)" = "$wt" ]
    # git's own name for the worktree — the basename of its gitdir — is the colour key that
    # the p10k segment and fzedit also use. Anything else and the ⊙ is a different colour
    # in each tool, which is worse than no colour.
    [ "$(printf '%s' "$row" | field $F_WTKEY)" = "$(basename "$wt")" ]
}

@test "the primary checkout gets a worktree path but no colour key" {
    # "Untinted" is itself the signal that you are on the main repo — see
    # lib/worktree-colour.sh. A key here would tint it like any other worktree.
    cd "$TEST_GIT_REPO"
    local branch; branch=$(git symbolic-ref --short HEAD)

    local row
    row=$("$FZREF" --list | awk -F'\t' -v b="$branch" '$4 == b { print; exit }')
    [ "$(printf '%s' "$row" | field $F_WTPATH)" = "$TEST_GIT_REPO" ]
    [ -z "$(printf '%s' "$row" | field $F_WTKEY)" ]
}

@test "a worktree mid-rebase keeps its branch instead of vanishing" {
    # `git worktree list --porcelain` reports a rebasing worktree as `detached` with no
    # branch line at all, so the branch you are most likely to be typing a rebase-adjacent
    # command about is the one that silently loses its worktree.
    create_branch_at_time TEST-100 1700000000
    local wt; wt=$(create_worktree TEST-100)
    local gitdir; gitdir=$(get_worktree_gitdir "$wt")
    mkdir -p "$gitdir/rebase-merge"
    echo "refs/heads/TEST-100" > "$gitdir/rebase-merge/head-name"
    git -C "$wt" checkout -q --detach HEAD
    cd "$TEST_GIT_REPO"

    local row
    row=$("$FZREF" --list | awk -F'\t' '$4 == "TEST-100" { print; exit }')
    [ "$(printf '%s' "$row" | field $F_WTPATH)" = "$wt" ]
}

@test "the branch checked out where fzref runs is marked as here" {
    create_branch_at_time TEST-100 1700000000
    local wt; wt=$(create_worktree TEST-100)
    cd "$wt"

    local row
    row=$("$FZREF" --list | awk -F'\t' '$4 == "TEST-100" { print; exit }')
    [ "$(printf '%s' "$row" | field $F_HERE)" = "1" ]

    # And exactly one row is marked, or the marker means nothing.
    run bash -c "'$FZREF' --list | awk -F'\t' '\$11 == \"1\"' | wc -l"
    [ "$output" = "1" ]
}

# ============================================================================
# Jira enrichment
# ============================================================================

@test "the ticket title beats the commit subject as the description" {
    create_jira_cache "$FZREF_JIRA_TITLES" "TEST-100" "the ticket title"
    create_jira_cache "$FZREF_JIRA_STATUSES" "TEST-100" "In Review"
    create_branch_at_time TEST-100 1700000000
    cd "$TEST_GIT_REPO"

    local row
    row=$("$FZREF" --list | awk -F'\t' '$4 == "TEST-100" { print; exit }')
    [ "$(printf '%s' "$row" | field $F_TICKET)" = "TEST-100" ]
    [ "$(printf '%s' "$row" | field $F_DESC)" = "the ticket title" ]
    [ "$(printf '%s' "$row" | field $F_STATUS)" = "In Review" ]
}

@test "a ticket id anywhere in the branch name is found" {
    create_jira_cache "$FZREF_JIRA_TITLES" "TEST-100" "the ticket title"
    create_branch_at_time hotfix-TEST-100-and-more 1700000000
    cd "$TEST_GIT_REPO"

    local row
    row=$("$FZREF" --list | awk -F'\t' '$4 == "hotfix-TEST-100-and-more" { print; exit }')
    [ "$(printf '%s' "$row" | field $F_TICKET)" = "TEST-100" ]
    [ "$(printf '%s' "$row" | field $F_DESC)" = "the ticket title" ]
}

@test "a ticket with no cached title falls back to the commit subject, not to blank" {
    create_branch_at_time TEST-999 1700000000
    cd "$TEST_GIT_REPO"

    local row
    row=$("$FZREF" --list | awk -F'\t' '$4 == "TEST-999" { print; exit }')
    [ "$(printf '%s' "$row" | field $F_TICKET)" = "TEST-999" ]
    [ "$(printf '%s' "$row" | field $F_DESC)" = "commit on TEST-999" ]
}

@test "a project key that is not configured is not treated as a ticket" {
    create_branch_at_time NOPE-100 1700000000
    cd "$TEST_GIT_REPO"

    local row
    row=$("$FZREF" --list | awk -F'\t' '$4 == "NOPE-100" { print; exit }')
    [ -z "$(printf '%s' "$row" | field $F_TICKET)" ]
}

@test "a tab in a Jira title cannot shear the row" {
    printf 'TEST-100:a title with a\ttab in it\n' > "$FZREF_JIRA_TITLES"
    create_branch_at_time TEST-100 1700000000
    cd "$TEST_GIT_REPO"

    run bash -c "'$FZREF' --list | awk -F'\t' 'NF != 11 { bad++ } END { print bad + 0 }'"
    [ "$output" = "0" ]
}

# ============================================================================
# Remotes
# ============================================================================

setup_remote() {
    local remote="$TEST_TMPDIR/remote.git"
    git init -q --bare "$remote"
    cd "$TEST_GIT_REPO"
    git remote add origin "$remote"
    git push -q origin --all
    git fetch -q origin
}

@test "a local branch records the remote spelling that ctrl-r would insert" {
    create_branch_at_time TEST-100 1700000000
    setup_remote
    cd "$TEST_GIT_REPO"

    local row
    row=$("$FZREF" --list | awk -F'\t' '$4 == "TEST-100" { print; exit }')
    [ "$(printf '%s' "$row" | field $F_REMOTE)" = "origin/TEST-100" ]
}

@test "origin/HEAD does not become a row called origin" {
    # `refname:short` abbreviates refs/remotes/origin/HEAD all the way to plain "origin",
    # which matches no */HEAD pattern — so filtering on the short name silently let a row
    # named after the remote itself through.
    create_branch_at_time TEST-100 1700000000
    setup_remote
    git remote set-head origin --auto >/dev/null 2>&1 || \
        git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    cd "$TEST_GIT_REPO"

    run bash -c "'$FZREF' --list | awk -F'\t' '\$4 == \"origin\"' | wc -l"
    [ "$output" = "0" ]
}

@test "a remote branch with a local counterpart is not listed twice" {
    create_branch_at_time TEST-100 1700000000
    setup_remote
    cd "$TEST_GIT_REPO"

    run bash -c "'$FZREF' --list | awk -F'\t' '\$4 == \"origin/TEST-100\"' | wc -l"
    [ "$output" = "0" ]
}

@test "a remote-only branch is listed, since there is no other way to reach it" {
    create_branch_at_time TEST-100 1700000000
    setup_remote
    cd "$TEST_GIT_REPO"
    git branch -q -D TEST-100

    # The fixture's commit dates are years in the past, which the age cutoff would drop for
    # the right reason — that behaviour has its own test below.
    export RR_REMOTE_MAX_AGE_DAYS=0
    local row
    row=$("$FZREF" --list | awk -F'\t' '$4 == "origin/TEST-100" { print; exit }')
    [ -n "$row" ]
    [ "$(printf '%s' "$row" | field $F_KIND)" = "remote" ]
    [ "$(printf '%s' "$row" | field $F_REMOTE)" = "origin/TEST-100" ]
    [ -z "$(printf '%s' "$row" | field $F_WTPATH)" ]
}

@test "remote-only branches past the age cutoff are dropped" {
    create_branch_at_time TEST-100 1700000000
    setup_remote
    cd "$TEST_GIT_REPO"
    git branch -q -D TEST-100

    RR_REMOTE_MAX_AGE_DAYS=1 run bash -c "'$FZREF' --list | awk -F'\t' '\$4 == \"origin/TEST-100\"' | wc -l"
    [ "$output" = "0" ]

    RR_REMOTE_MAX_AGE_DAYS=0 run bash -c "'$FZREF' --list | awk -F'\t' '\$4 == \"origin/TEST-100\"' | wc -l"
    [ "$output" = "1" ]
}

# ============================================================================
# Preview
# ============================================================================

@test "the preview reports the divergence from HEAD" {
    create_branch_at_time feature 1700000000
    cd "$TEST_GIT_REPO"
    git commit -q --allow-empty -m "a commit only on main"

    run "$FZREF" --preview feature ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"+1"* ]]
    [[ "$output" == *"-1"* ]]
}

@test "the preview shows the worktree path when there is one" {
    create_branch_at_time TEST-100 1700000000
    local wt; wt=$(create_worktree TEST-100)
    cd "$TEST_GIT_REPO"

    run "$FZREF" --preview TEST-100 "$wt"
    [[ "$output" == *"$wt"* ]]
}

@test "the preview of an ancestor falls back to that ref's own commits" {
    # An already-merged branch has nothing that HEAD lacks, and an empty pane says nothing
    # about what the ref is.
    create_branch_at_time feature 1700000000
    cd "$TEST_GIT_REPO"
    git merge -q --no-ff -m "merge feature" feature

    run "$FZREF" --preview feature ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"ancestor"* ]]
    [[ "$output" == *"commit on feature"* ]]
}

# ============================================================================
# Degraded modes
# ============================================================================

@test "no Jira caches at all still produces rows" {
    export FZREF_JIRA_TITLES="$TEST_TMPDIR/does-not-exist"
    export FZREF_JIRA_STATUSES="$TEST_TMPDIR/also-not"
    create_branch_at_time feature 1700000000
    cd "$TEST_GIT_REPO"

    run bash -c "'$FZREF' --list | wc -l"
    [ "$status" -eq 0 ]
    [ "$output" -gt 0 ]
}

@test "no .env at all still produces rows, just without ticket columns" {
    export FZREF_ENV_FILE="$TEST_TMPDIR/no-such-env"
    create_branch_at_time TEST-100 1700000000
    cd "$TEST_GIT_REPO"

    local row
    row=$("$FZREF" --list | awk -F'\t' '$4 == "TEST-100" { print; exit }')
    [ -n "$row" ]
    [ -z "$(printf '%s' "$row" | field $F_TICKET)" ]
}

@test "outside a git repository it fails rather than printing something wrong" {
    cd "$TEST_TMPDIR"
    mkdir -p not-a-repo
    cd not-a-repo
    run "$FZREF" --list
    [ "$status" -ne 0 ]
}

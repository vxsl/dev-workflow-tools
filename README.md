# dev-workflow-tools

Interactive Git + Jira + GitLab workflow tools with fzf interfaces.

## Installation

```bash
cd ~/bin
git clone <repo-url> dev-workflow-tools
cd dev-workflow-tools
cp .env.example .env
# Edit .env with your Jira credentials
```

Add to `~/.zshrc`:
```zsh
source ~/bin/dev-workflow-tools/shell/dev-workflow.zsh
```

### Dependencies

Required: `git`, `fzf`, `jq`, `curl`, `glab`
Optional:
- `tmux` (for pane management + auto-clear refresh summary)
- `xdotool` (Linux X11 only - for auto-clear refresh summary outside tmux)
- `xclip`, `bat`, `eza`, `fd`, `wmctrl`

## Configuration

Edit `.env`:
```bash
JIRA_DOMAIN="<your-company>.atlassian.net"
JIRA_PROJECT="<PROJ|DEV|ENG>"
JIRA_EMAIL="your-email@company.com"
JIRA_API_TOKEN="your-api-token"

# Optional - your JIRA username (for branch highlighting in rr)
JIRA_ME="your-jira-username"
TICKET_CREATOR_BOT_TOKEN="xoxb-..."
FZF_PERSIST_MODE=1  # For xmonad scratchpads/tmux popups

# QA Branch Integration (for publish-changes)
JIRA_QA_BRANCH_FIELD="customfield_12345"  # Auto-detected if not set
JIRA_QA_BRANCH_DOMAIN="qa.example.com"    # Single domain or comma/space-separated list
```

Get Jira API token: https://id.atlassian.com/manage-profile/security/api-tokens

#### Required Jira API Token Scopes

When creating your API token, select these granular scopes:

| Scope | Used for |
|---|---|
| `read:jira-work` | Searching/reading issues, projects, statuses, priorities |
| `write:jira-work` | Creating issues, adding comments, transitioning statuses, updating fields |
| `read:jira-user` | Reading current user info (`/myself` endpoint) |
| `read:board:jira-software` | Fetching boards for sprint assignment (`create-jira-ticket`) |
| `read:sprint:jira-software` | Fetching active sprints (`create-jira-ticket`) |
| `write:sprint:jira-software` | Adding issues to sprints (`create-jira-ticket`) |

> **Note:** If classic scopes are available, `read:jira-work` + `write:jira-work` + `read:jira-user` cover everything except Agile board/sprint features.

### Slack Bot Token

The `TICKET_CREATOR_BOT_TOKEN` is used by `oneshot` to post ticket and MR links to Slack threads. The bot requires these OAuth scopes:

- `chat:write` - Post messages to channels/threads
- `channels:read` - Verify bot membership in public channels
- `groups:read` - Verify bot membership in private channels

To add these scopes:
1. Go to https://api.slack.com/apps → Your App → OAuth & Permissions
2. Add the scopes under "Bot Token Scopes"
3. Reinstall the app to your workspace
4. Copy the "Bot User OAuth Token" (starts with `xoxb-`) to `.env`

**Note:** The bot must be added to channels before it can post. Use `/invite @your-bot-name` in the channel.

### QA Branch Integration

When creating a merge request with `publish-changes`, the tool can automatically set a "QA Branch" field in your Jira ticket. This is useful if your workflow includes deploying feature branches to QA environments.

**Configuration:**
- `JIRA_QA_BRANCH_DOMAIN` - The domain(s) where QA branches are deployed (e.g., `"qa.example.com"`)
  - Supports multiple domains: `"qa1.example.com,qa2.example.com"` or `"qa1.example.com qa2.example.com"`
  - Multiple domains will show an fzf menu to select which one to use
  - The branch name will be formatted as: `branch-name.qa.example.com`
- `JIRA_QA_BRANCH_FIELD` - The custom field ID in Jira (e.g., `"customfield_12345"`)
  - If not set, the tool will auto-detect fields matching "QA Branch" or "Branch QA"

**Example:**
```bash
JIRA_QA_BRANCH_DOMAIN="qa.example.com"
# When you create an MR from branch "PROJ-123", Jira will show: PROJ-123.qa.example.com
```

### FZF Persist Mode

By default, fzf tools exit after selection (normal CLI behavior). Set `FZF_PERSIST_MODE=1` if using xmonad scratchpads or tmux popups to keep the interface open after actions.

### Worktree Customization

Automatically customize new worktrees when created via `create-wt` or rr's F2/F3 keybindings.

**Exclude Build Artifacts** (skip copying large directories):
```bash
# Skip Rust's target/ directory (can be hundreds of MB)
WORKTREE_COPY_EXCLUDE="target/"

# Multiple patterns
WORKTREE_COPY_EXCLUDE="target/ build/ dist/ *.log"
```

**VS Code Settings** (simple JSON merge):
```bash
# Disable Rust analyzer in all new worktrees
VSCODE_WORKSPACE_SETTINGS='{"rust-analyzer.enable": false}'

# Multiple settings
VSCODE_WORKSPACE_SETTINGS='{"rust-analyzer.enable": false, "editor.formatOnSave": true}'
```

**Post-Worktree Hook** (arbitrary customization):
```bash
POST_WORKTREE_HOOK="/home/username/bin/my-worktree-setup.sh"
```

See [WORKTREE_CUSTOMIZATION.md](WORKTREE_CUSTOMIZATION.md) for detailed examples and use cases.

## Tools

### `jira-fzf`
Browse/search Jira tickets, create new tickets, checkout branches, create MRs.

**Usage:** `jira-fzf [--persist] [--one-shot] [--dry-run] [--labels "bug,ui"]`
- `--persist` - Keep open after actions (for scratchpads/tmux popups)
- `--one-shot` - Exit after selection (default)

**Keys:** `<CR>` maximize | `^y` copy | `^o` open | `^t` new ticket | `^g` create MR | `^c` checkout | `^s` sort | `^r` refresh

### `create-jira-ticket`
Create Jira tickets with interactive prompts.
```bash
create-jira-ticket                       # Interactive
create-jira-ticket --summary "Fix bug"   # Quick
create-jira-ticket --slack-url URL       # Link to Slack
create-jira-ticket --no-labels           # No labels at all
```

The label step defaults to `front-end`. To create a ticket with no labels, pick
`(no label)` in the picker (second entry, so `Enter` still takes the default),
or pass `--no-labels` to skip the step. `oneshot` and `jira-fzf` both accept
`--labels` and `--no-labels` and pass them down.

Three things are resolved rather than asked, because they only ever have one
answer for a ticket you're creating to work on now:

| | |
|---|---|
| **Board** | Set `JIRA_DEFAULT_PROJECT` in `.env` and the "Select board" step disappears. `--project KEY` overrides it for one run. Without either, several keys in `JIRA_PROJECTS` still get a picker. |
| **Sprint** | The board's running sprint, or the next one due to start. |
| **Assignee** | You. |

### `oneshot` (alias: `os`)
One-shot workflow: staged changes → branch → commit → MR.
```bash
oneshot                    # Interactive
oneshot PROJ-1234          # Use ticket
oneshot https://slack...   # From Slack thread
oneshot --from-commit      # Ticket + MR title/description from the commit
oneshot --no-labels        # New ticket gets no labels
```

`--from-commit` applies when the change is one already-made commit and nothing
is staged: its subject becomes the ticket summary and MR title, its body the
ticket description and MR description, instead of being typed a third time.
Trailers (`Co-Authored-By:`, `Session-Id:`) are left out, and the commit itself
is never rewritten — it keeps the message you gave it, without a ticket key.
oneshot offers this on its own whenever it sees a lone unpublished commit; the
flag just answers in advance.

### `publish-changes`
Create GitLab MRs with Jira integration.
```bash
publish-changes                # Interactive
publish-changes PROJ-1234      # With ticket
publish-changes --draft        # Draft MR
```

### `rr.sh` (alias: `r`)
Recent branches with Jira info.
```bash
r           # Recent local branches
r -o        # Remote branches
r -r        # Refresh cache
```

**Keys:** `^l` load more | `^o` toggle local/remote | `^r` refresh (shows summary for 2.5s, auto-clears) | `F2` new worktree | `F3` new branch+wt | `F8` delete wt

**Refresh Auto-Clear:**
The refresh summary automatically clears after 2.5 seconds when using:
- **tmux** - Works in any tmux session
- **macOS** - Uses built-in `osascript` (no extra install needed)
- **Linux X11** - Requires `xdotool` package

If auto-clear is unavailable, the summary will show installation instructions or indicate it will persist.

**Display Columns:**
1. **Branch** - Branch name with indicators
2. **Title** - JIRA ticket summary
3. **Status** - JIRA ticket status
4. **Assignee** - JIRA ticket assignee
5. **Checked** - When you last checked out this branch/worktree
6. **Committed** - When the last commit was made

**Branch Emphasis** (requires `JIRA_ME` in `.env`):
- **★ Bright purple** - Your authoritative branch (exact ticket: `UB-6493`)
- **· Dimmed purple** - Your variant branch (ticket + suffix: `UB-6493-wip`)
- **Gray (no symbol)** - Other branches (not assigned to you)

**Visual Indicators:**
- `⊙` on a filled block — this branch has a worktree, and the block is *that worktree's*
  colour, the same one the p10k prompt segment and fzedit give it (see
  `lib/worktree-colour.sh`). The block runs across the branch name too, so the whole cell
  reads as one segment. The primary checkout is deliberately left unblocked.
- `!` after the block — the worktree is dirty
- `⊙≠` — a different branch is checked out in that worktree

#### Tmux Pane Management (Optional)

You can configure `rr` to manage specific tmux panes (e.g., dev server, tsc-watch) across worktrees. When enabled, you can switch which worktree is active for each pane with a single keystroke.

**Configuration in `.env`:**
```bash
# Enable pane management
RR_PANE_MGMT_ENABLED=true

# Dev server pane (format: session:window.pane)
RR_DEV_SERVER_PANE="tmuxa-1:0.1"
RR_DEV_SERVER_COMMAND="yarn install && yarn run-p tailwind dev"

# TypeScript watch pane (optional)
RR_TSC_WATCH_PANE="tmuxa-1:0.2"
RR_TSC_WATCH_COMMAND="yarn tsc-watch"
```

**Usage:**
1. In `rr`, select a worktree with an existing worktree (marked with ⚡⌘)
2. Press `F4` to set it as the dev server target
3. Press `F5` to set it as the tsc-watch target
4. The script will automatically:
   - Stop the current process in the pane (Ctrl-C, escalating to SIGINT then SIGTERM for anything that holds stdin in raw mode and ignores a bare `^C`)
   - Wait for the pane's own shell prompt to come back — it will refuse rather than type into a program that is still holding the terminal
   - cd to the selected worktree and run the configured command, sent as a single bracketed paste so no character of it can be read as a key binding

**Visual Indicators:**
- `▶` (green) - This worktree is running the dev server
- `⏩` (cyan) - This worktree is running tsc-watch

**Finding your pane IDs:**
```bash
# List all tmux panes with their IDs
tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index} - #{pane_title}"
```

### `fzedit`
The file pad: a worktree-aware fuzzy finder that fronts nvim, tig and rr. Lives in a
scratchpad terminal, so it is always one keystroke away and never in your way.

Scope is a single axis, widest-last, because the sets nest rather than toggle:

```
conflicts  ⊂  changed  ⊂  worktree  ⊂  home
```

`TAB` widens, `S-TAB` narrows, and the whole ladder is in the header with counts, so
where you are and where TAB goes are both visible without remembering letters.

Worktrees are rows in every rung (`⊙`), appended after the files — so a filename
query never surfaces one, while a branch or ticket-shaped query does. Switching
worktree and opening a file are the same gesture: type what you want.

Each checkout gets its own colour, and it is the *same* colour the p10k prompt segment
(`shell/p10k-worktree.zsh`) gives it — palette, key and hash all live in
`lib/worktree-colour.sh` so the two cannot drift. With 150-odd worktrees of one repo,
several of them sharing a branch-name prefix, "am I in the right checkout" wants to be
answerable by colour rather than by reading. The primary worktree is deliberately
untinted: no colour is itself the signal that you are on `main`.

**Which worktree am I in** is the header's first line, drawn as a filled block in that
worktree's colour — the same shape, and literally the same escape bytes, as the prompt
segment:

```
⊙ ul.UB-6709   UB-6709-add-custom-trimet-layer      ⚠ ul.hotfix (rebase 2/6)
└ block, in this worktree's colour                  └ something parked elsewhere
```

The pad is a fixed-cwd full-screen scratchpad, so unlike every other window it has no
ambient clue about which checkout you are about to edit — a block is the one thing on the
line you cannot miss. It turns white-on-red and says `⚠ WRONG BRANCH: <branch>` when the
checkout is not on the branch its `<repo>.<branch>` name promises, which is the same alarm
the prompt raises, from the same rule in `lib/worktree-mismatch.sh`. Prefix matches count
as matches (`ul.UB-6709` holding `UB-6709-add-custom-trimet-layer` is fine) and anything
mid-rebase is left alone — an alarm that fires every time you rebase is one you stop
reading.

**Keys** — `F1` in the pad prints all of them.

| | |
|---|---|
| `enter` | open the file, or switch to the `⊙` worktree |
| `^space` / `^E` | mark rows / open every marked row in **one** nvim |
| `^F` | ripgrep file *contents*, landing on the matching line |
| `^K` | this file, over in another worktree |
| `^R` | worktree picker — hands off to `rr`, so you get tickets, MR state, dirty flags |
| `^L` | tig: this file's history, or `tig status` on a `⊙` row |
| `^A` | stage / unstage |
| `^O` `^S` | open in cursor / new tmux window at the repo root |
| `^C` `^Y` | copy absolute / repo-relative path |
| `^G` `^X` `^B` | new tab / previous / next  (a tab is a whole fzedit instance) |
| `esc` `F5` | clear the query / refresh, ignoring caches |

Inside `^F`: `^F` again freezes the results and fuzzy-filters them, `^E` sends every
match to nvim's quickfix list.

**Why it is scoped.** The pad's cwd is fixed, so `$PWD` says nothing; the worktree is
inferred from your most recently active tmux pane. Unscoped, `fd ~/` was 2.86M rows and
5s — 2.02M of them the same ~12.6k repo-relative paths repeated once per sibling
worktree, so a filename query returned the same file 154 times with no way to tell the
copies apart. The home rung prunes sibling worktrees and the noise list below, which
gets it to ~32k rows in 0.6s.

**Config.** Machine paths in `.env` (`FZEDIT_DEFAULT_REPO`, `FZEDIT_PREFERRED_DIRS`);
home-sweep noise in `~/.config/fzedit/ignore`, seeded on first run and meant to be
edited. Worktree recency is shared with `rr` — same log, same format — so both tools
agree on "most recent" and each updates it.

`bats test/fzedit.bats` — 125 end-to-end tests.

See [WORKFLOW.md](WORKFLOW.md) for the whole loop — fzedit, nvim, tig and rr
together — including the nvim keymaps worth internalising.

### `fzref` (bound to `Ctrl+B`, and to `Tab` where a ref is the only option)

Picks a ref for a command you are already typing — `git rebase <TAB>` is the case it
exists for. Git's own completion offers every branch, alphabetically, which is the wrong
index: what you remember is the ticket ("the AOI fill one"), and the branch name is the
thing you are trying to look up.

So the rows are keyed on the work rather than on the ref — Jira title and status from
`rr`'s caches, and the ⊙ block in the worktree's own colour, the same block the p10k
segment and `fzedit` draw:

```
 ⊙  ➤ UL-1633        fix queries stuck loading when rapidly cancelled…  ⬡ IN REVIEW  9 minutes ago
    ⊙ UL-1773        AOI shapes should have no fill on the map          ⬡ IN REVIEW  16 minutes ago
      origin/UL-1774 Re-land the zip-ingestion batch runner             ○ TO DO      12 hours ago
```

A coloured ⊙ means that branch is checked out in that worktree (untinted = the primary
checkout, none = no worktree); `➤` is the branch you are on right now. Ordered by the
later of the tip commit and the last time you were in its worktree, so "the one I was just
in" floats up alongside "the one I just committed to".

**The accept key picks which of a ref's names you get**, because that depends entirely on
the verb in front of it:

| key | inserts | for |
|---|---|---|
| `enter` | `UL-1633` | `git rebase` / `merge` / `switch` |
| `alt-enter` | `/home/kyle/work/repos/ul.UL-1633` | `cd`, `ls`, anything taking a path |
| `ctrl-r` | `origin/UL-1633` | rebasing onto the remote |
| `ctrl-t` | `UL-1633` | the bare ticket id, for `ticket-ask` etc |

Each falls back to the branch name when the row has no such value. `ctrl-/` toggles the
preview, which shows how far the ref is ahead/behind you and the commits that differ.

**Two ways in.** `Ctrl+B` always opens the picker and replaces the word at the cursor.
`Tab` opens it only where a ref is the *only* possible argument, and otherwise falls
straight through to normal completion:

| where Tab opens the picker | where it stays out of the way |
|---|---|
| `rebase`, `merge`, `switch`, `cherry-pick`, `revert` | bare `git branch` — naming one to *create* |
| `reset --hard/--soft/--merge/--keep` (git forbids paths there) | bare `git reset` and `--mixed` — usually unstaging paths |
| `branch -d/-D/-f` (a list of existing branches) | `switch -c` / `checkout -b` first arg — a new name |
| `branch -m/-c <existing>` — but not the new name after it | `restore <pathspec>` — its ref lives in `--source` |
| `worktree add <path> …`, `push/pull/fetch <remote> …` | anything after a bare `--` — pathspecs by definition |
| any option whose value is a ref: `--onto`, `--source`, `-u` | `create-wt` excepted, non-git commands |

For the genuinely ambiguous ones — `checkout`, `diff`, `log`, `show`, `bisect` — it opens
only when the partial word already matches a ref, so `git diff src/<TAB>` keeps completing
filenames.

Tab is wired up from `~/.zshrc`'s Tab dispatcher, guarded on `$+functions[_fzref_tab_try]`
so that file keeps working with this repo unsourced:

```zsh
if (( $+functions[_fzref_tab_try] )) && _fzref_tab_try; then
    return
fi
```

Everything is computed live — `for-each-ref` and `worktree list` are ~8ms each on a
370-branch repo, so the whole list is ~150ms and a cache would only ever be a way to be
wrong. The Jira columns come from `rr`'s caches because those are the only slow part, and
`rr` already keeps them warm. Unlike `rr`'s rows this does *not* report dirty worktrees:
that is a `git status` per worktree, and it is not information that helps you choose the
*name* of a ref.

`bats test/fzref.bats test/fzref_context.bats` — 60 tests.

### `restage`
Unstage two WIP commits, keeping oldest staged.

### `apply_staged_to_commit`
Apply staged changes to a commit via fixup+autosquash.
```bash
apply_staged_to_commit <commit-sha>
```

### `slack-react-notify`
Get pinged when people react to *your* Slack messages — something Slack doesn't do
natively. A small cross-platform (Linux/macOS) Socket Mode daemon: it listens for
`reaction_added` events, keeps only the ones on messages you authored, and **DMs
you on Slack**. That Slack DM fires Slack's own desktop *and* mobile notification
(a message you send yourself wouldn't), so you're reached on every device. Set
`SLACK_REACT_DELIVERY=desktop` for a local `notify-send`/`osascript` popup instead,
or `both` for both.

```bash
slack-react-notify             # run in the foreground
slack-react-notify --check     # validate tokens + identity, then exit
slack-react-notify --help      # full Slack-app setup walkthrough
slack-react-notify --print-manifest                  # paste into "Create New App"
slack-react-notify --print-service systemd|launchd   # run it on login
```

**Fastest setup:** `slack-react-notify --print-manifest`, paste it into
https://api.slack.com/apps → *Create New App → From a manifest*. Then generate an
App-Level Token (`connections:write`) → `SLACK_REACT_APP_TOKEN`, install the app,
and copy **both** the User OAuth Token → `SLACK_REACT_TOKEN` (reaction events +
reads) and the Bot User OAuth Token → `SLACK_REACT_BOT_TOKEN` (DMs you). Run
`--check` to confirm.

Runs as its **own dedicated Slack app**, independent of `ticket-bot` — don't share
tokens, since Slack load-balances events across simultaneous Socket Mode
connections on one app. The user-token `reaction_added` subscription ("on behalf
of users") covers every channel and DM you're in with no bot invites; the bot
token is used only to send you the DM. See the `Slack Reaction Notifications` block
in `.env.example` for the full scope list and steps.

**Run it on login:**
```bash
# Linux (systemd user service)
slack-react-notify --print-service systemd > ~/.config/systemd/user/slack-react-notify.service
systemctl --user daemon-reload && systemctl --user enable --now slack-react-notify

# macOS (launchd agent)
slack-react-notify --print-service launchd > ~/Library/LaunchAgents/com.dev-workflow-tools.slack-react-notify.plist
launchctl load -w ~/Library/LaunchAgents/com.dev-workflow-tools.slack-react-notify.plist
```

### `work-arcs`
Group the repo's loose work into the arcs it actually belongs to, and reconcile that
against Jira. 389 unmerged branches is not 389 things — `UB-6919` alone owns 20 of
them. Flat, that's noise; grouped, it's a handful of pieces of work.

Roots are ticket keys, or a shared name prefix for work that never got a ticket (the
`adaptive` / `adaptive-bak` / `adaptive-bak-bak-bak` family is one arc no key-based
grouping can see). Under each: branches with their stacking parents — a branch can
sit on several, so this is a DAG — stashes with the files in them, MRs with comment
counts, and the Claude sessions that touched any of it.

```bash
work-arcs                  # every arc, most recently touched first
work-arcs --focus          # what you are actually working on (8 arcs, derived)
work-arcs --gap            # where Jira and reality disagree
work-arcs --jira-ify dove  # file a ticket for an arc, prefilled from what it is
work-arcs --curate         # answer the memberships it is least sure of
work-arcs --json           # the whole graph
```

**`--focus` is derived, never declared** — there's nothing to keep up to date.
Recency decides what's eligible; *engagement* decides the order. Sorting by recency
alone returned 28 arcs for a two-day window, because a session sweeping across
branches touches many of them. How many transcript entries mention a branch tells
those apart: three mentions is a grep, four thousand is what you were doing.

**`--gap` answers whether Jira is representative.** Three disagreements, each wanting
a different action:

| Gap | Meaning |
|---|---|
| real work with no ticket | `dove` — 17 branches, days of work no remote has, no Jira presence |
| status claims handed off | `UL-1692` says *In Review* with a fortnight never pushed |
| ticket with no work | assigned and open, but no branch or session exists |

**Only work that is still outstanding.** The first row asks whether anything is left to
file a ticket *about* — unpushed commits, an open merge request, or any demand — and not
merely whether the arc has a ticket and looks busy. Without that it offered a one-step
`--jira-ify` command for work that had already merged, on a page that listed the same
workstream under *Landed*. The test is `settled`, which is the one place that decides
whether every branch of an arc has landed or been abandoned, plus the `pre-landing` rung
where the work shipped as a reshape and the survivors are drafts from before it.

`--jira-ify` files the ticket using what the arc already knows — branches, unpushed
count, session count, recent commit subjects — then drops into `create-jira-ticket`'s
board picker, because UL vs UB is a judgment call. Add `--dry-run` to see it first.

**Which work exists only here.** The aggregate strip at the top of the page counts the
workstreams no remote has a copy of, and that count opens: one row per workstream, biggest
and longest-quiet first, capped at eight with the remainder stated. Each row carries the
workstream's name, what it would cost to lose, how long it has been quiet, the branch that
IS the work, and a link to its card. Both figures are on the row because the order is made
of both — days of work times staleness — so a thirteen-day workstream touched yesterday
correctly sits below a seventeen-day one nobody has opened for a fortnight.

`work-arcs --json` emits that order as `only_here`: arc ids, ranked, complete. Like
`forgotten` it is the ranking and not the data — the arcs carry `unpushed_days`,
`unpushed_dates` and `authoritative` already — and the cap belongs to whatever renders it,
because a list truncated on the wire could never be un-truncated.

**What leads, and what merely persists.** Local-only work has a permanent home — the count,
the disclosure, the `only_here` ranking — and it does not have the first attention slot:
*"the tool is too obsessed with me having commits on my laptop. i guess i do want that
information somewhere but it's not the main signal of unfinished work"*. So the strip reads
people first — what came back to you, then what is out for review — before what is only
here, and the rungs where the next move is nobody's but yours follow in `DEMAND_RANK`'s own
order. Inside a recency group, the same rule: what is waiting on you, worst first, with the
size of the pile as the tiebreak rather than the sort. Nothing is hidden and no count moves.
A loop with somebody else in it compounds while it waits; a commit on this disk does not.

**The Jira-mismatch rows are ranked on that same principle** — *longest uncorrected first*,
which is how long the ticket has gone without anyone touching any field on it, and therefore
the least time the wrong status can have been standing. Days of work is the tiebreak, not the
sort. One ranking, made once in `reconcile`: the table renders it in order, the page's
opening sentence and the morning brief both take its head, and so the three cannot name
three different worst tickets — nor can a sentence link to a row the table's fourteen-row
cap removed.

**`--authoritative-ticket` says what an arc’s work IS**, which is the one thing neither
git nor Jira can settle. `UL-1852` reached review as one merge request; file overlap had
already gathered eleven other branches into the same arc — experiments, backups, a
pre-squash copy, a spike that went nowhere — and every one of them held the arc on the
`local-only` rung, reporting *85 commits exist only here* about work that had shipped. Every
count was right; what they were counts **of** was the question.

**Filed from the page, in one click.** Every workstream this applies to carries a *this
work is* row above its tree: one button per ticket it could be filed as, each labelled with
what the row will say once it is — `UL-1852 → in qualification`, `UL-1853 → landed`. Click
it and the page applies it there and then: the rung changes, the counts change, the branches
outside that ticket go struck through in the tree, and the demands it silences disappear.
Click it again to unfile.

None of that is worked out in the browser. `work-arcs` precomputes every state the control
can reach — one per offerable key, plus the underived state to return to — by actually
applying each filing and reading `finalize`'s answer, so the page records intent and swaps
in the pipeline's own numbers. A second implementation of the rung ladder in JavaScript is a
ladder that eventually disagrees with this one. Only keys that change something are offered,
at most three, the one the derivation already chose first.

Like parking and detaching, it applies in the page and survives reloads (the artifact's own
`localStorage`), and **Save filings** writes `authoritative-ticket.json` for
`~/.local/state/work-arcs/` so `work-arcs`' own counts agree with what you are looking at.
The store the page keeps is seeded from the file `work-arcs` read, not from the rows on
screen — a workstream outside the focus window has no row, and a store built from rows alone
would drop its filing the first time the page saved one.

There is a command-line twin, as there is for every control on the page:

```bash
work-arcs --authoritative-ticket UL-1852       # the key alone, where one arc holds it
work-arcs --authoritative-ticket "Derive dataset geometry…=UL-1852"
work-arcs --derive-ticket UL-1852              # back to the derivation
```

Filing the work as a ticket files it as the merge request under that ticket, so the rung
falls to whatever that merge request says. Branches outside its lineage — its stack
parents and its own copies are inside it — become **history**: still drawn in the tree,
struck through, still counted in `branches`, but no longer counted as risk, no longer
holding the rung down, and no longer asking for anything. Once the merge request merges the
arc can finally read *landed*, which it never could while eleven drafts from before it were
outstanding.

It is a suppression, so it expires like every other declaration here: it records a
fingerprint of the tips it set aside and applies only while those are still the tips. A
commit landing on any of them means you went back to that branch, and a branch you went
back to is not history — the page then says it has stopped filing the arc that way, and
everything is counted again. Two things it deliberately does not touch: unpushed commits on
the declared branch itself, and anything the merge request is asking for.

**Where the grouping is unsure, it asks.** File overlap has a resolution limit and this
repo has been to the end of it: two tickets that edit the same module are structurally
identical however the weights are set, and the model split pass — which reads the commits,
the one thing overlap cannot — still leaves errors. Measured, live: `UL-1852` is two commits
of geo\_filter migration sitting in a fifteen-branch arc about deriving route geometry from
metadata, held there by two shared files. Nothing in the derivation can tell those apart,
because by every signal it has, they are the same.

So the doubt is published instead of tuned away. Every clustered membership carries a
confidence — how much evidence holds this branch in this arc, discounted by how close the
call was and by whether the branch's own name is filed under a different ticket — and the
five least confident become questions:

```bash
work-arcs --curate    # y keep · n pry · s skip · esc done
```

One keystroke each, a preview pane showing both sides of the tie, and the same five rows
on the page with **yes** / **no** buttons. The rules are all about the asking, because a
queue that is unpleasant to open is a queue that stays full: never more than five, one per
arc (two branches propping each other up is one question, not two), **skip is free and
leaves no record**, silence when there is nothing to ask, and nothing anywhere that
notifies, badges or counts up at you.

Four kinds of membership are never asked about, because each is a fact rather than a
guess: a branch cut from another, the same commit under a second name, a superseded copy
verified by `git patch-id`, and a branch whose own name carries the arc's ticket. The
branch carrying the arc's merge request is *not* on that list, and that is the correction
that made the queue useful — authority follows the newest MR rather than the weight of the
work, so an arc's subject can be decided by a stranger, which is worse than a stranger
merely standing in it. The question says what prying it costs before you answer.

**Yes** pins the membership; **no** writes the same detachment the `✕` on the tree writes.
Both expire the way every declaration here does — against the company the branch keeps,
never the arc's name, so a reworded label leaves them alone and a regrouping ends them out
loud.

**And every answer is a labelled example.** They append to `curation-labels.jsonl`, both
verdicts and not only the corrections — scored on corrections alone, a clusterer that split
everything into singletons would agree with every one of them and be useless.

```bash
arc-cluster --score-labels    # this clustering against every judgement already made
```

Which is the point. *Is it worth going on massaging the detection algorithm?* has been
argued about for three revisions of the plan and cannot be settled by argument. Now the
next change to the resolution, the hub ceiling or the corroboration floor either scores
better against judgements a person actually made, or it does not.

**The Slack lens: what was decided, on the card for the work it decided about.** The
graph knows what the code says and what the tickets say, and both are records of
decisions already taken. The taking happens in Slack — a week later the only trace of
"we agreed to drop the `array_has` calls" is thirty messages deep in `#tech-backend`,
recoverable nowhere else on the machine. So each workstream card carries a **From Slack**
block: what its threads settled, what they left standing, every line quoting the one
message it comes from with a permalink to it.

Only threads **you posted in**, read with **your own token**, on **your own page** — the
boundary is structural rather than a policy, and the block says so. A thread joins a
workstream on an exact identifier it contains: a ticket key some arc owns, a branch name
distinctive enough to survive being typed in a sentence, an MR iid. Measured over a
fortnight: 219 threads, 78 of them in channels, **18 joined** — 14 on a ticket key, 3 on
an MR reference, 1 on a branch name. Threads are read whole or not used at all; a
synthesis over the fifth of a conversation that search happens to return is not partial
but wrong, because the message that reverses the decision is exactly the one search
missed. DM and group-DM history this token cannot read and does not ask for, so 151 of
those 219 were never opened — the block reports that count rather than implying it saw
everything.

**Every quote is a message, and it is set as one:** who said it, their avatar, and their
words with Slack’s own markup rendered. `conversations.replies` names an author as a bare
`U0A5LKV7E0K` — which is what the cards used to print — so `users.info` is asked once
per person per month and cached in `slack-people.json`, avatar bytes included. Those are
stored as inline data URIs because the page is an artifact whose CSP refuses every external
host: an avatar served from `avatars.slack-edge.com` is not a slow avatar, it is no avatar.
Where Slack gives us no face the chip is the person’s initials, in a hue hashed from their
name, so they are the same colour in every section. Emoji shortcodes are resolved only where
they can be named — `ratio 3:4:5` holds a shortcode-shaped `:4:`, and a substitution
firing on anything shortcode-shaped would silently print `ratio 35`.

`✕` acknowledges a thread; the fingerprint carries the thread's last message, so anyone
adding to it brings the block back. One cached model call per thread: the first run of
the day costs about 13¢ a thread and every rerun costs nothing.
`--no-slack-threads` skips the lens (the ledger's own Slack rows are unaffected).

The lens also feeds **Since the last build**, so a decision reached overnight can open the
morning brief. What counts as new there is the *message* an item quotes, never the sentence
about it — the model may reword a decision and that is not news — while a reply to the
thread does count, because it is the same event the `✕` expires against. An acknowledged
thread contributes nothing: no line, and no arc in the "N workstreams moved under you"
count. Threads are compared only between two runs that both read the lens whole, so the
first run after an outage or a `--no-slack-threads` says nothing about Slack rather than
reporting a week-old conversation as this morning's news.

**The block at the top of the page is a list, not a paragraph.** It used to be one serif
paragraph carrying five facts, and it was not readable: five sentences each with a claim, a
number, a superlative and a subordinate clause, run together with nothing to tell a skimming
reader which one was about what. `arc-morning` already composed one sentence per topic, so
each now takes a row with its kind named in the margin — *open loop*, *past due*,
*dropped*, *jira disagrees* — and its subject linked to the row below that is the evidence
for it. The one model call it makes changed job with the shape: it tightens each line on its
own, and the contract is positional, so a line count that does not match, an anchor carried
onto the neighbouring line, or a numeral that drifted between lines rejects the whole pass
rather than half of it.

**Under the brief is what to say at the next standup.** The page answers "what is true
about my work"; a standup asks what the other people on the call need to hear, and the
difference is not a matter of trimming. Three things change at once. The window is the
cadence rather than the build — every other interval on this page is measured from the last
time `arcs` ran, and a standup covers the interval since the last *standup*. The audience is
the team, so the vocabulary is ticket keys, MR numbers, channels and names rather than rungs
and workstreams. And the pick is what somebody on the call can unstick, not what will bite
you soonest — which is why the morning brief opens on a 159-day stall and this does not.

Four beats, each dropped when it holds nothing: **moved** (MRs, commits and tickets that
changed), **discussed** (what was settled or left open in Slack, and review threads where
somebody asked or you answered), **blocked / asks** (who is waiting on whom), and **in front
of you** (the two workstreams you were last in, plus your sprint tickets that are not handed
off — a prompt, since nothing here knows your plans). *copy* puts the whole thing on the
clipboard as the same plain text the block shows, composed once so the two cannot drift.

The window is derived from the clock alone — **the most recent standup that has already
happened, running to now** — so there is no state to get out of step and it is right on a
laptop that has not been opened for a week. At 09:00 on a Monday it covers Friday onward and
the notes are for the meeting in ninety minutes; at 11:00 the same morning the last standup
is that one, and the notes are already Wednesday's. A window only minutes old says so, so
"nothing moved" reads as a fact about the clock rather than about you.

Two things it will not do. It infers nothing — a ticket is said as a status and a date,
never as a transition, because nothing here saw the ticket before the window opened. And it
invents no ranking: the ledger arrives sorted worst-first and is consumed in that order. The
one judgement it makes is a partition, twice over. Debts group by kind, so eleven "nobody
has reviewed !104xx" rows are one sentence naming the oldest instead of eleven lines
differing by a number; and they split by age, so a five-month stall is still said but in a
tail line rather than opening the fortieth consecutive standup with something nobody is
going to act on.

Env: `WORK_ARCS_REPO` (default `~/work/repos/ul`), `WORK_ARCS_MAIN` (`origin/main`),
`WORK_ARCS_PROJECTS` (`~/.claude/projects`), plus the `JIRA_*` vars for `--gap`. For the
Slack lens: `WORK_ARCS_SLACK_LOOKBACK` (14 days), `WORK_ARCS_SLACK_THREADS_MAX` (150
threads a run), `WORK_ARCS_SLACK_THREAD_JOBS` (6 concurrent) and
`WORK_ARCS_SLACK_THREAD_MODEL` (falls back to `WORK_ARCS_COMMIT_MODEL`, then `sonnet`). For
the standup block: `STANDUP_DAYS` (`mon,wed,fri`), `STANDUP_TIME` (`10:30`), `STANDUP_TZ`
(`America/Los_Angeles`), `STANDUP_STALE_DAYS` (30 — where a debt stops being news),
`STANDUP_QUOTE_MAX` (110 characters) and the per-beat caps `STANDUP_MOVED_MAX` (3),
`STANDUP_DISCUSSED_MAX` (3), `STANDUP_BLOCKED_MAX` (2) and `STANDUP_NEXT_MAX` (2).

```bash
arc-standup --text                 # the notes, without building a page
arc-standup --at 2026-08-24T09:00  # any standup's window, without waiting for it
```

### `arc-standup-notify`
The block above was correct for weeks and was not being used, because correct is not the
same as present: it sits on a page you have to remember to open, and the quarter hour
before a call is exactly when nobody remembers a page exists. Two weeks of measurement
found not one of the page's own controls ever touched. So the same eight lines now arrive
on the screen at 10:15 on a standup morning — a desktop notification carrying the block
verbatim, with the artifact URL as its last line.

**It delivers the morning's composition rather than a fresh one**, and that is a choice
rather than a shortcut. A re-run at 10:10 would cost model calls, would have to sit behind
the quota guard and the lock, and would make the notification only as reliable as five
minutes of git, GitLab, Jira and Slack on a laptop that has been awake for ten. And the
staleness is not where it looks: the window opens at the *last* standup and closes at the
*next* one, so the 07:10 build and a 10:15 read on the same morning are asking about the
same interval. What the morning's text is missing is the three hours before the call, which
is the part still in your head. `arcs` leaves the block in `standup.json` beside the page,
carrying the same `text` field the *copy* button carries, so the spoken, pasted and
notified versions are one composition.

**It skips rather than catches up.** The timer sets `Persistent=false`, the exact opposite
of the refresh timer and for the mirror-image reason: a rebuild missed at 07:10 is worth
doing at 08:04 when the lid opens, and prep missed at 10:15 is worth nothing at 11:00
because the standup has happened. The schedule is a convenience and not the authority —
`--install-timer` derives `OnCalendar` (days, time, timezone) from `STANDUP_DAYS`,
`STANDUP_TIME` and `STANDUP_TZ` minus the lead, and the program re-derives the same
calendar on every run through `arc-standup`'s own `cadence()`. A cadence changed in `.env`
and never reinstalled costs a wasted wake-up, never a wrong one.

**It gives and never asks**, which is the whole difference between this and a status bot.
No question, no queue, at most one notification per standup, and silence when the block has
nothing in it. It is silent on failure too — every refusal writes a sentence to
`refresh.log` instead, because an unexplained absence is the failure this workstream keeps
rediscovering. Five refusals it will log by name: no prep on disk, prep composed for a
standup that has been and gone, an empty block, the wrong quarter hour, and one already
delivered this morning.

Env: `STANDUP_NOTIFY_LEAD` (15 minutes before the standup), `WORK_ARCS_ARTIFACT_URL` (the
line that makes the page reachable from the popup) and `WORK_ARCS_NOTIFY` (the notifier,
`~/bin/notification/claude-notify.sh`). The cadence knobs are `arc-standup`'s, shared
rather than duplicated.

```bash
arc-standup-notify --install-timer   # Mon,Wed,Fri 10:15, derived from the cadence
arc-standup-notify --check           # what it would do right now, and why
arc-standup-notify --print           # the prep it is holding
arc-standup-notify --force           # send it anyway, whatever the clock says
```

### `arcs-refresh`
`arcs` rebuilds the work-arcs page; this runs it at 07:10 so the page is already fresh
when you sit down, which was the point of the thing and was still a command you had to
remember to type. Scheduled as a **systemd user timer** rather than a crontab line, and
that is not a preference — see *It catches up after a closed lid* below.

```bash
arcs-refresh --install-timer        # daily at 07:10, catches up after the laptop sleeps
arcs-refresh --install-timer 06:30  # or whenever
arcs-refresh --uninstall-timer      # disable it and remove the units
arcs-refresh --check-quota          # what the guard currently thinks
arcs-refresh --check-refresh        # can the stored refresh token still mint one?
arcs-refresh --hook                 # the arc-record Stop hook block, not installed for you
```

**Install it on this machine** — one line, and it removes the crontab line if one is
still there:

```bash
~/bin/dev-workflow-tools/bin/arcs-refresh --install-timer
```

That copies `systemd/work-arcs-refresh.{service,timer}` into
`~/.config/systemd/user/`, rewrites `ExecStart` to this checkout and `OnCalendar` to the
time asked for, and runs `systemctl --user daemon-reload && systemctl --user enable --now
work-arcs-refresh.timer`. `--install-cron` still exists for machines with no systemd user
manager, but read the next paragraph before choosing it.

**It catches up after a closed lid.** `10 7 * * *` does not fire on a laptop that is
asleep at 07:10, and cron keeps no memory of a run it owes you, so a weekend of closed
lid produced no line in the log at all — an absence rather than a failure, which is the
harder thing to notice and the reason it went a week unspotted. The systemd timer sets
`Persistent=true`: systemd stamps every run and, on its next start, fires immediately for
one it missed. It deliberately does *not* set `WakeSystem` — waking a laptop in a bag at
07:10 to rebuild a page nobody is looking at yet is worse than rebuilding it at 08:04 when
the lid opens. A run that stands down on quota (exit 3) or finds the lock held (exit 4) is
named in `SuccessExitStatus`, so `systemctl --user status` stays meaningful.

One thing a user timer still cannot survive: a machine that is *logged out* rather than
asleep, because the user manager the timer lives in goes with the session. Suspend keeps
the session, which is the failure this fixes, so `Linger=no` is the right default — but if
this ever misses a morning after a reboot nobody logged in from,
`loginctl enable-linger $USER` is the answer, and `systemctl --user list-timers` will show
`LAST`/`PASSED` empty when that is what happened.

**It refreshes its own access token.** The quota guard reads
`claudeAiOauth.accessToken` from `~/.claude/.credentials.json`, and that token is good for
hours rather than for a night: at 07:10 no Claude session has run since the evening
before, `/usage` answers 401, and the fail-closed guard below stands the run down. Every
step of that is correct and the feature does not exist. A 401 — and only a 401 — now buys
one retry with an access token minted from `claudeAiOauth.refreshToken` against the token
endpoint the CLI itself uses. A timeout or a 500 buys nothing, because those say something
about the network and nothing about the token. **The refreshed token is never written
back**: that file belongs to whichever Claude Code session is running, which rewrites it
whole and unlocked, and a lost race there is a broken login rather than a stale page.
`~/bin/hud-claude-usage` has the same 401-means-stale limitation and keeps its stale cache
instead; it could borrow this, but it lives outside this repo.

**And if minting a token is refused, it asks Claude Code to do it.** Minting one directly
has never been observed to work from this machine: the token endpoint answers `429
rate_limit_error` to this client, while Claude Code's own refresh from the same machine
three minutes later succeeded. What *has* been observed working is a live session
refreshing the credential — that is exactly why the same quota check passed by hand at
10:00 on a morning it had failed at 07:10. So a refused mint falls through to the cheapest
session there is (`claude -p --model haiku`), and the retry re-reads the file that session
rewrote. It runs through `lib/headless_claude`, which matters beyond this script: a bare
`claude -p` starts a real session, so the Stop hook would notify and the transcript would
join the corpus `work-arcs` and `arc-cluster` read — every morning the token went stale
would appear on the page as work you did, and `arc-backfill` would feed it back as a
prompt. Set `WORK_ARCS_REFRESH_SESSION_FALLBACK=0` to stand down instead. Nothing reaches a
model on a morning the token was fine, on a network failure, or when the direct mint
worked; `--check-refresh` asks whether the direct route is currently available at all.

**It stands down rather than spend.** `extra_usage` is enabled on this account, so 100%
of the weekly quota is where charging starts, not where anything stops. The run reads
the utilisation first and skips above 80% of the 5-hour window or 90% of the 7-day one
(`WORK_ARCS_REFRESH_MAX_5H`, `WORK_ARCS_REFRESH_MAX_7D`), and skips when it cannot read
them at all — a stale page costs one `/arcs`, a blind run can cost money. Set
`WORK_ARCS_REFRESH_ON_UNKNOWN=run` if you would rather it guessed.

The log distinguishes the ways that can go, because "could not be read" covering all of
them is what hid the expired token for eight days: `quota ok after refreshing the access
token` (it worked), `stood down: 5-hour quota at 83%…` (there was no room),
`the access token is expired and refreshing it was refused (token endpoint HTTP 429,
rate_limit_error: …)` (the credential needs a person), and `the usage endpoint could not
be read (HTTP 000)` (there is no network). A timer that catches up on wake fires while
wifi is still associating, so a read with no HTTP status at all is retried
`WORK_ARCS_REFRESH_NET_TRIES` times, `WORK_ARCS_REFRESH_NET_DELAY` seconds apart, before
it counts as an answer.

**You only hear from it when it didn't run.** A daily "it worked" is training to ignore
notifications. Everything goes to `~/.local/state/work-arcs/refresh.log` (ring-trimmed);
the desktop notification fires only on a skip or a failure. `flock` keeps it from racing
a manual `arcs` — both would move the run-over-run snapshot baseline.

**It builds; it does not publish.** The page is a Claude Code artifact and only a Claude
session can write to that URL. The gain is that `/arcs` becomes upload-only against a
page that is minutes old.

Written for cron's environment rather than a login shell's, which is not cosmetic:
`claude` lives in `~/.local/bin` and `lib/headless_claude.py` calls it by bare name, so
with cron's `PATH=/usr/bin:/bin` every model call raises `FileNotFoundError`, each one is
caught, and the pipeline exits 0 having built a page with no arc names on it. Preflight
refuses to start when a required program is missing, and `could not run claude` in the
output counts as a failed run whatever the exit status says.

## Shell Integration

The `shell/dev-workflow.zsh` provides:

### Keybindings
- `Ctrl+G` - Commit message history widget (with `^f`/`^x`/`^r`/`^o` for conventional commit types)
- `Ctrl+B` - Ref picker ([`fzref`](#fzref-bound-to-ctrlb-and-to-tab-where-a-ref-is-the-only-option)); replaces the word at the cursor
- `Tab` - Also the ref picker, but only where a ref is the only possible argument (needs the hook in `~/.zshrc`, see `fzref`)

### Functions
- `gcm "message"` - Commit with message (saves to history)
- `nvgcm "message"` - Commit without verification hooks

### Aliases

**Commits:**
- `wip` - Quick WIP commit (no hooks)
- `gca` - Amend last commit (no edit)
- `reword` - Amend commit message

**Branches:**
- `r` - Recent branches (uses rr.sh)
- `gc` - Switch branch with preview
- `gcb` - Create and checkout branch

**Reset:**
- `soft` / `so` - Soft reset HEAD~1 + unstage
- `rho` / `gr` / `gru` - Hard reset to upstream

**Stash:**
- `gs` - Stash changes
- `gsk` - Stash with untracked
- `gsp` - Stash pop
- `swip` - Add all + WIP + status

**Fetch/Pull:**
- `p` / `pull` - Pull changes
- `gf` - Fetch all remotes
- `gfpa` - Fetch with prune

**Rebase:**
- `grom` - Rebase onto origin/main
- `gfgrom` - Fetch + rebase origin/main
- `grc` - Continue rebase
- `gra` - Abort rebase

**Cherry-pick:**
- `gcpc` - Continue cherry-pick
- `gcpa` - Abort cherry-pick

**Other:**
- `push` / `mush` - Push changes
- `os` - Alias for oneshot

## Troubleshooting

**"JIRA_EMAIL and JIRA_API_TOKEN must be set"**
→ Create `.env` from `.env.example`

**"glab CLI not found"**
→ Install from https://gitlab.com/gitlab-org/cli

**Jira tickets not showing**
→ Check credentials, verify `JIRA_PROJECT`, try `r -r`

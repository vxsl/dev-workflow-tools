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
```

### `oneshot` (alias: `os`)
One-shot workflow: staged changes → branch → commit → MR.
```bash
oneshot                    # Interactive
oneshot PROJ-1234          # Use ticket
oneshot https://slack...   # From Slack thread
oneshot --from-commit      # Ticket + MR title/description from the commit
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

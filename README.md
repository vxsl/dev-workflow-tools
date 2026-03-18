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
```

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
- `⚡` Worktree exists
- `⌘` Worktree status (green=clean, orange=dirty)

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
   - Kill the current process in the pane (Ctrl-C)
   - cd to the selected worktree
   - Run the configured command

**Visual Indicators:**
- `▶` (green) - This worktree is running the dev server
- `⏩` (cyan) - This worktree is running tsc-watch

**Finding your pane IDs:**
```bash
# List all tmux panes with their IDs
tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index} - #{pane_title}"
```

### `fzedit`
Interactive file finder/editor.

**Keys:** `<CR>` nvim | `^o` cursor | `^s` shell | `^r` refresh | `^c` copy path

### `restage`
Unstage two WIP commits, keeping oldest staged.

### `apply_staged_to_commit`
Apply staged changes to a commit via fixup+autosquash.
```bash
apply_staged_to_commit <commit-sha>
```

## Shell Integration

The `shell/dev-workflow.zsh` provides:

### Keybindings
- `Ctrl+G` - Commit message history widget (with `^f`/`^x`/`^r`/`^o` for conventional commit types)

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

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
Optional: `xclip`, `bat`, `eza`, `fd`, `wmctrl`

## Configuration

Edit `.env`:
```bash
JIRA_DOMAIN="company.atlassian.net"
JIRA_PROJECT="PROJ"
JIRA_EMAIL="your-email@company.com"
JIRA_API_TOKEN="your-api-token"

# Optional
JIRA_ME="Your Name"
TICKET_CREATOR_BOT_TOKEN="xoxb-..."
FZF_PERSIST_MODE=1  # For xmonad scratchpads/tmux popups
```

Get API token: https://id.atlassian.com/manage-profile/security/api-tokens

### FZF Persist Mode

By default, fzf tools exit after selection (normal CLI behavior). Set `FZF_PERSIST_MODE=1` if using xmonad scratchpads or tmux popups to keep the interface open after actions.

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

### `oneshot` (alias: `osgcm`)
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

**Keys:** `^l` load more | `^o` toggle local/remote

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
- `osgcm` - Alias for oneshot

## Troubleshooting

**"JIRA_EMAIL and JIRA_API_TOKEN must be set"**
→ Create `.env` from `.env.example`

**"glab CLI not found"**
→ Install from https://gitlab.com/gitlab-org/cli

**Jira tickets not showing**
→ Check credentials, verify `JIRA_PROJECT`, try `r -r`

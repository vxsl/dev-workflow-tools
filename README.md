# dev-workflow-tools

A collection of interactive Git + Jira + GitLab workflow tools with beautiful fzf interfaces.

## 🎯 What is this?

A cohesive set of scripts and shell integrations that streamline your development workflow:
- **Interactive branch management** with Jira ticket integration
- **Quick ticket creation** from Slack threads or CLI
- **One-shot workflows** (stage → branch → commit → MR)
- **MR creation** with automatic Jira updates
- **Git utilities** for common operations (WIP commits, rebasing, etc.)

## 📦 Tools Included

### Core Scripts

#### `jira-fzf`
Interactive Jira ticket browser with fuzzy search.
- Browse all tickets in your project
- Create new tickets
- Open tickets/MRs in browser
- Checkout branches for tickets
- Create MRs from tickets
- Live preview with ticket details

**Keybindings:**
- `<CR>` - Maximize preview
- `<C-y>` - Copy ticket URL/key
- `<C-o>` - Open ticket/MR in browser
- `<C-t>` - Create new ticket
- `<C-g>` - Create MR for ticket
- `<C-c>` - Checkout ticket branch
- `<C-s>` - Change sort order
- `<C-r>` - Refresh cache

#### `create-jira-ticket`
Standalone Jira ticket creation with interactive prompts.
- Choose issue type, priority, assignee, labels, sprint
- Link to Slack threads automatically
- Auto-caches new tickets for jira-fzf

**Usage:**
```bash
create-jira-ticket                                # Interactive
create-jira-ticket --summary "Fix bug"            # Quick create
create-jira-ticket --slack-url URL                # Link to Slack
create-jira-ticket --dry-run                      # Test without creating
```

#### `oneshot` (alias: `osgcm`)
One-shot workflow: staged changes → branch → commit → MR.
- Select or create Jira ticket
- Create branch from ticket
- Commit staged changes
- Push and create MR
- Post to Slack thread (optional)

**Usage:**
```bash
oneshot                              # Interactive
oneshot UB-1234                      # Use existing ticket
oneshot https://slack.com/...        # Create ticket + link to Slack
```

#### `publish-changes`
Create GitLab Merge Requests with Jira integration.
- Interactive branch/target selection
- Preview commits in MR
- Auto-push to origin
- Update Jira ticket (add comment, set QA branch, transition status)
- Open MR + Jira in browser

**Usage:**
```bash
publish-changes                      # Interactive
publish-changes UB-1234              # With Jira ticket
publish-changes --branch feat/foo    # Specific branch
publish-changes --target main        # Pre-select target
publish-changes --draft              # Create as draft MR
```

#### `rr.sh` (alias: `r`)
Recent branches selector with Jira integration.
- Shows recent local branches (default) or remote branches
- Displays Jira ticket title, status, assignee
- Color-coded by status
- Highlights your assigned tickets

**Usage:**
```bash
r                    # Recent local branches
r -o                 # Remote branches
r -r                 # Force refresh cache
r -n 50              # Show 50 branches
```

**Keybindings:**
- `<C-l>` - Load more branches
- `<C-o>` - Toggle local/remote mode

#### `restage`
Unstage two WIP commits, keeping oldest staged and newest unstaged.

**Usage:**
```bash
restage              # After two 'wip' commits
```

#### `apply_staged_to_commit`
Apply staged changes to a specific commit in history using fixup + autosquash rebase.

**Usage:**
```bash
apply_staged_to_commit <commit-sha>
```

### Shell Integration

The `shell/dev-workflow.zsh` file provides:
- Git workflow aliases (`wip`, `gca`, `grom`, etc.)
- Commit message history (Ctrl+G widget)
- Functions (`gcm`, `nvgcm`)
- PATH setup for tools

## 🚀 Installation

### 1. Clone as submodule in ~/bin

```bash
cd ~/bin
git submodule add <your-repo-url> dev-workflow-tools
git submodule update --init --recursive
```

### 2. Configure credentials

```bash
cd ~/bin/dev-workflow-tools
cp .env.example .env
# Edit .env with your credentials
nvim .env
```

Required:
- `JIRA_EMAIL` - Your Jira email
- `JIRA_API_TOKEN` - Get from https://id.atlassian.com/manage-profile/security/api-tokens

Optional:
- `TICKET_CREATOR_BOT_TOKEN` - Slack bot token for oneshot
- `JIRA_DOMAIN` - Default: urbanlogiq.atlassian.net
- `JIRA_PROJECT` - Default: UB

### 3. Add to your shell

Add to `~/.zshrc`:

```zsh
# dev-workflow-tools integration
source ~/bin/dev-workflow-tools/shell/dev-workflow.zsh
```

Reload your shell:
```bash
exec zsh
```

## 📋 Requirements

### Required
- `git` - Version control
- `fzf` - Fuzzy finder for interactive selection
- `jq` - JSON processing
- `curl` - API calls to Jira/GitLab
- `glab` - GitLab CLI (for publish-changes and MR features)

### Optional
- `xclip` or `wl-copy` - Clipboard integration
- `wmctrl` - Focus Firefox window for MR/ticket opening
- `bat` - Better preview in fzf (fallback: cat)
- `eza` - Better preview in fzf (fallback: ls)

### Install dependencies

**Fedora/RHEL:**
```bash
sudo dnf install fzf jq curl xclip wmctrl bat eza
```

**Ubuntu/Debian:**
```bash
sudo apt install fzf jq curl xclip wmctrl bat eza
```

**glab (GitLab CLI):**
```bash
# Install from https://gitlab.com/gitlab-org/cli
# Or via package manager
```

## 🎨 Features

### Jira Integration
- Browse and search tickets
- Create tickets with rich prompts
- Auto-detect tickets from branch names
- Update ticket status on MR creation
- Add MR links as comments
- Set QA branch custom field

### GitLab Integration
- Create MRs from CLI
- Interactive target branch selection
- Preview commits before creating MR
- Draft MR support
- Auto-open in browser

### Slack Integration
- Link Jira tickets to Slack threads
- Post ticket links back to Slack
- Post MR links to Slack threads

### Git Workflow
- Fast branch switching with fuzzy search
- Jira-aware branch listing
- WIP commit workflows
- Commit message history and reuse
- Interactive rebasing helpers

## 🔧 Configuration

### Environment Variables

All tools respect these environment variables (set in `.env` or shell):

```bash
# Jira
JIRA_EMAIL="your-email@company.com"
JIRA_API_TOKEN="your-api-token"
JIRA_DOMAIN="company.atlassian.net"
JIRA_PROJECT="PROJ"
JIRA_QA_BRANCH_FIELD="customfield_xxxxx"  # Auto-detected if not set

# Slack
TICKET_CREATOR_BOT_TOKEN="xoxb-..."

# Display
JIRA_ME="Your Name"  # Highlight your tickets in rr.sh
```

### Customization

Modify `shell/dev-workflow.zsh` to:
- Add/remove aliases
- Change keybindings
- Customize colors in rr.sh
- Adjust default sort orders

## 🎓 Common Workflows

### Start work on a Jira ticket

```bash
# Option 1: Browse tickets
jira-fzf
# Press Ctrl+C to checkout the branch

# Option 2: Quick switch
r
# Type ticket number, press Enter
```

### Create ticket from Slack thread

```bash
# Copy Slack thread URL, then:
oneshot https://slack.com/archives/...
# Follow prompts, creates ticket + MR + posts back to Slack
```

### Quick WIP commit workflow

```bash
git add -A       # Stage changes
wip              # Quick WIP commit (no hooks)
# ... work on other branch ...
git switch UB-1234
soft             # Soft reset WIP, unstage
# Continue editing
```

### Create MR for current branch

```bash
publish-changes
# Interactive: select target, create MR, update Jira
```

### Commit with message history

```bash
# Press Ctrl+G in terminal
# Select from recent messages or type new
# Ctrl+F/X/R/O for conventional commit prefixes
```

## 🐛 Troubleshooting

### "Error: JIRA_EMAIL and JIRA_API_TOKEN must be set"
- Create `.env` file from `.env.example`
- Add your credentials

### "Error: glab CLI not found"
- Install glab: https://gitlab.com/gitlab-org/cli

### MRs not opening in browser
- Install `xdg-open` (Linux) or ensure default browser is set
- Optional: Install `wmctrl` to focus specific Firefox window

### Jira tickets not showing in rr.sh
- Check API credentials
- Verify `JIRA_PROJECT` matches your project key
- Try `r -r` to force cache refresh

### Keybindings not working
- Ensure you've sourced `shell/dev-workflow.zsh`
- Check for conflicts with other zsh plugins
- Some keybindings require `zsh-vi-mode`

## 📜 License

[Your License Here]

## 🤝 Contributing

[Your Contributing Guidelines Here]


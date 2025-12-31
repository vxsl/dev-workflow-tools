# Installation Guide

## Current Status ✅

The dev-workflow-tools have been set up and are ready to use! Here's what's been done:

1. ✅ Created directory structure in `~/bin/dev-workflow-tools/`
2. ✅ Moved all scripts to `bin/` subdirectory
3. ✅ Created shell integration in `shell/dev-workflow.zsh`
4. ✅ Updated `~/.zshrc` to source the integration
5. ✅ Initialized git repository
6. ✅ Created `.env.example` template

## Next Steps

### 1. Set up credentials

Copy the `.env.example` file and add your credentials:

```bash
cd ~/bin/dev-workflow-tools
cp .env.example .env
nvim .env
```

Fill in:
- `JIRA_EMAIL` - Your Jira email
- `JIRA_API_TOKEN` - Get from https://id.atlassian.com/manage-profile/security/api-tokens
- `TICKET_CREATOR_BOT_TOKEN` - (Optional) Slack bot token for oneshot

### 2. Reload your shell

```bash
exec zsh
```

The tools should now be available:
- `jira-fzf` - Interactive ticket browser
- `r` - Recent branches
- `osgcm` or `oneshot` - One-shot workflow
- All git aliases (`wip`, `gca`, `grom`, etc.)

### 3. (Optional) Push to remote repository

If you want to host this as a proper git repository:

```bash
cd ~/bin/dev-workflow-tools

# Create a new repository on GitHub/GitLab, then:
git remote add origin <your-repo-url>
git push -u origin main
```

### 4. (Optional) Set up as proper submodule

After pushing to a remote, you can convert this to a proper submodule:

```bash
cd ~/bin
git rm -r --cached dev-workflow-tools
git submodule add <your-repo-url> dev-workflow-tools
git commit -m "Add dev-workflow-tools as submodule"
```

## What Changed in Your .zshrc

The following sections were commented out (now in dev-workflow-tools):
- `gcm-widget` function (Ctrl+G commit message selector)
- `gcm` and `nvgcm` functions
- Git workflow aliases (`wip`, `gca`, `grom`, `r`, `osgcm`, etc.)

These are now sourced from:
```
~/bin/dev-workflow-tools/shell/dev-workflow.zsh
```

## Verification

Test that everything works:

```bash
# Should show help/usage
jira-fzf --help 2>&1 | head -5

# Should show recent branches
r

# Should show commit message widget
# Press Ctrl+G in your terminal
```

## Troubleshooting

### "command not found"
- Make sure you've reloaded your shell: `exec zsh`
- Verify the source line was added to `.zshrc`:
  ```bash
  grep "dev-workflow-tools" ~/.zshrc
  ```

### Jira API errors
- Check your `.env` file has correct credentials
- Verify API token at: https://id.atlassian.com/manage-profile/security/api-tokens

### Git aliases not working
- The old aliases in `.zshrc` are commented out
- New aliases come from `dev-workflow.zsh`
- Reload shell: `exec zsh`

## File Locations

```
~/bin/dev-workflow-tools/
├── .env                     # Your credentials (gitignored)
├── .env.example             # Template
├── README.md                # Full documentation
├── INSTALL.md               # This file
├── bin/                     # Executable scripts
│   ├── jira-fzf
│   ├── create-jira-ticket
│   ├── oneshot
│   ├── publish-changes
│   ├── rr.sh
│   ├── restage
│   └── apply_staged_to_commit
├── lib/                     # Shared libraries
│   └── fzf-persist
├── shell/                   # Shell integration
│   └── dev-workflow.zsh
└── doc/                     # Documentation
    ├── .zshrc.new           # Full updated .zshrc example
    └── zshrc_changes.md     # List of changes made
```

## Original Script Locations

The original scripts are still in `~/bin/` (you may want to clean them up later):
- `~/bin/jira-fzf` → `~/bin/dev-workflow-tools/bin/jira-fzf`
- `~/bin/create-jira-ticket` → `~/bin/dev-workflow-tools/bin/create-jira-ticket`
- `~/bin/oneshot` → `~/bin/dev-workflow-tools/bin/oneshot`
- `~/bin/publish-changes` → `~/bin/dev-workflow-tools/bin/publish-changes`
- `~/bin/rr.sh` → `~/bin/dev-workflow-tools/bin/rr.sh`
- `~/bin/restage` → `~/bin/dev-workflow-tools/bin/restage`
- `~/bin/apply_staged_to_commit` → `~/bin/dev-workflow-tools/bin/apply_staged_to_commit`

You can remove the originals once you've verified everything works:
```bash
cd ~/bin
rm jira-fzf create-jira-ticket oneshot publish-changes restage apply_staged_to_commit
```

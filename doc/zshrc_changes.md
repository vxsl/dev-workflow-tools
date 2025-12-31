# Changes to .zshrc

This file documents the changes needed to your `~/.zshrc` to integrate dev-workflow-tools.

## Changes Made

### Remove these sections (now in dev-workflow-tools):

1. **Lines 80-122**: `gcm-widget` function (moved to dev-workflow.zsh)
2. **Lines 204-217**: `nvgcm` and `gcm` functions (moved to dev-workflow.zsh)
3. **Lines 240, 252, and git aliases 248-281**: Git workflow aliases (moved to dev-workflow.zsh)

### Add this section (source dev-workflow-tools):

Add after line 189 (after other source statements):

```zsh
# ============================================================================
# dev-workflow-tools integration
# Git + Jira + GitLab workflow tools with fzf interfaces
# ============================================================================
if [[ -f "$HOME/bin/dev-workflow-tools/shell/dev-workflow.zsh" ]]; then
    source "$HOME/bin/dev-workflow-tools/shell/dev-workflow.zsh"
fi
```

## Complete Updated .zshrc

Below is your complete updated `.zshrc` with dev-workflow-tools integrated:

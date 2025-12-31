# Migration Guide: Environment Variables Now Required

## 🚨 Breaking Change

All company-specific defaults have been removed. You **must** now set these environment variables in your `.env` file.

## Required Changes to Your .env

Your `.env` file must now include these **required** variables:

```bash
# Previously had defaults, now REQUIRED:
JIRA_DOMAIN="your-company.atlassian.net"  # Was: urbanlogiq.atlassian.net
JIRA_PROJECT="YOUR_KEY"                   # Was: UB

# Already required (no change):
JIRA_EMAIL="your-email@company.com"
JIRA_API_TOKEN="your-token"
```

### New Optional Variables

```bash
# Highlight your assigned tickets in rr.sh
JIRA_ME="Your Display Name"

# Auto-detected if not set
JIRA_QA_BRANCH_FIELD="customfield_12345"
```

## Quick Setup

```bash
cd ~/bin/dev-workflow-tools

# If you don't have a .env file yet:
cp .env.example .env

# Edit and fill in YOUR values:
nvim .env
```

### Example .env File

```bash
JIRA_DOMAIN="mycompany.atlassian.net"
JIRA_PROJECT="DEV"
JIRA_EMAIL="john.doe@mycompany.com"
JIRA_API_TOKEN="ATATT3xFfGF0..."
JIRA_ME="John Doe"
```

## What Changed

### Before (hardcoded defaults):
```bash
JIRA_DOMAIN="${JIRA_DOMAIN:-urbanlogiq.atlassian.net}"
JIRA_PROJECT="${JIRA_PROJECT:-UB}"
```

### After (environment-driven):
```bash
JIRA_DOMAIN="${JIRA_DOMAIN}"
JIRA_PROJECT="${JIRA_PROJECT}"

# Validate required environment variables
if [ -z "$JIRA_DOMAIN" ] || [ -z "$JIRA_PROJECT" ]; then
    echo "Error: JIRA_DOMAIN and JIRA_PROJECT must be set" >&2
    exit 1
fi
```

## Affected Scripts

All scripts now validate required variables on startup:
- `jira-fzf`
- `create-jira-ticket`
- `oneshot`
- `rr.sh`
- `publish-changes` (only if using Jira features)

## Error Messages

If you forget to set required variables, you'll see:

```
Error: JIRA_DOMAIN and JIRA_PROJECT must be set in .env or environment
```

**Solution:** Create/update your `.env` file with the required values.

## Why This Change?

- **Portability**: Tools work for any company/project
- **Security**: No company-specific data in version control
- **Clarity**: Explicit configuration over hidden defaults
- **Sharing**: Can share tools publicly without exposing internal details

## Testing

After updating your `.env`:

```bash
# Reload shell
exec zsh

# Test Jira connection
jira-fzf

# Test branch listing
r

# All should work without errors
```


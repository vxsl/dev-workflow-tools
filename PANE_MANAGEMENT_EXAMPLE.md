# Tmux Pane Management - Example Setup

This is an example of how to configure `rr` to manage your dev server and tsc-watch panes.

## Step 1: Find Your Tmux Pane IDs

First, list all your tmux panes to find the IDs:

```bash
tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index} - #{pane_title}"
```

Example output:
```
tmuxa-1:0.0 - tig status
tmuxa-1:0.1 - yarn run-p tailwind dev    ← Dev server pane
tmuxa-1:0.2 - yarn tsc-watch              ← TSC watch pane
tmuxa-1:0.3 - zsh
tmuxa-1:0.4 - tig
```

## Step 2: Configure .env

Add to your `.env` file:

```bash
# Enable pane management
RR_PANE_MGMT_ENABLED=true

# Pane 1 - Dev Server
RR_PANE_1_ID="tmuxa-1:0.1"
RR_PANE_1_DIR="client/web"                    # Subdirectory within worktree
RR_PANE_1_COMMAND="yarn install && yarn run-p tailwind dev"
RR_PANE_1_LABEL="dev"                         # Short label for display
RR_PANE_1_INDICATOR="▶"                       # Visual indicator
RR_PANE_1_KEY="f4"                            # Keybinding

# Pane 2 - TypeScript Watch
RR_PANE_2_ID="tmuxa-1:0.2"
RR_PANE_2_DIR="client/web"
RR_PANE_2_COMMAND="yarn tsc-watch"
RR_PANE_2_LABEL="tsc"
RR_PANE_2_INDICATOR="⏩"
RR_PANE_2_KEY="f5"
```

## Step 3: Use in rr

1. Run `r` to open the branch selector
2. You'll see new keybindings in the header:
   ```
   📁 LOCAL MODE │ ... │ F4: dev │ F5: tsc │ F6: all │ F7: curr
   ```
3. Navigate to a worktree (any branch with ⚡⌘ badges)
4. Press `F4` to switch the dev server to this worktree
5. Press `F5` to switch the tsc-watch to this worktree
6. Press `F6` to switch **ALL** panes to the selected branch
7. Press `F7` (anywhere) to switch **ALL** panes to your current branch

## What Happens When You Press F4/F5

When you press F4 (or F5), `rr` will:

1. **Check** if the branch has a worktree
   - If no worktree exists, it will **prompt** you to create one
2. **Kill** the current process in the pane (sends Ctrl-C)
3. **Clear** the pane
4. **cd** to the selected worktree directory (with subdirectory if configured)
5. **Verify** the directory change was successful
6. **Run** the configured command (e.g., `yarn install && yarn run-p tailwind dev`)
7. **Mark** this worktree as the active target with a visual indicator

## F6 - Switch All Panes

Press `F6` on any branch to switch **all configured panes** to that branch:
- Prompts to create a worktree if it doesn't exist
- Switches all panes (dev server, tsc-watch, etc.) at once
- Reports success/failure count

## F7 - Switch All Panes to Current Directory/Worktree

Press `F7` to switch **all configured panes** to your current worktree:
- Doesn't require selecting a branch in fzf
- Uses your **current directory** (not branch name)
- Perfect for when you're already in a worktree and want all panes to switch to it
- If you're in the main repo, it will use the current branch and create a worktree if needed

## Visual Indicators

After setting a worktree as a pane target, you'll see badges next to the worktree indicator:

```
  UB-6227       │ Fix login bug              │ ● In Progress    │ ...
★ UB-6380 ⚡⌘▶⏩ │                            │ ● In Progress    │ ...
  UB-5421 ⚡⌘   │                            │ ○ To Do          │ ...
```

Legend:
- `⚡` - Worktree exists
- `⌘` - Worktree is clean (green) or dirty (orange)
- `▶` - Dev server is running in this worktree (green)
- `⏩` - TSC watch is running in this worktree (cyan)

## Example Workflow

1. You have worktrees for `UB-6380`, `UB-6227`, and `UB-5421`
2. Currently working on `UB-6380` (dev server running there)
3. Need to test `UB-6227` quickly
4. Run `r`, select `UB-6227`, press `F4`
5. Dev server switches to `UB-6227` worktree
6. The `▶` indicator moves from `UB-6380` to `UB-6227`
7. Your tmux pane automatically restarts the dev server in the new worktree

## Adding More Panes

You can add more panes by incrementing the number:

```bash
# Pane 3 - Jest watch (example)
RR_PANE_3_ID="tmuxa-1:0.3"
RR_PANE_3_DIR="client/web"
RR_PANE_3_COMMAND="yarn jest --watch"
RR_PANE_3_LABEL="jest"
RR_PANE_3_INDICATOR="🧪"
RR_PANE_3_KEY="f9"
```

Panes are automatically detected - no code changes needed!
Available keybindings: f4-f7, f9-f12 (F6 and F7 are reserved for "all panes" operations)

## Tracking the Current Dev Environment (Optional)

If you have tools that need to know which `.env` file is "currently active" (e.g., which worktree is running the dev server), you can add a symlink update to your pane command:

```bash
# Instead of:
RR_PANE_1_COMMAND="yarn install && yarn run-p tailwind dev"

# Use (note: \$PWD/.env since we're already in client/web from RR_PANE_1_DIR):
RR_PANE_1_COMMAND="mkdir -p ~/.config/dev-workflow && ln -sf \$PWD/.env ~/.config/dev-workflow/current-env; yarn install && yarn run-p tailwind dev"
```

**Important**:
- Use `\$PWD` (escaped with backslash) so it expands in the target pane, not when sourcing `.env`
- Use `\$PWD/.env` not `\$PWD/client/web/.env` since the pane is already in the `client/web` subdirectory (from `RR_PANE_1_DIR`)
- Use semicolon (`;`) before `yarn` to ensure yarn runs even if symlink fails

### How it works:

1. When you press F4 to switch the dev pane to a new worktree
2. The command runs in the new worktree directory
3. `ln -sf $PWD/client/web/.env ~/.config/dev-workflow/current-env` creates/updates the symlink
4. The symlink now points to the current worktree's `.env` file
5. Other tools can read this symlink to access the "current" environment

### Example use case:

```bash
# After switching dev server to UB-6227 worktree:
$ ls -l ~/.config/dev-workflow/current-env
lrwxr-xr-x 1 kyle kyle 56 Feb 12 10:30 /home/kyle/.config/dev-workflow/current-env -> /home/kyle/work/repos/ul.UB-6227/client/web/.env

# After switching to UB-6380:
$ ls -l ~/.config/dev-workflow/current-env
lrwxr-xr-x 1 kyle kyle 56 Feb 12 10:35 /home/kyle/.config/dev-workflow/current-env -> /home/kyle/work/repos/ul.UB-6380/client/web/.env

# Use in scripts:
$ cat $(readlink ~/.config/dev-workflow/current-env)
# Shows the .env for whichever worktree is currently running dev server
```

## Disabling

To disable pane management, just set:

```bash
RR_PANE_MGMT_ENABLED=false
```

Or comment out the pane management section in `.env`.

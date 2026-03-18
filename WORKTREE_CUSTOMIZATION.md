# Worktree Customization

When creating new worktrees with `create-wt` or rr's F2/F3 keybindings, you can automatically customize the copied files using these configuration methods.

## 0. Excluding Large Build Artifacts

Skip copying large build directories like Rust's `target/`:

```bash
# Skip target/ directories when copying (default if not set)
WORKTREE_COPY_EXCLUDE="target/"

# Multiple patterns (space-separated)
WORKTREE_COPY_EXCLUDE="target/ *.log build/ dist/"
```

**Why exclude `target/`?**
- Rust's `target/debug` can be hundreds of MB to several GB
- Contains build artifacts specific to each build
- Can be regenerated with `cargo build`
- Copying it wastes time and disk space

## 1. VS Code Workspace Settings (Simple)

Add to your `.env`:

```bash
# Example: Disable Rust analyzer in all new worktrees
VSCODE_WORKSPACE_SETTINGS='{"rust-analyzer.enable": false}'

# Example: Multiple settings
VSCODE_WORKSPACE_SETTINGS='{"rust-analyzer.enable": false, "editor.formatOnSave": true, "eslint.enable": false}'
```

**How it works:**
- Settings are merged into `.vscode/settings.json` in `client/web/` of the new worktree
- If the file exists, settings are merged (your new settings override existing ones)
- If the file doesn't exist, it's created with your settings
- Uses proper JSON parsing/merging via Python

## 2. Post-Worktree Hook (Advanced)

For arbitrary customization beyond VS Code settings, create a script and reference it in `.env`:

```bash
POST_WORKTREE_HOOK="/home/username/bin/my-worktree-setup.sh"
```

**Example hook script** (`~/bin/my-worktree-setup.sh`):

```bash
#!/bin/bash
WORKTREE_PATH="$1"

# Disable Rust in Cursor too
CURSOR_SETTINGS="$WORKTREE_PATH/client/web/.cursor/settings.json"
if [ -f "$CURSOR_SETTINGS" ]; then
    python3 -c "
import json
with open('$CURSOR_SETTINGS', 'r') as f:
    settings = json.load(f)
settings['rust-analyzer.enable'] = False
with open('$CURSOR_SETTINGS', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
"
fi

# Add custom .nvimrc
cat > "$WORKTREE_PATH/client/web/.nvimrc" << 'EOF'
set relativenumber
let g:ale_linters = {'javascript': ['eslint']}
EOF

# Any other custom setup...
echo "✓ Custom worktree setup complete"
```

Make it executable:
```bash
chmod +x ~/bin/my-worktree-setup.sh
```

**How it works:**
- The hook script receives the full worktree path as `$1`
- It runs after file copying completes
- You can modify any files, create new ones, run commands, etc.
- Must be executable (`chmod +x`)

## Execution Order

When creating a new worktree:

1. **Worktree created** (`git worktree add`)
2. **Files copied** (`.env`, `.vscode`, `node_modules`, etc.)
   - Excludes patterns from `WORKTREE_COPY_EXCLUDE` (e.g., `target/`)
3. **VS Code settings merged** (if `VSCODE_WORKSPACE_SETTINGS` is set)
4. **Post-worktree hook runs** (if `POST_WORKTREE_HOOK` is set and executable)
5. **Script switches to** `client/web` directory

## Use Cases

**VS Code Settings** - Best for:
- Disabling specific language servers (Rust, Go, etc.)
- Workspace-specific editor config
- Simple JSON modifications

**Post-Worktree Hook** - Best for:
- Modifications to multiple tools (VS Code + Cursor + Vim)
- Creating additional files
- Running setup commands
- Complex conditional logic
- Modifications based on branch name or JIRA ticket

## Tips

1. **Test your hook script manually first:**
   ```bash
   ~/bin/my-worktree-setup.sh /path/to/test/worktree
   ```

2. **Add error handling to hooks:**
   ```bash
   #!/bin/bash
   set -e  # Exit on error
   WORKTREE_PATH="${1:?Worktree path required}"
   ```

3. **Use both methods together:**
   - `VSCODE_WORKSPACE_SETTINGS` for simple VS Code tweaks
   - `POST_WORKTREE_HOOK` for everything else

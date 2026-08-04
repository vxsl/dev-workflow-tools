# The editing workflow

Agentic programming with occasional hand-coding, without opening Cursor.

Four tools, each owning one question:

| | | |
|---|---|---|
| **fzedit** | *which file* | the pad — `Ctrl-Alt-Space`, always up, never in the way |
| **nvim** | *change it* | opens inside the pad; quitting drops you back on the picker |
| **tig** | *how did it get like this* | history and diffs, reachable from the pad and back |
| **rr** | *which branch / ticket* | worktrees, Jira state, MR state |

They hand off to each other rather than nesting, so you are never more than one
keystroke from the tool that answers the question you actually have.

---

## The loop

**1 — Agent works.** It edits files in a worktree. You are not in the editor.

**2 — See what changed.** `Ctrl-Alt-Space`, then `S-TAB` twice to the `changed` rung.
That is the source-control sidebar: every dirty and untracked file, badged
(`M` modified, `A` added, `?` untracked, `!!` conflicted), diff in the preview pane.
`S-TAB` once more narrows to `conflicts` alone.

The header carries the ladder with live counts, and warns when *another* worktree has
a rebase parked in it — because `conflicts (0)` on a clean tree looks exactly like
being pointed at the wrong worktree, and with two branches sharing a prefix that is
easy.

**3 — Read the changes.** `^space` to mark the interesting files, then `^E` — all of
them open in **one** nvim, so the LSP starts once instead of once per file. `:bn` /
`:bp` between them.

Or `<leader>gd` once inside: the whole working tree as a diff panel, file list on the
left.

**4 — Hand-edit.** See the nvim half below. `<leader>j` when done.

**5 — Stage.** `^A` on a row in the pad toggles staged/unstaged. Or per-hunk inside
nvim with `<leader>ga`.

**6 — Understand something.** `^L` on a file → its history in tig. From tig, `E` jumps
straight back into the pad at the line under your cursor. That loop is the whole point:
find a file, read how it got that way, land in the exact line that interests you.

**7 — Next branch.** `^T` → rr, with tickets, MR state, dirty flags, and the ability to
create a worktree on the spot. Or type a branch name in the pad and hit a `⊙` row.

---

## fzedit — which file

`F1` in the pad prints the full keymap. The parts worth internalising:

### Scope is one axis

```
conflicts  ⊂  changed  ⊂  worktree  ⊂  home
```

`TAB` widens, `S-TAB` narrows. It launches on `home` because the pad is a general
"open a file" tool first, and starting narrow means the file you want is often simply
absent. The rung resets on every launch — landing in a rung you set days ago is just
confusing.

`home` is **not** everything on disk. It prunes the other worktrees of your current
repo and a noise list of package caches and toolchains, which is what takes it from
2.86M rows to ~32k. So the way to reach a file in a *different* worktree is not to
search harder — it is `^K` or a `⊙` row.

### Worktrees are rows

`⊙` rows, cyan, appended after the files so a filename query never surfaces one but a
branch or ticket-shaped query does. `enter` on one re-scopes the picker instead of
opening an editor. Ordering is genuine navigation recency, shared with rr.

### The two directions

- `⊙` row / `^T` — **worktree first**, then find the file.
- `^K` — **file first**, then the worktree. Same repo-relative path, over there.
  This is the one you want more often than you would guess: you have already found the
  file, and what you actually want is the copy on the branch you are about to work on.

### Content search

`^F` — ripgrep over file *contents*, re-running on every keystroke, `enter` landing on
the matching line. Inside it:

- `^F` again freezes the results and fuzzy-filters them — the two-stage search you want
  when a common identifier matches four hundred lines.
- `^E` sends every match to nvim's quickfix list. `:cn` / `:cp` to walk them.

### Tabs

A tab is a whole fzedit instance with its own scope and rung. `^G` new, `^X` / `^B`
left / right, `C-M-w` close (it refuses to close the last one, which would take the pad
down). tig's `E` opens files into a new tab.

---

## nvim — change it

`<leader>` is space. `<leader>sk` searches every keymap; which-key shows the tree as
you type, with `<leader>g` and `<leader>t` labelled.

### Save

| | |
|---|---|
| `<leader>j` | format → eslint `--fix` → write |
| `<leader>h` | organizeImports → format → eslint `--fix` → write |
| `<leader>J` | format **only the lines you changed** vs git — no whole-file diff noise |
| `:w` | format on save |

All async: the editor never blocks, the fixes land when they land. If a save takes
over 750ms it tells you how long, which is the number to watch if it starts feeling
slow.

`<leader>J` is the one to reach for in a file that was never prettier-clean — it
formats your hunks and leaves the other 400 lines alone.

### Hunks and diffs

The distinction worth holding onto, because it is easy to conflate:

- **`<leader>t*` / `<leader>g*` compare the working tree against something** — "how
  does my copy differ from X". Your uncommitted work is the subject.
- **`<leader>tc` / `<leader>gC` show a commit's own patch** — "what did X change", with
  uncommitted work excluded entirely.

`<leader>t*` is scoped to the current file; `<leader>g*` spans the repo.

| | |
|---|---|
| `]c` / `[c` | next / previous changed hunk (also works in diff mode) |
| `<leader>gp` | preview this hunk in a float, no mode switch |
| `<leader>ga` / `<leader>gA` | stage hunk / buffer (`ga` toggles, so it unstages too) |
| `<leader>gr` / `<leader>gR` | reset hunk / buffer — **this is how you discard** |
| `<leader>td` / `<leader>tD` | this file: diff vs index / vs last commit, side by side |
| `<leader>gd` | working-tree diff panel, all files |
| `<leader>gD` | repo diff vs merge-base with origin/main |
| `<leader>tM` | this file, everything since the merge-base with origin/main |
| `<leader>tc` / `<leader>gC` | what the last commit did (to this file / repo-wide) |
| `<leader>tC` / `<leader>gc` | pick commits → diff; `<Tab>` marks two to span between |
| `<leader>gh` / `<leader>gH` | this file's history / branch history |
| `<leader>gs` | changed files picker |
| `<leader>gb` | branches |
| `<leader>gl` / `<leader>tb` | blame this line / toggle inline blame |
| `<leader>gq` | close the diff panel |

Inline blame is on by default — dimmed virtual text at the end of the current line,
the GitLens thing.

### Conflicts

Opening a conflicted file jumps you to the first marker and says so, rather than
leaving you at line 1.

| | |
|---|---|
| `]x` / `[x` | next / previous conflict |
| `co` / `ct` / `cb` / `c0` | take ours / theirs / both / neither |
| `<leader>gx` | every conflicted file → quickfix |

Diagnostics are suppressed while a file is conflicted, because half a conflict is never
valid syntax and the LSP would scream.

### LSP

| | |
|---|---|
| `grd` / `grD` / `grt` | definition / declaration / type definition |
| `grr` / `gri` | references / implementations |
| `grn` | rename |
| `gra` | code action |
| `gO` / `gW` | document / workspace symbols |
| `K` | hover |
| `<leader>q` | diagnostics → loclist |
| `<leader>sd` | search diagnostics |

### Finding things

| | |
|---|---|
| `<leader><leader>` | open buffers |
| `<leader>sf` / `<leader>sg` / `<leader>sw` | files / live grep / word under cursor |
| `<leader>s.` | recent files |
| `<leader>sr` | resume the last search |
| `<leader>sk` / `<leader>sh` / `<leader>sc` | keymaps / help / commands |
| `<leader>ss` | pick a telescope picker |

For *files*, the pad is usually faster than `<leader>sf` — it is already scoped to the
worktree and already knows your recent files. Use `<leader>sg` / `<leader>sw` inside
nvim, or `^F` from the pad.

### Other

| | |
|---|---|
| `^/` | toggle comment (also visual, also insert) |
| `<leader>tm` | render markdown in the buffer — the closest thing to a preview without leaving the pad |
| `<leader>st` | theme picker with live preview; the choice survives a restart |
| `^h` `^j` `^k` `^l` | move between windows |
| `<Esc>` | clear search highlight |

---

## What is in the nvim config

`~/.dotfiles/xdg-home/.config/nvim` (a submodule; kickstart-derived). Everything added
lives in `lua/custom/`:

- **`plugins/git.lua`** — the source-control sidebar, minus Cursor. gitsigns with inline
  blame on and hunk actions under `<leader>g*`; git-conflict.nvim with the
  jump-to-first-marker autocmd; diffview panels; the telescope git pickers, which came
  free and were simply never bound. The long comment at the top is the
  working-tree-vs-commit-patch distinction above.
- **`plugins/format.lua`** — `<leader>j`, `<leader>h`, `<leader>J`. conform with a
  prettier that copes with worktrees having no `node_modules` (borrows a sibling's
  binary *and* its config, because a config that `require.resolve`s plugins resolves
  them relative to itself). The async chain, and the reason each step is chained on a
  completion rather than a wait.
- **`plugins/markdown.lua`** — in-buffer markdown rendering, no nerd font required.
- **`plugins/theme.lua`** — theme picker with live preview, choice persisted.
- **`util/gitdiff.lua`** — turning a choice of commits into a diffview revspec; shared
  by the `<leader>t` file toggles and the `<leader>g` panels.
- **`local.lua`** — machine-specific paths, gitignored. `local.lua.example` documents it.

`<leader>h*` is deliberately free of gitsigns hunk actions (kickstart puts them there)
so `<leader>h` can be the Cursor organizeImports save.

---

## Where things are configured

| | |
|---|---|
| fzedit, rr, tig hand-off | `~/bin/dev-workflow-tools/` (`.env` for machine paths) |
| fzedit home-sweep noise | `~/.config/fzedit/ignore` — seeded on first run, meant to be edited |
| worktree recency | `~/.cache/rr/worktree_access.log`, shared by rr and fzedit |
| tig keys | `~/.tigrc` (`E` → fzedit tab on the line, `W` → tab scoped to the repo) |
| the pad window itself | your WM — `~/.xmonad/xmonad.hs`, or `~/.config/hypr/pads.tsv` |
| tab keys in the pad | `~/.tmux.conf` (`C-x` / `C-b` / `C-M-w`, scoped to the pad session) |

---

## Things that are easy to forget

- **`<leader>J`, not `<leader>j`**, in a file that was never prettier-clean.
- **`^E` in the pad**, not four separate `enter`s — one LSP start instead of four.
- **`^K`** exists. You do not have to switch worktree and then find the file again.
- **`<leader>gr`** is how you discard a hunk. There is deliberately no discard key in
  the pad; you want the diff in front of you when you throw work away.
- **`^F` then `^F`** — ripgrep to narrow, then fuzzy to pick.
- **`esc` clears the query** in the pad. `^U` is half-page-up, not clear-line.
- **The header warns about rebases in other worktrees.** If `conflicts (0)` surprises
  you, read it.

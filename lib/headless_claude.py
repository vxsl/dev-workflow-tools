"""Run `claude -p` as a utility call rather than as a session of your work.

A tool that shells out to `claude -p` starts a real Claude Code session, and everything
downstream treats it as one: the Stop hook fires a desktop notification, orch files it
under whatever workstream the cwd belongs to, and its transcript joins the corpus that
work-arcs and arc-cluster read. That is wrong three times over -- a classifier deciding
whether a Slack message is a question is not work anyone did.

It also closes a loop. arc-backfill globs every project directory for prompts, so
arc-brief describing 59 arcs writes 59 transcripts that the next run reads back as
prompts, clusters, and describes. The tool measures itself, and the noise compounds on
every refresh.

The fix is to make these calls identifiable. They run with cwd inside one dedicated
directory, so their transcripts land in a project directory of their own that any
consumer can skip wholesale -- more robust than matching on prompt text, which breaks
the moment a prompt is reworded. Notifications are turned off by the env var the Stop
hook already honours.

    from headless_claude import run
    r = run(["--model", "haiku", prompt], timeout=30)

Consumers that read ~/.claude/projects should skip `PROJECT_DIR`.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
SESSION_DIR = STATE / "claude-headless"

# Claude Code names a project directory after its cwd with every non-alphanumeric
# character replaced by a dash, so the name is derivable rather than something to
# hardcode and keep in sync.
PROJECT_DIR = re.sub(r"[^A-Za-z0-9]", "-", str(SESSION_DIR))

_README = """\
Transcripts of `claude -p` utility calls made by dev-workflow-tools -- intent
classifiers, summarizers, and the arc namer. They are not sessions of anyone's work.

They live here so they land in their own Claude Code project directory instead of the
project the calling tool happened to run from, which keeps them out of orch's session
list and out of the prompt corpus work-arcs reads.

Safe to delete at any time.
"""


def ensure_dir():
    try:
        SESSION_DIR.mkdir(parents=True, exist_ok=True)
        readme = SESSION_DIR / "README"
        if not readme.exists():
            readme.write_text(_README)
    except OSError:
        return False
    return True


def run(args, timeout=60, **kw):
    """`claude -p <args>` as a utility call. Same return as subprocess.run.

    Callers keep their own error handling -- this only fixes where the session lands
    and that it stays quiet.
    """
    env = dict(os.environ)
    # The Stop hook's documented per-session opt-out. Without it a batch of 59 calls
    # is 59 desktop notifications.
    env["CLAUDE_NOTIFY_QUIET"] = "1"
    cwd = str(SESSION_DIR) if ensure_dir() else None
    return subprocess.run(
        ["claude", "-p", *args],
        capture_output=True, text=True, timeout=timeout, env=env, cwd=cwd, **kw)


def add_to_path():
    """Let bin/ scripts import this without an installed package."""
    lib = str(Path(__file__).resolve().parent)
    if lib not in sys.path:
        sys.path.insert(0, lib)

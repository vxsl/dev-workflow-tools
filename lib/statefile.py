"""Reading a JSON state file that a crash, a full disk or an editor may have mangled.

Every program in this pipeline keeps state under $XDG_STATE_HOME/work-arcs: dismissals,
parkings, detachments, three model-verdict caches, the run-over-run snapshot, the brief
cache, the split cache. All of them are dict-shaped, all of them are read with
`json.loads(path.read_text())`, and all of them were guarded like this:

    try:
        store = json.loads(PATH.read_text()) or {}
    except (OSError, ValueError):
        store = {}

which catches the file being absent and the file not being JSON, and does nothing at all
about the file being *valid JSON of the wrong shape*. `[{"x": 1}]`, `"hello"`, `42` and
`null` all parse, and then the first `store.items()` or `cache.get("prompt")` two lines
later raises AttributeError -- straight out through main as a traceback, on a run that
cron owns and nobody is watching. Measured on this tree: 21 tracebacks across five
readers before this module existed.

That is not a theoretical shape. A process killed partway through `write_text` leaves a
prefix of the old file, and a prefix of `{"a": {...}}` is usually invalid JSON but a
prefix of a file whose top level was ever a list is often a valid shorter list. `null` is
what `json.dumps(None)` writes, which is one bad `store = None` away.

Two of the ten readers already did the right thing -- `load_overrides` in work-arcs and
`load_cache` in arc-brief both ended `return data if isinstance(data, dict) else {}`. The
idiom was known and applied at 20% coverage, which is the failure mode of an idiom rather
than of a programmer. So it lives here now, once, and the callers import it.

The contract is deliberately narrow: it always returns a dict, and it never raises. A
state file is a cache or an acknowledgement store, never the input the run is about --
losing one costs a re-derivation or, at worst, a re-click, and neither is worth failing a
morning build over. What it must not do is fail *silently*, so a discarded file says so on
stderr, naming itself. Absence of a section over a wrong section, and a named absence over
an unnamed one.
"""

import json


def load_store(path, what="", say=None):
    """A dict from a JSON file, whatever is actually in the file.

    Returns {} for: no file, an unreadable file, a file that is not JSON, and a file whose
    JSON is not an object. The first two are ordinary and silent -- a cache that does not
    exist yet is the normal state on a fresh machine. The last two are corruption and say
    so through `say`, because a cache that silently emptied itself looks exactly like a
    cache that is working and cold, and the difference is a run's worth of model calls.

    `what` names the store in that message in the reader's terms ("the dismissal store")
    rather than in the path's. `say` defaults to printing on stderr; pass a collector to
    capture it, or `lambda _: None` where a caller has to stay silent.
    """
    if say is None:
        def say(msg):
            import sys
            print(msg, file=sys.stderr)
    try:
        raw = path.read_text()
    except OSError:
        return {}
    try:
        data = json.loads(raw)
    except ValueError as e:
        say(f"  ignoring {path} — it is not readable JSON ({e}); "
            f"{what or 'the store'} starts empty this run")
        return {}
    if data is None:
        # Distinct from the branch below only in that it is not worth a warning: `null` is
        # what an empty store legitimately serialises to if anything ever wrote None, and
        # an empty store is what we would return anyway.
        return {}
    if not isinstance(data, dict):
        say(f"  ignoring {path} — it holds {type(data).__name__} where an object "
            f"belongs; {what or 'the store'} starts empty this run")
        return {}
    return data

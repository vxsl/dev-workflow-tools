---
description: Rebuild the work-arcs page and republish it to its artifact URL
---

Rebuild the standing picture of Kyle's work and republish it, in place, to the artifact
it already lives at.

Any arguments after the command pass straight through to `arcs` (e.g. `/arcs --focus 30`,
`/arcs --no-brief`).

## Steps

1. Run `arcs $ARGUMENTS`. It runs `work-arcs → arc-brief → arc-morning → arc-standup →
   arcs-page`, writes the HTML, and prints the output path and the artifact URL. It takes
   about a minute — most of that is GitLab and the model passes, and both are cached, so a
   second run in the same hour is fast.

2. Publish the file it printed with the **Artifact** tool, passing:
   - `file_path`: the path `arcs` printed
   - `url`: the URL `arcs` printed (from `WORK_ARCS_ARTIFACT_URL` in the repo's `.env`).
     **This is not optional.** Publishing without it creates a second artifact with a new
     link rather than updating the one Kyle has open.
   - `favicon`: 🧭 — keep it stable, he finds the tab by its icon
   - `label`: a two-or-three-word note on what moved since last time

   If the publish is refused because this session has not seen the current version, WebFetch
   the URL once and publish again. Do **not** pass `force` — the page is fully regenerated
   from the repo each run, so there is nothing of anyone else's to preserve, but the refusal
   is also a signal that another session is publishing and worth a moment's thought.

3. Report what actually changed, not that it succeeded. Compare against the previous run
   where you can: which workstreams moved rung, what came back, what landed, what is newly
   `no reviewer asked` or newly `approved, stacked`. The page states everything else — the
   only thing worth saying in chat is the delta.

   On a standup morning, say what is in the standup block too — it is the reason he opened
   the page at that hour, and its window is the one interval on the page a rebuild does not
   change. `arc-standup --text` prints it on its own if he asks for it without a rebuild.

## Notes

- Publishing is a Claude Code step by necessity: the page is an artifact, and only a session
  can write to that URL. `arcs` on its own does every part that a shell can do.
- If `arcs` fails, say which stage. It runs the programs separately so the failing one is
  named rather than surfacing as "stdin is not work-arcs --json".

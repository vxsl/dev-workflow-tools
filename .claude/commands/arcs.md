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

2. Run `arcs-refresh --publish`. It uploads the file `arcs` just wrote to the artifact URL
   in `.env`, over the same HTTP API the CLI's own Artifact tool uses, and prints the new
   version. It reads the artifact's current title and favicon and sends them back
   unchanged, so the tab Kyle finds by its icon keeps its name and its icon.

   Do **not** publish with the Artifact tool instead. It works, but it has to read the
   whole 370KB page into context first, and this does the same job for nothing.

   If it fails, it says why in one line. The two worth knowing:
   - **the publish cap for this plan has been reached** — nothing to do but wait; the
     page on disk is current and the next morning's run will send it.
   - **the artifact moved since this run read it** — another session published in
     between. It supersedes it automatically and says so; the page is regenerated whole
     from local state every run, so nothing of that version was worth keeping.

3. Report what actually changed, not that it succeeded. Compare against the previous run
   where you can: which workstreams moved rung, what came back, what landed, what is newly
   `no reviewer asked` or newly `approved, stacked`. The page states everything else — the
   only thing worth saying in chat is the delta.

   On a standup morning, say what is in the standup block too — it is the reason he opened
   the page at that hour, and its window is the one interval on the page a rebuild does not
   change. `arc-standup --text` prints it on its own if he asks for it without a rebuild.

## Notes

- The morning timer (`work-arcs-refresh.timer`, 07:10) now publishes on its own — this
  command is for a rebuild on demand, not for finishing a job the timer left half done.
- If `arcs` fails, say which stage. It runs the programs separately so the failing one is
  named rather than surfacing as "stdin is not work-arcs --json".

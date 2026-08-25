"""How big a body of unpublished work is, said the same way everywhere.

A commit count is churn, not meaning. In fast agentic development one afternoon takes
fifty commits, and a backup or squash-remnant branch multiplies them again -- so "85
commits exist only here" measures how the work was typed rather than how much of it there
is. The scale that survives that is DAYS OF WORK: the distinct author-date days across the
distinct commits no remote has. It moves when a day of work happens and not otherwise,
which is also what makes it safe to put in a run-over-run snapshot.

Four surfaces say this fact -- the rung a workstream sits on, the demand under its card,
the Jira-mismatch row, and the aggregate tile at the top of the page -- and the morning
brief reads two of them back as prose. Two roundings of one number would eventually
disagree on the same page, which is the small contradiction that costs a reader their
trust in the large ones. So the wording lives here and every caller imports it.
"""


def work_scale(days, commits):
    """The size of some unpublished work in days, and the verb that agrees with it.

    Returns a `(phrase, verb)` pair so a caller can either drop the phrase into a fragment
    ("a day's work, only here") or build a sentence around it ("a day's work exists nowhere
    but this laptop") without re-deciding the grammar.

    Two degradations, both bounded by what the evidence supports. A single day carrying a
    single commit is at most one sitting, so it claims less than a day rather than a whole
    one. No dates at all -- the degraded path, where there was no repo to ask -- names no
    scale, because an invented one is worse than none.
    """
    if days >= 2:
        return f"{days} days of work", "exist"
    if days == 1:
        return ("a day's work" if commits > 1 else "less than a day's work"), "exists"
    return "unpushed work", "exists"

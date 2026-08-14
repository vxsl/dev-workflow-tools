"""How long a gap between two builds is, said the same way everywhere.

The page states the interval twice -- once in the stamp line ("nothing changed since the
last build (51 minutes ago)") and once at the head of the morning brief ("in the 51
minutes since the last build"). Those are the same fact, and two roundings of it would
eventually disagree by a minute or an hour on the same page, which is exactly the kind of
small contradiction that costs a reader their trust in the large ones.

So the coarsening lives in one place and both callers import it.
"""


def fmt_interval(secs):
    """A gap between two builds, in the coarsest unit that still says something.

    Rounded up rather than truncated, because a 50-minute gap reported as "0 hours" reads
    as a bug. Empty string when the gap is unknown, so the sentence can simply omit it
    instead of printing a placeholder.
    """
    if not isinstance(secs, int) or isinstance(secs, bool) or secs < 0:
        return ""
    if secs < 5400:
        n, unit = max(1, round(secs / 60)), "minute"
    elif secs < 129600:
        n, unit = max(1, round(secs / 3600)), "hour"
    else:
        n, unit = max(1, round(secs / 86400)), "day"
    return f"{n} {unit}" + ("" if n == 1 else "s")

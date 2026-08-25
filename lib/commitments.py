"""Which ledger rows are promises Kyle made, shared by everything that has to ask.

The ledger holds two kinds of promise. One is read out of Kyle's own Slack messages; the
other is read out of his own voice in a meeting transcript. They differ only in where the
words were said: both are inferred rather than asserted by an API, both carry the sentence
they are a claim about, both close on the same evidence, and both expire the same way.

They are named here because four places, in three programs, independently have to
recognise one:

    work-arcs   close_commitments, which takes a kept promise off the ledger
    work-arcs   the CLI render, which says how a row that closes on nothing will die
    arcs-page   the same sentence in HTML, plus MINE -- whose words the quote is
    arc-morning overdue_commitments, which compares a promise to the clock it set itself

Every one of them spelled `kind == "commitment"` before there was a second kind, and the
failure mode of that is not a crash. A meeting row that `close_commitments` recognises and
the page does not is a row that vanishes on evidence while its expiry note still promises
it has eleven days left; the reverse is a promise the page renders forever because nothing
will ever close it. Both read, to Kyle, as the tool having quietly lost track -- the one
failure from which no amount of correctness later recovers.

So the tuple lives in one place, and adding a third kind is one edit rather than four.
"""

# Ordered as they were built, which is also cheapest-source first. Nothing depends on the
# order; a caller wanting a stable render order should sort on its own key.
COMMITMENT_KINDS = ("commitment", "meeting-commitment")


def is_commitment(entry):
    """Whether a ledger row is a promise Kyle made. Takes the row, not its kind, because
    every caller has the row and half of them were reaching into it twice to ask."""
    return (entry or {}).get("kind") in COMMITMENT_KINDS

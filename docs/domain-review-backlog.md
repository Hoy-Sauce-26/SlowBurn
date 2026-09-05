# Review lens backlog

The suite is frozen (`scripts/check-domain.py`, `scripts/lenses.py`). New lens ideas land
here rather than in the plan or the scripts, so that a run cannot be made to find something
by widening what counts.

Promote one only when it would catch a defect that changes a number for ordinary input.

- Enum branch exhaustiveness beyond `taxTreatment`
- Cross-band consistency for every projected quantity, not just the snapshot's
- Whether each `TaxYear` datum's `indexed` flag matches current statute, per tax-year update
- Per-entity referential integrity beyond invariants 25 and 26
- A `(§13.x)` deferral pointer that §13 never lists. Found by hand this session:
  `Liability.originationDate` promised a §13 entry for borrowing that funds no
  acquisition, and there was none. The gate proves a §ref resolves, never that the
  thing it promises is there. Costs no number, so it stays here.
- A bare `§4.3`/`§4.4`/`§6`/`§8.4` ref now that each has subsections. Sixty-two are
  legitimately section-wide, so this can only ever be a survey, not a gate.

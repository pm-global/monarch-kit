# Validation outputs

One file per validation effort. Each file records what was checked and what was found.

The ledger that defines these efforts, tracks their status, and holds the decision rules is
`docs/working-plan.md`. Read it first.

These outputs are evidence, not plans. A finding here is only actionable once the ledger says
the effort that produced it has closed.

## Files

- `effort-02-specs-vs-code.txt` covers `docs/domain-specs.md` and
  `docs/mechanism-decisions.md` against the code. Complete. All eight sections checked, with
  each finding tagged with a destination.
- `effort-03-report-vs-code.txt` covers the report design against the renderer. Half done. Both
  inventories exist, v5 as `[1]` through `[17]` and v9 as `[V9-1]` through `[V9-17]`. Two
  passes remain: diff the inventories, then check both samples and the renderer against
  `docs/reference/report-design-system.md`.

- `effort-04-plans-vs-code.txt` covers the three files in `docs/plans/` against the code, for
  implementation status per named piece of work. Not started. Stub only. The ledger already
  carries three unverified findings, restated in the file. Ticket #23.
- `effort-05-research-extraction.txt` covers `docs/reference/gpo-review-workflow.md` and both
  files in `docs/reference/ad-research/` for decision-relevant content. Not started. Stub only.
  The source files survive the pass. Tickets #14 and #15.
- `effort-07-citation-verification.txt` covers the PCI DSS, NIST 800-53 and Microsoft citations
  in `docs/reference/dormant-account-standard.md` against their sources. Not started. Stub
  only. Output is one flag per citation. Ticket #21.
- `effort-08-summary-vs-code.txt` covers `docs/working-summary.md` against `Monarch.psm1` and
  `tests/Monarch.Tests.ps1`. Not started. Stub only. Unreconciled GitHub issues fold into the
  same pass. Ticket #12.

The ledger has no effort 1 and no effort 6.

## Authority

`effort-03-report-vs-code.txt` records a rule that applies to every effort: reference files are
ground truth by convention only. The repository owner is the final authority. Files get updated
to match decisions. Decisions never get overridden by what a file happens to say.

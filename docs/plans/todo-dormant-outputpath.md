# Plan: Find-DormantAccount — Adopt Directory Semantics for -OutputPath

## Problem Statement

`Find-DormantAccount` currently receives a full file path for `-OutputPath`. The module
standard (established by todo-privaccess-output.md) is directory semantics: function receives
a directory, constructs its own filename internally. Find-DormantAccount is out of alignment
and must be updated to match before Phase 2 remediation functions depend on its output location.

**Blocked by:** `docs/plans/todo-privaccess-output.md` — that plan establishes the directory
semantics pattern this plan adopts.

## Engineering/Design Decisions

**Decision: change -OutputPath to accept directory, write dormant-accounts.csv internally.**
Consistent with the module-wide directory semantics pattern. Rejected: keep full file path
— inconsistency across functions forces callers to know each function's filename convention.

**Decision: update orchestrator call site to pass directory, not file path.**
Orchestrator already constructs the phase output directory. Pass that directory. The function
owns `dormant-accounts.csv` as its filename.

**Decision: treat as a breaking change to -OutputPath parameter semantics.**
Callers passing a file path will get a directory created at that path (or an error if a file
already exists there). Document the change. No backwards-compatibility shim — the pattern
must be consistent.

## Mechanism

1. Change `-OutputPath` parameter to expect a directory path (update parameter help)
2. Internally: `$filePath = Join-Path $OutputPath 'dormant-accounts.csv'`
3. Write to `$filePath` using `Export-Csv`
4. Update orchestrator call site to pass phase directory instead of constructed file path
5. Update tests to reflect new semantics

## Invariants

- Output filename is always `dormant-accounts.csv` when `-OutputPath` is provided
- Omitting `-OutputPath` produces identical behavior to current (no file output)
- Return object `OutputPath` property contains the full file path, not the directory

## Risks and Mitigations

**Risk: existing call sites outside the orchestrator pass full file paths.**
Mitigation: search Monarch.psm1 for all `Find-DormantAccount` call sites before implementing.
At time of writing, only the orchestrator calls it. Confirm before proceeding.

## Reviewer Findings

*(To be completed during self-assessment before moving to docs/plans/)*

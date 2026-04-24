# Plan: Privileged Access Functions Missing -OutputPath

## Problem Statement

The orchestrator creates the `03-Privileged-Access` output folder but none of the four
privileged access functions (`Get-PrivilegedGroupMembership`, `Find-AdminCountOrphan`,
`Find-KerberoastableAccount`, `Find-ASREPRoastableAccount`) accept an `-OutputPath` parameter.
CSV export was removed at some point. These functions produce no file output, leaving the
folder empty after an audit run.

## Engineering/Design Decisions

**Decision: accept a directory path, construct filename internally.**
Consistent with the directory semantics pattern established across the module. Function
receives a directory, writes `<function-specific-name>.csv` internally. Callers pass the
phase output directory; functions own their filenames. Rejected: full file path parameter
— callers shouldn't construct filenames for functions they don't own.

**Decision: -OutputPath is optional, not mandatory.**
Functions must remain usable in isolation (direct calls, testing). When omitted, file output
is skipped; return object is unaffected. Rejected: mandatory -OutputPath — breaks existing
call sites and test mocks.

**Decision: return object includes output path when written.**
When `-OutputPath` is provided and a file is written, the return object gains an `OutputPath`
property with the full file path. Callers (orchestrator) can log or reference it. When omitted,
property is absent or `$null`.

## Mechanism

Each of the four functions gains:
```
param(
    ...existing params...
    [string]$OutputPath  # optional directory path
)
```

After building the result object, if `$OutputPath` is provided:
1. Validate directory exists (create if absent — consistent with orchestrator behavior)
2. Export result to CSV with function-specific filename
3. Add `OutputPath` property to return object

Orchestrator wires up `-OutputPath` for all four functions using the existing phase directory
it already creates.

## Invariants

- Return object structure unchanged when `-OutputPath` is omitted
- Function runs without `-OutputPath` — no side effects, no errors
- File written atomically (Export-Csv completes before return)
- Filename is deterministic and function-specific (no timestamps in filename)

## Risks and Mitigations

**Risk: directory creation race in parallel execution.**
Mitigation: use `New-Item -Force -ItemType Directory` — idempotent, safe for concurrent callers.

**Risk: large result sets producing large CSV files.**
Mitigation: no size limit required — these are audit outputs, not streaming data. Document
expected size range in function help.

## Reviewer Findings

*(To be completed during self-assessment before moving to docs/plans/)*

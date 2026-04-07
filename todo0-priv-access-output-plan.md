# TODO-0: Privileged Access File Output

## Problem

Orchestrator creates `03-Privileged-Access` but no function writes to it. The four priv access functions lost their `-OutputPath` support at some point. The folder is always empty.

## Affected Functions

- `Get-PrivilegedGroupMembership`
- `Find-AdminCountOrphan`
- `Find-KerberoastableAccount`
- `Find-ASREPRoastableAccount`

## Research Needed

- What CSV output did these functions originally produce? Check git history for removed `-OutputPath` params and `Export-Csv` calls.
- What file names and structure match the existing patterns (01-Baseline, 02-GPO-Audit, 04-Dormant-Accounts)?
- Which functions should always write vs conditionally write (e.g. only when findings exist)?
- Does `Find-DormantAccount` provide the right template for the pattern?

## Scope

- Add `-OutputPath` parameter to each function
- Add conditional CSV export (matching existing patterns)
- Wire `-OutputPath = $dirs.Priv` in orchestrator call entries
- Tests for file output behavior
- Verify manifest picks up new files correctly

## Out of Scope

- New columns or return contract changes
- Report changes (metrics/advisories already work from the structured return data)

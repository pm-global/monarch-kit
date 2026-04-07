# TODO-0: Privileged Access File Output

## Problem

Orchestrator creates `03-Privileged-Access` (`$dirs.Priv`, line 3049) but none of the four priv access functions write to it. The folder is always empty after a Discovery run.

## Affected Functions

| Function | Current Params | Return Data Available for CSV |
|----------|---------------|-------------------------------|
| `Get-PrivilegedGroupMembership` (line 765) | `-Server` only | `Groups[].Members[]` -- SAM, DisplayName, ObjectType, IsDirect, IsEnabled, LastLogon |
| `Find-AdminCountOrphan` (line 860) | `-Server` only | `Orphans[]` -- SAM, DisplayName, Enabled, MemberOf |
| `Find-KerberoastableAccount` (line 921) | `-Server` only | `Accounts[]` -- SAM, DisplayName, SPNs, IsPrivileged, PasswordAgeDays, Enabled |
| `Find-ASREPRoastableAccount` (line 986) | `-Server` only | `Accounts[]` -- SAM, DisplayName, IsPrivileged, Enabled |

## Research Needed

1. **Git history for removed `-OutputPath` params.** These functions may have had CSV export at some point. Check `git log -p -- Monarch.psm1` filtered for these function names to see if/when `-OutputPath` and `Export-Csv` were removed, and what the original column selection looked like.

2. **Template pattern: `Find-DormantAccount` (line 617).** This is the working reference:
   - Accepts `-OutputPath` as a file path (not directory)
   - Conditional export: `if ($OutputPath -and $accounts.Count -gt 0)`
   - Selects specific columns via `Select-Object` before export
   - Stores `$csvPath` in return object as `CSVPath`
   - Orchestrator passes `OutputPath = $dirs.Dormant` (a directory -- but DormantAccount treats it as a file path, which is inconsistent with how GPO uses it as a directory)

3. **OutputPath semantics decision.** `Find-DormantAccount` receives a file path. `Export-GPOAudit` receives a directory and creates subfolders. For priv access, which pattern?
   - **Option A (file path):** Each function gets its own `-OutputPath` file path. Orchestrator passes `Join-Path $dirs.Priv 'privileged-groups.csv'` etc. Simpler per-function, matches DormantAccount.
   - **Option B (directory):** Each function gets the directory, picks its own filename. More autonomous but inconsistent with DormantAccount.
   - **Recommendation:** Option A -- matches existing pattern, orchestrator controls filenames.

4. **Which functions should always write vs conditionally write?**
   - `Get-PrivilegedGroupMembership`: always write (groups always exist, even if empty -- the count IS the finding)
   - `Find-AdminCountOrphan`: conditional (only when orphans found)
   - `Find-KerberoastableAccount`: conditional (only when SPN accounts found)
   - `Find-ASREPRoastableAccount`: conditional (only when pre-auth-disabled accounts found)

5. **Column selection per function.** What columns go in each CSV? The return objects have nested data (e.g., `Groups[].Members[]` is two levels deep). Need to decide: one CSV per function with flattened rows, or multiple CSVs?
   - `Get-PrivilegedGroupMembership`: flatten to one row per member with GroupName column (like GPO linkage pattern)
   - Others: straightforward -- one row per account, select relevant columns

## Scope

- Add `-OutputPath` parameter to each of the 4 functions
- Add conditional CSV export matching the `Find-DormantAccount` pattern
- Add `CSVPath` to each function's return object
- Wire `OutputPath = Join-Path $dirs.Priv '<filename>.csv'` in orchestrator call entries (line 3064-3067)
- Tests for: file created when findings exist, file not created when empty, correct columns exported

## Out of Scope

- New columns or return contract changes (export existing data only)
- Report changes (metrics/advisories already work from the structured return data)

## Implementation

**Model:** Sonnet. Mechanical pattern replication from `Find-DormantAccount`. No ambiguity once the research questions above are answered.

**Passes:** 1. All four functions + orchestrator wiring + tests in a single pass.

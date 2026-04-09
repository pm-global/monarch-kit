# TODO-0: Privileged Access File Output

## Problem

Orchestrator creates `03-Privileged-Access` (`$dirs.Priv`, line 3049) but none of the four priv
access functions write to it. The folder is always empty after a Discovery run.

Git history confirmed: these functions never had `-OutputPath`. Purely additive — no regression.

## What Changes and What Doesn't

| Function | Change |
|----------|--------|
| `Get-PrivilegedGroupMembership` (line 765) | Add `-OutputPath` (directory); writes `privileged-groups.csv` |
| `Find-AdminCountOrphan` (line 860) | Add `-OutputPath` (directory); writes `admincount-orphans.csv` |
| `Find-KerberoastableAccount` (line 921) | No change to function; orchestrator combines its output |
| `Find-ASREPRoastableAccount` (line 986) | No change to function; orchestrator combines its output |

## Resolved Decisions

**OutputPath semantics (Option B):** Functions receive a directory, construct their own filename
internally via `Join-Path $OutputPath 'filename.csv'`. No orchestrator filename duplication.

**Kerberoastable + AS-REP combined:** Single `roastable-accounts.csv` written by the orchestrator
after both functions complete. `ThreatType` column (`Kerberoast` / `ASREP`). Neither function gets
an `-OutputPath` param. If one function errored or returned 0 results, the other's rows still
write. If both return 0, nothing is written.

**Orchestrator combine lookup:** `$results | Where-Object { $_.Function -eq '...' }` — the same
pattern used throughout `New-MonarchReport` (confirmed at lines 2570, 2784, 2792, 2798, 2800,
2804, 2810, 2812, 2821, 2832, 2837, 2839, 2849). Not a new pattern.

**Combine block placement:** Immediately after the `foreach ($call in $calls)` loop closes
(after line 3096), before `$orchestratorResult` is built (line 3099). `$dirs.Priv` is guaranteed
to exist — created at line 3052 before any function is called.

**Combine block failure handling:** Wrapped in try/catch. On failure: `Write-Warning` with
context. Does not abort the run. Does not touch the return contract (no Warnings field on
orchestrator result). File write failure is surfaced to the caller without changing counts or
dispositions.

**Write conditions — all functions conditional:**
- `Get-PrivilegedGroupMembership`: `if ($OutputPath -and $flatMembers.Count -gt 0)`
- `Find-AdminCountOrphan`: `if ($OutputPath -and $orphans.Count -gt 0)`
- Orchestrator roastable combine: `if ($rows.Count -gt 0)`
- Zero results = no file = correct signal. The report surfaces zero-count via return object
  fields (`DomainAdminCount`, `DomainAdminStatus`), not via CSV presence. Same pattern as
  Kerberoast and ASREP, which only generate report advisories when counts are positive.

**Directory validation:** None in functions. `Export-Csv` throws natively on a bad path.
Orchestrator creates all subdirectories before calling any function (line 3052). Standalone
callers are responsible for their own path — consistent with `Find-DormantAccount` behavior.

**privileged-groups.csv:** Flatten `Groups[].Members[]` to one row per member. Sort by
`SamAccountName` — groups all of a user's memberships together for admin readability.
Columns: `SamAccountName, GroupName, DisplayName, ObjectType, IsDirect, IsEnabled, LastLogon`

**admincount-orphans.csv:** One row per orphan. `MemberOf` joined with `'; '` via computed
`Select-Object` property (export existing data only — no new AD calls).
Columns: `SamAccountName, DisplayName, Enabled, MemberOf`

**roastable-accounts.csv:** One row per account. ASREP rows have empty `SPNs` and
`PasswordAgeDays` — honest empty cells.
Columns: `ThreatType, SamAccountName, DisplayName, IsPrivileged, Enabled, SPNs, PasswordAgeDays`

**CSVPath in return objects:** `Get-PrivilegedGroupMembership` and `Find-AdminCountOrphan` add
`CSVPath` (null when not written). Additive — no existing consumer breaks.

## Cmdlet Output — Do Not Guess

No new AD cmdlet calls introduced. All CSV column selections read from PSCustomObjects already
built within each function. Field names confirmed against source (lines 765–1040):
- `Get-PrivilegedGroupMembership` member fields: `SamAccountName, DisplayName, ObjectType,
  IsDirect, IsEnabled, LastLogon`. `LastLogon` is stored from `$userDetail.LastLogonDate`.
  `GroupName` comes from the outer group object.
- `Find-AdminCountOrphan` orphan fields: `SamAccountName, DisplayName, Enabled, MemberOf`
  (array of raw DNs)
- `Find-KerberoastableAccount` account fields: `SamAccountName, DisplayName, SPNs,
  IsPrivileged, PasswordAgeDays, Enabled`
- `Find-ASREPRoastableAccount` account fields: `SamAccountName, DisplayName, IsPrivileged,
  Enabled`

## Invariants

- `CSVPath` in return object is non-null if and only if a file was written
- `roastable-accounts.csv` is never written with 0 rows
- All rows in `privileged-groups.csv` have a non-null `GroupName`
- No new AD calls made during CSV export
- Orchestrator return contract unchanged (Phase, Domain, DCUsed, DCSource, StartTime, EndTime,
  OutputPath, ReportPath, Results, Failures, Dispositions, TotalChecks)

## Implementation Passes

### Pass 0 — Confirm mock pattern (no code written)

Orchestrator `Describe 'Invoke-DomainAudit'` outer `BeforeAll` mocks all functions with a generic
object (`Function = 'MockFunction'`, no `Accounts` property). This must not be changed. New
combine test contexts override the two roastable function mocks to return objects with correct
`Function` values and populated `Accounts` arrays. Existing contexts are untouched and produce
0 combine rows — correct.

### Pass 1 — Tests (write first; confirm they fail before touching implementation)

**`Get-PrivilegedGroupMembership` — add `Context 'CSV export with OutputPath'`:**
- File created at `Join-Path $TestDrive 'privileged-groups.csv'` when `-OutputPath $TestDrive`
  and members exist
- File not created when all groups have 0 members
- Rows sorted by `SamAccountName`
- Columns present: `SamAccountName, GroupName, DisplayName, ObjectType, IsDirect, IsEnabled,
  LastLogon`
- `result.CSVPath` equals the constructed path when written; null when not written

**`Find-AdminCountOrphan` — add `Context 'CSV export with OutputPath'`:**
- File created when orphans found
- File not created when no orphans
- `MemberOf` column contains `'; '`-joined DNs
- Columns present: `SamAccountName, DisplayName, Enabled, MemberOf`
- `result.CSVPath` equals path when written; null when not written

**Orchestrator — add `Context 'Roastable CSV combine'` inside `Describe 'Invoke-DomainAudit'`:**
- Override mocks for both roastable functions with proper return objects (correct `Function`
  value, populated `Accounts` arrays)
- `roastable-accounts.csv` written when both return accounts
- Written when only kerberoast returns accounts (ASREP mock returns 0)
- Written when only ASREP returns accounts (kerberoast mock returns 0)
- Not written when both return 0 accounts
- `ThreatType` column present and correct per source
- ASREP rows have empty `SPNs` and `PasswordAgeDays`
- Combine write failure (mock Export-Csv to throw): Write-Warning emitted, orchestrator
  completes, return object intact

### Pass 2 — Implementation

**`Get-PrivilegedGroupMembership`** (line 765):
- Add `[string]$OutputPath` param
- `$csvPath = $null` before return block
- After `$groups` is built: flatten all members across groups, sort by `SamAccountName`
- `if ($OutputPath -and $flatMembers.Count -gt 0)`: write CSV to
  `Join-Path $OutputPath 'privileged-groups.csv'`, set `$csvPath`
- Add `CSVPath = $csvPath` to return object

**`Find-AdminCountOrphan`** (line 860):
- Add `[string]$OutputPath` param
- `$csvPath = $null` before return block
- `if ($OutputPath -and $orphans.Count -gt 0)`: write CSV (join `MemberOf` via computed
  `Select-Object` property), set `$csvPath`
- Add `CSVPath = $csvPath` to return object

**Orchestrator** (after line 3096, before line 3099):
- Add `OutputPath = $dirs.Priv` to param hashes for `Get-PrivilegedGroupMembership` and
  `Find-AdminCountOrphan` (lines 3064–3065)
- After the loop: look up roastable results via `Where-Object { $_.Function -eq '...' }`,
  build combined rows with `ThreatType`, wrap in try/catch, write `roastable-accounts.csv`
  if rows exist, emit `Write-Warning` on failure

### Pass 3 — Update `docs/domain-specs.md`

Section 3 (Privileged Access) lists functions as single-line bullets with no return contract
detail. Update:
- `Get-PrivilegedGroupMembership`: add CSV export note, filename, columns, `CSVPath` return field
- `Find-AdminCountOrphan`: same
- `Find-KerberoastableAccount` / `Find-ASREPRoastableAccount`: note combined output appears in
  `roastable-accounts.csv` via orchestrator, not from either function directly

## Out of Scope

- New columns or additional AD properties beyond what functions already collect
- Report changes (metrics/advisories already work from structured return data)
- `-OutputPath` on `Find-KerberoastableAccount` or `Find-ASREPRoastableAccount`
- Resolving `MemberOf` DNs to display names (new AD call)
- Changing the existing generic orchestrator mock in `BeforeAll`

## Model

Sonnet. Four sequential passes: confirm mock pattern → tests → implementation → docs.

# Step 8 Subplan: Find-DormantAccount

Most complex single function in the project. One function in the `IdentityLifecycle` domain. Discovery phase. Follows the established pattern (return contract, `-Server` splatting, `try/catch` sections, `Warnings` array) but adds `-OutputPath` for CSV export and the `lastLogonTimestamp` optimization for cross-DC query efficiency.

**Dev-guide checkpoints applied:** Code budget, completion over expansion, guards at boundaries, test behavior not implementation, one function one job, max 2 nesting levels.

**Current state:** 13 working API functions, 102 tests passing. This step adds 1 function (the most complex).

**V0 reference:** `.v0/Find-DormantAccounts.ps1` has exclusion logic (lines 68–204), cross-DC LastLogon aggregation (lines 229–241), never-logged-on handling (lines 253–266), CSV export (lines 310–332), and MemberOfGroups formatting (line 292). Carry the exclusion categories, cross-DC foreach-try pattern, and MemberOfGroups semicolon join. Drop Write-Host output, stale password secondary signal, IncludeNeverLoggedOn switch (always include, gated by grace period), and Description/CanonicalName/Info/extensionAttribute fields.

**Key divergence from v0:** The v0 script queries every DC for every filtered user — O(users × DCs). The spec requires a `lastLogonTimestamp` first pass: query the replicated attribute once, then only cross-DC query accounts within 15 days of the threshold. This changes cost from O(users × DCs) to O(near-threshold-users × DCs).

---

## Pass 1: Core Function — Exclusions + Basic Dormancy Detection

The function skeleton, config reads, AD query, all six exclusion categories, basic dormancy classification using `lastLogonTimestamp` only (no cross-DC yet), never-logged-on handling, and return contract. This pass produces correct results for the majority of accounts — only the narrow near-threshold band will be refined in Pass 2.

### 8a. Find-DormantAccount (core)

- [x] **`Find-DormantAccount` function** in `#region Identity Lifecycle`

  Code-budget target for this pass: ~55 lines. Pass 2 adds ~15–20 more lines for cross-DC + CSV.

  | Parameter | Type | Notes |
  |-----------|------|-------|
  | `-Server` | string | Standard AD target |
  | `-OutputPath` | string | Optional CSV output path |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'IdentityLifecycle'` | Literal |
  | `Function` | `'Find-DormantAccount'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `ThresholdDays` | `[int]` | `Get-MonarchConfigValue 'DormancyThresholdDays'` |
  | `Accounts` | `@([PSCustomObject])` | Array of dormant account objects |
  | `CSVPath` | `[string]` | `$null` in Pass 1 (CSV added in Pass 2) |
  | `TotalCount` | `[int]` | Count of Accounts array |
  | `NeverLoggedOnCount` | `[int]` | Count where DaysSinceLogon = -1 |
  | `ExcludedCount` | `[int]` | Total queried minus included |
  | `Warnings` | `@([string])` | Accumulated errors |

  Account sub-object shape:

  | Property | Type | Source |
  |----------|------|--------|
  | `SamAccountName` | `[string]` | From `Get-ADUser` |
  | `DisplayName` | `[string]` | From `Get-ADUser` |
  | `LastLogon` | `[datetime]` or `$null` | Converted from `lastLogonTimestamp` FileTime; `$null` if never |
  | `DaysSinceLogon` | `[int]` | Days since LastLogon; `-1` if never |
  | `PasswordLastSet` | `[datetime]` | From `Get-ADUser` |
  | `PasswordAgeDays` | `[int]` | Calculated from PasswordLastSet |
  | `MemberOfGroups` | `[string]` | Semicolon-delimited group names |
  | `DormantReason` | `[string]` | Classification text |
  | `DistinguishedName` | `[string]` | From `Get-ADUser` |

  Implementation details:
  - MSA/gMSA filtered out via `Where-Object objectClass` immediately after `Get-ADUser` query
  - Six exclusion categories: built-in accounts, PasswordNeverExpires, SPNs, keyword match, privileged group membership, MSA/gMSA (pre-filtered)
  - `[regex]::Escape($kw)` on keywords — keywords contain `-` which is regex special
  - `lastLogonTimestamp` converted from FileTime via `[DateTime]::FromFileTime()`
  - Never-logged-on: check WhenCreated age against NeverLoggedOnGraceDays
  - MemberOfGroups resolved via `Get-ADGroup -Identity` per DN, joined with '; '

- [x] **Tests: Find-DormantAccount (core)** (~11 tests)
  - Account with no logon for 100 days → included with correct DormantReason
  - Account with logon 30 days ago → excluded
  - Built-in account (Administrator) → excluded
  - Account with PasswordNeverExpires → excluded
  - Account with SPN → excluded
  - Account matching service keyword (e.g., "SVC-Backup") → excluded
  - MSA/gMSA object → excluded
  - Account in privileged group → excluded
  - Never-logged-on account created 10 days ago → excluded (grace period)
  - Never-logged-on account created 90 days ago → included
  - ExcludedCount = total users minus included count

**Pass 1 exit criteria:** Function returns correct objects with all six exclusion categories working. 11 tests passing. Cross-DC refinement and CSV export not yet implemented.

---

## Pass 2: Cross-DC Optimization + CSV Export + Config Override Tests

Add the `lastLogonTimestamp` optimization (cross-DC queries for near-threshold accounts only), CSV export when `OutputPath` provided, and the remaining 3 tests.

### 8b. Cross-DC lastLogon refinement

- [x] **Add cross-DC optimization to Find-DormantAccount** (~15–20 additional lines)

  Insert between exclusion filtering and dormancy classification. Defines `$nearThresholdCutoff` = threshold minus 15 days. Accounts with `lastLogonTimestamp` in the 15-day window get cross-DC `lastLogon` queries. Per-DC `Get-ADUser -Identity -Server $dc.HostName -Properties LastLogon`, take max across all DCs.

  Nesting: `foreach user { foreach DC { try/catch } }` = 2 levels in inner block. Within limits.

### 8c. CSV export

- [x] **Add CSV export to Find-DormantAccount** (~8 additional lines)

  When `$OutputPath` provided and accounts exist, `Export-Csv` with 7 fields: SamAccountName, DisplayName, LastLogon, DaysSinceLogon, PasswordAgeDays, MemberOfGroups, DormantReason.

### 8d. Remaining tests

- [x] **Tests: CSV export and config overrides** (~3 tests)
  - CSV written to OutputPath with correct columns
  - Config override: custom DormancyThresholdDays changes threshold
  - Config override: custom ServiceAccountKeywords changes exclusion

**Pass 2 exit criteria:** Cross-DC optimization in place. CSV export works. All 14 tests passing. Function totals ~65–75 lines.

---

## Pass 3: Full Suite Verification

- [x] **Run all tests (Steps 1–8)** — verify no regressions
  - Steps 1–7 tests still pass (102 existing)
  - All Step 8 tests pass (14 new)
  - Expected total: ~116 tests
- [x] **Check diagnostics** — no warnings or errors in `.psm1`
- [x] **Verify `FunctionsToExport`** — `Find-DormantAccount` already listed in `Monarch.psd1`
- [x] **Verify function placement** — function lives in `#region Identity Lifecycle` (lines 600–746)
- [x] **Code budget check** — 106 substantive lines (above 65–75 target, justified by breadth: 6 exclusions + cross-DC + CSV)

**Pass 3 exit criteria:** Full green suite. 14 working API functions total.

---

## New Cmdlets to Stub (beyond Steps 4–7)

No new cmdlet stubs needed. All cmdlets already stubbed from prior steps:

| Cmdlet | Already stubbed in | Notes for Step 8 |
|--------|-------------------|------------------|
| `Get-ADUser` | Steps 5–7 | New properties: `lastLogonTimestamp`, `WhenCreated`, `PasswordNeverExpires`, `ServicePrincipalName`, `objectClass`. All param shapes already in stub. |
| `Get-ADGroup` | Steps 6–7 | Used for privileged group RID lookup + MemberOfGroups name resolution. `-Identity` for DN lookup. |
| `Get-ADDomainController` | Steps 5–7 | Used for cross-DC DC list (Pass 2). Already stubbed with `-Filter '*'`. |

Mock data note: `lastLogonTimestamp` is a FileTime integer. Use `(Get-Date).AddDays(-100).ToFileTime()` in mocks.

---

## Dev-Guide Compliance Notes

| Principle | How applied |
|-----------|-------------|
| Code budget | Target ~65–75 lines total. Most complex function, justified by breadth (6 exclusion categories + cross-DC + CSV). Each section is individually simple. |
| Completion over expansion | Two implementation passes. Pass 1 ships core logic with 11 tests (usable without cross-DC). Pass 2 adds optimization + CSV + remaining tests. |
| Guards at boundaries | `-Server` splatting built once. Initial `Get-ADUser` in try/catch. Per-DC try/catch in cross-DC loop. `Get-ADGroup` per-DN try/catch for MemberOfGroups. |
| Test behavior not implementation | Tests check which accounts appear in Accounts array, DormantReason content, ExcludedCount arithmetic, CSV column presence. No assertions on internal variables or call sequences. |
| One function one job | Single function does dormancy discovery. Does not disable, move, or modify accounts. CSV export is ancillary output of the same discovery. |
| Max 2 nesting levels | Cross-DC loop: `foreach user { foreach DC { try/catch } }` = 2 levels. Exclusion filtering is sequential foreach with continue, not nested. |
| Config access | Four config keys via `Get-MonarchConfigValue`: `DormancyThresholdDays`, `NeverLoggedOnGraceDays`, `ServiceAccountKeywords`, `BuiltInExclusions`. All already in `$script:DefaultConfig`. |
| No cross-function dependencies | RID pattern for privileged group detection duplicated inline (same block as Steps 6–7). Does not call `Get-PrivilegedGroupMembership`. |

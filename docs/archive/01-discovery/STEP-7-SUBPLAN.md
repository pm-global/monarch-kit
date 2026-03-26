# Step 7 Subplan: Privileged Access

Four functions in the `PrivilegedAccess` domain. All Discovery phase, all follow the established pattern (return contract, `-Server` splatting, `try/catch` sections, `Warnings` array).

**Dev-guide checkpoints applied:** Code budget, completion over expansion, guards at boundaries, test behavior not implementation, one function one job, no cross-function dependencies.

**Current state:** 9 working API functions, 86 tests passing. This step adds 4 more functions.

**V0 reference:** `Audit-PrivilegedAccess.ps1` has group discovery (lines 68–105), recursive membership (lines 117–157), AdminCount orphans (lines 249–289), and user analysis (lines 173–233). Carry the data shapes and RID patterns. Drop text output, CSV export, risk scoring, and "handover" language.

---

## Pass 1: Get-PrivilegedGroupMembership + Find-AdminCountOrphan

Two functions that both query privileged groups by RID pattern. Natural pairing — same stubs, same mock data foundation. Ship both with tests in one pass.

### 7a. Get-PrivilegedGroupMembership

- [x] **`Get-PrivilegedGroupMembership` function** in `#region Privileged Access`

  Most complex function in this step. Enumerates all privileged groups by RID pattern, gets direct + recursive members, classifies IsDirect, checks DomainAdminCount against config thresholds.

  Code-budget target: ~60–70 lines.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'PrivilegedAccess'` | Literal |
  | `Function` | `'Get-PrivilegedGroupMembership'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `Groups` | `@([PSCustomObject])` | Array of group objects (see below) |
  | `DomainAdminCount` | `[int]` | Member count of *-512 group |
  | `DomainAdminStatus` | `[string]` | `OK`, `Warning`, `Critical` |
  | `Warnings` | `@([string])` | Accumulated errors |

  Group sub-object shape:

  | Property | Type |
  |----------|------|
  | `GroupName` | `[string]` |
  | `GroupSID` | `[string]` |
  | `MemberCount` | `[int]` |
  | `Members` | `@([PSCustomObject])` |

  Member sub-object shape:

  | Property | Type | Source |
  |----------|------|--------|
  | `SamAccountName` | `[string]` | `Get-ADGroupMember` |
  | `DisplayName` | `[string]` | `Get-ADUser` |
  | `ObjectType` | `[string]` | `.objectClass` from `Get-ADGroupMember` |
  | `IsDirect` | `[bool]` | In non-recursive set |
  | `IsEnabled` | `[bool]` | `Get-ADUser .Enabled` |
  | `LastLogon` | `[datetime]` or `$null` | `Get-ADUser .LastLogonDate` |

  Implementation details:
  - Two `Get-ADGroupMember` calls per group: non-recursive (direct) and `-Recursive` (all). Delta = nested members.
  - Per-member `Get-ADUser -Identity` for user details. Computer objects or deleted accounts may fail — each in own try/catch.
  - `DomainAdminStatus`: compare count against `DomainAdminWarningThreshold` (default 5) and `DomainAdminCriticalThreshold` (default 10) via `Get-MonarchConfigValue`.
  - Per-group try/catch — one group failure doesn't block others. 3-level nesting justified for per-group resilience.

- [x] **Tests: Get-PrivilegedGroupMembership** (~7 tests)
  - Return shape correct, Domain = 'PrivilegedAccess', Function = 'Get-PrivilegedGroupMembership'
  - Nested member has `IsDirect = $false`
  - Direct member has `IsDirect = $true`
  - DomainAdminCount = 3 → `DomainAdminStatus = 'OK'`
  - Group has correct MemberCount (direct + nested)
  - DomainAdminCount = 7 → `DomainAdminStatus = 'Warning'`
  - Config override changes thresholds

### 7b. Find-AdminCountOrphan

- [x] **`Find-AdminCountOrphan` function** in `#region Privileged Access`

  Code-budget target: ~35–40 lines. Queries AdminCount=1 users, cross-references against privileged group DNs.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'PrivilegedAccess'` | Literal |
  | `Function` | `'Find-AdminCountOrphan'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `Orphans` | `@([PSCustomObject])` | Array of orphan objects |
  | `Count` | `[int]` | Orphans count |
  | `Warnings` | `@([string])` | Accumulated errors |

  Orphan sub-object: SamAccountName, DisplayName, Enabled, MemberOf.

  Implementation details:
  - Independent group discovery — does NOT call `Get-PrivilegedGroupMembership`. Duplicating 3 lines of RID lookup is better than creating a function dependency.
  - MemberOf comparison — direct membership only. Orphan detection doesn't need nested resolution.

- [x] **Tests: Find-AdminCountOrphan** (~3 tests)
  - Account with AdminCount=1 and no privileged group → is an orphan
  - Account with AdminCount=1 in Domain Admins → not an orphan
  - Count matches Orphans array length

**Pass 1 exit criteria:** Both functions return correct objects. ~10 tests passing.

---

## Pass 2: Find-KerberoastableAccount + Find-ASREPRoastableAccount

Two simple user queries with privileged cross-reference. Natural pairing — similar structure, shared stubs.

### 7c. Find-KerberoastableAccount

- [x] **`Find-KerberoastableAccount` function** in `#region Privileged Access`

  Code-budget target: ~35–40 lines. Queries ALL user accounts with SPNs, flags privileged subset.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'PrivilegedAccess'` | Literal |
  | `Function` | `'Find-KerberoastableAccount'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `Accounts` | `@([PSCustomObject])` | Array of account objects |
  | `TotalCount` | `[int]` | Total SPN accounts |
  | `PrivilegedCount` | `[int]` | Count where IsPrivileged = $true |
  | `Warnings` | `@([string])` | Accumulated errors |

  Account sub-object: SamAccountName, DisplayName, SPNs, IsPrivileged, PasswordAgeDays, Enabled.

  Per spec: returns ALL accounts with SPNs, not just privileged. `IsPrivileged` flag lets consumers filter.

- [x] **Tests: Find-KerberoastableAccount** (~4 tests)
  - Non-privileged account with SPN → included, `IsPrivileged = $false`
  - Privileged account with SPN → included, `IsPrivileged = $true`
  - `PrivilegedCount` counts only `IsPrivileged = $true` entries
  - `TotalCount` = total entries

### 7d. Find-ASREPRoastableAccount

- [x] **`Find-ASREPRoastableAccount` function** in `#region Privileged Access`

  Code-budget target: ~25–30 lines. Simplest function in this step.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'PrivilegedAccess'` | Literal |
  | `Function` | `'Find-ASREPRoastableAccount'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `Accounts` | `@([PSCustomObject])` | Array of account objects |
  | `Count` | `[int]` | Total accounts |
  | `Warnings` | `@([string])` | Accumulated errors |

  Account sub-object: SamAccountName, DisplayName, IsPrivileged, Enabled.

  Logic: `Get-ADUser -Filter 'DoesNotRequirePreAuth -eq $true'` + privileged cross-reference.

- [x] **Tests: Find-ASREPRoastableAccount** (~2 tests)
  - Return shape correct
  - Count matches array length

**Pass 2 exit criteria:** Both functions return correct objects. ~6 tests passing.

---

## Pass 3: Full Suite Verification

- [x] **Run all tests (Steps 1–7)** — verify no regressions
  - Steps 1–6 tests still pass (86 existing)
  - All Step 7 tests pass
  - Expected total: ~102 tests (86 existing + ~16 new)
- [x] **Check diagnostics** — no warnings or errors in `.psm1`
- [x] **Verify `FunctionsToExport`** — all four functions listed in `Monarch.psd1`
- [x] **Verify function placement** — all four live in `#region Privileged Access`

**Pass 3 exit criteria:** Full green suite. Thirteen working API functions total.

---

## New Cmdlets to Stub (beyond Steps 4–6)

No new cmdlets — all were introduced in Steps 4–6. Existing stubs need updates:

| Cmdlet | Update needed | Used by |
|--------|--------------|---------|
| `Get-ADGroupMember` | Add `[switch]$Recursive` parameter | 7a |
| `Get-ADUser` | Already has `-Identity` from Step 6 | 7a, 7b, 7c, 7d |
| `Get-ADGroup` | Already has `-Properties SID` | All |

---

## Dev-Guide Compliance Notes

| Principle | How applied |
|-----------|-------------|
| Code budget | Get-PrivilegedGroupMembership ~65 lines (most complex), others ~25–40. No function exceeds its scope. |
| Completion over expansion | Two implementation passes, each ships complete functions with tests. Complex + moderate paired in Pass 1. |
| Guards at boundaries | `-Server` splatting built once per function. Per-group try/catch in enumeration. |
| Test behavior not implementation | Tests check return values, counts, and status classification, not internal variable names or call sequences. |
| One function one job | Each function does one audit query. `Find-AdminCountOrphan` independently discovers groups — no cross-function dependency. |
| Max 2 nesting levels | Get-PrivilegedGroupMembership has foreach>try>foreach (3 levels justified for per-group resilience). |
| Config access | DomainAdminWarningThreshold, DomainAdminCriticalThreshold via Get-MonarchConfigValue. |

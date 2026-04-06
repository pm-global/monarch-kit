# Step 7 — Advisory Description Improvements (All 4 Passes)

## Context

Step 7 of `report-data-plan.md`. Steps 1-6 are complete (serialization fixes, all 6 metrics strips). This step rewrites 4 advisory descriptions in `New-MonarchReport` to surface more actionable data. All 4 changes are in independent `switch` cases — no conflicts — so they execute as a single pass.

## Pre-existing Issue Found During Review

**`EnterpriseAdminCount` does not exist on the actual return object of `Get-PrivilegedGroupMembership`.**

The function (lines 849-857) returns: `DomainAdminCount`, `DomainAdminStatus`, `Groups`, `Warnings`.
There is no `EnterpriseAdminCount` top-level property. The EA count is derivable from `.Groups` where `GroupSID -like '*-519'`, but it's not surfaced.

This affects:
- **Step 2 metrics strip** (line 2783): references `$privGrp.EnterpriseAdminCount` — will always be `$null`, metric silently never renders in real usage. Test at line 4232 hand-fabricates `EnterpriseAdminCount = 2` on the mock, masking this.
- **7C denominator** (this step): plan says `DomainAdminCount + EnterpriseAdminCount` — the EA half will be `$null`.

**Resolution options (needs decision before implementing 7C):**
- A: Derive EA count from `.Groups` at the report layer: `$eaGroup = $privGrpResult.Groups | Where-Object { $_.GroupSID -like '*-519' }; $eaCount = if ($eaGroup) { $eaGroup.MemberCount } else { 0 }` — correct but couples report to group enumeration internals
- B: Use `DomainAdminCount` only as denominator — simpler, but understates the total privileged population
- C: Fix the function to add `EnterpriseAdminCount` to its return — correct root fix, but that's a function contract change (out of scope for Step 7, which is report-only)
- D: Compute a deduplicated total across all groups from `.Groups`: `($privGrpResult.Groups | Measure-Object -Property MemberCount -Sum).Sum` — but this double-counts users in multiple groups

**My recommendation: Option A for now (derive at report layer), file Option C as a follow-up.** The `.Groups` array is the function's documented return contract and its shape is stable. But this needs sign-off.

---

## Changes

### 7A — FSMO single-DC advisory: add DC name
**File:** `Monarch.psm1` — `Get-FSMORolePlacement` case (currently line ~2643)
**Current:** `'All FSMO roles held by a single DC'`
**New:** Interpolate `$r.Roles[0].Holder` when available, fall back to current text if `Roles` is empty/null.

**Return shape verified:** `Get-FSMORolePlacement` returns `.Roles` as array of `{ Role, Holder (string), Reachable (bool), Site }`, `.AllOnOneDC` (bool), `.UnreachableCount` (int). When `AllOnOneDC = $true`, all entries in `Roles` have the same `Holder` value, so `Roles[0].Holder` is correct.

**Null guard needed:** `Roles` could be empty if all role holder lookups failed (warnings populated instead). Fall back to generic text.

**No multi-DC concern:** `AllOnOneDC = $true` means literally one DC holds everything.

**Assessment: Straightforward. No issues found.**

### 7B — Event log advisory: count DCs not issues — NEEDS REWORK

**File:** `Monarch.psm1` — `Get-EventLogConfiguration` case (currently line ~2621)

**Return shape:** `.DCs` is array of `{ DCName (string), Logs: array of { LogName, MaxSizeKB, OverflowAction } }`.

**The problem the plan identified:** The original code built an `$issues` array with one entry per issue per DC, then counted issues. One DC with 2 problems (undersized + bad overflow) → "2 event log configuration issues" which misleadingly suggests 2 DCs.

**What the original code actually preserved that I erased:** Each `$issues` entry was a string like `"DC01: Security log 512000KB (minimum 1048576)"` — it named the DC and the specific problem. The count was misleading but the underlying data was actionable.

**What the plan spec said:** `"Security log misconfigured on $n DC(s)"` — this fixes the count problem but throws away the specific issue detail AND the DC name association.

**What an admin needs to see:**
1. Which DCs are affected (by name)
2. What specifically is wrong on each one (undersized? bad overflow action? both?)

**Revised approach:** Keep the per-DC iteration, but build a per-DC summary that names the DC and its issues. The advisory description should read like:
`"Security log: DC01 (undersized, overflow action), DC02 (undersized)"`

Or for a single DC with one issue:
`"Security log: DC01 (undersized — 512000KB, minimum 1048576KB)"`

**Key design question:** How verbose should a single advisory description string be with 5+ DCs? At scale this could get long. Options:
- A: Full detail for all DCs in description (accurate, potentially long)
- B: Name all DCs with issue type tags, no numeric detail: `"Security log: DC01 (undersized, overflow), DC02 (undersized)"`
- C: Name up to 3 DCs, then `"...and N more"` for the rest
- D: Keep current approach but fix the count to be DC-based: `"Security log misconfigured on 2 DC(s): DC01, DC02"` — names DCs but doesn't say what's wrong on each

**My recommendation: Option B.** Compact enough for 2-5 DCs (typical), names every DC, tells the admin what category of fix each needs. The exact KB values are available in the raw data export. The advisory card's job is triage — "what do I look at first" — not a fix recipe.

### 7C — Protected Users gap: add denominator — NEEDS DENOMINATOR DECISION

**File:** `Monarch.psm1` — `Test-ProtectedUsersGap` case (currently line ~2562)
**Current:** `"$($r.GapAccounts.Count) privileged accounts not in Protected Users"`

**Cross-domain data join:** `Test-ProtectedUsersGap` is in `SecurityPosture` domain, `Get-PrivilegedGroupMembership` is in `PrivilegedAccess`. Searching `$resultsList` by function name (not domain) is correct since function names are unique.

**Critical finding — group scope mismatch:**
`Test-ProtectedUsersGap` checks **7 privileged groups**: DA (-512), EA (-519), Schema Admins (-518), Administrators (S-1-5-32-544), Account Operators (-548), Server Operators (-549), Backup Operators (-551). GapAccounts are deduplicated across all of them.

`Get-PrivilegedGroupMembership` checks the **same 7 groups** and returns them in `.Groups`, but only surfaces `DomainAdminCount` as a top-level count. `EnterpriseAdminCount` is not on the return object (see pre-existing issue above).

So `DA + EA` is a subset of the population that `Test-ProtectedUsersGap` evaluates. If there are 15 gap accounts and 9 are DA+EA, the other 6 are from Account Ops, Backup Ops, etc. Showing "15 of 9" would be wrong and confusing.

**Revised approach options:**
- A: Derive total from `.Groups` MemberCount sum — but this double-counts (a user in DA and EA counts twice)
- B: Use only `DomainAdminCount` and label it clearly: `"15 privileged accounts not in Protected Users (7 Domain Admins)"` — shifts meaning from "denominator" to "context"
- C: Just add the DA+EA context without framing it as a fraction: `"15 privileged accounts not in Protected Users — includes 7 DAs, 2 EAs"` — additive context, not a ratio
- D: Keep count-only form until the function adds a deduplicated total (Option C from pre-existing issue)

**My recommendation: Option C.** It adds context without creating a misleading ratio. The cross-reference to `Get-PrivilegedGroupMembership` is still useful (naming DA/EA counts), just not as a denominator. Option D is the safest but adds no value.

**If Option C, the EA count needs to be derived** from `.Groups` at the report layer since it's not a top-level property. See pre-existing issue above.

### 7D — Kerberoastable: always show privileged count
**File:** `Monarch.psm1` — `Find-KerberoastableAccount` case (currently line ~2560, already edited)
**Current (already changed):** `"$($r.TotalCount) accounts with SPNs — 0 privileged"`

**Return shape verified:** `.TotalCount` (int), `.PrivilegedCount` (int). Both always present. No cross-reference needed.

**Assessment: Already implemented correctly. The em-dash format is clean and matches the critical-path description style (`"N privileged accounts with SPNs (Kerberoasting risk -- privileged)"`).**

---

## Test Updates

### Existing tests to modify

1. **Line 3654** — EventLog advisory assertion: update to match new description format (depends on 7B approach chosen)
2. **Line 3612** — EventLog mock: 1 DC with 2 issues — update assertion to reflect DC-named output
3. **Line 3616** — FSMO mock: `Roles = @()` — keep for fallback test
4. **Line 3625** — Kerberoastable assertion: update from `'50 accounts with SPNs'` to match `'50 accounts with SPNs.*0 privileged'`
5. **Line 3662** — FSMO assertion: keep as fallback-text test (Roles is empty in this mock)

### New tests to add

1. **7A** — FSMO with populated Roles + `AllOnOneDC = $true` → advisory contains DC hostname
2. **7A** — FSMO with empty Roles (existing mock covers fallback)
3. **7B** — 1 DC with 2 issues → description names DC and both issue types
4. **7B** — 2 DCs with different issues → description names both DCs with their respective issues
5. **7B** — 0 affected DCs → no advisory
6. **7C** — Gap + PrivilegedGroupMembership present → description includes DA/EA context
7. **7C** — Gap without PrivilegedGroupMembership → count-only form
8. **7D** — `TotalCount=50, PrivilegedCount=0` → `'0 privileged'` in advisory (already edited, needs test)
9. **7D** — `TotalCount=0` → no card (regression guard)

### Pre-existing test issue to address

- **Line 4232** — mock fabricates `EnterpriseAdminCount = 2` which the real function doesn't return. If we derive EA from `.Groups` at the report layer, the test mock needs a `.Groups` array with EA group entry. If we only use `DomainAdminCount`, remove the fabricated property to prevent false confidence.

---

## Decisions (signed off 2026-04-05)

1. **7B format:** Option B — `"Security log: DC01 (undersized, overflow), DC02 (undersized)"`
2. **7C approach:** Option C — `"15 privileged accounts not in Protected Users — includes 7 DAs, 2 EAs"`
3. **7C EA derivation:** Derive from `.Groups` at report layer (filter by `GroupSID -like '*-519'`)
4. **Pre-existing `EnterpriseAdminCount` gap:** Fix metrics strip now (line 2783) — derive EA from `.Groups` there too, same pattern as 7C

## Files to Modify

- `/var/mnt/storage/CODE/monarch-kit/Monarch.psm1` — 4 switch cases in advisory generation
- `/var/mnt/storage/CODE/monarch-kit/Tests/Monarch.Tests.ps1` — advisory test contexts

## Verification

1. Run full Pester suite
2. No advisory description contains raw `$null` or empty interpolated values
3. All 4 advisory rewrites verified by specific test assertions
4. EventLog advisory names DCs for actionability
5. Protected Users advisory doesn't produce misleading ratios

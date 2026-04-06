# Step 7 — Advisory Description Improvements (All 4 Passes)

## Context

Step 7 of `report-data-plan.md`. Steps 1-6 are complete (serialization fixes, all 6 metrics strips). This step rewrites 4 advisory descriptions in `New-MonarchReport` to surface more actionable data. All 4 changes are in independent `switch` cases — no conflicts — so they execute as a single pass.

## Changes

### 7A — FSMO single-DC advisory: add DC name
**File:** `Monarch.psm1:2634`
**Current:** `'All FSMO roles held by a single DC'`
**New:** Interpolate `$r.Roles[0].Holder` when available, fall back to current text if `Roles` is empty/null.

The mock at test line 3616 has `Roles = @()` — need to add a Roles entry with a Holder for the new test, or add a separate test context.

### 7B — Event log advisory: count DCs not issues
**File:** `Monarch.psm1:2612-2623`
**Current:** Builds `$issues` array (one entry per issue per DC), then reports `"$($issues.Count) event log configuration issues across DCs"` — one DC with 2 problems says "2 issues" (misleading).
**New:** Count distinct DCs with at least one issue. Description: `"Security log misconfigured on $n DC(s)"`.

Replace the `$issues` array approach with an `$affectedDCs` list that tracks unique DC names.

### 7C — Protected Users gap: add denominator
**File:** `Monarch.psm1:2562-2563`
**Current:** `"$($r.GapAccounts.Count) privileged accounts not in Protected Users"`
**New:** Cross-reference `Get-PrivilegedGroupMembership` from `$resultsList` to get DA+EA count as denominator: `"N of M privileged accounts not in Protected Users"`. Fall back to count-only when the priv group result is absent.

Per plan recommendation: use `DomainAdminCount + EnterpriseAdminCount` as the tier-0 denominator.

### 7D — Kerberoastable: always show privileged count
**File:** `Monarch.psm1:2560`
**Current:** `"$($r.TotalCount) accounts with SPNs (Kerberoasting risk)"` (when PrivilegedCount=0)
**New:** `"$($r.TotalCount) accounts with SPNs — 0 privileged"` — always shows the privileged count so reviewers know it was checked.

## Test Updates

### Existing tests to modify

1. **Line 3654** — EventLog advisory assertion: change `'event log configuration issues'` to match new `'Security log misconfigured on'` pattern.

2. **Line 3612** — EventLog mock in advisory context: currently has 1 DC with 2 issues (undersized + bad overflow). New assertion should match `'Security log misconfigured on 1 DC'`.

3. **Line 3616** — FSMO mock: `Roles = @()` means fallback text. Either update this mock to include a Roles entry with Holder, or keep it for the fallback test and add a new test for the DC-name path.

4. **Line 3625** — Kerberoastable assertion: update `'50 accounts with SPNs'` to match new format `'50 accounts with SPNs.*0 privileged'`.

5. **Line 3662** — FSMO assertion: update to match new description text when Roles has a Holder.

### New tests to add (in the advisory extraction context or new context)

1. **7A** — FSMO with populated Roles: `AllOnOneDC = $true`, `Roles = @([PSCustomObject]@{ Role='PDCEmulator'; Holder='DC01.contoso.com'; Reachable=$true; Site='Default' })` → advisory contains `'DC01.contoso.com'`
2. **7A** — FSMO with empty Roles: falls back to `'All FSMO roles held by a single DC'` (existing mock covers this)
3. **7B** — 2 DCs each with 1 issue → `'Security log misconfigured on 2 DC'`
4. **7B** — 0 affected DCs → no advisory rendered
5. **7C** — Gap + PrivilegedGroupMembership present → `'of \d+'` in description
6. **7C** — Gap without PrivilegedGroupMembership → count-only form (no "of")
7. **7D** — `TotalCount=50, PrivilegedCount=0` → `'0 privileged'` in advisory
8. **7D** — `TotalCount=0` → no card (existing behavior, regression guard)

## Implementation Order

Single pass — all 4 code edits, then all test updates, then run full suite.

## Files to Modify

- `/var/mnt/storage/CODE/monarch-kit/Monarch.psm1` — lines 2558-2634 (4 switch cases)
- `/var/mnt/storage/CODE/monarch-kit/Tests/Monarch.Tests.ps1` — advisory test context (~line 3559) + new test contexts

## Verification

1. Run full Pester suite: `Invoke-Pester ./Tests/Monarch.Tests.ps1 -Output Detailed`
2. Confirm no advisory description contains raw `$null` or empty interpolated values
3. All 4 advisory rewrites verified by specific test assertions

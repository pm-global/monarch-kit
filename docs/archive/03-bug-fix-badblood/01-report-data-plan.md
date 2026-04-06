# Report Data Surface — Implementation Plan

## Context

`New-MonarchReport` in `Monarch.psm1` generates the HTML discovery report from orchestrator results.
The report has two confirmed bug categories and one data-surfacing gap category.
This plan addresses all three. Read `dev-guide.md` before starting any pass.

**Project type:** Library/Module (report generator called by orchestrator).
**Integration surface:** `New-MonarchReport` accepts a `$Results` PSCustomObject and writes an HTML file.
The return contract (file path string) must not change. Internal HTML structure changes are safe.
**Test file:** `Tests/Monarch.Tests.ps1` — Pester 5+, all AD/DNS/GPO cmdlets mocked.

---

## Implementation Sequence

```
Step 1: Serialization bugs (A1, A2 skeleton)       — Sonnet  ✓
Step 2: Metrics strip — Privileged Access           — Sonnet  ✓
Step 3: Metrics strip — Infrastructure Health       — Sonnet  ✓
Step 4: Metrics strip — Identity Lifecycle          — Sonnet  ✓
Step 5: Metrics strip — Group Policy                — Sonnet  ✓
Step 6: Metrics strip — Security Posture            — Sonnet  ✓
Step 7: Advisory description improvements           — Opus    ✓
Step 8: AS-REP severity promotion                   — Sonnet  ✓
Step 9: Integration validation                      — Sonnet  ✓
```

Steps are sequential. Each step is one chat. Each step has a validation pass as its final action before handoff.

---

## Confirmed Return Contracts (reference for all passes)

### `Results` object (orchestrator output)
```
Results.Domain       — domain FQDN string
Results.DCUsed       — string (DC hostname) — confirmed from orchestrator: $dc = $target.DCName
Results.StartTime    — DateTime
Results.EndTime      — DateTime
Results.Results      — array of function result PSCustomObjects
Results.Failures     — array of failure PSCustomObjects
Results.Dispositions — array of disposition PSCustomObjects
Results.TotalChecks  — int
```

### Key function return contracts

**Get-ForestDomainLevel**
```
.DomainFunctionalLevel  — string (DomainMode value, e.g. 'Windows2016Domain')
.ForestFunctionalLevel  — string
.SchemaVersion          — int
```

**Get-FSMORolePlacement**
```
.Roles            — array of: { Role, Holder (DC hostname string), Reachable (bool), Site }
.AllOnOneDC       — bool
.UnreachableCount — int
```

**Get-SiteTopology**
```
.SiteCount         — int (direct property)
.SubnetCount       — int
.Sites             — array of site objects
.UnassignedSubnets — array
.EmptySites        — array
```

**Get-ReplicationHealth**
```
.FailedLinkCount   — int
.WarningLinkCount  — int
```

**Get-PrivilegedGroupMembership**
```
.DomainAdminCount    — int
.DomainAdminStatus   — 'Critical' | 'Warning' | 'OK'
.Groups              — array of: { GroupName, GroupSID, MemberCount, Members }
```

**Find-KerberoastableAccount**
```
.TotalCount      — int
.PrivilegedCount — int
```

**Find-AdminCountOrphan**
```
.Count — int
```

**Find-ASREPRoastableAccount**
```
.Accounts — array of: { SamAccountName, DisplayName, IsPrivileged (bool), Enabled }
.Count    — int (total, not privileged)
```
Note: PrivilegedCount must be computed at report layer:
`$privCount = @($r.Accounts | Where-Object { $_.IsPrivileged }).Count`

**Find-DormantAccount**
```
.NeverLoggedOnCount — int (accounts where DaysSinceLogon -eq -1)
.ExcludedCount      — int (totalQueried - accounts.Count)
.ThresholdDays      — int (from config)
.Accounts           — array
```

**Export-GPOAudit**
```
.TotalGPOs             — int
.UnlinkedCount         — int
.DisabledCount         — int
.HighRiskCounts        — PSCustomObject:
    .UserRights         — int
    .SecurityOptions    — int
    .Scripts            — int
    .SoftwareInstall    — int
.OverpermissionedCount — int
```

**Find-WeakAccountFlag**
```
.CountByFlag — hashtable: { 'PasswordNeverExpires', 'ReversibleEncryption', 'DESOnly' }
.Findings    — array
```

**Test-ProtectedUsersGap**
```
.GapAccounts — array (count = number of privileged accounts not in Protected Users)
```

**Find-LegacyProtocolExposure**
```
.DCFindings — array of: { Risk ('High'|'Medium'|'Low'), DCName, ... }
```

**Get-PasswordPolicyInventory**
```
.DefaultPolicy — PSCustomObject: { MinLength, ComplexityEnabled, LockoutThreshold, ReversibleEncryption }
```

**Get-EventLogConfiguration**
```
.DCs — array of: { DCName, Logs: array of { LogName, MaxSizeKB, OverflowAction } }
```

---

## Step 1 — Serialization Bug Fixes + Multi-Result Helper

**Model: Sonnet**

### Context to load
- `dev-guide.md`
- `New-MonarchReport` function (full text)
- This plan file

### Pass 1A — Fix `$dc` header variable

**Problem:** In the live report, the DC meta line renders as `@{DCName=LIGHT-DC.LIGHT.local; Logs=System.Object[]}`.
The orchestrator stores `DCUsed` as `$dc = $target.DCName` (a string), but something is producing an object in practice.

**Fix:** Guard the extraction:
```powershell
$dc = if ($Results.DCUsed -is [string]) { $Results.DCUsed } else { $Results.DCUsed.DCName }
```
This makes the header robust regardless of how DCUsed arrives.

**Location:** Near top of `New-MonarchReport`, in the "Extract header data" block.

**Tests to write:**
- `New-MonarchReport` called with `Results.DCUsed` as a plain string → header `<span>` contains the string
- `New-MonarchReport` called with `Results.DCUsed` as `[PSCustomObject]@{ DCName = 'DC01' }` → header `<span>` contains `'DC01'`
- Neither test should produce `@{` anywhere in the output

### Pass 1B — Replace `Select-Object -First 1` with multi-result collector

**Problem:** The domain-section loop does:
```powershell
$domainResult = $resultsList | Where-Object { $_.Domain -eq $d } | Select-Object -First 1
```
This discards all but the first result for a domain. Domains like InfrastructureHealth have 4 functions.

**Fix:** Replace with a full collect:
```powershell
$domainResults = @($resultsList | Where-Object { $_.Domain -eq $d })
```
Then replace `$domainResult` references in the existing `BackupReadiness` switch case with:
```powershell
$domainResult = $domainResults | Where-Object { $_.Function -eq 'Get-BackupReadinessStatus' } | Select-Object -First 1
```
This is a refactor pass — no new metrics cases yet, just restructures to unblock Steps 2–6.

**Tests to write:**
- Build a mock `$Results.Results` with two objects sharing the same `.Domain` value
- Verify the BackupReadiness metrics still render correctly (regression guard)
- Verify no `Select-Object -First 1` remains in the domain-section loop (code audit assertion in test comments)

### Validation before handoff
- All existing report tests pass
- The two new DC header tests pass
- The BackupReadiness regression test passes
- No `@{` appears in header output for either DCUsed shape

---

## Step 2 — Metrics Strip: Privileged Access

**Model: Sonnet**

### Context to load
- `dev-guide.md`
- `New-MonarchReport` function (full text, post-Step-1 version)
- This plan file (return contracts section + this step)

### Pass 2A — Add PrivilegedAccess metrics switch case

Add a `'PrivilegedAccess'` case to the domain-metrics switch. Pull from multiple results:

```
Domain Admins         → Get-PrivilegedGroupMembership: .DomainAdminCount
Enterprise Admins     → Get-PrivilegedGroupMembership: .EnterpriseAdminCount
Kerberoastable (priv) → Find-KerberoastableAccount:   .PrivilegedCount
AdminCount Orphans    → Find-AdminCountOrphan:         .Count
```

Each metric is null-guarded — if the result object is absent (function failed), omit that metric silently.

**HTML pattern** (matches existing BackupReadiness style):
```html
<div class='domain-metric'>Domain Admins: <strong>7</strong></div>
```

**Tests to write:**
- Mock results with all four functions present → all four metrics render
- Mock results with `Find-AdminCountOrphan` absent (failed/not assessed) → other three render, orphan metric absent
- Metric values are correct (spot-check each field)
- No metric renders as empty string or `$null`

### Validation before handoff
- New tests pass
- No regression in BackupReadiness or other domain sections

---

## Step 3 — Metrics Strip: Infrastructure Health

**Model: Sonnet**

### Context to load
- `dev-guide.md`
- `New-MonarchReport` function (full text, post-Step-2 version)
- This plan file (return contracts section + this step)

### Pass 3A — Add InfrastructureHealth metrics switch case

Pull from multiple results:

```
Domain Controllers → Get-SiteTopology:       compute from .Sites — sum of DC count per site
                     Fallback label if null:  omit metric
Site count         → Get-SiteTopology:        .SiteCount
Functional Level   → Get-ForestDomainLevel:   .DomainFunctionalLevel
FSMO status        → Get-FSMORolePlacement:   
                     if .UnreachableCount > 0  → "$($r.UnreachableCount) unreachable"
                     elseif .AllOnOneDC        → "Single DC"
                     else                      → "Distributed"
```

**DC count from Sites:** The `Sites` array contains site objects. The exact shape of a site object's DC list is not confirmed in this plan — implementer must grep `Get-SiteTopology` in `Monarch.psm1` to find the DC collection property name before writing the aggregation. If the shape is unclear, use `SiteCount` only and omit DC count with a TODO comment.

**Tests to write:**
- All four metrics render with mock data for all three functions
- FSMO status renders "Single DC" when `AllOnOneDC = $true`
- FSMO status renders "2 unreachable" when `UnreachableCount = 2`
- FSMO status renders "Distributed" when `AllOnOneDC = $false` and `UnreachableCount = 0`
- `Get-ForestDomainLevel` absent → functional level metric omitted, others render

### Validation before handoff
- All new and prior tests pass

---

## Step 4 — Metrics Strip: Identity Lifecycle

**Model: Sonnet**

### Context to load
- `dev-guide.md`
- `New-MonarchReport` function (full text, post-Step-3 version)
- This plan file (return contracts section + this step)

### Pass 4A — Add IdentityLifecycle metrics switch case

```
Dormant Accounts → Find-DormantAccount: .Accounts.Count
Never Logged On  → Find-DormantAccount: .NeverLoggedOnCount
Threshold        → Find-DormantAccount: .ThresholdDays  (render as "90 days")
Excluded         → Find-DormantAccount: .ExcludedCount  (render as "28 (service/built-in)")
```

**Tests to write:**
- All four metrics render with mock data
- Threshold renders with "days" suffix
- Excluded renders with "(service/built-in)" suffix
- `Find-DormantAccount` absent → section renders no metrics (not an error)

### Pass 4B — Improve dormant account advisory description

**Current:** `"143 dormant accounts identified for review"`
**Spec:** `"143 dormant accounts ($($r.ThresholdDays)-day threshold, $($r.ExcludedCount) excluded)"`

Location: the `'Find-DormantAccount'` case in the advisory-generation switch.

**Tests to write:**
- Advisory description includes threshold value
- Advisory description includes excluded count
- Zero dormant accounts → no advisory card rendered

**Existing test to update before writing new tests:**
- `Tests/Monarch.Tests.ps1` line ~3496 asserts the old text (`'12 dormant accounts identified for review'`).
  Update it to match the new format. The mock for that test (line ~3471) also lacks `ThresholdDays`
  and `ExcludedCount` properties — add them to the mock at the same time or the interpolation will
  produce empty values and the updated assertion will fail.

### Validation before handoff
- All new and prior tests pass

---

## Step 5 — Metrics Strip: Group Policy

**Model: Sonnet**

### Context to load
- `dev-guide.md`
- `New-MonarchReport` function (full text, post-Step-4 version)
- This plan file (return contracts section + this step)

### Pass 5A — Add GroupPolicy metrics switch case

```
Total GPOs       → Export-GPOAudit: .TotalGPOs
Unlinked         → Export-GPOAudit: .UnlinkedCount
With User Rights → Export-GPOAudit: .HighRiskCounts.UserRights
With Scripts     → Export-GPOAudit: .HighRiskCounts.Scripts
```

**Tests to write:**
- All four metrics render with mock data
- `HighRiskCounts` sub-object is null-guarded — if absent, User Rights and Scripts metrics omitted
- `Export-GPOAudit` absent → no metrics rendered

### Validation before handoff
- All new and prior tests pass

---

## Step 6 — Metrics Strip: Security Posture

**Model: Sonnet**

### Context to load
- `dev-guide.md`
- `New-MonarchReport` function (full text, post-Step-5 version)
- This plan file (return contracts section + this step)

### Pass 6A — Add SecurityPosture metrics switch case

```
Password Never Expires → Find-WeakAccountFlag:        .CountByFlag['PasswordNeverExpires']
                         null-guard: 0 if key absent
Protected Users Gaps   → Test-ProtectedUsersGap:      .GapAccounts.Count
Legacy Exposure        → Find-LegacyProtocolExposure: 
                         Group DCFindings by DCName (High/Medium only), render as "DC01 (2), DC02 (1)"
                         Note: DCFindings is per-finding not per-DC; grouping by DCName gives correct DC count.
                         Metric omitted entirely if no High/Medium findings.
```

**Tests to write:**
- All three metrics render with mock data
- `CountByFlag` missing `PasswordNeverExpires` key → renders as 0
- `DCFindings` with mixed Risk levels → count excludes 'Low'
- Any source function absent → that metric omitted, others render

### Validation before handoff
- All new and prior tests pass

---

## Step 7 — Advisory Description Improvements

**Model: Opus**

This step has the most judgment-sensitive work — cross-domain data joins and description rewrites.
Six improvements, implemented as individual passes so each can be verified independently.

### Context to load
- `dev-guide.md`
- `New-MonarchReport` function (full text, post-Step-6 version)
- This plan file (return contracts section + this step)

### Pass 7A — FSMO single-DC advisory: add DC name

**Current:** `"All FSMO roles held by a single DC"`
**Spec:** `"All FSMO roles held by $($fsmoResult.Roles[0].Holder)"`

`Roles[0].Holder` is the DC hostname string when `AllOnOneDC -eq $true`.
Null-guard: if `Roles` is empty or null, fall back to current text.

**Tests:**
- `AllOnOneDC = $true`, `Roles[0].Holder = 'DC01.contoso.com'` → advisory contains `'DC01.contoso.com'`
- `Roles` is empty → advisory falls back to generic text without error

### Pass 7B — Event log advisory: count DCs not issues

**Current logic:** builds an `$issues` array (one entry per issue per DC), then counts issues.
One DC with two problems → "2 event log configuration issues" (misleading).

**Implemented:** Consolidate to one entry per DC; collect issue tags per DC, then join.
Description format: `"Security log: DC01 (undersized, overflow action), DC02 (undersized)"`.
Each DC appears once regardless of how many issues it has.

```powershell
$dcSummaries = @()
foreach ($dcEntry in $r.DCs) {
    $secLog = $dcEntry.Logs | Where-Object { $_.LogName -eq 'Security' }
    if ($null -ne $secLog) {
        $tags = @()
        if ($secLog.MaxSizeKB -lt $minSize) { $tags += 'undersized' }
        if ($secLog.OverflowAction -notin $okActions) { $tags += 'overflow action' }
        if ($tags.Count -gt 0) { $dcSummaries += "$($dcEntry.DCName) ($($tags -join ', '))" }
    }
}
if ($dcSummaries.Count -gt 0) {
    $advisories.Add([PSCustomObject]@{ ... Description = "Security log: $($dcSummaries -join ', ')" })
}
```

Note: loop variable must be `$dcEntry`, not `$dc` — `$dc` is used earlier for the report header.

**Tests:**
- 1 DC with 2 issues → `"Security log: DC01 (undersized, overflow action)"`
- 2 DCs with different issues → `"Security log: DC01 (undersized, overflow action), DC02 (undersized)"`
- 0 affected DCs → no advisory

### Pass 7C — Protected Users gap: add denominator

**Current:** `"15 privileged accounts not in Protected Users"`
**Spec:** `"15 of [total] privileged accounts not in Protected Users"`

Total privileged count: cross-reference `Get-PrivilegedGroupMembership` result from `$resultsList`.
The total is not a single number — it's the sum of unique members across all privileged groups.
`Get-PrivilegedGroupMembership` returns `.DomainAdminCount` and `.EnterpriseAdminCount` but not a single total.

**Decision required before implementation:** What is the right denominator?
Options:
- A: `DomainAdminCount` only (most actionable — DA is the primary target group)
- B: A deduplicated total across all privileged groups (most accurate, requires the full member list)
- C: Omit denominator, keep current text (safe fallback if B is too complex)

**Recommendation: Option A.** The Protected Users gap is most consequential for DAs. "15 of 7 DA + 2 EA not in Protected Users" is harder to read than "15 of 9 highest-privileged accounts." Implementer should confirm DA + EA count is the right denominator and use `$daCount + $eaCount` as a proxy for total tier-0 privileged accounts.

**Tests:**
- Gap count and total both present → description includes "of N"
- `Get-PrivilegedGroupMembership` absent → description falls back to count-only form without error

### Pass 7D — Kerberoastable: always show privileged count

**Current (non-critical path):** `"50 accounts with SPNs (Kerberoasting risk)"`
**Spec:** `"50 accounts with SPNs — 0 privileged"`

Even when `PrivilegedCount -eq 0`, show it. The zero is signal — it tells the reviewer the dangerous subset was checked.

**Change location:** The `'Find-KerberoastableAccount'` advisory case (the `$r.TotalCount -gt 0 -and $r.PrivilegedCount -eq 0` branch).

**Tests:**
- `TotalCount = 50`, `PrivilegedCount = 0` → advisory text contains "0 privileged"
- `TotalCount = 50`, `PrivilegedCount = 3` → Critical card (existing behavior, regression guard)
- `TotalCount = 0` → no card

### Validation before handoff (Step 7)
- All six advisory improvement tests pass
- All prior tests pass (full suite)
- No advisory description contains raw `$null` or empty interpolated values

---

## Step 8 — AS-REP Severity Promotion

**Model: Sonnet**

### Context to load
- `dev-guide.md`
- `New-MonarchReport` function (full text, post-Step-7 version)
- This plan file (return contracts section + this step)

### Pass 8A — Compute PrivilegedCount and split severity

**Current:** Flat advisory for all AS-REP accounts regardless of privilege level.

**Spec:**
```powershell
'Find-ASREPRoastableAccount' {
    $privCount = @($r.Accounts | Where-Object { $_.IsPrivileged }).Count
    $total = $r.Count
    if ($privCount -gt 0) {
        $criticals.Add([PSCustomObject]@{ ... Description = "$total accounts with pre-auth disabled — $privCount privileged" })
    } elseif ($total -gt 0) {
        $advisories.Add([PSCustomObject]@{ ... Description = "$total accounts with pre-auth disabled — 0 privileged" })
    }
}
```

Parallel pattern to `Find-KerberoastableAccount`. Critical when privileged accounts are exposed.

**Tests to write:**
- `Accounts` contains 2 with `IsPrivileged = $true`, 186 with `$false` → Critical card, description contains "2 privileged"
- `Accounts` contains 188 all with `IsPrivileged = $false` → Advisory card, description contains "0 privileged"
- `Accounts` is empty → no card
- Critical card appears in the critical-section HTML block, not advisory block

### Validation before handoff
- All new and prior tests pass
- Critical count in stats bar increments correctly when privileged AS-REP accounts present

---

## Step 9 — Integration Validation

**Model: Sonnet**

### Context to load
- `dev-guide.md`
- `New-MonarchReport` function (full text, post-Step-8 version)
- This plan file (full)
- `report-v7.html` (reference for known live-domain output)
- `report-v5.html` (reference for intended design)

### Pass 9A — Full suite run + output review

1. Run full Pester suite. All tests must pass.
2. Build a comprehensive mock `$Results` object covering all eight domains with realistic data (based on v5 reference values where possible).
3. Call `New-MonarchReport` with this mock and render the output.
4. Verify against checklist:

**Header:**
- [ ] DC name renders as plain string (no `@{`)
- [ ] Date and duration render correctly

**Stats bar:**
- [ ] Critical count matches actual critical cards
- [ ] Advisory count matches actual advisory cards
- [ ] Checks ratio is correct

**Per-domain metrics strips (all five new cases):**
- [ ] PrivilegedAccess: DA count, EA count, Kerberoastable (priv), AdminCount orphans
- [ ] InfrastructureHealth: DC count (or omitted if indeterminate), site count, functional level, FSMO status
- [ ] IdentityLifecycle: dormant count, never logged on, threshold, excluded
- [ ] GroupPolicy: total GPOs, unlinked, user rights, scripts
- [ ] SecurityPosture: password never expires, protected users gaps, legacy exposure DCs
- [ ] BackupReadiness: tombstone lifetime, recycle bin, detection tier (regression)

**Advisory descriptions:**
- [ ] FSMO single-DC advisory names the DC
- [ ] Dormant account advisory includes threshold and excluded count
- [ ] Event log advisory counts DCs not issues
- [ ] Protected Users advisory includes denominator
- [ ] Kerberoastable advisory always shows privileged count
- [ ] AS-REP advisory shows privileged count; promotes to Critical when > 0

**Clean domains:**
- [ ] Domains with no findings still appear in "No findings:" line

**File tree:**
- [ ] Renders correctly (regression guard — was working in v7)

### Pass 9B — Regression diff against v7

Compare mock output against v7 HTML structure. Document any intentional differences.
Flag anything that changed unintentionally.

### Validation — done when
- Full Pester suite passes
- Checklist above is fully checked
- No unintentional regressions from v7

---

## What This Plan Does Not Cover

- Phase 2: Report redesign (layout, visual hierarchy changes) — separate plan
- Phase 3: Report reimplementation — follows Phase 2 design
- Function-level return contract changes (all fixes are in the report generator only)
- `Find-UnlinkedGPO` deduplication with `Export-GPOAudit` (both surface unlinked count — currently the advisory fires from `Export-GPOAudit.UnlinkedCount`; `Find-UnlinkedGPO` case is not in the advisory switch and this is correct)

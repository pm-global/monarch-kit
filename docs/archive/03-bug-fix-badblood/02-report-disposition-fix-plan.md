# TODO-3: Function Disposition in Report

## Context

The report currently cannot distinguish "checked and clean" from "never checked." When a function fails (e.g., GroupPolicy module not loaded), its domain may appear in the "No findings" line -- implying it was assessed and clean when it was never assessed at all. This erodes trust in the report.

The fix: every function gets a disposition (findings, clean, or not assessed). The report renders this accurately. Domains where all functions succeeded show "No findings." Domains where any function failed show per-function "Not assessed" cards with the function name and reason.

**Decision references:** bb-fix-plan.md Decision 1 (option c -- surface non-clear states only), Decision 2 (throw on total module absence), Decision 4 (silence boundary).

---

## Pass 1: Disposition Tracking in Orchestrator - COMPLETE

**File:** `Monarch.psm1` -- `Invoke-DomainAudit` (lines 2764-2859)

### Changes

**1a. Add canonical function-to-domain mapping to the `$calls` array.**

Each entry in `$calls` already has `Name` and `Params`. Add a `Domain` key to each entry so the orchestrator knows which domain a function belongs to *before* it runs. This is needed to identify "not assessed" functions whose return object never materializes.

The mapping (derived from each function's hardcoded `Domain` property in its return object):

```
New-DomainBaseline          -> AuditCompliance
Get-FSMORolePlacement       -> InfrastructureHealth
Get-ReplicationHealth       -> InfrastructureHealth
Get-SiteTopology            -> InfrastructureHealth
Get-ForestDomainLevel       -> InfrastructureHealth
Export-GPOAudit             -> GroupPolicy
Find-UnlinkedGPO            -> GroupPolicy
Find-GPOPermissionAnomaly   -> GroupPolicy
Get-PrivilegedGroupMembership -> PrivilegedAccess
Find-AdminCountOrphan       -> PrivilegedAccess
Find-KerberoastableAccount  -> PrivilegedAccess
Find-ASREPRoastableAccount  -> PrivilegedAccess
Find-DormantAccount         -> IdentityLifecycle
Get-PasswordPolicyInventory -> SecurityPosture
Find-WeakAccountFlag        -> SecurityPosture
Test-ProtectedUsersGap      -> SecurityPosture
Find-LegacyProtocolExposure -> SecurityPosture
Get-BackupReadinessStatus   -> BackupReadiness
Test-TombstoneGap           -> BackupReadiness
Get-AuditPolicyConfiguration -> AuditCompliance
Get-EventLogConfiguration   -> AuditCompliance
Test-SRVRecordCompleteness  -> DNS
Get-DNSScavengingConfiguration -> DNS
Test-ZoneReplicationScope   -> DNS
Get-DNSForwarderConfiguration -> DNS
```

**1b. Build disposition list alongside results/failures.**

Replace the current two-list pattern (`$results` + `$failures`) with a unified execution loop that tracks disposition per function. The `$results` and `$failures` lists remain for backward compatibility, but a new `$dispositions` list captures the full picture.

After each function call, record:

```powershell
[PSCustomObject]@{
    Function    = $call.Name
    Domain      = $call.Domain
    Disposition = 'Findings' | 'Clean' | 'NotAssessed'
    Error       = $null | 'error message'
}
```

Disposition logic:
- Function threw -> `NotAssessed`, Error = exception message (also added to `$failures` for backward compat)
- Function returned result -> check if the switch-case logic in the report would produce any findings. **No -- that's too coupled.** Instead, use a simpler heuristic: the result is added to `$results`, disposition is `Clean` by default. The report's findings extraction later determines whether it's actually `Findings` or `Clean`. The orchestrator just tracks ran-vs-failed.

**Simplification:** The orchestrator only needs two dispositions: `Assessed` and `NotAssessed`. Whether "assessed" means "findings" or "clean" is the report's job (it already has the switch-case logic). The orchestrator's role is: did the function run successfully or not?

Revised disposition:

```powershell
[PSCustomObject]@{
    Function    = $call.Name
    Domain      = $call.Domain
    Disposition = 'Assessed' | 'NotAssessed'
    Error       = $null | 'error message'
}
```

**1c. Add Dispositions and TotalChecks to orchestrator return object.**

```powershell
[PSCustomObject]@{
    Phase        = 'Discovery'
    Domain       = $target.Domain
    DCUsed       = $dc
    DCSource     = $target.Source
    StartTime    = $startTime
    EndTime      = Get-Date
    OutputPath   = $OutputPath
    ReportPath   = $null
    Results      = @($results)
    Failures     = @($failures)     # kept for backward compat
    Dispositions = @($dispositions) # NEW
    TotalChecks  = $calls.Count     # NEW -- denominator for stats
}
```

### Tests (Pass 1)

Add to `Tests/Monarch.Tests.ps1` under the `Invoke-DomainAudit` Describe block:

1. **All functions succeed:** Dispositions has 25 entries, all `Assessed`, no errors
2. **One function throws:** Dispositions has 25 entries, 24 `Assessed`, 1 `NotAssessed` with Error populated. Same function appears in `Failures` list.
3. **Dispositions have correct Domain values:** Verify the Domain property on each disposition matches the expected mapping
4. **TotalChecks equals call count:** `TotalChecks -eq 25`

---

## Pass 2: Report Consumes Dispositions - COMPLETE

**File:** `Monarch.psm1` -- `New-MonarchReport` (lines 2412-2756)

### Changes

**2a. Extract disposition data at the top of the function.**

After the existing header data extraction (lines 2445-2457), add:

```powershell
$dispositions = @($Results.Dispositions)
$totalChecks = if ($Results.TotalChecks) { $Results.TotalChecks } else { $functionCount + $errorCount }
$assessedCount = @($dispositions | Where-Object { $_.Disposition -eq 'Assessed' }).Count
$notAssessedCount = $totalChecks - $assessedCount
```

The fallback (`$functionCount + $errorCount`) handles cases where the report receives data from an older orchestrator version without Dispositions.

Also build per-domain check counts for section headers:

```powershell
$domainCheckCounts = @{}   # domain -> @{ Assessed = N; Total = M }
foreach ($d in $dispositions) {
    if (-not $domainCheckCounts.ContainsKey($d.Domain)) { $domainCheckCounts[$d.Domain] = @{ Assessed = 0; Total = 0 } }
    $domainCheckCounts[$d.Domain].Total++
    if ($d.Disposition -eq 'Assessed') { $domainCheckCounts[$d.Domain].Assessed++ }
}
```

**2b. Update stats bar.**

Replace the current 4-stat layout:

```
Critical: N | Advisory: N | Functions: N | Errors: N
```

With 3 stats:

```
Critical: N | Advisory: N | Checks: assessed/total
```

The Checks stat uses outline style. If `assessedCount < totalChecks`, use regular outline (visible). If all assessed, use outline with full fraction. The fraction format (e.g., "22/25") goes in the stat-number div.

Remove the separate Errors stat pill -- the denominator gap communicates this, and the "Not assessed" cards explain the details.

**2c. Fix the "clean domains" logic.**

Current bug: `$allDomains` is derived only from `$resultsList` (successful returns). Domains with zero successful functions don't appear.

Fix: Build `$allDomains` from the canonical domain order list (`$domainOrder`) which already contains all 8 domains. Then classify each:

```powershell
# Domains with findings (already computed from criticals + advisories)
# $findingDomains hashtable exists

# Domains that are not assessed (any function in the domain has NotAssessed disposition)
$notAssessedDomains = @{}
foreach ($d in $dispositions | Where-Object { $_.Disposition -eq 'NotAssessed' }) {
    if (-not $notAssessedDomains.ContainsKey($d.Domain)) {
        $notAssessedDomains[$d.Domain] = [System.Collections.Generic.List[PSCustomObject]]::new()
    }
    $notAssessedDomains[$d.Domain].Add($d)
}

# Clean domains: in domainOrder, had at least one assessed function, no findings, no not-assessed functions
$assessedDomains = @($dispositions | Where-Object { $_.Disposition -eq 'Assessed' } |
    ForEach-Object { $_.Domain } | Sort-Object -Unique)
$cleanDomains = @($assessedDomains | Where-Object {
    -not $findingDomains.ContainsKey($_) -and -not $notAssessedDomains.ContainsKey($_)
})
```

**2d. Render "Not assessed" cards within domain sections.**

After the existing domain sections loop (findings domains), add rendering for not-assessed domains. Two scenarios:

**Domain section headers now include a check count** showing assessed/total for that domain. This gives at-a-glance coverage per domain without requiring the reader to count cards.

```html
<div class='domain-section'>
  <h2>Group Policy <span class='check-count'>1/3 checks</span></h2>
  ...
</div>
```

The `check-count` span uses `--t5` size, `--text-3` color, normal weight -- subordinate to the domain name. When all checks pass (`3/3`), it still renders (confirms completeness). CSS:

```css
.check-count { font-size: var(--t5); font-weight: 400; color: var(--text-3); margin-left: 8px; }
```

**Console translation:** `Group Policy (1/3 checks)` in DarkGray after the domain name.

**Rendering scenarios:**

**Scenario A -- Domain has ONLY not-assessed functions (all failed):**
Render a domain section header with `0/N checks` + one "Not assessed" card per failed function.

**Scenario B -- Domain has a MIX of findings/clean AND not-assessed:**
The domain already has a section from findings. Header shows partial fraction (e.g., `1/3 checks`). Append "Not assessed" cards at the bottom of that section.

For domains with no findings but some not-assessed functions: render a domain section with the check count and just the "Not assessed" cards (no findings cards).

Card HTML for not-assessed:

```html
<div class='card w-neutral not-assessed'>
  <div class='adv-label'>Not Assessed</div>
  <div class='fn-name'>Get-DNSForwarderConfiguration</div>
  <div class='fn-error'>DnsServer module not loaded</div>
</div>
```

Uses existing neutral card weight (3px gray border). The `fn-name` and `fn-error` classes already exist from the Function Errors section styling.

**2e. Update the clean domains line.**

Use the fixed `$cleanDomains` from 2c. Only domains where ALL functions were assessed and NONE produced findings appear here.

**2f. Remove the standalone "Function Errors" section.**

The current "Function Errors" section at the bottom (lines 2713-2720) is replaced by the per-domain "Not assessed" cards. The information now lives contextually within the domain it belongs to, which is more useful diagnostically. Remove the bottom section entirely.

**2g. Add CSS for not-assessed cards and check counts.**

The `.not-assessed` class inherits from `.card.w-neutral`. Add minimal styling. Keep `.fn-name` / `.fn-error` generic on `.card` since they're shared:

```css
.card .fn-name { font-weight: 600; font-size: var(--t5); color: var(--text-1); margin-bottom: var(--gap-micro); }
.card .fn-error { font-size: var(--t5); color: var(--text-2); }
.check-count { font-size: var(--t5); font-weight: 400; color: var(--text-3); margin-left: 8px; }
```

Print: `.check-count` prints as-is (already light gray, converts to gray in print).

**2h. Handle backward compatibility (no Dispositions property).**

If `$Results.Dispositions` is null/empty (old orchestrator data), fall back to current behavior: derive disposition from Results + Failures. Build synthetic dispositions:

```powershell
if ($dispositions.Count -eq 0) {
    # Backward compat: synthesize from Results + Failures
    $dispositions = @()
    foreach ($r in $resultsList) {
        $dispositions += [PSCustomObject]@{ Function = $r.Function; Domain = $r.Domain; Disposition = 'Assessed'; Error = $null }
    }
    foreach ($f in $failures) {
        # Domain unknown from old failure format -- skip domain-level placement
        $dispositions += [PSCustomObject]@{ Function = $f.Function; Domain = $null; Disposition = 'NotAssessed'; Error = $f.Error }
    }
}
```

Failures without domain info fall through to a generic "Not assessed" list at the bottom (preserving old behavior). Only new orchestrator output gets full domain-contextual placement.

### Rendering order (updated report structure)

1. Title, metadata, stats (Checks: N/N)
2. Critical findings section (unchanged)
3. Domain sections -- domains with findings OR not-assessed functions, ordered by `$domainOrder`
   - Domain header with check count (e.g., "Group Policy 1/3 checks")
   - Domain metrics (unchanged, only for domains with result data)
   - Advisory cards (existing)
   - Not-assessed cards (new -- per failed function)
4. Clean domains line ("No findings: ...")
5. Output file tree (unchanged)
6. Footer (unchanged)

### Tests (Pass 2)

Add to `Tests/Monarch.Tests.ps1` under the `New-MonarchReport` Describe block:

1. **All functions assessed, no findings:** Report contains "No findings" with all 8 domain names. No "Not Assessed" cards. Checks stat shows "25/25".
2. **All functions assessed, some findings:** Report contains domain sections with findings. Clean domains in "No findings" line. Checks stat shows "25/25".
3. **Some functions not assessed:** Report contains "Not Assessed" cards in the correct domain section. Those domains do NOT appear in "No findings" line. Checks stat shows correct fraction (e.g., "22/25").
4. **Entire domain not assessed (all 3 GPO functions fail):** Group Policy section renders with "0/3 checks" in header and only "Not assessed" cards. Domain does not appear in "No findings" line.
5. **Mixed domain (1 GPO function fails, 2 succeed):** Group Policy section header shows "2/3 checks", has findings/advisory cards AND a "Not assessed" card for the failed function.
6. **Backward compat (no Dispositions property):** Report renders without errors, falls back to current behavior.
7. **Stats bar:** Verify HTML contains `Checks` stat with correct assessed/total fraction.
8. **Domain section check counts:** Verify each domain section header includes the correct `N/M checks` count.

---

## Pass 3: Integration Smoke Test COMPLETE

**No code changes.** Verify the full pipeline works:

1. Run `Invoke-DomainAudit -Phase Discovery` against a test environment (or BadBlood domain if available)
2. Verify the orchestrator return object has `Dispositions` and `TotalChecks` properties
3. Open the generated HTML report and verify:
   - Stats bar shows `Checks: N/N`
   - Domains with findings render correctly (unchanged from before)
   - Clean domains listed in "No findings" line
   - Any failed functions show "Not assessed" cards in the correct domain section
   - No standalone "Function Errors" section at the bottom
4. Run full Pester suite: `Invoke-Pester Tests/Monarch.Tests.ps1`

---

## Files Modified

| File | Pass | What Changes |
|------|------|-------------|
| `Monarch.psm1` | 1 | `Invoke-DomainAudit`: add Domain to $calls entries, disposition tracking loop, new return properties |
| `Monarch.psm1` | 2 | `New-MonarchReport`: stats bar, disposition consumption, not-assessed cards, clean domains fix, remove Function Errors section, CSS |
| `Tests/Monarch.Tests.ps1` | 1 | Orchestrator disposition tests |
| `Tests/Monarch.Tests.ps1` | 2 | Report disposition rendering tests |

## Key Reuse

- **Existing `$domainOrder` and `$domainNames`** (report lines 2460-2472) -- already define all 8 domains with display names and priority order. Reuse for the full domain roster.
- **Existing `.card.w-neutral` CSS** -- reuse for "Not assessed" cards.
- **Existing `.fn-name` and `.fn-error` CSS** -- reuse from current failure-item styling.
- **Existing per-function try/catch loop** (orchestrator lines 2835-2842) -- extend, don't replace.

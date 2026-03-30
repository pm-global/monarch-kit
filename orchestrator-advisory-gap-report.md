# Orchestrator Advisory Gap — Bug Report

**Project:** monarch-kit v0.2.0-beta
**Scope:** `Invoke-DomainAudit` → `New-MonarchReport` findings extraction (lines 2473–2516 of `Monarch.psm1`)
**Classification:** Critical — incorrect results, interface violation

---

## Summary

The orchestrator's findings extraction switch statement maps 12 of 25 called functions to report advisories. The remaining 10 analysis functions (excluding 3 that are purely informational) execute successfully, return populated results, and are silently discarded by the report. The Discovery report presents "No findings" for domains that have findings.

This was confirmed against a BadBlood-populated lab domain: `Find-KerberoastableAccount` returned `TotalCount = 50` but generated no advisory. The report showed 5 advisories; the actual count based on the data collected is substantially higher.

---

## Root Cause

The report rendering pipeline has two stages:

1. **Findings extraction** (lines 2473–2516): A `switch ($r.Function)` block iterates over all collected results and populates `$criticals` and `$advisories` lists.
2. **HTML rendering** (lines 2601–2639): Only domains with entries in `$criticals` or `$advisories` get sections in the report. Domains with no entries appear in the "No findings" line.

If a function has no case in the switch, its results never enter either list, and its domain may show as clean. The switch was written with 12 cases when 22 were needed (excluding 3 informational functions that correctly have no advisory logic).

### Why this happened

The dev plan (CLAUDE-DEV-PLAN-v1.md) built the module in 14 sequential steps. The API functions were implemented in Steps 4–12. Reporting was Step 13. The orchestrator was Step 14. The switch statement needed to reference return properties from all 25 functions, but was written with cases for roughly half of them. The most likely explanation: the advisory mapping was started but not completed before the step was marked done.

The dev plan's Step 13 spec describes the report as rendering "Advisory items listed (unlinked GPOs, AdminCount orphans, weak flags)" — listing specific examples rather than requiring exhaustive coverage. The Step 14 tests verify that the orchestrator calls all functions and that failures are isolated, but do not verify that every function's findings reach the report. The test gap mirrors the code gap.

---

## Findings

### Critical — Functions with analysis results that never surface

Each entry below lists the function, what it returns, the property that should trigger an advisory, and what BadBlood is likely to populate.

**1. `Find-KerberoastableAccount`** (line 2504)
Case exists but is wrong. Checks `$r.PrivilegedCount -gt 0` only. Ignores `$r.TotalCount`. Any account with an SPN is Kerberoastable regardless of group membership — an attacker requests a service ticket and cracks the password offline. Your lab returned `TotalCount = 50, PrivilegedCount = 0`. The spec (dev plan line 551) explicitly states: "Return ALL accounts with SPNs, not just privileged ones. `IsPrivileged` flag lets consumers filter." The orchestrator violates this by filtering at the advisory level.

Advisory trigger should be: `TotalCount -gt 0` (with `PrivilegedCount` escalating severity).

**2. `Find-ASREPRoastableAccount`** (no case in switch)
Returns `Count` and `Accounts`. No advisory logic at all. AS-REP roasting lets an attacker request an encrypted ticket for any account with pre-auth disabled and crack it offline. Same risk class as Kerberoasting. BadBlood creates accounts with `DoesNotRequirePreAuth = $true`.

Advisory trigger: `$r.Count -gt 0`.

**3. `Find-WeakAccountFlag`** (no case in switch)
Returns `Findings` array and `CountByFlag` hashtable. Flags include `PasswordNeverExpires`, `ReversibleEncryption`, `DESOnly`. These are concrete security weaknesses — reversible encryption stores passwords in a recoverable format, DES-only uses a broken cipher. BadBlood creates accounts with these flags.

Advisory trigger: `$r.Findings.Count -gt 0` (with `ReversibleEncryption` and `DESOnly` arguably critical, not advisory).

**4. `Find-LegacyProtocolExposure`** (no case in switch)
Returns `DCFindings` array with per-DC findings for NTLMv1, LM hash storage, LDAP signing. These are high and medium risk findings per the function's own `Risk` property. A lab DC with default settings will likely have `LDAPSigningDisabled` at minimum.

Advisory trigger: `$r.DCFindings.Count -gt 0` (with `Risk = 'High'` findings escalated to critical).

**5. `Find-UnlinkedGPO`** (no case in switch)
Returns `UnlinkedGPOs` array and `Count`. Note: `Export-GPOAudit` has its own `UnlinkedCount` property and a switch case on line 2514. These are separate functions with separate return objects. `Find-UnlinkedGPO` is called independently (line 2740) and its results are not consumed. If `Export-GPOAudit` and `Find-UnlinkedGPO` disagree on count (possible if error handling differs), the report shows whichever `Export-GPOAudit` reports.

Advisory trigger: `$r.Count -gt 0`. May be redundant with `Export-GPOAudit` — verify whether both are needed.

**6. `Find-GPOPermissionAnomaly`** (no case in switch)
Returns `Anomalies` array and `Count`. Detects non-standard editors on GPOs (anyone outside `PermittedGPOEditors` config). BadBlood creates GPOs with delegated permissions.

Advisory trigger: `$r.Count -gt 0`.

**7. `Get-PasswordPolicyInventory`** (no case in switch)
Returns `DefaultPolicy` with `MinLength`, `ComplexityEnabled`, `ReversibleEncryption`, `LockoutThreshold` and `FineGrainedPolicies` array. A default domain policy with `MinLength < 14` or `ComplexityEnabled = $false` or `LockoutThreshold = 0` is a common audit finding. The function collects the data but no advisory evaluates it.

Advisory trigger: Could check `DefaultPolicy.MinLength -lt 14`, `DefaultPolicy.ComplexityEnabled -eq $false`, `DefaultPolicy.LockoutThreshold -eq 0`, or `DefaultPolicy.ReversibleEncryption -eq $true`. Thresholds should be configurable.

**8. `Get-DNSScavengingConfiguration`** (no case in switch)
Returns `Zones` array with `ScavengingEnabled` per zone. Disabled scavenging causes stale DNS records to accumulate indefinitely — a common AD hygiene issue.

Advisory trigger: Zones where `ScavengingEnabled -eq $false`.

**9. `Get-EventLogConfiguration`** (no case in switch)
Returns per-DC event log settings (Security, System, Directory Service) with `MaxSizeKB` and `OverflowAction`. Undersized Security logs or `OverwriteAsNeeded` on DCs are audit findings.

Advisory trigger: Possible check for `MaxSizeKB` below a threshold or `OverflowAction` that discards events. Lower priority than the security findings above.

**10. `Test-ZoneReplicationScope`** (no case in switch)
Returns `Zones` with `ReplicationScope` and `IsDsIntegrated`. Non-integrated zones or legacy replication scope are noteworthy but lower priority.

Advisory trigger: Zones with `IsDsIntegrated -eq $false` or legacy replication scope.

### Not bugs — informational functions correctly excluded

These three functions are data snapshots with no finding/threshold logic. No advisory is expected:

- `New-DomainBaseline` — writes CSVs, provides reference data
- `Get-FSMORolePlacement` — informational (though `UnreachableCount -gt 0` could warrant an advisory)
- `Get-ForestDomainLevel` — informational

Note: `Get-FSMORolePlacement` returns `UnreachableCount` and `AllOnOneDC`. An unreachable FSMO holder is arguably worth surfacing. This is a judgment call, not a bug.

### Also not mapped: `Test-TombstoneGap`

Returns `CriticalGap` (same concept as `Get-BackupReadinessStatus`). Since `Get-BackupReadinessStatus` already has a `CriticalGap` check in the switch, `Test-TombstoneGap`'s result may be intentionally redundant. But if they're called with different inputs or if `BackupReadinessStatus` can't determine backup age (tier 1 only), `Test-TombstoneGap` with an explicit `-BackupAgeDays` would be the only source of that finding. Currently its result is discarded.

---

## Report-Level Rendering Gap

Beyond the switch statement, the domain-specific metrics section (lines 2616–2622) only has a case for `BackupReadiness`. When a domain does get advisories (e.g., `PrivilegedAccess`), the report shows the advisory cards but no contextual metrics — no total Kerberoastable count, no member counts, no password policy summary. This is a secondary issue; the primary problem is that most findings don't reach the report at all.

---

## Impact on Your Lab Report

Your report showed:

| Report section | What it showed | What was likely present |
|---|---|---|
| Privileged Access | DA count, 1 AdminCount orphan | Also: 50 Kerberoastable accounts, AS-REP roastable accounts |
| Security Posture | 15 not in Protected Users | Also: weak account flags (PasswordNeverExpires, ReversibleEncryption, DESOnly), legacy protocol exposure on DC |
| Group Policy | "No findings" | Likely: unlinked GPOs, permission anomalies (BadBlood creates both) |
| Identity Lifecycle | "No findings" | Possibly dormant accounts (depends on BadBlood lastLogon dates — this function IS mapped, so if it shows nothing, it's correct) |
| Audit & Compliance | "No findings" | Possibly: event log sizing issues, audit policy gaps (function ran, results discarded) |
| DNS | Missing SRV records | Also: scavenging configuration not evaluated |

---

## Test Gap

The existing Pester tests for `Invoke-DomainAudit` (dev plan Step 14) verify:

- All Discovery functions are called
- A function that throws appears in Failures
- Output directories are created
- Return object has correct shape

They do not verify: **results with finding-worthy data produce advisories in the report**. A test that passes mock results with `Find-KerberoastableAccount.TotalCount = 50` through the orchestrator and asserts an advisory card appears in the HTML would have caught this at development time.

---

## Fix Priority

Per the dev-guide impact/effort matrix:

| Fix | Impact | Effort | Priority |
|---|---|---|---|
| Add missing switch cases for items 1–6 | High | Low | Do Now |
| Add switch cases for items 7–10 | Medium | Low | Do Now |
| Fix Kerberoastable PrivilegedCount-only check | High | Low | Do Now |
| Add orchestrator→report integration tests | High | Medium | Do Now |
| Add domain-specific metrics rendering | Low | Medium | Consider |

Items 1–6 are security-relevant findings that the tool was designed to surface. The functions are written, tested, and returning data. The only missing piece is 1–3 lines per function in the switch block.

---

## Suggested Verification

After fixing the switch statement, re-run against the BadBlood lab and confirm:

```powershell
$result = Invoke-DomainAudit -Phase Discovery -OutputPath C:\MonarchOutput

# Check every analysis function produced an advisory (or has genuinely empty results)
$result.Results | ForEach-Object {
    [PSCustomObject]@{
        Function = $_.Function
        HasData  = ($_.PSObject.Properties | Where-Object {
            $_.Name -in 'Count','TotalCount','Findings','Accounts','Anomalies','DCFindings','UnlinkedGPOs'
        } | Where-Object { $_.Value -and @($_.Value).Count -gt 0 }).Count -gt 0
    }
} | Format-Table -AutoSize
```

Any function where `HasData = $true` must have a corresponding advisory in the report.

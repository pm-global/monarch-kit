# Step 13 Subplan: Reporting (Revised)

One function: `New-MonarchReport`. Presentation layer — reads structured results from the orchestrator, generates a single-page HTML Discovery report. Never calls API functions.

**Current state:** 26 working API functions, 149 tests passing. This step adds 1 function.

**Design reference:** `docs/design-system.md` for spacing, type scale, color, component grammar. `report-v5.html` is the canonical visual reference — the HTML template should match this implementation.

**V0 reference:** `.v0/Export-GPOAudit.ps1` for string concatenation HTML pattern (not here-strings). Current `Export-GPOAudit` in Monarch.psm1 uses the same pattern.

**Config integration:** Read `ReportAccentPrimary` from config via `Get-MonarchConfigValue`. Inject into CSS `:root` block. Default: `#2E5090`. Critical red is hardcoded — never configurable.

---

## Report Information Hierarchy

The report is read top-to-bottom by three audiences with different needs. The structure serves all three without requiring any of them to scroll past content they don't care about.

**First screen (executive — IT Director, change advisory board):**
- Header: domain, DC used, audit date, duration
- Executive summary block: total critical findings count, total advisory count, overall status (Critical / Advisory / Clean)
- Critical findings table (if any): one row per finding, domain, description, action needed

**Middle (operational — domain admin doing the work):**
- Per-domain sections, but only for domains WITH findings. Each section shows key counts and status.
- Domains with nothing to report are collapsed into a single "Clean Domains" line at the end of this block, not rendered as empty sections.

**Bottom (reference):**
- Function errors section (if any failures occurred)
- Links to detailed output files (CSVs, GPO HTML index, baseline data)
- Audit metadata (function count, execution time, DC source)

---

## Critical Findings: Complete List

The subplan must extract ALL of these. These are the findings that justify immediate action or block progression to the Remediation phase.

| Source Function | Condition | Severity | Display Text |
|----------------|-----------|----------|-------------|
| Get-BackupReadinessStatus | `CriticalGap -eq $true` | Critical | Backup age exceeds tombstone lifetime — USN rollback risk |
| Get-BackupReadinessStatus | `DetectionTier -eq 1` and `BackupToolDetected -eq $null` | Advisory | No backup tool detected — verify backup coverage manually |
| Get-ReplicationHealth | `FailedLinkCount -gt 0` | Critical | N replication links failing |
| Get-ReplicationHealth | `WarningLinkCount -gt 0` | Advisory | N replication links approaching threshold |
| Get-PrivilegedGroupMembership | `DomainAdminStatus -eq 'Critical'` | Critical | Domain Admin count exceeds critical threshold (N members) |
| Get-PrivilegedGroupMembership | `DomainAdminStatus -eq 'Warning'` | Advisory | Domain Admin count exceeds warning threshold (N members) |
| Find-DormantAccount | `TotalCount -gt 0` | Advisory | N dormant accounts identified for review |
| Get-SiteTopology | `UnassignedSubnets.Count -gt 0` | Advisory | N subnets not assigned to any site |
| Get-SiteTopology | `EmptySites.Count -gt 0` | Advisory | N sites with no domain controllers |
| Test-SRVRecordCompleteness | `AllComplete -eq $false` | Advisory | Missing SRV records in N sites |
| Get-AuditPolicyConfiguration | `Consistent -eq $false` | Advisory | Audit policy inconsistent across domain controllers |
| Get-DNSForwarderConfiguration | `Consistent -eq $false` | Advisory | DNS forwarder configuration inconsistent across DCs |
| Find-KerberoastableAccount | `PrivilegedCount -gt 0` | Advisory | N privileged accounts with SPNs (Kerberoasting risk) |
| Test-ProtectedUsersGap | `GapAccounts.Count -gt 0` | Advisory | N privileged accounts not in Protected Users |
| Find-AdminCountOrphan | `Count -gt 0` | Advisory | N AdminCount orphans (stale privilege markers) |
| Export-GPOAudit | `UnlinkedCount -gt 0` | Advisory | N unlinked (orphaned) GPOs |

Critical findings go in the top-of-report critical table. Advisory findings go in the executive summary count and in their respective domain sections. This is the complete extraction list — the implementation should not add or remove items from this list without updating this plan.

---

## Domain Section Rendering Rules

**Domains WITH findings** get a full section: domain name header, key metrics, advisory items. Ordered by severity — domains with critical findings first, then advisory, then informational.

**Domains with NO findings** are not rendered as individual sections. They appear as a single line in a "Clean Domains" summary: "No findings: DNS, Audit & Compliance" (or whatever domains had clean results).

**Domain ordering when findings exist:**
1. Backup & Recovery (if critical gap or no tool detected)
2. Infrastructure Health (if replication failures or site issues)
3. Privileged Access (if DA count or Kerberoasting concerns)
4. Identity Lifecycle (if dormant accounts found)
5. Group Policy (if unlinked GPOs or permission anomalies)
6. Security Posture (if weak flags, Protected Users gaps, legacy protocols)
7. Audit & Compliance (if inconsistencies)
8. DNS (if SRV or forwarder issues)

This ordering reflects operational priority — safety-critical findings surface first.

---

## Failures Section

If the orchestrator's `Failures` array is non-empty, render a "Function Errors" section after the domain sections. One row per failure: function name, error message. This section only appears when failures exist.

A report where ALL functions failed (Results.Results is empty, Failures is full) should still render: the header, an executive summary showing "0 functions completed, N failures", the failures table, and nothing else. No empty domain sections.

---

## Pass 1: New-MonarchReport + Tests

### 13a. New-MonarchReport

- [x] **`New-MonarchReport` function** in `#region Reporting`

  Code-budget target: ~100–120 lines (justified — HTML generation with executive summary, critical findings extraction, per-domain conditional rendering, failures section, styling).

  | Parameter | Type | Description |
  |-----------|------|-------------|
  | `-Results` | PSCustomObject | Orchestrator's return object |
  | `-OutputPath` | string | Directory to write the report |
  | `-Format` | string | `'HTML'` (default) |

  Return: `[string]` — path to generated report file.

  Implementation outline:
  1. Null-check on `$Results` — if null, write a minimal report stating no data and return path
  2. Extract header data: Phase, Domain, DCUsed, StartTime, EndTime, duration
  3. Scan `$Results.Results` against the complete critical findings table above. Separate into Critical and Advisory lists.
  4. Render executive summary: critical count, advisory count, overall status
  5. Render critical findings table (if any criticals exist)
  6. Group `$Results.Results` by Domain property. Determine which domains have findings vs clean.
  7. Render per-domain sections for domains WITH findings, ordered by severity priority
  8. Render "Clean Domains" one-liner for domains with no findings
  9. Render failures section from `$Results.Failures` (if non-empty)
  10. Build output file tree dynamically from results: iterate `$Results.Results`, collect `OutputPaths`, `CSVPath`, and `OutputFiles` properties. Group by top-level directory. Only include paths that were actually generated — no hardcoded folder list, no filesystem scanning. Render as clean directory listing per design-system.md (no counts, no promoted links, no hints).
  11. Inject `ReportAccentPrimary` from config into CSS `:root` block. Fall back to `#2E5090`.
  12. Assemble HTML with string concatenation, write to `$OutputPath/00-Discovery-Report.html`

### 13b. Tests

- [x] **Tests: New-MonarchReport** (~8 tests)

  **Core behavior:**
  1. Produces HTML file at specified path from well-formed orchestrator data with mixed findings
  2. Executive summary block present with correct critical and advisory counts
  3. Critical finding (`CriticalGap=$true`) appears in critical findings table at top of report
  4. Advisory finding (dormant count > 0) appears in correct domain section, not in critical table
  5. Domain with no findings does NOT get its own section — appears in "Clean Domains" line

  **Edge cases:**
  6. Empty results (Results.Results is empty array, Failures is empty) — produces report with header and "No findings" summary, does not crash
  7. All functions failed (Results.Results empty, Failures has entries) — produces report with header, "0 completed" summary, and failures table only
  8. Failed function in Failures array appears in failures section with function name and error message

---

## Pass 2: Full Suite Verification

- [x] **Run all tests (Steps 1–13)** — verify no regressions
  - Steps 1–12 tests still pass (149 existing)
  - All Step 13 tests pass (8 new)
  - Total: 157 tests, 0 failures
- [x] **Check diagnostics** — no warnings or errors in `.psm1`
- [x] **Verify `FunctionsToExport`** — `New-MonarchReport` listed in `Monarch.psd1` (line 21)
- [x] **Verify function placement** — lives in `#region Reporting` (line 2404)

**Pass 2 exit criteria:** Full green suite. 27 working API functions total.

---

## New Cmdlets to Stub

None. `New-MonarchReport` only uses `Out-File` (built-in) and reads from the `$Results` parameter. No AD cmdlets, no remoting.

---

## Dev-Guide Compliance Notes

| Principle | How applied |
|-----------|-------------|
| Code budget | ~100–120 lines (justified — HTML with executive summary, conditional domain rendering, critical extraction, failures, styling). |
| Completion over expansion | Single implementation pass. HTML only (Text format deferred: "future: Text"). |
| Guards at boundaries | Null-check on Results at top. Per-domain try/catch for section rendering. |
| Test behavior not implementation | Tests check file existence, executive summary counts, critical section content, clean domain collapsing, edge cases. No assertions on specific HTML tags or CSS classes. |
| One function one job | Report generation only. Never calls API functions. |
| Max 2 nesting levels | `foreach domain { foreach result { } }` = 1–2 levels. |
| Silence is success | No console output. Returns file path. |
| No API calls in reporting | Reads Results parameter only — reporting can't drift from actual data. |
| Document why not what | Critical findings table is the complete extraction spec. Implementation comments explain extraction logic, not HTML structure. |

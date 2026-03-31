# Monarch-Kit Development Plan

Checklist-driven implementation plan. Each checkbox is a discrete deliverable. Check items off as they're completed. Every step includes its tests -- code and tests ship together, never separately.

**Last updated:** 2026-03-31

---

## Emergent TODOs

Items are ordered by priority. Blocking relationships noted where they exist.

**TODO-1: Detection pipeline repair -- diagnostic pass. COMPLETE.**
Ran each Discovery function against BadBlood domain. 5 bugs confirmed, all caused by accessing properties that don't exist on real cmdlet output (mocks hid the problem). Results: `bb-fix-plan.md`.

**TODO-2: Fix individual detection bugs.**
5 confirmed bugs. Individual plan files in repo root: `bb-fix-bug1.md` through `bb-fix-bug5.md`. Execute in fresh chats, archive when validated.
Blocked by: TODO-1 (complete -- bug list confirmed via BB diagnostic).

**TODO-3: Function disposition in report.**
Every function gets a final status: findings, clear, or not assessed. Report must distinguish "checked and clean" from "never checked." Covers degraded-state reporting (missing DNS/GPO modules) and replaces silent omission.
Blocked by: TODO-2 (fix bugs before adding disposition tracking).

**TODO-4: Honest file manifest with relative links.**
Build report file tree from verified disk paths, not function claims. Relative links that actually open files. Only list what exists.
Blocked by: TODO-2 (file output bugs must be fixed first).

**TODO-5: Integration validation against BadBlood.**
Full pipeline re-run. Verify GPO counts, advisory counts, domain coverage, manifest accuracy, working links. Compare to report-v5.html reference.
Blocked by: TODO-3, TODO-4.

**TODO-6: Advisory metrics and counting model.**
Each advisory card should show contextual numbers (total Kerberoastable count, member counts, password policy summary). The domain-specific metrics section only renders metrics for Backup & Recovery. Additionally, per-item severity should roll up correctly. Needs its own design pass before implementation.
Blocked by: TODO-2 (the switch cases must exist before metrics can reference them).

**TODO-7: Test coverage audit -- estimate current coverage against 80% target.**
SRE + testing specialist review. Includes integration tests added during BB fix work. Broader question: what other end-to-end paths lack integration tests?
Blocked by: TODO-5 (so BB fix tests are included in the estimate).

**TODO-8: Preflight validation function (`Test-MonarchEnvironment` or `Invoke-MonarchPreflight`).**
Validate PowerShell version, AD module availability, optional module presence, domain reachability, and execution context before discovery runs. Returns pass/fail object with blocking issues, warnings for degraded-but-runnable conditions, and the resolved domain + candidate DC.
Blocked by: nothing. Independent work.

**TODO-9: Progress output with silent mode.**
`Write-Progress` for long-running orchestrated runs, suppressible with `-Silent`. Default shows concise status; `-Verbose` shows per-step detail.
Blocked by: nothing, but TODO-8 (preflight) should land first since it establishes the pre-run output pattern.

**TODO-10: Retroactive research brief for monarch-kit.**
Formalize `initial-research.md` into a proper `research-brief-monarch-kit.md` per the research doc template. Reference work, not implementation.
Blocked by: nothing.

## Roadmap Overview

| Plan | Scope | Status |
|------|-------|--------|
| **Plan 1** | Discovery phase + orchestrator + tests + reporting | **Complete** |
| **Plan 2** | Remediation/Monitoring/Cleanup functions + tests | Not started |
| **Plan 3** | Start-MonarchAudit interactive wrapper + tests | Not started |
| **Plan 4** | Comparison functions (GPO, baseline, CIS) + tests | Not started |
| **Plan 5** | OctoDoc stratagem integration (after sensor redesign) | Blocked -- waiting on OctoDoc redesign |

Plans are sequential. Each plan depends on the one before it. Plan 5 is triggered externally (OctoDoc redesign), not by Plan 4 completion.

---

## Plan 1: Discovery Phase -- COMPLETE

28 functions, 162 Pester tests, all passing. Implemented in 14 steps.

**Full archive:** `docs/archive/01-discovery/CLAUDE-DEV-PLAN-v1.md`
**Step subplans:** `docs/archive/01-discovery/STEP-{4,5,5b,7-14}-SUBPLAN.md`

### What was built

| Steps | Scope | Functions |
|-------|-------|-----------|
| 1-3 | Module skeleton, config layer, DC resolution | `Import-MonarchConfig`, `Get-MonarchConfigValue`, `Resolve-MonarchDC` |
| 4 | Audit & Compliance baseline | `New-DomainBaseline` |
| 5 | Infrastructure Health | `Get-ForestDomainLevel`, `Get-FSMORolePlacement`, `Get-SiteTopology`, `Get-ReplicationHealth` |
| 6 | Security Posture | `Get-PasswordPolicyInventory`, `Find-WeakAccountFlag`, `Test-ProtectedUsersGap`, `Find-LegacyProtocolExposure` |
| 7 | Privileged Access | `Get-PrivilegedGroupMembership`, `Find-AdminCountOrphan`, `Find-KerberoastableAccount`, `Find-ASREPRoastableAccount` |
| 8 | Identity Lifecycle | `Find-DormantAccount` |
| 9 | Group Policy | `Export-GPOAudit`, `Find-UnlinkedGPO`, `Find-GPOPermissionAnomaly` |
| 10 | Backup & Recovery | `Get-BackupReadinessStatus`, `Test-TombstoneGap` |
| 11 | DNS | `Test-SRVRecordCompleteness`, `Get-DNSScavengingConfiguration`, `Test-ZoneReplicationScope`, `Get-DNSForwarderConfiguration` |
| 12 | Audit & Compliance (remaining) | `Get-AuditPolicyConfiguration`, `Get-EventLogConfiguration` |
| 13 | Reporting | `New-MonarchReport` |
| 14 | Orchestrator | `Invoke-DomainAudit` |

### Universal Patterns (apply to all plans)

**Domain parameter threading:**
- `Invoke-DomainAudit` accepts `-Domain [string]` (optional, defaults to current domain via `(Get-ADDomain).DNSRoot`)
- The orchestrator resolves domain -> healthy DC once at the top using `Get-HealthyDC`
- All API functions accept `-Server [string]` -- can be a DC name or domain FQDN, maps 1:1 to AD cmdlet `-Server` parameter
- The orchestrator always passes the resolved DC name as `-Server`
- Direct callers can pass whatever they want -- a DC name, a domain FQDN, or omit it for the local domain default

**Return contract pattern (all functions):**
Every public function returns one or more `[PSCustomObject]` with a `Domain` property naming which functional domain it belongs to (e.g., `'InfrastructureHealth'`, `'IdentityLifecycle'`). No formatted strings as primary output. No Write-Host in API functions. Functions that also produce file output (Export-GPOAudit, Find-DormantAccount) return the structured object AND write files -- the object includes paths to generated files.

**Error handling pattern:**
- Read-only functions use `$ErrorActionPreference = 'Continue'` -- gather as much as possible, surface errors in a `Warnings` array property on the return object
- Functions that query multiple independent things (baseline, GPO audit) catch per-section and continue
- If the entire function fails (can't reach AD at all), throw -- let the orchestrator catch it and record the failure

**Config access pattern:**
All functions read from `$script:Config` (module-scoped variable set at import time). Never from `$Global:` or by re-reading the config file. Config keys are accessed with a helper that falls back to built-in defaults: `Get-MonarchConfigValue -Key 'DormancyThresholdDays'`.

**Test strategy:**
- Pester 5+ tests in `Tests/Monarch.Tests.ps1`, organized by `Describe` blocks per function
- All AD/DNS/GPO cmdlets are mocked -- tests run without a domain
- Every function's tests verify: return object has correct properties, correct `Domain` and `Function` values, `Timestamp` is populated, `Warnings` is an array
- Functions with business logic get additional tests: exclusion logic, threshold comparisons, config overrides
- Tests are written alongside code at each step, not after

---

## Plan 2: Remediation, Monitoring, and Cleanup Functions

**Prerequisite:** Plan 1 complete.

**Scope:** Destructive operations with WhatIf support, rollback data, hold period enforcement.

**Functions:**

| Function | Phase | WhatIf | Key Concern |
|----------|-------|--------|-------------|
| `Suspend-DormantAccount` | Remediation | Yes | Archives rollback data to extensionAttribute14, strips groups, moves to quarantine, writes disable date to extensionAttribute15 |
| `Restore-DormantAccount` | Remediation | Yes | Reads extensionAttribute14, restores groups + OU, clears both attributes, re-enables |
| `Remove-DormantAccount` | Cleanup | Yes | Hold period enforcement via extensionAttribute15, pre-deletion archive, SID preservation |
| `Remove-AdminCountOrphan` | Remediation | Yes | Clears AdminCount flag from orphaned accounts |
| `Grant-TimeBoundGroupMembership` | Remediation | Yes | Adds with auto-expiration via AD TTL mechanism |
| `Backup-GPO` | Remediation | No (read) | Full XML backup for restore capability |
| `Get-DormantAccountMonitoringMetrics` | Monitoring | No (read) | Queries quarantine OU, counts, hold period status |

**Test focus:** WhatIf produces correct preview output. Rollback data serialization/deserialization round-trips correctly. Hold period calculation correct. Exclusion of accounts without monarch-kit disable dates. Integration tests for suspend -> restore cycle and suspend -> delete cycle using mocked AD.

**Implementation constraints (discovered 2026-03-26):**

- **Primary Group handling:** Every AD account must have a Primary Group (typically "Domain Users"). `Suspend-DormantAccount` cannot strip it -- must be excluded from group removal or handled specially.
- **extensionAttribute14 size limit:** AD extensionAttributes 1-15 have a `rangeUpper` of 1024 bytes. Users with many group memberships (20+ groups with long DNs) can exceed this. Need pre-write validation and a fallback strategy (truncate with warning? separate attribute? file-based archive?).
- **Entra ID Connect sync scope:** Many orgs use OU-based filtering for directory sync. Moving an account to `zQuarantine-Dormant` may move it out of sync scope, causing the cloud identity to soft-delete. Document as a warning in the wrapper's pre-phase guidance.
- **AdminSDHolder timing:** `adminCount` is set by SDProp on a 60-minute cycle but never cleared automatically. `Remove-AdminCountOrphan` should note that accounts removed from privileged groups <60 minutes ago may still have adminCount=1 legitimately. Consider a DiagnosticHint.
- **DC targeting for writes:** Discovery uses any healthy DC. Remediation writes (disable, move, strip groups) should target the PDC emulator or a specific writable DC to avoid replication conflicts.
- **Confirm support:** Add `$ConfirmPreference = 'High'` alongside `-WhatIf` for `Remove-DormantAccount` (permanent deletion). Standard PowerShell safety pattern via `ShouldProcess`.

---

## Plan 3: Interactive Wrapper

**Prerequisite:** Plans 1 and 2 complete.

**Scope:** `Start-MonarchAudit` -- the admin-facing entry point.

**Key deliverables:**
- Interactive menu (1-5 phase selection, Q to quit)
- Pre-phase guidance (what will happen, time estimates, pre-flight checks)
- Human confirmations before destructive operations
- Reviewed CSV path prompt during Remediation
- Checklist rendering during Review phase (from docs/checklists.md)
- Post-phase summary with output paths and next steps
- Monitoring metrics template and checkpoint guidance
- Post-deletion timing warnings
- `-Phase` parameter for non-interactive use

**V0 reference:** `Start-NetworkHandover.ps1` is essentially a template. Carry the UX patterns: `Show-Banner`, `Wait-ForContinue`, `Show-ChecklistItem`, `Invoke-SafeScript` (renamed to call orchestrator instead of scripts).

**The wrapper calls the orchestrator.** It never calls API functions directly.

**Test focus:** Parameter validation. Phase dispatch calls `Invoke-DomainAudit` with correct `-Phase`. Menu loop handles invalid input. Confirmation prompts block destructive operations.

---

## Plan 4: Comparison Functions

**Prerequisite:** Plan 1 complete (needs baseline data from prior Discovery runs).

**Scope:** Functions that compare two datasets or compare against an external standard.

**Functions:**

| Function | Domain | Requirement |
|----------|--------|-------------|
| `Compare-DomainBaseline` | Audit & Compliance | Two baseline snapshots (previous + current) |
| `Compare-GPO` | Group Policy | Two GPO snapshots or DC-to-DC comparison |
| `Compare-CISBaseline` | Security Posture | External baseline definition file |
| `Test-TieredAdminCompliance` | Privileged Access | Tier model definition in config |

**Test focus:** Delta detection (field added, removed, changed). Classification of changes (expected, advisory, requires-review). Handles missing previous baseline gracefully. CIS baseline comparison accepts generic baseline definition format.

---

## Plan 5: OctoDoc Stratagem Integration

**Prerequisite:** Plan 1 complete AND OctoDoc redesigned with `Invoke-DCProbes` and probe registry.

**Scope:** Refactor functions that should use stratagems instead of direct AD queries.

**Functions affected:**
- Infrastructure Health: replication, time sync (compose Replication + TimeSync stratagems)
- Backup & Recovery: backup readiness (compose WSBackup + BackupVendorDetection stratagems)

**What changes:** Internal implementation of affected functions switches from direct AD cmdlets to stratagem composition + `Invoke-DCProbes` + result interpretation. Return contracts stay identical -- consumers see no change.

**What doesn't change:** Function signatures, return contracts, config keys, test assertions (add new tests for stratagem path, keep existing tests for direct-query fallback).

**OctoDoc probe registry integration:** When OctoDoc supports self-describing probe menus, add a `Get-MonarchStratagem` function that maps monarch domains to available probes. This enables LLM agents to dynamically compose stratagems based on what the sensor layer can actually check.

**Blocked until:** OctoDoc redesign ships with `Invoke-DCProbes`, probe registry, and the standard probe result contract (CheckName, Status, Success, Value, Timestamp, Error, ErrorCategory, ExecutionTime).

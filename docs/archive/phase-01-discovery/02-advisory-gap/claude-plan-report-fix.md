# claude-plan-report-fix.md

## Scope

Fix the orchestrator findings extraction gap identified in `orchestrator-advisory-gap-report.md`. The `Invoke-DomainAudit` → `New-MonarchReport` pipeline silently discards results from 10 of 25 Discovery functions. This plan wires those results into the report and adds integration tests to prevent recurrence.

**In scope:**
- Fix the existing `Find-KerberoastableAccount` switch case (checks `PrivilegedCount` only, ignores `TotalCount`)
- Add missing switch cases for 9 unmapped analysis functions
- Wire up 2 judgment-call functions (`Get-FSMORolePlacement`, `Test-TombstoneGap`) pending code inspection
- Add config keys for threshold-based advisories (password policy, event log, DNS)
- Add orchestrator→report integration tests
- Lab validation against BadBlood

**Out of scope (deferred — see TODOs):**
- Domain-specific metrics rendering alongside advisory cards
- Relative file links in report output
- Advisory counting/threshold model redesign

**Not modified:**
- API functions (all 28 are correct and tested)
- Orchestrator function-calling logic (all functions are called, results are collected)
- Report HTML structure (advisory cards render correctly when populated)

---

## Step 1 — Code Inspection: Resolve Overlap Questions

**Purpose:** Two items in the gap report have potential redundancy with existing switch cases. Read the code, determine whether wiring them up would duplicate advisories or fill gaps. This step produces decisions, not code.

**Inspect:**

1. **`Find-UnlinkedGPO` vs `Export-GPOAudit`** — `Export-GPOAudit` already has a switch case checking `UnlinkedCount`. `Find-UnlinkedGPO` is called separately and returns its own `Count` and `UnlinkedGPOs` array. Determine: do they query the same data? Can they disagree? Should `Find-UnlinkedGPO` generate its own advisory, replace the `Export-GPOAudit` unlinked count, or be skipped?

2. **`Test-TombstoneGap` vs `Get-BackupReadinessStatus`** — `Get-BackupReadinessStatus` has a `CriticalGap` check in the switch. `Test-TombstoneGap` returns its own `CriticalGap`. Determine: does `Test-TombstoneGap` add information when `BackupReadinessStatus` only reaches Tier 1? Is it redundant at Tier 2+? Should it have its own advisory or only fire when `BackupReadinessStatus` lacks backup age data?

**Output:** A decision for each item — wire up, skip, or conditional logic. Decisions feed into Steps 3 and 4.

**Dependency:** None. First step.

---

## Step 2 — Add Config Keys for Threshold-Based Advisories

**Purpose:** Items 7–10 in the gap report require threshold comparisons (password policy min length, lockout threshold, event log max size, etc.). Per project convention, all configurable values use the config layer. Add keys to `$script:DefaultConfig` before writing the switch cases that reference them.

**Config keys to add:**

| Key | Default | Used by |
|-----|---------|---------|
| `MinPasswordLength` | `14` | `Get-PasswordPolicyInventory` |
| `RequireLockoutThreshold` | `$true` | `Get-PasswordPolicyInventory` |
| `MinSecurityLogSizeKB` | `1048576` | `Get-EventLogConfiguration` |
| `AcceptableOverflowActions` | `@('ArchiveTheLogWhenFull')` | `Get-EventLogConfiguration` |
| `RequireDNSScavenging` | `$true` | `Get-DNSScavengingConfiguration` |
| `RequireDSIntegration` | `$true` | `Test-ZoneReplicationScope` |

**Passes:**
1. Add keys and defaults to `$script:DefaultConfig` in `Monarch.psm1`
2. Verify `Get-MonarchConfigValue` returns them correctly (quick Pester spot-check)

**Dependency:** None. Can run in parallel with Step 1.

---

## Step 3 — Fix and Add Switch Cases (Core Fix)

**Purpose:** Fix the Kerberoastable case and add the 9 missing switch cases. This is the primary fix — after this step, all analysis functions surface findings in the report.

**Pass 1 — Fix `Find-KerberoastableAccount` (item 1):**
Change the existing case from `$r.PrivilegedCount -gt 0` to `$r.TotalCount -gt 0`. Use `PrivilegedCount -gt 0` to escalate severity from advisory to critical.

**Pass 2 — Add cases for security-critical items (items 2–4):**

| Function | Advisory trigger | Severity escalation |
|----------|-----------------|---------------------|
| `Find-ASREPRoastableAccount` | `$r.Count -gt 0` | — |
| `Find-WeakAccountFlag` | `$r.Findings.Count -gt 0` | `ReversibleEncryption` or `DESOnly` in `CountByFlag` → critical |
| `Find-LegacyProtocolExposure` | `$r.DCFindings.Count -gt 0` | `Risk -eq 'High'` → critical |

**Pass 3 — Add cases for GPO items (items 5–6):**

| Function | Advisory trigger | Notes |
|----------|-----------------|-------|
| `Find-UnlinkedGPO` | Per Step 1 decision | May be skip, advisory, or conditional |
| `Find-GPOPermissionAnomaly` | `$r.Count -gt 0` | — |

**Pass 4 — Add cases for threshold-based items (items 7–10):**

| Function | Advisory trigger (using config keys from Step 2) |
|----------|--------------------------------------------------|
| `Get-PasswordPolicyInventory` | `DefaultPolicy.MinLength -lt $minLen`, `ComplexityEnabled -eq $false`, `LockoutThreshold -eq 0` (when `RequireLockoutThreshold`), `ReversibleEncryption -eq $true` |
| `Get-DNSScavengingConfiguration` | Zones where `ScavengingEnabled -eq $false` (when `RequireDNSScavenging`) |
| `Get-EventLogConfiguration` | `MaxSizeKB -lt $minSize` or `OverflowAction` not in `$acceptableActions` — per DC, Security log |
| `Test-ZoneReplicationScope` | `IsDsIntegrated -eq $false` (when `RequireDSIntegration`) or legacy replication scope |

**Dependency:** Step 1 (for Pass 3 item 5 decision), Step 2 (for Pass 4 config keys).

---

## Step 4 — Wire Up Judgment-Call Functions

**Purpose:** Add switch cases for `Get-FSMORolePlacement` and `Test-TombstoneGap`.

| Function | Advisory trigger | Notes |
|----------|-----------------|-------|
| `Get-FSMORolePlacement` | `$r.UnreachableCount -gt 0` → critical; `$r.AllOnOneDC -eq $true` → advisory | Currently classified as informational — adding advisory logic |
| `Test-TombstoneGap` | Per Step 1 decision | May be conditional on `BackupReadinessStatus` detection tier |

**Dependency:** Step 1 (for `Test-TombstoneGap` decision).

---

## Step 5 — Integration Tests

**Purpose:** Add Pester tests that verify the full orchestrator→report pipeline: mock results with finding-worthy data go in, advisory cards come out. This is the test gap identified in the report — existing tests verify function calls and failure isolation but not findings extraction.

**Pass 1 — Test infrastructure:**
Create mock result objects for each analysis function with finding-worthy data (e.g., `Find-KerberoastableAccount` with `TotalCount = 5`, `Find-ASREPRoastableAccount` with `Count = 3`). These mocks feed into the switch statement under test.

**Pass 2 — Positive tests (findings → advisories):**
For each function with a switch case, verify that a result with finding-worthy data produces an entry in `$advisories` or `$criticals`. One test per function. Pattern:

```
Given: mock result with [Function].TotalCount = 5
When: findings extraction runs
Then: $advisories contains an entry referencing [Function]
```

**Pass 3 — Severity escalation tests:**
For functions with severity escalation (Kerberoastable with PrivilegedCount, WeakAccountFlag with ReversibleEncryption, LegacyProtocolExposure with High risk), verify the escalation from advisory to critical.

**Pass 4 — Negative tests (clean results → no advisory):**
For threshold-based functions, verify that results within acceptable ranges produce no advisory (e.g., `MinLength = 14` with config default `MinPasswordLength = 14` → no finding).

**Dependency:** Steps 3 and 4 (tests verify the switch cases those steps add).

---

## Step 6 — Lab Validation

**Purpose:** Re-run against BadBlood-populated lab domain. Confirm all analysis functions with data produce advisories in the report.

**Verification:**
1. Run `Invoke-DomainAudit -Phase Discovery -OutputPath C:\MonarchOutput`
2. Run the verification script from the gap report (check every function's `HasData` against advisory presence)
3. Confirm report advisory count is substantially higher than the original 5
4. Spot-check: Kerberoastable card appears with TotalCount, AS-REP roastable card appears, weak flags card appears

**Dependency:** Steps 3, 4, 5 all complete.

---

## TODOs (Deferred — Out of Scope for This Plan)

**1. Advisory metrics and counting model:**
The domain-specific metrics section (lines 2616–2622) only renders contextual numbers for Backup & Recovery. Other domains show advisory cards but no summary counts. Additionally, the threshold/counting model needs review — each Kerberoastable account should increment the critical tally by 1, but the current advisory logic may not count this way. This is a design question (how should per-item severity roll up into domain-level counts?) that was not part of the original Discovery spec. Needs its own design pass before implementation.

**2. Test coverage audit:**
SRE + testing specialist review current Pester coverage and estimate percentage against 80% target. The original plan required 80% coverage but the orchestrator→report pipeline had no integration tests verifying that collected data reaches the report. Step 5 of this plan adds the missing integration tests for the findings extraction path specifically, but the broader coverage gap needs an inventory: what other end-to-end paths lack integration testing? Reviewers should estimate current coverage, identify gaps, and scope the work to reach 80%.

**3. Relative file links in report:**
Functions that produce file output (`Export-GPOAudit`, `Find-DormantAccount`) include absolute paths in their return objects. The report should render these as relative links so the output folder is portable. Small fix, no design dependency — can be done independently.

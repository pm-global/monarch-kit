# BadBlood Fix Plan — Detection Pipeline Repair

## Problem Statement

Running against a BadBlood-populated domain (known-bad, deliberately wrecked), the report shows ~0 GPOs, 1 critical, ~15 advisories. Expected: dozens of GPOs, many more findings. The detection pipeline is silently dropping or failing to surface real problems.

Three root causes suspected:

1. **Detection gaps** — functions return empty/zero results, no advisory fires, report says nothing
2. **File output gaps** — some output folders don't get populated, errors swallowed
3. **Manifest inaccuracy** — report file tree references files that don't exist, links don't work

---

## Critical Decisions (resolve before implementation)

**Decision 1: Function disposition model**
Every function that runs needs a final status in the report. Options:
- (a) Add a status row per function (verbose, clutters report)
- (b) Add a per-domain summary line: "N findings / clear / not assessed" (compact)
- (c) Only surface non-clear states: findings or "not assessed" (silence-is-success aligned)

Recommendation: (c) — aligns with existing design philosophy. Domains with no findings and no errors get the existing "No findings" treatment. Domains where a function failed or couldn't run get an explicit "not assessed" card. This distinguishes "checked and clean" from "never checked."

**Decision 2: GPO module absence handling**
When GroupPolicy module isn't loaded, Export-GPOAudit currently fails silently. Options:
- (a) Throw — orchestrator catches, records failure, report shows error
- (b) Return a degraded result object with TotalGPOs=0 and a warning
- (c) Return a result with a new `Status = 'NotAssessed'` property and reason

Recommendation: (a) for total module absence (can't do anything useful), (c) for partial failures within the function (some GPOs processed, some errored).

**Decision 3: Manifest construction strategy**
Build file tree from:
- (a) What functions claim they wrote (current — unreliable)
- (b) What's actually on disk after all functions complete (scan OutputPath)
- (c) Hybrid — collect claims, verify each path exists, include only verified

Recommendation: (c) — preserves the structured grouping from function metadata (folder names, categories) while ensuring nothing phantom appears. Functions that write files report their paths; manifest builder verifies before including.

**Decision 4: "Silence is success" boundary**
The design doc says silence is success. But a report that says nothing about GPOs when GPOs exist is broken. Where's the line?
- Silence is success means: no advisory card for clean results
- Silence is NOT: omitting entire domains from the report without explanation
- Every domain that was assessed appears in the report, even if only as "No findings"
- Every domain that was NOT assessed appears with "Not assessed — [reason]"

---

## Step 1 — Diagnostic Pass (no code changes) — COMPLETE

Ran `bb-check.ps1` on BadBlood domain (LIGHT.local, single DC). All 25 functions called individually. Results:

**Root cause:** All 5 bugs are the same class — code accesses properties that don't exist on real cmdlet output. Pester mocks provided fictional properties, so tests passed. Only running against a real domain exposed the failures.

**Confirmed bugs (severity order):**

| Bug | Function | Line | Issue | Impact |
|-----|----------|------|-------|--------|
| 1 | `Get-ReplicationHealth` | 525 | `@splatAD` passes `-Server` to `Get-ADReplicationPartnerMetadata` (doesn't accept it) | FIXED 2026-03-31 |
| 2 | `Get-EventLogConfiguration` | 2208 | `.LogRetention` doesn't exist on `EventLogConfiguration` class | FIXED 2026-03-31 |
| 3 | `Export-GPOAudit` + orchestrator | 2813 | Orchestrator doesn't pass `-IncludePermissions`/`-IncludeWMIFilters` | FIXED |
| 4 | `Get-DNSForwarderConfiguration` | 2390 | `.UseRootHints` version-dependent, throws on some hosts | FIXED |
| 5 | `Export-GPOAudit` | 1200 | `.Order` doesn't exist on GPO XML `LinksTo` node | FIXED |

**Not bugs (confirmed working):**
- GPO count of 3 is correct — BadBlood creates users/groups/ACLs, not GPOs
- Find-DormantAccount TotalCount=0 is correct — BB accounts are 1 day old, under both dormancy threshold and never-logged-on grace period
- All other functions return correct data (property names in initial diagnostic were wrong)

**Individual fix plans:** `bb-fix-bug1.md` through `bb-fix-bug5.md` in repo root.

---

## Step 2 — Fix Individual Detection Bugs - COMPLETE

**Purpose:** Fix each function identified in Step 1.

**Plan files:** Each bug has a self-contained plan file in the repo root (`bb-fix-bug1.md` through `bb-fix-bug5.md`). Each plan has 2 passes: code fix + test update. Execute in fresh chats, archive when validated.

**Progress:** Bug 1 FIXED (2026-03-31). Bug 2 FIXED (2026-03-31). Bug 3 FIXED (2026-03-31). Bug 4 FIXED (2026-03-31). Bug 5 FIXED (2026-03-31). All bugs resolved.

---

## Step 3 — Add Function Disposition to Report

**Purpose:** Every function that ran gets a status. Report distinguishes "clean" from "not assessed."

**Pass 1:** Add disposition tracking to the orchestrator. Each function call records: ran successfully, returned findings, returned clean, or failed.

**Pass 2:** Update New-MonarchReport to consume dispositions. Domains where all functions succeeded but had no findings: "No findings." Domains where a function failed: "Not assessed — [reason]" card.

**Pass 3:** Pester tests for disposition rendering.

---

## Step 4 — Build Honest File Manifest

**Purpose:** Report file tree reflects only files that actually exist. Links work.

**Pass 1:** After all functions complete, collect claimed output paths from result objects. Verify each path exists with Test-Path. Build manifest from verified paths only.

**Pass 2:** Convert absolute paths to relative paths (relative to OutputPath). Generate working href links.

**Pass 3:** Pester tests — mock file system, verify manifest accuracy.

---

## Step 5 — Integration Validation

**Purpose:** Full pipeline test against BadBlood domain.

**Pass 1:** Re-run Invoke-DomainAudit on BB domain. Verify:
- GPO count is non-zero and plausible
- Advisory count reflects actual domain state
- Every domain section appears with findings or "No findings"
- No domain says "Not assessed" unless the module is genuinely missing
- File manifest matches actual disk contents
- All manifest links open the correct files

**Pass 2:** Compare report output to report-v5.html reference format. Verify domain metrics, advisory cards, expandable detail tables are all populated where data exists.

---

## Relationship to CLAUDE-DEV-PLAN TODOs

- TODO-1 (diagnostic pass): COMPLETE
- TODO-2 (fix bugs): COMPLETE
- TODO-3 (function disposition): Step 3 of this plan
- TODO-4 (honest manifest): Step 4 of this plan
- TODO-5 (integration validation): Step 5 of this plan
- TODO-6 (advisory metrics): deferred, but TODO-3 disposition work is prerequisite

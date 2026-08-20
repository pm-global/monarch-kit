# Working Summary
This file is a single file that captures the decisions and development of all the legacy documentation within the monarch-kit project. it is necessary to organize this so it can be processed into CONTEXT.md, ADRs, and Github Issues so the repo is compatible with Matt Pocock's /grill-with-docs skill and other programming skills. Without those initial files, all of his other skills/tools are... useless. having the docs in place means the skills are vastly more functional, existing work can be checked against the design in a strategic and complete way, and future development in the repo is easier. Matt's skills assume an empty repo or a pre-existing repo doc format. Since this repo is neither, this file is part of a strategy to get there.

Source: `docs/archive/phase-01-discovery/01-discovery/CLAUDE-DEV-PLAN-v1.md`, lines 1–585 (Plan 1, Steps 1–7; all `[x]` shipped).

## context

- Return contract: every public function returns `PSCustomObject` with `Domain` (functional area: `InfrastructureHealth`, `IdentityLifecycle`, `PrivilegedAccess`, `SecurityPosture`, `AuditCompliance`, …), `Function`, `Timestamp`, `Warnings[]`.
- `-Domain` vs `-Server`: `-Domain` is the audit target name; orchestrator resolves it to a DC once, passes as `-Server` everywhere. Direct callers can pass either.
- Config access: single entry point `Get-MonarchConfigValue -Key`; never index `$script:Config` directly.
- Privileged group definition: matched by RID suffix (`*-512` Domain Admins, `*-518` Schema Admins, `*-519` Enterprise Admins) + well-known SIDs (`S-1-5-32-544/548/549/551`), not full SID string.
- "Orphan" (`Find-AdminCountOrphan`): `AdminCount=1` but not a member of any privileged group.
- "Gap account" (`Test-ProtectedUsersGap`): privileged but missing from Protected Users. Rule: never recommend blanket addition — accounts with SPN (`HasSPN=$true`) will break if added.
- `DomainAdminStatus`: `OK`/`Warning`/`Critical`, threshold-driven (default 5/10).
- `Get-ForestDomainLevel` intentionally overlaps `New-DomainBaseline` — baseline is a snapshot doc, this is a focused check. Both cheap AD queries.

## adr

1. **Error handling pattern** — read-only functions use `$ErrorActionPreference='Continue'`, catch per-section, surface failures in `Warnings[]`; only throw if the whole function can't reach AD. Hard to reverse across 25 functions, surprising to a new reader, real tradeoff (resilience vs fail-fast).

2. **`Find-AdminCountOrphan` duplicates group-enumeration logic** instead of calling `Get-PrivilegedGroupMembership`. Doc flags it explicitly as a "Design decision." Surprising (breaks DRY on purpose), real tradeoff stated (duplication vs function coupling).

3. **OctoDoc optional dependency with fallback** — `Resolve-MonarchDC` tries `Get-HealthyDC` (OctoDoc) first, falls back to `Get-ADDomainController -Discover` if OctoDoc missing/fails/unavailable. Hard to reverse once callers depend on the shape, surprising why an external MVP module is wired in at all, real tradeoff (richer data vs availability without it).

4. **Object-only output, v0 text reports dropped.** Breaking change from v0 behavior (`Create-NetworkBaseline.ps1` wrote text reports); return object is now the sole structured output, CSV exports kept per-section. Surprising if you know v0, real tradeoff (structured data vs human-readable output at the source).

---

Source: same file, lines 586–1072 (Plan 1, Steps 8–14; all `[x]` shipped).

## context

- "Dormant account" (`Find-DormantAccount`): no logon within `DormancyThresholdDays`, minus exclusions — built-ins, `PasswordNeverExpires`, SPN holders, service-keyword matches, privileged group members, MSA/gMSA objects, never-logged-on accounts younger than grace period.
- GPO output folder convention: `00-SUMMARY` … `05-WMI-Filters`, fixed numbering, carried from v0.
- Backup detection tiers: `DetectionTier` 1 (tombstone/recycle bin, always available) → 2 (WSB event log or known vendor service) → 3 (opt-in vendor integration for actual backup age).
- `CriticalGap`: backup age exceeds tombstone lifetime — only evaluable once `LastBackupAge` is known (tier 3).
- Orchestrator output layout: `Monarch-Audit-yyyyMMdd/01-Baseline … 05-Infrastructure/`, fixed execution order of 25 functions + report.

## adr

5. **Two-pass dormant-account scan.** First pass uses replicated `lastLogonTimestamp` (cheap, no cross-DC fanout); only accounts within 15 days of threshold get the expensive per-DC `lastLogon` query. Hard to reverse once relied on at scale, surprising (why not just query `lastLogon` directly), real tradeoff (accuracy vs cost, O(users×DCs) → O(near-threshold×DCs)).

6. **`New-MonarchReport` never calls API functions — reads `Results` only.** Stated explicitly: "reporting can't drift from the actual data." Hard to reverse once report and orchestrator are wired this way, surprising to someone expecting the report to fetch its own data, real tradeoff (loose coupling vs convenience).

---

Source: same file, lines 1073–1187 (Plans 2–5, all `Not started`).

## planned

- **Plan 2 — Remediation/Monitoring/Cleanup**: `Suspend-DormantAccount`, `Restore-DormantAccount`, `Remove-DormantAccount`, `Remove-AdminCountOrphan`, `Grant-TimeBoundGroupMembership`, `Backup-GPO`, `Get-DormantAccountMonitoringMetrics`. Destructive ops, WhatIf-gated, built on the extensionAttribute14/15 mechanism already decided in Plan 1.
- **Plan 3 — Interactive wrapper** (`Start-MonarchAudit`): menu-driven entry point (1–5 phase selection). Design constraint stated up front: calls the orchestrator only, never API functions directly. Not built — not yet an ADR.
- **Plan 4 — Comparison functions**: `Compare-DomainBaseline`, `Compare-GPO`, `Compare-CISBaseline`, `Test-TieredAdminCompliance`. Needs prior Discovery data or external baseline files.
- **Plan 5 — OctoDoc stratagem integration**: refactor replication/time-sync/backup functions to use stratagems + `Invoke-DCProbes` instead of direct AD queries. Return contracts stay identical. Blocked on OctoDoc redesign, not just unscheduled.

---

Source: `STEP-13-SUBPLAN.md` (Reporting, shipped).

## context

- **Critical vs Advisory classification** — the finding-severity glossary. Critical = blocks progression to Remediation. Advisory = surfaced, doesn't block. Complete mapping, one row per source-function condition:

  | Source Function | Condition | Severity |
  |----------------|-----------|----------|
  | `Get-BackupReadinessStatus` | `CriticalGap -eq $true` | Critical |
  | `Get-BackupReadinessStatus` | Tier 1 only, no backup tool detected | Advisory |
  | `Get-ReplicationHealth` | `FailedLinkCount -gt 0` | Critical |
  | `Get-ReplicationHealth` | `WarningLinkCount -gt 0` | Advisory |
  | `Get-PrivilegedGroupMembership` | `DomainAdminStatus -eq 'Critical'` | Critical |
  | `Get-PrivilegedGroupMembership` | `DomainAdminStatus -eq 'Warning'` | Advisory |
  | `Find-DormantAccount` | `TotalCount -gt 0` | Advisory |
  | `Get-SiteTopology` | `UnassignedSubnets.Count -gt 0` | Advisory |
  | `Get-SiteTopology` | `EmptySites.Count -gt 0` | Advisory |
  | `Test-SRVRecordCompleteness` | `AllComplete -eq $false` | Advisory |
  | `Get-AuditPolicyConfiguration` | `Consistent -eq $false` | Advisory |
  | `Get-DNSForwarderConfiguration` | `Consistent -eq $false` | Advisory |
  | `Find-KerberoastableAccount` | `PrivilegedCount -gt 0` | Advisory *(superseded — see two-branch trigger below)* |
  | `Test-ProtectedUsersGap` | `GapAccounts.Count -gt 0` | Advisory |
  | `Find-AdminCountOrphan` | `Count -gt 0` | Advisory |
  | `Export-GPOAudit` | `UnlinkedCount -gt 0` | Advisory |

  This was the extraction list as of Step 13 shipping — later found incomplete (10 functions returned data with no case) and extended; see advisory-gap section below. **Also missing from this table:** `Find-ASREPRoastableAccount` — added later via `01-report-data-plan.md` (Step 8), same two-branch pattern as `Find-KerberoastableAccount`: `PrivilegedCount -gt 0` → Critical, `TotalCount -gt 0 -and PrivilegedCount -eq 0` → Advisory.

- **Report domain ordering** (when findings exist, operational priority): Backup & Recovery → Infrastructure Health → Privileged Access → Identity Lifecycle → Group Policy → Security Posture → Audit & Compliance → DNS. Domains with no findings collapse into one "Clean Domains" line, never rendered as empty sections.

- **Not yet read**: `docs/design-system.md` and `report-v5.html` — cited as the canonical visual reference for the HTML report, neither pulled into this summary yet.

---

Source: `docs/archive/phase-01-discovery/02-advisory-gap/` — `orchestrator-advisory-gap-report.md`, `claude-plan-report-fix.md`, `STEP-3-SUBPLAN.md`, `STEP-5-SUBPLAN.md` (advisory extraction gap, found and fixed).

## context

- `Find-KerberoastableAccount` two-branch trigger: `PrivilegedCount -gt 0` → Critical; `TotalCount -gt 0 -and PrivilegedCount -eq 0` → Advisory. Guard prevents double-count when both nonzero.
- `Find-UnlinkedGPO` and `Test-TombstoneGap` have no switch case by design: former redundant with `Export-GPOAudit`'s `UnlinkedCount`, latter dead in current pipeline (orchestrator never passes `-BackupAgeDays`, so `CriticalGap` is always `$null`).
- `ReversibleEncryption` checked at two levels intentionally, not redundant: `Find-WeakAccountFlag` (per-account, who has it) and `Get-PasswordPolicyInventory` (domain-wide default policy).
- `Find-LegacyProtocolExposure`: `Risk -eq 'High'` → Critical, `Risk -eq 'Medium'` → Advisory.
- Config keys (`$script:DefaultConfig`): `MinPasswordLength`(14), `RequireLockoutThreshold`($true), `MinSecurityLogSizeKB`(1048576), `AcceptableOverflowActions`(@('ArchiveTheLogWhenFull')), `RequireDNSScavenging`($true), `RequireDSIntegration`($true).

---

Source: `docs/archive/phase-01-discovery/03-bug-fix-badblood/01-squash/bb-fix-bug2.md`, `bb-fix-bug3.md`, `bb-fix-bug4.md`, `bb-fix-bug5.md` (BadBlood lab bug fixes; `bb-fix-bug1.md` skipped — pure splat-parameter mistake, no domain fact to extract).

## context

- Orchestrator always calls `Export-GPOAudit` with `-IncludePermissions -IncludeWMIFilters` set. Design choice: those switches exist for lightweight direct callers; the orchestrator always wants full analysis.
- `Get-DNSForwarderConfiguration.DCForwarders[].UseRootHints`: version-dependent property, absent on some Windows Server versions. When absent, value is `$null` — not `$false`. Don't treat `$null` as "root hints disabled."
- GPO XML `LinksTo` node (`Export-GPOAudit` linkage objects) only has `SOMPath`, `Enabled`, `NoOverride` — no `Order` property exists on it, don't re-add.
- `Get-EventLogConfiguration.DCs[].Logs[].OverflowAction` comes from `Get-WinEvent -ListLog`'s `LogMode` enum: `Circular` / `AutoBackup` / `Retain`. No separate retention-days concept exists for event logs.

**OPEN QUESTION (unresolved, needs a later doc or code check to confirm/squash):** the advisory-gap fix's config default `AcceptableOverflowActions = @('ArchiveTheLogWhenFull')` doesn't match any actual `LogMode` value above (`Circular`/`AutoBackup`/`Retain`). If that default is still live, the event-log advisory fires on every DC unconditionally — `'ArchiveTheLogWhenFull'` can never match. Cross-doc inconsistency between `STEP-3-SUBPLAN.md` (advisory-gap) and `bb-fix-bug2.md` (this fix) — neither doc references the other.

---

Source: `docs/archive/phase-01-discovery/03-bug-fix-badblood/00-bb-fix-plan.md` (overarching BadBlood-fix plan; all steps complete).

## context

- Silence-is-success boundary, precisely: no advisory card for a *clean* result, but every *assessed* domain still appears in the report — as "No findings" if clean, "Not assessed — [reason]" if a function failed. Never omit an assessed domain silently; that's the line between "quiet" and "broken."

## adr

7. **Function disposition model** — every function that runs gets a final status, consumed by `New-MonarchReport`. Only non-clear states get surfaced explicitly. Hard to reverse (report contract), surprising (silence-is-success doesn't mean *omission*), real tradeoff (compact report vs distinguishing "checked clean" from "never checked"). **Correction (`02-report-disposition-fix-plan.md`):** implemented as **2-state**, not 3-state — orchestrator tracks only `Assessed`/`NotAssessed` (did the function run?). Findings-vs-clean is determined later by the report's existing switch-case logic, not the orchestrator. A 3-state model (findings/clean/not-assessed) was explicitly considered and rejected mid-plan as "too coupled."

8. **GPO module absence handling, split by failure type.** Full `GroupPolicy` module missing → `Export-GPOAudit` throws, orchestrator catches, report shows error (nothing useful possible). Partial in-function failure → returns `Status='NotAssessed'` + reason, keeps going. Hard to reverse, surprising (why not always degrade gracefully), real tradeoff (fail-fast on unrecoverable vs resilience on partial failure).

9. **File manifest built by pure disk scan, not claim-verification.** **Corrected (`03-manifest-fix-plan.md`, D1 — explicitly "Decision 3(b)"):** shipped implementation scans `$OutputPath` directly with `Get-ChildItem -File -Recurse` after all functions complete; function-claimed paths (`OutputFiles`/`OutputPaths`/`CSVPath`) are never consulted. Rejected pure "trust claims" (phantom links) and the hybrid claim-then-verify approach originally recommended in `00-bb-fix-plan.md` — scanning is simpler (one call vs three property-type branches), correct by construction, and catches files a function wrote but didn't report. Hard to reverse, surprising, real tradeoff (structure/grouping from function metadata vs guaranteed honesty) — disk-scan wins on honesty, grouping is reconstructed from path segments instead.

---

Source: `docs/archive/phase-01-discovery/03-bug-fix-badblood/01-report-data-plan.md` (report data-surface plan; all 9 steps complete).

## context

- `Results` object top-level shape (orchestrator output consumed by `New-MonarchReport`): `Domain, DCUsed, StartTime, EndTime, Results[], Failures[], Dispositions[], TotalChecks`.
- Protected Users gap advisory carries no denominator/fraction — additive context only: `"15 privileged accounts not in Protected Users — includes 7 DAs, 2 EAs"`. `EnterpriseAdminCount` is not a real top-level field on `Get-PrivilegedGroupMembership`; EA count is derived from `.Groups` (`GroupSID -like '*-519'`) at the report layer — same derivation used for the PrivilegedAccess metrics strip. A DA+EA-only denominator was rejected: `Test-ProtectedUsersGap` evaluates 7 privileged groups total, so DA+EA is a strict subset and would misstate the fraction.
- Kerberoastable non-critical advisory always states privileged count, including zero — the zero is signal the dangerous subset was checked, not omitted.
- AS-REP roastable severity mirrors Kerberoastable's two-branch pattern: `PrivilegedCount -gt 0` → Critical, `TotalCount -gt 0 -and PrivilegedCount -eq 0` → Advisory. `PrivilegedCount` is computed at the report layer from `.Accounts | Where-Object IsPrivileged`, not a source field on `Find-ASREPRoastableAccount`.
- `report-v5.html` = intended design reference; `report-v7.html` = known live-domain output reference, used for regression diff in integration validation.
- Report redesign (layout, visual hierarchy) explicitly out of scope for this plan — separate later phase.

---

Source: `docs/archive/phase-01-discovery/03-bug-fix-badblood/04-report-step7-plan.md` (Step 7 advisory rewrites; complete).

## context

- Event log advisory names each affected DC with its issue tags, not a bare count: `"Security log: DC01 (undersized, overflow), DC02 (undersized)"`.

---

Source: `docs/archive/phase-01-discovery/03-bug-fix-badblood/02-report-disposition-fix-plan.md` (TODO-3 implementation; all 3 passes complete).

## context

- Canonical function→domain map (all 25 functions across 8 domains), built into the orchestrator's `$calls` array so a function that throws (never returns a result object) can still be placed in the correct domain section as "not assessed."
- Backward-compat fallback: if `Results.Dispositions` is absent (older orchestrator output), the report synthesizes dispositions from `Results`+`Failures`. Synthesized failures have `Domain = $null` (old failure format didn't carry it) and fall into a generic not-assessed list rather than their domain section — only new orchestrator output gets full domain-contextual placement.

---

Source: `docs/archive/phase-01-discovery/03-bug-fix-badblood/03-manifest-fix-plan.md` (Step 4 implementation; all 3 passes complete).

## context

- Empty-manifest rule: if zero files exist under `OutputPath` (excluding the report itself) after cleanup, the whole "Output Files" section is omitted, not rendered empty.
- Scope boundary stated explicitly: this plan changes only manifest construction/rendering in `New-MonarchReport` plus the disk cleanup pass — function return contracts (`OutputFiles`/`OutputPaths`/`CSVPath` shapes) and orchestrator logic untouched.

## adr

10. **Report generation deletes empty files/dirs from disk as a side effect.** Before scanning, `New-MonarchReport` recursively removes 0-byte files and empty directories under `OutputPath` (leaf-first), so orchestrator-pre-created folders a function wrote nothing into vanish from both disk and report. Hard to reverse (destructive, silent), surprising (a *report* function mutates the output directory), real tradeoff (perfectly honest 1:1 tree vs a reporting step that deletes things).

---

Source: `docs/archive/phase-01-discovery/04-todos-and-bugfix/todo0-gpo-file-tree/todo00-gpo-file-tree-plan.md` (TODO-00, GPO file tree fix).

## context

- File tree collapse rule: subfolder groups exceeding threshold (5 files) collapse to a `subfolder/* (N files)` line, `--text-3` color. Index file (`00-*`) still renders as a separate clickable link above the collapse line. General mechanism, not GPO-specific — applies to any high-cardinality generated file set.
- `Get-GPOReport` HTML export needs `-ErrorAction Stop` — it produces non-terminating errors on failure, which are swallowed silently otherwise (no file written, no warning), matching the existing pattern used elsewhere in the module.
- `-Path` parameter on `Get-GPOReport -ReportType Html` is unreliable — capture the report as a string and write via `Out-File` instead.
- `00-INDEX.html` GPO rows are built from the full `Get-GPO -All` list, not from the HTML-generation-success list — index always lists every GPO regardless of export outcome, "View" link conditional on the file existing, otherwise shows "N/A".

## adr

11. **Design-system exception for generated file sets.** Count annotations are allowed for collapsed high-cardinality folders, overriding `docs/design-system.md` line 177's "no counts, no promoted links." Surprising (contradicts a stated design rule), real tradeoff (informational count vs "silence is success" minimalism), hard to reverse once other generated-output sections follow the same collapse pattern.

---

Source: `docs/archive/phase-01-discovery/04-todos-and-bugfix/todo0-gpo-file-tree/todo0-pass2-priv-access-implementation-plan.md` (TODO-2, Pass 2 implementation).

## context

- `Get-PrivilegedGroupMembership`/`Find-AdminCountOrphan` support `-OutputPath` — write `privileged-groups.csv` (flattened group members, sorted by SamAccountName) / `admincount-orphans.csv`. `CSVPath` return field non-null iff a file was written — empty result set writes nothing.
- Orchestrator combines `Find-KerberoastableAccount` + `Find-ASREPRoastableAccount` output into a single `roastable-accounts.csv` (`ThreatType` column distinguishes) in `03-Privileged-Access/`. Combine happens at the orchestrator level, not on the functions themselves — neither function got `-OutputPath`. Never written if 0 rows.
- Combine step wrapped in try/catch — failure warns, doesn't rethrow, orchestrator completes regardless.

---

Source: `docs/archive/phase-01-discovery/04-todos-and-bugfix/todo0-gpo-file-tree/todo0-priv-access-output-plan.md` (TODO-0, original plan; implemented by the Pass 2 doc above — overlapping content not re-listed).

## context

- Zero-CSV-rows is a deliberate signal, not a gap: report surfaces priv-access counts via return-object fields, not CSV presence — same pattern already used for Kerberoast/ASREP advisories (only fire when counts positive).
- No path validation in these functions — `Export-Csv` throws natively on a bad path. Orchestrator pre-creates all subdirs before calling. Standalone callers own their path validity, consistent with `Find-DormantAccount`'s existing behavior.

---

Source: `docs/archive/phase-01-discovery/04-todos-and-bugfix/todo1-surface-diagnostic-hints.md` (TODO-1, surface DiagnosticHints in report cards).

## context

- `DiagnosticHint`/`DiagnosticHints` render as `.card .diagnostic-hint` divs — scalar field → one div, list field (only `Get-ReplicationHealth` today) → one div per entry, each on its own line.
- `Test-TombstoneGap` only gets a real hint when the orchestrator has a prior `Get-BackupReadinessStatus` result with non-null `LastBackupAge` (Tier 3 only) — injects `BackupAgeDays = [int]LastBackupAge.TotalDays`. Without it, `CriticalGap` stays `$null` and no finding is emitted — not a false critical, not the stub masquerading as a finding.
- `Test-TombstoneGap`'s critical `Description` matches `Get-BackupReadinessStatus`'s critical description verbatim, by design — sets up mechanical dedupe of the resulting duplicate-card case (filed separately).
- Card rendering loop is shared across all functions, not just the ones with `DiagnosticHint` — property access on card/source result objects needs `-ErrorAction SilentlyContinue` under active `Set-StrictMode -Version Latest`, since most functions lack the field entirely.

---

Source: `docs/archive/phase-01-discovery/04-todos-and-bugfix/todo2-bad-test-fix.md` (TODO-2, pre-existing test fixes; test-only, no production code change).

## context

- Pester gotcha: `Should -Invoke` doesn't see mock calls made during `BeforeAll` when asserted in a later `It` block — the call under test must happen inside the `It` itself, not the setup block.

---

Source: `docs/archive/phase-01-discovery/04-todos-and-bugfix/todo3-progress-output-plan.md` (TODO-3, progress output with silent mode).

## context

- `-Verbosity` param (`Silent`/`Error`/`Warn`/`Info`, default `Info`) on `Invoke-DomainAudit` and `New-MonarchReport` gates progress bar / per-function narration / failure blocks / OK summary. Implemented as named booleans precomputed once before the loop (`$showHeader`, `$showProgress`, etc.), not inlined per-iteration string comparisons. *(Custom scheme built before realizing PowerShell's own `-Verbose`/`$VerbosePreference` mechanism existed — see `planned` below.)*
- Standard pattern for suppressing a called function's own narration: redirect its `Write-Host` via `6>$null` (Information stream), let the caller narrate that step itself instead.
- Visual conventions: DarkGray per-function lines, Red failure blocks (`->` arrow, not `↳`), Green OK summary, Cyan header, plain center-dot `·` (U+00B7) as separator. Duration formatted `Xm Ys` at 60s+, else `Xs`.
- PowerShell footgun: `Write-Progress` call must be a single line, no backtick continuation — trailing whitespace after a backtick silently breaks the call.

## adr

12. **4-level `-Verbosity` scheme, default `Info` (max non-debug verbosity).** Hard to reverse (public param once scripts depend on it), real trade-off (transparency-by-default vs automation-quiet-by-default) — rationale stated: tool runs infrequently on important infra, so admin sees everything by default; `Silent` exists for piping/automation. *(See `planned` below — custom scheme predates discovery of PowerShell's built-in verbosity system.)*

## planned

- Rip out the custom `-Verbosity` parameter/scheme entirely; replace with PowerShell's built-in verbosity capabilities (`-Verbose` common parameter, `Write-Verbose`, `$VerbosePreference`). Custom scheme was built without realizing the built-in mechanism already covered this.

---

Source: `docs/archive/phase-01-discovery/04-todos-and-bugfix/todo4-passthru-param.md` (TODO-4, `-PassThru` for `Invoke-DomainAudit`, v0.5.1-beta).

## context

- `Invoke-DomainAudit` returns nothing by default — must pass `-PassThru` to get the result object. Default optimizes for clean interactive console output (avoids an accidental `Out-Default` object dump after the `audit OK:` line).

## adr

13. **`-PassThru` gate on `Invoke-DomainAudit`'s return, breaking change.** Shipped as a clean break at v0.5.1-beta (no external users yet, no deprecation period). Hard to reverse once scripts depend on default silence, surprising (functions conventionally just return their result), real trade-off (clean interactive UX by default vs scripting having to opt in explicitly).

---

Source: `docs/plans/roastable-consolidation-plan.md` (not started).

## planned

- **Roastable advisory consolidation**: merge Kerberoastable + AS-REP roastable into one Privileged Access advisory (currently two separate cards). Discovery functions, return contracts, `roastable-accounts.csv` unchanged. Blocks `advisory-drilldown-plan.md`, which must be revised to match once this lands.

---

Source: `docs/plans/todo-dormant-outputpath.md` (implemented).

## context

- `Find-DormantAccount` follows the module's directory-semantics `-OutputPath` convention (same as `Get-PrivilegedGroupMembership`/`Find-AdminCountOrphan`): receives a directory, writes `dormant-accounts.csv` internally. Orchestrator passes `$dirs.Dormant`.

---

Source: `docs/plans/todo-privaccess-output.md` (2 of 4 functions implemented; see existing context above).

## context

**OPEN QUESTION (unresolved — needs a later doc or code check to confirm/squash):** this plan targets `-OutputPath` on all four Privileged Access functions. `Get-PrivilegedGroupMembership`/`Find-AdminCountOrphan` have it (already documented above). `Find-KerberoastableAccount`/`Find-ASREPRoastableAccount` still don't — orchestrator calls them with only `-Server` (`Monarch.psm1:3099-3100`). Unclear if that's this plan still pending, or superseded by the roastable-accounts.csv combiner (already shipped, documented above) as the intentional final design for those two.

---

Source: `docs/raw/todo-advisory-hints.md` (raw, undesigned, not started).

## planned

- **Advisory card action hints.** Advisory-severity cards need action-hint text, same as critical cards got via TODO-1. Separate wording set — must avoid false urgency for non-critical findings. Needs a design pass before implementation; promote to `docs/plans/` with hint text per card type when ready.

---

Source: `docs/raw/todo-failed-check-surfacing.md` (raw, undesigned, not started).

## planned

- **Failed-check surfacing as a critical advisory.** No on-page signal today when a discovery function fails to return data — `-Silent` runs and non-watching admins see nothing, risking a false negative that looks like a clean domain. Sketch: one critical advisory naming every failed function, bucketed `$criticals`. Subsumes the roastable consolidation plan's per-advisory `?` placeholder as the global version of that signal. Explicitly deferred out of that plan's scope.

---

Source: `docs/raw/todo-live-domain-tests.md` (raw, undesigned, not started).

## planned

- **Live domain test suite.** Current suite is mock-only; some AD failure modes only surface against a real domain. Sketch: separate `Monarch.LiveDomain.Tests.ps1`, gated by `$env:MONARCH_TEST_DOMAIN`, BadBlood VM as target. Revisit once Phase 2 remediation functions ship — destructive-op mocks (suspend → restore → delete) need the most scrutiny.

---

Source: `docs/raw/todo-research-brief.md` (reference work; done — see correction below).

## context

**Correction:** already done. `docs/gap-research.md` is the reformatted research brief this item asked for — structure matches the project's research-brief format (Platform Constraints, Established Patterns, Known Failure Modes, Available Building Blocks, Prior Art, plus further synthesis sections not in the source). `docs/initial-research.md` is the raw source transcript it was built from. Filed under a different name than expected (`gap-research.md`, not `research-brief-monarch-kit.md`).

---

Source: `docs/raw/todo-test-coverage.md` (audit task, not started).

## planned

- **Test coverage audit, 80% target.** Audit `Monarch.Tests.ps1` against an 80% behavior-coverage target. Map each public function to its coverage, flag untested behaviors (not just untested lines) and integration-test gaps in orchestrator paths. Audit only, no design needed; findings that need new tests become Class B changes.

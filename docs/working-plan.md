# Working Plan

**This file no longer tracks the work.** Issue #9 is the map, and its child issues are the
open questions. This file retires into that map. What survives here until then is the target
tree below and the notes that have no home yet.

This file is part of the effort to standardize documentation for this repo to what is required by Matt Pocock's /grill-with-docs skill.

Document categorization for `docs/` root, plus the validation efforts required before any of it is trusted enough to convert, cite, or build against.

---

## Document Buckets

### A. Decision record — convert to ADR
- **mechanism-decisions.md** — internal hard-to-reverse decisions with rationale (config model, thresholds, extensionAttribute choices). Convert to `docs/adr/`, one file per decision, once cleared by Validation Effort 2.

### B. Normative standard — not a decision, not user-facing, stays standalone
- **docs/reference/dormant-account-standard.md** — PCI DSS / NIST 800-53 / MS compliance standard the code must conform to. External authority, not an internal choice, so it doesn't become an ADR. Standards move slowly; re-verify citations occasionally, otherwise stable.

### C. Living standards doc — peer to CODING_STANDARDS.md
- **docs/reference/report-design-system.md** — visual/report standard. Needs an improvement pass plus a gap audit against the current report implementation (Validation Effort 3).

### D. Baseline — the current real output
- **docs/sample-report/demo_report_v9.html** — a real client report, anonymized. This is what the module produces today, and it is the baseline for measuring change.
- **docs/sample-report/demo_report_v5.html** — a fabricated mockup that was never implemented. `report-design-system.md` was extracted from it. Treat it as an unmet aspiration, not as a description of the tool. v10 is defined as v9 plus whatever of v5 is still wanted.
- See `docs/sample-report/README.md` for all three samples and their roles.

### E. Future-phase development research — dormant until then
- **checklists.md** — seed material for Phase 3 (interactive wrapper). Not user-facing. No action until Phase 3 starts, then feeds that phase's spec/ticket work.

### F. Design-rationale source — still live
- **docs/reference/gpo-review-workflow.md** — shaped which discovery checks exist and what data the report surfaces. Re-consult on any future report or discovery change, same role mechanism-decisions.md plays for thresholds.

### G. Needs disassembly — no single verdict yet
- **domain-specs.md** — two things stapled together: a function/contract catalog (may now be redundant with implemented code, given the minimal-comment code style) and non-obvious rationale notes (real institutional knowledge with no other home). Requires a line-by-line sort — not a file-level decision — before any verdict on what survives and where it goes (CONTEXT.md, an ADR, or nowhere).

### H. Instructional — no change needed
- **deployment-guide.md** — environment setup and deploy steps.

### I. Implementation plan — status tracked in Validation Effort 4
- **docs/plans/todo-privaccess-output.md**
- **docs/plans/roastable-consolidation-plan.md**
- **docs/plans/advisory-drilldown-plan.md**

### Research — survives as reference, does not dissolve
- **docs/reference/ad-research/research-brief.md** — the structured brief. Its own title is "Research Brief: monarch-kit".
- **docs/reference/ad-research/research-brief-draft.md** — the earlier, wider version the brief was built from. Carries tail material the brief dropped.

### Out of scope for this pass
- **working-summary.md** — separate validation effort, tracked below.
- **CODING_STANDARDS.md** — already known-good, excluded from this review. Moved to the repo root.

---

## Validation Efforts

More efforts may be appended here (5, 6, ...) as they're identified. The Final Step below always runs last, after every effort in this section closes — inserting a new numbered effort never requires renumbering it.

### 2. [COMPLETE] domain-specs.md + mechanism-decisions.md vs code
Success: every entry in both files checked against the implemented function or mechanism it describes.
- mechanism-decisions.md entries confirmed still true → eligible for ADR conversion (Bucket A).
- domain-specs.md entries sorted into (a) redundant with code, safe to drop, or (b) non-obvious rationale with no other home, migrated to CONTEXT.md or an ADR before the file is touched further (Bucket G).

### 3. report-design-system.md + report samples vs report-generation code
Premise corrected. v5 was a fabricated mockup that was never implemented, so the renderer is not a regression from it. v9 is the baseline — a real, anonymized client report showing what the module produces today. v10 is defined as v9 plus whatever of v5 is still wanted.

Success: feature-by-feature check of what `report-design-system.md` and the samples specify against what the current renderer actually produces. Output is a gap list — implemented / partial / missing — per feature. That list is the input for building v10.

Status: half done. Both inventories exist in `docs/validation/effort-03-report-vs-code.txt`, v5 as `[1]`-`[17]` and v9 as `[V9-1]`-`[V9-17]`. Two passes remain: diff the two inventories, then check both samples and the renderer against the design system and the recorded Known Drift items D1-D4.

### 4. docs/plans/*.md vs code (implementation status)
Success: each plan checked against code for actual implementation status — not-started / partial / complete — per named piece of work inside the plan, not just file-level. Line-number anchors re-verified before resuming work, since a single unrelated code edit invalidates every reference below it in the plan.

Decision rule:
- Complete → archive the plan file, record the outcome in working-summary.md.
- Partial → split done from remaining; keep only the remaining work active in docs/plans/.
- Not started → stays active in docs/plans/, no working-summary entry yet.

Respect dependency ordering stated inside the plans themselves (e.g., roastable-consolidation-plan.md must land before advisory-drilldown-plan.md) — don't archive or summarize members of a dependency chain out of order.

Current findings:
- todo-privaccess-output.md — partial (2/4 functions have -OutputPath: Get-PrivilegedGroupMembership, Find-AdminCountOrphan done; Find-KerberoastableAccount, Find-ASREPRoastableAccount not).
- roastable-consolidation-plan.md — not started.
- advisory-drilldown-plan.md — not started, blocked on roastable-consolidation-plan.md.

### 5. gpo-review-workflow.md + research-brief.md + research-brief-draft.md — extraction pass
Success: each file read for decision-relevant content — anything that actually informed a mechanism decision, a domain-spec entry, or the report's design. That content gets mapped to the ADR or CONTEXT.md entry it belongs in (source paragraph → destination).

### 7. dormant-account-standard.md — citation verification
Success: `/research` pass reverifying the PCI DSS v4.0.1, NIST 800-53, and MS 2026 guidance citations are still current and accurately represented. Output: per-citation confirmed / outdated / needs-update flag.

### 8. working-summary.md vs code
Success: every claimed decision and every complete-or-planned item in working-summary.md checked against current `Monarch.psm1` + `tests/Monarch.Tests.ps1`, marked valid / stale / wrong. Nothing carried into CONTEXT.md or an ADR until it clears this check. GitHub issues not yet parsed into working-summary get reconciled into it in the same pass, not treated separately.

---

## Final Step — docs/ tidy-up (runs after every validation effort above closes)

Not a validation effort — a consolidation pass toward the target tree below. Git is the archive: `git log`, tags, and closed GitHub issues already give searchable, permanent history. A hand-maintained `docs/archive/` folder duplicates that badly and just stays in everyone's checkout. `docs/` should hold only current, load-bearing truth — everything superseded, resolved, or absorbed elsewhere gets folded into CONTEXT.md / docs/adr/, leaving the source file redundant.

Never delete anything — flagging a file as redundant is as far as this plan goes; removal is the user's call.

**Target tree.** This is the end state, after every validation effort closes and this cleanup
lands. It is not the current tree. The move-and-rename pass of 2026-08-20 produced an
intermediate tree that still holds `docs/plans/` and `docs/archive/`; both are retired here.

```
/
├── README.md
├── AGENTS.md                    ← short. Sitemap for what's actually left below.
├── CONTEXT.md
├── CODING_STANDARDS.md          ← moved up from docs/ on 2026-08-20
├── AGENT_CONDUCT.md             ← portable agent rules
├── CONTRIBUTING.md
├── skills/                      ← deterministic tools an agent runs, one folder each
└── docs/
    ├── adr/                     ← every real decision, one file each
    ├── agents/                  ← skill infra, already correct, untouched
    ├── reference/               ← standing how-to and AD research, survives
    │   └── ad-research/
    ├── validation/              ← evidence from the doc-versus-code efforts
    ├── phases/                  ← optional, 3 small files, north-star scope
    └── sample-report/
```

**Superseded, not relocated:**

- `docs/archive/`, `docs/plans/` — directories retired. Completed work: content already captured by git history, source file becomes redundant. Future work: GitHub issues via to-spec/to-tickets, never a docs/plans file to begin with.
- `domain-specs.md` — dissolved. Rationale that matters → ADR/CONTEXT. Contract catalog → redundant with code, or PowerShell comment-based help inside `Monarch.psm1` if it needs a home at all.
- `gpo-review-workflow.md`, `research-brief.md`, `research-brief-draft.md` — **superseded, this line is wrong.** These now live under `docs/reference/` and survive. Decision-relevant content still gets extracted into the ADR it informed, but the source files stay. AD research carries breadth an ADR must not absorb: attack paths, community consensus, and places where Microsoft's own guidance is contested. The "git is the archive" argument above holds for superseded plans. It fails for rewritten research, which never existed in git history, so there is nothing to recover.
- `checklists.md` — becomes a GitHub issue (Phase 3 backlog), not a live file.
- `mechanism-decisions.md` — dissolved into `docs/adr/`, one decision per file.
- `working-summary.md`, `working-plan.md` (this file) — become redundant once `CONTEXT.md` + `docs/adr/` exist and this cleanup lands. Scratch scaffolding for the migration, not permanent residents.

---

## Notes

- validation efforts are independent — different code areas, no required order, can run in parallel.
- Bucket A (mechanism-decisions.md) and Bucket G (domain-specs.md) do not convert to ADR/CONTEXT format until Validation Effort 2 clears them.
- Bucket C/D (report-design-system.md, the report samples) do not get treated as settled until Validation Effort 3 produces the gap list.
- The move-and-rename pass ran on 2026-08-20. The target tree above reflects it.
- ADR conventions live in `docs/agents/domain.md`, which is the file the engineering skills read before they explore. 
- ADRs get written inside grilling sessions as decisions resolve, not by a numbered effort here. ADR-0000 is the thesis and is written first.
- Every unit of this work runs in its own session. Efforts are independent and may overlap, but each one ends in a file the user reads before its findings get converted.
- Open item, blocks ADR conversion of two mechanism-decisions.md sections: the hold period is written three ways. `mechanism-decisions.md` line 23 says 30, configurable 30-365. Its Monitoring Phase Guidance section says 30-90. `domain-specs.md` states a bare 30-day minimum. See `docs/validation/effort-02-specs-vs-code.txt` lines 52 and 87.
- Open item: `effort-03-report-vs-code.txt` defines Known Drift D1, D2, and D3. Its own closing line and this file's Effort 3 entry both say D1-D4. The issue list in the same file starts at I2 with no I1. Whether items were dropped or the numbering slipped is unresolved and needs the author.

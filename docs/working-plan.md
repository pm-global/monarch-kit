# Working Plan

Document categorization for `docs/` root, plus the validation efforts required before any of it is trusted enough to convert, cite, or build against.

---

## Document Buckets

### A. Decision record — convert to ADR
- **mechanism-decisions.md** — internal hard-to-reverse decisions with rationale (config model, thresholds, extensionAttribute choices). Convert to `docs/adr/`, one file per decision, once cleared by Validation Effort 2.

### B. Normative standard — not a decision, not user-facing, stays standalone
- **dormant-account-policy.md** — PCI DSS / NIST 800-53 / MS compliance standard the code must conform to. External authority, not an internal choice, so it doesn't become an ADR. Standards move slowly; re-verify citations occasionally, otherwise stable.

### C. Living standards doc — peer to CODING_STANDARDS.md
- **design-system.md** — visual/report standard. Needs an improvement pass plus a gap audit against the current report implementation (Validation Effort 3).

### D. Reference implementation — not an archive
- **docs/sample-report/demo_report_v5.html** — the worked example design-system.md was extracted from. Currently ahead of the implemented report, not behind it: a feature checklist for report work, not dead weight.

### E. Future-phase development research — dormant until then
- **checklists.md** — seed material for Phase 3 (interactive wrapper). Not user-facing. No action until Phase 3 starts, then feeds that phase's spec/ticket work.

### F. Design-rationale source — still live
- **gpo-review-guide.md** — shaped which discovery checks exist and what data the report surfaces. Re-consult on any future report or discovery change, same role mechanism-decisions.md plays for thresholds.

### G. Needs disassembly — no single verdict yet
- **domain-specs.md** — two things stapled together: a function/contract catalog (may now be redundant with implemented code, given the minimal-comment code style) and non-obvious rationale notes (real institutional knowledge with no other home). Requires a line-by-line sort — not a file-level decision — before any verdict on what survives and where it goes (CONTEXT.md, an ADR, or nowhere).

### H. Instructional — no change needed
- **deployment-guide.md** — environment setup and deploy steps.

### I. Implementation plan — status tracked in Validation Effort 4
- **docs/plans/todo-privaccess-output.md**
- **docs/plans/roastable-consolidation-plan.md**
- **docs/plans/advisory-drilldown-plan.md**

### Historical research — archive-adjacent, already accurate
- **gap-research.md**
- **initial-research.md**

### Out of scope for this pass
- **working-summary.md** — separate validation effort, tracked below.
- **CODING_STANDARDS.md** — already known-good, excluded from this review.

---

## Validation Efforts

More efforts may be appended here (5, 6, ...) as they're identified. The Final Step below always runs last, after every effort in this section closes — inserting a new numbered effort never requires renumbering it.

### 2. domain-specs.md + mechanism-decisions.md vs code
Success: every entry in both files checked against the implemented function or mechanism it describes.
- mechanism-decisions.md entries confirmed still true → eligible for ADR conversion (Bucket A).
- domain-specs.md entries sorted into (a) redundant with code, safe to drop, or (b) non-obvious rationale with no other home, migrated to CONTEXT.md or an ADR before the file is touched further (Bucket G).

### 3. design-system.md + docs/sample-report/demo_report_v5.html vs report-generation code
Success: feature-by-feature comparison of what the spec and reference implementation call for against what the current report renderer actually produces. Output is a gap list — implemented / partial / missing — per feature. That list is the input for deciding whether to revise design-system.md, redevelop the report to match it, or both.

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

### 5. gpo-review-guide.md + gap-research.md + initial-research.md — extraction pass
Success: each file read for decision-relevant content — anything that actually informed a mechanism decision, a domain-spec entry, or the report's design. That content gets mapped to the ADR or CONTEXT.md entry it belongs in (source paragraph → destination).

### 7. dormant-account-policy.md — citation verification
Success: `/research` pass reverifying the PCI DSS v4.0.1, NIST 800-53, and MS 2026 guidance citations are still current and accurately represented. Output: per-citation confirmed / outdated / needs-update flag.

### 8. working-summary.md vs code
Success: every claimed decision and every complete-or-planned item in working-summary.md checked against current `Monarch.psm1` + `tests/Monarch.Tests.ps1`, marked valid / stale / wrong. Nothing carried into CONTEXT.md or an ADR until it clears this check. GitHub issues not yet parsed into working-summary get reconciled into it in the same pass, not treated separately.

---

## Final Step — docs/ tidy-up (runs after every validation effort above closes)

Not a validation effort — a consolidation pass toward the target tree below. Git is the archive: `git log`, tags, and closed GitHub issues already give searchable, permanent history. A hand-maintained `docs/archive/` folder duplicates that badly and just stays in everyone's checkout. `docs/` should hold only current, load-bearing truth — everything superseded, resolved, or absorbed elsewhere gets folded into CONTEXT.md / docs/adr/, leaving the source file redundant.

Never delete anything — flagging a file as redundant is as far as this plan goes; removal is the user's call.

**Target tree:**

```
/
├── README.md
├── AGENTS.md                    ← short. Sitemap for what's actually left below.
├── CONTEXT.md
├── CODING_STANDARDS.md
├── CONTRIBUTING.md
└── docs/
    ├── adr/                     ← every real decision, one file each
    ├── agents/                  ← skill infra, already correct, untouched
    ├── design-system.md         ← or folded into CODING_STANDARDS.md, one standards doc
    ├── dormant-account-policy.md
    ├── deployment-guide.md      ← only if genuinely distinct from README's install section
    ├── phases/                  ← optional, 3 small files, north-star scope
    └── sample-report/
```

**Superseded, not relocated:**

- `docs/archive/`, `docs/plans/` — directories retired. Completed work: content already captured by git history, source file becomes redundant. Future work: GitHub issues via to-spec/to-tickets, never a docs/plans file to begin with.
- `domain-specs.md` — dissolved. Rationale that matters → ADR/CONTEXT. Contract catalog → redundant with code, or PowerShell comment-based help inside `Monarch.psm1` if it needs a home at all.
- `gpo-review-guide.md`, `gap-research.md`, `initial-research.md` — decision-relevant content extracted into the ADR it informed, source file becomes redundant after.
- `checklists.md` — becomes a GitHub issue (Phase 3 backlog), not a live file.
- `mechanism-decisions.md` — dissolved into `docs/adr/`, one decision per file.
- `working-summary.md`, `working-plan.md` (this file) — become redundant once `CONTEXT.md` + `docs/adr/` exist and this cleanup lands. Scratch scaffolding for the migration, not permanent residents.

---

## Notes

- validation efforts are independent — different code areas, no required order, can run in parallel.
- Bucket A (mechanism-decisions.md) and Bucket G (domain-specs.md) do not convert to ADR/CONTEXT format until Validation Effort 2 clears them.
- Bucket C/D (design-system.md, demo_report_v5.html) do not get treated as settled until Validation Effort 3 produces the gap list.

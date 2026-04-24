# Step 9 — Integration Validation: Handoff

**Model: Sonnet**

## Context to load
- `dev-guide.md` (project root, not docs/)
- `New-MonarchReport` function in `Monarch.psm1` (lines ~2417–2960)
- `Tests/Monarch.Tests.ps1` — Pester 5+ test suite
- This file

---

## State at handoff

**Tests:** 292 passing, 0 failing.

**Completed passes:**

### 9A — Full suite run ✓

### 9B — Integration test context ✓
Retired partial `'Advisory extraction'` context (10 tests), added full 8-domain
`'Integration — all domains with findings'` context (31 tests).

Bug fixed: `foreach ($dc in $r.DCs)` in `Get-EventLogConfiguration` advisory loop
was clobbering the `$dc` header variable — renamed to `$dcEntry`.

### 9C-A — File tree v5 alignment ✓
Replaced flat-div/inline-padding tree with v5 semantic structure:
`.group` > `.folder` + `.tree-children` > `.tree-item`. Sub-path shown as display
text. Root-level files render as bare `.tree-item`. Added `.tree-children` CSS rule.

---

## v5 Alignment — outstanding items (todos for future steps)

These divergences were identified by comparing against `docs/report-v5.html`.
Items 1 and 3 are in the plan to fix (see below). Items 2 and 4 are todos.

1. **Stats bar 3 vs 4 pills** — intentional simplification, no action needed
2. **Expandable details/tables** — TODO: `<details>/<summary>` blocks with data tables
   for replication links, FSMO roles, group memberships etc. v5 includes these;
   Phase 1 emits none. Needs a dedicated step.
3. **Dead CSS** — see Pass 9C-B below
4. **Action hints in critical cards** — TODO: `.card .action-hint` is defined in CSS
   but never emitted. v5 shows an optional second line on critical cards. Needs a
   dedicated step.

---

## Remaining passes

### 9C-B — Trim dead CSS ✓
Removed `summary{list-style:none}summary::-webkit-details-marker{display:none}` from
`@media print` block. Kept `.card .action-hint` (see CLAUDE-DEV-PLAN TODO-1).
292 tests passing.

### 9D — Real-domain run ✓
Reviewed live HTML from LIGHT.local domain (2026-04-06). All checklist items passed.
Fixes applied during review:
- Replaced em dashes and double dashes with colons (title) and parentheses (advisory qualifiers)
- Fixed CSS `::before` escape on `.tree-item` (`\2500 ` → `\2500\20 `) for proper spacing
292 tests passing.

---

## COMPLETE
All passes done. 292 tests passing. Report validated against live domain.

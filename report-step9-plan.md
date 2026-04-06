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

**File:** `Monarch.psm1`, `New-MonarchReport`, CSS string.

Audit the full CSS string (~lines 2665–2719) and remove any rules whose selectors
are never emitted by the HTML generation code. Do not rely on this handoff's analysis —
read the CSS string and the HTML generation code yourself to confirm what is and isn't
used before removing anything.

Known candidate (verify before removing):
- `summary{list-style:none}summary::-webkit-details-marker{display:none}` in the
  `@media print` block (~line 2718) — for `<details><summary>` elements that Phase 1
  never emits

Keep `.card .action-hint` — not yet emitted but required before remediation (see CLAUDE-DEV-PLAN TODO-1).

No new tests needed. Run full suite to confirm 292 still pass.

---

### 9D — Real-domain run

The user will run `Invoke-MonarchDiscovery` against a live Windows domain and provide
the generated HTML. This pass cannot be completed by an agent alone — wait for the user.

**When output is provided, review for:**
- Any `@{` or `System.Object[]` in header, metrics, or advisory text
- Empty/null interpolations in advisory descriptions
- Metrics strips with blank values for functions that ran successfully
- Advisory text that reads incorrectly against real data
- File tree rendering correctly for the actual output structure
- Stats bar counts matching actual critical/advisory card counts

For each issue: fix in `Monarch.psm1`, add regression test in `Tests/Monarch.Tests.ps1`
using the existing mock patterns in `Describe 'New-MonarchReport'`.

---

## Key conventions

- CSS is a single concatenated string in `New-MonarchReport` (~lines 2665–2719)
- Advisory/critical generation: `foreach ($r in $resultsList)` switch (~lines 2543–2648)
- Domain metrics strips: domain-section loop switch (~lines 2780–2870)
- `$dc` (header var, set ~line 2457) must not be reused as a loop variable anywhere
- Tests: `-ModuleName Monarch` mocking; all AD cmdlets mocked; `$TestDrive` for output dirs
- Run: `Invoke-Pester ./Tests/Monarch.Tests.ps1 -Output Minimal`

## Done when
- 9C-B complete and suite passes at 292
- 9D real-domain output reviewed, issues fixed and tested

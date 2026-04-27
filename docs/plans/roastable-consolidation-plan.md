# Roastable Advisory Consolidation — Plan

## Problem Statement

The Discovery Report renders Kerberoastable and AS-REP roastable findings as two separate advisories. A domain admin's remediation pass treats both as one workstream — same password rotation, same Protected Users move, same RC4-vs-AES verification — diverging only on a single per-row attribute fix (SPN removal vs `DONT_REQ_PREAUTH` reset). Splitting the report card forces the reader to mentally re-merge findings before triage. This plan consolidates the two advisories into one Privileged Access advisory while keeping the separate discovery functions, return contracts, and `roastable-accounts.csv` shape unchanged.

This plan lands first. The advisory drilldown plan currently references the two-advisory shape and must be revised before its implementation begins.

---

## Engineering & Design Decisions

### D1. Discovery functions and CSV combiner unchanged
`Find-KerberoastableAccount` (`Monarch.psm1:946`) and `Find-ASREPRoastableAccount` (`Monarch.psm1:1011`) keep return contracts. `roastable-accounts.csv` shape (`Monarch.psm1:3162-3190`) unchanged — already merged with `ThreatType` discriminator. Programmatic consumers are unaffected.

### D2. Merge happens via post-hoc lookup, not in-loop deferred state
The advisory build at `Monarch.psm1:2551-2553` runs one `foreach` over `$resultsList` with a `switch ($r.Function)`. Two existing case bodies — `'Find-KerberoastableAccount'` (`:2582-2585`) and `'Find-ASREPRoastableAccount'` (`:2606-2613`) — are deleted. Combined advisory is constructed after the loop ends via `$resultsList | Where-Object { $_.Function -eq 'X' } | Select-Object -First 1` lookups.

**Why:** This is the existing convention in the same codebase. Used at `Monarch.psm1:2588` (Test-ProtectedUsersGap cross-lookup), `:2820` (PrivilegedAccess metric panel), `:3164-3165` (CSV combiner — exactly the same two functions, two lines above where this merge block lands). Mid-loop deferred state would introduce a novel pattern when an existing one fits. Two extra scans over `$resultsList` (~50 entries max) is irrelevant cost.

**Rejected:** Defer-and-merge with `$kerb`/`$asrep` locals captured inside switch case bodies. Functional, but introduces architectural variance — readers must learn two patterns where one suffices.

### D3. Description format
Combined advisory description, exact format:

```
$total roastable accounts ($k Kerberoast, $a AS-REP, $priv privileged)
```

Type order: Kerberoast first, AS-REP second. Matches code section order (`:2582` then `:2606`) and CSV row authoring order (`:3170` then `:3179`). All three counts always rendered, including zeros — predictable parseable shape across runs.

`AS-REP` is hyphenated to match the existing AS-REP description text at `:2610`. Pluralization is left untouched (`1 roastable accounts` is irrelevant; existing advisories don't fix this).

### D4. Hide-on-zero
Combined advisory is emitted only when `($k > 0) OR ($a > 0)`. Both-zero produces no advisory. Showing a zero-count finding is a false positive per the project's Informational Minimalism principle (`dev-guide.md:84-93`).

### D5. Failure-state placeholder
Discovery functions can fail in three observable ways: function did not run (no entry in `$resultsList`), function ran with a complete failure (entry present, full Warnings, zero Accounts), function ran with partial failure (entry present, non-empty Warnings, possibly partial Accounts).

Rule, applied per source independently:

```
$kerbCount = if ($null -eq $kerbResult) { '?' }
             elseif ($kerbResult.Warnings.Count -gt 0) { '?' }
             else { $kerbResult.TotalCount }
```

Same for `$asrepCount`. The `IsPrivileged` count: if either source resolves to `?`, the privileged count is also `?`. The total count: if either source is `?`, total is `?`.

**Why `?`:** ASCII-only single-character signal. Distinguishable from a numeric zero. Survives terminal, HTML, and CSV consumers without escaping. The `Silent` execution mode hides console progress — a placeholder in the report is the only signal to a non-watching admin that a check did not produce an intelligible result.

**Both-source failure:** if both sources resolve to `?` and there is no other signal, no advisory is emitted. With nothing known, there is nothing to surface here. The orchestrator's `Failures` array remains the authoritative record of execution failures; this plan does not extend it.

**Out of scope:** extending the `?` placeholder pattern to other advisories. Tracked separately. A future plan adds a critical advisory listing all functions that failed to produce intelligible results — see `docs/raw/todo-failed-check-surfacing.md`.

### D6. Severity rule
Combined privileged count `> 0` → `$criticals`. Combined privileged count `= 0` → `$advisories`. Combined privileged count `= '?'` → `$advisories` (cannot prove critical without data; the placeholder signals the unknown).

Matches the existing per-type severity rule (`:2583`, `:2609-2612`).

### D7. PrivilegedAccess metric tile
Replace the existing tile at `Monarch.psm1:2820-2821`:

```
before:  Kerberoastable (privileged): N
after:   Roastable (privileged): N
```

Where `N` is the merged privileged count. Same merge math as the advisory description. Same `?` placeholder rule. Single source of truth — tile and advisory cannot diverge.

### D8. Combined advisory shape
Object pushed to `$criticals` or `$advisories`:

```
[PSCustomObject]@{
    Domain         = 'PrivilegedAccess'
    DisplayDomain  = 'Privileged Access'
    Description    = "$total roastable accounts ($k Kerberoast, $a AS-REP, $priv privileged)"
}
```

No `DiagnosticHint` — neither current case sets one. No drilldown spec — the advisory drilldown plan attaches one when it revises.

### D9. Function-name string constants
Three string literals are bound to the discovery functions: `'Find-KerberoastableAccount'`, `'Find-ASREPRoastableAccount'`. They appear at the new merge block plus existing sites (`:2820`, `:3099-3100`, `:3164-3165`). Locked to local `$KerbFn` / `$AsrepFn` variables at the top of the merge block with a comment pointing to the discovery function definitions. A test asserts that the orchestrator output contains a result whose `Function` matches each constant exactly — fails loudly on rename.

**Why:** the merge silently hides one of the two threat signals if a future contributor renames a discovery function without updating the lookup string. Stale lookup → `$null` → permanent `?` placeholder, indistinguishable from a transient runtime failure.

---

## Mechanism

**Advisory build phase (`Monarch.psm1:~2551-2700`):**
1. Loop body cases for `'Find-KerberoastableAccount'` and `'Find-ASREPRoastableAccount'` are deleted.
2. After the `foreach ($r in $resultsList)` loop closes, a new merge block runs.
3. Merge block:
   - Looks up both function results via `Where-Object | Select-Object -First 1`.
   - Resolves `$kerbCount`, `$asrepCount`, `$privCount`, `$total` with the placeholder rule (D5).
   - If both resolved to known zero or both placeholder with no other findings → return without emitting.
   - Else builds the description string (D3) and pushes the combined advisory into `$criticals` or `$advisories` per D6.

**Metric tile phase (`Monarch.psm1:~2820-2821`):**
1. `$kerb` lookup is preserved.
2. New `$asrep` lookup added.
3. Tile string changed to `Roastable (privileged): N`, where `N` uses the merge math from D5/D7.

**State changes:** none. Read-only report rendering. No file mutation outside the existing report HTML output. CSV combiner untouched.

**Failure behavior:** Discovery function failure is observable to the merge block via `$null` lookup or non-empty `Warnings`. Merge block degrades gracefully via `?` placeholder. Renderer never throws on missing or partial source data.

---

## Invariants

These must remain true after the change. Each becomes a test target.

1. `Find-KerberoastableAccount` and `Find-ASREPRoastableAccount` return contracts unchanged (covered by existing function-level tests at `tests/Monarch.Tests.ps1:2241,2313`).
2. `roastable-accounts.csv` schema unchanged: `ThreatType, SamAccountName, DisplayName, IsPrivileged, Enabled, SPNs, PasswordAgeDays`.
3. Exactly one roastable advisory is emitted when at least one source has a non-zero, non-placeholder count.
4. Zero advisories are emitted when both sources are known zero, or both sources are `?`.
5. The advisory bucket is `$criticals` if and only if combined privileged count is a positive integer.
6. The PrivilegedAccess domain section renders exactly one `Roastable (privileged): N` tile, never two, never `Kerberoastable (...)` plus `AS-REP (...)`.
7. The Description and tile use the same merge math — they cannot disagree on counts within a single report run.
8. A discovery function rename without a corresponding string update fails the lookup-constant test.

---

## Risks and Mitigations

**R1. Drilldown plan staleness.** `docs/plans/advisory-drilldown-plan.md` references two roastable advisories (D8.4, D8.5) with separate column specs and CSV map entries. After this plan lands, those entries describe an advisory shape that no longer exists.
**Mitigation:** the drilldown plan is revised before its implementation begins, collapsing the two entries into one. Sequencing per `docs/raw/dropdown-plan-triage.md:482-484`. Implementation of either plan does not start until the other is design-locked.

**R2. Function rename invalidates lookup silently.** A future contributor renames `Find-KerberoastableAccount` or `Find-ASREPRoastableAccount` without updating the merge block string constant. Stale lookup returns `$null`, the merge emits `? Kerberoast` (or AS-REP) indefinitely.
**Mitigation:** D9 — string constants bound to named locals with a comment. A test asserts that the orchestrator output contains a result for each function name exactly. Rename without test update fails CI.

**R3. Both-source failure produces silent gap.** If both discovery functions fail entirely (both `?`), no advisory is emitted. A `-Silent` automation run loses the only on-page signal that the roastable check did not produce results.
**Mitigation accepted within plan scope:** the orchestrator `Failures` array remains the authoritative execution-failure record. The Discovery Report top-line check count (`X/Y checks`) reflects the failure. **Mitigation deferred:** a critical advisory enumerating all failed checks will close this gap globally — tracked at `docs/raw/todo-failed-check-surfacing.md`. That feature subsumes the single-advisory remedy and is not built here to avoid scope creep.

**R4. Merge math drift between tile and advisory.** Two consumers of the same merge logic (D7 tile, D8 advisory) could diverge if logic is duplicated.
**Mitigation:** lift the merge math into a single internal helper invoked by both sites, or (lighter touch) keep the math inline at both sites and assert consumer parity in tests. Decision: inline at both sites — the math is short, and a helper with two callers in the same function is a one-callsite-equivalent abstraction. Parity is asserted by a test that runs a single mocked result set through both renders and checks the count strings match.

---

## Reviewer Findings

### R1 — Staff Engineer / Tech Lead

**Finding:** Description format and ordering must be locked before code, not chosen during implementation. **Resolution:** D3 specifies exact format string, type order, and zero-rendering rule.

**Finding:** The advisory build switch is a high-traffic structure. Removing two case bodies must not affect adjacent cases or the per-domain `$dn` resolution. **Resolution:** Delete-only edit. Adjacent cases unchanged. Post-loop merge resolves `$dn = 'Privileged Access'` independently from a static lookup keyed on `'PrivilegedAccess'`, matching `:2540` map.

### R2 — SRE / Production Engineer

**Finding:** No state mutation. Report rendering is idempotent — running twice on the same `$resultsList` produces identical output. Documented as invariant 3.

**Finding:** Partial failure path exists (one source fails, other succeeds). **Resolution:** D5 placeholder makes the partial state diagnosable on the page. Failure does not propagate to render exception.

### R3 — Engineering Manager

**Finding:** This change adds no new public function, no new infrastructure, no new abstraction layer. It deletes two switch cases and adds one post-loop block plus one tile rename. Infrastructure-to-feature ratio improves.

**Finding:** Drilldown plan staleness is a completion-discipline concern. **Resolution:** R1 in Risks. Sequencing locked per triage. Drilldown plan revision is the next plan, not concurrent work.

### R4 — AI/ML Agent Tooling Engineer

**Finding:** Future agent reading the orchestrator may search for `Find-Roastable*` and find nothing because the discovery function names are unchanged. **Resolution:** D9 binds function-name strings to clearly named locals (`$KerbFn`, `$AsrepFn`) at the top of the merge block with a comment pointing to the discovery function definitions.

**Finding:** `?` placeholder must not be confused with a literal account count by an agent or a CSV consumer. **Resolution:** Placeholder lives only in the rendered HTML Description and the rendered metric tile. CSV row data and discovery function return contracts use real values or empty arrays — no placeholder leaks into structured output. Documented as part of D5 and invariant 2.

### R5 — Adversarial Design Critic

**Finding:** The original adversarial concern was multi-domain forest scope. Reframed: monarch-kit targets 100-10,000 user single-domain shops. Multi-domain forests run in enterprise tier with dedicated security tooling (BloodHound Enterprise, Tenable, Quest, Semperis) — not the audience. Scalar deferred-state architecture is appropriate; speculative defense against multi-domain invocation would be infrastructure for a customer segment the module does not serve.

**Reframed finding:** the load-bearing assumption is that the function-name strings used at the merge block exactly match the strings produced by `$result.Function`. A rename in either direction silently demotes the merge into a permanent `?` placeholder with no exception, no warning, no log line. **Resolution:** D9, R2 in Risks. A test asserts that the lookup string for each function returns a non-null result against a baseline `$resultsList`.

---

## Pass Sequence

Tests are written and updated before any implementation edit. Per `dev-guide.md` LLM4TDD: write tests first, verify they fail correctly against unchanged code, then implement until they pass.

1. Pass 1 — Delete the four stale assertions at `tests/Monarch.Tests.ps1:3986`, `:3990`, `:4203`, `:4208`. Add new tests covering every invariant in the Invariants section:
   - Both sources non-zero, no privileged → advisory bucket, exact description string.
   - Privileged in either source → critical bucket.
   - Single-source case (Kerberoast-only) → combined advisory shows `0 AS-REP`.
   - Single-source case (AS-REP-only) → combined advisory shows `0 Kerberoast`.
   - Both-zero → no advisory, no tile rendered for roastable count.
   - One source `$null` (missing from `$resultsList`) → `?` placeholder applied to that count, to total, and to privileged.
   - One source has non-empty `Warnings` → `?` placeholder applied to that count, to total, and to privileged.
   - Both sources `?` → no advisory emitted.
   - Lookup-string constant test (D9, R2): mocked baseline `$resultsList` resolves both function-name lookups to non-null.
   - Tile/advisory parity test (R4 in Risks): single mocked result set produces matching count strings in tile and advisory description.
2. Pass 2 — Run the full suite. Confirm new tests fail in the expected ways against the unchanged module — this proves they exercise the right surface and are not vacuously passing.
3. Pass 3 — Delete the two switch case bodies at `Monarch.psm1:2582-2585` and `:2606-2613`. Run the suite; the four-test expected-breakage set is already gone from Pass 1, so any failure here is a regression in adjacent cases — investigate before proceeding.
4. Pass 4 — Add the post-loop merge block. Lock function-name string constants per D9. Update the PrivilegedAccess metric tile per D7. Run the suite until all new tests pass and no other tests regress.
5. Pass 5 — Confirm sample report against BadBlood lab data (`docs/sample-report/report-v7-badblood/`) shows one roastable card with the expected description string. Visual confirmation only; this is not a test target.

---

## Files Touched

- `Monarch.psm1` — advisory build switch (delete two cases), post-loop merge block (new), PrivilegedAccess metric tile (rename + merge math).
- `tests/Monarch.Tests.ps1` — replace four assertions, add invariant coverage.

## Files Not Touched

- `Monarch.psd1` — no export changes.
- `Monarch-Config.psd1` — no new config keys.
- `docs/plans/advisory-drilldown-plan.md` — out of scope; revised in a follow-on plan.
- Discovery function bodies — unchanged.
- CSV combiner at `Monarch.psm1:3162-3190` — unchanged.

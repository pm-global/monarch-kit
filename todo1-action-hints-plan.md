# TODO-1: Action Hints in Critical Cards

## Problem

`.card .action-hint` CSS rule exists (design-system.md) but no card ever emits an action-hint
element. Critical cards show what was found but not what to do about it.

Advisory card hints are tracked separately as TODO-7.

## Current State

Critical findings are generated in `New-MonarchReport` (lines 2528–2664). Each critical is a
`[PSCustomObject]@{ Domain; DisplayDomain; Description }`. There is no `ActionHint` property
and no `<div class='action-hint'>` emitted. The CSS rule at line 2694 is ready.

Critical card rendering is at line 2748:
```
"<div class='card w-critical'><div class='domain-tag'>$($c.DisplayDomain)</div><div class='description'>$($c.Description)</div></div>"
```
The action-hint div goes after `.description`, inside the card, conditional on `$c.ActionHint`.

## Critical Findings That Need Hints

| Finding | Function | Line |
|---------|----------|------|
| Backup age exceeds tombstone lifetime (USN rollback risk) | `Get-BackupReadinessStatus` | 2537 |
| {N} replication links failing | `Get-ReplicationHealth` | 2541 |
| Domain Admin count exceeds critical threshold | `Get-PrivilegedGroupMembership` | 2545 |
| Default domain policy stores passwords with reversible encryption | `Get-PasswordPolicyInventory` | 2620 |
| {N} privileged accounts with SPNs (Kerberoasting risk) | `Find-KerberoastableAccount` | 2565 |
| {N} accounts with pre-auth disabled ({N} privileged) | `Find-ASREPRoastableAccount` | 2591 |
| WeakAccountFlag: reversible encryption (individual accounts) | `Find-WeakAccountFlag` | ~2598 |
| WeakAccountFlag: DES-only Kerberos | `Find-WeakAccountFlag` | ~2599 |
| {N} FSMO role holders unreachable | `Get-FSMORolePlacement` | 2658 |

## Design Decisions

**Tone (resolved):**
- Suggestive for risky actions where blindly following could break things
- Imperative for safe actions
- Reference when detailed steps exist elsewhere

**Data flow (resolved):** Add `ActionHint` property to critical objects. Findings with no hint
omit the property — rendering checks `if ($c.ActionHint)`.

**Conditional hints:** Evaluate per finding in Pass 1. Data already present in the critical
object (counts, specific values) may be worth surfacing inline. Pass 1 decides which findings
benefit from conditional text and what the conditions are.

## Implementation

**Model:** Opus for Pass 1 (domain knowledge, hint text). Sonnet for Pass 2 (code).

### Pass 0 — Tests (write first, confirm they fail before any implementation)

Add to the existing `Describe 'New-MonarchReport'` block in `Tests/Monarch.Tests.ps1`.

**Structural tests — ActionHint presence:**
For each of the 9 critical finding types, mock the relevant function to return a result that
triggers the critical, call `New-MonarchReport`, assert the resulting critical object has a
non-null non-empty `ActionHint`. These tests fail until Pass 2 implements the property.

**HTML rendering — hint present:**
When a critical object has `ActionHint` set, the rendered HTML contains
`<div class='action-hint'>`.

**HTML rendering — hint absent:**
When a critical object has no `ActionHint`, the rendered HTML does not contain `action-hint`.

**Note:** After Pass 1 produces the hint text table, update the structural assertions to match
exact hint strings. The test structure is the gate; exact text is filled in before Pass 2 begins.

### Pass 1 — Research + hint text table (Opus)

Read `docs/checklists.md`, `docs/gpo-review-guide.md`, and Microsoft Security Baselines.
For each of the 9 findings, produce a completed row:

| Finding | Hint text | Tone | Conditional? |
|---------|-----------|------|--------------|
| ... | ... | suggestive / imperative / reference | yes/no — if yes, specify condition and alternate text |

Apply the tone rules. Evaluate each finding for whether data already in the critical object
(count, specific values) would improve the hint. After the table is complete, update the Pass 0
test assertions to match exact hint strings.

### Pass 2 — Implementation (Sonnet)

- Add `ActionHint` to each of the 9 critical object constructions (lines 2537–2658)
- Update card rendering at line 2748 to conditionally append
  `<div class='action-hint'>$($c.ActionHint)</div>` after `.description`
- Run the full test suite. All tests must pass before this pass is considered complete.

## Out of Scope

- CSS changes (`.card .action-hint` rule already exists at line 2694)
- Advisory card hints (TODO-7)
- Linking hints to remediation functions (Plan 2 dependency)

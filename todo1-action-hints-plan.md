# TODO-1: Action Hints in Critical/Advisory Cards

## Problem

`.card .action-hint` CSS rule exists (design-system.md) but no card ever emits an action-hint element. Critical and advisory cards show what was found but not what to do about it.

## Current State

The report generates criticals and advisories in `New-MonarchReport` (lines 2528-2640). Each advisory/critical is a `[PSCustomObject]@{ Domain; DisplayDomain; Description }`. The Description is the only text shown. There is no ActionHint property and no `<div class='action-hint'>` emitted.

There are currently 20+ distinct advisory/critical descriptions across 15 functions (lines 2535-2640). Each would potentially need its own hint text.

## Research Needed (Domain Knowledge -- This Is the Hard Part)

The hint text requires AD administration domain expertise. This is NOT a code question -- it's "what should an experienced admin do when they see this finding?"

For each finding type, research must answer:
1. **What is the standard remediation?** Not monarch-kit-specific -- what does Microsoft recommend? What do experienced admins actually do?
2. **Is the next step obvious or non-obvious?** "15 privileged accounts not in Protected Users" -- obvious next step? No. Adding service accounts with SPNs to Protected Users breaks Kerberos delegation. The hint needs to warn about this.
3. **Is the hint always the same, or conditional on other data?** Example: dormant account hint might differ based on whether the count is 10 vs 1000.
4. **Does the hint reference a tool or process that exists yet?** "Run Suspend-DormantAccount" only makes sense post-Plan-2. Pre-Plan-2 hints should reference manual steps or CSV review.

### Findings That Need Hints (grouped by complexity)

**Likely self-explanatory (may not need hints):**
- Replication links failing/warning
- Audit policy inconsistent across DCs
- DNS forwarder configuration inconsistent

**Clear next step but non-obvious details:**
- Domain Admin count exceeds threshold -- "Review membership, remove unnecessary accounts"
- AdminCount orphans -- "Run `dsacls` to reset inherited permissions, or wait for Plan 2's Remove-AdminCountOrphan"
- Unlinked GPOs -- "Review in GPMC and delete if no longer needed"
- Missing SRV records -- "Check DNS registration on affected DCs, run `dcdiag /test:dns`"
- Event log configuration issues -- "Standardize log sizes and retention across DCs"

**Requires careful wording (risk of bad advice):**
- Privileged accounts not in Protected Users -- MUST warn about SPN/delegation breakage
- Kerberoastable privileged accounts -- "Rotate passwords, consider removing SPNs or using gMSA"
- AS-REP roastable accounts -- "Enable pre-authentication unless there's a documented exception"
- Legacy protocol exposure (NTLMv1/LM) -- "Audit NTLMv1 usage before disabling; disabling without audit can break authentication"
- Reversible encryption / DES-only -- "Disable these flags, but verify no legacy applications depend on them"
- Backup age exceeds tombstone -- critical safety issue, hint must be precise
- No backup tool detected -- "Verify backup coverage; this check only detects common tools"
- Password policy weaknesses -- multiple sub-findings, each with different advice
- Dormant accounts -- depends on count and whether remediation tools exist yet
- Weak security flags -- varies by flag type
- GPOs with non-standard editors -- "Review in 04-Permissions/REVIEW-overpermissioned-gpos.csv"
- DNS scavenging disabled -- "Enable scavenging with appropriate no-refresh/refresh intervals"

### Research Sources

- Microsoft Security Baselines documentation
- `docs/checklists.md` -- existing institutional knowledge in the repo
- `docs/gpo-review-guide.md` -- GPO-specific guidance
- `docs/dormant-account-policy.md` -- dormant account compliance policy
- Microsoft AD security best practices (TierModel, PAW)
- CIS Benchmarks for Windows Server (if accessible)

## Design Decisions

1. **Which cards get hints?** Options:
   - Every card -- consistent but some hints would be trivially obvious ("replication is failing" -> "fix replication")
   - Only cards where the next step is non-obvious or risky -- better signal-to-noise
   - **Recommendation:** Non-obvious and risky findings only. Self-explanatory findings get no hint (silence is success principle).

2. **Tone.** Options:
   - Imperative: "Remove unnecessary Domain Admin members"
   - Suggestive: "Review membership and consider removing unnecessary accounts"
   - Reference: "See docs/checklists.md for review steps"
   - **Recommendation:** Suggestive for risky actions (where blindly following could break things), imperative for safe actions, reference when detailed steps exist elsewhere.

3. **Conditional hints.** Some hints should vary:
   - Protected Users gap: if service accounts with SPNs are in the gap list, warn about delegation breakage
   - Dormant accounts: different hint pre-Plan-2 vs post-Plan-2
   - **Decision needed:** Are conditional hints worth the complexity for v1, or should all hints be static with a general caveat?

4. **Data flow.** Currently advisories are `{ Domain, DisplayDomain, Description }`. Adding hints means either:
   - Adding an `ActionHint` property to the advisory/critical objects
   - Generating hints inline during HTML rendering based on the Description text (fragile)
   - **Recommendation:** Add `ActionHint` property. Cleaner, testable.

## Scope

- Determine which cards get hints (design decision #1)
- Write hint text for each qualifying finding (research deliverable)
- Add `ActionHint` property to critical/advisory objects in finding extraction (lines 2528-2640)
- Emit `<div class='action-hint'>...</div>` inside card markup when ActionHint is present
- Tests for hint presence/absence per card type

## Out of Scope

- CSS changes (`.card .action-hint` rule already exists)
- Linking hints to remediation functions (Plan 2 dependency)
- Conditional hints based on cross-function data (defer to v2 unless trivially simple)

## Implementation

**Model:** Opus for the research pass (domain knowledge, reading docs, writing hint text). Sonnet for the code implementation after hint text is decided.

**Passes:** 2. First pass: research + hint text decisions (produces a hint text table). Second pass: code implementation using the decided text.

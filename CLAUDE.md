# monarch-kit

Active Directory audit and administration suite for mid-market domains.

dev-guide.md defines how to program. This file defines what this project is.

## Module Identity

- **Name:** monarch-kit
- **Target:** mid-market domains (100-10,000 users), experienced IT administrators and LLM agents
- **PowerShell:** 5.1+
- **Structure:** single `.psm1` + `.psd1`
- **Dependencies:** `RequiredModules = @('ActiveDirectory')` -- GroupPolicy and DnsServer are optional (checked at runtime, functions degrade gracefully)
- **Config:** `Monarch-Config.psd1` -- optional, all defaults are built in

## Current State

**Plan 1 (Discovery phase) is complete.** 28 functions, 162 Pester tests, all passing.

| What | Status |
|------|--------|
| Discovery API functions (28) | Complete |
| Orchestrator (`Invoke-DomainAudit -Phase Discovery`) | Complete |
| Report generator (`New-MonarchReport`) | Complete |
| Remediation/Monitoring/Cleanup functions | Plan 2 -- not started |
| Interactive wrapper (`Start-MonarchAudit`) | Plan 3 -- not started |
| Comparison functions (GPO, baseline, CIS) | Plan 4 -- not started |
| OctoDoc extraction + stratagem integration | Plan 5 -- blocked on OctoDoc redesign |

**Only Discovery-phase code exists.** All functions query AD directly. There are no stratagems, no probe composition, no `Invoke-DCProbes`. See `CLAUDE-DEV-PLAN.md` for the full roadmap and implementation details per plan.

## Architecture (As Built)

```
Monarch API functions (28 functions -- direct AD/DNS/GPO queries)
    |
    v
Invoke-DomainAudit (orchestrator -- coordinates Discovery phase)
    |
    v
New-MonarchReport (HTML report from orchestrator results)
```

**DC resolution:** `Resolve-MonarchDC` tries `Get-HealthyDC` if available (legacy from when OctoDoc was a separate module), then falls back to `Get-ADDomainController -Discover`. In practice, the fallback is what runs in most environments.

**OctoDoc history:** OctoDoc was originally a separate sensor module. It was rolled into monarch-kit. `Get-HealthyDC` is the only remaining touchpoint -- called opportunistically with a fallback. Plan 5 is a future extraction of the sensor layer back into a separate module with a proper probe registry and stratagem interface. That work is blocked and not reflected in the current code.

**The boundary principle still holds:** observation logic (what state does AD report?) and interpretation logic (what does that state mean for the audit?) are kept separate in the code even though they live in the same module. When implementing new functions, keep raw AD queries separate from the grading/assessment logic that interprets them.

## Coding Patterns

These patterns apply to every function in the module.

**Parameter convention:**
- All API functions accept `-Server [string]` -- maps 1:1 to AD cmdlet `-Server` parameter
- Can be a DC name, domain FQDN, or omitted for local domain default
- The orchestrator resolves domain to a healthy DC once, then passes it as `-Server` to every function

**Return contract:**
Every public function returns one or more `[PSCustomObject]` with these mandatory properties:

```powershell
[PSCustomObject]@{
    Domain    = 'InfrastructureHealth'   # Functional domain name
    Function  = 'Get-FSMORolePlacement'  # Function that produced this
    Timestamp = (Get-Date -Format o)     # ISO 8601
    Warnings  = @()                      # Always an array, even when empty
    # ... domain-specific properties
}
```

Functions that also produce file output (Export-GPOAudit, Find-DormantAccount) return the structured object AND write files -- the object includes paths to generated files.

**Error handling:**
- Per-cmdlet `-ErrorAction SilentlyContinue` on individual AD calls -- gather as much as possible
- Non-fatal issues go in the `Warnings` array property
- Functions that query multiple independent things (baseline, GPO audit) catch per-section and continue
- Total failure (can't reach AD at all) throws -- the orchestrator catches it and records the failure
- No Write-Host in API functions

**Config access:**
All functions read from `$script:Config` (module-scoped, set at import time). Never from `$Global:` or by re-reading the config file. Access via helper:

```powershell
$threshold = Get-MonarchConfigValue -Key 'DormancyThresholdDays'
```

Falls back to built-in defaults if the key is missing from the config file. See `$script:DefaultConfig` at the top of Monarch.psm1 for all keys and defaults.

**Test strategy:**
- Pester 5+ in `Tests/Monarch.Tests.ps1`, one `Describe` block per function
- All AD/DNS/GPO cmdlets are mocked -- tests run without a domain
- Every function's tests verify: correct properties, correct `Domain` and `Function` values, `Timestamp` populated, `Warnings` is an array
- Functions with business logic get additional tests: exclusion logic, threshold comparisons, config overrides

## Domain / Phase Organization

Functions are organized by domain. Currently only Discovery phase is implemented.

| Domain | Discovery | Remediation | Monitoring | Cleanup |
|--------|-----------|-------------|------------|---------|
| Infrastructure Health | Complete | -- | -- | -- |
| Identity Lifecycle | Complete | Plan 2 | Plan 2 | Plan 2 |
| Privileged Access | Complete | Plan 2 | -- | -- |
| Group Policy | Complete | Plan 2 (backup) | -- | -- |
| Security Posture | Complete | -- | -- | -- |
| Backup & Recovery | Complete | -- | -- | -- |
| Audit & Compliance | Complete | -- | -- | -- |
| DNS (AD-Integrated) | Complete | -- | -- | -- |

The Review phase is human activity (review findings, validate exclusions, approve plan) -- not a function call.

The orchestrator (`Invoke-DomainAudit`) calls functions by phase. See `docs/domain-specs.md` for complete function lists per domain.

## Graduated Confidence

`Get-BackupReadinessStatus` returns a `DetectionTier` indicating how far detection reached:

- **Tier 1** -- tombstone lifetime + Recycle Bin status (always available)
- **Tier 2** -- backup tool detected via service enumeration or event logs (best-effort)
- **Tier 3** -- backup age from vendor integration (opt-in config)

Each tier is more actionable than null. "We checked and it's fine" vs "we found it but can't query it" vs "we found nothing." See `docs/mechanism-decisions.md` for the complete backup detection strategy.

## Conventions

- All public functions return structured objects. No formatted strings as primary output.
- Silence is success. Console output is thin and optional.
- `-WhatIf` support required on all destructive operations.
- Read-only operations never modify state.
- All configurable values use the config layer -- no hardcoded values in function bodies. See `docs/mechanism-decisions.md` for the config model.
- Audit workflow language throughout: "audit cycle", "audit phase" -- never "handover" or "takeover."
- All strings in code and documentation must be ASCII-safe (0x00-0x7F). Non-ASCII characters corrupt silently when transferred between systems.
- All visual output (HTML reports, console formatting) follows `docs/design-system.md`.

## Known Constraints

**lastLogonTimestamp replication floor:** The `lastLogonTimestamp` attribute only updates if the previous value is older than `msDS-LogonTimeSyncInterval` (default ~14 days). The code handles this with a 15-day near-threshold window that cross-validates against per-DC `LastLogon` for accounts close to the dormancy cutoff. This means the dormancy threshold config has an effective floor around 30 days -- below that, false positives from replication lag become likely.

## Reference Documents

- `docs/domain-specs.md` -- eight domains with function lists, return contracts, phase tags
- `docs/mechanism-decisions.md` -- config model, disable date tracking, RID patterns, GPO string matching, backup detection tiers, monitoring guidance
- `docs/checklists.md` -- expert-curated review phase checklists (institutional knowledge, do not regenerate)
- `docs/design-system.md` -- visual language for HTML reports and console output
- `docs/dormant-account-policy.md` -- compliance-aligned dormant account lifecycle policy
- `docs/deployment-guide.md` -- Windows host setup, Pester tests, lab testing, production readiness
- `docs/gpo-review-guide.md` -- GPO review methods and priority guidance

## Prototype Reference

The `docs/archive/00-prototype/` directory contains the previous audit toolkit implementation. It is permanent reference material for understanding existing logic and institutional knowledge. When implementing a function, check the prototype scripts for the corresponding logic.

**The spec wins when prototype code and the domain spec conflict.** The spec is the target state. Prototype code is source material, not authority.

---

**Last reviewed:** 2026-03-26 | **Review quarterly.** Verify domain specs match implemented code, confirm current state section reflects actual plan progress.

# monarch-kit

Active Directory audit and administration suite. Composes OctoDoc stratagems for sensor data and provides the interpretation layer that produces actionable domain answers.

## Module Identity

- **Name:** monarch-kit
- **Depends on:** OctoDoc (sensor layer — `RequiredModules = @('OctoDoc')`)
- **Target:** mid-market domains (100–10,000 users), experienced IT administrators and LLM agents
- **PowerShell:** 5.1+
- **Structure:** single `.psm1` + `.psd1`

## Architecture

```
OctoDoc (sensor layer — separate repo, do not modify)
    ├─ Probe Registry (queryable menu of capabilities)
    ├─ Invoke-DCProbes (executes stratagems, returns raw probe results)
    └─ Get-HealthyDC (health score model)
         ↓
monarch-kit (interpretation layer — this repo)
    ├─ API functions — compose stratagems, interpret results, return structured objects
    ├─ Invoke-DomainAudit — orchestrator, coordinates phases, enforces WhatIf gates
    └─ Start-MonarchAudit — interactive wrapper, menus, guidance, human prompts
         ↓
Reporting Module (future consumer — not in scope)
```

**The boundary is absolute:** OctoDoc observes, monarch-kit interprets. Interpretation logic never lives in the sensor layer.

**Three execution layers:** API functions return objects. The orchestrator (`Invoke-DomainAudit`) coordinates which functions run per phase. The interactive wrapper (`Start-MonarchAudit`) is the admin-facing entry point with menus, checklists, and guidance. See `@docs/domain-specs.md` for the complete three-layer specification.

## Stratagem Model

Monarch functions compose "stratagems" — recipes of which OctoDoc probes to run — and interpret the results.

```powershell
# Compose stratagem
$stratagem = @{
    Name   = 'BackupReadiness'
    Probes = @('WSBackup', 'BackupVendorDetection', 'TombstoneLifetime', 'RecycleBin')
}

# Execute via OctoDoc
$probeResults = Invoke-DCProbes -DCName $DCName -Stratagem $stratagem

# Interpret results (monarch-kit's job)
$tier = Determine-DetectionTier -ProbeResults $probeResults
$gap = Test-TombstoneGap -ProbeResults $probeResults

# Return graded answer
return @{
    Domain        = 'BackupReadiness'
    DetectionTier = $tier
    CriticalGap   = $gap
}
```

OctoDoc runs stratagems. Monarch composes them and interprets results. This boundary is absolute.

## Probe Contract (What OctoDoc Returns)

Every probe returns this shape:

```powershell
@{
    CheckName     = "NTDS"
    Status        = "Healthy"  # Enum: Healthy|Degraded|Stopped|Timeout|Unknown
    Success       = $true      # Target passed the check
    Value         = "Running"  # Raw observed state (never a derived label)
    Timestamp     = [datetime]
    Error         = $null      # Human-readable detail (null when healthy)
    ErrorCategory = $null      # Machine-readable: AccessDenied|NotFound|Timeout|ProbeError|null
    ExecutionTime = 87         # Duration in ms
}
```

- `Value` is always raw observed state — what the OS/service actually reported
- `ErrorCategory` distinguishes target failure from probe failure (agents branch on this)
- `Error` is null when healthy — agents checking `if ($result.Error)` rely on this

## Graduated Confidence

When a detection has multiple tiers, return `DetectionTier` indicating how far detection reached. Partial information reduces blast radius even when it doesn't eliminate uncertainty.

Three distinct states: "we checked and it's fine" vs "we found it but can't query it" vs "we found nothing." Each tier is more actionable than null. Backup readiness is the canonical example — see `@docs/mechanism-decisions.md` for the complete three-tier specification.

## Domain / Phase Organization

Functions are organized by domain (what they do) and tagged by phase (when they run).

| Domain | Discovery | Review | Remediation | Monitoring | Cleanup |
|--------|-----------|--------|-------------|------------|---------|
| Infrastructure Health | ✓ | | | | |
| Identity Lifecycle | ✓ | | ✓ | ✓ | ✓ |
| Privileged Access | ✓ | | ✓ | | |
| Group Policy | ✓ | | ✓ (backup) | | |
| Security Posture | ✓ | | | | |
| Backup & Recovery | ✓ | | | | (context) |
| Audit & Compliance | ✓ | | | | |
| DNS (AD-Integrated) | ✓ | | | | |

The Review phase is human activity (review findings, validate exclusions, approve plan) — not a function call.

The orchestrator (`Invoke-DomainAudit`) calls functions by phase. See `@docs/domain-specs.md` for complete function lists per domain.

## Conventions

- All public functions return structured objects. No formatted strings as primary output.
- Silence is success. Console output is thin and optional.
- `-WhatIf` support required on all destructive operations.
- Read-only operations never modify state.
- All configurable values use the config layer — no hardcoded values in function bodies. See `@docs/mechanism-decisions.md` for the config model.
- Audit workflow language throughout: "audit cycle", "audit phase" — never "handover" or "takeover."
- All visual output (HTML reports, console formatting) follows @docs/design-system.md — spacing, type scale, color, and component grammar.

## Three-Tier Output Model

Three levels of interpretation serve different consumers:

1. **Raw probe results** — array of probe contract objects, no interpretation. For custom investigation.
2. **Orchestrated health score** — `Get-HealthyDC` returns best DC by health score. For DC selection.
3. **Interpreted domain answers** — monarch-kit functions return graded answers with DetectionTier and DiagnosticHints. For audit workflows.

Not redundant — different questions for different consumers.

## Reference Documents

- `@docs/domain-specs.md` — eight domains with function lists, return contracts, phase tags, stratagem composition
- `@docs/mechanism-decisions.md` — config model, disable date tracking, RID patterns, GPO string matching, backup detection tiers, monitoring guidance
- `@docs/checklists.md` — expert-curated review phase checklists (institutional knowledge, do not regenerate)

## Prototype Reference

The `docs/archive/00-prototype/` directory contains the previous audit toolkit implementation. It is permanent reference material for understanding existing logic and institutional knowledge. When implementing a function, check the prototype scripts for the corresponding logic to understand what was built and why.

**The spec wins when prototype code and the domain spec conflict.** The spec is the target state. Prototype code is source material, not authority.

---

**Last reviewed:** 2026-03-26 | **Review quarterly.** Verify domain specs match implemented code, confirm OctoDoc probe registry still matches stratagem compositions.

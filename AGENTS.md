# monarch-kit

Active Directory audit and administration suite for mid-market domains (100-10,000 users).

`dev-guide.md` defines *how* to program. This file defines *what* this project is.
Contribution process and merge requirements: see `CONTRIBUTING.md`.

## Module Identity

- **PowerShell 5.1+** module (`Monarch.psm1` + `Monarch.psd1`)
- Core dependency: ActiveDirectory module (GroupPolicy and DnsServer are optional)
- Target users: experienced IT administrators and LLM agents

## Current State

Phase 1 (Discovery) complete — see `docs/archive/phase-01-discovery/` and git release tags.
Phases 2-4 defined in `docs/phases/`. Active work tracked in GitHub milestones.
Current phase: 2. Active plans: `docs/plans/`.

## Repository Structure

```
.                               ← root: governance, module files
├── Monarch.psm1                ← main module — all functions
├── Monarch.psd1                ← module manifest (version, exports)
├── Monarch-Config.psd1         ← default configuration values
├── preflight-win.ps1           ← Windows environment check
├── AGENTS.md                   ← project identity and sitemap (this file)
├── CONTRIBUTING.md             ← contribution process and merge requirements
├── CLAUDE-DEV-PLAN.md          ← retired — see header for extraction map
├── tests/
│   └── Monarch.Tests.ps1       ← all tests
└── docs/
    ├── phases/                 ← phase scope definitions (stable, one per phase)
    ├── plans/                  ← implementation-ready specs (active work)
    ├── raw/                    ← identified issues and undesigned items
    ├── archive/                ← completed work, one folder per phase
    │   └── phase-01-discovery/
    ├── sample-report/          ← real scan output examples
    │   └── report-v7-badblood/
    ├── report-v5-to-be-superseded.html  ← legacy feature showcase (temporary)
    └── *.md                    ← stable design decisions and specs
```

## Documentation Sitemap

### Key Files

| File | Purpose | Load When |
|------|---------|-----------|
| `Monarch.psm1` | Main module implementation — all functions live here | Any code changes or implementation work |
| `Monarch.psd1` | Module manifest (version, dependencies, exports) | Module structure or packaging changes |
| `Monarch-Config.psd1` | Default configuration values and thresholds | Config or threshold work |
| `preflight-win.ps1` | Windows environment check (server/workstation aware) | First run on a new Windows host |
| `tests/Monarch.Tests.ps1` | Full test suite (Pester 5+, mock-only) | Writing or modifying tests |
| `CONTRIBUTING.md` | Contribution process, class definitions, merge requirements | Planning a contribution |
| `docs/phases/phase-02-remediation.md` | Phase 2 scope: remediation, monitoring, cleanup functions | Phase 2 implementation work |
| `docs/phases/phase-03-wrapper.md` | Phase 3 scope: interactive wrapper (Start-MonarchAudit) | Phase 3 implementation work |
| `docs/phases/phase-04-comparison.md` | Phase 4 scope: comparison and compliance functions | Phase 4 implementation work |
| `docs/sample-report/report-v7-badblood/` | Completed scan output against a BadBlood domain | Understanding component output format |
| `docs/report-v5-to-be-superseded.html` | Feature showcase from earlier mockup | Implementing report features not yet in v7 |
| `docs/domain-specs.md` | Audit domains, functions per phase, return contracts | Function implementation or orchestrator work |
| `docs/mechanism-decisions.md` | Technical decisions (config, lastLogonTimestamp, backup tiers, etc.) | Logic involving config, thresholds, or interpretation |
| `docs/checklists.md` | Human review checklists and institutional knowledge | Remediation or interactive wrapper work |
| `docs/design-system.md` | HTML report visuals and console output rules | Reporting changes |
| `docs/dormant-account-policy.md` | Dormant account compliance policy | Dormant account features |
| `docs/deployment-guide.md` | Environment setup, RSAT, first-run validation | Preflight or deployment work |
| `docs/gpo-review-guide.md` | GPO review methods and priorities | Group Policy work |
| `docs/gap-research.md` | Implementation gap analysis vs industry standards | Gap analysis or roadmap work |
| `docs/initial-research.md` | Foundational research on AD audit tools and patterns | Design validation or research context |

**Strict loading rule:** Only load a file when it clearly matches the current task. Use filesystem commands (`find`, `ls`, `grep`) first before reading full files.

## Key Conventions

### Parameter Threading

- All public discovery functions accept a `-Server [string]` parameter.
- The orchestrator resolves the Domain Controller **once** and threads the same `-Server` value to every function.
- Individual functions respect the passed `-Server` value and perform no DC discovery of their own.
- Only pass `-Server` to AD cmdlets that actually support it (some do not).

### Return Contract

- All functions return structured `[PSCustomObject]` with at minimum: `Domain`, `Function`, `Timestamp`, `Warnings`.
- `Domain` names the functional domain (e.g., `'InfrastructureHealth'`, `'IdentityLifecycle'`).
- Functions that also produce file output return the structured object AND write files. The object includes paths to generated files.
- No formatted strings as primary output. No `Write-Host` in API functions.

### Config Access

- Config is accessed only via `Get-MonarchConfigValue -Key 'KeyName'`.
- Never access `$Global:` or re-read the config file inside a function.
- Module-scoped `$script:Config` is set at import time.

### Error Handling

- Read-only functions: `$ErrorActionPreference = 'Continue'` — gather as much as possible, surface errors in the `Warnings` array on the return object.
- Functions querying multiple independent things (baseline, GPO audit): catch per-section and continue.
- If the entire function fails (cannot reach AD at all): throw — let the orchestrator catch and record the failure.

### Output Path Semantics

- Functions that write files accept a directory path via `-OutputPath`, not a full file path.
- Each function constructs its own filename internally (`Join-Path $OutputPath 'filename.csv'`).
- When `-OutputPath` is omitted, file output is skipped; return object is unaffected.
- When a file is written, the return object gains an `OutputPath` property with the full file path.

### Test Strategy

- Tests live in `tests/Monarch.Tests.ps1`, organized by `Describe` block per function.
- All AD/DNS/GPO cmdlets are mocked — tests run without a domain.
- Every function's tests verify: correct return object properties, correct `Domain` and `Function` values, `Timestamp` populated, `Warnings` is an array.
- Functions with business logic get additional tests: exclusion logic, threshold comparisons, config overrides.
- Tests are written alongside code at each step, never after.
- Live domain testing is not yet implemented — see `docs/raw/todo-live-domain-tests.md`.

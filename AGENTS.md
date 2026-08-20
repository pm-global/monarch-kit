# monarch-kit

Active Directory audit and administration suite for mid-market domains (100-10,000 users).

Commit conventions and merge requirements: see `CONTRIBUTING.md`. Rules that judge the agent,
including when a change needs a plan: see `AGENT_CONDUCT.md`.

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
├── CONTRIBUTING.md             ← commit conventions and merge requirements
├── AGENT_CONDUCT.md            ← rules that judge the worker, any repo
├── CODING_STANDARDS.md         ← function-level code rules, any language
├── tests/
│   └── Monarch.Tests.ps1       ← all tests
└── docs/
    ├── adr/                    ← architecture decision records
    ├── agents/                 ← agent skill configuration
    ├── reference/              ← standing how-to and AD research
    │   └── ad-research/
    ├── validation/             ← evidence from doc-versus-code checks
    ├── phases/                 ← phase scope definitions (stable, one per phase)
    ├── plans/                  ← implementation-ready specs (active work)
    ├── sample-report/          ← report samples, see its README for which is authoritative
    ├── archive/                ← historical, nothing load-bearing
    │   ├── phase-01-discovery/
    │   └── raw/                ← undesigned items, several are specs for open issues
    └── *.md                    ← ledgers and documents pending dissolution
```

## Documentation Sitemap

### Read these first

Read `docs/adr/README.md` and the records it lists before any other document in this repo.
The records in `docs/adr/` hold the decisions. Where any document disagrees with an ADR, the
ADR wins and the other document is wrong.

Read `CONTEXT.md` next. It defines the terms this project narrows.

### Key Files

| File | Purpose | Load When |
|------|---------|-----------|
| `Monarch.psm1` | Main module implementation — all functions live here | Any code changes or implementation work |
| `Monarch.psd1` | Module manifest (version, dependencies, exports) | Module structure or packaging changes |
| `Monarch-Config.psd1` | Default configuration values and thresholds | Config or threshold work |
| `preflight-win.ps1` | Windows environment check (server/workstation aware) | First run on a new Windows host |
| `tests/Monarch.Tests.ps1` | Full test suite (Pester 5+, mock-only) | Writing or modifying tests |
| `CONTRIBUTING.md` | Commit conventions, attribution, merge requirements | Committing or merging |
| `AGENT_CONDUCT.md` | Change classes, plan requirements, the five reviewer lenses | Planning any change |
| `docs/phases/phase-02-remediation.md` | Phase 2 scope: remediation, monitoring, cleanup functions | Phase 2 implementation work |
| `docs/phases/phase-03-wrapper.md` | Phase 3 scope: interactive wrapper (Start-MonarchAudit) | Phase 3 implementation work |
| `docs/phases/phase-04-comparison.md` | Phase 4 scope: comparison and compliance functions | Phase 4 implementation work |
| `docs/sample-report/README.md` | Which report sample is authoritative and why | Any report work |
| `docs/sample-report/demo_report_v9.html` | Current real report output, anonymized. The baseline | Reporting changes |
| `docs/sample-report/demo_report_v7_badblood/` | First real scan output, against a BadBlood lab domain | Understanding component output format |
| `docs/sample-report/demo_report_v5.html` | Unimplemented mockup. Design target, never shipped | Implementing report features not yet in v9 |
| `docs/domain-specs.md` | Audit domains, functions per phase, return contracts | Function implementation or orchestrator work |
| `docs/mechanism-decisions.md` | Technical decisions (config, lastLogonTimestamp, backup tiers, etc.) | Logic involving config, thresholds, or interpretation |
| `docs/checklists.md` | Human review checklists and institutional knowledge | Remediation or interactive wrapper work |
| `docs/reference/report-design-system.md` | HTML report visuals and console output rules | Reporting changes |
| `docs/reference/dormant-account-standard.md` | External compliance standard the code conforms to | Dormant account features |
| `docs/reference/deployment-guide.md` | Environment setup, RSAT, first-run validation | Preflight or deployment work |
| `docs/reference/gpo-review-workflow.md` | GPO review methods and priorities | Group Policy work |
| `docs/reference/ad-research/research-brief.md` | Implementation gap analysis vs industry standards | Gap analysis or roadmap work |
| `docs/reference/ad-research/research-brief-draft.md` | Earlier, wider version of the brief | Design validation or research context |
| `docs/validation/` | Evidence from doc-versus-code validation efforts | Before trusting any document |
| `CODING_STANDARDS.md` | Function-level code rules, any language | Writing or reviewing code |

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
- No `Write-Host` in API functions.

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
- Live domain testing is not yet implemented — see `docs/archive/raw/todo-live-domain-tests.md`.

## Agent skills

### Issue tracker

Issues live in GitHub Issues (`pm-global/monarch-kit`), managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — `CONTEXT.md` + `docs/adr/` at repo root. See `docs/agents/domain.md`.

# monarch-kit

Active Directory audit and administration suite for mid-market domains (100-10,000 users).

`dev-guide.md` defines *how* to program. This file defines *what* this project is.

## Module Identity
- **PowerShell 5.1+** module (`Monarch.psm1` + `Monarch.psd1`)
- Core dependency: ActiveDirectory module (GroupPolicy and DnsServer are optional)
- Target users: experienced IT administrators and LLM agents

## Current State
Plan 1 (Discovery phase) is complete — 28 functions + orchestrator + reporting.  
See `CLAUDE-DEV-PLAN.md` for full roadmap and status.

## Documentation Sitemap & Dynamic Discovery

**At the start of every task:**
1. Read this sitemap.
2. Run `find . -name "*.md" | sort` and `Get-ChildItem -Recurse -Filter "*.ps*1"` to explore structure.
3. Read **only** the files relevant to the current task.
4. Prefer reading full files over relying on summaries here.

### Key Files

| File                        | Purpose (read full file for details)                                      | Load When |
|-----------------------------|---------------------------------------------------------------------------|-----------|
| `Monarch.psm1`              | Main module implementation — all functions live here                      | Any code changes or implementation work |
| `Monarch.psd1`              | Module manifest (version, dependencies, exports)                          | Module structure or packaging changes |
| `preflight-win.ps1`         | Windows environment check script (VOM output, server/workstation aware)   | First run on a new Windows host |
| `CLAUDE-DEV-PLAN.md`        | Current roadmap, plan status, and implementation sequence                 | Planning or sequencing decisions |
| `docs/domain-specs.md`      | Audit domains, functions per phase, return contracts                      | Function implementation or orchestrator work |
| `docs/mechanism-decisions.md` | Technical decisions (config, lastLogonTimestamp, backup tiers, etc.)    | Logic involving config, thresholds, or interpretation |
| `docs/checklists.md`        | Human review checklists and institutional knowledge                       | Remediation or interactive wrapper work |
| `docs/design-system.md`     | HTML report visuals and console output rules                              | Reporting changes |
| `docs/dormant-account-policy.md` | Dormant account compliance policy                                     | Dormant account features |
| `docs/deployment-guide.md`  | Environment setup, RSAT, first-run validation                             | Preflight or deployment work |
| `docs/gpo-review-guide.md`  | GPO review methods and priorities                                         | Group Policy work |
| `docs/gap-research.md`      | Implementation gap analysis vs industry standards                          | Gap analysis or roadmap work |
| `docs/initial-research.md`  | Foundational research on AD audit tools and patterns                      | Design validation or research context |

**Strict loading rule:** Only `@` a file when it clearly matches the current task. Use filesystem commands (`find`, `ls`, `grep`) first before reading full files.

## Key Conventions

- All public discovery functions accept a `-Server [string]` parameter.
- The orchestrator resolves the Domain Controller **once** and threads the same `-Server` value to every function.
- Individual functions must respect the passed `-Server` value and must not perform their own DC discovery.
- Only pass `-Server` to AD cmdlets that actually support it (some do not).
- All functions return structured `[PSCustomObject]` with at minimum: `Domain`, `Function`, `Timestamp`, `Warnings`.
- Config must only be accessed via `Get-MonarchConfigValue`.

**Last reviewed:** 2026-03-31

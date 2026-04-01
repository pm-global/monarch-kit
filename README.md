# monarch-kit

PowerShell module for Active Directory auditing. Structured discovery across eight domains, graded findings, HTML reporting.

**v0.2.0-beta** — Discovery phase complete (28 functions, 162 tests). Remediation, interactive wrapper, and remaining phases are planned.

## Quick Start

```powershell
.\preflight-win.ps1                   # check environment and import module (run once per session)
Invoke-DomainAudit -Phase Discovery   # orchestrates all 25 API functions, generates HTML report
```

Or import manually:

```powershell
Import-Module Monarch
Invoke-DomainAudit -Phase Discovery
```

Or call functions directly:

```powershell
Import-Module Monarch
Get-PrivilegedGroupMembership -Server dc01.contoso.com
Find-DormantAccount -Server dc01.contoso.com -OutputPath .\dormant-accounts
```

Every function returns structured PowerShell objects. Pipe to `Format-Table`, `Export-Csv`, or consume programmatically.

## Architecture

```
OctoDoc (optional — enhances DC selection with health scoring)
    ↓
Monarch API functions (25) — interpret AD state, return graded domain answers
    ↓
Invoke-DomainAudit — orchestrator, coordinates Discovery phase
    ↓
New-MonarchReport — single-page HTML report from orchestrator results
```

API functions return structured objects. The orchestrator calls them in sequence, isolates failures, and generates the report. OctoDoc is optional — without it, DC selection uses standard AD discovery.

## Domain Coverage

| Domain | Functions | Covers |
|--------|-----------|--------|
| Infrastructure Health | 4 | FSMO roles, replication health, site/subnet topology, functional levels |
| Identity Lifecycle | 1 | Dormant account discovery with CSV export |
| Privileged Access | 4 | Group membership, AdminCount orphans, Kerberoastable, AS-REP roastable |
| Group Policy | 3 | GPO export (HTML/XML/CSV), unlinked GPOs, permission anomalies |
| Security Posture | 4 | Password policies, weak account flags, Protected Users gaps, legacy protocols |
| Backup & Recovery | 2 | Three-tier backup detection, tombstone gap analysis |
| Audit & Compliance | 3 | Domain baselines, audit policy consistency, event log configuration |
| DNS (AD-Integrated) | 4 | SRV record completeness, scavenging, zone replication, forwarder consistency |

Plus `Invoke-DomainAudit` (orchestrator), `New-MonarchReport` (HTML reporting), and `Resolve-MonarchDC` (DC selection). 28 functions total.

## Phases

| Phase | Status | Purpose |
|-------|--------|---------|
| Discovery | **Complete** | Document current state across all eight domains |
| Review | Human activity | Review findings, validate exclusions, approve plan ([checklists](docs/checklists.md)) |
| Remediation | Planned | Execute approved changes with WhatIf gates |
| Monitoring | Planned | Track metrics during hold period |
| Cleanup | Planned | Permanent deletion after hold period |

Discovery is entirely read-only. No operations modify AD state.

## Requirements

- PowerShell 5.1+
- ActiveDirectory module
- GroupPolicy module (for GPO functions)
- DnsServer module (optional — DNS functions degrade gracefully without it)
- OctoDoc module (optional — enhances DC selection with health scoring)
- Windows Server 2016+ or Windows 10/11 with RSAT

## Configuration

All defaults are built in. A fresh install works without configuration. [`Monarch-Config.psd1`](Monarch-Config.psd1) ships with every default commented out — uncomment and modify values for your environment. Key areas: dormancy thresholds, privileged group thresholds, service account keywords, backup vendor integration, report accent colors.

## Troubleshooting

**"Cannot find domain controllers"** — run on a domain-joined machine, verify DNS resolution, check firewall rules for AD ports.

**"Access denied" errors** — need Domain Admin or equivalent. Check UAC (run as administrator).

**"LastLogon always null"** — account truly never logged on, or all DCs were unreachable during query.

**GPO export fails for specific GPO** — likely corrupted GPO or DENY ACL. Check Event Viewer.

## Project Artifacts

This repo includes development artifacts alongside the module code:

- [`CLAUDE.md`](CLAUDE.md) — machine-readable project specification (architecture, conventions, probe contracts)
- [`dev-guide.md`](dev-guide.md) — universal AI agent coding guidelines
- [`docs/domain-specs.md`](docs/domain-specs.md) — eight domains with function lists and return contracts
- [`docs/mechanism-decisions.md`](docs/mechanism-decisions.md) — technical decisions with rationale
- [`docs/design-system.md`](docs/design-system.md) — visual language specification for report output
- [`docs/checklists.md`](docs/checklists.md) — expert-curated review phase checklists
- [`docs/report-v5.html`](docs/report-v5.html) — canonical HTML report reference
- [`docs/archive/01-discovery/`](docs/archive/01-discovery/) — complete Discovery implementation history (14 step subplans)
- [`docs/archive/00-prototype/`](docs/archive/00-prototype/) — previous toolkit preserved as reference material

Reading order for contributors: this README, then [`CLAUDE.md`](CLAUDE.md), then [`docs/domain-specs.md`](docs/domain-specs.md) for the domain you're working on.

## Compliance

Dormant account policy aligns with PCI DSS v4.0.1, NIST SP 800-53 Rev 5, and Microsoft 2026 guidance. See [`docs/dormant-account-policy.md`](docs/dormant-account-policy.md).

## Related Tools

- **Ping Castle** — AD security scoring and hardening assessment
- **BloodHound** — attack path mapping
- **Microsoft Policy Analyzer** — GPO baseline comparison

## License

MIT

---

Built with Claude Opus 4.6 directed by human input.

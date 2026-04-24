# monarch-kit

A multi-phase Active Directory audit and administration suite. The Discovery phase — currently complete — documents your domain's health across eight audit categories (read-only, no Internet required) and produces graded findings in a single-page HTML report plus an array of csv files allowing for easy offline analysis. Remediation, monitoring, and cleanup phases are in development, building toward a complete AD management workflow for mid-market domains.

**v0.5.1-beta** — Discovery phase complete (28 functions, 346 tests). Remediation, interactive wrapper, and remaining phases are planned.

## Requirements

- Windows Server 2016+ or Windows 10/11
- PowerShell 5.1+
- RSAT: Active Directory Domain Services Tools (`Get-WindowsCapability -Online -Name Rsat.ActiveDirectory*`)
- RSAT: Group Policy Management Tools (for GPO functions)
- Must run on a domain-joined machine with Domain Admin or equivalent rights

## Installation

```powershell
git clone https://github.com/pm-global/monarch-kit.git
cd monarch-kit
```

## Quick Start

Open an **administrator PowerShell window**, navigate to the repo root, and run:

```powershell
.\preflight-win.ps1
```

Preflight checks your environment, installs any missing RSAT components, and imports the module. Then run the audit:

```powershell
# interactive — clean console, follow the report path on the OK line
Invoke-DomainAudit -Phase Discovery

# automation — capture findings, failures, dispositions
$result = Invoke-DomainAudit -Phase Discovery -PassThru
```

When it finishes, the console prints the report path. Open it in any browser.

**One-liner option** — preflight and launch in a single step (opens in a new window):

```powershell
.\preflight-win.ps1 -AndMonarch
```

The audit runs 25 checks sequentially — expect 1–3 minutes on a typical domain. When it finishes, a folder named `Monarch-Audit-YYYYMMDD` appears in your current directory containing the HTML report (`00-Discovery-Report.html`) and per-function CSV/JSON output files.

> **Note:** monarch-kit hashes `Monarch.psm1` at import time and rechecks on every run. If the file on disk has changed — e.g. after a `git pull` — `Invoke-DomainAudit` spawns a new elevated PowerShell window running `.\preflight-win.ps1 -AndMonarch`, then exits with code `3`. The new window reloads the module and relaunches the audit automatically. monarch-kit will never run a version of itself that differs from what is on disk. Automation scripts can detect this cycle by checking for exit code `3`.

## What You'll See

Console output during the run (default `Info` verbosity):

```
audit: corp.example.com  ·  DC: dc01.corp.example.com  ·  25 checks

  audit: Get-FSMORolePlacement...
  audit: Get-ReplicationHealth...
  ...
audit OK: 25/25 checks (1m 42s)
```

The HTML report contains:
- **Header** — domain, DC used, audit duration, pass/fail summary
- **Critical findings** — items requiring immediate attention, with remediation hints
- **Advisory findings** — lower-severity items worth reviewing
- **Per-category sections** — detailed results for each of the eight audit categories
- **Output file tree** — links to all generated CSV/JSON files

## Verbosity

Control console output with `-Verbosity`:

| Level | Progress bar | Per-function narration | Failure blocks | OK line |
|-------|-------------|----------------------|----------------|---------|
| `Silent` | No | No | No | No |
| `Error` | Yes | No | Yes | No |
| `Warn` | Yes | No | Yes | Yes |
| `Info` (default) | Yes | Yes | Yes | Yes |

```powershell
Invoke-DomainAudit -Phase Discovery -Verbosity Silent   # zero output, report still generated
Invoke-DomainAudit -Phase Discovery -Verbosity Warn     # progress bar + summary only
```

## Architecture

```
Monarch API functions (25) — interpret AD state, return graded answers per category
    ↓
Invoke-DomainAudit — orchestrator, coordinates Discovery phase
    ↓
New-MonarchReport — single-page HTML report from orchestrator results
```

API functions return structured objects. The orchestrator calls them in sequence, isolates failures, and generates the report. A failed check does not stop the run — it's recorded and reported.

## Audit Categories

| Category | Functions | Covers |
|----------|-----------|--------|
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
| Discovery | **Complete** | Document current state across all eight audit categories |
| Review | Human activity | Review findings, validate exclusions, approve plan ([checklists](docs/checklists.md)) |
| Remediation | Planned | Execute approved changes with WhatIf gates |
| Monitoring | Planned | Track metrics during hold period |
| Cleanup | Planned | Permanent deletion after hold period |

Discovery is entirely read-only. No operations modify AD state.

## Configuration

All defaults are built in. A fresh install works without configuration. [`Monarch-Config.psd1`](Monarch-Config.psd1) ships with every default commented out — uncomment and modify values for your environment. Key areas: dormancy thresholds, privileged group thresholds, service account keywords, backup vendor integration, report accent colors.

## Troubleshooting

**"Cannot find domain controllers"** — run on a domain-joined machine, verify DNS resolution, check firewall rules for AD ports.

**"Access denied" errors** — need Domain Admin or equivalent. Check UAC (run as administrator).

**"LastLogon always null"** — account truly never logged on, or all DCs were unreachable during query.

**GPO export fails for specific GPO** — likely corrupted GPO or DENY ACL. Check Event Viewer.

## Calling Functions Directly

Every function returns structured PowerShell objects. Pipe to `Format-Table`, `Export-Csv`, or consume programmatically.

```powershell
Import-Module .\Monarch.psd1
Get-PrivilegedGroupMembership -Server dc01.contoso.com
Find-DormantAccount -Server dc01.contoso.com -OutputPath .\dormant-accounts
```

## Project Artifacts

This repo includes development artifacts alongside the module code:

- [`CLAUDE.md`](CLAUDE.md) — machine-readable project specification (architecture, conventions, probe contracts)
- [`docs/domain-specs.md`](docs/domain-specs.md) — audit categories with function lists and return contracts
- [`docs/mechanism-decisions.md`](docs/mechanism-decisions.md) — technical decisions with rationale
- [`docs/design-system.md`](docs/design-system.md) — visual language specification for report output
- [`docs/checklists.md`](docs/checklists.md) — expert-curated review phase checklists

Reading order for contributors: this README, then [`CLAUDE.md`](CLAUDE.md), then [`docs/domain-specs.md`](docs/domain-specs.md) for the category you're working on.

## Compliance

Dormant account policy aligns with PCI DSS v4.0.1, NIST SP 800-53 Rev 5, and Microsoft 2026 guidance. See [`docs/dormant-account-policy.md`](docs/dormant-account-policy.md).

## Related Tools

- **Ping Castle** — AD security scoring and hardening assessment
- **BloodHound** — attack path mapping
- **Microsoft Policy Analyzer** — GPO baseline comparison

## License

	GPL-3.0

---

Designed and developed with Claude Sonnet and Opus, directed by human input with ❤️ and a genuine commitment to the highest standard of craft and code quality possible.
 

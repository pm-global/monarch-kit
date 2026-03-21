# monarch-kit

Active Directory audit and administration module. Repeatable, phased audit workflows for mid-market domains.

## The Problem

You manage an AD environment that works but has unknown history: overpermissioned accounts, dormant users, undocumented GPOs, unclear backup status. You need to systematically document, assess, remediate, and maintain it without breaking production. Point-in-time scanners tell you what's wrong. They don't give you a safe, repeatable process to fix it.

monarch-kit is the process. Discovery through cleanup, with human gates, hold periods, and compliance tracking built in.

## Quick Start

```powershell
Install-Module OctoDoc    # sensor layer (dependency)
Install-Module Monarch    # audit and administration suite

Import-Module Monarch
Start-MonarchAudit        # interactive menu — pick a phase
```

Or run a phase directly:

```powershell
Invoke-DomainAudit -Phase Discovery   # returns structured results, no prompts
```

## How It Works

```
OctoDoc (sensor — observes AD health, returns raw probe data)
    ↓
Monarch API functions (interpret probe results, return graded domain answers)
    ↓
Invoke-DomainAudit (orchestrator — coordinates phases, enforces safety gates)
    ↓
Start-MonarchAudit (interactive wrapper — menus, checklists, guided workflow)
```

OctoDoc observes. Monarch interprets. The boundary is absolute — interpretation logic never lives in the sensor. OctoDoc loads automatically as a module dependency.

The interactive wrapper (`Start-MonarchAudit`) is what admins run at a console. The orchestrator (`Invoke-DomainAudit`) is the API for scripts and agents. Both call the same underlying functions.

## Audit Phases

1. **Discovery** — document current state across all domains (GPOs, privileged access, dormant accounts, backup readiness, DNS, security posture, baselines)
2. **Review** — human gate with expert-curated checklists. Review findings, validate exclusions, approve remediation plan.
3. **Remediation** — execute approved changes. WhatIf preview enforced before any modification.
4. **Monitoring** — track metrics during hold period (30–90 days). Reclamation requests, re-enabled accounts, service interruptions.
5. **Cleanup** — permanent deletion after hold period. WhatIf preview enforced. Pre-deletion archive for compliance.

## Domains

| Domain | What It Covers |
|--------|---------------|
| Infrastructure Health | FSMO roles, replication topology, site/subnet coverage, functional levels, time sync |
| Identity Lifecycle | Dormant account discovery → suspend → monitor → restore/delete, provisioning, stale computers |
| Privileged Access | Group membership audit, AdminCount orphans, Kerberoastable/AS-REP roastable accounts, tiered admin compliance |
| Group Policy | GPO export in multiple formats, unlinked/orphaned GPOs, permission anomalies, high-risk setting detection |
| Security Posture | Password policies, weak account flags, Protected Users gaps, legacy protocol exposure, CIS/STIG baseline comparison |
| Backup & Recovery | Three-tier backup detection (universal → tool detection → vendor integration), tombstone gap analysis, USN rollback warning |
| Audit & Compliance | Domain baselines, audit policy configuration, event log settings, baseline change tracking |
| DNS (AD-Integrated) | SRV record completeness, scavenging configuration, zone replication scope, forwarder configuration |

## Configuration

All defaults are built in. A fresh install works without configuration.

`Monarch-Config.psd1` ships with every default commented out. Uncomment and modify values for your environment. The file is self-documenting — each entry explains what it controls and why the default was chosen.

Key configurable values: dormancy threshold, hold period, quarantine OU name, service account exclusion keywords, admin naming patterns, privileged group thresholds, replication warning thresholds, backup vendor integration.

For multi-environment deployments, each environment gets its own config file. The module reads config on load — different environments, different thresholds, same module.

## Safety

Every destructive operation follows the same pattern:

```powershell
# 1. Preview with WhatIf (mandatory first step)
Invoke-DomainAudit -Phase Remediation -WhatIf

# 2. Review the preview output

# 3. Execute after human approval
Invoke-DomainAudit -Phase Remediation
```

Built-in protections: WhatIf on all destructive operations, automatic exclusion of service accounts and critical resources, confirmation prompts in the interactive wrapper, read-before-write (query first, modify separately), rollback data archived before suspend operations, hold period enforcement before deletion.

## Troubleshooting

**"Cannot find domain controllers"** — run on a domain-joined machine, verify DNS resolution, check firewall rules for AD ports.

**"Access denied" errors** — need Domain Admin or equivalent. Check UAC (run as administrator). Some operations require specific delegated permissions.

**"LastLogon always null"** — account truly never logged on, or all DCs were unreachable during query. Check DC availability with `Get-ADDomainController -Discover`.

**GPO export fails for specific GPO** — likely corrupted GPO or DENY ACL. Check Event Viewer. Skip and investigate separately.

**OctoDoc probe returns ErrorCategory = AccessDenied** — the service account's delegation may have been removed. Check the account's permissions on the target DC.

## Compliance

Dormant account policy aligns with PCI DSS v4.0.1, NIST SP 800-53 Rev 5, and Microsoft 2026 guidance. See [docs/dormant-account-policy.md](docs/dormant-account-policy.md) for the complete policy with compliance references and governance cadence.

## Related Tools

monarch-kit is a repeatable audit workflow — discovery through cleanup with phased remediation and compliance tracking. It complements point-in-time assessment tools:

- **Ping Castle** — free AD security scoring (run for initial assessment, use monarch-kit for ongoing operations)
- **BloodHound** — attack path mapping (use carefully in production)
- **Microsoft Policy Analyzer** — GPO baseline comparison

See [docs/gpo-review-guide.md](docs/gpo-review-guide.md) for a detailed guide on reviewing GPO findings, including three review methods and priority guidance.

## Requirements

- PowerShell 5.1+
- OctoDoc module (installed as dependency)
- ActiveDirectory PowerShell module
- GroupPolicy module (for GPO domain)
- DnsServer module (optional, for DNS domain)
- Windows Server 2019+ or Windows 10/11 with RSAT

## Contributing

Set up: clone the repo, ensure OctoDoc is installed, import the module.

If you're using an AI coding agent (Claude Code, Cursor, etc.), CLAUDE.md provides project context automatically. The `docs/` directory contains domain specifications, mechanism decisions, and checklists that agents reference during implementation.

Reading order for contributors: README (you're here) → CLAUDE.md → docs/domain-specs.md for the domain you're working on → docs/mechanism-decisions.md if your domain has specific technical requirements.

## Project Status

Active development. Built with Claude Opus 4.6 directed by human input.

## License

MIT

---

**Philosophy:** Safety first, human-in-the-loop, evidence-based decisions. These are tools, not magic bullets. The real work is in the analysis, decision-making, and communication.

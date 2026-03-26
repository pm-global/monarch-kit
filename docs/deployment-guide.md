# Deployment and Testing Guide

Run monarch-kit on Windows — from Pester tests through lab validation to production.

---

## 1. Windows Host Setup

### PowerShell and RSAT

Monarch-kit requires PowerShell 5.1+ and the ActiveDirectory module. On Windows Server 2016+:

```powershell
# Check PowerShell version
$PSVersionTable.PSVersion

# Install RSAT AD tools (Server)
Install-WindowsFeature RSAT-AD-PowerShell, RSAT-ADDS-Tools

# Install RSAT Group Policy tools (for GPO functions)
Install-WindowsFeature GPMC

# Install RSAT DNS tools (optional — DNS functions degrade gracefully without it)
Install-WindowsFeature RSAT-DNS-Server
```

On Windows 10/11:

```powershell
# Settings → Apps → Optional Features → Add a feature
# Or via PowerShell (requires admin):
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0
```

Verify:

```powershell
Get-Module -ListAvailable ActiveDirectory, GroupPolicy, DnsServer | Format-Table Name, Version
```

All three should appear. GroupPolicy and DnsServer are optional — monarch-kit checks for them at runtime and skips gracefully.

### Pester 5

Windows ships with Pester 3.x. You need Pester 5+.

```powershell
# Remove the built-in Pester 3 (run as admin)
$module = "C:\Program Files\WindowsPowerShell\Modules\Pester"
takeown /F $module /A /R
icacls $module /reset
icacls $module /grant "*S-1-5-32-544:F" /inheritance:d /T
Remove-Item -Path $module -Recurse -Force -ErrorAction SilentlyContinue

# Install Pester 5
Install-Module -Name Pester -Force -SkipPublisherCheck
Import-Module Pester
(Get-Module Pester).Version   # Should be 5.x
```

### Install monarch-kit

The module is not on PSGallery. Copy the repo to the Windows host and either:

**Option A — Import directly from the repo:**

```powershell
Import-Module C:\path\to\monarch-kit\Monarch.psd1
```

**Option B — Install to a module path:**

```powershell
$dest = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules\Monarch"
New-Item -Path $dest -ItemType Directory -Force
Copy-Item C:\path\to\monarch-kit\Monarch.psm1, C:\path\to\monarch-kit\Monarch.psd1, C:\path\to\monarch-kit\Monarch-Config.psd1 -Destination $dest
Import-Module Monarch
```

Verify:

```powershell
Get-Module Monarch | Format-List Name, Version, ExportedFunctions
# Should show 28 functions (27 exported + 1 private config helper)
```

---

## 2. Run Pester Tests (Mocked — No Domain Required)

These are the same 162 tests from development. They mock all AD/GPO/DNS cmdlets and run without a domain. Run these first to confirm the module works on the Windows host.

```powershell
cd C:\path\to\monarch-kit
Invoke-Pester -Path .\Tests\Monarch.Tests.ps1 -Output Detailed
```

**Expected:** 162 tests, 0 failures. If anything fails here, it's an environment issue (wrong Pester version, missing module, path problem) — not a domain issue.

**Common issues:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Cannot find module 'Pester'` | Pester 5 not installed | See Pester 5 section above |
| `The term 'Get-ADDomain' is not recognized` | ActiveDirectory module not installed | Install RSAT |
| Tests pass but show `Pester 3.x` warnings | Old Pester still loaded | Close PowerShell, reopen, `Import-Module Pester -MinimumVersion 5.0` |
| `Access to the path is denied` | Running from a read-only location | Copy repo to a writable path |

---

## 3. Lab Domain Testing

### Lab Environment

You need a Windows domain with populated data. Two proven approaches:

**BadBlood** (recommended) — populates an existing domain with realistic fake users, groups, OUs, GPOs, permissions, and attack paths:
- https://github.com/davidprowe/BadBlood
- Run on a DC after domain setup: `.\Invoke-BadBlood.ps1`
- Creates ~2,500 users, nested groups, GPOs, delegation, service accounts with SPNs

**AutomatedLab / yourDomain-in-a-box** — builds the full VM infrastructure:
- DC(s), member servers, client machines
- Then run BadBlood on top

### Minimum lab topology

- 1 DC (Windows Server 2016+ with AD DS, DNS, GPMC roles)
- Domain functional level: 2012 R2+ (for fine-grained password policies, Protected Users group)
- 1 domain-joined Windows machine to run monarch-kit from (or run directly on the DC)

### Pre-flight checks

Before running monarch-kit, verify the lab domain is reachable and the test data is present:

```powershell
# Can you reach AD?
Get-ADDomain | Format-List DNSRoot, DomainMode, PDCEmulator

# Are there users to find?
(Get-ADUser -Filter *).Count

# Are there GPOs?
(Get-GPO -All).Count

# Are there groups with members?
Get-ADGroupMember "Domain Admins" | Format-Table Name

# Is DNS integrated?
Get-DnsServerZone | Where-Object { $_.IsDsIntegrated } | Format-Table ZoneName

# Can you reach DCs remotely? (needed for audit policy and event log checks)
$dc = (Get-ADDomainController).HostName
Invoke-Command -ComputerName $dc -ScriptBlock { hostname }
```

If `Invoke-Command` fails, enable PSRemoting on the DC:

```powershell
# On the DC:
Enable-PSRemoting -Force
```

### Run Discovery against the lab

```powershell
Import-Module C:\path\to\monarch-kit\Monarch.psd1

# Full Discovery — all 25 API functions
Invoke-DomainAudit -Phase Discovery -OutputPath C:\MonarchOutput
```

This creates:

```
C:\MonarchOutput\
├── 00-Discovery-Report.html
├── 01-Baseline\
│   ├── domain-info.csv
│   ├── domain-controllers.csv
│   ├── fsmo-roles.csv
│   ├── object-counts.csv
│   └── password-policy.csv
├── 02-GPO-Audit\
│   └── <GPO-Name>.html (one per GPO)
├── 03-Privileged-Access\
└── 04-Dormant-Accounts\
    └── dormant-accounts.csv
```

Open `00-Discovery-Report.html` in a browser and walk through every section.

### What to validate in the lab

Check each domain against what BadBlood creates:

| Domain | What to look for | BadBlood creates it? |
|--------|-----------------|---------------------|
| Infrastructure Health | FSMO roles resolved, replication healthy (single DC = trivially healthy), sites/subnets listed, functional levels reported | Yes (domain structure) |
| Identity Lifecycle | Dormant accounts found (BadBlood creates old lastLogon dates), CSV exported | Yes |
| Privileged Access | Domain Admins/Enterprise Admins members listed, Kerberoastable accounts found (SPNs), AS-REP roastable found, AdminCount orphans detected | Yes (SPNs, nested groups, delegation) |
| Group Policy | GPOs exported to HTML, unlinked GPOs detected, permission anomalies flagged | Yes (creates GPOs with various links) |
| Security Posture | Password policies inventoried (default + any FGPPs), weak flags found, Protected Users gaps identified, legacy protocol exposure flagged | Partially (password policies yes, legacy protocols depend on lab config) |
| Backup & Recovery | Backup services checked (likely none in lab — that's fine, confirms detection logic works), tombstone lifetime reported | No backup agents — expect "no backup detected" |
| Audit & Compliance | Baseline CSVs generated, audit policy retrieved from DC, event log config retrieved | Yes (DC exists) |
| DNS | SRV records validated, scavenging config reported, zone replication scope checked, forwarders listed | Yes (AD-integrated DNS) |

### Per-function spot checks

Run individual functions to isolate behavior:

```powershell
$dc = (Resolve-MonarchDC).DCName

# Should return populated objects with real data
Get-PrivilegedGroupMembership -Server $dc | Format-Table
Find-KerberoastableAccount -Server $dc | Format-Table
Find-DormantAccount -Server $dc -OutputPath C:\temp\dormant
Get-PasswordPolicyInventory -Server $dc
Get-AuditPolicyConfiguration -Server $dc
Test-SRVRecordCompleteness -Server $dc
```

Every function returns a PSCustomObject with `Domain`, `Function`, `Timestamp`, and `Warnings` properties. Check:
- `Warnings` is an empty array (or contains expected warnings, not errors)
- Data properties are populated (not null/empty when you expect data)
- CSV/HTML files are written where expected

### Expected differences from mocked tests

Things that will be different in a real domain vs mocked tests:

- **Timing:** Functions that query every DC take longer. `Get-ReplicationHealth` and `Get-AuditPolicyConfiguration` scale with DC count.
- **Remote execution failures:** `Invoke-Command` to DCs may fail due to WinRM configuration, firewall rules, or permissions. These surface as warnings, not crashes.
- **Empty results:** Some functions may return zero findings (no dormant accounts, no Kerberoastable users) depending on what BadBlood populated. That's correct behavior — the function ran, found nothing, and reported it.
- **GPO HTML generation:** `Get-GPOReport -ReportType Html` can fail on corrupted GPOs. Failures are caught per-GPO and logged in the return object.

---

## 4. Production Readiness Checklist

Once lab tests pass, work through this checklist before running against production.

### Permissions

```powershell
# Check your effective permissions
whoami /groups | findstr /i "domain admins"

# Or more precisely — do you have the read access monarch-kit needs?
# These are the AD operations used (all read-only):
Get-ADUser -Filter * -ResultSetSize 1 -Properties lastLogonTimestamp   # User read
Get-ADGroup -Filter * -ResultSetSize 1                                 # Group read
Get-ADComputer -Filter * -ResultSetSize 1                              # Computer read
Get-ADObject -Filter * -ResultSetSize 1 -SearchBase (Get-ADRootDSE).schemaNamingContext  # Schema read
Get-GPO -All | Select-Object -First 1                                 # GPO read
Get-GPPermission -Guid (Get-GPO -All | Select-Object -First 1).Id -All  # GPO permission read
```

Monarch-kit needs:
- **Read access to all AD objects** — Domain Admin has this, but a custom read-only service account works too
- **Invoke-Command to DCs** — for audit policy and event log enumeration
- **Read access to GPOs** — for HTML/XML export and permission auditing
- **Read access to DNS zones** — for DNS functions (optional)

### Read-Only Verification

Discovery is read-only by design. No functions in the Discovery phase call any write cmdlets. To verify this yourself:

```powershell
# Search the module source for write operations — these should only appear
# in Remediation functions (Plan 2, not yet implemented)
Select-String -Path C:\path\to\monarch-kit\Monarch.psm1 -Pattern 'Set-AD|Remove-AD|New-AD|Disable-AD|Enable-AD|Move-AD'
```

Any matches should be in functions tagged for Remediation/Cleanup phases (Plan 2), not Discovery. `Invoke-DomainAudit -Phase Discovery` only calls Discovery-phase functions.

The only filesystem writes are:
- CSV exports to `$OutputPath`
- HTML report to `$OutputPath`
- GPO HTML exports to `$OutputPath\02-GPO-Audit\`

### Network and Firewall

Monarch-kit talks to DCs over standard AD ports plus WinRM:

| Port | Protocol | Used by |
|------|----------|---------|
| 389 | LDAP | All AD cmdlets |
| 636 | LDAPS | AD cmdlets (if SSL configured) |
| 3268 | GC | `Get-ADForest`, cross-domain queries |
| 88 | Kerberos | Authentication |
| 53 | DNS | `Resolve-DnsName` for SRV validation |
| 5985/5986 | WinRM | `Invoke-Command` to DCs (audit policy, event logs) |
| ICMP | Ping | `Test-Connection` for FSMO reachability |

If WinRM is blocked to DCs, the audit policy and event log functions will return warnings but won't crash. Everything else works over standard LDAP.

### Performance Impact

Discovery functions are read-only AD queries. Impact assessment:

- **LDAP load:** Standard `Get-AD*` queries. Equivalent to an admin opening ADUC and browsing. No bulk writes, no schema modifications.
- **Replication queries:** `Get-ADReplicationPartnerMetadata` reads replication status. Does not trigger replication.
- **DNS queries:** Reads zone config and SRV records. Does not modify zones.
- **WinRM sessions:** One `Invoke-Command` per DC for audit policy, one for event log config. Short-lived, read-only.
- **GPO reads:** `Get-GPOReport` generates HTML/XML from existing GPO data. Read-only, but generating reports for hundreds of GPOs takes time.

**Largest query:** `Get-ADUser -Filter * -Properties <multiple>` in `Find-DormantAccount`. In a 10,000-user domain this is a noticeable LDAP query but well within normal admin tooling patterns. Runs once.

### Timing

Pick a low-activity window for the first production run. Not because monarch-kit is risky — it's read-only — but because:

1. `lastLogon` accuracy improves when all DCs are reachable (dormant account detection)
2. Replication health is most meaningful when measured during normal operation
3. First run lets you calibrate expected duration before scheduling recurring runs

### Dry Run — Individual Functions First

Don't start with `Invoke-DomainAudit` in production. Run individual functions first to validate behavior:

```powershell
Import-Module Monarch
$dc = (Resolve-MonarchDC).DCName
Write-Host "Using DC: $dc"

# Start with the lightest functions
Get-ForestDomainLevel -Server $dc
Get-FSMORolePlacement -Server $dc

# Then heavier queries
Get-PrivilegedGroupMembership -Server $dc
Get-PasswordPolicyInventory -Server $dc

# Then the functions that hit every DC
Get-ReplicationHealth -Server $dc
Get-AuditPolicyConfiguration -Server $dc

# Then file-producing functions (specify an output path)
New-DomainBaseline -Server $dc -OutputPath C:\MonarchOutput\baseline
Export-GPOAudit -Server $dc -OutputPath C:\MonarchOutput\gpo-audit
Find-DormantAccount -Server $dc -OutputPath C:\MonarchOutput\dormant
```

Check each result. If everything looks right, run the full orchestrator:

```powershell
Invoke-DomainAudit -Phase Discovery -OutputPath C:\MonarchOutput
```

### Post-Run Review

After the first production run:

1. Open `00-Discovery-Report.html` — check the stats bar (critical/advisory counts, function errors)
2. Check the Failures section — any functions that errored? Common: WinRM failures to specific DCs, GPO permission denials
3. Spot-check findings against what you know about the domain:
   - Do the Domain Admin members match what you expect?
   - Are the dormant accounts actually dormant?
   - Do the FSMO roles match your documentation?
4. Check `Warnings` arrays in individual function results for anything unexpected

---

## Quick Reference

```powershell
# === Setup ===
Install-WindowsFeature RSAT-AD-PowerShell, RSAT-ADDS-Tools, GPMC    # Server
Install-Module -Name Pester -Force -SkipPublisherCheck                # Pester 5
Import-Module C:\path\to\monarch-kit\Monarch.psd1                    # Module

# === Mocked Tests (no domain needed) ===
Invoke-Pester -Path .\Tests\Monarch.Tests.ps1 -Output Detailed       # 162 tests

# === Lab Run ===
Invoke-DomainAudit -Phase Discovery -OutputPath C:\LabOutput

# === Production Run ===
$dc = (Resolve-MonarchDC).DCName                                      # Verify DC
Get-ForestDomainLevel -Server $dc                                     # Light test
Invoke-DomainAudit -Phase Discovery -OutputPath C:\MonarchOutput      # Full run
```

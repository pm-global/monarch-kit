# Mechanism Decisions

Technical decisions with rationale. These are not style preferences — each decision has a specific reason documented below. Do not "improve" these mechanisms without understanding why they exist.

---

## Configuration Model

All threshold values, keyword lists, and policy defaults follow the Ghostty model:

- Sane defaults are built into the module. No config file is required. A fresh install works out of the box.
- A config file (`Monarch-Config.psd1`) ships with every default value present but commented out. Uncommenting a value overrides the built-in default.
- The config file is self-documenting — each entry includes a comment explaining what it controls and why the default was chosen.
- The module reads config on load. Missing keys fall back to built-in defaults. A partial config file is valid.

Hardcoded values in function bodies are not acceptable. Every value a thoughtful administrator might want to adjust belongs in the config layer.

### Config Defaults

**Identity Lifecycle**
- Dormancy threshold: 90 days — aligns with PCI/NIST/Microsoft guidance
- Grace period for never-logged-on accounts: 60 days — allows time for new account setup before flagging
- Hold period minimum before deletion: 30 days (configurable 30–365)
- Quarantine OU name: `zQuarantine-Dormant` — the `z` prefix sorts to the bottom of the OU list in ADUC, keeping it out of daily view
- Disable date tracking attribute: `extensionAttribute15` — higher-numbered extensionAttributes are less commonly allocated to HR or directory sync mappings. Configurable for environments where this attribute is in use.
- Service account exclusion keywords: `SERVICE, -SVC, SVC-, _SVC, SVC_, APP-, -APP, BREAKGLASS, SQL, IIS, BACKUP, MONITOR` — BREAKGLASS identifies emergency access accounts that must never be touched by automated processes
- Rollback data attribute: `extensionAttribute14` — stores JSON with source OU and group memberships before suspend. Same rationale as extensionAttribute15: higher-numbered attributes are less commonly claimed. Configurable for environments where this attribute is in use.
- Exclude object types from dormant discovery: Managed Service Accounts (`msDS-ManagedServiceAccount`) and Group Managed Service Accounts (`msDS-GroupManagedServiceAccount`). These are not user accounts and will produce false positives.

**Privileged Access**
- Domain Admin count warning threshold: 5
- Domain Admin count critical threshold: 10
- Admin account naming pattern: `adm|admin` — configurable for environments using different conventions (e.g., `-DA` suffix, `t0-` prefix)
- Permitted GPO editors: `Domain Admins, Enterprise Admins, Group Policy Creator Owners`

**Infrastructure**
- Replication health warning threshold: 24 hours since last successful replication (per-link, not per-DC)

**Compliance**
- Deletion archive retention guidance: 7 years — surfaced in post-deletion output as a reminder, not enforced by the module

---

## Disable Date Tracking

The disable function records the disable timestamp so the delete function can enforce hold periods.

**Implementation:**
- Store disable date in a configurable AD extensionAttribute (default: `extensionAttribute15`)
- Format: ISO 8601 timestamp (`yyyy-MM-ddTHH:mm:ssZ`)
- PowerShell's `[DateTime]::Parse()` handles ISO 8601 natively

**Why extensionAttribute, not the `info` field:**
- extensionAttributes are single-valued strings with no inherited meaning
- The `info` field is multi-line freetext that HR systems, directory sync, and manual admin notes legitimately write to — you don't own it
- extensionAttribute won't be overwritten unless something explicitly targets it
- Queryable: `Get-ADUser -Filter {extensionAttribute15 -like '*'}` returns all accounts with a disable date

**No `whenChanged` fallback.** If the configured extensionAttribute is not set, the account was not disabled by monarch-kit. Do not guess at the date. Either skip the account or surface it as a separate category requiring manual review. DiagnosticHint: `"No monarch-kit disable date found — account may have been disabled manually or before monarch-kit deployment. Verify disable date before permanent deletion."`

**This eliminates inter-function contracts.** The disable and delete functions both use the same AD attribute via standard AD cmdlets. The only contract is "this attribute exists and is configurable."

---

## Rollback Data Archiving

The suspend function must capture enough state for a complete rollback. A reclamation request should restore the account to its exact pre-suspend condition.

**Implementation:**
- Store rollback data in a configurable AD extensionAttribute (default: `extensionAttribute14`)
- Format: JSON object containing source OU and group membership DNs

```json
{
  "sourceOU": "OU=Sales,OU=Users,DC=contoso,DC=com",
  "groups": [
    "CN=SalesTeam,OU=Groups,DC=contoso,DC=com",
    "CN=VPNUsers,OU=Groups,DC=contoso,DC=com"
  ]
}
```

**Suspend writes, restore reads.** Suspend-DormantAccount serializes the data before stripping groups and moving the account. Restore-DormantAccount reads it, restores groups, moves the account back to sourceOU, clears both extensionAttribute14 and extensionAttribute15, and re-enables the account.

**No rollback data = manual recovery.** If extensionAttribute14 is empty, the account was suspended before this mechanism existed or was suspended manually. Surface as a separate category. DiagnosticHint: `"No rollback data found — group memberships and source OU must be restored manually."`

**Same rationale as extensionAttribute15:** single-valued, queryable, not claimed by standard directory sync mappings. Configurable for environments where this attribute is in use.

---

## Privileged Group Matching — RID Suffix Patterns

Match privileged groups by RID suffix pattern, not full SID.

Use `*-512` for Domain Admins, `*-519` for Enterprise Admins, `*-518` for Schema Admins. Do not use full SIDs.

**Why this is a portability requirement:**
- Full SIDs are domain-specific — `S-1-5-21-<domain-prefix>-512` only works in the domain it was captured from
- RID suffix patterns work across any domain because the RID (512, 519, 518) is constant
- A module with hardcoded full SIDs will silently fail to match privileged groups when deployed to a new domain

**Exception:** Well-known local group SIDs (`S-1-5-32-544` Administrators, `S-1-5-32-548` Account Operators, etc.) are stable across all Windows installations and may be used as-is.

---

## GPO High-Risk Detection

Detect high-risk settings (UserRightsAssignment, SecurityOptions, Scripts, SoftwareInstallation) by XML string matching, not structured XML parsing.

```powershell
$XMLContent = $GPOReport.OuterXml
$HasUserRights      = $XMLContent -match "UserRightsAssignment"
$HasSecurityOptions = $XMLContent -match "SecurityOptions"
$HasScripts         = $XMLContent -match "<Script>"
$HasSoftwareInstall = $XMLContent -match "SoftwareInstallation"
```

**Why string matching is correct:** XML namespace handling in GPO reports varies across domain and forest functional levels. Namespace-aware parsing would be cleaner in theory but less reliable in practice. The string-match approach works consistently across all functional level variations.

**Document this decision in code** with a comment explaining why. This prevents future "cleanup" that introduces namespace-handling bugs.

---

## Replication Partition Awareness

Report per-partition status where possible, not just per-link pass/fail.

A DC failing to replicate the Schema partition while successfully replicating the Domain partition is a different problem (less severe) than one failing all partitions.

DiagnosticHint for partial failures: `"Schema partition replicating successfully, Domain partition failing — DNS or site link configuration issue likely"`

The Application partition (used by AD-integrated DNS zones) should be checked explicitly. DNS application partition replication failures are the most common partial-replication scenario in practice and present differently than Schema or Configuration partition failures.

---

## Backup Detection Strategy

**Safety-critical data flow:** Backup age → tombstone gap detection → USN rollback warning. If backup age is null, gap detection silently skips — missing data causes a silent skip of a critical warning, not a loud failure. Graduated confidence reporting is required.

### Tier 1 — Universal (always runs)

No dependency on backup tool availability:

- Tombstone lifetime: query via `(Get-ADRootDSE).configurationNamingContext` → Directory Service object → `tombstoneLifetime` attribute. Default: 180 days (Server 2003 SP1+), 60 days (older).
- AD Recycle Bin status: `(Get-ADOptionalFeature -Filter 'name -like "Recycle Bin Feature"').EnabledScopes` — non-empty = enabled.

### Tier 2 — Windows Server Backup (best-effort)

- Event Log: Microsoft-Windows-Backup source, Event ID 4 (successful backup completion)
- WMI: `root/Microsoft/Windows/Backup` namespace, `MSFT_WBJob` class
- Filter for system state backup type — file-level backups don't protect AD

### Tier 2 — Third-Party Tool Detection (best-effort)

Enumerate services against known backup service names:

```powershell
$KnownBackupServices = @{
    'Veeam'      = @('VeeamBackupSvc', 'VeeamDeploymentService')
    'Acronis'    = @('AcronisCyberProtectService', 'AcronisAgent')
    'Carbonite'  = @('CarboniteService')
    'Commvault'  = @('GxCVD', 'GxVssProv')
    'Arcserve'   = @('CASAD2DWebSvc')
}
```

If detected but backup age unknown: Status = `Unknown` (not `Failed`). DiagnosticHint: `"Third-party backup tool detected ([Vendor]) — configure vendor integration in Monarch-Config.psd1 for automatic last-backup detection."`

### Tier 3 — Vendor-Specific Integration (opt-in)

Config supports PowerShell module, CLI, registry, and event log integration types:

```powershell
# Monarch-Config.psd1
@{
    # BackupIntegration = @{
    #     Type       = 'VeeamModule'  # VeeamModule | CLI | Registry | EventLog
    #     ModuleName = 'Veeam.Backup.PowerShell'
    #     ServerName = 'localhost'
    # }
}
```

Ships with working examples for Veeam (PowerShell module), Acronis (registry key), Commvault (CLI).

### Critical Gap Detection

When backup age IS available: if `backup age in days > tombstone lifetime`, then Status = `Degraded`, CriticalGap = `$true`.

DiagnosticHint: `"Last backup is older than tombstone lifetime ([X] days vs [Y] day limit) — recovery from this backup may cause USN rollback. Verify replication state before attempting any restore operation."`

This is the highest-priority finding in the Backup & Recovery domain.

---

## Monitoring Phase Guidance

**Metrics to track during hold period:**
- Accounts disabled (total count)
- Reclamation requests (how many users asked for accounts back)
- Accounts re-enabled (restored due to valid business need)
- Days in monitoring (hold period elapsed)
- Issues encountered (authentication failures, service interruptions)

**Hold period checkpoints:**
- **Daily:** review authentication failure logs, monitor helpdesk tickets, check for service interruptions
- **Weekly:** review reclamation requests, document re-enabled accounts with justification, update exception list, report metrics to stakeholders
- **Hold period complete:** minimum period elapsed (30–90 days), no outstanding reclamation requests, all exceptions documented, final approval for deletion obtained

**Post-deletion timing warnings** (include in Cleanup phase output):
- "Deletions will replicate to all DCs within 15 minutes"
- "Entra ID Connect (formerly Azure AD Connect) will sync deletions on next cycle (if hybrid environment)"

# Domain Specifications

Complete function lists, return contracts, phase tags, and stratagem composition for all eight monarch-kit domains.

---

## 1. Infrastructure Health

Extends OctoDoc with topology awareness and FSMO intelligence.

**Participates in:** Discovery

**Stratagems composed:**
- DC reachability and health: NTDS, Ping, RPC
- Replication health with per-partition status: Replication, DNS, NTDS
- Time sync with PDC emulator awareness: TimeSync + FSMO role query

**Functions:**
- FSMO role placement + reachability (queries AD directly, not OctoDoc)
- Replication topology health per-link with partition awareness (composes Replication stratagem)
- Site/subnet topology (queries AD directly) -- highest-value checks: IP subnets not assigned to any site (causes clients to authenticate against random DCs) and sites with no DCs assigned (common configuration drift in multi-site environments)
- Forest/domain functional level + schema version (queries AD directly)
- DNS zone health for AD-integrated zones, SRV record completeness per site (queries DNS directly)

Per-partition replication status is a graduated confidence pattern. Full replication success, partial partition success, and total failure are three distinct states with different DiagnosticHints. The Application partition (used by DNS) should be checked explicitly -- DNS application partition replication failures are the most common partial-replication scenario in practice.

---

## 2. Identity Lifecycle

Manages the full account lifecycle from provisioning through deletion.

**Participates in:** All five phases

**Institutional knowledge to preserve:**
- Service account exclusion keywords including BREAKGLASS
- 60-day grace period for never-logged-on accounts
- Cross-DC LastLogon aggregation (accurate dormancy detection) -- use replicated `lastLogonTimestamp` for first pass (good enough for 90-day dormancy threshold), cross-DC `lastLogon` queries only for accounts near the threshold. This optimization matters at scale.
- Disable date tracking in extensionAttribute15 (ISO 8601 format) -- see mechanism-decisions.md
- Rollback data in extensionAttribute14 (JSON: sourceOU + group memberships) -- see mechanism-decisions.md
- 30-day minimum hold period before deletion
- Quarantine OU naming convention: `zQuarantine-Dormant` (z prefix sorts to bottom)
- Exclude Managed Service Accounts (MSA) and Group Managed Service Accounts (gMSA) from dormant account discovery -- these are AD objects, not user accounts, and will produce false positives. Handle separately or exclude entirely.

**Functions:**
- Find-DormantAccount (Discovery) -- queries AD directly with lastLogonTimestamp first pass and cross-DC LastLogon for near-threshold accounts. Excludes MSA/gMSA object types. No stratagem. Returns structured objects AND exports CSV with fields: SamAccountName, DisplayName, LastLogon, DaysSinceLogon, PasswordAgeDays, MemberOfGroups, DormantReason. This CSV is the input for human review.
- Suspend-DormantAccount (Remediation) -- accepts a reviewed CSV path (human-pruned output from Find-DormantAccount) as input. Archives group memberships and source OU to extensionAttribute14 as JSON, then disables, strips groups, moves to quarantine, writes disable date to extensionAttribute15. **Destructive, requires -WhatIf.**
- Restore-DormantAccount (Remediation) -- reads extensionAttribute14, restores group memberships, moves account back to source OU, clears extensionAttribute14 and extensionAttribute15, re-enables account. **Destructive, requires -WhatIf.**
- Get-DormantAccountMonitoringMetrics (Monitoring) -- track accounts disabled, reclamation requests, re-enabled count, days in hold
- Remove-DormantAccount (Cleanup) -- permanent deletion with pre-deletion archive (7-year retention guidance), SID preservation. **Destructive, requires -WhatIf.**
- User provisioning (template-based, OU placement, group membership). **Destructive.**
- Stale computer account discovery

**Human gate pattern:** Discovery outputs a full CSV. The human reviews it, removes accounts to keep, saves the pruned version. Remediation reads the pruned CSV. This is the core safety mechanism -- the automated system never decides which accounts to disable.

**v0 scripts:** Find-DormantAccounts.ps1, Disable-DormantAccounts.ps1, Delete-DormantAccounts.ps1

**Visual language:** The wrapper's console output follows the design system in docs/design-system.md -- console color mapping, spacing translation, and severity prefix conventions.
---

## 3. Privileged Access

Audits and remediates privileged group membership and attack surface.

**Participates in:** Discovery, Remediation

**Institutional knowledge to preserve:**
- Privileged group matching by RID suffix pattern (`*-512` not full SID) -- see mechanism-decisions.md
- Domain Admin count thresholds: 5 (warning), 10 (critical)
- Admin account naming pattern `adm|admin` (configurable)

**Functions:**
- Get-PrivilegedGroupMembership (Discovery) -- enumerate all privileged groups with nested membership. Accepts `-OutputPath` (directory); writes `privileged-groups.csv` when members exist (one row per member, sorted by SamAccountName). Columns: SamAccountName, GroupName, DisplayName, ObjectType, IsDirect, IsEnabled, LastLogon. Return object includes `CSVPath` (null when not written).
- Find-AdminCountOrphan (Discovery) -- accounts with AdminCount=1 but no current privileged group membership. Accepts `-OutputPath` (directory); writes `admincount-orphans.csv` when orphans exist. Columns: SamAccountName, DisplayName, Enabled, MemberOf (DNs joined with `'; '`). Return object includes `CSVPath` (null when not written).
- Find-KerberoastableAccount (Discovery) -- ALL user accounts with SPNs, flag privileged subset separately (not just privileged+SPN). No `-OutputPath`; combined into `roastable-accounts.csv` by the orchestrator.
- Find-ASREPRoastableAccount (Discovery) -- accounts with pre-auth disabled. No `-OutputPath`; combined into `roastable-accounts.csv` by the orchestrator.
- **Orchestrator combine:** After both roastable functions complete, `Invoke-DomainAudit` writes `03-Privileged-Access/roastable-accounts.csv` combining both result sets. Columns: ThreatType (Kerberoast/ASREP), SamAccountName, DisplayName, IsPrivileged, Enabled, SPNs (joined with `'; '`), PasswordAgeDays. ASREP rows have empty SPNs and PasswordAgeDays. File is not written if both functions return zero accounts or both fail.
- Test-TieredAdminCompliance (Discovery) -- verify Tier 0/1/2 separation
- Remove-AdminCountOrphan (Remediation) -- clear AdminCount flag from orphaned accounts. **Destructive, requires -WhatIf.**
- Grant-TimeBoundGroupMembership (Remediation) -- add with auto-expiration. **Destructive, requires -WhatIf.**

**v0 scripts:** Audit-PrivilegedAccess.ps1

---

## 4. Group Policy

Comprehensive GPO documentation, anomaly detection, and backup.

**Participates in:** Discovery, Remediation (backup only)

**Institutional knowledge to preserve:**
- GPO high-risk detection via XML string matching (not namespace-aware parsing) -- see mechanism-decisions.md
- High-risk categories: UserRightsAssignment, SecurityOptions, Scripts, SoftwareInstallation
- Permitted GPO editors: `Domain Admins, Enterprise Admins, Group Policy Creator Owners`
- Numbered output folder convention (00-SUMMARY, 01-HTML, 02-XML, 03-CSV, 04-Permissions, 05-WMI-Filters) for review priority order
- GPO display names must be sanitized for filesystem use (strip `\/:*?"<>|` characters) when generating HTML report filenames
- GPO owner field included in CSV summary output

**Functions:**
- Export-GPOAudit (Discovery) -- comprehensive GPO documentation in multiple formats. Generates:
  - HTML reports per GPO with clickable index page (styled, shows domain info, audit date, GPO count, links to each report)
  - Full XML backup via `Backup-GPO -All` (restore-ready)
  - CSV summary with fields: DisplayName, GUID, CreatedTime, ModifiedTime, UserEnabled, ComputerEnabled, WMIFilter, Description, HasUserRights, HasSecurityOptions, HasScripts, HasSoftwareInstall, Owner
  - CSV linkage detail: GPOName, LinkedTo, Enabled, NoOverride, Order. Unlinked GPOs flagged as `**UNLINKED**`
  - Executive summary text file with statistics (total GPOs, unlinked count, disabled count, high-risk settings counts) and numbered review priorities
  - WMI filter export (optional): queries `msWMI-Som` AD objects, exports name, description, WQL query, dates
  - Permission analysis (optional): per-GPO permissions with trustee, SID, type, permission level, inherited flag. Overpermissioned GPOs exported separately (edit rights outside permitted editors list)
- Find-UnlinkedGPO (Discovery) -- orphaned policies (also surfaced as part of Export-GPOAudit linkage CSV)
- Find-GPOPermissionAnomaly (Discovery) -- non-standard edit rights (also surfaced as part of Export-GPOAudit permission analysis)
- Backup-GPO (Remediation) -- full XML backup for restore capability
- Compare-GPO (Discovery) -- before/after or DC-to-DC comparison

**v0 scripts:** Export-GPOAudit.ps1

---

## 5. Security Posture

Password policy, weak flags, legacy protocol exposure, and baseline compliance.

**Participates in:** Discovery

**Functions:**
- Get-PasswordPolicyInventory (Discovery) -- default domain policy + all fine-grained PSOs
- Find-WeakAccountFlag (Discovery) -- password never expires, reversible encryption, DES enabled
- Test-ProtectedUsersGap (Discovery) -- privileged accounts not in Protected Users group. DiagnosticHint must warn: adding service accounts to Protected Users will break them (Kerberos delegation is disabled, NTLM is blocked). Do not recommend blanket addition without filtering for service accounts.
- Find-LegacyProtocolExposure (Discovery) -- NTLMv1, LM hashes, etc.
- Compare-CISBaseline (Discovery) -- configurable baseline definition (not hardcoded version), structured deviation output

CIS/STIG baseline comparison accepts an external baseline definition rather than hardcoding a specific benchmark version. The comparison mechanism is generic.

---

## 6. Backup & Recovery Readiness

Uses the three-tier graduated confidence model extensively. See mechanism-decisions.md for the complete backup detection strategy and return contract.

**Participates in:** Discovery, Cleanup (compliance archiving context)

**Stratagems composed:**
- Tier 1 (Universal): TombstoneLifetime, RecycleBin (always run, no dependencies)
- Tier 2 (WSB best-effort): WSBackup probe
- Tier 2 (Vendor detection): BackupVendorDetection (service enumeration + event logs)
- Tier 3 (Vendor integration): Configured per environment in Monarch-Config.psd1

**Functions:**
- Get-BackupReadinessStatus (Discovery) -- composes backup readiness stratagem, interprets results across three tiers, returns DetectionTier + DiagnosticHints
- Test-TombstoneGap (Discovery) -- when backup age IS available, compare against tombstone lifetime, flag critical if exceeded

**Critical return contract:**
```powershell
@{
    Domain                = 'BackupReadiness'
    TombstoneLifetimeDays = 180
    RecycleBinEnabled     = $true
    BackupToolDetected    = 'Veeam'       # or $null
    BackupToolSource      = 'ServiceEnum' # ServiceEnum | EventLog | WSB | VendorIntegration
    LastBackupAge         = $null         # [timespan] if tier 3 reached
    BackupAgeSource       = $null         # WSB | VendorIntegration | $null
    DetectionTier         = 2             # 1, 2, or 3
    CriticalGap           = $false        # true if backup age > tombstone lifetime
    Status                = 'Unknown'     # Healthy | Degraded | Unknown
    DiagnosticHint        = "Veeam detected -- configure vendor integration for automatic age detection"
}
```

---

## 7. Audit & Compliance

Domain baseline documentation and change tracking.

**Participates in:** Discovery

**Functions:**
- New-DomainBaseline (Discovery) -- comprehensive domain snapshot (functional levels, DCs, FSMO, OUs, object counts, password policy)
- Get-AuditPolicyConfiguration (Discovery) -- per-DC audit policy settings
- Get-EventLogConfiguration (Discovery) -- log size/retention per DC
- Compare-DomainBaseline (Discovery) -- delta between two snapshots, classify changes as expected/advisory/requires-review

**v0 scripts:** Create-NetworkBaseline.ps1

---

## 8. DNS (AD-Integrated)

AD-integrated DNS zone health and configuration audit.

**Participates in:** Discovery

**Functions:**
- Test-SRVRecordCompleteness (Discovery) -- verify all required SRV records exist per site
- Get-DNSScavengingConfiguration (Discovery) -- scavenging settings per zone
- Test-ZoneReplicationScope (Discovery) -- verify zone is replicated to appropriate DCs
- Get-DNSForwarderConfiguration (Discovery) -- forwarder config per DC

---

## The Three-Layer Execution Model

The v0 script (`Start-NetworkHandover.ps1`) combined interactive guidance with orchestration with execution in one file. Monarch separates these into three layers:

```
Start-MonarchAudit (interactive wrapper -- menu, guidance, human prompts)
    \-- Invoke-DomainAudit (orchestrator -- phase coordination, WhatIf gates, state)
        \-- Individual Monarch functions (API -- structured results)
```

### Layer 1: API Functions (per-domain)

Individual functions that query AD, compose stratagems, interpret results, and return structured objects. These are the functions listed in each domain section above. They have no interactive prompts, no menus, no guidance text. An agent, script, or orchestrator calls them and gets objects back.

### Layer 2: Invoke-DomainAudit (orchestrator)

Coordinates which functions run in which order per phase. Returns structured results. No interactive prompts.

```powershell
# Non-interactive -- returns objects
$results = Invoke-DomainAudit -Phase Discovery
```

**Output directory structure:** The orchestrator creates a date-stamped root directory (`Monarch-Audit-yyyyMMdd`) with numbered subdirectories per domain component:
```
Monarch-Audit-20260321/
+-- 01-Baseline/
+-- 02-GPO-Audit/          (uses Export-GPOAudit's own folder convention internally)
+-- 03-Privileged-Access/
+-- 04-Dormant-Accounts/
\-- 05-Infrastructure/
```

**Phases:**
1. **Discovery** -- calls Discovery functions from all domains, returns collected results
2. **Review** -- returns checklist content and findings for consumer to present (see checklists.md)
3. **Remediation** -- enforces WhatIf preview before execution. Accepts reviewed CSV path for dormant account suspend.
4. **Monitoring** -- returns metrics and hold period status (see mechanism-decisions.md)
5. **Cleanup** -- enforces WhatIf preview before permanent deletion

Maintains phase state between executions. Called with `-Phase` parameter -- no default phase, parameter is required.

### Layer 3: Start-MonarchAudit (interactive wrapper)

The admin-facing entry point. Replaces `Start-NetworkHandover.ps1`. This is what an admin types at a console.

**Default behavior (no arguments):** presents an interactive menu for phase selection, same pattern as the v0 script.

**With arguments:** `Start-MonarchAudit -Phase Discovery` skips the menu and runs that phase directly.

**The wrapper's responsibilities (things the orchestrator does NOT do):**
- Interactive menu (1-5 phase selection, Q to quit)
- Pre-phase guidance ("This phase will...", expected time estimates, pre-flight checklists)
- Timing expectations per step: Discovery overall 30-60 minutes, dormant account cross-DC query 10-20 minutes depending on domain size
- Human confirmations before destructive operations ("Continue with remediation? yes/no")
- Prompting for reviewed CSV path during Remediation ("Path to reviewed dormant accounts CSV")
- Rendering structured results in human-readable format
- Surfacing checklists inline during the Review phase
- Surfacing monitoring metrics template and checkpoint guidance during Monitoring
- Post-phase output summary (listing paths to each output directory)
- Post-phase next steps ("Run: Start-MonarchAudit -Phase Monitoring")
- Post-deletion timing warnings ("Deletions will replicate to all DCs within 15 minutes")
- Press-any-key flow between steps

**The wrapper calls the orchestrator.** It does not call API functions directly. All phase coordination goes through `Invoke-DomainAudit`.

**v0 scripts:** Start-NetworkHandover.ps1

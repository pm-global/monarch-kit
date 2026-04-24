# Phase 2: Remediation, Monitoring, and Cleanup Functions

**Prerequisite:** Phase 1 complete.

**Scope:** Destructive operations with WhatIf support, rollback data, hold period enforcement.

## Functions

| Function | Phase | WhatIf | Key Concern |
|----------|-------|--------|-------------|
| `Suspend-DormantAccount` | Remediation | Yes | Archives rollback data to extensionAttribute14, strips groups, moves to quarantine, writes disable date to extensionAttribute15 |
| `Restore-DormantAccount` | Remediation | Yes | Reads extensionAttribute14, restores groups + OU, clears both attributes, re-enables |
| `Remove-DormantAccount` | Cleanup | Yes | Hold period enforcement via extensionAttribute15, pre-deletion archive, SID preservation |
| `Remove-AdminCountOrphan` | Remediation | Yes | Clears AdminCount flag from orphaned accounts |
| `Grant-TimeBoundGroupMembership` | Remediation | Yes | Adds with auto-expiration via AD TTL mechanism |
| `Backup-GPO` | Remediation | No (read) | Full XML backup for restore capability |
| `Get-DormantAccountMonitoringMetrics` | Monitoring | No (read) | Queries quarantine OU, counts, hold period status |

## Test Focus

WhatIf produces correct preview output. Rollback data serialization/deserialization round-trips
correctly. Hold period calculation correct. Exclusion of accounts without monarch-kit disable
dates. Integration tests for suspend → restore cycle and suspend → delete cycle using mocked AD.

## Implementation Constraints (discovered 2026-03-26)

- **Primary Group handling:** Every AD account must have a Primary Group (typically "Domain Users").
  `Suspend-DormantAccount` cannot strip it — must be excluded from group removal or handled specially.

- **extensionAttribute14 size limit:** AD extensionAttributes 1-15 have a `rangeUpper` of 1024 bytes.
  Users with many group memberships (20+ groups with long DNs) can exceed this. Need pre-write
  validation and a fallback strategy (truncate with warning? separate attribute? file-based archive?).

- **Entra ID Connect sync scope:** Many orgs use OU-based filtering for directory sync. Moving an
  account to `zQuarantine-Dormant` may move it out of sync scope, causing the cloud identity to
  soft-delete. Document as a warning in the wrapper's pre-phase guidance.

- **AdminSDHolder timing:** `adminCount` is set by SDProp on a 60-minute cycle but never cleared
  automatically. `Remove-AdminCountOrphan` should note that accounts removed from privileged groups
  <60 minutes ago may still have adminCount=1 legitimately. Consider a DiagnosticHint.

- **DC targeting for writes:** Discovery uses any healthy DC. Remediation writes (disable, move,
  strip groups) should target the PDC emulator or a specific writable DC to avoid replication
  conflicts.

- **Confirm support:** Add `$ConfirmPreference = 'High'` alongside `-WhatIf` for
  `Remove-DormantAccount` (permanent deletion). Standard PowerShell safety pattern via `ShouldProcess`.

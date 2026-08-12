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

  # TODO-5: Diagnostic Hints — Backlog

Future DiagnosticHint work items and draft text.

## Work items

### 1. Dedupe tombstone-gap critical cards

`Test-TombstoneGap` and `Get-BackupReadinessStatus` both fire a critical
with Description *"Backup age exceeds tombstone lifetime (USN rollback
risk)"* when a Tier-3 backup age exceeds the tombstone lifetime. Two cards,
identical text, same finding.

Options:
- Drop `Test-TombstoneGap`'s extraction branch; fold its hint content into
  `Get-BackupReadinessStatus`'s card.
- Dedupe in the extraction loop: skip TombstoneGap's critical when
  BackupReadinessStatus already fired one.
- Differentiate the wording (not recommended — the identical wording is
  deliberate so the collapse is mechanical).

### 2. Add DiagnosticHints to 7 more functions

Functions that produce critical/advisory findings but emit no
`DiagnosticHint` today:

- `Get-PrivilegedGroupMembership`
- `Get-PasswordPolicyInventory`
- `Find-KerberoastableAccount`
- `Find-ASREPRoastableAccount`
- `Find-WeakAccountFlag`
- `Find-LegacyProtocolExposure`
- `Get-FSMORolePlacement`

Draft text below. Per function: add `DiagnosticHint` to the return object,
add a unit test asserting its content, add the extraction forward in
`New-MonarchReport`, add a flow-through assertion.

### 3. Orphan-finder script

AST-based PowerShell script, ~50–100 lines, runnable from CLI and as a
Pester test. Finds two patterns:

- **Orphan fields** — a field on a function's return `PSCustomObject` that
  nothing downstream reads. PSScriptAnalyzer cannot catch this class because
  PowerShell's dynamic property access (`$obj.$dynamicName`,
  `$obj.PSObject.Properties[...]`) defeats static "defined but never read"
  detection.
- **Orphan results** — a function that runs in the orchestration list
  (`Monarch.psm1` around L3099) but has no case in the `New-MonarchReport`
  extraction switch (L2560–2689).

For each pattern: parse the module, enumerate candidates, report a table.
Baseline known orphans so the first clean run is deterministic. Document
known false-positive classes (dynamic dispatch, splatting, non-report
consumers) in the script header.

Out of scope: CI wiring.

## Draft hint text

Observational voice: mechanics and numbers, no instruction verbs.

`Get-PrivilegedGroupMembership`
- **Hint:** {DomainAdminCount} members in Domain Admins (critical threshold {CriticalThreshold}). Every DA session below Tier 0 exposes the credential to anything on that host.
- **Tools:** `Get-ADGroupMember -Recursive`, `Get-ADUser`
- **Search:** `Tier 0`, `AdminSDHolder`, `adminCount`, `pass-the-hash`

`Get-PasswordPolicyInventory`
- **Hint:** Default Domain Policy has `ReversiblePasswordEncryption` set. New passwords store in `supplementalCredentials` CLEARTEXT; existing hashes persist until each user's next change.
- **Tools:** `Get-ADDefaultDomainPasswordPolicy`, `DSInternals`
- **Search:** `UF_ENCRYPTED_TEXT_PWD_ALLOWED`, `supplementalCredentials`, `Primary:CLEARTEXT`, `DCSync`

`Find-KerberoastableAccount`
- **Hint:** {PrivilegedCount} privileged accounts have SPNs. Any domain user can request a TGS-REP and crack it offline; feasibility depends on password length and encryption type (RC4_HMAC fastest).
- **Tools:** `setspn -L`, `Get-ADServiceAccount`, `Rubeus kerberoast`
- **Search:** `TGS-REP`, `RC4_HMAC`, `msDS-SupportedEncryptionTypes`, `Hashcat 13100`

`Find-ASREPRoastableAccount`
- **Hint:** {Count} accounts have `DONT_REQ_PREAUTH` ({PrivilegedCount} privileged). AS-REP returns without authentication; the encrypted timestamp cracks offline like kerberoast but with no domain foothold needed.
- **Tools:** `Get-ADUser -Filter { DoesNotRequirePreAuth -eq $true }`, `Set-ADAccountControl`
- **Search:** `DONT_REQ_PREAUTH`, `UF_DONT_REQUIRE_PREAUTH`, `AS-REP roasting`, `Hashcat 18200`

`Find-WeakAccountFlag`
- **Hint:** {ReversibleCount} accounts with `AllowReversiblePasswordEncryption`, {DESOnlyCount} with `UseDESKeyOnly`. Reversible stores recoverable plaintext; DES-only forces single-DES Kerberos regardless of `msDS-SupportedEncryptionTypes`.
- **Tools:** `Get-ADUser -Properties AllowReversiblePasswordEncryption, UseDESKeyOnly`, `klist`
- **Search:** `UF_USE_DES_KEY_ONLY`, `UF_ENCRYPTED_TEXT_PWD_ALLOWED`, `supplementalCredentials`

`Find-LegacyProtocolExposure`
- **Hint:** {HighRiskCount} findings across {DCCount} DCs. NTLMv1 (`LmCompatibilityLevel < 3`) reverses to the NT hash; stored LM hashes (`NoLMHash` unset) crack in seconds at any password length.
- **Tools:** `Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\Lsa`, Event 4624 `LmPackageName`
- **Search:** `LmCompatibilityLevel`, `NoLMHash`, `NetNTLMv1`, `Hashcat 5500`

`Get-FSMORolePlacement`
- **Hint:** {UnreachableCount}/5 FSMO holders failed ICMP. PDCEmulator loss is immediate (time, password changes, GPO lock); RID/Schema/Naming losses are latent. ICMP failure alone doesn't confirm down — firewalls produce the same signal.
- **Tools:** `netdom query fsmo`, `ntdsutil roles`, `Test-NetConnection`
- **Search:** `operations master`, `FSMO seize vs transfer`, `RID pool exhaustion`

# Monarch-Kit Development Plan

Checklist-driven implementation plan. Each checkbox is a discrete deliverable. Check items off as they're completed. Every step includes its tests — code and tests ship together, never separately.

**Last updated:** 2026-03-21

---

## Roadmap Overview

| Plan | Scope | Status |
|------|-------|--------|
| **Plan 1** | Discovery phase + orchestrator + tests + reporting | Not started |
| **Plan 2** | Remediation/Monitoring/Cleanup functions + tests | Not started |
| **Plan 3** | Start-MonarchAudit interactive wrapper + tests | Not started |
| **Plan 4** | Comparison functions (GPO, baseline, CIS) + tests | Not started |
| **Plan 5** | OctoDoc stratagem integration (after sensor redesign) | Blocked — waiting on OctoDoc redesign |

Plans are sequential. Each plan depends on the one before it. Plan 5 is triggered externally (OctoDoc redesign), not by Plan 4 completion.

---

## Plan 1: Discovery Phase + Orchestrator + Tests + Reporting

### Scope

Everything needed to run `Invoke-DomainAudit -Phase Discovery -Domain "contoso.com"`, get structured results, and produce a human-readable report. 25 API functions, 1 orchestrator, config layer, module skeleton, report generation, and Pester tests for all of it.

### Universal Decisions (apply to every step)

**Domain parameter threading:**
- `Invoke-DomainAudit` accepts `-Domain [string]` (optional, defaults to current domain via `(Get-ADDomain).DNSRoot`)
- The orchestrator resolves domain → healthy DC once at the top using `Get-HealthyDC`
- All API functions accept `-Server [string]` — can be a DC name or domain FQDN, maps 1:1 to AD cmdlet `-Server` parameter
- The orchestrator always passes the resolved DC name as `-Server`
- Direct callers can pass whatever they want — a DC name, a domain FQDN, or omit it for the local domain default

**Return contract pattern (all functions):**
Every public function returns one or more `[PSCustomObject]` with a `Domain` property naming which functional domain it belongs to (e.g., `'InfrastructureHealth'`, `'IdentityLifecycle'`). No formatted strings as primary output. No Write-Host in API functions. Functions that also produce file output (Export-GPOAudit, Find-DormantAccount) return the structured object AND write files — the object includes paths to generated files.

**Error handling pattern:**
- Read-only functions use `$ErrorActionPreference = 'Continue'` — gather as much as possible, surface errors in a `Warnings` array property on the return object
- Functions that query multiple independent things (baseline, GPO audit) catch per-section and continue
- If the entire function fails (can't reach AD at all), throw — let the orchestrator catch it and record the failure

**Config access pattern:**
All functions read from `$script:Config` (module-scoped variable set at import time). Never from `$Global:` or by re-reading the config file. Config keys are accessed with a helper that falls back to built-in defaults: `Get-MonarchConfigValue -Key 'DormancyThresholdDays'`.

**Test strategy:**
- Pester 5+ tests in `Tests/Monarch.Tests.ps1`, organized by `Describe` blocks per function
- All AD/DNS/GPO cmdlets are mocked — tests run without a domain
- Every function's tests verify: return object has correct properties, correct `Domain` and `Function` values, `Timestamp` is populated, `Warnings` is an array
- Functions with business logic get additional tests: exclusion logic, threshold comparisons, config overrides
- Tests are written alongside code at each step, not after

---

### Step 1: Module Foundation

- [x] **`Monarch.psd1`** — module manifest
  - `RootModule = 'Monarch.psm1'`
  - `RequiredModules = @('ActiveDirectory')` — GroupPolicy and DnsServer are optional, checked at runtime
  - `FunctionsToExport` — explicit list of all public functions (no wildcards)
  - `PowerShellVersion = '5.1'`
- [x] **`Monarch.psm1`** — module script skeleton with `#region` blocks
  ```
  #region Config
  #region Private Helpers
  #region Infrastructure Health
  #region Identity Lifecycle
  #region Privileged Access
  #region Group Policy
  #region Security Posture
  #region Backup and Recovery
  #region Audit and Compliance
  #region DNS
  #region Reporting
  #region Orchestrator
  ```
  Single `.psm1` per CLAUDE.md spec. Refactor to dot-sourced files only if this becomes unwieldy.
- [x] **`Tests/Monarch.Tests.ps1`** — test file skeleton with `BeforeAll` block that imports the module
- [x] **Test: module loads** — `Import-Module` succeeds, manifest lists expected functions, private functions not exported

---

### Step 2: Config Layer

- [x] **`Monarch-Config.psd1`** — ships with all defaults commented out, self-documenting (pre-existing)
- [x] **Built-in defaults hashtable** in `.psm1` (`$script:DefaultConfig`):

  | Key | Default | Rationale |
  |-----|---------|-----------|
  | `DormancyThresholdDays` | 90 | PCI/NIST/Microsoft |
  | `NeverLoggedOnGraceDays` | 60 | New account setup window |
  | `HoldPeriodMinimumDays` | 30 | Minimum before deletion |
  | `QuarantineOUName` | `zQuarantine-Dormant` | z-prefix sorts to bottom |
  | `DisableDateAttribute` | `extensionAttribute15` | Less commonly claimed |
  | `RollbackDataAttribute` | `extensionAttribute14` | Same rationale |
  | `ServiceAccountKeywords` | `@('SERVICE','-SVC','SVC-','_SVC','SVC_','APP-','-APP','BREAKGLASS','SQL','IIS','BACKUP','MONITOR')` | From v0 |
  | `BuiltInExclusions` | `@('Administrator','Guest','krbtgt','DefaultAccount','WDAGUtilityAccount')` | From v0 |
  | `DomainAdminWarningThreshold` | 5 | Per spec |
  | `DomainAdminCriticalThreshold` | 10 | Per spec |
  | `AdminAccountPattern` | `'adm\|admin'` | Configurable regex |
  | `PermittedGPOEditors` | `@('Domain Admins','Enterprise Admins','Group Policy Creator Owners')` | Per spec |
  | `ReplicationWarningThresholdHours` | 24 | Per spec |
  | `DeletionArchiveRetentionYears` | 7 | Compliance guidance |
  | `KnownBackupServices` | `@{ Veeam = @(...); Acronis = @(...); ... }` | Tier 2 vendor service detection |
  | `BackupIntegration` | `$null` | Opt-in, tier 3 |
  | `HealthyDCThreshold` | 7 | For Get-HealthyDC |

  Key names aligned to existing `Monarch-Config.psd1` (e.g., `NeverLoggedOnGraceDays` not `GracePeriodDays`, `ReplicationWarningThresholdHours` not `ReplicationWarningHours`).

- [x] **`Import-MonarchConfig`** (private) — called once at module load. Reads `Monarch-Config.psd1` from module directory if it exists, merges with built-in defaults (file wins), stores in `$script:Config`
- [x] **`Get-MonarchConfigValue`** (private) — takes `-Key [string]`, returns value from `$script:Config`. Single access point — never index `$script:Config` directly in function bodies
- [x] **Tests: config layer** (14 tests passing)
  - Default values are correct when no config file exists
  - Config file overrides specific keys while preserving other defaults
  - `Get-MonarchConfigValue` returns expected values
  - Missing key returns `$null` (no throw)

---

### Step 3: Target Resolution

- [x] **`Resolve-MonarchDC`** (private)

  | Parameter | Type | Default |
  |-----------|------|---------|
  | `-Domain` | string | `$null` |

  Logic:
  1. If `-Domain` is null, set to `(Get-ADDomain).DNSRoot`
  2. Try `Get-HealthyDC -Detailed -Threshold (Get-MonarchConfigValue 'HealthyDCThreshold')` if OctoDoc is loaded
  3. If Get-HealthyDC fails or OctoDoc isn't available, fall back to `(Get-ADDomainController -DomainName $Domain -Discover).HostName`
  4. Return `[PSCustomObject]@{ DCName = $dc; Domain = $domain; Source = 'HealthyDC'|'Discovered' }`

  Why the fallback: OctoDoc is MVP with stubs. If it's not installed or fails, the audit should still work.

- [x] **Tests: target resolution** (5 tests passing)
  - With OctoDoc available: returns HealthyDC source
  - With OctoDoc unavailable (mock `Get-Command` returns nothing): falls back to Discovered source
  - With OctoDoc throwing: falls back to Discovered source
  - With no domain: uses current domain from mocked `Get-ADDomain`
  - Return shape has DCName, Domain, Source properties

---

### Step 4: New-DomainBaseline (pattern-setting function)

This is the first API function built. It establishes the pattern all subsequent functions follow.

- [x] **`New-DomainBaseline`** function

  Signature:
  ```
  function New-DomainBaseline {
      [CmdletBinding()]
      param(
          [string]$Server,
          [string]$OutputPath
      )
  ```

  Return contract:
  ```
  [PSCustomObject]@{
      Domain              = 'AuditCompliance'
      Function            = 'New-DomainBaseline'
      Timestamp           = [datetime]
      Server              = [string]
      DomainDNSRoot       = [string]
      DomainNetBIOS       = [string]
      DomainFunctionalLevel = [string]
      ForestName          = [string]
      ForestFunctionalLevel = [string]
      SchemaVersion       = [int]
      DomainControllers   = @([PSCustomObject]@{
          HostName = [string]; Site = [string]; OS = [string]
          IPv4 = [string]; IsGC = [bool]; IsRODC = [bool]
      })
      FSMORoles           = [PSCustomObject]@{
          SchemaMaster = [string]; DomainNaming = [string]
          PDCEmulator = [string]; RIDMaster = [string]
          Infrastructure = [string]
      }
      SiteCount           = [int]
      OUCount             = [int]
      UserCount           = [PSCustomObject]@{ Total = [int]; Enabled = [int] }
      ComputerCount       = [PSCustomObject]@{ Total = [int]; Enabled = [int] }
      GroupCount          = [int]
      PasswordPolicy      = [PSCustomObject]
      OutputFiles         = @([string])
      Warnings            = @([string])
  }
  ```

  V0 reference: `Create-NetworkBaseline.ps1` — carry the section-by-section approach with `try/catch` per section and `$ErrorActionPreference = 'Continue'`. Drop the text report generation (the return object IS the structured output). Keep CSV exports for each section to `$OutputPath`.

  Changes from v0:
  - Returns object instead of writing text report
  - FSMO is a sub-object, not a separate function
  - Schema version added (query `CN=Schema,CN=Configuration` for `objectVersion`)
  - Password policy included (v0 had this as a separate section)
  - DNS zones removed (belongs to DNS domain functions)
  - DHCP removed (not in spec)

- [x] **Tests: New-DomainBaseline** (27 tests — 11 shape/metadata, 9 resilience, 7 CSV export)
  - Return object has all required properties
  - `Domain` = `'AuditCompliance'`, `Function` = `'New-DomainBaseline'`
  - `Timestamp` is populated and recent
  - `Warnings` is an array
  - When a section fails (mock one cmdlet to throw), it appears in Warnings and other sections still populate
  - CSV files are written to `$OutputPath` when provided
  - `DomainControllers` is an array of objects with correct sub-properties

---

### Step 5: Infrastructure Health

Four functions, all follow the Step 4 pattern.

- [x] **5a. `Get-FSMORolePlacement`**

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'InfrastructureHealth'
      Function  = 'Get-FSMORolePlacement'
      Timestamp = [datetime]
      Roles     = @([PSCustomObject]@{
          Role      = [string]   # SchemaMaster|DomainNaming|PDCEmulator|RIDMaster|Infrastructure
          Holder    = [string]   # FQDN
          Reachable = [bool]
          Site      = [string]
      })
      AllOnOneDC     = [bool]
      UnreachableCount = [int]
      Warnings       = @()
  }
  ```

  Logic: `Get-ADDomain` + `Get-ADForest` for role holders, then `Test-Connection -Count 1` each. Lightweight.

- [x] **Tests: Get-FSMORolePlacement**
  - Return shape correct
  - `AllOnOneDC` = `$true` when all mocked roles point to same DC
  - `AllOnOneDC` = `$false` when roles are distributed
  - Unreachable DC (mock Test-Connection to fail) shows `Reachable = $false` and increments `UnreachableCount`

- [x] **5b. `Get-ReplicationHealth`**

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'InfrastructureHealth'
      Function  = 'Get-ReplicationHealth'
      Timestamp = [datetime]
      Links     = @([PSCustomObject]@{
          SourceDC      = [string]
          PartnerDC     = [string]
          Partition     = [string]       # Schema|Configuration|Domain|DomainDNS|ForestDNS
          LastSuccess   = [datetime]     # $null if never
          LastAttempt   = [datetime]
          ConsecutiveFailures = [int]
          Status        = [string]       # Healthy|Warning|Failed
      })
      HealthyLinkCount  = [int]
      WarningLinkCount  = [int]
      FailedLinkCount   = [int]
      DiagnosticHints   = @([string])
      Warnings          = @()
  }
  ```

  Logic: `Get-ADReplicationPartnerMetadata -Target * -Scope Forest` (or per-DC if that fails). Status = Healthy if last success < configurable `ReplicationWarningHours` (default 24h), Warning if > threshold but < 2× threshold, Failed if > 2× or consecutive failures > 0. DiagnosticHints generated for partial-partition failures.

  V0 reference: `Create-NetworkBaseline.ps1` replication section — carry per-DC iteration, add partition awareness and DiagnosticHints.

- [x] **Tests: Get-ReplicationHealth**
  - Healthy link (last success 2 hours ago) → Status = 'Healthy'
  - Warning link (last success 30 hours ago, default 24h threshold) → Status = 'Warning'
  - Failed link (consecutive failures > 0) → Status = 'Failed'
  - Counts are correct across mixed health states
  - DiagnosticHints generated when one partition fails but another succeeds on same link
  - Config override: custom `ReplicationWarningHours` changes threshold

- [x] **5c. `Get-SiteTopology`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'InfrastructureHealth'
      Function  = 'Get-SiteTopology'
      Timestamp = [datetime]
      Sites     = @([PSCustomObject]@{
          Name     = [string]
          DCCount  = [int]
          Subnets  = @([string])
      })
      UnassignedSubnets = @([string])
      EmptySites        = @([string])
      SiteCount         = [int]
      SubnetCount       = [int]
      Warnings          = @()
  }
  ```

  Logic: `Get-ADReplicationSite -Filter *`, `Get-ADReplicationSubnet -Filter *`. Subnets where `.Site` is null → UnassignedSubnets. Sites with no matching DC → EmptySites.

- [x] **Tests: Get-SiteTopology**
  - Subnet with no site → appears in `UnassignedSubnets`
  - Site with no DCs → appears in `EmptySites`
  - Counts match mocked data

- [x] **5d. `Get-ForestDomainLevel`**

  Trivial function. Returns functional levels and schema version.

  Return contract:
  ```
  [PSCustomObject]@{
      Domain              = 'InfrastructureHealth'
      Function            = 'Get-ForestDomainLevel'
      Timestamp           = [datetime]
      DomainFunctionalLevel = [string]
      ForestFunctionalLevel = [string]
      SchemaVersion       = [int]
      DomainDNSRoot       = [string]
      ForestName          = [string]
      Warnings            = @()
  }
  ```

  Note: Overlaps with `New-DomainBaseline`. Intentional — baseline is a snapshot document, this is a focused check. Both are cheap AD queries.

- [x] **Tests: Get-ForestDomainLevel**
  - Return shape correct
  - Schema version populated from mocked AD object

---

### Step 6: Security Posture

- [x] **6a. `Get-PasswordPolicyInventory`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain          = 'SecurityPosture'
      Function        = 'Get-PasswordPolicyInventory'
      Timestamp       = [datetime]
      DefaultPolicy   = [PSCustomObject]@{
          MinLength = [int]; HistoryCount = [int]; MaxAgeDays = [int]
          MinAgeDays = [int]; LockoutThreshold = [int]
          LockoutDurationMin = [int]; ComplexityEnabled = [bool]
          ReversibleEncryption = [bool]
      }
      FineGrainedPolicies = @([PSCustomObject]@{
          Name = [string]; Precedence = [int]; AppliesTo = @([string])
          MinLength = [int]; MaxAgeDays = [int]; LockoutThreshold = [int]
      })
      Warnings        = @()
  }
  ```

  Logic: `Get-ADDefaultDomainPasswordPolicy` + `Get-ADFineGrainedPasswordPolicy -Filter *`. Shape into objects.

- [x] **Tests: Get-PasswordPolicyInventory**
  - Return shape correct
  - FineGrainedPolicies is empty array when none exist (not `$null`)

- [x] **6b. `Find-WeakAccountFlag`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'SecurityPosture'
      Function  = 'Find-WeakAccountFlag'
      Timestamp = [datetime]
      Findings  = @([PSCustomObject]@{
          SamAccountName = [string]
          DisplayName    = [string]
          Flag           = [string]  # PasswordNeverExpires|ReversibleEncryption|DESOnly
          Enabled        = [bool]
          IsPrivileged   = [bool]
      })
      CountByFlag = [hashtable]      # { PasswordNeverExpires = 42; ... }
      Warnings    = @()
  }
  ```

  Logic: Three `Get-ADUser -Filter` queries for each flag. Union, deduplicate, cross-reference with privileged group membership.

- [x] **Tests: Find-WeakAccountFlag**
  - Account with multiple flags appears once per flag
  - `IsPrivileged` correctly set based on mocked group membership
  - `CountByFlag` totals match `Findings` array

- [x] **6c. `Test-ProtectedUsersGap`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'SecurityPosture'
      Function  = 'Test-ProtectedUsersGap'
      Timestamp = [datetime]
      ProtectedUsersMembers = @([string])
      GapAccounts = @([PSCustomObject]@{
          SamAccountName = [string]
          PrivilegedGroups = @([string])
          HasSPN     = [bool]
      })
      DiagnosticHint = [string]
      Warnings       = @()
  }
  ```

  Critical per spec: DiagnosticHint MUST warn that adding service accounts (HasSPN = true) to Protected Users will break them. Never recommend blanket addition.

- [x] **Tests: Test-ProtectedUsersGap**
  - Privileged account not in Protected Users → appears in GapAccounts
  - Privileged account already in Protected Users → not in GapAccounts
  - Account with SPN in GapAccounts → `HasSPN = $true`
  - DiagnosticHint contains SPN warning when any GapAccount has SPN

- [x] **6d. `Find-LegacyProtocolExposure`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'SecurityPosture'
      Function  = 'Find-LegacyProtocolExposure'
      Timestamp = [datetime]
      DCFindings = @([PSCustomObject]@{
          DCName    = [string]
          Finding   = [string]  # NTLMv1Enabled|LMHashStored|LDAPSigningDisabled|...
          Value     = [string]
          Risk      = [string]  # High|Medium
      })
      Warnings    = @()
  }
  ```

  Logic: For each DC, query registry keys (`LmCompatibilityLevel`, `NoLMHash`, LDAP signing). Use `Invoke-Command` or direct registry queries. If remote registry fails, add to Warnings and continue.

- [x] **Tests: Find-LegacyProtocolExposure**
  - LmCompatibilityLevel < 3 → NTLMv1Enabled finding
  - Unreachable DC → appears in Warnings, doesn't block other DCs

---

### Step 7: Privileged Access

- [x] **7a. `Get-PrivilegedGroupMembership`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'PrivilegedAccess'
      Function  = 'Get-PrivilegedGroupMembership'
      Timestamp = [datetime]
      Groups    = @([PSCustomObject]@{
          GroupName    = [string]
          GroupSID     = [string]
          MemberCount  = [int]
          Members      = @([PSCustomObject]@{
              SamAccountName = [string]; DisplayName = [string]
              ObjectType = [string]; IsDirect = [bool]; IsEnabled = [bool]
              LastLogon = [datetime]
          })
      })
      DomainAdminCount = [int]
      DomainAdminStatus = [string]  # OK|Warning|Critical
      Warnings         = @()
  }
  ```

  Privileged groups by RID suffix pattern per mechanism-decisions.md: `*-512` (Domain Admins), `*-518` (Schema Admins), `*-519` (Enterprise Admins). Plus well-known SIDs: `S-1-5-32-544`, `S-1-5-32-548`, `S-1-5-32-549`, `S-1-5-32-551`.

  Nested membership: `Get-ADGroupMember -Recursive`. Track direct vs. nested via non-recursive call first, then recursive — members only in recursive set are nested.

  DomainAdminStatus: Compare count against config thresholds (5 = Warning, 10 = Critical).

- [x] **Tests: Get-PrivilegedGroupMembership**
  - Groups matched by RID suffix, not full SID
  - Nested member has `IsDirect = $false`
  - Direct member has `IsDirect = $true`
  - DomainAdminCount = 3 → `DomainAdminStatus = 'OK'`
  - DomainAdminCount = 7 → `DomainAdminStatus = 'Warning'`
  - DomainAdminCount = 12 → `DomainAdminStatus = 'Critical'`
  - Config override changes thresholds

- [x] **7b. `Find-AdminCountOrphan`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'PrivilegedAccess'
      Function  = 'Find-AdminCountOrphan'
      Timestamp = [datetime]
      Orphans   = @([PSCustomObject]@{
          SamAccountName = [string]
          DisplayName    = [string]
          Enabled        = [bool]
          MemberOf       = @([string])
      })
      Count     = [int]
      Warnings  = @()
  }
  ```

  Logic: `Get-ADUser -Filter {AdminCount -eq 1}`, cross-reference with privileged groups using RID pattern. AdminCount=1 but not in any privileged group = orphan.

  Design decision: Queries privileged groups independently (same RID pattern logic), does NOT call `Get-PrivilegedGroupMembership` internally. Duplicating three lines of group enumeration is better than creating a function dependency.

- [x] **Tests: Find-AdminCountOrphan**
  - Account with AdminCount=1 and no privileged group → is an orphan
  - Account with AdminCount=1 in Domain Admins → not an orphan
  - Count matches Orphans array length

- [x] **7c. `Find-KerberoastableAccount`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'PrivilegedAccess'
      Function  = 'Find-KerberoastableAccount'
      Timestamp = [datetime]
      Accounts  = @([PSCustomObject]@{
          SamAccountName = [string]
          DisplayName    = [string]
          SPNs           = @([string])
          IsPrivileged   = [bool]
          PasswordAgeDays = [int]
          Enabled        = [bool]
      })
      TotalCount      = [int]
      PrivilegedCount = [int]
      Warnings        = @()
  }
  ```

  Per spec: Return ALL accounts with SPNs, not just privileged ones. `IsPrivileged` flag lets consumers filter.

- [x] **Tests: Find-KerberoastableAccount**
  - Non-privileged account with SPN → included, `IsPrivileged = $false`
  - Privileged account with SPN → included, `IsPrivileged = $true`
  - `PrivilegedCount` counts only `IsPrivileged = $true` entries
  - `TotalCount` = total entries

- [x] **7d. `Find-ASREPRoastableAccount`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'PrivilegedAccess'
      Function  = 'Find-ASREPRoastableAccount'
      Timestamp = [datetime]
      Accounts  = @([PSCustomObject]@{
          SamAccountName = [string]
          DisplayName    = [string]
          IsPrivileged   = [bool]
          Enabled        = [bool]
      })
      Count     = [int]
      Warnings  = @()
  }
  ```

  Logic: `Get-ADUser -Filter {DoesNotRequirePreAuth -eq $true}`.

- [x] **Tests: Find-ASREPRoastableAccount**
  - Return shape correct
  - Count matches array length

---

### Step 8: Find-DormantAccount

Most complex single function. Heaviest v0 reference.

- [ ] **`Find-DormantAccount`**

  Signature:
  ```
  function Find-DormantAccount {
      [CmdletBinding()]
      param(
          [string]$Server,
          [string]$OutputPath
      )
  ```

  Return contract:
  ```
  [PSCustomObject]@{
      Domain       = 'IdentityLifecycle'
      Function     = 'Find-DormantAccount'
      Timestamp    = [datetime]
      ThresholdDays = [int]
      Accounts     = @([PSCustomObject]@{
          SamAccountName  = [string]
          DisplayName     = [string]
          LastLogon       = [datetime]    # $null if never
          DaysSinceLogon  = [int]         # -1 if never
          PasswordLastSet = [datetime]
          PasswordAgeDays = [int]
          MemberOfGroups  = [string]      # semicolon-delimited group names
          DormantReason   = [string]
          DistinguishedName = [string]
      })
      CSVPath      = [string]
      TotalCount   = [int]
      NeverLoggedOnCount = [int]
      ExcludedCount = [int]
      Warnings     = @()
  }
  ```

  Key logic changes from v0:

  1. **lastLogonTimestamp optimization (spec requirement):** First pass uses `lastLogonTimestamp` (replicated, no cross-DC queries). Only accounts within 15 days of the dormancy threshold get the expensive cross-DC `lastLogon` query. Changes from O(users × DCs) to O(near-threshold-users × DCs).
  2. **MSA/gMSA exclusion (spec requirement, missing from v0):** Filter out `objectClass -eq 'msDS-ManagedServiceAccount'` and `'msDS-GroupManagedServiceAccount'` in the initial query.
  3. **Config-driven values:** Dormancy threshold, grace period, service account keywords, built-in exclusions — all from config, not hardcoded.
  4. **Returns objects AND exports CSV.** V0 only exported CSV.
  5. **Exclusion logic carried from v0:** Built-in accounts, PasswordNeverExpires, SPNs, keyword matching, privileged group membership (via RID pattern). All correct in v0, just config-driven now.

  CSV fields per spec: SamAccountName, DisplayName, LastLogon, DaysSinceLogon, PasswordAgeDays, MemberOfGroups, DormantReason.

- [ ] **Tests: Find-DormantAccount**
  - Account with no logon for 100 days → included with correct DormantReason
  - Account with logon 30 days ago → excluded
  - Built-in account (Administrator) → excluded
  - Account with PasswordNeverExpires → excluded
  - Account with SPN → excluded
  - Account matching service keyword (e.g., "SVC-Backup") → excluded
  - MSA/gMSA object → excluded
  - Account in privileged group → excluded
  - Never-logged-on account created 10 days ago → excluded (grace period)
  - Never-logged-on account created 90 days ago → included
  - `ExcludedCount` = total users minus included count
  - CSV written to OutputPath with correct columns
  - Config override: custom `DormancyThresholdDays` changes threshold
  - Config override: custom `ServiceAccountKeywords` changes exclusion

---

### Step 9: Export-GPOAudit

Most complex output function. Multiple files in multiple formats.

- [ ] **`Export-GPOAudit`**

  Signature:
  ```
  function Export-GPOAudit {
      [CmdletBinding()]
      param(
          [string]$Server,
          [string]$OutputPath,
          [switch]$IncludePermissions,
          [switch]$IncludeWMIFilters
      )
  ```

  Return contract:
  ```
  [PSCustomObject]@{
      Domain         = 'GroupPolicy'
      Function       = 'Export-GPOAudit'
      Timestamp      = [datetime]
      TotalGPOs      = [int]
      UnlinkedCount  = [int]
      DisabledCount  = [int]
      HighRiskCounts = [PSCustomObject]@{
          UserRights     = [int]
          SecurityOptions = [int]
          Scripts        = [int]
          SoftwareInstall = [int]
      }
      OverpermissionedCount = [int]     # $null if -IncludePermissions not set
      OutputPaths    = [PSCustomObject]@{
          Summary     = [string]
          HTML        = [string]
          XML         = [string]
          CSV         = [string]
          Permissions = [string]        # $null if not included
          WMI         = [string]        # $null if not included
      }
      Warnings       = @()
  }
  ```

  Carry from v0 almost entirely:
  - Folder numbering convention (00-SUMMARY through 05-WMI-Filters) — exact match
  - HTML index generation with styled template — carry as-is
  - XML backup via `Backup-GPO -All` — carry as-is
  - CSV summary with high-risk string matching — carry, already matches spec
  - Linkage CSV with `**UNLINKED**` — carry as-is
  - Permission analysis with overpermission detection — carry, use config for permitted editors
  - WMI filter export — carry as-is
  - Executive summary text — carry as-is
  - Filename sanitization (`-replace '[\\/:*?"<>|]', '_'`) — carry from v0

  Changes from v0:
  - Returns structured summary object (v0 had no return value)
  - Permitted editors from config instead of hardcoded
  - `Get-GPOReport` calls use `-Server $Server` for domain targeting
  - Drop `Write-Log` — use `Write-Verbose`, collect errors in Warnings

- [ ] **`Find-UnlinkedGPO`** — standalone function sharing GPO query logic (not a wrapper around Export-GPOAudit). Returns just the unlinked GPOs without file generation.
- [ ] **`Find-GPOPermissionAnomaly`** — standalone function. Returns overpermissioned GPOs without file generation. Uses config for permitted editors.

- [ ] **Tests: Export-GPOAudit**
  - Return shape correct
  - High-risk detection: GPO XML containing "UserRightsAssignment" → counted (string match, not XML parse — per mechanism-decisions.md)
  - Unlinked GPO (no LinksTo in report) → counted and flagged as `**UNLINKED**` in linkage CSV
  - OutputPaths populated when OutputPath provided
  - `OverpermissionedCount` is `$null` when `-IncludePermissions` not set
  - Filename sanitization strips invalid characters
- [ ] **Tests: Find-UnlinkedGPO**
  - GPO with no links → returned
  - GPO with links → not returned
- [ ] **Tests: Find-GPOPermissionAnomaly**
  - Non-standard editor → returned
  - Standard editor (from config `PermittedGPOEditors`) → not returned

---

### Step 10: Backup & Recovery

- [ ] **10a. `Get-BackupReadinessStatus`**

  Return contract (matches spec exactly):
  ```
  [PSCustomObject]@{
      Domain                = 'BackupReadiness'
      Function              = 'Get-BackupReadinessStatus'
      Timestamp             = [datetime]
      TombstoneLifetimeDays = [int]
      RecycleBinEnabled     = [bool]
      BackupToolDetected    = [string]       # vendor name or $null
      BackupToolSource      = [string]       # ServiceEnum|EventLog|WSB|VendorIntegration|$null
      LastBackupAge         = $null          # [timespan] if tier 3 reached
      BackupAgeSource       = [string]       # WSB|VendorIntegration|$null
      DetectionTier         = [int]          # 1, 2, or 3
      CriticalGap           = [bool]         # backup age > tombstone lifetime
      Status                = [string]       # Healthy|Degraded|Unknown
      DiagnosticHint        = [string]
      Warnings              = @()
  }
  ```

  Logic per tier:
  - **Tier 1 (always):** Tombstone lifetime from Directory Service config object (default 180 if not set). Recycle Bin via `Get-ADOptionalFeature`.
  - **Tier 2 WSB:** Event log `Microsoft-Windows-Backup` Event ID 4. WMI `root/Microsoft/Windows/Backup`. Filter for system state.
  - **Tier 2 Vendor:** Enumerate services against known backup service names from mechanism-decisions.md.
  - **Tier 3:** Only if `BackupIntegration` config is set. Execute configured integration type.

  CriticalGap only evaluated if `LastBackupAge` is not null.

- [ ] **Tests: Get-BackupReadinessStatus**
  - Tier 1 only (no backup tool detected) → `DetectionTier = 1`, `Status = 'Unknown'`
  - Tier 2 with Veeam service detected → `DetectionTier = 2`, `BackupToolDetected = 'Veeam'`, `BackupToolSource = 'ServiceEnum'`
  - Tier 3 with backup age available and within tombstone → `CriticalGap = $false`, `Status = 'Healthy'`
  - Tier 3 with backup age exceeding tombstone → `CriticalGap = $true`, `Status = 'Degraded'`, DiagnosticHint contains USN rollback warning
  - Tombstone lifetime defaults to 180 when attribute is not set
  - Recycle Bin detection: empty EnabledScopes → `$false`

- [ ] **10b. `Test-TombstoneGap`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain                = 'BackupReadiness'
      Function              = 'Test-TombstoneGap'
      Timestamp             = [datetime]
      TombstoneLifetimeDays = [int]
      BackupAgeDays         = [int]          # $null if unknown
      CriticalGap           = [bool]         # $null if backup age unknown
      DiagnosticHint        = [string]
      Warnings              = @()
  }
  ```

  Separately callable with `-BackupAgeDays [int]` and `-Server [string]`. If `-BackupAgeDays` omitted, `CriticalGap = $null`.

- [ ] **Tests: Test-TombstoneGap**
  - BackupAgeDays = 100, tombstone = 180 → `CriticalGap = $false`
  - BackupAgeDays = 200, tombstone = 180 → `CriticalGap = $true`
  - BackupAgeDays omitted → `CriticalGap = $null`, DiagnosticHint explains backup age required

---

### Step 11: DNS

All four functions require DnsServer module. Each checks availability first — if not available, returns result with Warnings.

- [ ] **11a. `Test-SRVRecordCompleteness`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'DNS'
      Function  = 'Test-SRVRecordCompleteness'
      Timestamp = [datetime]
      Sites     = @([PSCustomObject]@{
          SiteName       = [string]
          ExpectedRecords = [int]
          FoundRecords   = [int]
          MissingRecords = @([string])
      })
      AllComplete = [bool]
      Warnings    = @()
  }
  ```

  Logic: For each AD site, verify `_ldap._tcp`, `_kerberos._tcp`, `_kpasswd._tcp`, `_gc._tcp` per-site SRV records.

- [ ] **11b. `Get-DNSScavengingConfiguration`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'DNS'
      Function  = 'Get-DNSScavengingConfiguration'
      Timestamp = [datetime]
      Zones     = @([PSCustomObject]@{
          ZoneName        = [string]
          ScavengingEnabled = [bool]
          NoRefreshInterval = [timespan]
          RefreshInterval   = [timespan]
      })
      Warnings  = @()
  }
  ```

- [ ] **11c. `Test-ZoneReplicationScope`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'DNS'
      Function  = 'Test-ZoneReplicationScope'
      Timestamp = [datetime]
      Zones     = @([PSCustomObject]@{
          ZoneName         = [string]
          IsDsIntegrated   = [bool]
          ReplicationScope = [string]   # Forest|Domain|Legacy|Custom
          ZoneType         = [string]
      })
      Warnings  = @()
  }
  ```

- [ ] **11d. `Get-DNSForwarderConfiguration`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'DNS'
      Function  = 'Get-DNSForwarderConfiguration'
      Timestamp = [datetime]
      DCForwarders = @([PSCustomObject]@{
          DCName      = [string]
          Forwarders  = @([string])
          UseRootHints = [bool]
      })
      Consistent  = [bool]
      Warnings    = @()
  }
  ```

- [ ] **Tests: DNS functions (all four)**
  - DnsServer module unavailable → result returned with Warnings containing module message, no throw
  - DnsServer module available → correct return shapes
  - `Test-SRVRecordCompleteness`: missing record → appears in MissingRecords, `AllComplete = $false`
  - `Get-DNSForwarderConfiguration`: DCs with different forwarders → `Consistent = $false`

---

### Step 12: Audit & Compliance (remaining)

- [ ] **12a. `Get-AuditPolicyConfiguration`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'AuditCompliance'
      Function  = 'Get-AuditPolicyConfiguration'
      Timestamp = [datetime]
      DCs       = @([PSCustomObject]@{
          DCName     = [string]
          Categories = @([PSCustomObject]@{
              Category    = [string]
              Subcategory = [string]
              Setting     = [string]  # Success|Failure|Success and Failure|No Auditing
          })
      })
      Consistent = [bool]
      Warnings   = @()
  }
  ```

  Logic: `auditpol /get /category:*` over remoting per DC.

- [ ] **12b. `Get-EventLogConfiguration`**

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'AuditCompliance'
      Function  = 'Get-EventLogConfiguration'
      Timestamp = [datetime]
      DCs       = @([PSCustomObject]@{
          DCName = [string]
          Logs   = @([PSCustomObject]@{
              LogName      = [string]
              MaxSizeKB    = [int]
              RetentionDays = [int]
              OverflowAction = [string]
          })
      })
      Warnings  = @()
  }
  ```

  Logs checked: Security, System, Directory Service.

- [ ] **Tests: Audit & Compliance functions**
  - `Get-AuditPolicyConfiguration`: DCs with identical settings → `Consistent = $true`
  - `Get-AuditPolicyConfiguration`: DCs with different settings → `Consistent = $false`
  - `Get-EventLogConfiguration`: return shape correct per DC per log
  - Unreachable DC → in Warnings, doesn't block other DCs

---

### Step 13: Reporting

Discovery results need a human-readable report. The structured objects from all functions are the data source. Reporting is a presentation concern — it reads the orchestrator's return object and generates output.

- [ ] **`New-MonarchReport`** (private or public — decide during implementation)

  | Parameter | Type | Description |
  |-----------|------|-------------|
  | `-Results` | PSCustomObject | The orchestrator's return object |
  | `-OutputPath` | string | Directory to write the report |
  | `-Format` | string | `'HTML'` (default), future: `'Text'` |

  Generates a single-page HTML report summarizing Discovery findings:
  - Header: domain, DC used, audit date, duration
  - Section per domain with findings summary (counts, status indicators)
  - Critical findings highlighted (backup gap, failed replication, high DA count, dormant account count)
  - Links to detailed output files (CSVs, GPO HTML index)
  - Advisory items listed (unlinked GPOs, AdminCount orphans, weak flags)
  - Clean, professional styling (same Segoe UI style as the v0 GPO index page)

  Design: The report reads the `Results` array from the orchestrator, iterates by `Domain` property, and renders each section. It never calls API functions — it only consumes their output. This means reporting can't drift from the actual data.

- [ ] **Orchestrator integration** — `Invoke-DomainAudit -Phase Discovery` calls `New-MonarchReport` at the end of Discovery, writes it to the output root as `00-Discovery-Report.html`

- [ ] **Tests: New-MonarchReport**
  - Accepts orchestrator-shaped input, produces HTML file
  - Critical findings (e.g., `CriticalGap = $true`) appear in highlighted section
  - Missing domain results (function failed) → noted in report, doesn't crash
  - Output file is written to specified path

---

### Step 14: Orchestrator — `Invoke-DomainAudit`

- [ ] **`Invoke-DomainAudit`**

  Signature:
  ```
  function Invoke-DomainAudit {
      [CmdletBinding(SupportsShouldProcess)]
      param(
          [Parameter(Mandatory)]
          [ValidateSet('Discovery','Review','Remediation','Monitoring','Cleanup')]
          [string]$Phase,
          [string]$Domain,
          [string]$OutputPath  # defaults to "Monarch-Audit-yyyyMMdd"
      )
  ```

  Discovery phase logic:
  1. Resolve DC: `$target = Resolve-MonarchDC -Domain $Domain`
  2. Create output directory structure:
     ```
     Monarch-Audit-yyyyMMdd/
     ├── 01-Baseline/
     ├── 02-GPO-Audit/
     ├── 03-Privileged-Access/
     ├── 04-Dormant-Accounts/
     └── 05-Infrastructure/
     ```
  3. Call Discovery functions in order, passing `-Server $target.DCName` and appropriate `-OutputPath`
  4. Collect all return objects into results array
  5. If any function throws, catch it, record the failure, continue with remaining functions
  6. Call `New-MonarchReport` with collected results
  7. Return collected results

  Execution order:
  ```
  1.  New-DomainBaseline              → 01-Baseline/
  2.  Get-FSMORolePlacement           → 05-Infrastructure/
  3.  Get-ReplicationHealth           → 05-Infrastructure/
  4.  Get-SiteTopology                → 05-Infrastructure/
  5.  Get-ForestDomainLevel           → 05-Infrastructure/
  6.  Export-GPOAudit                  → 02-GPO-Audit/
  7.  Find-UnlinkedGPO                → (results only)
  8.  Find-GPOPermissionAnomaly       → (results only)
  9.  Get-PrivilegedGroupMembership   → 03-Privileged-Access/
  10. Find-AdminCountOrphan           → 03-Privileged-Access/
  11. Find-KerberoastableAccount      → 03-Privileged-Access/
  12. Find-ASREPRoastableAccount      → 03-Privileged-Access/
  13. Find-DormantAccount             → 04-Dormant-Accounts/
  14. Get-PasswordPolicyInventory     → (results only)
  15. Find-WeakAccountFlag            → (results only)
  16. Test-ProtectedUsersGap          → (results only)
  17. Find-LegacyProtocolExposure     → (results only)
  18. Get-BackupReadinessStatus       → (results only)
  19. Test-TombstoneGap               → (results only)
  20. Get-AuditPolicyConfiguration    → (results only)
  21. Get-EventLogConfiguration       → (results only)
  22. Test-SRVRecordCompleteness      → (results only)
  23. Get-DNSScavengingConfiguration  → (results only)
  24. Test-ZoneReplicationScope       → (results only)
  25. Get-DNSForwarderConfiguration   → (results only)
  26. New-MonarchReport               → 00-Discovery-Report.html
  ```

  Return contract:
  ```
  [PSCustomObject]@{
      Phase        = 'Discovery'
      Domain       = [string]
      DCUsed       = [string]
      DCSource     = [string]        # HealthyDC|Discovered
      StartTime    = [datetime]
      EndTime      = [datetime]
      OutputPath   = [string]
      ReportPath   = [string]        # path to HTML report
      Results      = @([PSCustomObject])
      Failures     = @([PSCustomObject]@{
          Function = [string]; Error = [string]
      })
  }
  ```

  Non-Discovery phases: `Review` returns checklist content. Others throw `"Phase '$Phase' not yet implemented"` — honest error, not a stub.

- [ ] **Tests: Invoke-DomainAudit**
  - `-Phase Discovery` calls all Discovery functions (mock them all, verify each is called)
  - Function that throws → appears in `Failures`, other functions still run
  - Output directories created
  - Return object has correct Phase, Domain, timing, results array
  - `-Domain` parameter passed through to Resolve-MonarchDC
  - Non-Discovery phase → throws not-implemented error
  - Report generated at end of Discovery

---

### Implementation Sequence

Build and verify in this order. Each step is independently testable. Tests ship with each step.

| Step | What | Test Focus | Depends On |
|------|------|-----------|-----------|
| 1 | Module manifest + skeleton + test file | Module loads, functions exported | Nothing |
| 2 | Config layer | Defaults, overrides, access pattern | Step 1 |
| 3 | Resolve-MonarchDC | OctoDoc path, fallback path, domain param | Step 2 |
| 4 | New-DomainBaseline | Return shape, partial failure, CSV output | Steps 1-3 |
| 5 | Infrastructure Health (4 functions) | FSMO reachability, replication thresholds, site gaps | Steps 1-3 |
| 6 | Security Posture (4 functions) | Flag detection, Protected Users SPN warning | Steps 1-3 |
| 7 | Privileged Access (4 functions) | RID matching, nested groups, DA thresholds | Steps 1-3 |
| 8 | Find-DormantAccount | Exclusion logic, lastLogonTimestamp optimization, CSV | Steps 1-3 |
| 9 | Export-GPOAudit + 2 thin functions | String matching, folder structure, permissions | Steps 1-3 |
| 10 | Backup & Recovery (2 functions) | Tier detection, tombstone gap, CriticalGap logic | Steps 1-3 |
| 11 | DNS (4 functions) | Module-unavailable handling, SRV completeness | Steps 1-3 |
| 12 | Audit & Compliance (2 functions) | Cross-DC consistency detection | Steps 1-3 |
| 13 | Reporting | HTML generation from structured data | Steps 4-12 |
| 14 | Orchestrator | Function dispatch, failure isolation, directory structure | All above |

---

### What's Deliberately Excluded from Plan 1

- `Start-MonarchAudit` (interactive wrapper) — Plan 3
- `Compare-GPO`, `Compare-DomainBaseline`, `Compare-CISBaseline` — Plan 4 (need prior data)
- `Test-TieredAdminCompliance` — Plan 4 (needs tier model config)
- All Remediation/Monitoring/Cleanup functions — Plan 2
- OctoDoc stratagem integration — Plan 5

---

## Plan 2: Remediation, Monitoring, and Cleanup Functions

**Prerequisite:** Plan 1 complete.

**Scope:** Destructive operations with WhatIf support, rollback data, hold period enforcement.

**Functions:**

| Function | Phase | WhatIf | Key Concern |
|----------|-------|--------|-------------|
| `Suspend-DormantAccount` | Remediation | Yes | Archives rollback data to extensionAttribute14, strips groups, moves to quarantine, writes disable date to extensionAttribute15 |
| `Restore-DormantAccount` | Remediation | Yes | Reads extensionAttribute14, restores groups + OU, clears both attributes, re-enables |
| `Remove-DormantAccount` | Cleanup | Yes | Hold period enforcement via extensionAttribute15, pre-deletion archive, SID preservation |
| `Remove-AdminCountOrphan` | Remediation | Yes | Clears AdminCount flag from orphaned accounts |
| `Grant-TimeBoundGroupMembership` | Remediation | Yes | Adds with auto-expiration via AD TTL mechanism |
| `Backup-GPO` | Remediation | No (read) | Full XML backup for restore capability |
| `Get-DormantAccountMonitoringMetrics` | Monitoring | No (read) | Queries quarantine OU, counts, hold period status |

**Test focus:** WhatIf produces correct preview output. Rollback data serialization/deserialization round-trips correctly. Hold period calculation correct. Exclusion of accounts without monarch-kit disable dates. Integration tests for suspend → restore cycle and suspend → delete cycle using mocked AD.

---

## Plan 3: Interactive Wrapper

**Prerequisite:** Plans 1 and 2 complete.

**Scope:** `Start-MonarchAudit` — the admin-facing entry point.

**Key deliverables:**
- Interactive menu (1-5 phase selection, Q to quit)
- Pre-phase guidance (what will happen, time estimates, pre-flight checks)
- Human confirmations before destructive operations
- Reviewed CSV path prompt during Remediation
- Checklist rendering during Review phase (from docs/checklists.md)
- Post-phase summary with output paths and next steps
- Monitoring metrics template and checkpoint guidance
- Post-deletion timing warnings
- `-Phase` parameter for non-interactive use

**V0 reference:** `Start-NetworkHandover.ps1` is essentially a template. Carry the UX patterns: `Show-Banner`, `Wait-ForContinue`, `Show-ChecklistItem`, `Invoke-SafeScript` (renamed to call orchestrator instead of scripts).

**The wrapper calls the orchestrator.** It never calls API functions directly.

**Test focus:** Parameter validation. Phase dispatch calls `Invoke-DomainAudit` with correct `-Phase`. Menu loop handles invalid input. Confirmation prompts block destructive operations.

---

## Plan 4: Comparison Functions

**Prerequisite:** Plan 1 complete (needs baseline data from prior Discovery runs).

**Scope:** Functions that compare two datasets or compare against an external standard.

**Functions:**

| Function | Domain | Requirement |
|----------|--------|-------------|
| `Compare-DomainBaseline` | Audit & Compliance | Two baseline snapshots (previous + current) |
| `Compare-GPO` | Group Policy | Two GPO snapshots or DC-to-DC comparison |
| `Compare-CISBaseline` | Security Posture | External baseline definition file |
| `Test-TieredAdminCompliance` | Privileged Access | Tier model definition in config |

**Test focus:** Delta detection (field added, removed, changed). Classification of changes (expected, advisory, requires-review). Handles missing previous baseline gracefully. CIS baseline comparison accepts generic baseline definition format.

---

## Plan 5: OctoDoc Stratagem Integration

**Prerequisite:** Plan 1 complete AND OctoDoc redesigned with `Invoke-DCProbes` and probe registry.

**Scope:** Refactor functions that should use stratagems instead of direct AD queries.

**Functions affected:**
- Infrastructure Health: replication, time sync (compose Replication + TimeSync stratagems)
- Backup & Recovery: backup readiness (compose WSBackup + BackupVendorDetection stratagems)

**What changes:** Internal implementation of affected functions switches from direct AD cmdlets to stratagem composition + `Invoke-DCProbes` + result interpretation. Return contracts stay identical — consumers see no change.

**What doesn't change:** Function signatures, return contracts, config keys, test assertions (add new tests for stratagem path, keep existing tests for direct-query fallback).

**OctoDoc probe registry integration:** When OctoDoc supports self-describing probe menus, add a `Get-MonarchStratagem` function that maps monarch domains to available probes. This enables LLM agents to dynamically compose stratagems based on what the sensor layer can actually check.

**Blocked until:** OctoDoc redesign ships with `Invoke-DCProbes`, probe registry, and the standard probe result contract (CheckName, Status, Success, Value, Timestamp, Error, ErrorCategory, ExecutionTime).
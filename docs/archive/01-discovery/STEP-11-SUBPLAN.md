# Step 11 Subplan: DNS (AD-Integrated)

Four functions in the `DNS` domain. All Discovery phase, all require DnsServer module with graceful unavailability handling. `Test-SRVRecordCompleteness` enumerates AD sites and checks per-site SRV records. `Get-DNSScavengingConfiguration` and `Test-ZoneReplicationScope` both query zone properties. `Get-DNSForwarderConfiguration` queries per-DC forwarder config with cross-DC consistency check.

**Dev-guide checkpoints applied:** Code budget, completion over expansion, guards at boundaries, test behavior not implementation, one function one job, max 2 nesting levels.

**Current state:** 20 working API functions, 135 tests passing. This step adds 4 more functions.

**V0 reference:** `.v0/Create-NetworkBaseline.ps1` lines 340–379. Carries: DnsServer module availability check pattern (`Get-Module -ListAvailable -Name DnsServer`), zone enumeration via `Get-DnsServerZone`. Drop `Add-Report`/`Export-Csv`, use structured return objects.

**Key design decisions:**
- DnsServer module check: `Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue` (lighter than `Get-Module -ListAvailable`). If unavailable, return result with empty data arrays and Warnings containing "DnsServer module not available" — never throw.
- SRV record lookup uses `Resolve-DnsName` (built-in, no module dependency) with `-Type SRV` for each expected record per site. This is more reliable than `Get-DnsServerResourceRecord` which requires running on a DNS server.
- Forwarder consistency: compare serialized forwarder lists across DCs. `Consistent = $true` when all identical.
- All four functions share the same `$splatAD` pattern and DNS module gate. Extract the gate into each function's preamble (not a shared helper — one function one job).

---

## Pass 1: Test-SRVRecordCompleteness + Get-DNSScavengingConfiguration

Two functions that pair naturally — SRV checks sites, scavenging checks zones. Establishes DNS module gate pattern.

### 11a. Test-SRVRecordCompleteness

- [x] **`Test-SRVRecordCompleteness` function** in `#region DNS` (line 2122)

  Code-budget target: ~35–40 lines.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:
  ```
  [PSCustomObject]@{
      Domain          = 'DNS'
      Function        = 'Test-SRVRecordCompleteness'
      Timestamp       = [datetime]
      Sites           = @([PSCustomObject]@{
          SiteName        = [string]
          ExpectedRecords = [int]         # always 4
          FoundRecords    = [int]
          MissingRecords  = @([string])
      })
      AllComplete     = [bool]
      Warnings        = @()
  }
  ```

  Implementation:
  - DNS module gate: `if (-not (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue))` → set warning, skip to return
  - `$domain = (Get-ADDomain @splatAD).DNSRoot`
  - `$sites = @(Get-ADReplicationSite -Filter '*' @splatAD)`
  - Required SRV prefixes: `@('_ldap._tcp', '_kerberos._tcp', '_kpasswd._tcp', '_gc._tcp')`
  - Per-site: `foreach ($site in $sites)` with try/catch
    - Per-prefix: `Resolve-DnsName "$prefix.$($site.Name)._sites.dc._msdcs.$domain" -Type SRV -ErrorAction SilentlyContinue`
    - Missing = prefixes where Resolve-DnsName returns $null
  - `$allComplete = ($sites | ForEach-Object { $_.MissingRecords.Count }) | Measure-Object -Sum | ... -eq 0`

- [x] **Tests: Test-SRVRecordCompleteness** (~3 tests)
  - DnsServer unavailable → result returned with Warnings, Sites empty, no throw
  - Site with missing record → appears in MissingRecords, AllComplete=$false
  - All records present → AllComplete=$true, MissingRecords empty

### 11b. Get-DNSScavengingConfiguration

- [x] **`Get-DNSScavengingConfiguration` function** in `#region DNS`

  Code-budget target: ~25 lines.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'DNS'
      Function  = 'Get-DNSScavengingConfiguration'
      Timestamp = [datetime]
      Zones     = @([PSCustomObject]@{
          ZoneName          = [string]
          ScavengingEnabled = [bool]
          NoRefreshInterval = [timespan]
          RefreshInterval   = [timespan]
      })
      Warnings  = @()
  }
  ```

  Implementation:
  - DNS module gate (same pattern)
  - `$splatDNS = if ($Server) { @{ ComputerName = $Server } } else { @{} }` (DnsServer cmdlets use `-ComputerName`, not `-Server`)
  - `$zones = @(Get-DnsServerZone @splatDNS | Where-Object { $_.IsDsIntegrated -and -not $_.IsAutoCreated })`
  - Per-zone: `Get-DnsServerZoneAging -Name $z.ZoneName @splatDNS` returns aging/scavenging properties
  - Map: ScavengingEnabled from `AgingEnabled`, NoRefreshInterval and RefreshInterval from zone aging properties

- [x] **Tests: Get-DNSScavengingConfiguration** (~2 tests)
  - DnsServer unavailable → result with Warnings, Zones empty
  - Zone with scavenging enabled → correct properties in Zones array

**Pass 1 exit criteria:** Both functions return correct objects. DNS module gate works. ~5 tests passing.

---

## Pass 2: Test-ZoneReplicationScope + Get-DNSForwarderConfiguration

### 11c. Test-ZoneReplicationScope

- [x] **`Test-ZoneReplicationScope` function** in `#region DNS`

  Code-budget target: ~20 lines.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

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

  Implementation:
  - DNS module gate
  - `$zones = @(Get-DnsServerZone @splatDNS | Where-Object { -not $_.IsAutoCreated })`
  - Per-zone: map ZoneName, IsDsIntegrated, ReplicationScope (DirectoryPartitionName mapped to scope label), ZoneType

- [x] **Tests: Test-ZoneReplicationScope** (~2 tests)
  - DnsServer unavailable → result with Warnings, Zones empty
  - DS-integrated zone → correct IsDsIntegrated, ReplicationScope, ZoneType

### 11d. Get-DNSForwarderConfiguration

- [x] **`Get-DNSForwarderConfiguration` function** in `#region DNS`

  Code-budget target: ~30 lines.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:
  ```
  [PSCustomObject]@{
      Domain       = 'DNS'
      Function     = 'Get-DNSForwarderConfiguration'
      Timestamp    = [datetime]
      DCForwarders = @([PSCustomObject]@{
          DCName       = [string]
          Forwarders   = @([string])
          UseRootHints = [bool]
      })
      Consistent   = [bool]
      Warnings     = @()
  }
  ```

  Implementation:
  - DNS module gate
  - `$dcs = @(Get-ADDomainController -Filter '*' @splatAD)`
  - Per-DC: `Get-DnsServerForwarder -ComputerName $dc.HostName` → IPAddress array, UseRootHints
  - Consistency: `$consistent = ($dcForwarders | ForEach-Object { ($_.Forwarders | Sort-Object) -join ',' } | Sort-Object -Unique | Measure-Object).Count -le 1`

- [x] **Tests: Get-DNSForwarderConfiguration** (~3 tests)
  - DnsServer unavailable → result with Warnings, DCForwarders empty, Consistent=$true
  - DCs with same forwarders → Consistent=$true
  - DCs with different forwarders → Consistent=$false

**Pass 2 exit criteria:** All four functions working. ~5 additional tests passing.

---

## Pass 3: Full Suite Verification

- [x] **Run all tests (Steps 1–11)** — verify no regressions
  - Steps 1–10 tests still pass (135 existing)
  - All Step 11 tests pass (10 new)
  - Total: 145 tests, 0 failures
- [x] **Check diagnostics** — no warnings or errors in `.psm1`
- [x] **Verify `FunctionsToExport`** — all four functions listed in `Monarch.psd1` (lines 58–62)
- [x] **Verify function placement** — all four live in `#region DNS` (lines 2123, 2173, 2214, 2254)

**Pass 3 exit criteria:** Full green suite. 24 working API functions total.

---

## New Cmdlets to Stub

| Cmdlet | Used by | Stub signature |
|--------|---------|---------------|
| `Get-DnsServerZone` | Scavenging, ZoneReplication | `param([string]$ComputerName)` |
| `Get-DnsServerZoneAging` | Scavenging | `param([string]$Name, [string]$ComputerName)` |
| `Get-DnsServerForwarder` | ForwarderConfig | `param([string]$ComputerName)` |
| `Resolve-DnsName` | SRVRecordCompleteness | `param([string]$Name, [string]$Type, [string]$Server, [string]$ErrorAction)` |
| `Get-ADDomain` | SRVRecordCompleteness | `param([string]$Server)` — may already be stubbed |
| `Get-ADReplicationSite` | SRVRecordCompleteness | Already stubbed from DomainBaseline |
| `Get-ADDomainController` | ForwarderConfig | Already stubbed |
| `Get-Command` | All four (module gate) | Built-in, mock only |

---

## Dev-Guide Compliance Notes

| Principle | How applied |
|-----------|-------------|
| Code budget | SRVRecord ~35 lines, Scavenging ~25 lines, ZoneReplication ~20 lines, ForwarderConfig ~30 lines. |
| Completion over expansion | Two implementation passes. Pass 1 ships SRV+Scavenging (5 tests). Pass 2 ships ZoneRepl+Forwarder (5 tests). |
| Guards at boundaries | DNS module gate at each function entry. Per-site/per-zone/per-DC try/catch. |
| Test behavior not implementation | Tests check return shapes, AllComplete, Consistent, MissingRecords. No assertions on internal variables. |
| One function one job | Four independent functions. No shared helpers. |
| Max 2 nesting levels | foreach site/zone/DC { try/catch } = 1 level. |
| Config access | No DNS-specific config needed. Module uses DnsServer cmdlet defaults. |

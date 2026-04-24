# Step 5 Subplan: Infrastructure Health

Four functions in the `InfrastructureHealth` domain. All Discovery phase, all follow the Step 4 pattern (return contract, `-Server` splatting, `try/catch` sections, `Warnings` array).

**Dev-guide checkpoints applied:** Code budget, completion over expansion, guards at boundaries, test behavior not implementation.

**Current state:** 1 working API function (`New-DomainBaseline`), 52 tests passing. This step adds 4 more functions. DNS functions listed under Infrastructure Health in the domain spec are deferred to Step 12 (DNS domain).

**V0 reference:** `Create-NetworkBaseline.ps1` has FSMO (lines 129–155), sites/subnets (lines 157–195), and replication (lines 263–306) sections. Carry the data shapes and AD cmdlet patterns. Drop text output and "handover" language.

---

## Pass 1: Get-ForestDomainLevel + Get-FSMORolePlacement

Two functions that both query `Get-ADDomain` / `Get-ADForest`. Natural pairing — same stubs, same mock data foundation. Ship both with tests in one pass.

### 5d. Get-ForestDomainLevel

- [x] **`Get-ForestDomainLevel` function** in `#region Infrastructure Health`

  Trivial function. Three AD queries, one return object. Overlaps with `New-DomainBaseline` intentionally — baseline is a snapshot document, this is a focused check for the orchestrator.

  Code-budget target: ~25–30 lines.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'InfrastructureHealth'` | Literal |
  | `Function` | `'Get-ForestDomainLevel'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `DomainFunctionalLevel` | `[string]` | `Get-ADDomain` `.DomainMode` |
  | `ForestFunctionalLevel` | `[string]` | `Get-ADForest` `.ForestMode` |
  | `SchemaVersion` | `[int]` | `Get-ADObject` on `CN=Schema,CN=Configuration` `.objectVersion` |
  | `DomainDNSRoot` | `[string]` | `Get-ADDomain` `.DNSRoot` |
  | `ForestName` | `[string]` | `Get-ADForest` `.Name` |
  | `Warnings` | `@([string])` | Accumulated errors |

  Cmdlets: `Get-ADDomain`, `Get-ADForest`, `Get-ADObject` — all already stubbed in Step 4 pattern.

- [x] **Tests: Get-ForestDomainLevel** (~3 tests)
  - Return object has all required properties, `Domain` = `'InfrastructureHealth'`, `Function` = `'Get-ForestDomainLevel'`
  - Schema version populated from mock `objectVersion`
  - Section failure (mock `Get-ADForest` to throw) → `ForestFunctionalLevel` is `$null`, `DomainFunctionalLevel` still populated, warning present

### 5a. Get-FSMORolePlacement

- [x] **`Get-FSMORolePlacement` function** in `#region Infrastructure Health`

  Code-budget target: ~50–60 lines. Core logic: get 5 role holders from domain/forest objects, test reachability of each, build sub-objects.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'InfrastructureHealth'` | Literal |
  | `Function` | `'Get-FSMORolePlacement'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `Roles` | `@([PSCustomObject])` | Array of 5 role objects (see below) |
  | `AllOnOneDC` | `[bool]` | All role holders are the same FQDN |
  | `UnreachableCount` | `[int]` | Count of roles where `Reachable = $false` |
  | `Warnings` | `@([string])` | Accumulated errors |

  Role sub-object shape:

  | Property | Type | Source |
  |----------|------|--------|
  | `Role` | `[string]` | `SchemaMaster`, `DomainNaming`, `PDCEmulator`, `RIDMaster`, `Infrastructure` |
  | `Holder` | `[string]` | FQDN from domain/forest objects |
  | `Reachable` | `[bool]` | `Test-Connection -Count 1 -Quiet` |
  | `Site` | `[string]` | Match holder against DC list from `Get-ADDomainController -Filter '*'` |

  Implementation details:
  - Build role list from `$domainInfo` (PDCEmulator, RIDMaster, Infrastructure) and `$forestInfo` (SchemaMaster, DomainNamingMaster) — same pattern as `New-DomainBaseline` section 3
  - Deduplicate holders before testing reachability (if all 5 are on one DC, only ping once)
  - `Test-Connection -ComputerName $holder -Count 1 -Quiet` — returns `$true`/`$false`. Wrap in `try/catch` for environments where ICMP is blocked (catch → `$false` + warning). **Cross-platform note:** `-Count` parameter name is the same on PS 5.1 and 7.x, but early 7.x versions had different return-type behavior. The `try/catch` fallback to `$false` covers both — don't rely on the return type being `[bool]` without the `-Quiet` switch.
  - `AllOnOneDC` = `($roles.Holder | Select-Object -Unique).Count -eq 1`
  - Site lookup: query DCs once, build hostname→site hashtable, look up each holder. If DC list fails, `Site` = `$null` with warning.

  New cmdlet to stub: `Test-Connection` (not used in Step 4).

- [x] **Tests: Get-FSMORolePlacement** (~5 tests)
  - Return shape correct, `Roles` has 5 entries with correct sub-properties
  - `AllOnOneDC` = `$true` when all mocked roles point to same DC
  - `AllOnOneDC` = `$false` when roles are distributed across 2+ DCs
  - Unreachable DC (mock `Test-Connection` to return `$false`) → `Reachable = $false` and `UnreachableCount` incremented
  - Domain/Forest query failure → function still returns contract shape with warning

**Pass 1 exit criteria:** Both functions return correct objects. ~8 tests passing.

---

## Pass 2: Get-SiteTopology

- [x] **`Get-SiteTopology` function** in `#region Infrastructure Health`

  Code-budget target: ~50–60 lines. Highest-value checks per domain spec: subnets not assigned to any site and sites with no DCs.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'InfrastructureHealth'` | Literal |
  | `Function` | `'Get-SiteTopology'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `Sites` | `@([PSCustomObject])` | Array of site objects (see below) |
  | `UnassignedSubnets` | `@([string])` | Subnets where `.Site` is `$null` |
  | `EmptySites` | `@([string])` | Sites with no DCs assigned |
  | `SiteCount` | `[int]` | Total sites |
  | `SubnetCount` | `[int]` | Total subnets |
  | `Warnings` | `@([string])` | Accumulated errors |

  Site sub-object shape:

  | Property | Type |
  |----------|------|
  | `Name` | `[string]` |
  | `DCCount` | `[int]` |
  | `Subnets` | `@([string])` |

  Implementation details:
  - `Get-ADReplicationSite -Filter '*'` for sites
  - `Get-ADReplicationSubnet -Filter '*'` for subnets — match to sites via `.Site` property (DN of the site)
  - `Get-ADDomainController -Filter '*'` for DC-to-site mapping — group by `.Site` property
  - `EmptySites`: sites where no DC has a matching `.Site` value
  - `UnassignedSubnets`: subnets where `.Site` is `$null` or empty
  - Each query is its own `try/catch` — if subnets fail, sites still populate (with `Subnets = @()` per site)

  New cmdlet to stub: `Get-ADReplicationSubnet` (not used in Steps 4).

- [x] **Tests: Get-SiteTopology** (~5 tests)
  - Return shape correct with all required properties
  - Subnet with no site assignment → appears in `UnassignedSubnets`
  - Site with no DCs → appears in `EmptySites`
  - Counts (`SiteCount`, `SubnetCount`) match mocked data
  - Subnet query failure → sites still populated, subnets empty, warning present

**Pass 2 exit criteria:** Function returns correct objects including anomaly detection. ~5 tests passing.

---

## Pass 3: Get-ReplicationHealth

Most complex function in this step. Gets its own pass. Per domain spec: "Per-partition replication status is a graduated confidence pattern."

- [x] **`Get-ReplicationHealth` function** in `#region Infrastructure Health`

  Code-budget target: ~70–80 lines. Core complexity: status classification by time threshold and partition-level DiagnosticHints.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'InfrastructureHealth'` | Literal |
  | `Function` | `'Get-ReplicationHealth'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `Links` | `@([PSCustomObject])` | Array of link objects (see below) |
  | `HealthyLinkCount` | `[int]` | Count where Status = 'Healthy' |
  | `WarningLinkCount` | `[int]` | Count where Status = 'Warning' |
  | `FailedLinkCount` | `[int]` | Count where Status = 'Failed' |
  | `DiagnosticHints` | `@([string])` | Generated for partial-partition failures |
  | `Warnings` | `@([string])` | Accumulated errors |

  Link sub-object shape:

  | Property | Type |
  |----------|------|
  | `SourceDC` | `[string]` |
  | `PartnerDC` | `[string]` |
  | `Partition` | `[string]` — `Schema`, `Configuration`, `Domain`, `DomainDNS`, `ForestDNS` |
  | `LastSuccess` | `[datetime]` or `$null` |
  | `LastAttempt` | `[datetime]` |
  | `ConsecutiveFailures` | `[int]` |
  | `Status` | `[string]` — `Healthy`, `Warning`, `Failed` |

  Status classification logic:
  - `Failed`: `ConsecutiveFailures > 0` (takes priority — active failures are always critical)
  - `Warning`: last success > `ReplicationWarningThresholdHours` (config, default 24) but < 2× threshold, AND no consecutive failures
  - `Healthy`: last success within threshold AND no consecutive failures

  DiagnosticHints generation:
  - When one partition fails but another succeeds on the same source↔partner pair → hint: `"DC01→DC02: Domain partition healthy but DomainDNS partition failed — check DNS application partition replication"`
  - Per domain spec: DNS application partition replication failures are the most common partial-replication scenario
  - **Hint strings are illustrative, not prescribed.** The mechanism-decisions doc shows a different example (`"Schema partition replicating successfully, Domain partition failing — DNS or site link configuration issue likely"`) for a different scenario. Both docs show the same *pattern*: name the healthy partition, name the failing partition, suggest a likely cause. Include the DC pair names (e.g., `DC01→DC02:`) for operational usefulness — the mechanism-decisions doc omits them but real admins need them. Generate hints dynamically from the actual partition data — don't hardcode a fixed set.

  Implementation details:
  - `Get-ADDomainController -Filter '*'` to get DC list
  - Per-DC: `Get-ADReplicationPartnerMetadata -Target $dc.HostName` — returns one entry per partner per partition
  - Wrap per-DC query in `try/catch` — unreachable DC adds warning, doesn't block other DCs (same resilience pattern as v0)
  - Partition name normalization: extract partition type from the DN (e.g., `DC=DomainDnsZones,...` → `DomainDNS`, `CN=Schema,...` → `Schema`, `CN=Configuration,...` → `Configuration`). **Keep this simple** — a `-match` cascade (3–5 lines) is the right tool, not structured DN parsing. Same rationale as GPO high-risk detection in mechanism-decisions.md: string matching is more reliable than structured parsing across functional level variations. Budget ~5 lines for this; if it grows beyond that, the approach is wrong.
  - Config access: `Get-MonarchConfigValue 'ReplicationWarningThresholdHours'`

  New cmdlet to stub: `Get-ADReplicationPartnerMetadata`.

  V0 reference: `Create-NetworkBaseline.ps1` lines 263–306 — same per-DC iteration, same 24-hour threshold check. Add partition awareness and DiagnosticHints.

- [x] **Tests: Get-ReplicationHealth** (~7 tests)
  - Return shape correct with all required properties
  - Healthy link (last success 2 hours ago, 0 failures) → `Status = 'Healthy'`
  - Warning link (last success 30 hours ago, default 24h threshold, 0 failures) → `Status = 'Warning'`
  - Failed link (`ConsecutiveFailures = 3`) → `Status = 'Failed'` regardless of last success time
  - Counts (`HealthyLinkCount`, `WarningLinkCount`, `FailedLinkCount`) correct across mixed states
  - Partial-partition failure (one partition healthy, another failed on same DC pair) → `DiagnosticHints` contains a hint about the failing partition
  - Config override: mock `ReplicationWarningThresholdHours = 48` → link at 30 hours is now `Healthy` instead of `Warning`

**Pass 3 exit criteria:** Function handles healthy, warning, and failed states. DiagnosticHints generated for partial-partition scenarios. ~7 tests passing.

---

## Pass 4: Full Suite Verification

- [x] **Run all tests (Steps 1–5)** — verify no regressions
  - Steps 1–4 tests still pass (52 existing)
  - All Step 5 tests pass
  - Expected total: ~72 tests (52 existing + ~20 new)
- [x] **Check diagnostics** — no warnings or errors in `.psm1`
- [x] **Verify `FunctionsToExport`** — all four functions listed in `Monarch.psd1`
- [x] **Verify function placement** — all four live in `#region Infrastructure Health`

**Pass 4 exit criteria:** Full green suite. Five working API functions total (1 Audit + 4 Infrastructure).

---

## New Cmdlets to Stub (beyond Step 4)

| Cmdlet | Used by | Notes |
|--------|---------|-------|
| `Test-Connection` | Get-FSMORolePlacement | `-Count 1 -Quiet` returns bool. Stub needs `param($ComputerName, $Count, [switch]$Quiet)` |
| `Get-ADReplicationSite` | Get-SiteTopology | `-Filter '*'` pattern. Stub needs `param($Filter, $Server)`. **Not stubbed in Step 4** — needs a new module-scope stub alongside the existing AD cmdlet stubs. |
| `Get-ADReplicationSubnet` | Get-SiteTopology | `-Filter '*'` pattern. Stub needs `param($Filter, $Server)` |
| `Get-ADReplicationPartnerMetadata` | Get-ReplicationHealth | `-Target` per DC. Stub needs `param($Target, $Server)` |

Cmdlets already stubbed in Step 4 (re-stub per `Describe` block via `Mock -ModuleName Monarch`): `Get-ADDomain`, `Get-ADForest`, `Get-ADObject`, `Get-ADDomainController`. Step 4 did **not** stub `Get-ADReplicationSite` — it is new to Step 5 (listed above).

### Cross-platform note: Test-Connection

`Test-Connection -ComputerName $holder -Count 1 -Quiet` is correct for PowerShell 5.1. On PowerShell 7.x the parameter is also `-Count` but early 7.x versions had behavioral differences in return type. The `try/catch` fallback to `$false` covers both platforms — if the cmdlet behaves unexpectedly, the catch fires and reachability defaults to unknown with a warning. Mock the stub to return `$true`/`$false` directly; don't try to simulate platform-specific behavior in tests.

---

## Dev-Guide Compliance Notes

| Principle | How applied |
|-----------|-------------|
| Code budget | Get-ForestDomainLevel ~25 lines, others ~50–80. No function exceeds its scope. |
| Completion over expansion | Three implementation passes, each ships complete functions with tests. Trivial + moderate paired in Pass 1. |
| Guards at boundaries | `-Server` splatting built once per function. `Test-Connection` wrapped in `try/catch` at the call site. |
| Test behavior not implementation | Tests check return values and status classification, not internal variable names or call sequences. |
| Appropriate complexity | Status classification uses simple threshold math, not an elaborate state machine. DiagnosticHints are string interpolation, not a template engine. |
| Config access | `ReplicationWarningThresholdHours` read via `Get-MonarchConfigValue` — no hardcoded thresholds in function body. |
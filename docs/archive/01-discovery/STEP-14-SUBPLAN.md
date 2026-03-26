# Step 14 Subplan: Orchestrator

One function: `Invoke-DomainAudit`. Coordinates which API functions run per phase, collects results, handles failures, generates report. Never contains domain logic — it's a dispatcher.

**Current state:** 27 working functions (25 API + 1 reporting + 1 DC resolution), 157 tests passing. This step adds 1 function.

**V0 reference:** `.v0/Start-NetworkHandover.ps1` for phase dispatch and error wrapping patterns. The v0 combined orchestration + interactive wrapper in one script; monarch-kit separates them (orchestrator here, interactive wrapper is Plan 3).

**Key dependencies (all implemented):**
- `Resolve-MonarchDC` (line 114) — resolves domain to healthy DC, returns `{ DCName, Domain, Source }`
- `New-MonarchReport` (line 2407) — generates HTML report from orchestrator return object
- All 25 API functions — each returns PSCustomObject with `Domain`, `Function`, `Timestamp`, `Warnings`

---

## Discovery Phase Function Sequence

The orchestrator calls these 25 functions in order, then generates the report. Each function gets `-Server $dc` and an `-OutputPath` where applicable.

| # | Function | Output Subdirectory |
|---|----------|-------------------|
| 1 | New-DomainBaseline | 01-Baseline/ |
| 2 | Get-FSMORolePlacement | — |
| 3 | Get-ReplicationHealth | — |
| 4 | Get-SiteTopology | — |
| 5 | Get-ForestDomainLevel | — |
| 6 | Export-GPOAudit | 02-GPO-Audit/ |
| 7 | Find-UnlinkedGPO | — |
| 8 | Find-GPOPermissionAnomaly | — |
| 9 | Get-PrivilegedGroupMembership | — |
| 10 | Find-AdminCountOrphan | — |
| 11 | Find-KerberoastableAccount | — |
| 12 | Find-ASREPRoastableAccount | — |
| 13 | Find-DormantAccount | 04-Dormant-Accounts/ |
| 14 | Get-PasswordPolicyInventory | — |
| 15 | Find-WeakAccountFlag | — |
| 16 | Test-ProtectedUsersGap | — |
| 17 | Find-LegacyProtocolExposure | — |
| 18 | Get-BackupReadinessStatus | — |
| 19 | Test-TombstoneGap | — |
| 20 | Get-AuditPolicyConfiguration | — |
| 21 | Get-EventLogConfiguration | — |
| 22 | Test-SRVRecordCompleteness | — |
| 23 | Get-DNSScavengingConfiguration | — |
| 24 | Test-ZoneReplicationScope | — |
| 25 | Get-DNSForwarderConfiguration | — |
| — | New-MonarchReport | root (00-Discovery-Report.html) |

---

## Return Contract

```
[PSCustomObject]@{
    Phase      = 'Discovery'
    Domain     = [string]
    DCUsed     = [string]
    DCSource   = [string]          # 'HealthyDC' or 'Discovered'
    StartTime  = [datetime]
    EndTime    = [datetime]
    OutputPath = [string]
    ReportPath = [string]
    Results    = @([PSCustomObject])
    Failures   = @([PSCustomObject]@{ Function = [string]; Error = [string] })
}
```

---

## Pass 1: Invoke-DomainAudit + Tests

### 14a. Invoke-DomainAudit

- [x] **`Invoke-DomainAudit` function** in `#region Orchestrator`

  Code-budget target: ~55 lines.

  | Parameter | Type | Description |
  |-----------|------|-------------|
  | `-Phase` | string | ValidateSet: Discovery, Review, Remediation, Monitoring, Cleanup |
  | `-Domain` | string | Optional. DNS root. |
  | `-OutputPath` | string | Optional. Defaults to `Monarch-Audit-yyyyMMdd` |

### 14b. Tests

- [x] **Tests: Invoke-DomainAudit** (~5 tests)
  1. Discovery phase returns correct structure (Phase, Domain, DCUsed, 25 Results, 0 Failures, ReportPath)
  2. Function failure isolation (1 throws → 24 Results, 1 Failure)
  3. Output directories created (root + 4 subdirectories)
  4. New-MonarchReport called once
  5. Non-Discovery phase throws not-implemented

---

## Pass 2: Full Suite Verification

- [x] **Run all tests (Steps 1–14)** — verify no regressions
  - Steps 1–13 tests still pass (157 existing)
  - All Step 14 tests pass (5 new)
  - Total: 162 tests, 0 failures
- [x] **Check diagnostics** — no warnings or errors in `.psm1`
- [x] **Verify `FunctionsToExport`** — `Invoke-DomainAudit` listed in `Monarch.psd1` (line 18)
- [x] **Verify function placement** — lives in `#region Orchestrator` (line 2689)

**Pass 2 exit criteria:** Full green suite. 28 working functions total.

---

## Dev-Guide Compliance Notes

| Principle | How applied |
|-----------|-------------|
| Code budget | ~55 lines. Loop + try/catch, no domain logic. |
| Completion over expansion | Single pass. Discovery only. Other phases throw not-implemented. |
| Guards at boundaries | DC resolution failure is fatal. Per-function try/catch for isolation. |
| Test behavior not implementation | Tests check return shape, failure isolation, directory creation. No assertions on call order. |
| One function one job | Orchestration only. Never interprets results. |
| Max 2 nesting levels | `foreach { try { } catch { } }` = 2 levels. |
| Silence is success | No console output. Returns structured object. |

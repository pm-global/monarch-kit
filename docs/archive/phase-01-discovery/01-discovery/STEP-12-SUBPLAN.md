# Step 12 Subplan: Audit & Compliance (remaining)

Two functions in the `AuditCompliance` domain. `Get-AuditPolicyConfiguration` queries `auditpol` per DC via `Invoke-Command` remoting and detects cross-DC consistency. `Get-EventLogConfiguration` queries event log settings (Security, System, Directory Service) per DC via `Get-WinEvent`. No v0 reference — built from scratch per domain-specs.

**Dev-guide checkpoints applied:** Code budget, completion over expansion, guards at boundaries, test behavior not implementation, one function one job, max 2 nesting levels.

**Current state:** 24 working API functions, 145 tests passing. This step adds 2 more functions.

**V0 reference:** None. No audit policy or event log code in `.v0/`.

**Key design decisions:**
- `auditpol /get /category:*` via `Invoke-Command -ComputerName $dc.HostName` for remote execution. Parse CSV-style output.
- Event log config via `Get-WinEvent -ListLog` (built-in, no module dependency). Queries 3 specific logs: Security, System, 'Directory Service'.
- Cross-DC consistency for audit policy: serialize each DC's categories array and compare. Same pattern as `Get-DNSForwarderConfiguration`.
- Per-DC try/catch — unreachable DC goes to Warnings, doesn't block other DCs.

---

## Pass 1: Get-AuditPolicyConfiguration + Get-EventLogConfiguration + Tests

Both functions are lightweight enough to implement in a single pass.

### 12a. Get-AuditPolicyConfiguration

- [x] **`Get-AuditPolicyConfiguration` function** in `#region Audit and Compliance` (before `#endregion`, line 2117)

  Code-budget target: ~35–40 lines.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:
  ```
  [PSCustomObject]@{
      Domain     = 'AuditCompliance'
      Function   = 'Get-AuditPolicyConfiguration'
      Timestamp  = [datetime]
      DCs        = @([PSCustomObject]@{
          DCName     = [string]
          Categories = @([PSCustomObject]@{
              Category    = [string]
              Subcategory = [string]
              Setting     = [string]   # Success|Failure|Success and Failure|No Auditing
          })
      })
      Consistent = [bool]
      Warnings   = @()
  }
  ```

  Implementation:
  - `$dcs = @(Get-ADDomainController -Filter '*' @splatAD)`
  - Per-DC: `Invoke-Command -ComputerName $dc.HostName -ScriptBlock { auditpol /get /category:* /r } -ErrorAction Stop`
  - `/r` flag gives CSV output: `Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting`
  - Parse CSV: skip header, extract Category (from subcategory grouping) and Setting from `Inclusion Setting` column
  - Actually — `auditpol /get /category:*` text output is easier to parse: lines with "  Subcategory  Setting" pattern
  - Better approach: use `/r` (CSV) and `ConvertFrom-Csv` for reliable parsing
  - Consistency: serialize each DC's sorted categories, compare unique count

- [x] **Tests: Get-AuditPolicyConfiguration** (~2 tests)
  - DCs with identical settings → Consistent=$true
  - DCs with different settings → Consistent=$false

### 12b. Get-EventLogConfiguration

- [x] **`Get-EventLogConfiguration` function** in `#region Audit and Compliance`

  Code-budget target: ~30 lines.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:
  ```
  [PSCustomObject]@{
      Domain    = 'AuditCompliance'
      Function  = 'Get-EventLogConfiguration'
      Timestamp = [datetime]
      DCs       = @([PSCustomObject]@{
          DCName = [string]
          Logs   = @([PSCustomObject]@{
              LogName        = [string]
              MaxSizeKB      = [int]
              RetentionDays  = [int]
              OverflowAction = [string]
          })
      })
      Warnings  = @()
  }
  ```

  Implementation:
  - `$dcs = @(Get-ADDomainController -Filter '*' @splatAD)`
  - `$logNames = @('Security', 'System', 'Directory Service')`
  - Per-DC, per-log: `Invoke-Command -ComputerName $dc.HostName -ScriptBlock { Get-WinEvent -ListLog $using:logName }` or `Get-WinEvent -ListLog $logName -ComputerName $dc.HostName`
  - Map: MaximumSizeInBytes → MaxSizeKB (÷1024), LogMode → OverflowAction
  - RetentionDays: from registry or `wevtutil gl` — actually `Get-WinEvent -ListLog` doesn't expose retention days directly. Use `Invoke-Command` with `wevtutil gl $logName` to get Retention, or default to 0 when not available.
  - Simpler: use `Get-EventLog -List` (PS 5.1 compatible) which returns MaximumKilobytes, OverflowAction, MinimumRetentionDays directly. But `Get-EventLog` may not support 'Directory Service' log name.
  - Best approach: `Invoke-Command` per DC with scriptblock that queries `Get-WinEvent -ListLog` for the 3 logs. MaximumSizeInBytes/1024 for MaxSizeKB. For retention, use registry or return 0.

- [x] **Tests: Get-EventLogConfiguration** (~2 tests)
  - Return shape correct per DC per log (3 logs)
  - Unreachable DC → warning, doesn't block other DCs

**Pass 1 exit criteria:** Both functions return correct objects. Cross-DC consistency detection works. ~4 tests passing.

---

## Pass 2: Full Suite Verification

- [x] **Run all tests (Steps 1–12)** — verify no regressions
  - Steps 1–11 tests still pass (145 existing)
  - All Step 12 tests pass (4 new)
  - Total: 149 tests, 0 failures
- [x] **Check diagnostics** — no warnings or errors in `.psm1`
- [x] **Verify `FunctionsToExport`** — both functions listed in `Monarch.psd1` (lines 55–56)
- [x] **Verify function placement** — both live in `#region Audit and Compliance` (lines 2117, 2169)

**Pass 2 exit criteria:** Full green suite. 26 working API functions total.

---

## New Cmdlets to Stub

| Cmdlet | Used by | Stub signature |
|--------|---------|---------------|
| `Invoke-Command` | Both functions | `param([string]$ComputerName, [scriptblock]$ScriptBlock, [string]$ErrorAction)` |
| `Get-ADDomainController` | Both functions | Already stubbed |

Note: `auditpol` and `Get-WinEvent` run inside `Invoke-Command` scriptblocks — they execute remotely and don't need local stubs. We mock `Invoke-Command` itself.

---

## Dev-Guide Compliance Notes

| Principle | How applied |
|-----------|-------------|
| Code budget | AuditPolicy ~35 lines, EventLog ~30 lines. |
| Completion over expansion | Single implementation pass for both functions + tests. |
| Guards at boundaries | Per-DC try/catch. Per-log try/catch in EventLog. |
| Test behavior not implementation | Tests check Consistent, DCs array, Logs array. No assertions on parsing internals. |
| One function one job | Two independent functions — audit policy vs event log config. |
| Max 2 nesting levels | foreach DC { try/catch } = 1 level. |
| Config access | No audit-specific config needed. |

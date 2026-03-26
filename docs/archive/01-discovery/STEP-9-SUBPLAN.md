# Step 9 Subplan: Group Policy

Three functions in the `GroupPolicy` domain. `Export-GPOAudit` is the most complex output function in the project — multiple file formats, HTML templating, XML/CSV/permission/WMI exports. `Find-UnlinkedGPO` and `Find-GPOPermissionAnomaly` are lightweight standalone queries.

**Dev-guide checkpoints applied:** Code budget, completion over expansion, guards at boundaries, test behavior not implementation, one function one job, max 2 nesting levels.

**Current state:** 15 working API functions, 116 tests passing. This step adds 3 more functions.

**V0 reference:** `.v0/Export-GPOAudit.ps1` (475 lines). Carry almost entirely: folder numbering (00-SUMMARY through 05-WMI), HTML index template, XML backup via `Backup-GPO -All`, CSV summary with high-risk string matching, linkage CSV with `**UNLINKED**`, permission analysis with overpermission detection, WMI filter export, executive summary, filename sanitization. Drop `Write-Log`/`Write-Host`, use `Write-Verbose` + `Warnings` array. Permitted editors from config instead of hardcoded.

**Key mechanism decision:** GPO high-risk detection uses XML string matching (`-match`), NOT namespace-aware parsing (per `docs/mechanism-decisions.md` lines 106–120). Comment in code explains why.

---

## Pass 1: Find-UnlinkedGPO + Find-GPOPermissionAnomaly

Two lightweight standalone functions. Natural pairing — both query GPOs and return filtered results. Establishes GPO cmdlet stub patterns for Pass 2.

### 9a. Find-UnlinkedGPO

- [x] **`Find-UnlinkedGPO` function** in `#region Group Policy`

  Code-budget target: ~25–30 lines. Queries all GPOs, gets XML report per GPO, checks for `LinksTo`.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'GroupPolicy'` | Literal |
  | `Function` | `'Find-UnlinkedGPO'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `UnlinkedGPOs` | `@([PSCustomObject])` | Array of unlinked GPO objects |
  | `Count` | `[int]` | UnlinkedGPOs count |
  | `Warnings` | `@([string])` | Accumulated errors |

  UnlinkedGPO sub-object: DisplayName, Id, CreatedTime, ModifiedTime, Owner.

  Implementation:
  - `Get-GPO -All` to get all GPOs
  - Per-GPO: `[xml]$report = Get-GPOReport -Guid $gpo.Id -ReportType Xml`
  - If `$report.GPO.LinksTo` is null/empty → unlinked
  - Per-GPO try/catch

- [x] **Tests: Find-UnlinkedGPO** (~2 tests)
  - GPO with no links → returned
  - GPO with links → not returned

### 9b. Find-GPOPermissionAnomaly

- [x] **`Find-GPOPermissionAnomaly` function** in `#region Group Policy`

  Code-budget target: ~30–35 lines. Queries all GPOs, gets permissions, flags non-standard editors.

  | Parameter | Type |
  |-----------|------|
  | `-Server` | string |

  Return contract:

  | Property | Type | Source |
  |----------|------|--------|
  | `Domain` | `'GroupPolicy'` | Literal |
  | `Function` | `'Find-GPOPermissionAnomaly'` | Literal |
  | `Timestamp` | `[datetime]` | `Get-Date` |
  | `Anomalies` | `@([PSCustomObject])` | Array of anomaly objects |
  | `Count` | `[int]` | Anomalies count |
  | `Warnings` | `@([string])` | Accumulated errors |

  Anomaly sub-object: GPOName, Trustee, TrusteeSID, Permission, Inherited.

  Implementation:
  - `$permittedEditors = Get-MonarchConfigValue 'PermittedGPOEditors'`
  - Per-GPO: `Get-GPPermission -Guid $gpo.Id -All`
  - Filter: `Permission -like '*Edit*' -and Trustee.Name not in permittedEditors -and -not Denied`

- [x] **Tests: Find-GPOPermissionAnomaly** (~2 tests)
  - Non-standard editor → returned in Anomalies
  - Standard editor (Domain Admins from config) → not returned

**Pass 1 exit criteria:** Both functions return correct objects. ~4 tests passing.

---

## Pass 2: Export-GPOAudit (core — summary + CSV + high-risk detection)

### 9c. Export-GPOAudit (core)

- [x] **`Export-GPOAudit` function (core)** in `#region Group Policy`

  Code-budget target for this pass: ~60–70 lines.

  | Parameter | Type | Notes |
  |-----------|------|-------|
  | `-Server` | string | Standard AD target |
  | `-OutputPath` | string | Base directory for all exports |
  | `-IncludePermissions` | switch | Include permission analysis |
  | `-IncludeWMIFilters` | switch | Include WMI filter export |

  Core sections: folder creation (00-SUMMARY, 03-CSV), GPO discovery, per-GPO analysis (high-risk string matching + link parsing), CSV export (gpo-summary.csv + gpo-linkage.csv), executive summary text file, return object.

- [x] **Tests: Export-GPOAudit (core)** (~4 tests)
  - Return shape correct
  - High-risk detection: GPO XML containing "UserRightsAssignment" → counted
  - Unlinked GPO counted and flagged `**UNLINKED**`
  - `OverpermissionedCount` is `$null` when `-IncludePermissions` not set

**Pass 2 exit criteria:** Core function returns correct counts and CSV files. ~4 tests passing.

---

## Pass 3: Export-GPOAudit (complete — HTML + XML + Permissions + WMI)

### 9d. HTML reports + XML backup

- [x] **Add HTML reports and XML backup** (~30–35 additional lines)

### 9e. Permission analysis + WMI filters

- [x] **Add permission analysis and WMI filter export** (~25–30 additional lines)

### 9f. Remaining tests

- [x] **Tests: File generation and sanitization** (~2 tests)
  - OutputPaths populated when OutputPath provided
  - Filename sanitization strips invalid characters

**Pass 3 exit criteria:** Full Export-GPOAudit with all file types. ~6 additional tests passing.

---

## Pass 4: Full Suite Verification

- [x] **Run all tests (Steps 1–9)** — verify no regressions
  - Steps 1–8 tests still pass (116 existing)
  - All Step 9 tests pass (10 new)
  - Total: 126 tests, 0 failures
- [x] **Check diagnostics** — no warnings or errors in `.psm1`
- [x] **Verify `FunctionsToExport`** — all three functions listed in `Monarch.psd1`
- [x] **Verify function placement** — all three live in `#region Group Policy` (lines 1035, 1077, 1124)

**Pass 4 exit criteria:** Full green suite. 18 working API functions total.

---

## New Cmdlets to Stub

| Cmdlet | Used by | Stub signature |
|--------|---------|---------------|
| `Get-GPO` | All three functions | `param([switch]$All, [string]$Server)` |
| `Get-GPOReport` | Export-GPOAudit, Find-UnlinkedGPO | `param([string]$Guid, [string]$ReportType, [string]$Path, [string]$Server)` |
| `Backup-GPO` | Export-GPOAudit | `param([switch]$All, [string]$Path, [string]$Server)` |
| `Get-GPPermission` | Export-GPOAudit, Find-GPOPermissionAnomaly | `param([string]$Guid, [switch]$All, [string]$Server)` |
| `Get-ADObject` | Export-GPOAudit (WMI) | Already stubbed, needs WMI filter support in mock |

---

## Dev-Guide Compliance Notes

| Principle | How applied |
|-----------|-------------|
| Code budget | Find-UnlinkedGPO ~25 lines, Find-GPOPermissionAnomaly ~30 lines. Export-GPOAudit ~100–120 lines total (justified — generates 6 file types). |
| Completion over expansion | Three implementation passes. Pass 1 ships two standalone functions. Pass 2 ships core Export-GPOAudit. Pass 3 adds file-heavy sections. |
| Guards at boundaries | Per-GPO try/catch in all three functions. Per-section try/catch in Export-GPOAudit. |
| Test behavior not implementation | Tests check return values, counts, CSV content, file existence. |
| One function one job | Three independent functions. Find-UnlinkedGPO and Find-GPOPermissionAnomaly do NOT call Export-GPOAudit. |
| Max 2 nesting levels | foreach GPO { try/catch } = 1 level. Permission filtering is flat. |
| Config access | `PermittedGPOEditors` via `Get-MonarchConfigValue`. |
| String matching for risk | XML `-match` per mechanism-decisions.md. Comment in code explains why. |

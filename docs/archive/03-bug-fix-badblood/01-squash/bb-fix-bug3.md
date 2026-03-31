# BB Fix Bug 3: Orchestrator doesn't pass GPO switches

Context: `CLAUDE.md`, `/var/mnt/storage/CODE/dev-guide.md`

## Problem

`Monarch.psm1:2813` — the orchestrator calls `Export-GPOAudit` with only `Server` and `OutputPath`:

```powershell
@{ Name = 'Export-GPOAudit'; Params = @{ Server = $dc; OutputPath = $dirs.GPO } }
```

`Export-GPOAudit` has two switch parameters — `-IncludePermissions` (line 1137) and `-IncludeWMIFilters` (line 1138) — that gate the permission analysis (lines 1248-1274) and WMI filter export (lines 1277-1286). Without these switches, both code paths are skipped entirely.

The return object reflects this: `OutputPaths.Permissions` and `OutputPaths.WMI` return `$null` (lines 1324-1325, gated by `if ($IncludePermissions)` / `if ($IncludeWMIFilters)`).

Note: folder creation at lines 1154-1156 creates all 6 output directories unconditionally when `$OutputPath` is set. So `04-Permissions/` and `05-WMI-Filters/` exist on disk but are empty.

## Decision

Add both switches to the orchestrator call. Permission analysis and WMI filter export are standard audit data that should always run during a Discovery audit. The switches exist for direct callers who want a lightweight export — the orchestrator should always use the full analysis.

## Pass 1 — Code fix

**File:** `Monarch.psm1`, line 2813

**Before:**
```powershell
@{ Name = 'Export-GPOAudit'; Params = @{ Server = $dc; OutputPath = $dirs.GPO } }
```

**After:**
```powershell
@{ Name = 'Export-GPOAudit'; Params = @{ Server = $dc; OutputPath = $dirs.GPO; IncludePermissions = $true; IncludeWMIFilters = $true } }
```

## Pass 2 — Test update

**File:** `Tests/Monarch.Tests.ps1`, `Invoke-DomainAudit` Describe block

- Find the mock or assertion for `Export-GPOAudit` within the orchestrator tests
- Verify the mock is called with `-IncludePermissions` and `-IncludeWMIFilters` (or update the assertion to check for these)
- If the mock's return object has `OutputPaths.Permissions = $null`, update it to return a path value since the switches are now passed

Run:
```powershell
Invoke-Pester -Path Tests/Monarch.Tests.ps1 -Filter 'Invoke-DomainAudit'
```

## Verification

- All Invoke-DomainAudit Pester tests pass
- On BB domain: `04-Permissions/gpo-permissions.csv` is created with permission data. `OutputPaths.Permissions` and `OutputPaths.WMI` are non-null in the return object. If overpermissioned GPOs exist, `REVIEW-overpermissioned-gpos.csv` is also created.

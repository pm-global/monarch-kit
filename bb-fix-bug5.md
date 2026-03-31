# BB Fix Bug 5: Export-GPOAudit — `.Order` property on GPO XML link nodes

Context: `CLAUDE.md`, `/var/mnt/storage/CODE/dev-guide.md`

## Problem

`Monarch.psm1:1200` — `Order = $link.Order` where `$link` comes from the GPO XML report's `LinksTo` node (`$report.GPO['LinksTo']` at line 1192).

The `LinksTo` XML node has: `SOMPath`, `Enabled`, `NoOverride`. It does not have `Order`. Accessing the nonexistent property on the XML element throws, caught by the per-GPO catch at line 1212. The warning is recorded but the GPO's linkage data is lost (the `$linkageDetails.Add()` at line 1195 never completes).

Also line 1209: `Order = 'N/A'` in the unlinked fallback object — this doesn't throw but should be removed for consistency.

## Decision

Remove `Order` from both linkage objects. Link order is not critical audit data for the Discovery report. The value was never successfully populated — it was always either throwing (linked GPOs) or hardcoded 'N/A' (unlinked GPOs). The `gpo-linkage.csv` loses the Order column, which is acceptable since it never contained real data.

More importantly, removing `Order` means the per-GPO catch block at line 1212 will no longer fire for this reason, so the linkage data (SOMPath, Enabled, NoOverride) will actually be captured.

## Pass 1 — Code fix

**File:** `Monarch.psm1`

**Lines 1195-1201 (linked GPO object) — remove Order line:**

Before:
```powershell
$linkageDetails.Add([PSCustomObject]@{
    GPOName    = $gpo.DisplayName
    LinkedTo   = $link.SOMPath
    Enabled    = $link.Enabled
    NoOverride = $link.NoOverride
    Order      = $link.Order
})
```

After:
```powershell
$linkageDetails.Add([PSCustomObject]@{
    GPOName    = $gpo.DisplayName
    LinkedTo   = $link.SOMPath
    Enabled    = $link.Enabled
    NoOverride = $link.NoOverride
})
```

**Lines 1204-1210 (unlinked fallback object) — remove Order line:**

Before:
```powershell
$linkageDetails.Add([PSCustomObject]@{
    GPOName    = $gpo.DisplayName
    LinkedTo   = '**UNLINKED**'
    Enabled    = 'N/A'
    NoOverride = 'N/A'
    Order      = 'N/A'
})
```

After:
```powershell
$linkageDetails.Add([PSCustomObject]@{
    GPOName    = $gpo.DisplayName
    LinkedTo   = '**UNLINKED**'
    Enabled    = 'N/A'
    NoOverride = 'N/A'
})
```

## Pass 2 — Test update

**File:** `Tests/Monarch.Tests.ps1`, `Export-GPOAudit` Describe block

- Remove `Order` from any mock linkage/XML objects
- Remove assertions checking for `Order` property on linkage detail objects
- Verify remaining assertions check `GPOName`, `LinkedTo`, `Enabled`, `NoOverride`

Run:
```powershell
Invoke-Pester -Path Tests/Monarch.Tests.ps1 -Filter 'Export-GPOAudit'
```

## Verification

- All Export-GPOAudit Pester tests pass
- On BB domain: no "property 'Order' cannot be found" warnings. `gpo-linkage.csv` generated with columns: GPOName, LinkedTo, Enabled, NoOverride (no Order column). Linkage data is actually populated now (previously lost due to the throw).

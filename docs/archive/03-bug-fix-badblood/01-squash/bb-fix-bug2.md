# BB Fix Bug 2: Get-EventLogConfiguration — `.LogRetention` doesn't exist - COMPLETE

Context: `CLAUDE.md`, `/var/mnt/storage/CODE/dev-guide.md`

## Problem

`Monarch.psm1:2208` — `RetentionDays = [int]$log.LogRetention` inside the `Invoke-Command` scriptblock result processing. `Get-WinEvent -ListLog` returns `System.Diagnostics.Eventing.Reader.EventLogConfiguration` objects. That class has:

- `LogName` — used at line 2206, works
- `MaximumSizeInBytes` — used at line 2207 (divided by 1024), works
- `LogMode` — enum (`Circular`, `AutoBackup`, `Retain`), used at line 2209 as `OverflowAction`, works
- `LogRetention` — **does not exist on this class**

The property access throws inside the foreach loop at line 2204. Since it's inside a try/catch (line 2195/2216), the entire DC's log data is lost. With a single DC, `DCs` comes back empty.

## Decision

Remove `RetentionDays` from the log object. Windows event logs don't have a separate "retention days" concept — retention behavior is controlled by `LogMode`:
- `Circular` = overwrite oldest events (no retention limit)
- `AutoBackup` = archive log when full, then overwrite
- `Retain` = never overwrite (manual clear required)

The report switch cases in `New-MonarchReport` that check event log data reference `MaxSizeKB` and `OverflowAction`, not `RetentionDays`. No downstream changes needed.

## Pass 1 — Code fix

**File:** `Monarch.psm1`, lines 2205-2210

**Before:**
```powershell
$logs += [PSCustomObject]@{
    LogName        = $log.LogName
    MaxSizeKB      = [int]($log.MaximumSizeInBytes / 1024)
    RetentionDays  = [int]$log.LogRetention
    OverflowAction = [string]$log.LogMode
}
```

**After:**
```powershell
$logs += [PSCustomObject]@{
    LogName        = $log.LogName
    MaxSizeKB      = [int]($log.MaximumSizeInBytes / 1024)
    OverflowAction = [string]$log.LogMode
}
```

## Pass 2 — Test update

**File:** `Tests/Monarch.Tests.ps1`, `Get-EventLogConfiguration` Describe block

- Remove `LogRetention` from any mock return objects that simulate `Get-WinEvent -ListLog` output
- Remove any assertions referencing `RetentionDays` on the log objects
- Verify remaining assertions check `LogName`, `MaxSizeKB`, `OverflowAction`

Run:
```powershell
Invoke-Pester -Path Tests/Monarch.Tests.ps1 -Filter 'Get-EventLogConfiguration'
```

## Verification

- All Get-EventLogConfiguration Pester tests pass
- On BB domain: `DCs` array populated with log data, `MaxSizeKB` and `OverflowAction` have values, no "LogRetention" warning

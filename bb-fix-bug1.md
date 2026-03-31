# BB Fix Bug 1: Get-ReplicationHealth — `-Server` splatted to wrong cmdlet — COMPLETE

Context: `CLAUDE.md`, `/var/mnt/storage/CODE/dev-guide.md`

## Problem

`Monarch.psm1:525` — `Get-ADReplicationPartnerMetadata -Target $dc.HostName @splatAD` passes `-Server` via the `@splatAD` splat. `Get-ADReplicationPartnerMetadata` does not accept `-Server` — it uses `-Target` for DC targeting, which is already provided. The invalid parameter causes the cmdlet to throw, caught by the per-DC catch block at line 564. Result: every DC's replication data is lost, the function returns zero links.

This means replication health is completely broken in every environment.

The DC list itself (line 513: `Get-ADDomainController -Filter '*' @splatAD`) correctly uses `@splatAD` — only the replication metadata call is wrong.

## Decision

Remove `@splatAD` from line 525. The `-Target $dc.HostName` already directs the query to the correct DC. Since `$dcObjects` was fetched from the correct domain via `@splatAD` at line 513, each `$dc.HostName` is already scoped to the right domain. No other targeting is needed.

## Pass 1 — Code fix — COMPLETE

**File:** `Monarch.psm1`, line 525

**Before:**
```powershell
$metadata = @(Get-ADReplicationPartnerMetadata -Target $dc.HostName @splatAD)
```

**After:**
```powershell
$metadata = @(Get-ADReplicationPartnerMetadata -Target $dc.HostName)
```

No other lines change. The rest of the function (partition classification, status grading, diagnostic hints) is correct — it just never received data.

## Pass 2 — Test update — COMPLETE

**File:** `Tests/Monarch.Tests.ps1`, `Get-ReplicationHealth` Describe block

Find the mock for `Get-ADReplicationPartnerMetadata`. If its `-ParameterFilter` checks for `-Server`, remove that filter — the real cmdlet doesn't accept `-Server`. The mock should filter on `-Target` if anything.

Run:
```powershell
Invoke-Pester -Path Tests/Monarch.Tests.ps1 -Filter 'Get-ReplicationHealth'
```

## Verification

- All Get-ReplicationHealth Pester tests pass
- On BB domain: function returns link data, `HealthyLinkCount`/`WarningLinkCount`/`FailedLinkCount` are populated, no "parameter name 'Server'" warning in `Warnings` array

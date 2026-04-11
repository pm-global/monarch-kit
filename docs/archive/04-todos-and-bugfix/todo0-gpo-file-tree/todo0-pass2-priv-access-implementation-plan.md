# TODO-2: Privileged Access File Output — Pass 2 Implementation

## Context

`Invoke-DomainAudit` creates `03-Privileged-Access/` but the four priv access functions never write
to it. Pass 2 adds `-OutputPath` support to two functions and a combine block in the orchestrator
for the two roastable functions.

Git history confirmed: these functions never had `-OutputPath`. Purely additive — no regression.

## Critical Files

- `Monarch.psm1` — `Get-PrivilegedGroupMembership` (line 765), `Find-AdminCountOrphan` (line 860),
  orchestrator `$calls` array (lines 3064–3065) and post-loop gap (after line 3096)

## Change Budget

~35 lines added, 2 lines modified. No deletions.

---

## Change 1 — `Get-PrivilegedGroupMembership` (line 767)

**Param:** add `[string]$OutputPath` alongside `[string]$Server`.

**Before the return block** (after line 838, before Section 3 comment at line 840):

```powershell
    $csvPath = $null
    if ($OutputPath) {
        $flatMembers = foreach ($g in $groups) {
            foreach ($m in $g.Members) {
                $m | Select-Object SamAccountName, @{n='GroupName';e={$g.GroupName}},
                    DisplayName, ObjectType, IsDirect, IsEnabled, LastLogon
            }
        }
        $flatMembers = @($flatMembers | Sort-Object SamAccountName)
        if ($flatMembers.Count -gt 0) {
            $csvPath = Join-Path $OutputPath 'privileged-groups.csv'
            $flatMembers | Export-Csv -Path $csvPath -NoTypeInformation
        }
    }
```

**Return object:** add `CSVPath = $csvPath`.

---

## Change 2 — `Find-AdminCountOrphan` (line 862)

**Param:** add `[string]$OutputPath` alongside `[string]$Server`.

**Before the return block** (after line 909, before line 911):

```powershell
    $csvPath = $null
    if ($OutputPath -and $orphans.Count -gt 0) {
        $csvPath = Join-Path $OutputPath 'admincount-orphans.csv'
        $orphans | Select-Object SamAccountName, DisplayName, Enabled,
            @{n='MemberOf';e={$_.MemberOf -join '; '}} |
            Export-Csv -Path $csvPath -NoTypeInformation
    }
```

**Return object:** add `CSVPath = $csvPath`.

---

## Change 3 — Orchestrator

**Lines 3064–3065:** add `OutputPath = $dirs.Priv` to the two param hashes:

```powershell
@{ Name = 'Get-PrivilegedGroupMembership'; Domain = 'PrivilegedAccess'; Params = @{ Server = $dc; OutputPath = $dirs.Priv } }
@{ Name = 'Find-AdminCountOrphan';         Domain = 'PrivilegedAccess'; Params = @{ Server = $dc; OutputPath = $dirs.Priv } }
```

**After line 3096** (foreach closes), before `$orchestratorResult` at line 3099:

```powershell
    # Combine roastable accounts into a single CSV
    try {
        $kerbResult  = $results | Where-Object { $_.Function -eq 'Find-KerberoastableAccount' }
        $asrepResult = $results | Where-Object { $_.Function -eq 'Find-ASREPRoastableAccount' }
        $rows = [System.Collections.Generic.List[PSCustomObject]]::new()
        if ($kerbResult) {
            foreach ($a in @($kerbResult.Accounts)) {
                $rows.Add([PSCustomObject]@{
                    ThreatType = 'Kerberoast'; SamAccountName = $a.SamAccountName
                    DisplayName = $a.DisplayName; IsPrivileged = $a.IsPrivileged
                    Enabled = $a.Enabled; SPNs = ($a.SPNs -join '; '); PasswordAgeDays = $a.PasswordAgeDays
                })
            }
        }
        if ($asrepResult) {
            foreach ($a in @($asrepResult.Accounts)) {
                $rows.Add([PSCustomObject]@{
                    ThreatType = 'ASREP'; SamAccountName = $a.SamAccountName
                    DisplayName = $a.DisplayName; IsPrivileged = $a.IsPrivileged
                    Enabled = $a.Enabled; SPNs = $null; PasswordAgeDays = $null
                })
            }
        }
        if ($rows.Count -gt 0) {
            $rows | Export-Csv -Path (Join-Path $dirs.Priv 'roastable-accounts.csv') -NoTypeInformation
        }
    } catch {
        Write-Warning "Roastable CSV combine failed: $_"
    }
```

**Notes:**
- `$kerbResult`/`$asrepResult` guarded with `if` — `Where-Object` with no match assigns `$null`
- `SPNs` joined to string for CSV; return object still holds original array
- `catch` emits `Write-Warning` and does not rethrow — orchestrator completes regardless

---

## Invariants (from todo0)

- `CSVPath` non-null if and only if a file was written
- `roastable-accounts.csv` never written with 0 rows
- All rows in `privileged-groups.csv` have a non-null `GroupName`
- No new AD calls during CSV export
- Orchestrator return contract unchanged

## Out of Scope

- New columns or additional AD properties beyond what functions already collect
- Report changes
- `-OutputPath` on `Find-KerberoastableAccount` or `Find-ASREPRoastableAccount`
- Resolving `MemberOf` DNs to display names

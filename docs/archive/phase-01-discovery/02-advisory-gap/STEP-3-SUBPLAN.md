# Step 3 + Step 4 Subplan: Fix and Add Switch Cases

## Target File

`Monarch.psm1` — switch block at lines 2483–2523.

All new cases go inside the `switch ($r.Function)` block (before the closing `}` on line 2524). Follow the existing one-liner pattern: condition check → `.Add()` call on `$criticals` or `$advisories`.

---

## Pass 1 — Fix Find-KerberoastableAccount (line 2512)

**Current (broken):**
```powershell
'Find-KerberoastableAccount' {
    if ($r.PrivilegedCount -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.PrivilegedCount) privileged accounts with SPNs (Kerberoasting risk)" }) }
}
```

**Replace with:**
```powershell
'Find-KerberoastableAccount' {
    if ($r.PrivilegedCount -gt 0) { $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.PrivilegedCount) privileged accounts with SPNs (Kerberoasting risk -- privileged)" }) }
    if ($r.TotalCount -gt 0 -and $r.PrivilegedCount -eq 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.TotalCount) accounts with SPNs (Kerberoasting risk)" }) }
}
```

**Why two branches, not one:** If PrivilegedCount > 0, the finding is critical (privileged accounts crackable offline). If TotalCount > 0 but no privileged accounts, it's advisory. The `-and $r.PrivilegedCount -eq 0` guard prevents a double entry when both are nonzero.

---

## Pass 2 — Security-Critical Items (new cases)

### Find-ASREPRoastableAccount

Return object: `Count` (int), `Accounts` (array). Domain: `PrivilegedAccess`.

```powershell
'Find-ASREPRoastableAccount' {
    if ($r.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.Count) accounts with Kerberos pre-auth disabled (AS-REP roasting risk)" }) }
}
```

No severity escalation — AS-REP roasting requires pre-auth disabled which is uncommon on privileged accounts, so advisory is appropriate.

### Find-WeakAccountFlag

Return object: `Findings` (array of objects with `.Flag`), `CountByFlag` (hashtable). Domain: `SecurityPosture`.

```powershell
'Find-WeakAccountFlag' {
    if ($r.CountByFlag.ContainsKey('ReversibleEncryption') -or $r.CountByFlag.ContainsKey('DESOnly')) {
        $desc = @()
        if ($r.CountByFlag.ContainsKey('ReversibleEncryption')) { $desc += "$($r.CountByFlag['ReversibleEncryption']) with reversible encryption" }
        if ($r.CountByFlag.ContainsKey('DESOnly')) { $desc += "$($r.CountByFlag['DESOnly']) with DES-only Kerberos" }
        $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = ($desc -join ', ') })
    }
    if ($r.Findings.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.Findings.Count) accounts with weak security flags" }) }
}
```

**Why both critical and advisory:** ReversibleEncryption and DES are cryptographic weaknesses that enable password recovery — critical. PasswordNeverExpires is a hygiene finding — advisory. A domain can have both.

### Find-LegacyProtocolExposure

Return object: `DCFindings` (array of objects with `.Risk`). Domain: `SecurityPosture`.

```powershell
'Find-LegacyProtocolExposure' {
    $highRisk = @($r.DCFindings | Where-Object { $_.Risk -eq 'High' })
    if ($highRisk.Count -gt 0) { $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($highRisk.Count) high-risk legacy protocol findings (NTLMv1/LM hash)" }) }
    $medRisk = @($r.DCFindings | Where-Object { $_.Risk -eq 'Medium' })
    if ($medRisk.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($medRisk.Count) legacy protocol findings on DCs" }) }
}
```

---

## Pass 3 — GPO Item

### Find-GPOPermissionAnomaly

Return object: `Anomalies` (array), `Count` (int). Domain: `GroupPolicy`.

```powershell
'Find-GPOPermissionAnomaly' {
    if ($r.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.Count) GPOs with non-standard editors" }) }
}
```

**Find-UnlinkedGPO: SKIPPED.** Redundant with `Export-GPOAudit` (same underlying query, case already exists at line 2521).

---

## Pass 4 — Threshold-Based Items (using config keys from Step 2)

### Get-PasswordPolicyInventory

Return object: `DefaultPolicy` (sub-object with MinLength, ComplexityEnabled, LockoutThreshold, ReversibleEncryption). Domain: `SecurityPosture`.

```powershell
'Get-PasswordPolicyInventory' {
    $minLen = Get-MonarchConfigValue -Key 'MinPasswordLength'
    $reqLockout = Get-MonarchConfigValue -Key 'RequireLockoutThreshold'
    $dp = $r.DefaultPolicy
    if ($null -ne $dp) {
        if ($dp.ReversibleEncryption -eq $true) { $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = 'Default domain policy stores passwords with reversible encryption' }) }
        $issues = @()
        if ($dp.MinLength -lt $minLen) { $issues += "minimum length $($dp.MinLength) (recommended $minLen)" }
        if ($dp.ComplexityEnabled -eq $false) { $issues += 'complexity requirements disabled' }
        if ($reqLockout -and $dp.LockoutThreshold -eq 0) { $issues += 'no account lockout threshold' }
        if ($issues.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "Default password policy: $($issues -join '; ')" }) }
    }
}
```

**Why ReversibleEncryption is critical here too:** Same reason as Find-WeakAccountFlag — it's a domain-wide policy enabling password recovery. The per-account finding and the policy-level finding are different signals (who has it vs. is it the default).

### Get-DNSScavengingConfiguration

Return object: `Zones` (array of objects with `.ScavengingEnabled`). Domain: `DNS`.

```powershell
'Get-DNSScavengingConfiguration' {
    $reqScav = Get-MonarchConfigValue -Key 'RequireDNSScavenging'
    if ($reqScav) {
        $stale = @($r.Zones | Where-Object { $_.ScavengingEnabled -eq $false })
        if ($stale.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($stale.Count) DNS zones with scavenging disabled" }) }
    }
}
```

### Get-EventLogConfiguration

Return object: `DCs` (array of objects with `.DCName` and `.Logs` array). Each log has `LogName`, `MaxSizeKB`, `OverflowAction`. Domain: `AuditCompliance`.

```powershell
'Get-EventLogConfiguration' {
    $minSize = Get-MonarchConfigValue -Key 'MinSecurityLogSizeKB'
    $okActions = Get-MonarchConfigValue -Key 'AcceptableOverflowActions'
    $issues = @()
    foreach ($dc in $r.DCs) {
        $secLog = $dc.Logs | Where-Object { $_.LogName -eq 'Security' }
        if ($null -ne $secLog) {
            if ($secLog.MaxSizeKB -lt $minSize) { $issues += "$($dc.DCName): Security log $($secLog.MaxSizeKB)KB (minimum $minSize)" }
            if ($secLog.OverflowAction -notin $okActions) { $issues += "$($dc.DCName): Security log overflow action '$($secLog.OverflowAction)'" }
        }
    }
    if ($issues.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($issues.Count) event log configuration issues across DCs" }) }
}
```

### Test-ZoneReplicationScope

Return object: `Zones` (array of objects with `.IsDsIntegrated`, `.ReplicationScope`). Domain: `DNS`.

```powershell
'Test-ZoneReplicationScope' {
    $reqDS = Get-MonarchConfigValue -Key 'RequireDSIntegration'
    if ($reqDS) {
        $nonDS = @($r.Zones | Where-Object { $_.IsDsIntegrated -eq $false })
        if ($nonDS.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($nonDS.Count) DNS zones not AD-integrated" }) }
    }
}
```

---

## Step 4 — Judgment-Call Function

### Get-FSMORolePlacement

Return object: `UnreachableCount` (int), `AllOnOneDC` (bool). Domain: `InfrastructureHealth`.

```powershell
'Get-FSMORolePlacement' {
    if ($r.UnreachableCount -gt 0) { $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.UnreachableCount) FSMO role holders unreachable" }) }
    if ($r.AllOnOneDC -eq $true) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = 'All FSMO roles held by a single DC' }) }
}
```

**Test-TombstoneGap: SKIPPED.** Orchestrator doesn't pass `-BackupAgeDays`, so `CriticalGap` is always `$null`. Redundant with `Get-BackupReadinessStatus` in the current pipeline.

---

## Insertion Point

All new cases go before the closing `}` on line 2524 (end of the switch block). Suggested ordering: keep existing cases in place, append new cases after `Export-GPOAudit` (line 2523), grouped by pass.

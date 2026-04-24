# Step 5 Subplan: Integration Tests

## Target File

`Tests/Monarch.Tests.ps1` — add a new `Context` block inside the existing `Describe 'New-MonarchReport'` block (after line 3471, before the Invoke-DomainAudit describe at line 3473).

## Test Infrastructure

All tests follow the existing pattern: build a `$mockResults` object with the same shape as `Invoke-DomainAudit` output, pass it to `New-MonarchReport`, read the HTML, and assert content.

The existing `BeforeAll` mock for `Get-MonarchConfigValue` (line 3369) returns `'#2E5090'` for all keys. For threshold-based tests, override this mock in the specific `Context` blocks that need config values.

---

## Context: Advisory extraction for all analysis functions

### BeforeAll

Build mock results with finding-worthy data for every function that has a switch case (existing + new). This is the comprehensive "everything has findings" scenario.

```powershell
Context 'Advisory extraction covers all analysis functions' {
    BeforeAll {
        Mock -ModuleName Monarch Get-MonarchConfigValue {
            switch ($Key) {
                'MinPasswordLength'         { 14 }
                'RequireLockoutThreshold'   { $true }
                'MinSecurityLogSizeKB'      { 1048576 }
                'AcceptableOverflowActions' { @('ArchiveTheLogWhenFull') }
                'RequireDNSScavenging'      { $true }
                'RequireDSIntegration'      { $true }
                default                     { '#2E5090' }
            }
        }
        $script:outDir = Join-Path $TestDrive 'report-advisories'
        New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
        $script:mockResults = [PSCustomObject]@{
            Phase = 'Discovery'; Domain = 'contoso.com'; DCUsed = 'DC01.contoso.com'
            StartTime = [datetime]'2026-03-25 14:00'; EndTime = [datetime]'2026-03-25 14:30'
            Failures = @()
            Results = @(
                # --- Existing cases (sanity) ---
                [PSCustomObject]@{ Domain = 'IdentityLifecycle'; Function = 'Find-DormantAccount'; TotalCount = 12; NeverLoggedOnCount = 3; Warnings = @() }
                [PSCustomObject]@{ Domain = 'PrivilegedAccess'; Function = 'Find-AdminCountOrphan'; Count = 4; Orphans = @(); Warnings = @() }

                # --- Fixed case ---
                [PSCustomObject]@{ Domain = 'PrivilegedAccess'; Function = 'Find-KerberoastableAccount'; TotalCount = 50; PrivilegedCount = 0; Accounts = @(); Warnings = @() }

                # --- New cases: security-critical ---
                [PSCustomObject]@{ Domain = 'PrivilegedAccess'; Function = 'Find-ASREPRoastableAccount'; Count = 3; Accounts = @(); Warnings = @() }
                [PSCustomObject]@{ Domain = 'SecurityPosture'; Function = 'Find-WeakAccountFlag'; Findings = @(1,2,3); CountByFlag = @{ 'PasswordNeverExpires' = 3 }; Warnings = @() }
                [PSCustomObject]@{ Domain = 'SecurityPosture'; Function = 'Find-LegacyProtocolExposure'; DCFindings = @([PSCustomObject]@{ Risk = 'Medium'; Finding = 'LDAPSigningDisabled' }); Warnings = @() }

                # --- New case: GPO ---
                [PSCustomObject]@{ Domain = 'GroupPolicy'; Function = 'Find-GPOPermissionAnomaly'; Count = 2; Anomalies = @(1,2); Warnings = @() }

                # --- New cases: threshold-based ---
                [PSCustomObject]@{ Domain = 'SecurityPosture'; Function = 'Get-PasswordPolicyInventory'; DefaultPolicy = [PSCustomObject]@{ MinLength = 8; ComplexityEnabled = $false; LockoutThreshold = 0; ReversibleEncryption = $false }; FineGrainedPolicies = @(); Warnings = @() }
                [PSCustomObject]@{ Domain = 'DNS'; Function = 'Get-DNSScavengingConfiguration'; Zones = @([PSCustomObject]@{ ZoneName = 'contoso.com'; ScavengingEnabled = $false }); Warnings = @() }
                [PSCustomObject]@{ Domain = 'AuditCompliance'; Function = 'Get-EventLogConfiguration'; DCs = @([PSCustomObject]@{ DCName = 'DC01'; Logs = @([PSCustomObject]@{ LogName = 'Security'; MaxSizeKB = 512000; OverflowAction = 'OverwriteAsNeeded' }) }); Warnings = @() }
                [PSCustomObject]@{ Domain = 'DNS'; Function = 'Test-ZoneReplicationScope'; Zones = @([PSCustomObject]@{ ZoneName = 'contoso.com'; IsDsIntegrated = $false; ReplicationScope = $null; ZoneType = 'Primary' }); Warnings = @() }

                # --- Judgment-call ---
                [PSCustomObject]@{ Domain = 'InfrastructureHealth'; Function = 'Get-FSMORolePlacement'; Roles = @(); AllOnOneDC = $true; UnreachableCount = 0; Warnings = @() }
            )
        }
        $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
        $script:content = Get-Content $script:result -Raw
    }
```

### Positive Tests (findings -> advisories)

One `It` block per function. Each asserts that the advisory or critical description text appears in the HTML.

```powershell
    # Fixed case
    It 'Find-KerberoastableAccount with TotalCount produces advisory' {
        $content | Should -Match '50 accounts with SPNs'
    }

    # New cases
    It 'Find-ASREPRoastableAccount produces advisory' {
        $content | Should -Match '3 accounts with Kerberos pre-auth disabled'
    }

    It 'Find-WeakAccountFlag produces advisory' {
        $content | Should -Match 'accounts with weak security flags'
    }

    It 'Find-LegacyProtocolExposure medium risk produces advisory' {
        $content | Should -Match 'legacy protocol findings on DCs'
    }

    It 'Find-GPOPermissionAnomaly produces advisory' {
        $content | Should -Match '2 GPOs with non-standard editors'
    }

    It 'Get-PasswordPolicyInventory weak policy produces advisory' {
        $content | Should -Match 'minimum length 8'
    }

    It 'Get-DNSScavengingConfiguration disabled zones produce advisory' {
        $content | Should -Match 'DNS zones with scavenging disabled'
    }

    It 'Get-EventLogConfiguration undersized log produces advisory' {
        $content | Should -Match 'event log configuration issues'
    }

    It 'Test-ZoneReplicationScope non-integrated produces advisory' {
        $content | Should -Match 'DNS zones not AD-integrated'
    }

    It 'Get-FSMORolePlacement AllOnOneDC produces advisory' {
        $content | Should -Match 'All FSMO roles held by a single DC'
    }
}
```

---

## Context: Severity Escalation Tests

Separate context with mock data that triggers critical-level findings.

```powershell
Context 'Severity escalation to critical' {
    BeforeAll {
        Mock -ModuleName Monarch Get-MonarchConfigValue { '#2E5090' }
        $script:outDir = Join-Path $TestDrive 'report-escalation'
        New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
        $script:mockResults = [PSCustomObject]@{
            Phase = 'Discovery'; Domain = 'contoso.com'; DCUsed = 'DC01.contoso.com'
            StartTime = [datetime]'2026-03-25 14:00'; EndTime = [datetime]'2026-03-25 14:30'
            Failures = @()
            Results = @(
                [PSCustomObject]@{ Domain = 'PrivilegedAccess'; Function = 'Find-KerberoastableAccount'; TotalCount = 50; PrivilegedCount = 3; Accounts = @(); Warnings = @() }
                [PSCustomObject]@{ Domain = 'SecurityPosture'; Function = 'Find-WeakAccountFlag'; Findings = @(1,2); CountByFlag = @{ 'ReversibleEncryption' = 2 }; Warnings = @() }
                [PSCustomObject]@{ Domain = 'SecurityPosture'; Function = 'Find-LegacyProtocolExposure'; DCFindings = @([PSCustomObject]@{ Risk = 'High'; Finding = 'NTLMv1Enabled' }); Warnings = @() }
                [PSCustomObject]@{ Domain = 'InfrastructureHealth'; Function = 'Get-FSMORolePlacement'; Roles = @(); AllOnOneDC = $false; UnreachableCount = 1; Warnings = @() }
                [PSCustomObject]@{ Domain = 'SecurityPosture'; Function = 'Get-PasswordPolicyInventory'; DefaultPolicy = [PSCustomObject]@{ MinLength = 14; ComplexityEnabled = $true; LockoutThreshold = 5; ReversibleEncryption = $true }; FineGrainedPolicies = @(); Warnings = @() }
            )
        }
        $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
        $script:content = Get-Content $script:result -Raw
        $script:critSection = ($content -split 'critical-section')[0]
    }

    It 'Kerberoastable with PrivilegedCount escalates to critical' {
        $content | Should -Match 'privileged accounts with SPNs.*privileged'
        $critSection | Should -Match 'privileged accounts with SPNs'
    }

    It 'WeakAccountFlag ReversibleEncryption escalates to critical' {
        $content | Should -Match 'reversible encryption'
        $critSection | Should -Match 'reversible encryption'
    }

    It 'LegacyProtocolExposure High risk escalates to critical' {
        $content | Should -Match 'high-risk legacy protocol'
        $critSection | Should -Match 'high-risk legacy protocol'
    }

    It 'FSMORolePlacement UnreachableCount escalates to critical' {
        $content | Should -Match 'FSMO role holders unreachable'
        $critSection | Should -Match 'FSMO role holders unreachable'
    }

    It 'PasswordPolicy ReversibleEncryption escalates to critical' {
        $content | Should -Match 'reversible encryption'
    }
}
```

---

## Context: Negative Tests (clean data -> no advisory)

Verify that results within acceptable ranges produce no advisory.

```powershell
Context 'Clean results produce no advisories for threshold functions' {
    BeforeAll {
        Mock -ModuleName Monarch Get-MonarchConfigValue {
            switch ($Key) {
                'MinPasswordLength'         { 14 }
                'RequireLockoutThreshold'   { $true }
                'MinSecurityLogSizeKB'      { 1048576 }
                'AcceptableOverflowActions' { @('ArchiveTheLogWhenFull') }
                'RequireDNSScavenging'      { $true }
                'RequireDSIntegration'      { $true }
                default                     { '#2E5090' }
            }
        }
        $script:outDir = Join-Path $TestDrive 'report-clean'
        New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
        $script:mockResults = [PSCustomObject]@{
            Phase = 'Discovery'; Domain = 'contoso.com'; DCUsed = 'DC01.contoso.com'
            StartTime = [datetime]'2026-03-25 14:00'; EndTime = [datetime]'2026-03-25 14:30'
            Failures = @()
            Results = @(
                [PSCustomObject]@{ Domain = 'PrivilegedAccess'; Function = 'Find-KerberoastableAccount'; TotalCount = 0; PrivilegedCount = 0; Accounts = @(); Warnings = @() }
                [PSCustomObject]@{ Domain = 'PrivilegedAccess'; Function = 'Find-ASREPRoastableAccount'; Count = 0; Accounts = @(); Warnings = @() }
                [PSCustomObject]@{ Domain = 'SecurityPosture'; Function = 'Find-WeakAccountFlag'; Findings = @(); CountByFlag = @{}; Warnings = @() }
                [PSCustomObject]@{ Domain = 'SecurityPosture'; Function = 'Find-LegacyProtocolExposure'; DCFindings = @(); Warnings = @() }
                [PSCustomObject]@{ Domain = 'GroupPolicy'; Function = 'Find-GPOPermissionAnomaly'; Count = 0; Anomalies = @(); Warnings = @() }
                [PSCustomObject]@{ Domain = 'SecurityPosture'; Function = 'Get-PasswordPolicyInventory'; DefaultPolicy = [PSCustomObject]@{ MinLength = 14; ComplexityEnabled = $true; LockoutThreshold = 5; ReversibleEncryption = $false }; FineGrainedPolicies = @(); Warnings = @() }
                [PSCustomObject]@{ Domain = 'DNS'; Function = 'Get-DNSScavengingConfiguration'; Zones = @([PSCustomObject]@{ ZoneName = 'contoso.com'; ScavengingEnabled = $true }); Warnings = @() }
                [PSCustomObject]@{ Domain = 'AuditCompliance'; Function = 'Get-EventLogConfiguration'; DCs = @([PSCustomObject]@{ DCName = 'DC01'; Logs = @([PSCustomObject]@{ LogName = 'Security'; MaxSizeKB = 1048576; OverflowAction = 'ArchiveTheLogWhenFull' }) }); Warnings = @() }
                [PSCustomObject]@{ Domain = 'DNS'; Function = 'Test-ZoneReplicationScope'; Zones = @([PSCustomObject]@{ ZoneName = 'contoso.com'; IsDsIntegrated = $true; ReplicationScope = 'DomainDnsZones'; ZoneType = 'Primary' }); Warnings = @() }
                [PSCustomObject]@{ Domain = 'InfrastructureHealth'; Function = 'Get-FSMORolePlacement'; Roles = @(); AllOnOneDC = $false; UnreachableCount = 0; Warnings = @() }
            )
        }
        $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
        $script:content = Get-Content $script:result -Raw
    }

    It 'produces zero criticals and zero advisories' {
        $content | Should -Match "stat-number'>0</div><div class='stat-label'>Critical"
        $content | Should -Match "stat-number'>0</div><div class='stat-label'>Advisory"
    }

    It 'no domain sections rendered' {
        $content | Should -Not -Match "<div class='domain-section'>"
    }
}
```

---

## Test Count Summary

| Context | Tests |
|---------|-------|
| Advisory extraction (positive) | 10 |
| Severity escalation | 5 |
| Clean results (negative) | 2 |
| **Total new tests** | **17** |

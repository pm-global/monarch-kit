#Requires -Modules Pester

# Monarch.Tests.ps1
# Pester 5+ tests for the Monarch module.
# All AD/DNS/GPO cmdlets are mocked — tests run without a domain.
# Organized by Describe blocks per function, added alongside code at each step.

BeforeAll {
    # Import the module from the project root, not from any installed location.
    $modulePath = Join-Path $PSScriptRoot '..' 'Monarch.psm1'

    # Remove the module if already loaded so we get a fresh import.
    if (Get-Module -Name 'Monarch')
    {
        Remove-Module -Name 'Monarch' -Force
    }

    # Mock ActiveDirectory module commands before import so RequiredModules
    # doesn't block us in a test environment without AD.
    # We import the .psm1 directly (not the .psd1) to skip RequiredModules enforcement.
    Import-Module $modulePath -Force
}

AfterAll {
    if (Get-Module -Name 'Monarch')
    {
        Remove-Module -Name 'Monarch' -Force
    }
}

# =============================================================================
# Step 1: Module Foundation
# =============================================================================

Describe 'Module: Load and Export' {

    It 'imports without error' {
        Get-Module -Name 'Monarch' | Should -Not -BeNullOrEmpty
    }

    It 'manifest lists all planned public functions' {
        # Read the .psd1 manifest directly to verify it declares the full export list.
        # This tests manifest correctness, not runtime exports (which depend on
        # whether functions are implemented yet).
        $manifestPath = Join-Path $PSScriptRoot '..' 'Monarch.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath

        $expectedFunctions = @(
            'Invoke-DomainAudit'
            'New-MonarchReport'
            'Get-FSMORolePlacement'
            'Get-ReplicationHealth'
            'Get-SiteTopology'
            'Get-ForestDomainLevel'
            'Find-DormantAccount'
            'Get-PrivilegedGroupMembership'
            'Find-AdminCountOrphan'
            'Find-KerberoastableAccount'
            'Find-ASREPRoastableAccount'
            'Export-GPOAudit'
            'Find-UnlinkedGPO'
            'Find-GPOPermissionAnomaly'
            'Get-PasswordPolicyInventory'
            'Find-WeakAccountFlag'
            'Test-ProtectedUsersGap'
            'Find-LegacyProtocolExposure'
            'Get-BackupReadinessStatus'
            'Test-TombstoneGap'
            'New-DomainBaseline'
            'Get-AuditPolicyConfiguration'
            'Get-EventLogConfiguration'
            'Test-SRVRecordCompleteness'
            'Get-DNSScavengingConfiguration'
            'Test-ZoneReplicationScope'
            'Get-DNSForwarderConfiguration'
        )

        foreach ($fn in $expectedFunctions)
        {
            $fn | Should -BeIn $manifest.FunctionsToExport -Because "$fn should be in manifest FunctionsToExport"
        }
    }

    It 'manifest does not list private functions' {
        $manifestPath = Join-Path $PSScriptRoot '..' 'Monarch.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath

        $privateFunctions = @(
            'Import-MonarchConfig'
            'Get-MonarchConfigValue'
            'Resolve-MonarchDC'
        )

        foreach ($fn in $privateFunctions)
        {
            $fn | Should -Not -BeIn $manifest.FunctionsToExport -Because "$fn is private"
        }
    }

    It 'manifest does not export variables' {
        $manifestPath = Join-Path $PSScriptRoot '..' 'Monarch.psd1'
        $manifest = Import-PowerShellDataFile -Path $manifestPath
        $manifest.VariablesToExport | Should -Be @()
    }
}

# =============================================================================
# Step 2: Config Layer
# =============================================================================

Describe 'Config: Built-in Defaults' {

    # Access private functions via the module scope.
    BeforeAll {
        $getConfig = { param($Key) & (Get-Module Monarch) { Get-MonarchConfigValue -Key $args[0] } $Key }
    }

    It 'returns DormancyThresholdDays default of 90' {
        $value = & $getConfig 'DormancyThresholdDays'
        $value | Should -Be 90
    }

    It 'returns NeverLoggedOnGraceDays default of 60' {
        $value = & $getConfig 'NeverLoggedOnGraceDays'
        $value | Should -Be 60
    }

    It 'returns HoldPeriodMinimumDays default of 30' {
        $value = & $getConfig 'HoldPeriodMinimumDays'
        $value | Should -Be 30
    }

    It 'returns QuarantineOUName default of zQuarantine-Dormant' {
        $value = & $getConfig 'QuarantineOUName'
        $value | Should -Be 'zQuarantine-Dormant'
    }

    It 'returns DisableDateAttribute default of extensionAttribute15' {
        $value = & $getConfig 'DisableDateAttribute'
        $value | Should -Be 'extensionAttribute15'
    }

    It 'returns RollbackDataAttribute default of extensionAttribute14' {
        $value = & $getConfig 'RollbackDataAttribute'
        $value | Should -Be 'extensionAttribute14'
    }

    It 'returns ServiceAccountKeywords as an array containing BREAKGLASS' {
        $value = & $getConfig 'ServiceAccountKeywords'
        $value | Should -Contain 'BREAKGLASS'
    }

    It 'returns BuiltInExclusions containing krbtgt' {
        $value = & $getConfig 'BuiltInExclusions'
        $value | Should -Contain 'krbtgt'
    }

    It 'returns DomainAdminWarningThreshold default of 5' {
        $value = & $getConfig 'DomainAdminWarningThreshold'
        $value | Should -Be 5
    }

    It 'returns DomainAdminCriticalThreshold default of 10' {
        $value = & $getConfig 'DomainAdminCriticalThreshold'
        $value | Should -Be 10
    }

    It 'returns ReplicationWarningThresholdHours default of 24' {
        $value = & $getConfig 'ReplicationWarningThresholdHours'
        $value | Should -Be 24
    }

    It 'returns HealthyDCThreshold default of 7' {
        $value = & $getConfig 'HealthyDCThreshold'
        $value | Should -Be 7
    }

    It 'returns BackupIntegration as null by default' {
        $value = & $getConfig 'BackupIntegration'
        $value | Should -BeNullOrEmpty
    }

    It 'returns null for a nonexistent key without throwing' {
        $value = & $getConfig 'CompletelyFakeKey'
        $value | Should -BeNullOrEmpty
    }
}

Describe 'Config: File Override' {

    BeforeAll {
        # Create a temporary config file that overrides one key.
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "MonarchTest_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        # Write a minimal config that overrides DormancyThresholdDays.
        $tempConfig = Join-Path $tempDir 'Monarch-Config.psd1'
        '@{ DormancyThresholdDays = 120 }' | Set-Content -Path $tempConfig

        # Copy the module to the temp dir so it finds the config file next to it.
        Copy-Item (Join-Path $PSScriptRoot '..' 'Monarch.psm1') $tempDir

        # Re-import from the temp dir.
        if (Get-Module -Name 'Monarch')
        { Remove-Module -Name 'Monarch' -Force
        }
        Import-Module (Join-Path $tempDir 'Monarch.psm1') -Force

        $getConfig = { param($Key) & (Get-Module Monarch) { Get-MonarchConfigValue -Key $args[0] } $Key }
    }

    AfterAll {
        # Restore the original module.
        if (Get-Module -Name 'Monarch')
        { Remove-Module -Name 'Monarch' -Force
        }
        Import-Module (Join-Path $PSScriptRoot '..' 'Monarch.psm1') -Force

        # Clean up temp dir.
        if (Test-Path $tempDir)
        { Remove-Item $tempDir -Recurse -Force
        }
    }

    It 'overrides DormancyThresholdDays from config file' {
        $value = & $getConfig 'DormancyThresholdDays'
        $value | Should -Be 120
    }

    It 'preserves defaults for keys not in the config file' {
        $value = & $getConfig 'NeverLoggedOnGraceDays'
        $value | Should -Be 60
    }
}

# =============================================================================
# Step 3: Target Resolution
# =============================================================================

Describe 'Resolve-MonarchDC' {

    BeforeAll {
        # Define stub functions in the module scope for AD cmdlets and OctoDoc
        # commands that don't exist in the test environment. Pester can only
        # mock commands that are defined somewhere.
        & (Get-Module Monarch) {
            if (-not (Get-Command 'Get-ADDomain' -ErrorAction SilentlyContinue))
            {
                function script:Get-ADDomain
                { 
                }
            }
            if (-not (Get-Command 'Get-ADDomainController' -ErrorAction SilentlyContinue))
            {
                function script:Get-ADDomainController
                { 
                }
            }
            if (-not (Get-Command 'Get-HealthyDC' -ErrorAction SilentlyContinue))
            {
                function script:Get-HealthyDC
                { 
                }
            }
        }

        $resolveDC = { param($Domain)
            & (Get-Module Monarch) {
                param($d)
                if ($d)
                { Resolve-MonarchDC -Domain $d 
                } else
                { Resolve-MonarchDC 
                }
            } $Domain
        }
    }

    Context 'when OctoDoc is available' {

        BeforeAll {
            Mock -ModuleName Monarch Get-Command {
                [PSCustomObject]@{ Name = 'Get-HealthyDC' }
            } -ParameterFilter { $Name -eq 'Get-HealthyDC' }

            Mock -ModuleName Monarch Get-HealthyDC {
                [PSCustomObject]@{
                    DCName      = 'DC01.contoso.com'
                    HealthScore = 9
                }
            }

            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{ DNSRoot = 'contoso.com' }
            }
        }

        It 'returns HealthyDC source when OctoDoc succeeds' {
            $result = & $resolveDC 'contoso.com'
            $result.Source | Should -Be 'HealthyDC'
            $result.DCName | Should -Be 'DC01.contoso.com'
            $result.Domain | Should -Be 'contoso.com'
        }
    }

    Context 'when OctoDoc is unavailable' {

        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $null } -ParameterFilter { $Name -eq 'Get-HealthyDC' }

            Mock -ModuleName Monarch Get-ADDomainController {
                [PSCustomObject]@{ HostName = 'DC02.contoso.com' }
            }

            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{ DNSRoot = 'contoso.com' }
            }
        }

        It 'falls back to Discovered source' {
            $result = & $resolveDC 'contoso.com'
            $result.Source | Should -Be 'Discovered'
            $result.DCName | Should -Be 'DC02.contoso.com'
        }
    }

    Context 'when OctoDoc throws' {

        BeforeAll {
            Mock -ModuleName Monarch Get-Command {
                [PSCustomObject]@{ Name = 'Get-HealthyDC' }
            } -ParameterFilter { $Name -eq 'Get-HealthyDC' }

            Mock -ModuleName Monarch Get-HealthyDC { throw 'OctoDoc error' }

            Mock -ModuleName Monarch Get-ADDomainController {
                [PSCustomObject]@{ HostName = 'DC03.contoso.com' }
            }

            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{ DNSRoot = 'contoso.com' }
            }
        }

        It 'falls back to Discovered source on OctoDoc failure' {
            $result = & $resolveDC 'contoso.com'
            $result.Source | Should -Be 'Discovered'
            $result.DCName | Should -Be 'DC03.contoso.com'
        }
    }

    Context 'with no domain specified' {

        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $null } -ParameterFilter { $Name -eq 'Get-HealthyDC' }

            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{ DNSRoot = 'auto.local' }
            }

            Mock -ModuleName Monarch Get-ADDomainController {
                [PSCustomObject]@{ HostName = 'DC-AUTO.auto.local' }
            }
        }

        It 'uses current domain from Get-ADDomain' {
            $result = & $resolveDC $null
            $result.Domain | Should -Be 'auto.local'
        }
    }

    Context 'return shape' {

        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $null } -ParameterFilter { $Name -eq 'Get-HealthyDC' }

            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{ DNSRoot = 'shape.test' }
            }

            Mock -ModuleName Monarch Get-ADDomainController {
                [PSCustomObject]@{ HostName = 'DC-SHAPE.shape.test' }
            }
        }

        It 'has DCName, Domain, and Source properties' {
            $result = & $resolveDC 'shape.test'
            $result.PSObject.Properties.Name | Should -Contain 'DCName'
            $result.PSObject.Properties.Name | Should -Contain 'Domain'
            $result.PSObject.Properties.Name | Should -Contain 'Source'
        }
    }
}

# =============================================================================
# Step 4: New-DomainBaseline
# Tests added in Step 4 implementation.
# =============================================================================

# =============================================================================
# Step 5: Infrastructure Health
# Tests added in Step 5 implementation.
# =============================================================================

# =============================================================================
# Step 6: Security Posture
# Tests added in Step 6 implementation.
# =============================================================================

# =============================================================================
# Step 7: Privileged Access
# Tests added in Step 7 implementation.
# =============================================================================

# =============================================================================
# Step 8: Find-DormantAccount
# Tests added in Step 8 implementation.
# =============================================================================

# =============================================================================
# Step 9: Export-GPOAudit
# Tests added in Step 9 implementation.
# =============================================================================

# =============================================================================
# Step 10: Backup & Recovery
# Tests added in Step 10 implementation.
# =============================================================================

# =============================================================================
# Step 11: DNS
# Tests added in Step 11 implementation.
# =============================================================================

# =============================================================================
# Step 12: Audit & Compliance
# Tests added in Step 12 implementation.
# =============================================================================

# =============================================================================
# Step 13: Reporting
# Tests added in Step 13 implementation.
# =============================================================================

# =============================================================================
# Step 14: Orchestrator
# Tests added in Step 14 implementation.
# =============================================================================

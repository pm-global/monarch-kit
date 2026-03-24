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
# =============================================================================

Describe 'New-DomainBaseline' {

    BeforeAll {
        # Define AD cmdlet stubs inside the module scope so Pester can mock them.
        # Parameters declared so splatted args bind correctly for mock assertions.
        & (Get-Module Monarch) {
            function script:Get-ADDomain
            { param([string]$Server)
            }
            function script:Get-ADForest
            { param([string]$Server)
            }
            function script:Get-ADObject
            { param([string]$Identity, [string[]]$Properties, [string]$Server)
            }
            function script:Get-ADDomainController
            { param([string]$Filter, [string]$Server)
            }
            function script:Get-ADReplicationSite
            { param([string]$Filter, [string]$Server)
            }
            function script:Get-ADOrganizationalUnit
            { param([string]$Filter, [string]$Server)
            }
            function script:Get-ADUser
            { param([string]$Filter, [string]$Server)
            }
            function script:Get-ADComputer
            { param([string]$Filter, [string]$Server)
            }
            function script:Get-ADGroup
            { param([string]$Filter, [string]$Server)
            }
            function script:Get-ADDefaultDomainPasswordPolicy
            { param([string]$Server)
            }
        }
    }

    Context 'when all sections succeed' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{
                    DNSRoot              = 'test.local'
                    NetBIOSName          = 'TEST'
                    DomainMode           = 'Windows2016Domain'
                    PDCEmulator          = 'DC01.test.local'
                    RIDMaster            = 'DC01.test.local'
                    InfrastructureMaster = 'DC01.test.local'
                    DistinguishedName    = 'DC=test,DC=local'
                }
            }

            Mock -ModuleName Monarch Get-ADForest {
                [PSCustomObject]@{
                    Name               = 'test.local'
                    ForestMode         = 'Windows2016Forest'
                    SchemaMaster       = 'DC01.test.local'
                    DomainNamingMaster = 'DC01.test.local'
                }
            }

            Mock -ModuleName Monarch Get-ADObject {
                [PSCustomObject]@{ objectVersion = 88 }
            }

            Mock -ModuleName Monarch Get-ADDomainController {
                @(
                    [PSCustomObject]@{
                        HostName          = 'DC01.test.local'
                        Site              = 'Default-First-Site-Name'
                        OperatingSystem   = 'Windows Server 2019'
                        IPv4Address       = '10.0.0.1'
                        IsGlobalCatalog   = $true
                        IsReadOnly        = $false
                    }
                )
            }

            Mock -ModuleName Monarch Get-ADReplicationSite {
                @(
                    [PSCustomObject]@{ Name = 'Default-First-Site-Name' },
                    [PSCustomObject]@{ Name = 'Branch-Site' }
                )
            }

            Mock -ModuleName Monarch Get-ADOrganizationalUnit {
                @(
                    [PSCustomObject]@{ Name = 'Users' },
                    [PSCustomObject]@{ Name = 'Computers' },
                    [PSCustomObject]@{ Name = 'Servers' }
                )
            }

            Mock -ModuleName Monarch Get-ADUser {
                @(
                    [PSCustomObject]@{ SamAccountName = 'user1'; Enabled = $true },
                    [PSCustomObject]@{ SamAccountName = 'user2'; Enabled = $true },
                    [PSCustomObject]@{ SamAccountName = 'user3'; Enabled = $false }
                )
            }

            Mock -ModuleName Monarch Get-ADComputer {
                @(
                    [PSCustomObject]@{ Name = 'PC01'; Enabled = $true },
                    [PSCustomObject]@{ Name = 'PC02'; Enabled = $false }
                )
            }

            Mock -ModuleName Monarch Get-ADGroup {
                @(
                    [PSCustomObject]@{ Name = 'Domain Admins' },
                    [PSCustomObject]@{ Name = 'Domain Users' }
                )
            }

            Mock -ModuleName Monarch Get-ADDefaultDomainPasswordPolicy {
                [PSCustomObject]@{
                    MinPasswordLength    = 12
                    PasswordHistoryCount = 24
                    MaxPasswordAge       = New-TimeSpan -Days 90
                    MinPasswordAge       = New-TimeSpan -Days 1
                    LockoutThreshold     = 5
                    LockoutDuration      = New-TimeSpan -Minutes 30
                    ComplexityEnabled    = $true
                }
            }

            $script:baseline = New-DomainBaseline -Server 'DC01.test.local'
        }

        It 'returns an object with all required properties' {
            $requiredProps = @(
                'Domain', 'Function', 'Timestamp', 'Server',
                'DomainDNSRoot', 'DomainNetBIOS', 'DomainFunctionalLevel',
                'ForestName', 'ForestFunctionalLevel', 'SchemaVersion',
                'DomainControllers', 'FSMORoles', 'SiteCount', 'OUCount',
                'UserCount', 'ComputerCount', 'GroupCount',
                'PasswordPolicy', 'OutputFiles', 'Warnings'
            )
            foreach ($prop in $requiredProps)
            {
                $baseline.PSObject.Properties.Name | Should -Contain $prop
            }
        }

        It 'sets Domain to AuditCompliance' {
            $baseline.Domain | Should -Be 'AuditCompliance'
        }

        It 'sets Function to New-DomainBaseline' {
            $baseline.Function | Should -Be 'New-DomainBaseline'
        }

        It 'sets Timestamp within 60 seconds of now' {
            $baseline.Timestamp | Should -Not -BeNullOrEmpty
            ((Get-Date) - $baseline.Timestamp).TotalSeconds | Should -BeLessThan 60
        }

        It 'returns zero warnings when all sections succeed' {
            @($baseline.Warnings).Count | Should -Be 0
        }

        It 'returns DomainControllers as an array with correct sub-properties' {
            @($baseline.DomainControllers).Count | Should -BeGreaterThan 0
            $dc = $baseline.DomainControllers[0]
            $dc.PSObject.Properties.Name | Should -Contain 'HostName'
            $dc.PSObject.Properties.Name | Should -Contain 'Site'
            $dc.PSObject.Properties.Name | Should -Contain 'OS'
            $dc.PSObject.Properties.Name | Should -Contain 'IPv4'
            $dc.PSObject.Properties.Name | Should -Contain 'IsGC'
            $dc.PSObject.Properties.Name | Should -Contain 'IsRODC'
        }

        It 'returns FSMORoles with all five role properties' {
            $roles = $baseline.FSMORoles
            $roles.PSObject.Properties.Name | Should -Contain 'SchemaMaster'
            $roles.PSObject.Properties.Name | Should -Contain 'DomainNaming'
            $roles.PSObject.Properties.Name | Should -Contain 'PDCEmulator'
            $roles.PSObject.Properties.Name | Should -Contain 'RIDMaster'
            $roles.PSObject.Properties.Name | Should -Contain 'Infrastructure'
        }

        It 'returns UserCount and ComputerCount with Total and Enabled' {
            $baseline.UserCount.Total | Should -Be 3
            $baseline.UserCount.Enabled | Should -Be 2
            $baseline.ComputerCount.Total | Should -Be 2
            $baseline.ComputerCount.Enabled | Should -Be 1
        }

        It 'populates correct values from mock data' {
            $baseline.Server | Should -Be 'DC01.test.local'
            $baseline.DomainDNSRoot | Should -Be 'test.local'
            $baseline.DomainNetBIOS | Should -Be 'TEST'
            $baseline.DomainFunctionalLevel | Should -Be 'Windows2016Domain'
            $baseline.ForestName | Should -Be 'test.local'
            $baseline.ForestFunctionalLevel | Should -Be 'Windows2016Forest'
            $baseline.SchemaVersion | Should -Be 88
            $baseline.SiteCount | Should -Be 2
            $baseline.OUCount | Should -Be 3
            $baseline.GroupCount | Should -Be 2
        }

        It 'records the Server value passed in' {
            $baseline.Server | Should -Be 'DC01.test.local'
        }

        It 'returns empty OutputFiles when OutputPath not provided' {
            @($baseline.OutputFiles).Count | Should -Be 0
        }
    }

    Context 'when Domain/Forest section fails' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain { throw 'DC unreachable' }
            Mock -ModuleName Monarch Get-ADForest { throw 'DC unreachable' }
            Mock -ModuleName Monarch Get-ADObject { [PSCustomObject]@{ objectVersion = 88 } }
            Mock -ModuleName Monarch Get-ADDomainController {
                @([PSCustomObject]@{
                        HostName = 'DC01'; Site = 'Site1'; OperatingSystem = 'WS2019'
                        IPv4Address = '10.0.0.1'; IsGlobalCatalog = $true; IsReadOnly = $false
                    })
            }
            Mock -ModuleName Monarch Get-ADReplicationSite { @([PSCustomObject]@{ Name = 'Site1' }) }
            Mock -ModuleName Monarch Get-ADOrganizationalUnit { @([PSCustomObject]@{ Name = 'Users' }) }
            Mock -ModuleName Monarch Get-ADUser { @([PSCustomObject]@{ Enabled = $true }) }
            Mock -ModuleName Monarch Get-ADComputer { @([PSCustomObject]@{ Enabled = $true }) }
            Mock -ModuleName Monarch Get-ADGroup { @([PSCustomObject]@{ Name = 'G1' }) }
            Mock -ModuleName Monarch Get-ADDefaultDomainPasswordPolicy { [PSCustomObject]@{ MinPasswordLength = 12 } }

            $script:result = New-DomainBaseline
        }

        It 'returns null for domain properties but populates DomainControllers' {
            $result.DomainDNSRoot | Should -BeNullOrEmpty
            $result.DomainControllers | Should -Not -BeNullOrEmpty
        }

        It 'cascades to FSMO gracefully with a warning' {
            $result.FSMORoles | Should -BeNullOrEmpty
            $result.Warnings | Should -Contain 'FSMORoles: skipped — Domain/Forest data unavailable.'
        }

        It 'includes the DomainForest error in Warnings' {
            ($result.Warnings | Where-Object { $_ -match 'DomainForest:' }) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'when DC query fails' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{
                    DNSRoot = 'test.local'; NetBIOSName = 'TEST'; DomainMode = 'Windows2016Domain'
                    PDCEmulator = 'DC01'; RIDMaster = 'DC01'; InfrastructureMaster = 'DC01'
                    DistinguishedName = 'DC=test,DC=local'
                }
            }
            Mock -ModuleName Monarch Get-ADForest {
                [PSCustomObject]@{ Name = 'test.local'; ForestMode = 'Windows2016Forest'; SchemaMaster = 'DC01'; DomainNamingMaster = 'DC01' }
            }
            Mock -ModuleName Monarch Get-ADObject { [PSCustomObject]@{ objectVersion = 88 } }
            Mock -ModuleName Monarch Get-ADDomainController { throw 'RPC unavailable' }
            Mock -ModuleName Monarch Get-ADReplicationSite { @([PSCustomObject]@{ Name = 'Site1' }) }
            Mock -ModuleName Monarch Get-ADOrganizationalUnit { @([PSCustomObject]@{ Name = 'Users' }) }
            Mock -ModuleName Monarch Get-ADUser {
                @([PSCustomObject]@{ Enabled = $true }, [PSCustomObject]@{ Enabled = $false })
            }
            Mock -ModuleName Monarch Get-ADComputer { @([PSCustomObject]@{ Enabled = $true }) }
            Mock -ModuleName Monarch Get-ADGroup { @([PSCustomObject]@{ Name = 'G1' }) }
            Mock -ModuleName Monarch Get-ADDefaultDomainPasswordPolicy { [PSCustomObject]@{ MinPasswordLength = 12 } }

            $script:result = New-DomainBaseline
        }

        It 'returns null DomainControllers but populates UserCount' {
            $result.DomainControllers | Should -BeNullOrEmpty
            $result.UserCount.Total | Should -Be 2
            $result.UserCount.Enabled | Should -Be 1
        }

        It 'includes the DomainControllers error in Warnings' {
            ($result.Warnings | Where-Object { $_ -match 'DomainControllers:' }) | Should -Not -BeNullOrEmpty
        }
    }

    Context 'when multiple sections fail' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain { throw 'fail 1' }
            Mock -ModuleName Monarch Get-ADForest { throw 'fail 1b' }
            Mock -ModuleName Monarch Get-ADObject { throw 'fail 2' }
            Mock -ModuleName Monarch Get-ADDomainController { throw 'fail 3' }
            Mock -ModuleName Monarch Get-ADReplicationSite { @([PSCustomObject]@{ Name = 'Site1' }) }
            Mock -ModuleName Monarch Get-ADOrganizationalUnit { @([PSCustomObject]@{ Name = 'OU1' }) }
            Mock -ModuleName Monarch Get-ADUser { @([PSCustomObject]@{ Enabled = $true }) }
            Mock -ModuleName Monarch Get-ADComputer { @([PSCustomObject]@{ Enabled = $true }) }
            Mock -ModuleName Monarch Get-ADGroup { @([PSCustomObject]@{ Name = 'G1' }) }
            Mock -ModuleName Monarch Get-ADDefaultDomainPasswordPolicy { [PSCustomObject]@{ MinPasswordLength = 12 } }

            $script:result = New-DomainBaseline
        }

        It 'accumulates warnings from all failed sections' {
            # DomainForest + SchemaVersion + FSMORoles (cascade) + DomainControllers = 4
            $result.Warnings.Count | Should -BeGreaterOrEqual 4
        }

        It 'still populates surviving sections' {
            $result.SiteCount | Should -Be 1
            $result.OUCount | Should -Be 1
            $result.UserCount.Total | Should -Be 1
            $result.GroupCount | Should -Be 1
        }
    }

    Context 'when all sections fail' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain { throw 'fail' }
            Mock -ModuleName Monarch Get-ADForest { throw 'fail' }
            Mock -ModuleName Monarch Get-ADObject { throw 'fail' }
            Mock -ModuleName Monarch Get-ADDomainController { throw 'fail' }
            Mock -ModuleName Monarch Get-ADReplicationSite { throw 'fail' }
            Mock -ModuleName Monarch Get-ADOrganizationalUnit { throw 'fail' }
            Mock -ModuleName Monarch Get-ADUser { throw 'fail' }
            Mock -ModuleName Monarch Get-ADComputer { throw 'fail' }
            Mock -ModuleName Monarch Get-ADGroup { throw 'fail' }
            Mock -ModuleName Monarch Get-ADDefaultDomainPasswordPolicy { throw 'fail' }

            $script:result = New-DomainBaseline
        }

        It 'still returns the contract shape with Domain, Function, and Timestamp' {
            $result.Domain | Should -Be 'AuditCompliance'
            $result.Function | Should -Be 'New-DomainBaseline'
            $result.Timestamp | Should -Not -BeNullOrEmpty
        }

        It 'returns Warnings as a populated array' {
            $result.Warnings | Should -Not -BeNullOrEmpty
            $result.Warnings.Count | Should -BeGreaterOrEqual 5
        }
    }

    Context 'CSV export with OutputPath' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{
                    DNSRoot = 'csv.local'; NetBIOSName = 'CSV'; DomainMode = 'Windows2016Domain'
                    PDCEmulator = 'DC01'; RIDMaster = 'DC01'; InfrastructureMaster = 'DC01'
                    DistinguishedName = 'DC=csv,DC=local'
                }
            }
            Mock -ModuleName Monarch Get-ADForest {
                [PSCustomObject]@{ Name = 'csv.local'; ForestMode = 'Windows2016Forest'; SchemaMaster = 'DC01'; DomainNamingMaster = 'DC01' }
            }
            Mock -ModuleName Monarch Get-ADObject { [PSCustomObject]@{ objectVersion = 88 } }
            Mock -ModuleName Monarch Get-ADDomainController {
                @([PSCustomObject]@{
                        HostName = 'DC01'; Site = 'Site1'; OperatingSystem = 'WS2019'
                        IPv4Address = '10.0.0.1'; IsGlobalCatalog = $true; IsReadOnly = $false
                    })
            }
            Mock -ModuleName Monarch Get-ADReplicationSite { @([PSCustomObject]@{ Name = 'Site1' }) }
            Mock -ModuleName Monarch Get-ADOrganizationalUnit { @([PSCustomObject]@{ Name = 'Users' }) }
            Mock -ModuleName Monarch Get-ADUser { @([PSCustomObject]@{ Enabled = $true }) }
            Mock -ModuleName Monarch Get-ADComputer { @([PSCustomObject]@{ Enabled = $true }) }
            Mock -ModuleName Monarch Get-ADGroup { @([PSCustomObject]@{ Name = 'G1' }) }
            Mock -ModuleName Monarch Get-ADDefaultDomainPasswordPolicy { [PSCustomObject]@{ MinPasswordLength = 12 } }

            $script:csvDir = Join-Path $TestDrive 'baseline-output'
            $script:csvResult = New-DomainBaseline -OutputPath $csvDir
        }

        It 'creates the output directory' {
            Test-Path $csvDir | Should -BeTrue
        }

        It 'writes expected CSV files' {
            Test-Path (Join-Path $csvDir 'domain-info.csv') | Should -BeTrue
            Test-Path (Join-Path $csvDir 'domain-controllers.csv') | Should -BeTrue
            Test-Path (Join-Path $csvDir 'fsmo-roles.csv') | Should -BeTrue
            Test-Path (Join-Path $csvDir 'object-counts.csv') | Should -BeTrue
            Test-Path (Join-Path $csvDir 'password-policy.csv') | Should -BeTrue
        }

        It 'populates OutputFiles with paths to written CSVs' {
            $csvResult.OutputFiles.Count | Should -Be 5
            $csvResult.OutputFiles | ForEach-Object { Test-Path $_ | Should -BeTrue }
        }
    }

    Context 'CSV export without OutputPath' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{
                    DNSRoot = 'no.local'; NetBIOSName = 'NO'; DomainMode = 'Windows2016Domain'
                    PDCEmulator = 'DC01'; RIDMaster = 'DC01'; InfrastructureMaster = 'DC01'
                    DistinguishedName = 'DC=no,DC=local'
                }
            }
            Mock -ModuleName Monarch Get-ADForest {
                [PSCustomObject]@{ Name = 'no.local'; ForestMode = 'Windows2016Forest'; SchemaMaster = 'DC01'; DomainNamingMaster = 'DC01' }
            }
            Mock -ModuleName Monarch Get-ADObject { [PSCustomObject]@{ objectVersion = 88 } }
            Mock -ModuleName Monarch Get-ADDomainController { @() }
            Mock -ModuleName Monarch Get-ADReplicationSite { @() }
            Mock -ModuleName Monarch Get-ADOrganizationalUnit { @() }
            Mock -ModuleName Monarch Get-ADUser { @() }
            Mock -ModuleName Monarch Get-ADComputer { @() }
            Mock -ModuleName Monarch Get-ADGroup { @() }
            Mock -ModuleName Monarch Get-ADDefaultDomainPasswordPolicy { [PSCustomObject]@{ MinPasswordLength = 12 } }

            $script:noPathResult = New-DomainBaseline
        }

        It 'returns empty OutputFiles' {
            @($noPathResult.OutputFiles).Count | Should -Be 0
        }
    }

    Context 'CSV export with partial section failure' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain { throw 'fail' }
            Mock -ModuleName Monarch Get-ADForest { throw 'fail' }
            Mock -ModuleName Monarch Get-ADObject { throw 'fail' }
            Mock -ModuleName Monarch Get-ADDomainController {
                @([PSCustomObject]@{
                        HostName = 'DC01'; Site = 'Site1'; OperatingSystem = 'WS2019'
                        IPv4Address = '10.0.0.1'; IsGlobalCatalog = $true; IsReadOnly = $false
                    })
            }
            Mock -ModuleName Monarch Get-ADReplicationSite { @([PSCustomObject]@{ Name = 'Site1' }) }
            Mock -ModuleName Monarch Get-ADOrganizationalUnit { @([PSCustomObject]@{ Name = 'Users' }) }
            Mock -ModuleName Monarch Get-ADUser { @([PSCustomObject]@{ Enabled = $true }) }
            Mock -ModuleName Monarch Get-ADComputer { @([PSCustomObject]@{ Enabled = $true }) }
            Mock -ModuleName Monarch Get-ADGroup { @([PSCustomObject]@{ Name = 'G1' }) }
            Mock -ModuleName Monarch Get-ADDefaultDomainPasswordPolicy { [PSCustomObject]@{ MinPasswordLength = 12 } }

            $script:partialDir = Join-Path $TestDrive 'partial-output'
            $script:partialResult = New-DomainBaseline -OutputPath $partialDir
        }

        It 'writes CSVs for successful sections only' {
            Test-Path (Join-Path $partialDir 'domain-controllers.csv') | Should -BeTrue
            Test-Path (Join-Path $partialDir 'object-counts.csv') | Should -BeTrue
            Test-Path (Join-Path $partialDir 'password-policy.csv') | Should -BeTrue
        }

        It 'does not write CSVs for failed sections' {
            Test-Path (Join-Path $partialDir 'domain-info.csv') | Should -BeFalse
            Test-Path (Join-Path $partialDir 'fsmo-roles.csv') | Should -BeFalse
        }

        It 'only lists written files in OutputFiles' {
            $partialResult.OutputFiles | ForEach-Object { Test-Path $_ | Should -BeTrue }
            ($partialResult.OutputFiles | Where-Object { $_ -match 'domain-info' }) | Should -BeNullOrEmpty
            ($partialResult.OutputFiles | Where-Object { $_ -match 'fsmo-roles' }) | Should -BeNullOrEmpty
        }
    }
}

# =============================================================================
# Step 5: Infrastructure Health
# =============================================================================

Describe 'Get-ForestDomainLevel' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADDomain
            { param([string]$Server)
            }
            function script:Get-ADForest
            { param([string]$Server)
            }
            function script:Get-ADObject
            { param([string]$Identity, [string[]]$Properties, [string]$Server)
            }
        }
    }

    Context 'when all sections succeed' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{
                    DNSRoot           = 'test.local'
                    DomainMode        = 'Windows2016Domain'
                    DistinguishedName = 'DC=test,DC=local'
                }
            }

            Mock -ModuleName Monarch Get-ADForest {
                [PSCustomObject]@{
                    Name       = 'test.local'
                    ForestMode = 'Windows2016Forest'
                }
            }

            Mock -ModuleName Monarch Get-ADObject {
                [PSCustomObject]@{ objectVersion = 88 }
            }

            $script:result = Get-ForestDomainLevel -Server 'DC01.test.local'
        }

        It 'returns correct shape and metadata' {
            $result.Domain   | Should -Be 'InfrastructureHealth'
            $result.Function | Should -Be 'Get-ForestDomainLevel'
            $result.Timestamp | Should -BeOfType [datetime]
            $result.Warnings | Should -HaveCount 0
            $result.PSObject.Properties.Name | Should -Contain 'DomainFunctionalLevel'
            $result.PSObject.Properties.Name | Should -Contain 'ForestFunctionalLevel'
            $result.PSObject.Properties.Name | Should -Contain 'SchemaVersion'
            $result.PSObject.Properties.Name | Should -Contain 'DomainDNSRoot'
            $result.PSObject.Properties.Name | Should -Contain 'ForestName'
        }

        It 'populates schema version from AD object' {
            $result.SchemaVersion         | Should -Be 88
            $result.DomainFunctionalLevel | Should -Be 'Windows2016Domain'
            $result.ForestFunctionalLevel | Should -Be 'Windows2016Forest'
            $result.DomainDNSRoot         | Should -Be 'test.local'
            $result.ForestName            | Should -Be 'test.local'
        }
    }

    Context 'when Forest query fails' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{
                    DNSRoot           = 'test.local'
                    DomainMode        = 'Windows2016Domain'
                    DistinguishedName = 'DC=test,DC=local'
                }
            }

            Mock -ModuleName Monarch Get-ADForest { throw 'Forest unreachable' }

            Mock -ModuleName Monarch Get-ADObject {
                [PSCustomObject]@{ objectVersion = 88 }
            }

            $script:result = Get-ForestDomainLevel -Server 'DC01.test.local'
        }

        It 'still populates domain data and warns about forest failure' {
            $result.DomainFunctionalLevel | Should -Be 'Windows2016Domain'
            $result.DomainDNSRoot         | Should -Be 'test.local'
            $result.ForestFunctionalLevel | Should -BeNullOrEmpty
            $result.ForestName            | Should -BeNullOrEmpty
            $result.Warnings | Should -HaveCount 1
            $result.Warnings[0] | Should -BeLike 'Forest:*'
        }
    }
}

Describe 'Get-FSMORolePlacement' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADDomain
            { param([string]$Server)
            }
            function script:Get-ADForest
            { param([string]$Server)
            }
            function script:Get-ADDomainController
            { param([string]$Filter, [string]$Server)
            }
            function script:Test-Connection
            { param($ComputerName, $Count, [switch]$Quiet)
            }
        }
    }

    Context 'when all roles on one DC' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{
                    PDCEmulator          = 'DC01.test.local'
                    RIDMaster            = 'DC01.test.local'
                    InfrastructureMaster = 'DC01.test.local'
                }
            }

            Mock -ModuleName Monarch Get-ADForest {
                [PSCustomObject]@{
                    SchemaMaster       = 'DC01.test.local'
                    DomainNamingMaster = 'DC01.test.local'
                }
            }

            Mock -ModuleName Monarch Get-ADDomainController {
                @(
                    [PSCustomObject]@{
                        HostName = 'DC01.test.local'
                        Site     = 'Default-First-Site-Name'
                    }
                )
            }

            Mock -ModuleName Monarch Test-Connection { $true }

            $script:result = Get-FSMORolePlacement -Server 'DC01.test.local'
        }

        It 'returns 5 roles with correct shape' {
            $result.Domain   | Should -Be 'InfrastructureHealth'
            $result.Function | Should -Be 'Get-FSMORolePlacement'
            $result.Timestamp | Should -BeOfType [datetime]
            $result.Roles | Should -HaveCount 5
            $result.Roles[0].PSObject.Properties.Name | Should -Contain 'Role'
            $result.Roles[0].PSObject.Properties.Name | Should -Contain 'Holder'
            $result.Roles[0].PSObject.Properties.Name | Should -Contain 'Reachable'
            $result.Roles[0].PSObject.Properties.Name | Should -Contain 'Site'
        }

        It 'reports AllOnOneDC = true' {
            $result.AllOnOneDC       | Should -BeTrue
            $result.UnreachableCount | Should -Be 0
        }

        It 'populates site from DC lookup' {
            $result.Roles | ForEach-Object { $_.Site | Should -Be 'Default-First-Site-Name' }
        }
    }

    Context 'when roles distributed across DCs with one unreachable' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain {
                [PSCustomObject]@{
                    PDCEmulator          = 'DC01.test.local'
                    RIDMaster            = 'DC01.test.local'
                    InfrastructureMaster = 'DC01.test.local'
                }
            }

            Mock -ModuleName Monarch Get-ADForest {
                [PSCustomObject]@{
                    SchemaMaster       = 'DC02.test.local'
                    DomainNamingMaster = 'DC02.test.local'
                }
            }

            Mock -ModuleName Monarch Get-ADDomainController {
                @(
                    [PSCustomObject]@{ HostName = 'DC01.test.local'; Site = 'Site-A' },
                    [PSCustomObject]@{ HostName = 'DC02.test.local'; Site = 'Site-B' }
                )
            }

            Mock -ModuleName Monarch Test-Connection { param($ComputerName)
                if ($ComputerName -eq 'DC02.test.local') { $false } else { $true }
            }

            $script:result = Get-FSMORolePlacement -Server 'DC01.test.local'
        }

        It 'reports AllOnOneDC = false with correct unreachable count' {
            $result.AllOnOneDC       | Should -BeFalse
            $result.UnreachableCount | Should -Be 2
            ($result.Roles | Where-Object { $_.Role -eq 'SchemaMaster' }).Reachable | Should -BeFalse
            ($result.Roles | Where-Object { $_.Role -eq 'PDCEmulator' }).Reachable | Should -BeTrue
        }
    }

    Context 'when Domain/Forest query fails' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomain { throw 'AD unreachable' }
            Mock -ModuleName Monarch Get-ADForest { throw 'AD unreachable' }
            Mock -ModuleName Monarch Get-ADDomainController { @() }
            Mock -ModuleName Monarch Test-Connection { $true }

            $script:result = Get-FSMORolePlacement -Server 'DC01.test.local'
        }

        It 'returns contract shape with empty roles and warning' {
            $result.Domain   | Should -Be 'InfrastructureHealth'
            $result.Function | Should -Be 'Get-FSMORolePlacement'
            $result.Roles    | Should -HaveCount 0
            $result.AllOnOneDC | Should -BeNullOrEmpty
            $result.Warnings | Should -Not -HaveCount 0
            $result.Warnings[0] | Should -BeLike 'DomainForest:*'
        }
    }
}

Describe 'Get-SiteTopology' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADReplicationSite
            { param([string]$Filter, [string]$Server)
            }
            function script:Get-ADReplicationSubnet
            { param([string]$Filter, [string]$Server)
            }
            function script:Get-ADDomainController
            { param([string]$Filter, [string]$Server)
            }
        }
    }

    Context 'when all sections succeed' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADReplicationSite {
                @(
                    [PSCustomObject]@{ Name = 'HQ'; DistinguishedName = 'CN=HQ,CN=Sites,CN=Configuration,DC=test,DC=local' },
                    [PSCustomObject]@{ Name = 'Branch'; DistinguishedName = 'CN=Branch,CN=Sites,CN=Configuration,DC=test,DC=local' }
                )
            }

            Mock -ModuleName Monarch Get-ADReplicationSubnet {
                @(
                    [PSCustomObject]@{ Name = '10.0.0.0/24'; Site = 'CN=HQ,CN=Sites,CN=Configuration,DC=test,DC=local' },
                    [PSCustomObject]@{ Name = '10.1.0.0/24'; Site = 'CN=Branch,CN=Sites,CN=Configuration,DC=test,DC=local' },
                    [PSCustomObject]@{ Name = '10.2.0.0/24'; Site = $null }
                )
            }

            Mock -ModuleName Monarch Get-ADDomainController {
                @(
                    [PSCustomObject]@{ HostName = 'DC01.test.local'; Site = 'HQ' }
                )
            }

            $script:result = Get-SiteTopology -Server 'DC01.test.local'
        }

        It 'returns correct shape and metadata' {
            $result.Domain   | Should -Be 'InfrastructureHealth'
            $result.Function | Should -Be 'Get-SiteTopology'
            $result.Timestamp | Should -BeOfType [datetime]
            $result.Warnings | Should -HaveCount 0
            $result.PSObject.Properties.Name | Should -Contain 'Sites'
            $result.PSObject.Properties.Name | Should -Contain 'UnassignedSubnets'
            $result.PSObject.Properties.Name | Should -Contain 'EmptySites'
            $result.PSObject.Properties.Name | Should -Contain 'SiteCount'
            $result.PSObject.Properties.Name | Should -Contain 'SubnetCount'
        }

        It 'detects unassigned subnets' {
            $result.UnassignedSubnets | Should -HaveCount 1
            $result.UnassignedSubnets | Should -Contain '10.2.0.0/24'
        }

        It 'detects empty sites' {
            $result.EmptySites | Should -HaveCount 1
            $result.EmptySites | Should -Contain 'Branch'
            $result.EmptySites | Should -Not -Contain 'HQ'
        }

        It 'returns correct counts and site sub-objects' {
            $result.SiteCount   | Should -Be 2
            $result.SubnetCount | Should -Be 3
            $result.Sites | Should -HaveCount 2
            $hq = $result.Sites | Where-Object { $_.Name -eq 'HQ' }
            $hq.DCCount | Should -Be 1
            $hq.Subnets | Should -Contain '10.0.0.0/24'
        }
    }

    Context 'when subnet query fails' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADReplicationSite {
                @(
                    [PSCustomObject]@{ Name = 'HQ'; DistinguishedName = 'CN=HQ,CN=Sites,CN=Configuration,DC=test,DC=local' }
                )
            }

            Mock -ModuleName Monarch Get-ADReplicationSubnet { throw 'Access denied' }

            Mock -ModuleName Monarch Get-ADDomainController {
                @(
                    [PSCustomObject]@{ HostName = 'DC01.test.local'; Site = 'HQ' }
                )
            }

            $script:result = Get-SiteTopology -Server 'DC01.test.local'
        }

        It 'still populates sites with empty subnets and warns' {
            $result.SiteCount   | Should -Be 1
            $result.SubnetCount | Should -Be 0
            $result.Sites[0].Subnets | Should -HaveCount 0
            $result.UnassignedSubnets | Should -HaveCount 0
            $result.Warnings | Should -HaveCount 1
            $result.Warnings[0] | Should -BeLike 'Subnets:*'
        }
    }
}

Describe 'Get-ReplicationHealth' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADDomainController
            { param([string]$Filter, [string]$Server)
            }
            function script:Get-ADReplicationPartnerMetadata
            { param($Target, [string]$Server)
            }
        }
    }

    Context 'with mixed health states' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomainController {
                @([PSCustomObject]@{ HostName = 'DC01.test.local' })
            }

            Mock -ModuleName Monarch Get-ADReplicationPartnerMetadata {
                @(
                    [PSCustomObject]@{
                        Partner                        = 'DC02.test.local'
                        Partition                      = 'DC=test,DC=local'
                        LastReplicationSuccess          = (Get-Date).AddHours(-2)
                        LastReplicationAttempt          = (Get-Date).AddHours(-2)
                        ConsecutiveReplicationFailures = 0
                    },
                    [PSCustomObject]@{
                        Partner                        = 'DC02.test.local'
                        Partition                      = 'CN=Configuration,DC=test,DC=local'
                        LastReplicationSuccess          = (Get-Date).AddHours(-30)
                        LastReplicationAttempt          = (Get-Date).AddHours(-1)
                        ConsecutiveReplicationFailures = 0
                    },
                    [PSCustomObject]@{
                        Partner                        = 'DC02.test.local'
                        Partition                      = 'DC=DomainDnsZones,DC=test,DC=local'
                        LastReplicationSuccess          = (Get-Date).AddHours(-2)
                        LastReplicationAttempt          = (Get-Date).AddHours(-1)
                        ConsecutiveReplicationFailures = 3
                    }
                )
            }

            $script:result = Get-ReplicationHealth -Server 'DC01.test.local'
        }

        It 'returns correct shape and metadata' {
            $result.Domain   | Should -Be 'InfrastructureHealth'
            $result.Function | Should -Be 'Get-ReplicationHealth'
            $result.Timestamp | Should -BeOfType [datetime]
            $result.PSObject.Properties.Name | Should -Contain 'Links'
            $result.PSObject.Properties.Name | Should -Contain 'HealthyLinkCount'
            $result.PSObject.Properties.Name | Should -Contain 'WarningLinkCount'
            $result.PSObject.Properties.Name | Should -Contain 'FailedLinkCount'
            $result.PSObject.Properties.Name | Should -Contain 'DiagnosticHints'
        }

        It 'classifies healthy link correctly' {
            $domainLink = $result.Links | Where-Object { $_.Partition -eq 'Domain' }
            $domainLink.Status | Should -Be 'Healthy'
        }

        It 'classifies warning link correctly' {
            $configLink = $result.Links | Where-Object { $_.Partition -eq 'Configuration' }
            $configLink.Status | Should -Be 'Warning'
        }

        It 'classifies failed link correctly' {
            $dnsLink = $result.Links | Where-Object { $_.Partition -eq 'DomainDNS' }
            $dnsLink.Status | Should -Be 'Failed'
            $dnsLink.ConsecutiveFailures | Should -Be 3
        }

        It 'returns correct counts' {
            $result.HealthyLinkCount | Should -Be 1
            $result.WarningLinkCount | Should -Be 1
            $result.FailedLinkCount  | Should -Be 1
        }

        It 'generates DiagnosticHints for partial-partition failure' {
            $result.DiagnosticHints | Should -Not -HaveCount 0
            $result.DiagnosticHints[0] | Should -BeLike '*DC01*DC02*healthy*DomainDNS*failed*'
        }
    }

    Context 'with config override changing threshold' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomainController {
                @([PSCustomObject]@{ HostName = 'DC01.test.local' })
            }

            Mock -ModuleName Monarch Get-ADReplicationPartnerMetadata {
                @(
                    [PSCustomObject]@{
                        Partner                        = 'DC02.test.local'
                        Partition                      = 'CN=Configuration,DC=test,DC=local'
                        LastReplicationSuccess          = (Get-Date).AddHours(-30)
                        LastReplicationAttempt          = (Get-Date).AddHours(-1)
                        ConsecutiveReplicationFailures = 0
                    }
                )
            }

            # Override threshold to 48h — 30-hour-old link should now be Healthy
            Mock -ModuleName Monarch Get-MonarchConfigValue { 48 } -ParameterFilter {
                $Key -eq 'ReplicationWarningThresholdHours'
            }

            $script:result = Get-ReplicationHealth -Server 'DC01.test.local'
        }

        It 'respects custom threshold from config' {
            $result.Links[0].Status | Should -Be 'Healthy'
            $result.HealthyLinkCount | Should -Be 1
            $result.WarningLinkCount | Should -Be 0
        }
    }
}

# =============================================================================
# Step 6: Security Posture
# =============================================================================

Describe 'Get-PasswordPolicyInventory' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADDefaultDomainPasswordPolicy
            { param([string]$Server)
            }
            function script:Get-ADFineGrainedPasswordPolicy
            { param([string]$Filter, [string]$Server)
            }
        }
    }

    Context 'when all sections succeed' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDefaultDomainPasswordPolicy {
                [PSCustomObject]@{
                    MinPasswordLength           = 12
                    PasswordHistoryCount        = 24
                    MaxPasswordAge              = New-TimeSpan -Days 90
                    MinPasswordAge              = New-TimeSpan -Days 1
                    LockoutThreshold            = 5
                    LockoutDuration             = New-TimeSpan -Minutes 30
                    ComplexityEnabled           = $true
                    ReversibleEncryptionEnabled = $false
                }
            }

            Mock -ModuleName Monarch Get-ADFineGrainedPasswordPolicy {
                @([PSCustomObject]@{
                    Name             = 'ServiceAccountPSO'
                    Precedence       = 10
                    AppliesTo        = @('CN=SvcAccounts,DC=test,DC=local')
                    MinPasswordLength = 20
                    MaxPasswordAge   = New-TimeSpan -Days 60
                    LockoutThreshold = 0
                })
            }

            $script:result = Get-PasswordPolicyInventory
        }

        It 'returns correct shape and metadata' {
            $result.Domain   | Should -Be 'SecurityPosture'
            $result.Function | Should -Be 'Get-PasswordPolicyInventory'
            $result.Timestamp | Should -BeOfType [datetime]
            $result.PSObject.Properties.Name | Should -Contain 'DefaultPolicy'
            $result.PSObject.Properties.Name | Should -Contain 'FineGrainedPolicies'
            $result.PSObject.Properties.Name | Should -Contain 'Warnings'
            $result.Warnings | Should -HaveCount 0
        }

        It 'populates default policy values from mock' {
            $result.DefaultPolicy.MinLength        | Should -Be 12
            $result.DefaultPolicy.HistoryCount     | Should -Be 24
            $result.DefaultPolicy.MaxAgeDays       | Should -Be 90
            $result.DefaultPolicy.MinAgeDays       | Should -Be 1
            $result.DefaultPolicy.LockoutThreshold | Should -Be 5
            $result.DefaultPolicy.LockoutDurationMin | Should -Be 30
            $result.DefaultPolicy.ComplexityEnabled | Should -BeTrue
            $result.DefaultPolicy.ReversibleEncryption | Should -BeFalse
        }
    }

    Context 'when no fine-grained policies exist' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDefaultDomainPasswordPolicy {
                [PSCustomObject]@{
                    MinPasswordLength           = 8
                    PasswordHistoryCount        = 12
                    MaxPasswordAge              = New-TimeSpan -Days 60
                    MinPasswordAge              = New-TimeSpan -Days 0
                    LockoutThreshold            = 3
                    LockoutDuration             = New-TimeSpan -Minutes 15
                    ComplexityEnabled           = $false
                    ReversibleEncryptionEnabled = $false
                }
            }

            Mock -ModuleName Monarch Get-ADFineGrainedPasswordPolicy { @() }

            $script:result = Get-PasswordPolicyInventory
        }

        It 'returns empty array for FineGrainedPolicies not null' {
            $result.FineGrainedPolicies -is [array] | Should -BeTrue
            @($result.FineGrainedPolicies).Count | Should -Be 0
        }
    }
}

Describe 'Find-WeakAccountFlag' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADUser
            { param([string]$Filter, [string[]]$Properties, [string]$Server)
            }
            function script:Get-ADGroup
            { param([string]$Filter, [string[]]$Properties, [string]$Server)
            }
        }

        $script:domainAdminsDN = 'CN=Domain Admins,CN=Users,DC=test,DC=local'
    }

    Context 'with mixed flag accounts' {

        BeforeAll {
            # user1: has PasswordNeverExpires AND ReversibleEncryption, is Domain Admin
            # user2: has ReversibleEncryption only, not privileged
            # user3: has DESOnly only, not privileged
            $user1 = [PSCustomObject]@{
                SamAccountName = 'user1'
                DisplayName    = 'User One'
                MemberOf       = @($domainAdminsDN)
            }
            $user2 = [PSCustomObject]@{
                SamAccountName = 'user2'
                DisplayName    = 'User Two'
                MemberOf       = @('CN=RegularGroup,DC=test,DC=local')
            }
            $user3 = [PSCustomObject]@{
                SamAccountName = 'user3'
                DisplayName    = 'User Three'
                MemberOf       = @()
            }

            Mock -ModuleName Monarch Get-ADUser -ParameterFilter {
                $Filter -like '*PasswordNeverExpires*'
            } { @($user1) }

            Mock -ModuleName Monarch Get-ADUser -ParameterFilter {
                $Filter -like '*AllowReversiblePasswordEncryption*'
            } { @($user1, $user2) }

            Mock -ModuleName Monarch Get-ADUser -ParameterFilter {
                $Filter -like '*UseDESKeyOnly*'
            } { @($user3) }

            Mock -ModuleName Monarch Get-ADGroup {
                @(
                    [PSCustomObject]@{
                        DistinguishedName = $domainAdminsDN
                        SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-512' }
                    },
                    [PSCustomObject]@{
                        DistinguishedName = 'CN=RegularGroup,DC=test,DC=local'
                        SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-1001' }
                    }
                )
            }

            $script:result = Find-WeakAccountFlag
        }

        It 'creates one finding per flag per user' {
            $result.Findings | Should -HaveCount 4
            @($result.Findings | Where-Object SamAccountName -eq 'user1') | Should -HaveCount 2
            @($result.Findings | Where-Object SamAccountName -eq 'user2') | Should -HaveCount 1
            @($result.Findings | Where-Object SamAccountName -eq 'user3') | Should -HaveCount 1
        }

        It 'sets IsPrivileged correctly from group membership' {
            $result.Findings | Where-Object SamAccountName -eq 'user1' |
                ForEach-Object { $_.IsPrivileged | Should -BeTrue }
            $result.Findings | Where-Object SamAccountName -eq 'user2' |
                ForEach-Object { $_.IsPrivileged | Should -BeFalse }
            $result.Findings | Where-Object SamAccountName -eq 'user3' |
                ForEach-Object { $_.IsPrivileged | Should -BeFalse }
        }

        It 'builds CountByFlag matching findings' {
            $result.CountByFlag['PasswordNeverExpires'] | Should -Be 1
            $result.CountByFlag['ReversibleEncryption'] | Should -Be 2
            $result.CountByFlag['DESOnly'] | Should -Be 1
        }
    }

    Context 'when one flag query fails' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADUser -ParameterFilter {
                $Filter -like '*PasswordNeverExpires*'
            } { throw 'Access denied' }

            Mock -ModuleName Monarch Get-ADUser -ParameterFilter {
                $Filter -like '*AllowReversiblePasswordEncryption*'
            } { @() }

            Mock -ModuleName Monarch Get-ADUser -ParameterFilter {
                $Filter -like '*UseDESKeyOnly*'
            } {
                @([PSCustomObject]@{
                    SamAccountName = 'svc1'
                    DisplayName    = 'Service One'
                    MemberOf       = @()
                })
            }

            Mock -ModuleName Monarch Get-ADGroup { @() }

            $script:result = Find-WeakAccountFlag
        }

        It 'still returns other flags and adds warning' {
            $result.Findings | Should -HaveCount 1
            $result.Findings[0].Flag | Should -Be 'DESOnly'
            $result.Warnings | Should -Not -BeNullOrEmpty
            $result.Warnings[0] | Should -BeLike '*PasswordNeverExpires*'
        }
    }
}

Describe 'Test-ProtectedUsersGap' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADGroup
            { param([string]$Filter, [string[]]$Properties, [string]$Server)
            }
            function script:Get-ADGroupMember
            { param([string]$Identity, [string]$Server)
            }
            function script:Get-ADUser
            { param([string]$Filter, [string]$Identity, [string[]]$Properties, [string]$Server)
            }
        }

        $script:protectedUsersDN = 'CN=Protected Users,CN=Users,DC=test,DC=local'
        $script:domainAdminsDN   = 'CN=Domain Admins,CN=Users,DC=test,DC=local'
        $script:schemaAdminsDN   = 'CN=Schema Admins,CN=Users,DC=test,DC=local'
    }

    Context 'with mixed membership' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADGroup {
                @(
                    [PSCustomObject]@{
                        Name              = 'Protected Users'
                        DistinguishedName = $protectedUsersDN
                        SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-525' }
                    },
                    [PSCustomObject]@{
                        Name              = 'Domain Admins'
                        DistinguishedName = $domainAdminsDN
                        SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-512' }
                    },
                    [PSCustomObject]@{
                        Name              = 'Schema Admins'
                        DistinguishedName = $schemaAdminsDN
                        SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-518' }
                    }
                )
            }

            # Protected Users contains only adminUser
            Mock -ModuleName Monarch Get-ADGroupMember -ParameterFilter {
                $Identity -eq $protectedUsersDN
            } {
                @([PSCustomObject]@{ SamAccountName = 'adminUser' })
            }

            # Domain Admins contains adminUser, gapUser, svcUser
            Mock -ModuleName Monarch Get-ADGroupMember -ParameterFilter {
                $Identity -eq $domainAdminsDN
            } {
                @(
                    [PSCustomObject]@{ SamAccountName = 'adminUser' },
                    [PSCustomObject]@{ SamAccountName = 'gapUser' },
                    [PSCustomObject]@{ SamAccountName = 'svcUser' }
                )
            }

            # Schema Admins contains gapUser
            Mock -ModuleName Monarch Get-ADGroupMember -ParameterFilter {
                $Identity -eq $schemaAdminsDN
            } {
                @([PSCustomObject]@{ SamAccountName = 'gapUser' })
            }

            # User detail: gapUser has no SPN, svcUser has SPN
            Mock -ModuleName Monarch Get-ADUser -ParameterFilter {
                $Identity -eq 'gapUser'
            } {
                [PSCustomObject]@{
                    SamAccountName        = 'gapUser'
                    ServicePrincipalName  = @()
                }
            }

            Mock -ModuleName Monarch Get-ADUser -ParameterFilter {
                $Identity -eq 'svcUser'
            } {
                [PSCustomObject]@{
                    SamAccountName        = 'svcUser'
                    ServicePrincipalName  = @('HTTP/svc.test.local')
                }
            }

            $script:result = Test-ProtectedUsersGap
        }

        It 'identifies gap accounts and protected members correctly' {
            $result.Domain   | Should -Be 'SecurityPosture'
            $result.Function | Should -Be 'Test-ProtectedUsersGap'
            $result.ProtectedUsersMembers | Should -Contain 'adminUser'
            $result.GapAccounts | Should -HaveCount 2
            @($result.GapAccounts | Where-Object SamAccountName -eq 'adminUser') | Should -HaveCount 0
            @($result.GapAccounts | Where-Object SamAccountName -eq 'gapUser') | Should -HaveCount 1
            @($result.GapAccounts | Where-Object SamAccountName -eq 'svcUser') | Should -HaveCount 1
        }

        It 'lists all privileged groups for multi-group accounts' {
            $gap = $result.GapAccounts | Where-Object SamAccountName -eq 'gapUser'
            $gap.PrivilegedGroups | Should -Contain 'Domain Admins'
            $gap.PrivilegedGroups | Should -Contain 'Schema Admins'
        }

        It 'sets HasSPN correctly from user SPN property' {
            ($result.GapAccounts | Where-Object SamAccountName -eq 'svcUser').HasSPN | Should -BeTrue
            ($result.GapAccounts | Where-Object SamAccountName -eq 'gapUser').HasSPN | Should -BeFalse
        }

        It 'generates DiagnosticHint warning about SPN accounts' {
            $result.DiagnosticHint | Should -Not -BeNullOrEmpty
            $result.DiagnosticHint | Should -BeLike '*service account*'
            $result.DiagnosticHint | Should -BeLike '*delegation*'
        }
    }
}

Describe 'Find-LegacyProtocolExposure' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADDomainController
            { param([string]$Filter, [string]$Server)
            }
            function script:Invoke-Command
            { param([string]$ComputerName, [scriptblock]$ScriptBlock)
            }
        }
    }

    Context 'with mixed DC settings' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomainController {
                @(
                    [PSCustomObject]@{ HostName = 'DC01.test.local' },
                    [PSCustomObject]@{ HostName = 'DC02.test.local' }
                )
            }

            # DC01: NTLMv1 vulnerable (level 2), LM hash ok, LDAP signing ok
            Mock -ModuleName Monarch Invoke-Command -ParameterFilter {
                $ComputerName -eq 'DC01.test.local'
            } {
                [PSCustomObject]@{
                    LmCompatibilityLevel = 2
                    NoLMHash             = 1
                    LDAPServerIntegrity  = 2
                }
            }

            # DC02: NTLMv1 ok (level 5), LM hash vulnerable (0), LDAP signing not required (1)
            Mock -ModuleName Monarch Invoke-Command -ParameterFilter {
                $ComputerName -eq 'DC02.test.local'
            } {
                [PSCustomObject]@{
                    LmCompatibilityLevel = 5
                    NoLMHash             = 0
                    LDAPServerIntegrity  = 1
                }
            }

            $script:result = Find-LegacyProtocolExposure
        }

        It 'detects NTLMv1 on vulnerable DC only' {
            $result.Domain   | Should -Be 'SecurityPosture'
            $result.Function | Should -Be 'Find-LegacyProtocolExposure'
            $ntlm = @($result.DCFindings | Where-Object Finding -eq 'NTLMv1Enabled')
            $ntlm | Should -HaveCount 1
            $ntlm[0].DCName | Should -Be 'DC01.test.local'
            $ntlm[0].Risk   | Should -Be 'High'
        }

        It 'detects multiple findings per DC with correct risk levels' {
            $result.DCFindings | Should -HaveCount 3
            $dc02 = @($result.DCFindings | Where-Object DCName -eq 'DC02.test.local')
            $dc02 | Should -HaveCount 2
            ($dc02 | Where-Object Finding -eq 'LMHashStored').Risk | Should -Be 'High'
            ($dc02 | Where-Object Finding -eq 'LDAPSigningDisabled').Risk | Should -Be 'Medium'
        }
    }

    Context 'when DC is unreachable' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomainController {
                @(
                    [PSCustomObject]@{ HostName = 'DC01.test.local' },
                    [PSCustomObject]@{ HostName = 'DC02.test.local' }
                )
            }

            # DC01: all secure
            Mock -ModuleName Monarch Invoke-Command -ParameterFilter {
                $ComputerName -eq 'DC01.test.local'
            } {
                [PSCustomObject]@{
                    LmCompatibilityLevel = 5
                    NoLMHash             = 1
                    LDAPServerIntegrity  = 2
                }
            }

            # DC02: unreachable
            Mock -ModuleName Monarch Invoke-Command -ParameterFilter {
                $ComputerName -eq 'DC02.test.local'
            } { throw 'WinRM connection failed' }

            $script:result = Find-LegacyProtocolExposure
        }

        It 'adds warning for unreachable DC without blocking others' {
            $result.DCFindings | Should -HaveCount 0
            $result.Warnings | Should -Not -BeNullOrEmpty
            $result.Warnings[0] | Should -BeLike '*DC02*'
        }
    }
}

# =============================================================================
# Step 7: Privileged Access
# =============================================================================

Describe 'Get-PrivilegedGroupMembership' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADGroup
            { param([string]$Filter, [string[]]$Properties, [string]$Server)
            }
            function script:Get-ADGroupMember
            { param([string]$Identity, [switch]$Recursive, [string]$Server)
            }
            function script:Get-ADUser
            { param([string]$Filter, [string]$Identity, [string[]]$Properties, [string]$Server)
            }
        }

        $script:domainAdminsDN = 'CN=Domain Admins,CN=Users,DC=test,DC=local'
        $script:schemaAdminsDN = 'CN=Schema Admins,CN=Users,DC=test,DC=local'
    }

    Context 'with domain admins and nested member' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADGroup {
                @(
                    [PSCustomObject]@{
                        Name              = 'Domain Admins'
                        DistinguishedName = $domainAdminsDN
                        SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-512' }
                    },
                    [PSCustomObject]@{
                        Name              = 'Schema Admins'
                        DistinguishedName = $schemaAdminsDN
                        SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-518' }
                    }
                )
            }

            # Domain Admins: direct = 3, recursive = 4 (nestedUser is nested-only)
            Mock -ModuleName Monarch Get-ADGroupMember -ParameterFilter {
                $Identity -eq $domainAdminsDN -and -not $Recursive
            } {
                @(
                    [PSCustomObject]@{ SamAccountName = 'directUser1'; objectClass = 'user' },
                    [PSCustomObject]@{ SamAccountName = 'directUser2'; objectClass = 'user' },
                    [PSCustomObject]@{ SamAccountName = 'directUser3'; objectClass = 'user' }
                )
            }

            Mock -ModuleName Monarch Get-ADGroupMember -ParameterFilter {
                $Identity -eq $domainAdminsDN -and $Recursive
            } {
                @(
                    [PSCustomObject]@{ SamAccountName = 'directUser1'; objectClass = 'user' },
                    [PSCustomObject]@{ SamAccountName = 'directUser2'; objectClass = 'user' },
                    [PSCustomObject]@{ SamAccountName = 'directUser3'; objectClass = 'user' },
                    [PSCustomObject]@{ SamAccountName = 'nestedUser'; objectClass = 'user' }
                )
            }

            # Schema Admins: direct = 1, recursive = 1
            Mock -ModuleName Monarch Get-ADGroupMember -ParameterFilter {
                $Identity -eq $schemaAdminsDN -and -not $Recursive
            } {
                @([PSCustomObject]@{ SamAccountName = 'directUser1'; objectClass = 'user' })
            }

            Mock -ModuleName Monarch Get-ADGroupMember -ParameterFilter {
                $Identity -eq $schemaAdminsDN -and $Recursive
            } {
                @([PSCustomObject]@{ SamAccountName = 'directUser1'; objectClass = 'user' })
            }

            # User details
            Mock -ModuleName Monarch Get-ADUser {
                [PSCustomObject]@{
                    SamAccountName = $Identity
                    DisplayName    = "Display $Identity"
                    Enabled        = $true
                    LastLogonDate  = (Get-Date).AddDays(-5)
                }
            }

            $script:result = Get-PrivilegedGroupMembership
        }

        It 'returns correct shape and metadata' {
            $result.Domain   | Should -Be 'PrivilegedAccess'
            $result.Function | Should -Be 'Get-PrivilegedGroupMembership'
            $result.Timestamp | Should -BeOfType [datetime]
            $result.Groups | Should -HaveCount 2
            $result.Warnings | Should -HaveCount 0
        }

        It 'marks nested member as IsDirect=false' {
            $daGroup = $result.Groups | Where-Object GroupName -eq 'Domain Admins'
            $nested = $daGroup.Members | Where-Object SamAccountName -eq 'nestedUser'
            $nested.IsDirect | Should -BeFalse
        }

        It 'marks direct member as IsDirect=true' {
            $daGroup = $result.Groups | Where-Object GroupName -eq 'Domain Admins'
            $direct = $daGroup.Members | Where-Object SamAccountName -eq 'directUser1'
            $direct.IsDirect | Should -BeTrue
        }

        It 'reports DomainAdminCount=4 with Status=OK' {
            $result.DomainAdminCount  | Should -Be 4
            $result.DomainAdminStatus | Should -Be 'OK'
        }

        It 'reports correct MemberCount per group' {
            ($result.Groups | Where-Object GroupName -eq 'Domain Admins').MemberCount | Should -Be 4
            ($result.Groups | Where-Object GroupName -eq 'Schema Admins').MemberCount | Should -Be 1
        }
    }

    Context 'when DA count triggers warning' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADGroup {
                @([PSCustomObject]@{
                    Name              = 'Domain Admins'
                    DistinguishedName = $domainAdminsDN
                    SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-512' }
                })
            }

            $sevenUsers = @(1..7 | ForEach-Object {
                [PSCustomObject]@{ SamAccountName = "user$_"; objectClass = 'user' }
            })

            Mock -ModuleName Monarch Get-ADGroupMember -ParameterFilter {
                -not $Recursive
            } { $sevenUsers }

            Mock -ModuleName Monarch Get-ADGroupMember -ParameterFilter {
                $Recursive
            } { $sevenUsers }

            Mock -ModuleName Monarch Get-ADUser {
                [PSCustomObject]@{
                    SamAccountName = $Identity
                    DisplayName    = $Identity
                    Enabled        = $true
                    LastLogonDate  = Get-Date
                }
            }

            $script:result = Get-PrivilegedGroupMembership
        }

        It 'reports DomainAdminStatus=Warning for 7 members' {
            $result.DomainAdminCount  | Should -Be 7
            $result.DomainAdminStatus | Should -Be 'Warning'
        }
    }

    Context 'with config override changing thresholds' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADGroup {
                @([PSCustomObject]@{
                    Name              = 'Domain Admins'
                    DistinguishedName = $domainAdminsDN
                    SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-512' }
                })
            }

            $threeUsers = @(1..3 | ForEach-Object {
                [PSCustomObject]@{ SamAccountName = "user$_"; objectClass = 'user' }
            })

            Mock -ModuleName Monarch Get-ADGroupMember -ParameterFilter {
                -not $Recursive
            } { $threeUsers }

            Mock -ModuleName Monarch Get-ADGroupMember -ParameterFilter {
                $Recursive
            } { $threeUsers }

            Mock -ModuleName Monarch Get-ADUser {
                [PSCustomObject]@{
                    SamAccountName = $Identity
                    DisplayName    = $Identity
                    Enabled        = $true
                    LastLogonDate  = Get-Date
                }
            }

            Mock -ModuleName Monarch Get-MonarchConfigValue -ParameterFilter {
                $Key -eq 'DomainAdminWarningThreshold'
            } { 3 }

            Mock -ModuleName Monarch Get-MonarchConfigValue -ParameterFilter {
                $Key -eq 'DomainAdminCriticalThreshold'
            } { 6 }

            $script:result = Get-PrivilegedGroupMembership
        }

        It 'respects custom thresholds from config' {
            $result.DomainAdminCount  | Should -Be 3
            $result.DomainAdminStatus | Should -Be 'Warning'
        }
    }
}

Describe 'Find-AdminCountOrphan' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADGroup
            { param([string]$Filter, [string[]]$Properties, [string]$Server)
            }
            function script:Get-ADUser
            { param([string]$Filter, [string]$Identity, [string[]]$Properties, [string]$Server)
            }
        }

        $script:domainAdminsDN = 'CN=Domain Admins,CN=Users,DC=test,DC=local'
    }

    Context 'with mixed AdminCount users' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADGroup {
                @([PSCustomObject]@{
                    Name              = 'Domain Admins'
                    DistinguishedName = $domainAdminsDN
                    SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-512' }
                })
            }

            Mock -ModuleName Monarch Get-ADUser {
                @(
                    [PSCustomObject]@{
                        SamAccountName = 'orphanUser'
                        DisplayName    = 'Orphan User'
                        Enabled        = $true
                        AdminCount     = 1
                        MemberOf       = @('CN=RegularGroup,DC=test,DC=local')
                    },
                    [PSCustomObject]@{
                        SamAccountName = 'activeAdmin'
                        DisplayName    = 'Active Admin'
                        Enabled        = $true
                        AdminCount     = 1
                        MemberOf       = @($domainAdminsDN)
                    }
                )
            }

            $script:result = Find-AdminCountOrphan
        }

        It 'detects orphan not in any privileged group' {
            @($result.Orphans | Where-Object SamAccountName -eq 'orphanUser') | Should -HaveCount 1
        }

        It 'excludes active admin still in privileged group' {
            @($result.Orphans | Where-Object SamAccountName -eq 'activeAdmin') | Should -HaveCount 0
        }

        It 'Count matches Orphans array length' {
            $result.Count | Should -Be 1
            $result.Orphans | Should -HaveCount $result.Count
        }
    }
}

Describe 'Find-KerberoastableAccount' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADGroup
            { param([string]$Filter, [string[]]$Properties, [string]$Server)
            }
            function script:Get-ADUser
            { param([string]$Filter, [string]$Identity, [string[]]$Properties, [string]$Server)
            }
        }

        $script:domainAdminsDN = 'CN=Domain Admins,CN=Users,DC=test,DC=local'
    }

    Context 'with mixed SPN accounts' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADGroup {
                @([PSCustomObject]@{
                    Name              = 'Domain Admins'
                    DistinguishedName = $domainAdminsDN
                    SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-512' }
                })
            }

            Mock -ModuleName Monarch Get-ADUser {
                @(
                    [PSCustomObject]@{
                        SamAccountName       = 'svcAcct'
                        DisplayName          = 'Service Account'
                        ServicePrincipalName = @('MSSQLSvc/db01.test.local:1433')
                        MemberOf             = @($domainAdminsDN)
                        PasswordLastSet      = (Get-Date).AddDays(-200)
                        Enabled              = $true
                    },
                    [PSCustomObject]@{
                        SamAccountName       = 'appAcct'
                        DisplayName          = 'App Account'
                        ServicePrincipalName = @('HTTP/app.test.local')
                        MemberOf             = @()
                        PasswordLastSet      = (Get-Date).AddDays(-30)
                        Enabled              = $true
                    }
                )
            }

            $script:result = Find-KerberoastableAccount
        }

        It 'includes non-privileged SPN account' {
            $app = $result.Accounts | Where-Object SamAccountName -eq 'appAcct'
            $app | Should -Not -BeNullOrEmpty
            $app.IsPrivileged | Should -BeFalse
        }

        It 'includes privileged SPN account' {
            $svc = $result.Accounts | Where-Object SamAccountName -eq 'svcAcct'
            $svc | Should -Not -BeNullOrEmpty
            $svc.IsPrivileged | Should -BeTrue
        }

        It 'PrivilegedCount counts only privileged entries' {
            $result.PrivilegedCount | Should -Be 1
        }

        It 'TotalCount equals total entries' {
            $result.TotalCount | Should -Be 2
        }
    }
}

Describe 'Find-ASREPRoastableAccount' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADGroup
            { param([string]$Filter, [string[]]$Properties, [string]$Server)
            }
            function script:Get-ADUser
            { param([string]$Filter, [string]$Identity, [string[]]$Properties, [string]$Server)
            }
        }

        $script:domainAdminsDN = 'CN=Domain Admins,CN=Users,DC=test,DC=local'
    }

    Context 'with AS-REP roastable accounts' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADGroup {
                @([PSCustomObject]@{
                    Name              = 'Domain Admins'
                    DistinguishedName = $domainAdminsDN
                    SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-512' }
                })
            }

            Mock -ModuleName Monarch Get-ADUser {
                @(
                    [PSCustomObject]@{
                        SamAccountName = 'asrepUser'
                        DisplayName    = 'ASREP User'
                        MemberOf       = @()
                        Enabled        = $true
                    },
                    [PSCustomObject]@{
                        SamAccountName = 'asrepAdmin'
                        DisplayName    = 'ASREP Admin'
                        MemberOf       = @($domainAdminsDN)
                        Enabled        = $true
                    }
                )
            }

            $script:result = Find-ASREPRoastableAccount
        }

        It 'returns correct shape with all accounts' {
            $result.Domain   | Should -Be 'PrivilegedAccess'
            $result.Function | Should -Be 'Find-ASREPRoastableAccount'
            $result.Accounts | Should -HaveCount 2
        }

        It 'Count matches array and IsPrivileged set correctly' {
            $result.Count | Should -Be 2
            ($result.Accounts | Where-Object SamAccountName -eq 'asrepAdmin').IsPrivileged | Should -BeTrue
            ($result.Accounts | Where-Object SamAccountName -eq 'asrepUser').IsPrivileged | Should -BeFalse
        }
    }
}

# =============================================================================
# Step 8: Find-DormantAccount
# =============================================================================

Describe 'Find-DormantAccount' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADUser
            { param([string]$Filter, [string]$Identity, [string[]]$Properties, [string]$Server)
            }
            function script:Get-ADGroup
            { param([string]$Filter, [string]$Identity, [string[]]$Properties, [string]$Server)
            }
            function script:Get-ADDomainController
            { param([string]$Filter, [string]$Server)
            }
        }

        $script:domainAdminsDN = 'CN=Domain Admins,CN=Users,DC=test,DC=local'
        $script:now = Get-Date
    }

    Context 'with mixed accounts' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADGroup -ParameterFilter { $Filter } {
                @([PSCustomObject]@{
                    Name              = 'Domain Admins'
                    DistinguishedName = $domainAdminsDN
                    SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-512' }
                })
            }

            Mock -ModuleName Monarch Get-ADGroup -ParameterFilter { $Identity } {
                [PSCustomObject]@{ Name = 'Domain Admins' }
            }

            Mock -ModuleName Monarch Get-ADUser {
                @(
                    [PSCustomObject]@{
                        SamAccountName       = 'dormant100'
                        DisplayName          = 'Dormant User'
                        lastLogonTimestamp    = $now.AddDays(-100).ToFileTime()
                        WhenCreated          = $now.AddDays(-200)
                        PasswordLastSet      = $now.AddDays(-50)
                        PasswordNeverExpires = $false
                        ServicePrincipalName = @()
                        MemberOf             = @()
                        objectClass          = 'user'
                        DistinguishedName    = 'CN=dormant100,OU=Users,DC=test,DC=local'
                        Enabled              = $true
                    },
                    [PSCustomObject]@{
                        SamAccountName       = 'recent30'
                        DisplayName          = 'Recent User'
                        lastLogonTimestamp    = $now.AddDays(-30).ToFileTime()
                        WhenCreated          = $now.AddDays(-200)
                        PasswordLastSet      = $now.AddDays(-10)
                        PasswordNeverExpires = $false
                        ServicePrincipalName = @()
                        MemberOf             = @()
                        objectClass          = 'user'
                        DistinguishedName    = 'CN=recent30,OU=Users,DC=test,DC=local'
                        Enabled              = $true
                    },
                    [PSCustomObject]@{
                        SamAccountName       = 'Administrator'
                        DisplayName          = 'Built-in Admin'
                        lastLogonTimestamp    = $now.AddDays(-5).ToFileTime()
                        WhenCreated          = $now.AddDays(-365)
                        PasswordLastSet      = $now.AddDays(-30)
                        PasswordNeverExpires = $false
                        ServicePrincipalName = @()
                        MemberOf             = @()
                        objectClass          = 'user'
                        DistinguishedName    = 'CN=Administrator,CN=Users,DC=test,DC=local'
                        Enabled              = $true
                    },
                    [PSCustomObject]@{
                        SamAccountName       = 'pwdNeverExp'
                        DisplayName          = 'Pwd Never Expires'
                        lastLogonTimestamp    = $now.AddDays(-100).ToFileTime()
                        WhenCreated          = $now.AddDays(-200)
                        PasswordLastSet      = $now.AddDays(-100)
                        PasswordNeverExpires = $true
                        ServicePrincipalName = @()
                        MemberOf             = @()
                        objectClass          = 'user'
                        DistinguishedName    = 'CN=pwdNeverExp,OU=Users,DC=test,DC=local'
                        Enabled              = $true
                    },
                    [PSCustomObject]@{
                        SamAccountName       = 'spnAccount'
                        DisplayName          = 'SPN Account'
                        lastLogonTimestamp    = $now.AddDays(-100).ToFileTime()
                        WhenCreated          = $now.AddDays(-200)
                        PasswordLastSet      = $now.AddDays(-100)
                        PasswordNeverExpires = $false
                        ServicePrincipalName = @('HTTP/web.test.local')
                        MemberOf             = @()
                        objectClass          = 'user'
                        DistinguishedName    = 'CN=spnAccount,OU=Users,DC=test,DC=local'
                        Enabled              = $true
                    },
                    [PSCustomObject]@{
                        SamAccountName       = 'SVC-Backup'
                        DisplayName          = 'Backup Service'
                        lastLogonTimestamp    = $now.AddDays(-100).ToFileTime()
                        WhenCreated          = $now.AddDays(-200)
                        PasswordLastSet      = $now.AddDays(-100)
                        PasswordNeverExpires = $false
                        ServicePrincipalName = @()
                        MemberOf             = @()
                        objectClass          = 'user'
                        DistinguishedName    = 'CN=SVC-Backup,OU=Users,DC=test,DC=local'
                        Enabled              = $true
                    },
                    [PSCustomObject]@{
                        SamAccountName       = 'msaAccount'
                        DisplayName          = 'Managed Service'
                        lastLogonTimestamp    = $now.AddDays(-100).ToFileTime()
                        WhenCreated          = $now.AddDays(-200)
                        PasswordLastSet      = $now.AddDays(-100)
                        PasswordNeverExpires = $false
                        ServicePrincipalName = @()
                        MemberOf             = @()
                        objectClass          = 'msDS-ManagedServiceAccount'
                        DistinguishedName    = 'CN=msaAccount,CN=Managed Service Accounts,DC=test,DC=local'
                        Enabled              = $true
                    },
                    [PSCustomObject]@{
                        SamAccountName       = 'privUser'
                        DisplayName          = 'Privileged User'
                        lastLogonTimestamp    = $now.AddDays(-100).ToFileTime()
                        WhenCreated          = $now.AddDays(-200)
                        PasswordLastSet      = $now.AddDays(-100)
                        PasswordNeverExpires = $false
                        ServicePrincipalName = @()
                        MemberOf             = @($domainAdminsDN)
                        objectClass          = 'user'
                        DistinguishedName    = 'CN=privUser,OU=Users,DC=test,DC=local'
                        Enabled              = $true
                    },
                    [PSCustomObject]@{
                        SamAccountName       = 'neverNew'
                        DisplayName          = 'Never New'
                        lastLogonTimestamp    = $null
                        WhenCreated          = $now.AddDays(-10)
                        PasswordLastSet      = $null
                        PasswordNeverExpires = $false
                        ServicePrincipalName = @()
                        MemberOf             = @()
                        objectClass          = 'user'
                        DistinguishedName    = 'CN=neverNew,OU=Users,DC=test,DC=local'
                        Enabled              = $true
                    },
                    [PSCustomObject]@{
                        SamAccountName       = 'neverOld'
                        DisplayName          = 'Never Old'
                        lastLogonTimestamp    = $null
                        WhenCreated          = $now.AddDays(-90)
                        PasswordLastSet      = $null
                        PasswordNeverExpires = $false
                        ServicePrincipalName = @()
                        MemberOf             = @()
                        objectClass          = 'user'
                        DistinguishedName    = 'CN=neverOld,OU=Users,DC=test,DC=local'
                        Enabled              = $true
                    }
                )
            }

            $script:result = Find-DormantAccount
        }

        It 'includes dormant account with correct DormantReason' {
            $acct = $result.Accounts | Where-Object SamAccountName -eq 'dormant100'
            $acct | Should -Not -BeNullOrEmpty
            $acct.DormantReason | Should -Match 'No logon for'
        }

        It 'excludes account with recent logon' {
            @($result.Accounts | Where-Object SamAccountName -eq 'recent30') | Should -HaveCount 0
        }

        It 'excludes built-in account' {
            @($result.Accounts | Where-Object SamAccountName -eq 'Administrator') | Should -HaveCount 0
        }

        It 'excludes PasswordNeverExpires account' {
            @($result.Accounts | Where-Object SamAccountName -eq 'pwdNeverExp') | Should -HaveCount 0
        }

        It 'excludes SPN account' {
            @($result.Accounts | Where-Object SamAccountName -eq 'spnAccount') | Should -HaveCount 0
        }

        It 'excludes keyword-matching account' {
            @($result.Accounts | Where-Object SamAccountName -eq 'SVC-Backup') | Should -HaveCount 0
        }

        It 'excludes MSA/gMSA object' {
            @($result.Accounts | Where-Object SamAccountName -eq 'msaAccount') | Should -HaveCount 0
        }

        It 'excludes privileged group member' {
            @($result.Accounts | Where-Object SamAccountName -eq 'privUser') | Should -HaveCount 0
        }

        It 'excludes never-logged-on account within grace period' {
            @($result.Accounts | Where-Object SamAccountName -eq 'neverNew') | Should -HaveCount 0
        }

        It 'includes never-logged-on account past grace period' {
            $acct = $result.Accounts | Where-Object SamAccountName -eq 'neverOld'
            $acct | Should -Not -BeNullOrEmpty
            $acct.DormantReason | Should -Match 'Never logged on'
            $acct.DaysSinceLogon | Should -Be -1
        }

        It 'reports correct ExcludedCount' {
            # 10 mock users - 1 MSA (pre-filtered) = 9 queried - 2 included = 7 excluded
            $result.ExcludedCount | Should -Be 7
            $result.TotalCount | Should -Be 2
        }
    }
}

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

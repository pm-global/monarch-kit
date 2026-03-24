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

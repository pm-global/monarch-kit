#Requires -Modules Pester

# Monarch.Tests.ps1
# Pester 5+ tests for the Monarch module.
# All AD/DNS/GPO cmdlets are mocked -- tests run without a domain.
# Organized by Describe blocks per function, added alongside code at each step.

BeforeAll {
    # Import the module from the project root, not from any installed location.
    $modulePath = "$PSScriptRoot\..\Monarch.psm1"
    
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
        $manifestPath = "$PSScriptRoot\..\Monarch.psd1"
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
    	
        $manifestPath = "$PSScriptRoot\..\Monarch.psd1"
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
        $manifestPath = "$PSScriptRoot\..\Monarch.psd1"
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
        Copy-Item ("$PSScriptRoot\..\Monarch.psm1") $tempDir

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
        Import-Module ("$PSScriptRoot\..\Monarch.psm1") -Force

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
            $result.Warnings | Should -Contain 'FSMORoles: skipped -- Domain/Forest data unavailable.'
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
            { param($Target)
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

            # Override threshold to 48h -- 30-hour-old link should now be Healthy
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

    Context 'CSV export with OutputPath' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADGroup -ParameterFilter { $Filter } {
                @([PSCustomObject]@{
                    Name              = 'Domain Admins'
                    DistinguishedName = $domainAdminsDN
                    SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-512' }
                })
            }
            Mock -ModuleName Monarch Get-ADGroup -ParameterFilter { $Identity } {
                [PSCustomObject]@{ Name = 'Some Group' }
            }

            Mock -ModuleName Monarch Get-ADUser {
                @([PSCustomObject]@{
                    SamAccountName       = 'csvUser'
                    DisplayName          = 'CSV User'
                    lastLogonTimestamp    = $now.AddDays(-100).ToFileTime()
                    WhenCreated          = $now.AddDays(-200)
                    PasswordLastSet      = $now.AddDays(-50)
                    PasswordNeverExpires = $false
                    ServicePrincipalName = @()
                    MemberOf             = @()
                    objectClass          = 'user'
                    DistinguishedName    = 'CN=csvUser,OU=Users,DC=test,DC=local'
                    Enabled              = $true
                })
            }

            $script:csvPath = Join-Path $TestDrive 'dormant.csv'
            $script:csvResult = Find-DormantAccount -OutputPath $csvPath
        }

        It 'writes CSV with correct columns' {
            $csvPath | Should -Exist
            $rows = Import-Csv $csvPath
            $rows | Should -HaveCount 1
            $rows[0].PSObject.Properties.Name | Should -Contain 'SamAccountName'
            $rows[0].PSObject.Properties.Name | Should -Contain 'DormantReason'
            $rows[0].PSObject.Properties.Name | Should -Contain 'MemberOfGroups'
            $csvResult.CSVPath | Should -Be $csvPath
        }
    }

    Context 'config override changes threshold' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADGroup -ParameterFilter { $Filter } {
                @([PSCustomObject]@{
                    Name              = 'Domain Admins'
                    DistinguishedName = $domainAdminsDN
                    SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-512' }
                })
            }

            Mock -ModuleName Monarch Get-ADUser {
                @([PSCustomObject]@{
                    SamAccountName       = 'borderUser'
                    DisplayName          = 'Border User'
                    lastLogonTimestamp    = $now.AddDays(-60).ToFileTime()
                    WhenCreated          = $now.AddDays(-200)
                    PasswordLastSet      = $now.AddDays(-60)
                    PasswordNeverExpires = $false
                    ServicePrincipalName = @()
                    MemberOf             = @()
                    objectClass          = 'user'
                    DistinguishedName    = 'CN=borderUser,OU=Users,DC=test,DC=local'
                    Enabled              = $true
                })
            }

            Mock -ModuleName Monarch Get-MonarchConfigValue { 50 } -ParameterFilter {
                $Key -eq 'DormancyThresholdDays'
            }

            $script:thresholdResult = Find-DormantAccount
        }

        It 'includes account dormant at custom threshold' {
            $thresholdResult.Accounts | Should -HaveCount 1
            $thresholdResult.Accounts[0].SamAccountName | Should -Be 'borderUser'
            $thresholdResult.ThresholdDays | Should -Be 50
        }
    }

    Context 'config override changes keyword exclusion' {

        BeforeAll {
            Mock -ModuleName Monarch Get-ADGroup -ParameterFilter { $Filter } {
                @([PSCustomObject]@{
                    Name              = 'Domain Admins'
                    DistinguishedName = $domainAdminsDN
                    SID               = [PSCustomObject]@{ Value = 'S-1-5-21-1234567890-512' }
                })
            }

            Mock -ModuleName Monarch Get-ADUser {
                @([PSCustomObject]@{
                    SamAccountName       = 'CUSTOM-Worker'
                    DisplayName          = 'Custom Worker'
                    lastLogonTimestamp    = $now.AddDays(-100).ToFileTime()
                    WhenCreated          = $now.AddDays(-200)
                    PasswordLastSet      = $now.AddDays(-100)
                    PasswordNeverExpires = $false
                    ServicePrincipalName = @()
                    MemberOf             = @()
                    objectClass          = 'user'
                    DistinguishedName    = 'CN=CUSTOM-Worker,OU=Users,DC=test,DC=local'
                    Enabled              = $true
                })
            }

            Mock -ModuleName Monarch Get-MonarchConfigValue { @('CUSTOM') } -ParameterFilter {
                $Key -eq 'ServiceAccountKeywords'
            }

            $script:kwResult = Find-DormantAccount
        }

        It 'excludes account matching custom keyword' {
            $kwResult.Accounts | Should -HaveCount 0
            $kwResult.ExcludedCount | Should -Be 1
        }
    }
}

# =============================================================================
# Step 9: Group Policy
# =============================================================================

Describe 'Find-UnlinkedGPO' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-GPO { param([switch]$All, [string]$Server) }
            function script:Get-GPOReport { param([string]$Guid, [string]$ReportType, [string]$Path, [string]$Server) }
        }
    }

    Context 'with mixed GPOs' {

        BeforeAll {
            Mock -ModuleName Monarch Get-GPO {
                @(
                    [PSCustomObject]@{
                        DisplayName      = 'Linked Policy'
                        Id               = 'aaaa-1111'
                        CreationTime     = (Get-Date).AddDays(-90)
                        ModificationTime = (Get-Date).AddDays(-10)
                        Owner            = 'DOMAIN\Admin'
                    },
                    [PSCustomObject]@{
                        DisplayName      = 'Orphaned Policy'
                        Id               = 'bbbb-2222'
                        CreationTime     = (Get-Date).AddDays(-180)
                        ModificationTime = (Get-Date).AddDays(-60)
                        Owner            = 'DOMAIN\Admin'
                    }
                )
            }

            Mock -ModuleName Monarch Get-GPOReport -ParameterFilter { $Guid -eq 'aaaa-1111' } {
                [xml]@'
<GPO xmlns="http://www.microsoft.com/GroupPolicy/Settings" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <LinksTo><SOMPath>OU=Users,DC=test,DC=local</SOMPath><Enabled>true</Enabled></LinksTo>
</GPO>
'@
            }

            Mock -ModuleName Monarch Get-GPOReport -ParameterFilter { $Guid -eq 'bbbb-2222' } {
                [xml]'<GPO xmlns="http://www.microsoft.com/GroupPolicy/Settings"></GPO>'
            }

            $script:result = Find-UnlinkedGPO
        }

        It 'returns unlinked GPO' {
            $result.Domain   | Should -Be 'GroupPolicy'
            $result.Function | Should -Be 'Find-UnlinkedGPO'
            $result.Count    | Should -Be 1
            $result.UnlinkedGPOs[0].DisplayName | Should -Be 'Orphaned Policy'
        }

        It 'excludes linked GPO' {
            @($result.UnlinkedGPOs | Where-Object DisplayName -eq 'Linked Policy') | Should -HaveCount 0
        }
    }
}

Describe 'Find-GPOPermissionAnomaly' {

    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-GPO { param([switch]$All, [string]$Server) }
            function script:Get-GPPermission { param([string]$Guid, [switch]$All, [string]$Server) }
        }
    }

    Context 'with mixed permissions' {

        BeforeAll {
            Mock -ModuleName Monarch Get-GPO {
                @([PSCustomObject]@{
                    DisplayName = 'Test Policy'
                    Id          = 'cccc-3333'
                })
            }

            Mock -ModuleName Monarch Get-GPPermission {
                @(
                    [PSCustomObject]@{
                        Trustee    = [PSCustomObject]@{ Name = 'Domain Admins'; Sid = 'S-1-5-21-123-512' }
                        Permission = 'GpoEditDeleteModifySecurity'
                        Inherited  = $false
                        Denied     = $false
                    },
                    [PSCustomObject]@{
                        Trustee    = [PSCustomObject]@{ Name = 'HelpDesk-Team'; Sid = 'S-1-5-21-123-9999' }
                        Permission = 'GpoEdit'
                        Inherited  = $false
                        Denied     = $false
                    }
                )
            }

            $script:result = Find-GPOPermissionAnomaly
        }

        It 'returns non-standard editor as anomaly' {
            $result.Domain   | Should -Be 'GroupPolicy'
            $result.Function | Should -Be 'Find-GPOPermissionAnomaly'
            $result.Count    | Should -Be 1
            $result.Anomalies[0].Trustee | Should -Be 'HelpDesk-Team'
            $result.Anomalies[0].GPOName | Should -Be 'Test Policy'
        }

        It 'excludes standard editor from anomalies' {
            @($result.Anomalies | Where-Object Trustee -eq 'Domain Admins') | Should -HaveCount 0
        }
    }
}

Describe 'Export-GPOAudit' {
    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-GPO { param([switch]$All, [string]$Server) }
            function script:Get-GPOReport { param([string]$Guid, [string]$ReportType, [string]$Path, [string]$Server) }
            function script:Backup-GPO { param([switch]$All, [string]$Path, [string]$Server) }
            function script:Get-GPPermission { param([string]$Guid, [switch]$All, [string]$Server) }
            function script:Get-ADObject { param([string]$Filter, [string]$Identity, [string[]]$Properties, [string]$Server) }
        }
    }

    Context 'with mixed GPOs (no OutputPath)' {
        BeforeAll {
            Mock -ModuleName Monarch Get-GPO {
                @(
                    [PSCustomObject]@{
                        DisplayName      = 'Security Baseline'
                        Id               = 'sec-1111'
                        CreationTime     = (Get-Date).AddDays(-180)
                        ModificationTime = (Get-Date).AddDays(-10)
                        User             = [PSCustomObject]@{ Enabled = $true }
                        Computer         = [PSCustomObject]@{ Enabled = $true }
                        WmiFilter        = $null
                        Description      = 'Baseline security settings'
                        Owner            = 'DOMAIN\Admin'
                    },
                    [PSCustomObject]@{
                        DisplayName      = 'Old Test Policy'
                        Id               = 'old-2222'
                        CreationTime     = (Get-Date).AddDays(-365)
                        ModificationTime = (Get-Date).AddDays(-200)
                        User             = [PSCustomObject]@{ Enabled = $false }
                        Computer         = [PSCustomObject]@{ Enabled = $false }
                        WmiFilter        = $null
                        Description      = 'Old test'
                        Owner            = 'DOMAIN\Admin'
                    }
                )
            }

            Mock -ModuleName Monarch Get-GPOReport -ParameterFilter { $Guid -eq 'sec-1111' } {
                [xml]@'
<GPO xmlns="http://www.microsoft.com/GroupPolicy/Settings">
  <Computer><ExtensionData><Extension><UserRightsAssignment/><SecurityOptions/></Extension></ExtensionData></Computer>
  <LinksTo><SOMPath>OU=Workstations,DC=test,DC=local</SOMPath><Enabled>true</Enabled><NoOverride>false</NoOverride></LinksTo>
</GPO>
'@
            }

            Mock -ModuleName Monarch Get-GPOReport -ParameterFilter { $Guid -eq 'old-2222' } {
                [xml]'<GPO xmlns="http://www.microsoft.com/GroupPolicy/Settings"><Computer><ExtensionData><Extension><AuditSetting/></Extension></ExtensionData></Computer></GPO>'
            }

            $script:result = Export-GPOAudit
        }

        It 'returns correct shape and counts' {
            $result.Domain    | Should -Be 'GroupPolicy'
            $result.Function  | Should -Be 'Export-GPOAudit'
            $result.TotalGPOs | Should -Be 2
            $result.UnlinkedCount | Should -Be 1
            $result.DisabledCount | Should -Be 1
        }

        It 'detects high-risk GPO settings via string matching' {
            $result.HighRiskCounts.UserRights      | Should -Be 1
            $result.HighRiskCounts.SecurityOptions  | Should -Be 1
            $result.HighRiskCounts.Scripts          | Should -Be 0
            $result.HighRiskCounts.SoftwareInstall  | Should -Be 0
        }

        It 'counts unlinked GPOs' {
            $result.UnlinkedCount | Should -Be 1
        }

        It 'OverpermissionedCount is null without -IncludePermissions' {
            $result.OverpermissionedCount | Should -BeNullOrEmpty
        }
    }

    Context 'with OutputPath and all switches' {
        BeforeAll {
            Mock -ModuleName Monarch Get-GPO {
                @(
                    [PSCustomObject]@{
                        DisplayName      = 'Security Baseline'
                        Id               = 'sec-1111'
                        CreationTime     = (Get-Date).AddDays(-180)
                        ModificationTime = (Get-Date).AddDays(-10)
                        User             = [PSCustomObject]@{ Enabled = $true }
                        Computer         = [PSCustomObject]@{ Enabled = $true }
                        WmiFilter        = $null
                        Description      = 'Baseline'
                        Owner            = 'DOMAIN\Admin'
                    },
                    [PSCustomObject]@{
                        DisplayName      = 'Old Test Policy'
                        Id               = 'old-2222'
                        CreationTime     = (Get-Date).AddDays(-365)
                        ModificationTime = (Get-Date).AddDays(-200)
                        User             = [PSCustomObject]@{ Enabled = $false }
                        Computer         = [PSCustomObject]@{ Enabled = $false }
                        WmiFilter        = $null
                        Description      = 'Old'
                        Owner            = 'DOMAIN\Admin'
                    },
                    [PSCustomObject]@{
                        DisplayName      = 'Bad/Name:Test*Policy'
                        Id               = 'bad-3333'
                        CreationTime     = (Get-Date).AddDays(-30)
                        ModificationTime = (Get-Date).AddDays(-5)
                        User             = [PSCustomObject]@{ Enabled = $true }
                        Computer         = [PSCustomObject]@{ Enabled = $true }
                        WmiFilter        = $null
                        Description      = 'Bad chars'
                        Owner            = 'DOMAIN\Admin'
                    }
                )
            }

            Mock -ModuleName Monarch Get-GPOReport -ParameterFilter { $Guid -eq 'sec-1111' -and $ReportType -eq 'Xml' } {
                [xml]@'
<GPO xmlns="http://www.microsoft.com/GroupPolicy/Settings">
  <Computer><ExtensionData><Extension><UserRightsAssignment/></Extension></ExtensionData></Computer>
  <LinksTo><SOMPath>OU=Workstations,DC=test,DC=local</SOMPath><Enabled>true</Enabled><NoOverride>false</NoOverride></LinksTo>
</GPO>
'@
            }
            Mock -ModuleName Monarch Get-GPOReport -ParameterFilter { $Guid -eq 'old-2222' -and $ReportType -eq 'Xml' } {
                [xml]'<GPO xmlns="http://www.microsoft.com/GroupPolicy/Settings"></GPO>'
            }
            Mock -ModuleName Monarch Get-GPOReport -ParameterFilter { $Guid -eq 'bad-3333' -and $ReportType -eq 'Xml' } {
                [xml]@'
<GPO xmlns="http://www.microsoft.com/GroupPolicy/Settings">
  <LinksTo><SOMPath>OU=Servers,DC=test,DC=local</SOMPath><Enabled>true</Enabled><NoOverride>false</NoOverride></LinksTo>
</GPO>
'@
            }
            Mock -ModuleName Monarch Get-GPOReport -ParameterFilter { $ReportType -eq 'Html' } {}
            Mock -ModuleName Monarch Backup-GPO {}
            Mock -ModuleName Monarch Get-GPPermission {
                @(
                    [PSCustomObject]@{ Trustee = [PSCustomObject]@{ Name = 'Domain Admins'; Sid = 'S-1-5-21-512' }; Permission = 'GpoEditDeleteModifySecurity'; Inherited = $false; Denied = $false },
                    [PSCustomObject]@{ Trustee = [PSCustomObject]@{ Name = 'HelpDesk-Team'; Sid = 'S-1-5-21-9999' }; Permission = 'GpoEdit'; Inherited = $false; Denied = $false }
                )
            }
            Mock -ModuleName Monarch Get-ADObject {
                @([PSCustomObject]@{ 'msWMI-Name' = 'Win10 Filter'; 'msWMI-Parm2' = 'SELECT * FROM Win32_OperatingSystem WHERE Version LIKE "10.%"'; whenCreated = (Get-Date).AddDays(-90); whenChanged = (Get-Date).AddDays(-30) })
            }

            $script:tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "gpo-test-$(Get-Random)"
            $script:result2 = Export-GPOAudit -OutputPath $tmpDir -IncludePermissions -IncludeWMIFilters
        }

        AfterAll {
            if (Test-Path $script:tmpDir) { Remove-Item $script:tmpDir -Recurse -Force }
        }

        It 'populates all OutputPaths when OutputPath provided' {
            $result2.OutputPaths.Summary     | Should -BeLike '*00-SUMMARY*'
            $result2.OutputPaths.HTML        | Should -BeLike '*01-HTML*'
            $result2.OutputPaths.XML         | Should -BeLike '*02-XML*'
            $result2.OutputPaths.CSV         | Should -BeLike '*03-CSV*'
            $result2.OutputPaths.Permissions | Should -BeLike '*04-Permissions*'
            $result2.OutputPaths.WMI         | Should -BeLike '*05-WMI*'
        }

        It 'sanitizes filenames by stripping invalid characters' {
            $indexPath = "$tmpDir\01-HTML-Reports\00-INDEX.html"
            $indexContent = Get-Content $indexPath -Raw
            # Filename in href is sanitized, display name preserved
            $indexContent | Should -Match "href='Bad_Name_Test_Policy\.html'"
        }
    }
}

# =============================================================================
# Step 10: Backup & Recovery
# =============================================================================

Describe 'Get-BackupReadinessStatus' {
    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADRootDSE { param([string]$Server) }
            function script:Get-ADOptionalFeature { param([string]$Filter, [string]$Server) }
            function script:Get-Service { param([string[]]$Name, [string]$ComputerName, [string]$ErrorAction) }
            function script:Get-ADObject { param([string]$Filter, [string]$Identity, [string[]]$Properties, [string]$Server) }
            function script:Get-ItemProperty { param([string]$Path, [string]$Name, [string]$ErrorAction) }
        }
    }

    Context 'Tier 1 only -- no backup tool detected' {
        BeforeAll {
            Mock -ModuleName Monarch Get-ADRootDSE {
                [PSCustomObject]@{ configurationNamingContext = 'CN=Configuration,DC=test,DC=local' }
            }
            Mock -ModuleName Monarch Get-ADObject {
                [PSCustomObject]@{ tombstoneLifetime = 180 }
            }
            Mock -ModuleName Monarch Get-ADOptionalFeature {
                [PSCustomObject]@{ EnabledScopes = @() }
            }
            Mock -ModuleName Monarch Get-Service {}

            $script:result = Get-BackupReadinessStatus
        }

        It 'returns Tier 1 with no backup tool detected' {
            $result.Domain         | Should -Be 'BackupReadiness'
            $result.Function       | Should -Be 'Get-BackupReadinessStatus'
            $result.DetectionTier  | Should -Be 1
            $result.Status         | Should -Be 'Unknown'
            $result.BackupToolDetected | Should -BeNullOrEmpty
            $result.CriticalGap    | Should -Be $false
        }

        It 'returns RecycleBinEnabled false when EnabledScopes empty' {
            $result.RecycleBinEnabled | Should -Be $false
        }
    }

    Context 'Tier 2 -- Veeam service detected' {
        BeforeAll {
            Mock -ModuleName Monarch Get-ADRootDSE {
                [PSCustomObject]@{ configurationNamingContext = 'CN=Configuration,DC=test,DC=local' }
            }
            Mock -ModuleName Monarch Get-ADObject {
                [PSCustomObject]@{ tombstoneLifetime = 180 }
            }
            Mock -ModuleName Monarch Get-ADOptionalFeature {
                [PSCustomObject]@{ EnabledScopes = @('CN=Partitions,CN=Configuration,DC=test,DC=local') }
            }
            # WSB not found
            Mock -ModuleName Monarch Get-Service {}
            # Veeam service running
            Mock -ModuleName Monarch Get-Service -ParameterFilter { $Name -contains 'VeeamBackupSvc' -or $Name -contains 'VeeamDeploymentService' } {
                [PSCustomObject]@{ Name = 'VeeamBackupSvc'; Status = 'Running' }
            }

            $script:result = Get-BackupReadinessStatus
        }

        It 'detects Veeam via service enumeration' {
            $result.DetectionTier      | Should -Be 2
            $result.BackupToolDetected | Should -Be 'Veeam'
            $result.BackupToolSource   | Should -Be 'ServiceEnum'
        }
    }

    Context 'tombstone defaults to 180 when attribute null' {
        BeforeAll {
            Mock -ModuleName Monarch Get-ADRootDSE {
                [PSCustomObject]@{ configurationNamingContext = 'CN=Configuration,DC=test,DC=local' }
            }
            Mock -ModuleName Monarch Get-ADObject {
                [PSCustomObject]@{ tombstoneLifetime = $null }
            }
            Mock -ModuleName Monarch Get-ADOptionalFeature {
                [PSCustomObject]@{ EnabledScopes = @() }
            }
            Mock -ModuleName Monarch Get-Service {}

            $script:result = Get-BackupReadinessStatus
        }

        It 'defaults tombstone to 180 when attribute is null' {
            $result.TombstoneLifetimeDays | Should -Be 180
        }
    }

    Context 'Tier 3 -- backup age within tombstone' {
        BeforeAll {
            Mock -ModuleName Monarch Get-ADRootDSE {
                [PSCustomObject]@{ configurationNamingContext = 'CN=Configuration,DC=test,DC=local' }
            }
            Mock -ModuleName Monarch Get-ADObject {
                [PSCustomObject]@{ tombstoneLifetime = 180 }
            }
            Mock -ModuleName Monarch Get-ADOptionalFeature {
                [PSCustomObject]@{ EnabledScopes = @('CN=Partitions') }
            }
            Mock -ModuleName Monarch Get-Service {}
            Mock -ModuleName Monarch Get-MonarchConfigValue -ParameterFilter { $Key -eq 'KnownBackupServices' } {
                @{ 'TestVendor' = @('TestSvc') }
            }
            Mock -ModuleName Monarch Get-MonarchConfigValue -ParameterFilter { $Key -eq 'BackupIntegration' } {
                @{ Type = 'Registry'; RegistryKey = 'HKLM:\SOFTWARE\Backup'; RegistryValue = 'LastBackup' }
            }
            Mock -ModuleName Monarch Get-ItemProperty {
                @{ LastBackup = (Get-Date).AddDays(-100) }
            }

            $script:result = Get-BackupReadinessStatus
        }

        It 'reports Healthy when backup within tombstone' {
            $result.DetectionTier | Should -Be 3
            $result.CriticalGap   | Should -Be $false
            $result.Status         | Should -Be 'Healthy'
        }
    }

    Context 'Tier 3 -- backup age exceeds tombstone' {
        BeforeAll {
            Mock -ModuleName Monarch Get-ADRootDSE {
                [PSCustomObject]@{ configurationNamingContext = 'CN=Configuration,DC=test,DC=local' }
            }
            Mock -ModuleName Monarch Get-ADObject {
                [PSCustomObject]@{ tombstoneLifetime = 180 }
            }
            Mock -ModuleName Monarch Get-ADOptionalFeature {
                [PSCustomObject]@{ EnabledScopes = @('CN=Partitions') }
            }
            Mock -ModuleName Monarch Get-Service {}
            Mock -ModuleName Monarch Get-MonarchConfigValue -ParameterFilter { $Key -eq 'KnownBackupServices' } {
                @{ 'TestVendor' = @('TestSvc') }
            }
            Mock -ModuleName Monarch Get-MonarchConfigValue -ParameterFilter { $Key -eq 'BackupIntegration' } {
                @{ Type = 'Registry'; RegistryKey = 'HKLM:\SOFTWARE\Backup'; RegistryValue = 'LastBackup' }
            }
            Mock -ModuleName Monarch Get-ItemProperty {
                @{ LastBackup = (Get-Date).AddDays(-200) }
            }

            $script:result = Get-BackupReadinessStatus
        }

        It 'reports Degraded with USN rollback warning when backup exceeds tombstone' {
            $result.DetectionTier  | Should -Be 3
            $result.CriticalGap    | Should -Be $true
            $result.Status          | Should -Be 'Degraded'
            $result.DiagnosticHint  | Should -Match 'USN rollback'
        }
    }
}

Describe 'Test-TombstoneGap' {
    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADRootDSE { param([string]$Server) }
            function script:Get-ADObject { param([string]$Filter, [string]$Identity, [string[]]$Properties, [string]$Server) }
        }
        Mock -ModuleName Monarch Get-ADRootDSE {
            [PSCustomObject]@{ configurationNamingContext = 'CN=Configuration,DC=test,DC=local' }
        }
        Mock -ModuleName Monarch Get-ADObject {
            [PSCustomObject]@{ tombstoneLifetime = 180 }
        }
    }

    It 'returns no gap when backup within tombstone' {
        $r = Test-TombstoneGap -BackupAgeDays 100
        $r.CriticalGap | Should -Be $false
        $r.TombstoneLifetimeDays | Should -Be 180
    }

    It 'returns critical gap when backup exceeds tombstone' {
        $r = Test-TombstoneGap -BackupAgeDays 200
        $r.CriticalGap | Should -Be $true
        $r.DiagnosticHint | Should -Match 'USN rollback'
    }

    It 'returns null CriticalGap when BackupAgeDays omitted' {
        $r = Test-TombstoneGap
        $r.CriticalGap | Should -BeNullOrEmpty
        $r.BackupAgeDays | Should -BeNullOrEmpty
        $r.DiagnosticHint | Should -Match 'Backup age not provided'
    }
}

# =============================================================================
# Step 11: DNS
# Tests added in Step 11 implementation.
# =============================================================================

Describe 'Test-SRVRecordCompleteness' {
    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADDomain { param([string]$Server) }
            function script:Get-ADReplicationSite { param([string]$Filter, [string]$Server) }
            function script:Resolve-DnsName { param([string]$Name, [string]$Type, [string]$Server, [string]$ErrorAction) }
        }
    }

    Context 'DnsServer module unavailable' {
        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $null } -ParameterFilter { $Name -eq 'Get-DnsServerZone' }
            $script:result = Test-SRVRecordCompleteness
        }

        It 'returns result with warning and no throw' {
            $result.Domain | Should -Be 'DNS'
            $result.Sites | Should -HaveCount 0
            $result.AllComplete | Should -Be $false
            $result.Warnings | Should -Contain 'DnsServer module not available -- SRV record check skipped.'
        }
    }

    Context 'site with missing SRV record' {
        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $true } -ParameterFilter { $Name -eq 'Get-DnsServerZone' }
            Mock -ModuleName Monarch Get-ADDomain { [PSCustomObject]@{ DNSRoot = 'test.local' } }
            Mock -ModuleName Monarch Get-ADReplicationSite { @(
                [PSCustomObject]@{ Name = 'Default-First-Site-Name' }
            ) }
            Mock -ModuleName Monarch Resolve-DnsName { [PSCustomObject]@{ Name = $Name; Type = 'SRV' } }
            Mock -ModuleName Monarch Resolve-DnsName { $null } -ParameterFilter { $Name -like '_kpasswd._tcp*' }
            $script:result = Test-SRVRecordCompleteness
        }

        It 'reports missing record and AllComplete false' {
            $result.AllComplete | Should -Be $false
            $result.Sites[0].MissingRecords | Should -Contain '_kpasswd._tcp'
            $result.Sites[0].FoundRecords | Should -Be 3
            $result.Sites[0].ExpectedRecords | Should -Be 4
        }
    }

    Context 'all records present' {
        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $true } -ParameterFilter { $Name -eq 'Get-DnsServerZone' }
            Mock -ModuleName Monarch Get-ADDomain { [PSCustomObject]@{ DNSRoot = 'test.local' } }
            Mock -ModuleName Monarch Get-ADReplicationSite { @(
                [PSCustomObject]@{ Name = 'Site1' }
            ) }
            Mock -ModuleName Monarch Resolve-DnsName { [PSCustomObject]@{ Name = $Name; Type = 'SRV' } }
            $script:result = Test-SRVRecordCompleteness
        }

        It 'reports AllComplete true with no missing records' {
            $result.AllComplete | Should -Be $true
            $result.Sites[0].MissingRecords | Should -HaveCount 0
            $result.Sites[0].FoundRecords | Should -Be 4
        }
    }
}

Describe 'Get-DNSScavengingConfiguration' {
    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-DnsServerZone { param([string]$ComputerName) }
            function script:Get-DnsServerZoneAging { param([string]$Name, [string]$ComputerName) }
        }
    }

    Context 'DnsServer module unavailable' {
        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $null } -ParameterFilter { $Name -eq 'Get-DnsServerZone' }
            $script:result = Get-DNSScavengingConfiguration
        }

        It 'returns result with warning and no throw' {
            $result.Domain | Should -Be 'DNS'
            $result.Zones | Should -HaveCount 0
            $result.Warnings | Should -Contain 'DnsServer module not available -- scavenging check skipped.'
        }
    }

    Context 'zone with scavenging enabled' {
        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $true } -ParameterFilter { $Name -eq 'Get-DnsServerZone' }
            Mock -ModuleName Monarch Get-DnsServerZone { @(
                [PSCustomObject]@{ ZoneName = 'test.local'; IsDsIntegrated = $true; IsAutoCreated = $false }
            ) }
            Mock -ModuleName Monarch Get-DnsServerZoneAging {
                [PSCustomObject]@{
                    AgingEnabled      = $true
                    NoRefreshInterval = [timespan]::FromDays(7)
                    RefreshInterval   = [timespan]::FromDays(7)
                }
            }
            $script:result = Get-DNSScavengingConfiguration
        }

        It 'returns zone with correct scavenging properties' {
            $result.Zones | Should -HaveCount 1
            $result.Zones[0].ZoneName | Should -Be 'test.local'
            $result.Zones[0].ScavengingEnabled | Should -Be $true
            $result.Zones[0].NoRefreshInterval | Should -Be ([timespan]::FromDays(7))
            $result.Zones[0].RefreshInterval | Should -Be ([timespan]::FromDays(7))
        }
    }
}

Describe 'Test-ZoneReplicationScope' {
    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-DnsServerZone { param([string]$ComputerName) }
        }
    }

    Context 'DnsServer module unavailable' {
        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $null } -ParameterFilter { $Name -eq 'Get-DnsServerZone' }
            $script:result = Test-ZoneReplicationScope
        }

        It 'returns result with warning and no throw' {
            $result.Domain | Should -Be 'DNS'
            $result.Zones | Should -HaveCount 0
            $result.Warnings | Should -Contain 'DnsServer module not available -- zone replication check skipped.'
        }
    }

    Context 'DS-integrated zone' {
        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $true } -ParameterFilter { $Name -eq 'Get-DnsServerZone' }
            Mock -ModuleName Monarch Get-DnsServerZone { @(
                [PSCustomObject]@{
                    ZoneName               = 'test.local'
                    IsDsIntegrated         = $true
                    IsAutoCreated          = $false
                    DirectoryPartitionName = 'DomainDnsZones.test.local'
                    ZoneType               = 'Primary'
                }
            ) }
            $script:result = Test-ZoneReplicationScope
        }

        It 'returns correct zone replication properties' {
            $result.Zones | Should -HaveCount 1
            $result.Zones[0].ZoneName | Should -Be 'test.local'
            $result.Zones[0].IsDsIntegrated | Should -Be $true
            $result.Zones[0].ReplicationScope | Should -Be 'DomainDnsZones.test.local'
            $result.Zones[0].ZoneType | Should -Be 'Primary'
        }
    }
}

Describe 'Get-DNSForwarderConfiguration' {
    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADDomainController { param([string]$Filter, [string]$Server) }
            function script:Get-DnsServerForwarder { param([string]$ComputerName) }
        }
    }

    Context 'DnsServer module unavailable' {
        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $null } -ParameterFilter { $Name -eq 'Get-DnsServerZone' }
            $script:result = Get-DNSForwarderConfiguration
        }

        It 'returns result with warning and Consistent true' {
            $result.Domain | Should -Be 'DNS'
            $result.DCForwarders | Should -HaveCount 0
            $result.Consistent | Should -Be $true
            $result.Warnings | Should -Contain 'DnsServer module not available -- forwarder check skipped.'
        }
    }

    Context 'DCs with same forwarders' {
        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $true } -ParameterFilter { $Name -eq 'Get-DnsServerZone' }
            Mock -ModuleName Monarch Get-ADDomainController { @(
                [PSCustomObject]@{ HostName = 'DC1.test.local' },
                [PSCustomObject]@{ HostName = 'DC2.test.local' }
            ) }
            Mock -ModuleName Monarch Get-DnsServerForwarder {
                [PSCustomObject]@{ IPAddress = @('8.8.8.8', '8.8.4.4'); UseRootHints = $true }
            }
            $script:result = Get-DNSForwarderConfiguration
        }

        It 'reports Consistent true' {
            $result.DCForwarders | Should -HaveCount 2
            $result.Consistent | Should -Be $true
        }
    }

    Context 'DCs with different forwarders' {
        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $true } -ParameterFilter { $Name -eq 'Get-DnsServerZone' }
            Mock -ModuleName Monarch Get-ADDomainController { @(
                [PSCustomObject]@{ HostName = 'DC1.test.local' },
                [PSCustomObject]@{ HostName = 'DC2.test.local' }
            ) }
            Mock -ModuleName Monarch Get-DnsServerForwarder {
                if ($ComputerName -eq 'DC1.test.local') {
                    [PSCustomObject]@{ IPAddress = @('8.8.8.8'); UseRootHints = $true }
                } else {
                    [PSCustomObject]@{ IPAddress = @('1.1.1.1'); UseRootHints = $false }
                }
            }
            $script:result = Get-DNSForwarderConfiguration
        }

        It 'reports Consistent false' {
            $result.Consistent | Should -Be $false
            $result.DCForwarders[0].Forwarders | Should -Contain '8.8.8.8'
            $result.DCForwarders[1].Forwarders | Should -Contain '1.1.1.1'
        }
    }

    Context 'DC where UseRootHints property is absent' {
        BeforeAll {
            Mock -ModuleName Monarch Get-Command { $true } -ParameterFilter { $Name -eq 'Get-DnsServerZone' }
            Mock -ModuleName Monarch Get-ADDomainController { @(
                [PSCustomObject]@{ HostName = 'DC1.test.local' }
            ) }
            Mock -ModuleName Monarch Get-DnsServerForwarder {
                [PSCustomObject]@{ IPAddress = @('8.8.8.8', '8.8.4.4') }
            }
            $script:result = Get-DNSForwarderConfiguration
        }

        It 'returns null UseRootHints and populated Forwarders without warning' {
            $result.DCForwarders | Should -HaveCount 1
            $result.DCForwarders[0].UseRootHints | Should -BeNullOrEmpty
            $result.DCForwarders[0].Forwarders | Should -Contain '8.8.8.8'
            $result.Warnings | Should -HaveCount 0
        }
    }
}

# =============================================================================
# Step 12: Audit & Compliance
# Tests added in Step 12 implementation.
# =============================================================================

Describe 'Get-AuditPolicyConfiguration' {
    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADDomainController { param([string]$Filter, [string]$Server) }
            function script:Invoke-Command { param([string]$ComputerName, [scriptblock]$ScriptBlock, [string]$ErrorAction) }
        }
    }

    Context 'DCs with identical audit settings' {
        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomainController { @(
                [PSCustomObject]@{ HostName = 'DC1.test.local' },
                [PSCustomObject]@{ HostName = 'DC2.test.local' }
            ) }
            $csvLines = @(
                '"Machine Name","Policy Target","Subcategory","Subcategory GUID","Inclusion Setting","Exclusion Setting"',
                '"DC","System","Security State Change","{0CCE9210-69AE-11D9-BED3-505054503030}","Success and Failure","No Auditing"',
                '"DC","Logon/Logoff","Logon","{0CCE9215-69AE-11D9-BED3-505054503030}","Success","No Auditing"'
            )
            Mock -ModuleName Monarch Invoke-Command { $csvLines }
            $script:result = Get-AuditPolicyConfiguration
        }

        It 'reports Consistent true with correct structure' {
            $result.Domain | Should -Be 'AuditCompliance'
            $result.DCs | Should -HaveCount 2
            $result.Consistent | Should -Be $true
            $result.DCs[0].Categories | Should -HaveCount 2
            $result.DCs[0].Categories[0].Setting | Should -Be 'Success and Failure'
        }
    }

    Context 'DCs with different audit settings' {
        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomainController { @(
                [PSCustomObject]@{ HostName = 'DC1.test.local' },
                [PSCustomObject]@{ HostName = 'DC2.test.local' }
            ) }
            $csvDC1 = @(
                '"Machine Name","Policy Target","Subcategory","Subcategory GUID","Inclusion Setting","Exclusion Setting"',
                '"DC1","System","Security State Change","{0CCE9210}","Success and Failure","No Auditing"'
            )
            $csvDC2 = @(
                '"Machine Name","Policy Target","Subcategory","Subcategory GUID","Inclusion Setting","Exclusion Setting"',
                '"DC2","System","Security State Change","{0CCE9210}","No Auditing","No Auditing"'
            )
            Mock -ModuleName Monarch Invoke-Command { $csvDC1 } -ParameterFilter { $ComputerName -eq 'DC1.test.local' }
            Mock -ModuleName Monarch Invoke-Command { $csvDC2 } -ParameterFilter { $ComputerName -eq 'DC2.test.local' }
            $script:result = Get-AuditPolicyConfiguration
        }

        It 'reports Consistent false' {
            $result.Consistent | Should -Be $false
            $result.DCs[0].Categories[0].Setting | Should -Be 'Success and Failure'
            $result.DCs[1].Categories[0].Setting | Should -Be 'No Auditing'
        }
    }
}

Describe 'Get-EventLogConfiguration' {
    BeforeAll {
        & (Get-Module Monarch) {
            function script:Get-ADDomainController { param([string]$Filter, [string]$Server) }
            function script:Invoke-Command { param([string]$ComputerName, [scriptblock]$ScriptBlock, $ArgumentList, [string]$ErrorAction) }
        }
    }

    Context 'DC with event log data' {
        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomainController { @(
                [PSCustomObject]@{ HostName = 'DC1.test.local' }
            ) }
            Mock -ModuleName Monarch Invoke-Command { @(
                [PSCustomObject]@{ LogName = 'Security'; MaximumSizeInBytes = 20971520; LogMode = 'Circular' },
                [PSCustomObject]@{ LogName = 'System'; MaximumSizeInBytes = 20971520; LogMode = 'Circular' },
                [PSCustomObject]@{ LogName = 'Directory Service'; MaximumSizeInBytes = 16777216; LogMode = 'AutoBackup' }
            ) }
            $script:result = Get-EventLogConfiguration
        }

        It 'returns correct log properties per DC' {
            $result.Domain | Should -Be 'AuditCompliance'
            $result.DCs | Should -HaveCount 1
            $result.DCs[0].Logs | Should -HaveCount 3
            $result.DCs[0].Logs[0].LogName | Should -Be 'Security'
            $result.DCs[0].Logs[0].MaxSizeKB | Should -Be 20480
            $result.DCs[0].Logs[2].OverflowAction | Should -Be 'AutoBackup'
        }
    }

    Context 'unreachable DC' {
        BeforeAll {
            Mock -ModuleName Monarch Get-ADDomainController { @(
                [PSCustomObject]@{ HostName = 'DC1.test.local' },
                [PSCustomObject]@{ HostName = 'DC2.test.local' }
            ) }
            Mock -ModuleName Monarch Invoke-Command { @(
                [PSCustomObject]@{ LogName = 'Security'; MaximumSizeInBytes = 20971520; LogMode = 'Circular' },
                [PSCustomObject]@{ LogName = 'System'; MaximumSizeInBytes = 20971520; LogMode = 'Circular' },
                [PSCustomObject]@{ LogName = 'Directory Service'; MaximumSizeInBytes = 16777216; LogMode = 'Circular' }
            ) }
            Mock -ModuleName Monarch Invoke-Command { throw 'The RPC server is unavailable' } -ParameterFilter { $ComputerName -eq 'DC2.test.local' }
            $script:result = Get-EventLogConfiguration
        }

        It 'captures error in Warnings without blocking other DCs' {
            $result.DCs | Should -HaveCount 1
            $result.DCs[0].DCName | Should -Be 'DC1.test.local'
            $result.Warnings | Should -HaveCount 1
            $result.Warnings[0] | Should -Match 'DC2.test.local'
        }
    }
}

# =============================================================================
# Step 13: Reporting
# =============================================================================

Describe 'New-MonarchReport' {
    BeforeAll {
        Mock -ModuleName Monarch Get-MonarchConfigValue { '#2E5090' }
    }

    Context 'Well-formed results with mixed findings' {
        BeforeAll {
            $script:outDir = Join-Path $TestDrive 'report-mixed'
            New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
            $script:mockResults = [PSCustomObject]@{
                Phase     = 'Discovery'
                Domain    = 'contoso.com'
                DCUsed    = 'DC01.contoso.com'
                StartTime = [datetime]'2026-03-25 14:00'
                EndTime   = [datetime]'2026-03-25 14:30'
                Results   = @(
                    [PSCustomObject]@{ Domain = 'BackupReadiness'; Function = 'Get-BackupReadinessStatus'; CriticalGap = $true; DetectionTier = 2; BackupToolDetected = 'Veeam'; TombstoneLifetimeDays = 180; RecycleBinEnabled = $true; Warnings = @() }
                    [PSCustomObject]@{ Domain = 'IdentityLifecycle'; Function = 'Find-DormantAccount'; TotalCount = 12; NeverLoggedOnCount = 3; Warnings = @() }
                    [PSCustomObject]@{ Domain = 'DNS'; Function = 'Test-SRVRecordCompleteness'; AllComplete = $true; Sites = @(); Warnings = @() }
                )
                Failures = @()
            }
            $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
            $script:content = Get-Content $script:result -Raw
        }

        It 'produces HTML file and returns path' {
            $result | Should -Be (Join-Path $outDir '00-Discovery-Report.html')
            Test-Path $result | Should -BeTrue
        }

        It 'has correct executive summary counts' {
            $content | Should -Match "stat-number'>1</div><div class='stat-label'>Critical"
            $content | Should -Match "stat-number'>1</div><div class='stat-label'>Advisory"
        }

        It 'critical finding appears in critical section' {
            $content | Should -Match 'Backup age exceeds tombstone lifetime'
        }

        It 'advisory appears in domain section not critical section' {
            # Advisory text present in file
            $content | Should -Match '12 dormant accounts identified for review'
            # Split on critical-section closing tag -- advisory should not be before it
            $critSection = ($content -split 'critical-section')[0]
            $critSection | Should -Not -Match 'dormant accounts'
        }

        It 'clean domain appears in clean-domains line not as own section' {
            $content | Should -Match 'No findings:.*DNS'
            $content | Should -Not -Match "<h2>DNS</h2>"
        }
    }

    Context 'Empty results and no failures' {
        BeforeAll {
            $script:outDir = Join-Path $TestDrive 'report-empty'
            New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
            $script:mockResults = [PSCustomObject]@{
                Phase = 'Discovery'; Domain = 'contoso.com'; DCUsed = 'DC01.contoso.com'
                StartTime = [datetime]'2026-03-25 14:00'; EndTime = [datetime]'2026-03-25 14:01'
                Results = @(); Failures = @()
            }
            $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
            $script:content = Get-Content $script:result -Raw
        }

        It 'produces report with zero counts and no domain sections' {
            Test-Path $result | Should -BeTrue
            $content | Should -Match "stat-number'>0</div><div class='stat-label'>Critical"
            $content | Should -Not -Match "<div class='domain-section'>"
        }
    }

    Context 'All functions failed -- backward compat (no Dispositions)' {
        BeforeAll {
            $script:outDir = Join-Path $TestDrive 'report-allfail'
            New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
            $script:mockResults = [PSCustomObject]@{
                Phase = 'Discovery'; Domain = 'contoso.com'; DCUsed = 'DC01.contoso.com'
                StartTime = [datetime]'2026-03-25 14:00'; EndTime = [datetime]'2026-03-25 14:02'
                Results = @()
                Failures = @(
                    [PSCustomObject]@{ Function = 'Get-ReplicationHealth'; Error = 'Access denied to DC02' }
                    [PSCustomObject]@{ Function = 'Find-DormantAccount'; Error = 'LDAP timeout' }
                )
            }
            $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
            $script:content = Get-Content $script:result -Raw
        }

        It 'shows Checks stat with 0/2 and domain-less Not Assessed section' {
            $content | Should -Match "stat-number'>0/2</div><div class='stat-label'>Checks"
            $content | Should -Match 'failures-section'
            $content | Should -Match 'Not Assessed'
        }

        It 'Not Assessed entries show function name and error message' {
            $content | Should -Match 'Get-ReplicationHealth'
            $content | Should -Match 'Access denied to DC02'
            $content | Should -Match 'Find-DormantAccount'
            $content | Should -Match 'LDAP timeout'
        }
    }

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
            $script:critSection = ($content -split 'critical-section')[2]
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

    Context 'Disposition rendering -- all assessed with some findings' {
        BeforeAll {
            Mock -ModuleName Monarch Get-MonarchConfigValue { '#2E5090' }
            $script:outDir = Join-Path $TestDrive 'report-disp-assessed'
            New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
            $script:mockResults = [PSCustomObject]@{
                Phase = 'Discovery'; Domain = 'contoso.com'; DCUsed = 'DC01.contoso.com'
                StartTime = [datetime]'2026-03-25 14:00'; EndTime = [datetime]'2026-03-25 14:30'
                Results = @(
                    [PSCustomObject]@{ Domain = 'IdentityLifecycle'; Function = 'Find-DormantAccount'; TotalCount = 12; NeverLoggedOnCount = 3; Warnings = @() }
                    [PSCustomObject]@{ Domain = 'DNS'; Function = 'Test-SRVRecordCompleteness'; AllComplete = $true; Sites = @(); Warnings = @() }
                )
                Failures = @()
                Dispositions = @(
                    [PSCustomObject]@{ Function = 'Find-DormantAccount'; Domain = 'IdentityLifecycle'; Disposition = 'Assessed'; Error = $null }
                    [PSCustomObject]@{ Function = 'Test-SRVRecordCompleteness'; Domain = 'DNS'; Disposition = 'Assessed'; Error = $null }
                )
                TotalChecks = 2
            }
            $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
            $script:content = Get-Content $script:result -Raw
        }

        It 'Checks stat shows 2/2' {
            $content | Should -Match "stat-number'>2/2</div><div class='stat-label'>Checks"
        }

        It 'no Not Assessed cards rendered' {
            $content | Should -Not -Match 'Not Assessed'
        }

        It 'clean domain in No findings line' {
            $content | Should -Match 'No findings:.*DNS'
        }
    }

    Context 'Disposition rendering -- some functions not assessed' {
        BeforeAll {
            Mock -ModuleName Monarch Get-MonarchConfigValue { '#2E5090' }
            $script:outDir = Join-Path $TestDrive 'report-disp-partial'
            New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
            $script:mockResults = [PSCustomObject]@{
                Phase = 'Discovery'; Domain = 'contoso.com'; DCUsed = 'DC01.contoso.com'
                StartTime = [datetime]'2026-03-25 14:00'; EndTime = [datetime]'2026-03-25 14:30'
                Results = @(
                    [PSCustomObject]@{ Domain = 'GroupPolicy'; Function = 'Find-UnlinkedGPO'; Count = 0; Warnings = @() }
                )
                Failures = @(
                    [PSCustomObject]@{ Function = 'Export-GPOAudit'; Error = 'GroupPolicy module not loaded' }
                    [PSCustomObject]@{ Function = 'Find-GPOPermissionAnomaly'; Error = 'GroupPolicy module not loaded' }
                )
                Dispositions = @(
                    [PSCustomObject]@{ Function = 'Export-GPOAudit'; Domain = 'GroupPolicy'; Disposition = 'NotAssessed'; Error = 'GroupPolicy module not loaded' }
                    [PSCustomObject]@{ Function = 'Find-UnlinkedGPO'; Domain = 'GroupPolicy'; Disposition = 'Assessed'; Error = $null }
                    [PSCustomObject]@{ Function = 'Find-GPOPermissionAnomaly'; Domain = 'GroupPolicy'; Disposition = 'NotAssessed'; Error = 'GroupPolicy module not loaded' }
                    [PSCustomObject]@{ Function = 'Find-DormantAccount'; Domain = 'IdentityLifecycle'; Disposition = 'Assessed'; Error = $null }
                )
                TotalChecks = 4
            }
            $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
            $script:content = Get-Content $script:result -Raw
        }

        It 'Checks stat shows correct fraction' {
            $content | Should -Match "stat-number'>2/4</div><div class='stat-label'>Checks"
        }

        It 'Not Assessed cards appear in Group Policy domain section' {
            $content | Should -Match 'Not Assessed'
            $content | Should -Match 'Export-GPOAudit'
            $content | Should -Match 'GroupPolicy module not loaded'
        }

        It 'Group Policy section has check count in header' {
            $content | Should -Match "Group Policy.*1/3 checks"
        }

        It 'domain with not-assessed functions does NOT appear in No findings line' {
            if ($content -match 'No findings:') {
                $content | Should -Not -Match 'No findings:.*Group Policy'
            }
        }
    }

    Context 'Disposition rendering -- entire domain not assessed' {
        BeforeAll {
            Mock -ModuleName Monarch Get-MonarchConfigValue { '#2E5090' }
            $script:outDir = Join-Path $TestDrive 'report-disp-allfail-domain'
            New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
            $script:mockResults = [PSCustomObject]@{
                Phase = 'Discovery'; Domain = 'contoso.com'; DCUsed = 'DC01.contoso.com'
                StartTime = [datetime]'2026-03-25 14:00'; EndTime = [datetime]'2026-03-25 14:30'
                Results = @(
                    [PSCustomObject]@{ Domain = 'DNS'; Function = 'Test-SRVRecordCompleteness'; AllComplete = $true; Sites = @(); Warnings = @() }
                )
                Failures = @(
                    [PSCustomObject]@{ Function = 'Export-GPOAudit'; Error = 'GroupPolicy module not loaded' }
                    [PSCustomObject]@{ Function = 'Find-UnlinkedGPO'; Error = 'GroupPolicy module not loaded' }
                    [PSCustomObject]@{ Function = 'Find-GPOPermissionAnomaly'; Error = 'GroupPolicy module not loaded' }
                )
                Dispositions = @(
                    [PSCustomObject]@{ Function = 'Export-GPOAudit'; Domain = 'GroupPolicy'; Disposition = 'NotAssessed'; Error = 'GroupPolicy module not loaded' }
                    [PSCustomObject]@{ Function = 'Find-UnlinkedGPO'; Domain = 'GroupPolicy'; Disposition = 'NotAssessed'; Error = 'GroupPolicy module not loaded' }
                    [PSCustomObject]@{ Function = 'Find-GPOPermissionAnomaly'; Domain = 'GroupPolicy'; Disposition = 'NotAssessed'; Error = 'GroupPolicy module not loaded' }
                    [PSCustomObject]@{ Function = 'Test-SRVRecordCompleteness'; Domain = 'DNS'; Disposition = 'Assessed'; Error = $null }
                )
                TotalChecks = 4
            }
            $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
            $script:content = Get-Content $script:result -Raw
        }

        It 'Group Policy section renders with 0/3 checks' {
            $content | Should -Match "Group Policy.*0/3 checks"
        }

        It 'Group Policy section has only Not Assessed cards' {
            $content | Should -Match 'Export-GPOAudit'
            $content | Should -Match 'Find-UnlinkedGPO'
            $content | Should -Match 'Find-GPOPermissionAnomaly'
        }

        It 'Group Policy does not appear in No findings line' {
            if ($content -match 'No findings:') {
                $content | Should -Not -Match 'No findings:.*Group Policy'
            }
        }

        It 'DNS appears in No findings line' {
            $content | Should -Match 'No findings:.*DNS'
        }

        It 'no standalone failures section' {
            $content | Should -Not -Match 'Function Errors'
        }
    }

    Context 'Disposition rendering -- backward compat with no Dispositions' {
        BeforeAll {
            Mock -ModuleName Monarch Get-MonarchConfigValue { '#2E5090' }
            $script:outDir = Join-Path $TestDrive 'report-disp-compat'
            New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null
            $script:mockResults = [PSCustomObject]@{
                Phase = 'Discovery'; Domain = 'contoso.com'; DCUsed = 'DC01.contoso.com'
                StartTime = [datetime]'2026-03-25 14:00'; EndTime = [datetime]'2026-03-25 14:30'
                Results = @(
                    [PSCustomObject]@{ Domain = 'DNS'; Function = 'Test-SRVRecordCompleteness'; AllComplete = $true; Sites = @(); Warnings = @() }
                )
                Failures = @(
                    [PSCustomObject]@{ Function = 'Get-ReplicationHealth'; Error = 'Access denied' }
                )
            }
            $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
            $script:content = Get-Content $script:result -Raw
        }

        It 'renders without errors' {
            Test-Path $result | Should -BeTrue
        }

        It 'Checks stat shows 1/2' {
            $content | Should -Match "stat-number'>1/2</div><div class='stat-label'>Checks"
        }

        It 'domain-less failure falls through to Not Assessed section' {
            $content | Should -Match 'Get-ReplicationHealth'
            $content | Should -Match 'Access denied'
        }
    }

    Context 'File tree matches disk -- verified files only' {
        BeforeAll {
            $script:outDir = Join-Path $TestDrive 'report-filetree'
            New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null

            # Real files with content
            $base = Join-Path $outDir '01-Baseline'
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            Set-Content -Path (Join-Path $base 'domain-info.csv') -Value 'col1,col2'
            Set-Content -Path (Join-Path $base 'controllers.csv') -Value 'dc1,dc2'

            # Empty directory (should be cleaned up)
            $emptyDir = Join-Path $outDir '03-Privileged-Access'
            New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null

            # Empty file (0 bytes, should be cleaned up)
            $zeroFile = Join-Path $base 'empty.csv'
            [IO.File]::WriteAllBytes($zeroFile, [byte[]]@())

            $script:emptyDirPath = $emptyDir
            $script:zeroFilePath = $zeroFile

            $script:mockResults = [PSCustomObject]@{
                Phase     = 'Discovery'
                Domain    = 'contoso.com'
                DCUsed    = 'DC01.contoso.com'
                StartTime = [datetime]'2026-03-25 14:00'
                EndTime   = [datetime]'2026-03-25 14:30'
                Results   = @()
                Failures  = @()
            }
            $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
            $script:content = Get-Content $script:result -Raw
        }

        It 'real files appear in tree' {
            $content | Should -Match 'domain-info\.csv'
            $content | Should -Match 'controllers\.csv'
        }

        It 'empty directory excluded from tree' {
            $content | Should -Not -Match '03-Privileged-Access'
        }

        It 'empty file excluded from tree' {
            $content | Should -Not -Match 'empty\.csv'
        }

        It 'folder links are <a> tags with href' {
            $content | Should -Match "<a href='01-Baseline/' class='folder'>"
        }

        It 'file links are <a> tags with href' {
            $content | Should -Match "<a href='01-Baseline/domain-info\.csv'>domain-info\.csv</a>"
        }

        It 'report file excluded from tree' {
            $content | Should -Not -Match '00-Discovery-Report\.html'
        }

        It 'empty directory removed from disk' {
            Test-Path $script:emptyDirPath | Should -BeFalse
        }

        It 'empty file removed from disk' {
            Test-Path $script:zeroFilePath | Should -BeFalse
        }

        It 'real files untouched on disk' {
            Test-Path (Join-Path $outDir '01-Baseline/domain-info.csv') | Should -BeTrue
            Test-Path (Join-Path $outDir '01-Baseline/controllers.csv') | Should -BeTrue
        }
    }

    Context 'File tree omitted when no output files exist' {
        BeforeAll {
            $script:outDir = Join-Path $TestDrive 'report-notree'
            New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null

            $script:mockResults = [PSCustomObject]@{
                Phase     = 'Discovery'
                Domain    = 'contoso.com'
                DCUsed    = 'DC01.contoso.com'
                StartTime = [datetime]'2026-03-25 14:00'
                EndTime   = [datetime]'2026-03-25 14:30'
                Results   = @()
                Failures  = @()
            }
            $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
            $script:content = Get-Content $script:result -Raw
        }

        It 'no output-section div in HTML' {
            $content | Should -Not -Match "<div class='output-section'>"
        }
    }

    Context 'Nested subdirectories cascade without repeating folder names' {
        BeforeAll {
            $script:outDir = Join-Path $TestDrive 'report-nested'
            New-Item -ItemType Directory -Path $script:outDir -Force | Out-Null

            # Create nested structure: 02-GPO-Audit/00-SUMMARY/EXEC.txt and 02-GPO-Audit/01-HTML/INDEX.html
            $gpoDir = Join-Path $outDir '02-GPO-Audit'
            New-Item -ItemType Directory -Path (Join-Path $gpoDir '00-SUMMARY') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $gpoDir '01-HTML') -Force | Out-Null
            Set-Content -Path (Join-Path $gpoDir '00-SUMMARY/EXEC.txt') -Value 'summary'
            Set-Content -Path (Join-Path $gpoDir '01-HTML/INDEX.html') -Value '<html>'

            $script:mockResults = [PSCustomObject]@{
                Phase     = 'Discovery'
                Domain    = 'contoso.com'
                DCUsed    = 'DC01.contoso.com'
                StartTime = [datetime]'2026-03-25 14:00'
                EndTime   = [datetime]'2026-03-25 14:30'
                Results   = @()
                Failures  = @()
            }
            $script:result = New-MonarchReport -Results $script:mockResults -OutputPath $script:outDir
            $script:content = Get-Content $script:result -Raw
        }

        It 'parent folder rendered as folder link exactly once' {
            $matches = [regex]::Matches($content, "class='folder'>02-GPO-Audit/</a>")
            $matches.Count | Should -Be 1
        }

        It 'subfolder names rendered as folder links exactly once each' {
            ([regex]::Matches($content, "class='folder'>00-SUMMARY/</a>")).Count | Should -Be 1
            ([regex]::Matches($content, "class='folder'>01-HTML/</a>")).Count | Should -Be 1
        }

        It 'subfolders rendered with deeper indent than parent' {
            # Parent at 0px, subfolder at 24px
            $content | Should -Match "padding-left:0px.*02-GPO-Audit/"
            $content | Should -Match "padding-left:24px.*00-SUMMARY/"
        }

        It 'leaf files are tree-items with links' {
            $content | Should -Match "tree-item.*<a href='02-GPO-Audit/00-SUMMARY/EXEC\.txt'>EXEC\.txt</a>"
            $content | Should -Match "tree-item.*<a href='02-GPO-Audit/01-HTML/INDEX\.html'>INDEX\.html</a>"
        }
    }

    Context 'Relative OutputPath produces relative hrefs' {
        BeforeAll {
            # Create output dir, then pass a RELATIVE path to New-MonarchReport
            $script:absDir = Join-Path $TestDrive 'report-relpath'
            New-Item -ItemType Directory -Path $script:absDir -Force | Out-Null
            $base = Join-Path $absDir '01-Baseline'
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            Set-Content -Path (Join-Path $base 'info.csv') -Value 'data'

            # Build a relative path from CWD to the test dir
            Push-Location $TestDrive
            $script:mockResults = [PSCustomObject]@{
                Phase     = 'Discovery'
                Domain    = 'contoso.com'
                DCUsed    = 'DC01.contoso.com'
                StartTime = [datetime]'2026-03-25 14:00'
                EndTime   = [datetime]'2026-03-25 14:30'
                Results   = @()
                Failures  = @()
            }
            $script:result = New-MonarchReport -Results $script:mockResults -OutputPath 'report-relpath'
            $script:content = Get-Content $script:result -Raw
            Pop-Location
        }

        It 'hrefs are relative, not absolute' {
            $content | Should -Match "<a href='01-Baseline/info\.csv'>info\.csv</a>"
            $content | Should -Not -Match 'TestDrive'
            $content | Should -Not -Match 'report-relpath'
        }

        It 'display text is filename only, not full path' {
            # The link text between <a> and </a> must be just the filename
            $content | Should -Match ">info\.csv</a>"
            $content | Should -Not -Match ">01-Baseline/info\.csv</a>"
        }
    }
}

# =============================================================================
# Step 14: Orchestrator
# =============================================================================

Describe 'Invoke-DomainAudit' {
    BeforeAll {
        Mock -ModuleName Monarch Resolve-MonarchDC {
            [PSCustomObject]@{ DCName = 'DC01.test.local'; Domain = 'test.local'; Source = 'HealthyDC' }
        }
        $script:discoveryFunctions = @(
            'New-DomainBaseline', 'Get-FSMORolePlacement', 'Get-ReplicationHealth',
            'Get-SiteTopology', 'Get-ForestDomainLevel', 'Export-GPOAudit',
            'Find-UnlinkedGPO', 'Find-GPOPermissionAnomaly',
            'Get-PrivilegedGroupMembership', 'Find-AdminCountOrphan',
            'Find-KerberoastableAccount', 'Find-ASREPRoastableAccount',
            'Find-DormantAccount', 'Get-PasswordPolicyInventory',
            'Find-WeakAccountFlag', 'Test-ProtectedUsersGap',
            'Find-LegacyProtocolExposure', 'Get-BackupReadinessStatus',
            'Test-TombstoneGap', 'Get-AuditPolicyConfiguration',
            'Get-EventLogConfiguration', 'Test-SRVRecordCompleteness',
            'Get-DNSScavengingConfiguration', 'Test-ZoneReplicationScope',
            'Get-DNSForwarderConfiguration'
        )
        foreach ($fn in $script:discoveryFunctions) {
            Mock -ModuleName Monarch $fn {
                [PSCustomObject]@{ Domain = 'Test'; Function = 'MockFunction'; Timestamp = Get-Date; Warnings = @() }
            }
        }
        Mock -ModuleName Monarch New-MonarchReport { Join-Path $OutputPath '00-Discovery-Report.html' }
    }

    Context 'Discovery phase with all functions succeeding' {
        BeforeAll {
            $script:outDir = Join-Path $TestDrive 'audit-success'
            $script:result = Invoke-DomainAudit -Phase Discovery -OutputPath $script:outDir
        }

        It 'returns correct structure with all results' {
            $result.Phase | Should -Be 'Discovery'
            $result.Domain | Should -Be 'test.local'
            $result.DCUsed | Should -Be 'DC01.test.local'
            $result.DCSource | Should -Be 'HealthyDC'
            $result.Results | Should -HaveCount 25
            $result.Failures | Should -HaveCount 0
            $result.ReportPath | Should -Not -BeNullOrEmpty
        }

        It 'creates output directory structure' {
            Test-Path $script:outDir | Should -BeTrue
            Test-Path (Join-Path $script:outDir '01-Baseline') | Should -BeTrue
            Test-Path (Join-Path $script:outDir '02-GPO-Audit') | Should -BeTrue
            Test-Path (Join-Path $script:outDir '03-Privileged-Access') | Should -BeTrue
            Test-Path (Join-Path $script:outDir '04-Dormant-Accounts') | Should -BeTrue
        }

        It 'generates report and returns path' {
            $result.ReportPath | Should -Match '00-Discovery-Report\.html'
        }
    }

    Context 'Function failure isolation' {
        BeforeAll {
            Mock -ModuleName Monarch Get-ReplicationHealth { throw 'Replication query failed' }
            $script:outDir = Join-Path $TestDrive 'audit-failure'
            $script:result = Invoke-DomainAudit -Phase Discovery -OutputPath $script:outDir
        }

        It 'records failure and continues with remaining functions' {
            $result.Results | Should -HaveCount 24
            $result.Failures | Should -HaveCount 1
            $result.Failures[0].Function | Should -Be 'Get-ReplicationHealth'
            $result.Failures[0].Error | Should -Match 'Replication query failed'
        }
    }

    Context 'Disposition tracking -- all functions succeed' {
        BeforeAll {
            # Re-mock all functions to return domain-accurate objects
            Mock -ModuleName Monarch Get-ReplicationHealth {
                [PSCustomObject]@{ Domain = 'InfrastructureHealth'; Function = 'Get-ReplicationHealth'; Timestamp = Get-Date; Warnings = @() }
            }
            $script:outDir = Join-Path $TestDrive 'audit-dispositions'
            $script:result = Invoke-DomainAudit -Phase Discovery -OutputPath $script:outDir
        }

        It 'Dispositions has 25 entries all Assessed' {
            $result.Dispositions | Should -HaveCount 25
            @($result.Dispositions | Where-Object { $_.Disposition -eq 'Assessed' }) | Should -HaveCount 25
            @($result.Dispositions | Where-Object { $_.Error -ne $null }) | Should -HaveCount 0
        }

        It 'TotalChecks equals call count' {
            $result.TotalChecks | Should -Be 25
        }

        It 'Dispositions have correct Domain values for known functions' {
            ($result.Dispositions | Where-Object { $_.Function -eq 'New-DomainBaseline' }).Domain | Should -Be 'AuditCompliance'
            ($result.Dispositions | Where-Object { $_.Function -eq 'Get-FSMORolePlacement' }).Domain | Should -Be 'InfrastructureHealth'
            ($result.Dispositions | Where-Object { $_.Function -eq 'Export-GPOAudit' }).Domain | Should -Be 'GroupPolicy'
            ($result.Dispositions | Where-Object { $_.Function -eq 'Find-DormantAccount' }).Domain | Should -Be 'IdentityLifecycle'
            ($result.Dispositions | Where-Object { $_.Function -eq 'Get-BackupReadinessStatus' }).Domain | Should -Be 'BackupReadiness'
            ($result.Dispositions | Where-Object { $_.Function -eq 'Test-SRVRecordCompleteness' }).Domain | Should -Be 'DNS'
            ($result.Dispositions | Where-Object { $_.Function -eq 'Get-PasswordPolicyInventory' }).Domain | Should -Be 'SecurityPosture'
            ($result.Dispositions | Where-Object { $_.Function -eq 'Get-PrivilegedGroupMembership' }).Domain | Should -Be 'PrivilegedAccess'
        }
    }

    Context 'Disposition tracking -- one function throws' {
        BeforeAll {
            Mock -ModuleName Monarch Get-ReplicationHealth { throw 'Replication query failed' }
            $script:outDir = Join-Path $TestDrive 'audit-disp-failure'
            $script:result = Invoke-DomainAudit -Phase Discovery -OutputPath $script:outDir
        }

        It 'Dispositions has 25 entries with 1 NotAssessed' {
            $result.Dispositions | Should -HaveCount 25
            @($result.Dispositions | Where-Object { $_.Disposition -eq 'Assessed' }) | Should -HaveCount 24
            $notAssessed = @($result.Dispositions | Where-Object { $_.Disposition -eq 'NotAssessed' })
            $notAssessed | Should -HaveCount 1
            $notAssessed[0].Function | Should -Be 'Get-ReplicationHealth'
            $notAssessed[0].Domain | Should -Be 'InfrastructureHealth'
            $notAssessed[0].Error | Should -Match 'Replication query failed'
        }

        It 'NotAssessed function also appears in Failures for backward compat' {
            $result.Failures | Should -HaveCount 1
            $result.Failures[0].Function | Should -Be 'Get-ReplicationHealth'
        }
    }

    Context 'Non-Discovery phase' {
        It 'throws not-implemented error' {
            { Invoke-DomainAudit -Phase Remediation -OutputPath $TestDrive } | Should -Throw '*not yet implemented*'
        }
    }
}

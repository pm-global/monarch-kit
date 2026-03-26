@{

    RootModule        = 'Monarch.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'a3e7b2c1-4d8f-4e6a-9c3b-1f5d7e8a2b4c'
    Author            = 'monarch-kit contributors'
    Description       = 'Active Directory auditing module. Structured discovery across eight domains, graded findings, HTML reporting.'
    PowerShellVersion = '5.1'

    # ActiveDirectory is required. GroupPolicy and DnsServer are optional,
    # checked at runtime by functions that need them.
    RequiredModules   = @('ActiveDirectory')

    # Explicit function exports -- no wildcards. Updated as functions are added.
    FunctionsToExport = @(

        # Orchestrator
        'Invoke-DomainAudit'

        # Reporting
        'New-MonarchReport'

        # Infrastructure Health
        'Get-FSMORolePlacement'
        'Get-ReplicationHealth'
        'Get-SiteTopology'
        'Get-ForestDomainLevel'

        # Identity Lifecycle
        'Find-DormantAccount'

        # Privileged Access
        'Get-PrivilegedGroupMembership'
        'Find-AdminCountOrphan'
        'Find-KerberoastableAccount'
        'Find-ASREPRoastableAccount'

        # Group Policy
        'Export-GPOAudit'
        'Find-UnlinkedGPO'
        'Find-GPOPermissionAnomaly'

        # Security Posture
        'Get-PasswordPolicyInventory'
        'Find-WeakAccountFlag'
        'Test-ProtectedUsersGap'
        'Find-LegacyProtocolExposure'

        # Backup and Recovery
        'Get-BackupReadinessStatus'
        'Test-TombstoneGap'

        # Audit and Compliance
        'New-DomainBaseline'
        'Get-AuditPolicyConfiguration'
        'Get-EventLogConfiguration'

        # DNS (AD-Integrated)
        'Test-SRVRecordCompleteness'
        'Get-DNSScavengingConfiguration'
        'Test-ZoneReplicationScope'
        'Get-DNSForwarderConfiguration'
    )

    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('ActiveDirectory', 'Audit', 'Security', 'Administration')
            ProjectUri = ''
            LicenseUri = ''
        }
    }
}

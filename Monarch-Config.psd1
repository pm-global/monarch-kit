# Monarch-Config.psd1
# Configuration file for monarch-kit
#
# All values below are the built-in defaults. The module works without this file.
# Uncomment and modify any value to override the default for your environment.
# Missing keys fall back to built-in defaults — a partial config file is valid.

@{

    # =========================================================================
    # Identity Lifecycle
    # =========================================================================

    # Days since last logon before an account is considered dormant.
    # Aligns with PCI/NIST/Microsoft guidance.
    # DormancyThresholdDays = 90

    # Days to wait before flagging never-logged-on accounts.
    # Allows time for new account provisioning and setup.
    # NeverLoggedOnGraceDays = 60

    # Minimum days an account must remain disabled before deletion is permitted.
    # Configurable 30-365. Enforced by Remove-DormantAccount.
    # HoldPeriodMinimumDays = 30

    # OU name for quarantined dormant accounts. The 'z' prefix sorts to the
    # bottom of the OU list in ADUC, keeping it out of daily view.
    # QuarantineOUName = 'zQuarantine-Dormant'

    # AD attribute for storing the disable date (ISO 8601 timestamp).
    # Higher-numbered extensionAttributes are less commonly allocated to
    # HR or directory sync mappings. Change if this attribute is already in use.
    # DisableDateAttribute = 'extensionAttribute15'

    # AD attribute for storing rollback data (JSON: sourceOU + group memberships).
    # Used by Suspend-DormantAccount and Restore-DormantAccount.
    # Same rationale as DisableDateAttribute — configurable for environments
    # where this attribute is already in use.
    # RollbackDataAttribute = 'extensionAttribute14'

    # Keywords in account names that indicate service accounts.
    # Matched accounts are excluded from dormant account discovery.
    # BREAKGLASS identifies emergency access accounts that must never be
    # touched by automated processes.
    # ServiceAccountKeywords = @(
    #     'SERVICE', '-SVC', 'SVC-', '_SVC', 'SVC_',
    #     'APP-', '-APP', 'BREAKGLASS',
    #     'SQL', 'IIS', 'BACKUP', 'MONITOR'
    # )

    # =========================================================================
    # Privileged Access
    # =========================================================================

    # Number of Domain Admin members that triggers a warning.
    # DomainAdminWarningThreshold = 5

    # Number of Domain Admin members that triggers a critical alert.
    # DomainAdminCriticalThreshold = 10

    # Regex pattern for detecting admin account naming conventions.
    # Used to identify user accounts in admin groups that don't follow
    # the expected naming convention. Adjust for environments using
    # different conventions (e.g., '-DA' suffix, 't0-' prefix).
    # AdminAccountPattern = 'adm|admin'

    # Groups permitted to have GPO edit rights. Accounts outside this list
    # with edit permissions trigger the overpermissioned flag.
    # PermittedGPOEditors = @(
    #     'Domain Admins',
    #     'Enterprise Admins',
    #     'Group Policy Creator Owners'
    # )

    # =========================================================================
    # Infrastructure
    # =========================================================================

    # Hours since last successful replication before flagging a warning.
    # Evaluated per replication link, not per DC.
    # ReplicationWarningThresholdHours = 24

    # =========================================================================
    # Compliance
    # =========================================================================

    # Years to retain pre-deletion archives. Surfaced in post-deletion output
    # as a reminder — not enforced by the module.
    # DeletionArchiveRetentionYears = 7

    # =========================================================================
    # Backup & Recovery
    # =========================================================================

    # Known third-party backup service names for Tier 2 detection.
    # Add entries for backup tools used in your environment.
    # KnownBackupServices = @{
    #     'Veeam'     = @('VeeamBackupSvc', 'VeeamDeploymentService')
    #     'Acronis'   = @('AcronisCyberProtectService', 'AcronisAgent')
    #     'Carbonite' = @('CarboniteService')
    #     'Commvault' = @('GxCVD', 'GxVssProv')
    #     'Arcserve'  = @('CASAD2DWebSvc')
    # }

    # Tier 3 vendor-specific integration. Uncomment and configure for your
    # backup tool to enable automatic last-backup-age detection.
    #
    # Veeam (PowerShell module):
    # BackupIntegration = @{
    #     Type       = 'VeeamModule'
    #     ModuleName = 'Veeam.Backup.PowerShell'
    #     ServerName = 'localhost'
    # }
    #
    # Acronis (registry key):
    # BackupIntegration = @{
    #     Type          = 'Registry'
    #     RegistryKey   = 'HKLM:\SOFTWARE\Acronis\BackupAndRecovery'
    #     RegistryValue = 'LastBackupTime'
    # }
    #
    # Commvault (CLI):
    # BackupIntegration = @{
    #     Type    = 'CLI'
    #     CLIPath = 'C:\Program Files\Commvault\ContentStore\Base\cvquery.exe'
    #     CLIArgs = 'query last-backup --format json'
    # }

}

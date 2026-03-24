# Monarch.psm1
# Active Directory audit and administration suite.
# Composes OctoDoc stratagems for sensor data and provides the interpretation
# layer that produces actionable domain answers.
#
# Structure: single .psm1 per CLAUDE.md spec, organized by #region blocks.
# Each region corresponds to a domain from docs/domain-specs.md.

Set-StrictMode -Version Latest

#region Config
# Built-in defaults, config file loading, and config access.
# All configurable values live here — no hardcoded values in function bodies.

$script:DefaultConfig = @{

    # Identity Lifecycle
    DormancyThresholdDays      = 90
    NeverLoggedOnGraceDays     = 60
    HoldPeriodMinimumDays      = 30
    QuarantineOUName           = 'zQuarantine-Dormant'
    DisableDateAttribute       = 'extensionAttribute15'
    RollbackDataAttribute      = 'extensionAttribute14'
    ServiceAccountKeywords     = @(
        'SERVICE', '-SVC', 'SVC-', '_SVC', 'SVC_',
        'APP-', '-APP', 'BREAKGLASS',
        'SQL', 'IIS', 'BACKUP', 'MONITOR'
    )
    BuiltInExclusions          = @(
        'Administrator', 'Guest', 'krbtgt',
        'DefaultAccount', 'WDAGUtilityAccount'
    )

    # Privileged Access
    DomainAdminWarningThreshold  = 5
    DomainAdminCriticalThreshold = 10
    AdminAccountPattern          = 'adm|admin'
    PermittedGPOEditors          = @(
        'Domain Admins',
        'Enterprise Admins',
        'Group Policy Creator Owners'
    )

    # Infrastructure
    ReplicationWarningThresholdHours = 24

    # Compliance
    DeletionArchiveRetentionYears = 7

    # Backup & Recovery
    KnownBackupServices        = @{
        'Veeam'     = @('VeeamBackupSvc', 'VeeamDeploymentService')
        'Acronis'   = @('AcronisCyberProtectService', 'AcronisAgent')
        'Carbonite' = @('CarboniteService')
        'Commvault' = @('GxCVD', 'GxVssProv')
        'Arcserve'  = @('CASAD2DWebSvc')
    }
    BackupIntegration          = $null

    # DC Selection
    HealthyDCThreshold         = 7
}

# Module-scoped config — populated by Import-MonarchConfig at load time.
$script:Config = @{}

function Import-MonarchConfig
{
    <#
    .SYNOPSIS
        Loads config from Monarch-Config.psd1 and merges with built-in defaults.
        Called once at module load. File values override defaults.
    #>
    $script:Config = $script:DefaultConfig.Clone()

    $configPath = Join-Path $PSScriptRoot 'Monarch-Config.psd1'
    if (Test-Path $configPath)
    {
        try
        {
            $fileConfig = Import-PowerShellDataFile -Path $configPath
            foreach ($key in $fileConfig.Keys)
            {
                $script:Config[$key] = $fileConfig[$key]
            }
        } catch
        {
            Write-Warning "Monarch: Failed to load config from $configPath — using defaults. Error: $_"
        }
    }
}

function Get-MonarchConfigValue
{
    <#
    .SYNOPSIS
        Returns a config value by key. Single access point for all config reads.
    .PARAMETER Key
        The config key to retrieve.
    #>
    param([Parameter(Mandatory)][string]$Key)

    if ($script:Config.ContainsKey($Key))
    {
        return $script:Config[$Key]
    }
    return $null
}

#endregion Config

#region Private Helpers

function Resolve-MonarchDC
{
    <#
    .SYNOPSIS
        Resolves a domain name to a healthy DC. Falls back to DC discovery
        if OctoDoc is unavailable.
    .PARAMETER Domain
        Domain FQDN. If null, uses the current domain.
    #>
    param([string]$Domain)

    if (-not $Domain)
    {
        $Domain = (Get-ADDomain).DNSRoot
    }

    # Try OctoDoc first
    $threshold = Get-MonarchConfigValue 'HealthyDCThreshold'
    if (Get-Command -Name 'Get-HealthyDC' -ErrorAction SilentlyContinue)
    {
        try
        {
            $dc = Get-HealthyDC -Detailed -Threshold $threshold
            if ($dc)
            {
                return [PSCustomObject]@{
                    DCName = $dc.DCName
                    Domain = $Domain
                    Source = 'HealthyDC'
                }
            }
        } catch
        {
            Write-Verbose "Monarch: Get-HealthyDC failed, falling back to DC discovery. Error: $_"
        }
    }

    # Fallback: standard DC discovery
    $dc = (Get-ADDomainController -DomainName $Domain -Discover -ErrorAction Stop).HostName
    return [PSCustomObject]@{
        DCName = $dc
        Domain = $Domain
        Source = 'Discovered'
    }
}

#endregion Private Helpers

#region Infrastructure Health
# FSMO roles, replication topology, site/subnet coverage, functional levels.
# All Discovery phase. Direct AD queries (no stratagems until OctoDoc redesign).

#endregion Infrastructure Health

#region Identity Lifecycle
# Dormant account discovery through deletion. Find-DormantAccount is Discovery;
# Suspend/Restore/Remove and monitoring are later phases (Plan 2).

#endregion Identity Lifecycle

#region Privileged Access
# Group membership audit, AdminCount orphans, Kerberoastable/AS-REP roastable.
# All Discovery phase except Remove-AdminCountOrphan (Remediation, Plan 2).

#endregion Privileged Access

#region Group Policy
# GPO export, unlinked GPO detection, permission anomaly detection.
# All Discovery phase except Backup-GPO (Remediation, Plan 2).

#endregion Group Policy

#region Security Posture
# Password policies, weak flags, Protected Users gaps, legacy protocols.
# All Discovery phase.

#endregion Security Posture

#region Backup and Recovery
# Three-tier graduated confidence model for backup detection.
# All Discovery phase.

#endregion Backup and Recovery

#region Audit and Compliance
# Domain baselines, audit policy config, event log config.
# All Discovery phase except Compare-DomainBaseline (Plan 4).

#endregion Audit and Compliance

#region DNS
# AD-integrated DNS zone health and configuration.
# All Discovery phase. Requires DnsServer module (optional, checked at runtime).

#endregion DNS

#region Reporting
# Generates human-readable reports from structured Discovery results.

#endregion Reporting

#region Orchestrator
# Invoke-DomainAudit coordinates which functions run per phase.
# Start-MonarchAudit (interactive wrapper) is Plan 3.

#endregion Orchestrator

# ============================================================================
# Module Initialization
# ============================================================================

Import-MonarchConfig

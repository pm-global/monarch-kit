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

function Get-ForestDomainLevel
{
    <#
    .SYNOPSIS
        Domain/forest functional levels and schema version.
    .DESCRIPTION
        Focused check for the orchestrator. Overlaps with New-DomainBaseline intentionally —
        baseline is a snapshot document, this is a quick level check.
        Each query is independent — if one fails, others still populate.
    .PARAMETER Server
        DC name or domain FQDN passed to AD cmdlets. Omit for local domain default.
    #>
    [CmdletBinding()]
    param(
        [string]$Server
    )

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server)
    { @{ Server = $Server }
    } else
    { @{}
    }

    $domainInfo = $null
    $forestInfo = $null
    $schemaVersion = $null

    # --- Section 1: Domain ---
    try
    {
        $domainInfo = Get-ADDomain @splatAD
    } catch
    {
        $warnings.Add("Domain: $_")
    }

    # --- Section 2: Forest ---
    try
    {
        $forestInfo = Get-ADForest @splatAD
    } catch
    {
        $warnings.Add("Forest: $_")
    }

    # --- Section 3: Schema Version (depends on domain DN) ---
    try
    {
        $schemaDN = "CN=Schema,CN=Configuration,$($domainInfo.DistinguishedName)"
        $schemaObj = Get-ADObject -Identity $schemaDN -Properties objectVersion @splatAD
        $schemaVersion = $schemaObj.objectVersion
    } catch
    {
        $warnings.Add("SchemaVersion: $_")
    }

    [PSCustomObject]@{
        Domain                = 'InfrastructureHealth'
        Function              = 'Get-ForestDomainLevel'
        Timestamp             = $timestamp
        DomainFunctionalLevel = if ($domainInfo) { $domainInfo.DomainMode } else { $null }
        ForestFunctionalLevel = if ($forestInfo) { $forestInfo.ForestMode } else { $null }
        SchemaVersion         = $schemaVersion
        DomainDNSRoot         = if ($domainInfo) { $domainInfo.DNSRoot } else { $null }
        ForestName            = if ($forestInfo) { $forestInfo.Name } else { $null }
        Warnings              = @($warnings)
    }
}

function Get-FSMORolePlacement
{
    <#
    .SYNOPSIS
        FSMO role holders with reachability and site placement.
    .DESCRIPTION
        Queries domain/forest for the 5 FSMO role holders, tests reachability via
        ICMP, and maps each holder to its AD site. Deduplicates holders before pinging.
        Domain/Forest failure returns early with contract shape — roles can't be determined.
    .PARAMETER Server
        DC name or domain FQDN passed to AD cmdlets. Omit for local domain default.
    #>
    [CmdletBinding()]
    param(
        [string]$Server
    )

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server)
    { @{ Server = $Server }
    } else
    { @{}
    }

    $roles = $null
    $allOnOneDC = $null
    $unreachableCount = 0

    # --- Section 1: Role Holders from Domain/Forest ---
    $domainInfo = $null
    $forestInfo = $null
    try
    {
        $domainInfo = Get-ADDomain @splatAD
        $forestInfo = Get-ADForest @splatAD
    } catch
    {
        $warnings.Add("DomainForest: $_")
        return [PSCustomObject]@{
            Domain           = 'InfrastructureHealth'
            Function         = 'Get-FSMORolePlacement'
            Timestamp        = $timestamp
            Roles            = @()
            AllOnOneDC       = $null
            UnreachableCount = 0
            Warnings         = @($warnings)
        }
    }

    # --- Section 2: Build role list ---
    $roleMap = @(
        @{ Role = 'SchemaMaster';   Holder = $forestInfo.SchemaMaster }
        @{ Role = 'DomainNaming';   Holder = $forestInfo.DomainNamingMaster }
        @{ Role = 'PDCEmulator';    Holder = $domainInfo.PDCEmulator }
        @{ Role = 'RIDMaster';      Holder = $domainInfo.RIDMaster }
        @{ Role = 'Infrastructure'; Holder = $domainInfo.InfrastructureMaster }
    )

    # --- Section 3: DC site lookup ---
    $dcSiteMap = @{}
    try
    {
        $dcObjects = @(Get-ADDomainController -Filter '*' @splatAD)
        foreach ($dc in $dcObjects)
        { $dcSiteMap[$dc.HostName] = $dc.Site
        }
    } catch
    {
        $warnings.Add("DCSiteLookup: $_")
    }

    # --- Section 4: Reachability (deduplicate holders before pinging) ---
    $uniqueHolders = @($roleMap.Holder | Select-Object -Unique)
    $reachability = @{}
    foreach ($holder in $uniqueHolders)
    {
        try
        {
            $reachability[$holder] = Test-Connection -ComputerName $holder -Count 1 -Quiet
        } catch
        {
            $reachability[$holder] = $false
            $warnings.Add("Reachability: $holder - $_")
        }
    }

    # --- Build role sub-objects ---
    $roles = @(foreach ($r in $roleMap)
        {
            [PSCustomObject]@{
                Role      = $r.Role
                Holder    = $r.Holder
                Reachable = $reachability[$r.Holder]
                Site      = $dcSiteMap[$r.Holder]
            }
        })

    $allOnOneDC = ($uniqueHolders.Count -eq 1)
    $unreachableCount = @($roles | Where-Object { -not $_.Reachable }).Count

    [PSCustomObject]@{
        Domain           = 'InfrastructureHealth'
        Function         = 'Get-FSMORolePlacement'
        Timestamp        = $timestamp
        Roles            = $roles
        AllOnOneDC       = $allOnOneDC
        UnreachableCount = $unreachableCount
        Warnings         = @($warnings)
    }
}

function Get-SiteTopology
{
    <#
    .SYNOPSIS
        AD site/subnet topology with anomaly detection.
    .DESCRIPTION
        Enumerates sites, subnets, and DCs. Detects unassigned subnets (no site)
        and empty sites (no DCs). Each query is independent — if one fails, others still populate.
    .PARAMETER Server
        DC name or domain FQDN passed to AD cmdlets. Omit for local domain default.
    #>
    [CmdletBinding()]
    param(
        [string]$Server
    )

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server)
    { @{ Server = $Server }
    } else
    { @{}
    }

    $siteObjects = @()
    $subnetObjects = @()
    $dcObjects = @()

    # --- Section 1: Sites ---
    try
    {
        $siteObjects = @(Get-ADReplicationSite -Filter '*' @splatAD)
    } catch
    {
        $warnings.Add("Sites: $_")
    }

    # --- Section 2: Subnets ---
    try
    {
        $subnetObjects = @(Get-ADReplicationSubnet -Filter '*' @splatAD)
    } catch
    {
        $warnings.Add("Subnets: $_")
    }

    # --- Section 3: DCs (for site-to-DC mapping) ---
    try
    {
        $dcObjects = @(Get-ADDomainController -Filter '*' @splatAD)
    } catch
    {
        $warnings.Add("DomainControllers: $_")
    }

    # Build site DN → name map for subnet matching
    $siteDNMap = @{}
    foreach ($s in $siteObjects)
    { $siteDNMap[$s.DistinguishedName] = $s.Name
    }

    # Map subnets to sites by DN
    $siteSubnets = @{}
    $unassigned = [System.Collections.Generic.List[string]]::new()
    foreach ($sub in $subnetObjects)
    {
        if ($sub.Site -and $siteDNMap.ContainsKey($sub.Site))
        {
            $siteName = $siteDNMap[$sub.Site]
            if (-not $siteSubnets.ContainsKey($siteName))
            { $siteSubnets[$siteName] = @()
            }
            $siteSubnets[$siteName] += $sub.Name
        } else
        {
            $unassigned.Add($sub.Name)
        }
    }

    # Build DC-per-site counts
    $siteDCCount = @{}
    foreach ($dc in $dcObjects)
    {
        if (-not $siteDCCount.ContainsKey($dc.Site))
        { $siteDCCount[$dc.Site] = 0
        }
        $siteDCCount[$dc.Site]++
    }

    # Build site sub-objects + detect empty sites
    $emptySites = [System.Collections.Generic.List[string]]::new()
    $sites = @(foreach ($s in $siteObjects)
        {
            $dcCount = if ($siteDCCount.ContainsKey($s.Name))
            { $siteDCCount[$s.Name]
            } else
            { 0
            }
            if ($dcCount -eq 0)
            { $emptySites.Add($s.Name)
            }
            [PSCustomObject]@{
                Name    = $s.Name
                DCCount = $dcCount
                Subnets = @(if ($siteSubnets.ContainsKey($s.Name))
                    { $siteSubnets[$s.Name]
                    } else
                    { @()
                    })
            }
        })

    [PSCustomObject]@{
        Domain            = 'InfrastructureHealth'
        Function          = 'Get-SiteTopology'
        Timestamp         = $timestamp
        Sites             = $sites
        UnassignedSubnets = @($unassigned)
        EmptySites        = @($emptySites)
        SiteCount         = $siteObjects.Count
        SubnetCount       = $subnetObjects.Count
        Warnings          = @($warnings)
    }
}

function Get-ReplicationHealth
{
    <#
    .SYNOPSIS
        Per-partition replication health with graduated confidence.
    .DESCRIPTION
        Queries each DC for replication partner metadata. Classifies each link as
        Healthy/Warning/Failed based on configurable time threshold and consecutive failures.
        Generates DiagnosticHints when one partition fails but another succeeds on the same DC pair.
        Per-DC query failures are isolated — unreachable DCs add warnings, don't block others.
    .PARAMETER Server
        DC name or domain FQDN passed to AD cmdlets. Omit for local domain default.
    #>
    [CmdletBinding()]
    param(
        [string]$Server
    )

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server)
    { @{ Server = $Server }
    } else
    { @{}
    }
    $thresholdHours = Get-MonarchConfigValue 'ReplicationWarningThresholdHours'

    # --- Section 1: Get all DCs ---
    $dcObjects = @()
    try
    {
        $dcObjects = @(Get-ADDomainController -Filter '*' @splatAD)
    } catch
    {
        $warnings.Add("DomainControllers: $_")
    }

    # --- Section 2: Collect replication metadata per DC ---
    $links = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($dc in $dcObjects)
    {
        try
        {
            $metadata = @(Get-ADReplicationPartnerMetadata -Target $dc.HostName @splatAD)
            foreach ($m in $metadata)
            {
                # Partition name normalization — string matching, not structured DN parsing
                $partition = switch -Regex ($m.Partition)
                {
                    '^CN=Schema'         { 'Schema' }
                    '^CN=Configuration'  { 'Configuration' }
                    '^DC=DomainDnsZones' { 'DomainDNS' }
                    '^DC=ForestDnsZones' { 'ForestDNS' }
                    default              { 'Domain' }
                }

                $status = if ($m.ConsecutiveReplicationFailures -gt 0)
                {
                    'Failed'
                } elseif ($m.LastReplicationSuccess -and
                    ((Get-Date) - $m.LastReplicationSuccess).TotalHours -gt (2 * $thresholdHours))
                {
                    'Failed'
                } elseif ($m.LastReplicationSuccess -and
                    ((Get-Date) - $m.LastReplicationSuccess).TotalHours -gt $thresholdHours)
                {
                    'Warning'
                } else
                {
                    'Healthy'
                }

                $links.Add([PSCustomObject]@{
                    SourceDC            = $dc.HostName
                    PartnerDC           = $m.Partner
                    Partition           = $partition
                    LastSuccess         = $m.LastReplicationSuccess
                    LastAttempt         = $m.LastReplicationAttempt
                    ConsecutiveFailures = $m.ConsecutiveReplicationFailures
                    Status              = $status
                })
            }
        } catch
        {
            $warnings.Add("Replication: $($dc.HostName) - $_")
        }
    }

    # --- Section 3: DiagnosticHints for partial-partition failures ---
    $hints = [System.Collections.Generic.List[string]]::new()
    $linkArray = @($links)
    $dcPairs = $linkArray | Select-Object SourceDC, PartnerDC -Unique
    foreach ($pair in $dcPairs)
    {
        $pairLinks = $linkArray | Where-Object {
            $_.SourceDC -eq $pair.SourceDC -and $_.PartnerDC -eq $pair.PartnerDC
        }
        $healthy = @($pairLinks | Where-Object { $_.Status -eq 'Healthy' })
        $failed  = @($pairLinks | Where-Object { $_.Status -eq 'Failed' })
        if ($healthy.Count -gt 0 -and $failed.Count -gt 0)
        {
            $hNames = ($healthy.Partition | Sort-Object) -join ', '
            $fNames = ($failed.Partition | Sort-Object) -join ', '
            $hints.Add("$($pair.SourceDC)->$($pair.PartnerDC): $hNames healthy but $fNames failed")
        }
    }

    $healthyCount = @($linkArray | Where-Object { $_.Status -eq 'Healthy' }).Count
    $warningCount = @($linkArray | Where-Object { $_.Status -eq 'Warning' }).Count
    $failedCount  = @($linkArray | Where-Object { $_.Status -eq 'Failed' }).Count

    [PSCustomObject]@{
        Domain           = 'InfrastructureHealth'
        Function         = 'Get-ReplicationHealth'
        Timestamp        = $timestamp
        Links            = $linkArray
        HealthyLinkCount = $healthyCount
        WarningLinkCount = $warningCount
        FailedLinkCount  = $failedCount
        DiagnosticHints  = @($hints)
        Warnings         = @($warnings)
    }
}

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

function New-DomainBaseline
{
    <#
    .SYNOPSIS
        Comprehensive domain snapshot — functional levels, DCs, FSMO, OUs, object counts, password policy.
    .DESCRIPTION
        Collects baseline data across seven sections. Each section is independent —
        if one fails, the rest still populate and the failure appears in Warnings.
        Pattern-setting function: all subsequent API functions follow this contract.
    .PARAMETER Server
        DC name or domain FQDN passed to AD cmdlets. Omit for local domain default.
    .PARAMETER OutputPath
        Directory for per-section CSV exports. Created if missing. Omit to skip file output.
    #>
    [CmdletBinding()]
    param(
        [string]$Server,
        [string]$OutputPath
    )

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $outputFiles = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server)
    { @{ Server = $Server }
    } else
    { @{}
    }

    # Initialize all result variables so the return contract is always complete.
    $domainInfo = $null
    $forestInfo = $null
    $schemaVersion = $null
    $fsmoRoles = $null
    $domainControllers = $null
    $siteCount = $null
    $ouCount = $null
    $userCount = $null
    $computerCount = $null
    $groupCount = $null
    $passwordPolicy = $null

    # --- Section 1: Domain & Forest ---
    try
    {
        $domainInfo = Get-ADDomain @splatAD
        $forestInfo = Get-ADForest @splatAD
    } catch
    {
        $warnings.Add("DomainForest: $_")
    }

    # --- Section 2: Schema Version ---
    try
    {
        $schemaDN = "CN=Schema,CN=Configuration,$($domainInfo.DistinguishedName)"
        $schemaObj = Get-ADObject -Identity $schemaDN -Properties objectVersion @splatAD
        $schemaVersion = $schemaObj.objectVersion
    } catch
    {
        $warnings.Add("SchemaVersion: $_")
    }

    # --- Section 3: FSMO Roles (depends on section 1) ---
    if ($domainInfo -and $forestInfo)
    {
        try
        {
            $fsmoRoles = [PSCustomObject]@{
                SchemaMaster   = $forestInfo.SchemaMaster
                DomainNaming   = $forestInfo.DomainNamingMaster
                PDCEmulator    = $domainInfo.PDCEmulator
                RIDMaster      = $domainInfo.RIDMaster
                Infrastructure = $domainInfo.InfrastructureMaster
            }
        } catch
        {
            $warnings.Add("FSMORoles: $_")
        }
    } else
    {
        $warnings.Add('FSMORoles: skipped — Domain/Forest data unavailable.')
    }

    # --- Section 4: Domain Controllers ---
    try
    {
        $dcObjects = @(Get-ADDomainController -Filter '*' @splatAD)
        $domainControllers = @(foreach ($dc in $dcObjects)
            {
                [PSCustomObject]@{
                    HostName = $dc.HostName
                    Site     = $dc.Site
                    OS       = $dc.OperatingSystem
                    IPv4     = $dc.IPv4Address
                    IsGC     = $dc.IsGlobalCatalog
                    IsRODC   = $dc.IsReadOnly
                }
            })
    } catch
    {
        $warnings.Add("DomainControllers: $_")
    }

    # --- Section 5: Sites ---
    try
    {
        $siteCount = @(Get-ADReplicationSite -Filter '*' @splatAD).Count
    } catch
    {
        $warnings.Add("Sites: $_")
    }

    # --- Section 6: OUs & Object Counts ---
    try
    {
        $ouCount = @(Get-ADOrganizationalUnit -Filter '*' @splatAD).Count
    } catch
    {
        $warnings.Add("OUCount: $_")
    }

    try
    {
        $allUsers = @(Get-ADUser -Filter '*' @splatAD)
        $userCount = [PSCustomObject]@{
            Total   = $allUsers.Count
            Enabled = @($allUsers | Where-Object Enabled -eq $true).Count
        }
    } catch
    {
        $warnings.Add("UserCount: $_")
    }

    try
    {
        $allComputers = @(Get-ADComputer -Filter '*' @splatAD)
        $computerCount = [PSCustomObject]@{
            Total   = $allComputers.Count
            Enabled = @($allComputers | Where-Object Enabled -eq $true).Count
        }
    } catch
    {
        $warnings.Add("ComputerCount: $_")
    }

    try
    {
        $groupCount = @(Get-ADGroup -Filter '*' @splatAD).Count
    } catch
    {
        $warnings.Add("GroupCount: $_")
    }

    # --- Section 7: Password Policy ---
    try
    {
        $passwordPolicy = Get-ADDefaultDomainPasswordPolicy @splatAD
    } catch
    {
        $warnings.Add("PasswordPolicy: $_")
    }

    # --- CSV Export ---
    if ($OutputPath)
    {
        if (-not (Test-Path $OutputPath))
        {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }

        if ($domainInfo)
        {
            $csvPath = Join-Path $OutputPath 'domain-info.csv'
            [PSCustomObject]@{
                DomainDNSRoot         = $domainInfo.DNSRoot
                DomainNetBIOS         = $domainInfo.NetBIOSName
                DomainFunctionalLevel = $domainInfo.DomainMode
                ForestName            = if ($forestInfo)
                { $forestInfo.Name
                } else
                { $null
                }
                ForestFunctionalLevel = if ($forestInfo)
                { $forestInfo.ForestMode
                } else
                { $null
                }
                SchemaVersion         = $schemaVersion
            } | Export-Csv -Path $csvPath -NoTypeInformation
            $outputFiles.Add($csvPath)
        }

        if ($domainControllers)
        {
            $csvPath = Join-Path $OutputPath 'domain-controllers.csv'
            $domainControllers | Export-Csv -Path $csvPath -NoTypeInformation
            $outputFiles.Add($csvPath)
        }

        if ($fsmoRoles)
        {
            $csvPath = Join-Path $OutputPath 'fsmo-roles.csv'
            $fsmoRoles | Export-Csv -Path $csvPath -NoTypeInformation
            $outputFiles.Add($csvPath)
        }

        if ($null -ne $userCount -or $null -ne $computerCount)
        {
            $csvPath = Join-Path $OutputPath 'object-counts.csv'
            [PSCustomObject]@{
                TotalUsers       = if ($userCount)
                { $userCount.Total
                } else
                { $null
                }
                EnabledUsers     = if ($userCount)
                { $userCount.Enabled
                } else
                { $null
                }
                TotalComputers   = if ($computerCount)
                { $computerCount.Total
                } else
                { $null
                }
                EnabledComputers = if ($computerCount)
                { $computerCount.Enabled
                } else
                { $null
                }
                Groups           = $groupCount
                OUs              = $ouCount
            } | Export-Csv -Path $csvPath -NoTypeInformation
            $outputFiles.Add($csvPath)
        }

        if ($passwordPolicy)
        {
            $csvPath = Join-Path $OutputPath 'password-policy.csv'
            $passwordPolicy | Export-Csv -Path $csvPath -NoTypeInformation
            $outputFiles.Add($csvPath)
        }
    }

    # --- Return Contract ---
    [PSCustomObject]@{
        Domain                = 'AuditCompliance'
        Function              = 'New-DomainBaseline'
        Timestamp             = $timestamp
        Server                = $Server
        DomainDNSRoot         = if ($domainInfo)
        { $domainInfo.DNSRoot
        } else
        { $null
        }
        DomainNetBIOS         = if ($domainInfo)
        { $domainInfo.NetBIOSName
        } else
        { $null
        }
        DomainFunctionalLevel = if ($domainInfo)
        { $domainInfo.DomainMode
        } else
        { $null
        }
        ForestName            = if ($forestInfo)
        { $forestInfo.Name
        } else
        { $null
        }
        ForestFunctionalLevel = if ($forestInfo)
        { $forestInfo.ForestMode
        } else
        { $null
        }
        SchemaVersion         = $schemaVersion
        DomainControllers     = $domainControllers
        FSMORoles             = $fsmoRoles
        SiteCount             = $siteCount
        OUCount               = $ouCount
        UserCount             = $userCount
        ComputerCount         = $computerCount
        GroupCount            = $groupCount
        PasswordPolicy        = $passwordPolicy
        OutputFiles           = @($outputFiles)
        Warnings              = @($warnings)
    }
}

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

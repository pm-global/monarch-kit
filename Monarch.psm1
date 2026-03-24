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

function Get-PrivilegedGroupMembership {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    $groups = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Section 1: Discover privileged groups ---
    $privGroups = @()
    try {
        $allGroups = @(Get-ADGroup -Filter '*' -Properties SID @splatAD)
        foreach ($g in $allGroups) {
            $sid = $g.SID.Value
            if ($sid -like '*-512' -or $sid -like '*-519' -or $sid -like '*-518' -or
                $sid -eq 'S-1-5-32-544' -or $sid -eq 'S-1-5-32-548' -or
                $sid -eq 'S-1-5-32-549' -or $sid -eq 'S-1-5-32-551') {
                $privGroups += [PSCustomObject]@{
                    DN   = $g.DistinguishedName
                    Name = $g.Name
                    SID  = $sid
                }
            }
        }
    } catch {
        $warnings.Add("GroupDiscovery: $_")
    }

    # --- Section 2: Enumerate members per group ---
    foreach ($pg in $privGroups) {
        try {
            $directMembers = @(Get-ADGroupMember -Identity $pg.DN @splatAD)
            $allMembers = @(Get-ADGroupMember -Identity $pg.DN -Recursive @splatAD)

            $directSAMs = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($dm in $directMembers) { $directSAMs.Add($dm.SamAccountName) | Out-Null }

            $memberObjects = [System.Collections.Generic.List[PSCustomObject]]::new()
            $seen = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)

            foreach ($m in $allMembers) {
                if ($seen.Add($m.SamAccountName)) {
                    $userDetail = $null
                    try {
                        $userDetail = Get-ADUser -Identity $m.SamAccountName -Properties DisplayName, Enabled, LastLogonDate @splatAD
                    } catch {
                        $warnings.Add("UserDetail($($m.SamAccountName)): $_")
                    }

                    $memberObjects.Add([PSCustomObject]@{
                        SamAccountName = $m.SamAccountName
                        DisplayName    = if ($userDetail) { $userDetail.DisplayName } else { $null }
                        ObjectType     = $m.objectClass
                        IsDirect       = $directSAMs.Contains($m.SamAccountName)
                        IsEnabled      = if ($userDetail) { $userDetail.Enabled } else { $null }
                        LastLogon      = if ($userDetail) { $userDetail.LastLogonDate } else { $null }
                    })
                }
            }

            $groups.Add([PSCustomObject]@{
                GroupName   = $pg.Name
                GroupSID    = $pg.SID
                MemberCount = $memberObjects.Count
                Members     = @($memberObjects)
            })
        } catch {
            $warnings.Add("GroupMembers($($pg.Name)): $_")
        }
    }

    # --- Section 3: Domain Admin status ---
    $daGroup = $groups | Where-Object { $_.GroupSID -like '*-512' }
    $daCount = if ($daGroup) { $daGroup.MemberCount } else { 0 }
    $warnThreshold = Get-MonarchConfigValue 'DomainAdminWarningThreshold'
    $critThreshold = Get-MonarchConfigValue 'DomainAdminCriticalThreshold'
    $daStatus = if ($daCount -ge $critThreshold) { 'Critical' }
                elseif ($daCount -ge $warnThreshold) { 'Warning' }
                else { 'OK' }

    [PSCustomObject]@{
        Domain            = 'PrivilegedAccess'
        Function          = 'Get-PrivilegedGroupMembership'
        Timestamp         = $timestamp
        Groups            = @($groups)
        DomainAdminCount  = $daCount
        DomainAdminStatus = $daStatus
        Warnings          = @($warnings)
    }
}

function Find-AdminCountOrphan {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    $orphans = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Section 1: Get privileged group DNs ---
    $privGroupDNs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    try {
        $allGroups = @(Get-ADGroup -Filter '*' -Properties SID @splatAD)
        foreach ($g in $allGroups) {
            $sid = $g.SID.Value
            if ($sid -like '*-512' -or $sid -like '*-519' -or $sid -like '*-518' -or
                $sid -eq 'S-1-5-32-544' -or $sid -eq 'S-1-5-32-548' -or
                $sid -eq 'S-1-5-32-549' -or $sid -eq 'S-1-5-32-551') {
                $privGroupDNs.Add($g.DistinguishedName) | Out-Null
            }
        }
    } catch {
        $warnings.Add("GroupDiscovery: $_")
    }

    # --- Section 2: Find AdminCount=1 users not in any privileged group ---
    try {
        $acUsers = @(Get-ADUser -Filter 'AdminCount -eq 1' -Properties AdminCount, MemberOf, DisplayName, Enabled @splatAD)
        foreach ($u in $acUsers) {
            $isPrivileged = $false
            foreach ($groupDN in @($u.MemberOf)) {
                if ($privGroupDNs.Contains($groupDN)) {
                    $isPrivileged = $true
                    break
                }
            }
            if (-not $isPrivileged) {
                $orphans.Add([PSCustomObject]@{
                    SamAccountName = $u.SamAccountName
                    DisplayName    = $u.DisplayName
                    Enabled        = $u.Enabled
                    MemberOf       = @($u.MemberOf)
                })
            }
        }
    } catch {
        $warnings.Add("AdminCountQuery: $_")
    }

    [PSCustomObject]@{
        Domain    = 'PrivilegedAccess'
        Function  = 'Find-AdminCountOrphan'
        Timestamp = $timestamp
        Orphans   = @($orphans)
        Count     = $orphans.Count
        Warnings  = @($warnings)
    }
}

#endregion Privileged Access

#region Group Policy
# GPO export, unlinked GPO detection, permission anomaly detection.
# All Discovery phase except Backup-GPO (Remediation, Plan 2).

#endregion Group Policy

#region Security Posture
# Password policies, weak flags, Protected Users gaps, legacy protocols.
# All Discovery phase.

function Get-PasswordPolicyInventory {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    $defaultPolicy = $null
    $fgPolicies = @()

    # --- Section 1: Default Domain Policy ---
    try {
        $pol = Get-ADDefaultDomainPasswordPolicy @splatAD
        $defaultPolicy = [PSCustomObject]@{
            MinLength            = $pol.MinPasswordLength
            HistoryCount         = $pol.PasswordHistoryCount
            MaxAgeDays           = $pol.MaxPasswordAge.Days
            MinAgeDays           = $pol.MinPasswordAge.Days
            LockoutThreshold     = $pol.LockoutThreshold
            LockoutDurationMin   = $pol.LockoutDuration.TotalMinutes
            ComplexityEnabled    = $pol.ComplexityEnabled
            ReversibleEncryption = $pol.ReversibleEncryptionEnabled
        }
    } catch {
        $warnings.Add("DefaultPolicy: $_")
    }

    # --- Section 2: Fine-Grained Password Policies ---
    try {
        $psos = @(Get-ADFineGrainedPasswordPolicy -Filter '*' @splatAD)
        $fgPolicies = @(foreach ($p in $psos) {
            [PSCustomObject]@{
                Name             = $p.Name
                Precedence       = $p.Precedence
                AppliesTo        = @($p.AppliesTo)
                MinLength        = $p.MinPasswordLength
                MaxAgeDays       = $p.MaxPasswordAge.Days
                LockoutThreshold = $p.LockoutThreshold
            }
        })
    } catch {
        $warnings.Add("FineGrainedPolicies: $_")
    }

    [PSCustomObject]@{
        Domain              = 'SecurityPosture'
        Function            = 'Get-PasswordPolicyInventory'
        Timestamp           = $timestamp
        DefaultPolicy       = $defaultPolicy
        FineGrainedPolicies = $fgPolicies
        Warnings            = @($warnings)
    }
}

function Find-WeakAccountFlag {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()
    $userMemberOf = @{}

    # --- Section 1: Query each flag type ---
    $flagFilters = @{
        PasswordNeverExpires = 'PasswordNeverExpires -eq $true -and Enabled -eq $true'
        ReversibleEncryption = 'AllowReversiblePasswordEncryption -eq $true -and Enabled -eq $true'
        DESOnly              = 'UseDESKeyOnly -eq $true -and Enabled -eq $true'
    }

    foreach ($flag in $flagFilters.Keys) {
        try {
            $users = @(Get-ADUser -Filter $flagFilters[$flag] -Properties DisplayName, MemberOf, ServicePrincipalName @splatAD)
            foreach ($u in $users) {
                if (-not $userMemberOf.ContainsKey($u.SamAccountName)) {
                    $userMemberOf[$u.SamAccountName] = @($u.MemberOf)
                }
                $findings.Add([PSCustomObject]@{
                    SamAccountName = $u.SamAccountName
                    DisplayName    = $u.DisplayName
                    Flag           = $flag
                    Enabled        = $true
                    IsPrivileged   = $false
                })
            }
        } catch {
            $warnings.Add("${flag}: $_")
        }
    }

    # --- Section 2: Cross-reference with privileged groups ---
    $privGroupDNs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    try {
        $allGroups = @(Get-ADGroup -Filter '*' -Properties SID @splatAD)
        foreach ($g in $allGroups) {
            $sid = $g.SID.Value
            if ($sid -like '*-512' -or $sid -like '*-519' -or $sid -like '*-518' -or
                $sid -eq 'S-1-5-32-544' -or $sid -eq 'S-1-5-32-548' -or
                $sid -eq 'S-1-5-32-549' -or $sid -eq 'S-1-5-32-551') {
                $privGroupDNs.Add($g.DistinguishedName) | Out-Null
            }
        }
    } catch {
        $warnings.Add("PrivilegedGroups: $_")
    }

    foreach ($f in $findings) {
        if ($userMemberOf.ContainsKey($f.SamAccountName)) {
            foreach ($groupDN in $userMemberOf[$f.SamAccountName]) {
                if ($privGroupDNs.Contains($groupDN)) {
                    $f.IsPrivileged = $true
                    break
                }
            }
        }
    }

    # --- Build CountByFlag ---
    $countByFlag = @{}
    foreach ($f in @($findings)) {
        if (-not $countByFlag.ContainsKey($f.Flag)) { $countByFlag[$f.Flag] = 0 }
        $countByFlag[$f.Flag]++
    }

    [PSCustomObject]@{
        Domain      = 'SecurityPosture'
        Function    = 'Find-WeakAccountFlag'
        Timestamp   = $timestamp
        Findings    = @($findings)
        CountByFlag = $countByFlag
        Warnings    = @($warnings)
    }
}

function Test-ProtectedUsersGap {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    $protectedMembers = @()
    $gapAccounts = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Section 1: Discover privileged and Protected Users groups ---
    $privGroups = @()
    $protectedUsersDN = $null
    try {
        $allGroups = @(Get-ADGroup -Filter '*' -Properties SID @splatAD)
        foreach ($g in $allGroups) {
            $sid = $g.SID.Value
            if ($sid -like '*-525') {
                $protectedUsersDN = $g.DistinguishedName
            }
            if ($sid -like '*-512' -or $sid -like '*-519' -or $sid -like '*-518' -or
                $sid -eq 'S-1-5-32-544' -or $sid -eq 'S-1-5-32-548' -or
                $sid -eq 'S-1-5-32-549' -or $sid -eq 'S-1-5-32-551') {
                $privGroups += [PSCustomObject]@{
                    DN   = $g.DistinguishedName
                    Name = $g.Name
                }
            }
        }
    } catch {
        $warnings.Add("GroupDiscovery: $_")
    }

    # --- Section 2: Get Protected Users members ---
    $protectedSAMs = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    if ($protectedUsersDN) {
        try {
            $puMembers = @(Get-ADGroupMember -Identity $protectedUsersDN @splatAD)
            $protectedMembers = @($puMembers.SamAccountName)
            foreach ($m in $puMembers) { $protectedSAMs.Add($m.SamAccountName) | Out-Null }
        } catch {
            $warnings.Add("ProtectedUsersMembers: $_")
        }
    } else {
        $warnings.Add("ProtectedUsersMembers: Protected Users group not found")
    }

    # --- Section 3: Get privileged group members, find gaps ---
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($pg in $privGroups) {
        try {
            $members = @(Get-ADGroupMember -Identity $pg.DN @splatAD)
            foreach ($m in $members) {
                if (-not $protectedSAMs.Contains($m.SamAccountName) -and
                    $seen.Add($m.SamAccountName)) {
                    $userDetail = $null
                    try {
                        $userDetail = Get-ADUser -Identity $m.SamAccountName -Properties ServicePrincipalName @splatAD
                    } catch {
                        $warnings.Add("UserDetail($($m.SamAccountName)): $_")
                    }
                    $hasSPN = if ($userDetail -and $userDetail.ServicePrincipalName) {
                        @($userDetail.ServicePrincipalName).Count -gt 0
                    } else { $false }

                    $gapAccounts.Add([PSCustomObject]@{
                        SamAccountName   = $m.SamAccountName
                        PrivilegedGroups = @($pg.Name)
                        HasSPN           = $hasSPN
                    })
                } elseif (-not $protectedSAMs.Contains($m.SamAccountName)) {
                    $existing = $gapAccounts | Where-Object SamAccountName -eq $m.SamAccountName
                    if ($existing) {
                        $existing.PrivilegedGroups = @($existing.PrivilegedGroups) + $pg.Name
                    }
                }
            }
        } catch {
            $warnings.Add("GroupMembers($($pg.Name)): $_")
        }
    }

    # --- DiagnosticHint ---
    $hint = $null
    $spnAccounts = @($gapAccounts | Where-Object HasSPN)
    if ($spnAccounts.Count -gt 0) {
        $hint = "WARNING: $($spnAccounts.Count) gap account(s) have SPNs (service accounts). " +
                "Adding service accounts to Protected Users disables Kerberos delegation and blocks NTLM. " +
                "Review each account before adding — blanket addition will break service authentication."
    }

    [PSCustomObject]@{
        Domain                = 'SecurityPosture'
        Function              = 'Test-ProtectedUsersGap'
        Timestamp             = $timestamp
        ProtectedUsersMembers = $protectedMembers
        GapAccounts           = @($gapAccounts)
        DiagnosticHint        = $hint
        Warnings              = @($warnings)
    }
}

function Find-LegacyProtocolExposure {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    $dcFindings = [System.Collections.Generic.List[PSCustomObject]]::new()

    # --- Section 1: Get DC list ---
    $dcs = @()
    try {
        $dcs = @(Get-ADDomainController -Filter '*' @splatAD)
    } catch {
        $warnings.Add("DCList: $_")
    }

    # --- Section 2: Query each DC for legacy protocol settings ---
    foreach ($dc in $dcs) {
        try {
            $regData = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                $lsa = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction SilentlyContinue
                $ntds = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters' -ErrorAction SilentlyContinue
                [PSCustomObject]@{
                    LmCompatibilityLevel = $lsa.LmCompatibilityLevel
                    NoLMHash             = $lsa.NoLMHash
                    LDAPServerIntegrity  = $ntds.LDAPServerIntegrity
                }
            }

            # NTLMv1 check
            $lmLevel = $regData.LmCompatibilityLevel
            if ($null -eq $lmLevel -or $lmLevel -lt 3) {
                $dcFindings.Add([PSCustomObject]@{
                    DCName  = $dc.HostName
                    Finding = 'NTLMv1Enabled'
                    Value   = "LmCompatibilityLevel=$lmLevel"
                    Risk    = 'High'
                })
            }

            # LM Hash storage check
            $noLM = $regData.NoLMHash
            if ($null -eq $noLM -or $noLM -ne 1) {
                $dcFindings.Add([PSCustomObject]@{
                    DCName  = $dc.HostName
                    Finding = 'LMHashStored'
                    Value   = "NoLMHash=$noLM"
                    Risk    = 'High'
                })
            }

            # LDAP Signing check
            $ldapSigning = $regData.LDAPServerIntegrity
            if ($null -eq $ldapSigning -or $ldapSigning -ne 2) {
                $dcFindings.Add([PSCustomObject]@{
                    DCName  = $dc.HostName
                    Finding = 'LDAPSigningDisabled'
                    Value   = "LDAPServerIntegrity=$ldapSigning"
                    Risk    = 'Medium'
                })
            }
        } catch {
            $warnings.Add("$($dc.HostName): $_")
        }
    }

    [PSCustomObject]@{
        Domain     = 'SecurityPosture'
        Function   = 'Find-LegacyProtocolExposure'
        Timestamp  = $timestamp
        DCFindings = @($dcFindings)
        Warnings   = @($warnings)
    }
}

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

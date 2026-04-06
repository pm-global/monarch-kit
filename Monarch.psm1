# Monarch.psm1
# Active Directory audit and administration suite.
# Composes OctoDoc stratagems for sensor data and provides the interpretation
# layer that produces actionable domain answers.


# Structure: single .psm1 per CLAUDE.md spec, organized by #region blocks.
# Each region corresponds to a domain from docs/domain-specs.md.

Set-StrictMode -Version Latest

#region Config
# Built-in defaults, config file loading, and config access.
# All configurable values live here -- no hardcoded values in function bodies.

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

    # Advisory Thresholds
    MinPasswordLength          = 14
    RequireLockoutThreshold    = $true
    MinSecurityLogSizeKB       = 1048576
    AcceptableOverflowActions  = @('ArchiveTheLogWhenFull')
    RequireDNSScavenging       = $true
    RequireDSIntegration       = $true
}

# Module-scoped config -- populated by Import-MonarchConfig at load time.
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
            Write-Warning "Monarch: Failed to load config from $configPath -- using defaults. Error: $_"
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
    .NOTES
        DCName is always a string array. Currently one element -- structure
        supports future expansion to return multiple healthy DCs.
    #>
    param([string]$Domain)
    Write-Host "resolve-monarchDC..." -ForegroundColor DarkGray
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
                    DCName = @($dc.DCName)
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
    # .HostName returns string[] in some environments -- @() normalizes either shape
    $dc = @((Get-ADDomainController -DomainName $Domain -Discover -ErrorAction Stop).HostName)
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
        Focused check for the orchestrator. Overlaps with New-DomainBaseline intentionally  --
        baseline is a snapshot document, this is a quick level check.
        Each query is independent -- if one fails, others still populate.
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
        Domain/Forest failure returns early with contract shape -- roles can't be determined.
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
        and empty sites (no DCs). Each query is independent -- if one fails, others still populate.
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

    # Build site DN -> name map for subnet matching
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
        Per-DC query failures are isolated -- unreachable DCs add warnings, don't block others.
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
            $metadata = @(Get-ADReplicationPartnerMetadata -Target $dc.HostName)
            foreach ($m in $metadata)
            {
                # Partition name normalization -- string matching, not structured DN parsing
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

function Find-DormantAccount {
    [CmdletBinding()]
    param([string]$Server, [string]$OutputPath)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    $thresholdDays = Get-MonarchConfigValue 'DormancyThresholdDays'
    $graceDays     = Get-MonarchConfigValue 'NeverLoggedOnGraceDays'
    $keywords      = Get-MonarchConfigValue 'ServiceAccountKeywords'
    $builtIns      = Get-MonarchConfigValue 'BuiltInExclusions'
    $cutoffDate    = $timestamp.AddDays(-$thresholdDays)

    # --- Section 1: Query all enabled users, filter MSA/gMSA ---
    $allUsers = @()
    try {
        $allUsers = @(Get-ADUser -Filter 'Enabled -eq $true' -Properties lastLogonTimestamp, WhenCreated, PasswordLastSet, PasswordNeverExpires, ServicePrincipalName, MemberOf, DisplayName, objectClass, DistinguishedName @splatAD |
            Where-Object { $_.objectClass -notin @('msDS-ManagedServiceAccount', 'msDS-GroupManagedServiceAccount') })
    } catch {
        $warnings.Add("UserQuery: $_")
    }
    $totalQueried = $allUsers.Count

    # --- Section 2: Privileged group discovery + exclusion filtering ---
    $privGroupDNs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($g in @(Get-ADGroup -Filter '*' -Properties SID @splatAD)) {
            $sid = $g.SID.Value
            if ($sid -like '*-512' -or $sid -like '*-519' -or $sid -like '*-518' -or
                $sid -eq 'S-1-5-32-544' -or $sid -eq 'S-1-5-32-548' -or
                $sid -eq 'S-1-5-32-549' -or $sid -eq 'S-1-5-32-551') {
                $privGroupDNs.Add($g.DistinguishedName) | Out-Null
            }
        }
    } catch { $warnings.Add("GroupDiscovery: $_") }

    $filtered = foreach ($u in $allUsers) {
        if ($builtIns -contains $u.SamAccountName) { continue }
        if ($u.PasswordNeverExpires) { continue }
        if (@($u.ServicePrincipalName).Count -gt 0) { continue }
        $kwMatch = $false
        foreach ($kw in $keywords) { if ($u.SamAccountName -match [regex]::Escape($kw)) { $kwMatch = $true; break } }
        if ($kwMatch) { continue }
        $inPriv = $false
        foreach ($dn in @($u.MemberOf)) { if ($privGroupDNs.Contains($dn)) { $inPriv = $true; break } }
        if ($inPriv) { continue }
        $u
    }
    $filtered = @($filtered)

    # --- Section 2b: Cross-DC lastLogon refinement for near-threshold accounts ---
    $nearCutoff = $timestamp.AddDays(-($thresholdDays - 15))
    $nearThreshold = @($filtered | Where-Object {
        $_.lastLogonTimestamp -and $_.lastLogonTimestamp -gt 0 -and
        ([DateTime]::FromFileTime($_.lastLogonTimestamp)) -ge $cutoffDate -and
        ([DateTime]::FromFileTime($_.lastLogonTimestamp)) -lt $nearCutoff
    })

    if ($nearThreshold.Count -gt 0) {
        $dcs = @()
        try { $dcs = @(Get-ADDomainController -Filter '*' @splatAD) } catch { $warnings.Add("DCDiscovery: $_") }

        foreach ($u in $nearThreshold) {
            $maxLogon = $null
            foreach ($dc in $dcs) {
                try {
                    $dcUser = Get-ADUser -Identity $u.SamAccountName -Server $dc.HostName -Properties LastLogon
                    if ($dcUser.LastLogon -gt 0) {
                        $thisLogon = [DateTime]::FromFileTime($dcUser.LastLogon)
                        if ($null -eq $maxLogon -or $thisLogon -gt $maxLogon) { $maxLogon = $thisLogon }
                    }
                } catch { $warnings.Add("CrossDC($($dc.HostName)/$($u.SamAccountName)): $_") }
            }
            if ($maxLogon) {
                $u | Add-Member -NotePropertyName '_refinedLastLogon' -NotePropertyValue $maxLogon -Force
            }
        }
    }

    # --- Section 3: Dormancy classification ---
    $accounts = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($u in $filtered) {
        $lastLogon = if ($u.PSObject.Properties['_refinedLastLogon']) {
            $u._refinedLastLogon
        } elseif ($u.lastLogonTimestamp -and $u.lastLogonTimestamp -gt 0) {
            [DateTime]::FromFileTime($u.lastLogonTimestamp)
        } else { $null }

        $dormantReason = $null
        if ($null -eq $lastLogon) {
            $accountAge = ($timestamp - $u.WhenCreated).Days
            if ($accountAge -ge $graceDays) {
                $dormantReason = "Never logged on (created $accountAge days ago)"
            }
        } elseif ($lastLogon -lt $cutoffDate) {
            $dormantReason = "No logon for $(($timestamp - $lastLogon).Days) days"
        }

        if (-not $dormantReason) { continue }

        $pwdAge = if ($u.PasswordLastSet) { ($timestamp - $u.PasswordLastSet).Days } else { -1 }
        $memberGroups = @($u.MemberOf | ForEach-Object {
            try { (Get-ADGroup -Identity $_ @splatAD).Name } catch { $null }
        } | Where-Object { $_ }) -join '; '

        $accounts.Add([PSCustomObject]@{
            SamAccountName    = $u.SamAccountName
            DisplayName       = $u.DisplayName
            LastLogon         = $lastLogon
            DaysSinceLogon    = if ($lastLogon) { ($timestamp - $lastLogon).Days } else { -1 }
            PasswordLastSet   = $u.PasswordLastSet
            PasswordAgeDays   = $pwdAge
            MemberOfGroups    = $memberGroups
            DormantReason     = $dormantReason
            DistinguishedName = $u.DistinguishedName
        })
    }

    # --- Section 4: Return ---
    $neverCount = @($accounts | Where-Object { $_.DaysSinceLogon -eq -1 }).Count
    $csvPath = $null
    if ($OutputPath -and $accounts.Count -gt 0) {
        $csvPath = $OutputPath
        $accounts | Select-Object SamAccountName, DisplayName, LastLogon, DaysSinceLogon, PasswordAgeDays, MemberOfGroups, DormantReason |
            Export-Csv -Path $csvPath -NoTypeInformation
    }

    [PSCustomObject]@{
        Domain             = 'IdentityLifecycle'
        Function           = 'Find-DormantAccount'
        Timestamp          = $timestamp
        ThresholdDays      = $thresholdDays
        Accounts           = @($accounts)
        CSVPath            = $csvPath
        TotalCount         = $accounts.Count
        NeverLoggedOnCount = $neverCount
        ExcludedCount      = $totalQueried - $accounts.Count
        Warnings           = @($warnings)
    }
}

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

function Find-KerberoastableAccount {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    $accounts = [System.Collections.Generic.List[PSCustomObject]]::new()

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

    # --- Section 2: Query users with SPNs ---
    try {
        $spnUsers = @(Get-ADUser -Filter 'ServicePrincipalName -like "*"' -Properties ServicePrincipalName, DisplayName, MemberOf, PasswordLastSet, Enabled @splatAD)
        foreach ($u in $spnUsers) {
            $isPriv = $false
            foreach ($groupDN in @($u.MemberOf)) {
                if ($privGroupDNs.Contains($groupDN)) { $isPriv = $true; break }
            }
            $pwdAge = if ($u.PasswordLastSet) {
                [int]($timestamp - $u.PasswordLastSet).TotalDays
            } else { -1 }

            $accounts.Add([PSCustomObject]@{
                SamAccountName  = $u.SamAccountName
                DisplayName     = $u.DisplayName
                SPNs            = @($u.ServicePrincipalName)
                IsPrivileged    = $isPriv
                PasswordAgeDays = $pwdAge
                Enabled         = $u.Enabled
            })
        }
    } catch {
        $warnings.Add("SPNQuery: $_")
    }

    $privCount = @($accounts | Where-Object IsPrivileged).Count

    [PSCustomObject]@{
        Domain          = 'PrivilegedAccess'
        Function        = 'Find-KerberoastableAccount'
        Timestamp       = $timestamp
        Accounts        = @($accounts)
        TotalCount      = $accounts.Count
        PrivilegedCount = $privCount
        Warnings        = @($warnings)
    }
}

function Find-ASREPRoastableAccount {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    $accounts = [System.Collections.Generic.List[PSCustomObject]]::new()

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

    # --- Section 2: Query users with pre-auth disabled ---
    try {
        $users = @(Get-ADUser -Filter 'DoesNotRequirePreAuth -eq $true' -Properties DisplayName, MemberOf, Enabled @splatAD)
        foreach ($u in $users) {
            $isPriv = $false
            foreach ($groupDN in @($u.MemberOf)) {
                if ($privGroupDNs.Contains($groupDN)) { $isPriv = $true; break }
            }
            $accounts.Add([PSCustomObject]@{
                SamAccountName = $u.SamAccountName
                DisplayName    = $u.DisplayName
                IsPrivileged   = $isPriv
                Enabled        = $u.Enabled
            })
        }
    } catch {
        $warnings.Add("ASREPQuery: $_")
    }

    [PSCustomObject]@{
        Domain    = 'PrivilegedAccess'
        Function  = 'Find-ASREPRoastableAccount'
        Timestamp = $timestamp
        Accounts  = @($accounts)
        Count     = $accounts.Count
        Warnings  = @($warnings)
    }
}

#endregion Privileged Access

#region Group Policy
# GPO export, unlinked GPO detection, permission anomaly detection.
# All Discovery phase except Backup-GPO (Remediation, Plan 2).

function Find-UnlinkedGPO {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    $unlinked = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $allGPOs = @(Get-GPO -All @splatAD)
    } catch {
        $warnings.Add("GPOQuery: $_")
        $allGPOs = @()
    }

    foreach ($gpo in $allGPOs) {
        try {
            [xml]$report = Get-GPOReport -Guid $gpo.Id -ReportType Xml @splatAD
            if (-not $report.GPO['LinksTo']) {
                $unlinked.Add([PSCustomObject]@{
                    DisplayName  = $gpo.DisplayName
                    Id           = $gpo.Id
                    CreatedTime  = $gpo.CreationTime
                    ModifiedTime = $gpo.ModificationTime
                    Owner        = $gpo.Owner
                })
            }
        } catch { $warnings.Add("GPOReport($($gpo.DisplayName)): $_") }
    }

    [PSCustomObject]@{
        Domain       = 'GroupPolicy'
        Function     = 'Find-UnlinkedGPO'
        Timestamp    = $timestamp
        UnlinkedGPOs = @($unlinked)
        Count        = $unlinked.Count
        Warnings     = @($warnings)
    }
}

function Find-GPOPermissionAnomaly {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    $permittedEditors = Get-MonarchConfigValue 'PermittedGPOEditors'
    $anomalies = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $allGPOs = @(Get-GPO -All @splatAD)
    } catch {
        $warnings.Add("GPOQuery: $_")
        $allGPOs = @()
    }

    foreach ($gpo in $allGPOs) {
        try {
            $perms = @(Get-GPPermission -Guid $gpo.Id -All @splatAD)
            foreach ($p in $perms) {
                if ($p.Permission -like '*Edit*' -and
                    $p.Trustee.Name -notin $permittedEditors -and
                    -not $p.Denied) {
                    $anomalies.Add([PSCustomObject]@{
                        GPOName    = $gpo.DisplayName
                        Trustee    = $p.Trustee.Name
                        TrusteeSID = $p.Trustee.Sid
                        Permission = $p.Permission
                        Inherited  = $p.Inherited
                    })
                }
            }
        } catch { $warnings.Add("GPOPerms($($gpo.DisplayName)): $_") }
    }

    [PSCustomObject]@{
        Domain    = 'GroupPolicy'
        Function  = 'Find-GPOPermissionAnomaly'
        Timestamp = $timestamp
        Anomalies = @($anomalies)
        Count     = $anomalies.Count
        Warnings  = @($warnings)
    }
}

function Export-GPOAudit {
    [CmdletBinding()]
    param(
        [string]$Server,
        [string]$OutputPath,
        [switch]$IncludePermissions,
        [switch]$IncludeWMIFilters
    )

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    # Create output directories (numbered for review priority order)
    $paths = @{
        Summary     = if ($OutputPath) { Join-Path $OutputPath '00-SUMMARY' } else { $null }
        HTML        = if ($OutputPath) { Join-Path $OutputPath '01-HTML-Reports' } else { $null }
        XML         = if ($OutputPath) { Join-Path $OutputPath '02-XML-Backup' } else { $null }
        CSV         = if ($OutputPath) { Join-Path $OutputPath '03-CSV-Analysis' } else { $null }
        Permissions = if ($OutputPath) { Join-Path $OutputPath '04-Permissions' } else { $null }
        WMI         = if ($OutputPath) { Join-Path $OutputPath '05-WMI-Filters' } else { $null }
    }
    if ($OutputPath) {
        foreach ($p in $paths.Values) { if ($p) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
    }

    $allGPOs = @()
    try { $allGPOs = @(Get-GPO -All @splatAD) } catch { $warnings.Add("GPOQuery: $_") }

    $gpoSummary = [System.Collections.Generic.List[PSCustomObject]]::new()
    $linkageDetails = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($gpo in $allGPOs) {
        try {
            [xml]$report = Get-GPOReport -Guid $gpo.Id -ReportType Xml @splatAD
            $xmlContent = $report.OuterXml

            # High-risk string matching (not XML parsing -- namespace handling varies, see mechanism-decisions.md)
            $hasUserRights     = [bool]($xmlContent -match 'UserRightsAssignment')
            $hasSecurityOpts   = [bool]($xmlContent -match 'SecurityOptions')
            $hasScripts        = [bool]($xmlContent -match '<Script>')
            $hasSoftwareInst   = [bool]($xmlContent -match 'SoftwareInstallation')

            $gpoSummary.Add([PSCustomObject]@{
                DisplayName        = $gpo.DisplayName
                GUID               = $gpo.Id
                CreatedTime        = $gpo.CreationTime
                ModifiedTime       = $gpo.ModificationTime
                UserEnabled        = $gpo.User.Enabled
                ComputerEnabled    = $gpo.Computer.Enabled
                WMIFilter          = if ($gpo.WmiFilter) { $gpo.WmiFilter.Name } else { $null }
                Description        = $gpo.Description
                HasUserRights      = $hasUserRights
                HasSecurityOptions = $hasSecurityOpts
                HasScripts         = $hasScripts
                HasSoftwareInstall = $hasSoftwareInst
                Owner              = $gpo.Owner
            })

            # Linkage -- use indexer for strict-mode-safe namespace XML access
            $links = $report.GPO['LinksTo']
            if ($links) {
                foreach ($link in @($links)) {
                    $linkageDetails.Add([PSCustomObject]@{
                        GPOName    = $gpo.DisplayName
                        LinkedTo   = $link.SOMPath
                        Enabled    = $link.Enabled
                        NoOverride = $link.NoOverride
                    })
                }
            } else {
                $linkageDetails.Add([PSCustomObject]@{
                    GPOName    = $gpo.DisplayName
                    LinkedTo   = '**UNLINKED**'
                    Enabled    = 'N/A'
                    NoOverride = 'N/A'
                })
            }
        } catch { $warnings.Add("GPOAnalysis($($gpo.DisplayName)): $_") }
    }

    if ($OutputPath -and $gpoSummary.Count -gt 0) {
        $gpoSummary | Export-Csv -Path (Join-Path $paths.CSV 'gpo-summary.csv') -NoTypeInformation
        $linkageDetails | Export-Csv -Path (Join-Path $paths.CSV 'gpo-linkage.csv') -NoTypeInformation
    }

    # HTML reports -- per-GPO HTML + clickable index
    if ($OutputPath) {
        $htmlIndex = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($gpo in $allGPOs) {
            try {
                $safeName = $gpo.DisplayName -replace '[\\/:*?"<>|]', '_'
                Get-GPOReport -Guid $gpo.Id -ReportType Html -Path (Join-Path $paths.HTML "$safeName.html") @splatAD
                $htmlIndex.Add([PSCustomObject]@{ DisplayName = $gpo.DisplayName; FileName = "$safeName.html"; GUID = $gpo.Id })
            } catch { $warnings.Add("HTMLReport($($gpo.DisplayName)): $_") }
        }
        $indexRows = ($htmlIndex | ForEach-Object {
            "<tr><td>$($_.DisplayName)</td><td style='font-family:monospace'>$($_.GUID)</td><td><a href='$($_.FileName)'>View</a></td></tr>"
        }) -join "`n"
        $style = 'body{font-family:Segoe UI,sans-serif;margin:20px}table{border-collapse:collapse;width:100%}th{background:#0078d4;color:white;padding:12px;text-align:left}td{padding:10px;border-bottom:1px solid #ddd}tr:hover{background:#f1f1f1}a{color:#0078d4}'
        $indexHtml = "<!DOCTYPE html><html><head><title>GPO Audit Index</title><style>$style</style></head>" +
            "<body><h1>GPO Audit Index</h1><p>Total GPOs: $($allGPOs.Count) | Generated: $timestamp</p>" +
            "<table><thead><tr><th>GPO Name</th><th>GUID</th><th>Report</th></tr></thead><tbody>" +
            "$indexRows</tbody></table></body></html>"
        $indexHtml | Out-File -FilePath (Join-Path $paths.HTML '00-INDEX.html') -Encoding UTF8
    }

    # XML backup -- restore-ready via Backup-GPO
    if ($OutputPath) {
        try { Backup-GPO -All -Path $paths.XML @splatAD | Out-Null } catch { $warnings.Add("XMLBackup: $_") }
    }

    # Permission analysis (when -IncludePermissions)
    $overpermCount = $null
    if ($IncludePermissions) {
        $permittedEditors = Get-MonarchConfigValue 'PermittedGPOEditors'
        $permReport = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($gpo in $allGPOs) {
            try {
                $perms = @(Get-GPPermission -Guid $gpo.Id -All @splatAD)
                foreach ($perm in $perms) {
                    $permReport.Add([PSCustomObject]@{
                        GPOName    = $gpo.DisplayName
                        Trustee    = $perm.Trustee.Name
                        TrusteeSID = $perm.Trustee.Sid
                        Permission = $perm.Permission
                        Inherited  = $perm.Inherited
                        Denied     = $perm.Denied
                    })
                }
            } catch { $warnings.Add("Permissions($($gpo.DisplayName)): $_") }
        }
        if ($OutputPath -and $permReport.Count -gt 0) {
            $permReport | Export-Csv -Path (Join-Path $paths.Permissions 'gpo-permissions.csv') -NoTypeInformation
        }
        $suspects = @($permReport | Where-Object { $_.Permission -like '*Edit*' -and $_.Trustee -notin $permittedEditors -and -not $_.Denied })
        $overpermCount = $suspects.Count
        if ($OutputPath -and $suspects.Count -gt 0) {
            $suspects | Export-Csv -Path (Join-Path $paths.Permissions 'REVIEW-overpermissioned-gpos.csv') -NoTypeInformation
        }
    }

    # WMI filter export (when -IncludeWMIFilters)
    if ($IncludeWMIFilters) {
        try {
            $wmiFilters = @(Get-ADObject -Filter "objectClass -eq 'msWMI-Som'" -Properties 'msWMI-Name', 'msWMI-Parm2', 'whenCreated', 'whenChanged' @splatAD)
            if ($wmiFilters.Count -gt 0 -and $OutputPath) {
                $wmiFilters | ForEach-Object {
                    [PSCustomObject]@{ Name = $_.'msWMI-Name'; Query = $_.'msWMI-Parm2'; Created = $_.whenCreated; Modified = $_.whenChanged }
                } | Export-Csv -Path (Join-Path $paths.WMI 'wmi-filters.csv') -NoTypeInformation
            }
        } catch { $warnings.Add("WMIFilters: $_") }
    }

    $unlinkedCount = @($linkageDetails | Where-Object LinkedTo -eq '**UNLINKED**').Count
    $disabledCount = @($allGPOs | Where-Object { -not $_.User.Enabled -and -not $_.Computer.Enabled }).Count
    $hrUserRights  = @($gpoSummary | Where-Object HasUserRights).Count
    $hrSecOpts     = @($gpoSummary | Where-Object HasSecurityOptions).Count
    $hrScripts     = @($gpoSummary | Where-Object HasScripts).Count
    $hrSoftware    = @($gpoSummary | Where-Object HasSoftwareInstall).Count

    if ($OutputPath) {
        $summaryText = "GROUP POLICY AUDIT SUMMARY`n" +
            "Domain Audit Date: $timestamp`n" +
            "Total GPOs: $($allGPOs.Count)`n" +
            "Unlinked GPOs: $unlinkedCount`n" +
            "Disabled GPOs: $disabledCount`n" +
            "High-Risk: UserRights=$hrUserRights, SecurityOptions=$hrSecOpts, Scripts=$hrScripts, SoftwareInstall=$hrSoftware"
        $summaryText | Out-File -FilePath (Join-Path $paths.Summary 'EXECUTIVE-SUMMARY.txt') -Encoding UTF8
    }

    [PSCustomObject]@{
        Domain                = 'GroupPolicy'
        Function              = 'Export-GPOAudit'
        Timestamp             = $timestamp
        TotalGPOs             = $allGPOs.Count
        UnlinkedCount         = $unlinkedCount
        DisabledCount         = $disabledCount
        HighRiskCounts        = [PSCustomObject]@{
            UserRights      = $hrUserRights
            SecurityOptions = $hrSecOpts
            Scripts         = $hrScripts
            SoftwareInstall = $hrSoftware
        }
        OverpermissionedCount = $overpermCount
        OutputPaths           = [PSCustomObject]@{
            Summary     = $paths.Summary
            HTML        = $paths.HTML
            XML         = $paths.XML
            CSV         = $paths.CSV
            Permissions = if ($IncludePermissions) { $paths.Permissions } else { $null }
            WMI         = if ($IncludeWMIFilters) { $paths.WMI } else { $null }
        }
        Warnings              = @($warnings)
    }
}

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
                "Review each account before adding -- blanket addition will break service authentication."
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

function Get-BackupReadinessStatus {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    # Tier 1 -- Universal (always runs)
    $tombstoneLifetime = 180
    try {
        $rootDSE = Get-ADRootDSE @splatAD
        $dsConfigDN = "CN=Directory Service,CN=Windows NT,CN=Services,$($rootDSE.configurationNamingContext)"
        $dsConfig = Get-ADObject -Identity $dsConfigDN -Properties tombstoneLifetime @splatAD
        if ($dsConfig.tombstoneLifetime) { $tombstoneLifetime = $dsConfig.tombstoneLifetime }
    } catch { $warnings.Add("TombstoneLookup: $_") }

    $recycleBinEnabled = $false
    try {
        $feature = Get-ADOptionalFeature -Filter "name -like 'Recycle Bin Feature'" @splatAD
        $recycleBinEnabled = [bool]($feature.EnabledScopes -and @($feature.EnabledScopes).Count -gt 0)
    } catch { $warnings.Add("RecycleBin: $_") }

    $detectionTier = 1
    $backupTool = $null
    $backupToolSource = $null
    $lastBackupAge = $null
    $backupAgeSource = $null

    # Tier 2 -- Windows Server Backup
    $splatDC = if ($Server) { @{ ComputerName = $Server } } else { @{} }
    try {
        $wsbService = Get-Service -Name 'wbengine' @splatDC -ErrorAction SilentlyContinue
        if ($wsbService) {
            $backupTool = 'Windows Server Backup'
            $backupToolSource = 'WSB'
            $detectionTier = 2
        }
    } catch { $warnings.Add("WSBDetection: $_") }

    # Tier 2 -- Third-party vendor detection
    if (-not $backupTool) {
        $knownServices = Get-MonarchConfigValue 'KnownBackupServices'
        foreach ($vendor in $knownServices.Keys) {
            try {
                $svcNames = $knownServices[$vendor]
                $found = Get-Service -Name $svcNames @splatDC -ErrorAction SilentlyContinue |
                    Where-Object Status -eq 'Running'
                if ($found) {
                    $backupTool = $vendor
                    $backupToolSource = 'ServiceEnum'
                    $detectionTier = 2
                    break
                }
            } catch { $warnings.Add("VendorDetection($vendor): $_") }
        }
    }

    # Tier 3 -- Vendor-specific integration (opt-in)
    $integration = Get-MonarchConfigValue 'BackupIntegration'
    if ($integration) {
        $detectionTier = 3
        $backupAgeSource = 'VendorIntegration'
        try {
            $backupDate = switch ($integration.Type) {
                'VeeamModule' {
                    $mod = Import-Module $integration.ModuleName -PassThru -ErrorAction Stop
                    $session = Get-VBRBackupSession -Name '*' | Sort-Object EndTime -Descending | Select-Object -First 1
                    $session.EndTime
                }
                'Registry' {
                    $regVal = Get-ItemProperty -Path $integration.RegistryKey -Name $integration.RegistryValue -ErrorAction Stop
                    [datetime]$regVal.($integration.RegistryValue)
                }
                'CLI' {
                    $output = & $integration.CLIPath $integration.CLIArgs 2>&1
                    [datetime]$output
                }
                default { $null }
            }
            if ($backupDate) {
                $lastBackupAge = $timestamp - $backupDate
            }
        } catch { $warnings.Add("Tier3Integration($($integration.Type)): $_") }
    }

    # Status classification
    $criticalGap = $false
    $status = 'Unknown'
    $hint = if ($backupTool) {
        "$backupTool detected -- configure vendor integration in Monarch-Config.psd1 for automatic last-backup detection."
    } else {
        'No backup tool detected. Verify backup solution is installed on this domain controller.'
    }

    if ($lastBackupAge) {
        if ($lastBackupAge.TotalDays -gt $tombstoneLifetime) {
            $criticalGap = $true
            $status = 'Degraded'
            $hint = "Last backup is older than tombstone lifetime ($([int]$lastBackupAge.TotalDays) days vs $tombstoneLifetime day limit) -- recovery from this backup may cause USN rollback. Verify replication state before attempting any restore operation."
        } else {
            $status = 'Healthy'
            $hint = "Backup age ($([int]$lastBackupAge.TotalDays) days) is within tombstone lifetime ($tombstoneLifetime days)."
        }
    }

    [PSCustomObject]@{
        Domain                = 'BackupReadiness'
        Function              = 'Get-BackupReadinessStatus'
        Timestamp             = $timestamp
        TombstoneLifetimeDays = $tombstoneLifetime
        RecycleBinEnabled     = $recycleBinEnabled
        BackupToolDetected    = $backupTool
        BackupToolSource      = $backupToolSource
        LastBackupAge         = $lastBackupAge
        BackupAgeSource       = $backupAgeSource
        DetectionTier         = $detectionTier
        CriticalGap           = $criticalGap
        Status                = $status
        DiagnosticHint        = $hint
        Warnings              = @($warnings)
    }
}

function Test-TombstoneGap {
    [CmdletBinding()]
    param(
        [string]$Server,
        [int]$BackupAgeDays
    )

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }

    $tombstoneLifetime = 180
    try {
        $rootDSE = Get-ADRootDSE @splatAD
        $dsConfigDN = "CN=Directory Service,CN=Windows NT,CN=Services,$($rootDSE.configurationNamingContext)"
        $dsConfig = Get-ADObject -Identity $dsConfigDN -Properties tombstoneLifetime @splatAD
        if ($dsConfig.tombstoneLifetime) { $tombstoneLifetime = $dsConfig.tombstoneLifetime }
    } catch { $warnings.Add("TombstoneLookup: $_") }

    $criticalGap = $null
    $hint = 'Backup age not provided -- supply -BackupAgeDays for gap analysis.'
    if ($PSBoundParameters.ContainsKey('BackupAgeDays')) {
        $criticalGap = $BackupAgeDays -gt $tombstoneLifetime
        $hint = if ($criticalGap) {
            "Last backup ($BackupAgeDays days) exceeds tombstone lifetime ($tombstoneLifetime days) -- recovery may cause USN rollback."
        } else {
            "Backup age ($BackupAgeDays days) is within tombstone lifetime ($tombstoneLifetime days)."
        }
    }

    [PSCustomObject]@{
        Domain                = 'BackupReadiness'
        Function              = 'Test-TombstoneGap'
        Timestamp             = $timestamp
        TombstoneLifetimeDays = $tombstoneLifetime
        BackupAgeDays         = if ($PSBoundParameters.ContainsKey('BackupAgeDays')) { $BackupAgeDays } else { $null }
        CriticalGap           = $criticalGap
        DiagnosticHint        = $hint
        Warnings              = @($warnings)
    }
}

#endregion Backup and Recovery

#region Audit and Compliance
# Domain baselines, audit policy config, event log config.
# All Discovery phase except Compare-DomainBaseline (Plan 4).

function New-DomainBaseline
{
    <#
    .SYNOPSIS
        Comprehensive domain snapshot -- functional levels, DCs, FSMO, OUs, object counts, password policy.
    .DESCRIPTION
        Collects baseline data across seven sections. Each section is independent  --
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
        $warnings.Add('FSMORoles: skipped -- Domain/Forest data unavailable.')
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

function Get-AuditPolicyConfiguration {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }
    $dcResults = @()

    try {
        $dcs = @(Get-ADDomainController -Filter '*' @splatAD)
    } catch {
        $warnings.Add("DCDiscovery: $_")
        $dcs = @()
    }

    foreach ($dc in $dcs) {
        try {
            $csvOutput = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                auditpol /get /category:* /r
            } -ErrorAction Stop
            $parsed = $csvOutput | ConvertFrom-Csv
            $categories = @($parsed | ForEach-Object {
                [PSCustomObject]@{
                    Category    = $_.'Policy Target'
                    Subcategory = $_.'Subcategory'
                    Setting     = $_.'Inclusion Setting'
                }
            })
            $dcResults += [PSCustomObject]@{
                DCName     = $dc.HostName
                Categories = $categories
            }
        } catch { $warnings.Add("AuditPolicy($($dc.HostName)): $_") }
    }

    $consistent = ($dcResults.Count -le 1) -or (
        @($dcResults | ForEach-Object {
            ($_.Categories | Sort-Object Subcategory | ForEach-Object { "$($_.Subcategory)=$($_.Setting)" }) -join ';'
        } | Sort-Object -Unique).Count -eq 1
    )

    [PSCustomObject]@{
        Domain     = 'AuditCompliance'
        Function   = 'Get-AuditPolicyConfiguration'
        Timestamp  = $timestamp
        DCs        = @($dcResults)
        Consistent = $consistent
        Warnings   = @($warnings)
    }
}

function Get-EventLogConfiguration {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }
    $dcResults = @()
    $logNames = @('Security', 'System', 'Directory Service')

    try {
        $dcs = @(Get-ADDomainController -Filter '*' @splatAD)
    } catch {
        $warnings.Add("DCDiscovery: $_")
        $dcs = @()
    }

    foreach ($dc in $dcs) {
        try {
            $logs = @()
            $logData = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                param($Names)
                foreach ($name in $Names) {
                    Get-WinEvent -ListLog $name -ErrorAction SilentlyContinue
                }
            } -ArgumentList (,$logNames) -ErrorAction Stop

            foreach ($log in $logData) {
                $logs += [PSCustomObject]@{
                    LogName        = $log.LogName
                    MaxSizeKB      = [int]($log.MaximumSizeInBytes / 1024)
                    OverflowAction = [string]$log.LogMode
                }
            }
            $dcResults += [PSCustomObject]@{
                DCName = $dc.HostName
                Logs   = @($logs)
            }
        } catch { $warnings.Add("EventLog($($dc.HostName)): $_") }
    }

    [PSCustomObject]@{
        Domain    = 'AuditCompliance'
        Function  = 'Get-EventLogConfiguration'
        Timestamp = $timestamp
        DCs       = @($dcResults)
        Warnings  = @($warnings)
    }
}

#endregion Audit and Compliance

#region DNS
# AD-integrated DNS zone health and configuration.
# All Discovery phase. Requires DnsServer module (optional, checked at runtime).

function Test-SRVRecordCompleteness {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }
    $siteResults = @()

    # DNS module gate -- all DNS functions require DnsServer module
    if (-not (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue)) {
        $warnings.Add('DnsServer module not available -- SRV record check skipped.')
    } else {
        $requiredPrefixes = @('_ldap._tcp', '_kerberos._tcp', '_kpasswd._tcp', '_gc._tcp')
        try {
            $domain = (Get-ADDomain @splatAD).DNSRoot
            $sites = @(Get-ADReplicationSite -Filter '*' @splatAD)
        } catch {
            $warnings.Add("SiteDiscovery: $_")
            $sites = @()
        }

        foreach ($site in $sites) {
            try {
                $missing = @()
                foreach ($prefix in $requiredPrefixes) {
                    $fqdn = "$prefix.$($site.Name)._sites.dc._msdcs.$domain"
                    $resolved = Resolve-DnsName -Name $fqdn -Type SRV -ErrorAction SilentlyContinue
                    if (-not $resolved) { $missing += $prefix }
                }
                $siteResults += [PSCustomObject]@{
                    SiteName        = $site.Name
                    ExpectedRecords = $requiredPrefixes.Count
                    FoundRecords    = $requiredPrefixes.Count - $missing.Count
                    MissingRecords  = @($missing)
                }
            } catch { $warnings.Add("SRVCheck($($site.Name)): $_") }
        }
    }

    [PSCustomObject]@{
        Domain      = 'DNS'
        Function    = 'Test-SRVRecordCompleteness'
        Timestamp   = $timestamp
        Sites       = @($siteResults)
        AllComplete = ($siteResults.Count -gt 0 -and @($siteResults | Where-Object { $_.MissingRecords.Count -gt 0 }).Count -eq 0)
        Warnings    = @($warnings)
    }
}

function Get-DNSScavengingConfiguration {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatDNS = if ($Server) { @{ ComputerName = $Server } } else { @{} }
    $zoneResults = @()

    if (-not (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue)) {
        $warnings.Add('DnsServer module not available -- scavenging check skipped.')
    } else {
        try {
            $zones = @(Get-DnsServerZone @splatDNS | Where-Object { $_.IsDsIntegrated -and -not $_.IsAutoCreated })
        } catch {
            $warnings.Add("ZoneEnumeration: $_")
            $zones = @()
        }

        foreach ($zone in $zones) {
            try {
                $aging = Get-DnsServerZoneAging -Name $zone.ZoneName @splatDNS
                $zoneResults += [PSCustomObject]@{
                    ZoneName          = $zone.ZoneName
                    ScavengingEnabled = [bool]$aging.AgingEnabled
                    NoRefreshInterval = $aging.NoRefreshInterval
                    RefreshInterval   = $aging.RefreshInterval
                }
            } catch { $warnings.Add("ZoneAging($($zone.ZoneName)): $_") }
        }
    }

    [PSCustomObject]@{
        Domain    = 'DNS'
        Function  = 'Get-DNSScavengingConfiguration'
        Timestamp = $timestamp
        Zones     = @($zoneResults)
        Warnings  = @($warnings)
    }
}

function Test-ZoneReplicationScope {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatDNS = if ($Server) { @{ ComputerName = $Server } } else { @{} }
    $zoneResults = @()

    if (-not (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue)) {
        $warnings.Add('DnsServer module not available -- zone replication check skipped.')
    } else {
        try {
            $zones = @(Get-DnsServerZone @splatDNS | Where-Object { -not $_.IsAutoCreated })
        } catch {
            $warnings.Add("ZoneEnumeration: $_")
            $zones = @()
        }

        foreach ($zone in $zones) {
            try {
                $zoneResults += [PSCustomObject]@{
                    ZoneName         = $zone.ZoneName
                    IsDsIntegrated   = [bool]$zone.IsDsIntegrated
                    ReplicationScope = if ($zone.IsDsIntegrated) { [string]$zone.DirectoryPartitionName } else { $null }
                    ZoneType         = [string]$zone.ZoneType
                }
            } catch { $warnings.Add("ZoneScope($($zone.ZoneName)): $_") }
        }
    }

    [PSCustomObject]@{
        Domain    = 'DNS'
        Function  = 'Test-ZoneReplicationScope'
        Timestamp = $timestamp
        Zones     = @($zoneResults)
        Warnings  = @($warnings)
    }
}

function Get-DNSForwarderConfiguration {
    [CmdletBinding()]
    param([string]$Server)

    $timestamp = Get-Date
    $warnings = [System.Collections.Generic.List[string]]::new()
    $splatAD = if ($Server) { @{ Server = $Server } } else { @{} }
    $dcForwarders = @()

    if (-not (Get-Command Get-DnsServerZone -ErrorAction SilentlyContinue)) {
        $warnings.Add('DnsServer module not available -- forwarder check skipped.')
    } else {
        try {
            $dcs = @(Get-ADDomainController -Filter '*' @splatAD)
        } catch {
            $warnings.Add("DCDiscovery: $_")
            $dcs = @()
        }

        foreach ($dc in $dcs) {
            try {
                $fwd = Get-DnsServerForwarder -ComputerName $dc.HostName
                $dcForwarders += [PSCustomObject]@{
                    DCName       = $dc.HostName
                    Forwarders   = @([string[]]$fwd.IPAddress)
                    UseRootHints = if ($fwd.PSObject.Properties['UseRootHints']) { [bool]$fwd.UseRootHints } else { $null }
                }
            } catch { $warnings.Add("Forwarder($($dc.HostName)): $_") }
        }
    }

    $consistent = ($dcForwarders.Count -le 1) -or (
        @($dcForwarders | ForEach-Object { ($_.Forwarders | Sort-Object) -join ',' } | Sort-Object -Unique).Count -eq 1
    )

    [PSCustomObject]@{
        Domain       = 'DNS'
        Function     = 'Get-DNSForwarderConfiguration'
        Timestamp    = $timestamp
        DCForwarders = @($dcForwarders)
        Consistent   = $consistent
        Warnings     = @($warnings)
    }
}

#endregion DNS

#region Reporting
# Generates human-readable reports from structured Discovery results.

function New-MonarchReport
{
    <#
    .SYNOPSIS
        Generates a single-page HTML Discovery report from orchestrator results.
    .PARAMETER Results
        Orchestrator return object (Phase, Domain, DCUsed, StartTime, EndTime, Results, Failures).
    .PARAMETER OutputPath
        Directory to write the report file.
    .PARAMETER Format
        Output format. Currently only 'HTML' is supported.
    #>
    [CmdletBinding()]
    param(
        [PSCustomObject]$Results,
        [string]$OutputPath,
        [string]$Format = 'HTML'
    )

    Write-Host "report: generating discovery report..." -ForegroundColor DarkGray
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $reportFile = Join-Path $OutputPath '00-Discovery-Report.html'

    # Config-driven accent color
    $accent = Get-MonarchConfigValue -Key 'ReportAccentPrimary'
    if (-not $accent) { $accent = '#2E5090' }

    # Null results -- minimal report
    if (-not $Results) {
        $html = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><title>Discovery Report</title></head>" +
            "<body><p>No data available.</p></body></html>"
        $html | Out-File -FilePath $reportFile -Encoding UTF8
        return $reportFile
    }

    # Extract header data
    Write-Host "report: extracting header and duration..." -ForegroundColor DarkGray
    $domain = $Results.Domain
    $dc = if ($Results.DCUsed -is [string]) { $Results.DCUsed } else { $Results.DCUsed.DCName }
    $startTime = $Results.StartTime
    $duration = if ($Results.StartTime -and $Results.EndTime) {
        $span = $Results.EndTime - $Results.StartTime
        if ($span.TotalMinutes -ge 1) { "$([math]::Round($span.TotalMinutes)) minutes" } else { "$([math]::Round($span.TotalSeconds)) seconds" }
    } else { 'N/A' }
    $dateStr = if ($startTime) { $startTime.ToString('MMMM d, yyyy HH:mm') } else { (Get-Date).ToString('MMMM d, yyyy HH:mm') }
    $resultsList = @($Results.Results)
    $failures = @($Results.Failures)
    $functionCount = $resultsList.Count
    $errorCount = $failures.Count

    # Disposition data -- from orchestrator or synthesized for backward compat
    $dispositions = [System.Collections.Generic.List[PSCustomObject]]::new()
    $dispProp = $Results.PSObject.Properties['Dispositions']
    if ($dispProp -and $dispProp.Value) {
        foreach ($dd in @($dispProp.Value)) { $dispositions.Add($dd) }
    }
    if ($dispositions.Count -eq 0) {
        foreach ($r in $resultsList) {
            $dispositions.Add([PSCustomObject]@{ Function = $r.Function; Domain = $r.Domain; Disposition = 'Assessed'; Error = $null })
        }
        foreach ($f in $failures) {
            $dispositions.Add([PSCustomObject]@{ Function = $f.Function; Domain = $null; Disposition = 'NotAssessed'; Error = $f.Error })
        }
    }
    $totalChecks = $functionCount + $errorCount
    $tcProp = $Results.PSObject.Properties['TotalChecks']
    if ($tcProp -and $tcProp.Value) { $totalChecks = $tcProp.Value }
    $assessedCount = @($dispositions | Where-Object { $_.Disposition -eq 'Assessed' }).Count

    # Per-domain check counts for section headers
    $domainCheckCounts = @{}
    foreach ($d in $dispositions) {
        if (-not $d.Domain) { continue }
        if (-not $domainCheckCounts.ContainsKey($d.Domain)) { $domainCheckCounts[$d.Domain] = @{ Assessed = 0; Total = 0 } }
        $domainCheckCounts[$d.Domain].Total++
        if ($d.Disposition -eq 'Assessed') { $domainCheckCounts[$d.Domain].Assessed++ }
    }

    # Not-assessed functions grouped by domain
    $notAssessedDomains = @{}
    foreach ($d in $dispositions | Where-Object { $_.Disposition -eq 'NotAssessed' }) {
        if (-not $d.Domain) { continue }
        if (-not $notAssessedDomains.ContainsKey($d.Domain)) {
            $notAssessedDomains[$d.Domain] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        $notAssessedDomains[$d.Domain].Add($d)
    }
    # Domain-less not-assessed (backward compat only)
    $domainlessNotAssessed = @($dispositions | Where-Object { $_.Disposition -eq 'NotAssessed' -and -not $_.Domain })

    # Domain display name mapping
    $domainNames = @{
        'BackupReadiness'      = 'Backup &amp; Recovery'
        'InfrastructureHealth' = 'Infrastructure Health'
        'PrivilegedAccess'     = 'Privileged Access'
        'IdentityLifecycle'    = 'Identity Lifecycle'
        'GroupPolicy'          = 'Group Policy'
        'SecurityPosture'      = 'Security Posture'
        'AuditCompliance'      = 'Audit &amp; Compliance'
        'DNS'                  = 'DNS'
    }

    # Domain priority ordering for sections with findings
    $domainOrder = @('BackupReadiness','InfrastructureHealth','PrivilegedAccess','IdentityLifecycle','GroupPolicy','SecurityPosture','AuditCompliance','DNS')

    # --- Critical findings extraction ---
    Write-Host "report: analyzing findings and building advisories..." -ForegroundColor DarkGray
    $criticals = [System.Collections.Generic.List[PSCustomObject]]::new()
    $advisories = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($r in $resultsList) {
        $dn = if ($domainNames.ContainsKey($r.Domain)) { $domainNames[$r.Domain] } else { $r.Domain }
        switch ($r.Function) {
            'Get-BackupReadinessStatus' {
                if ($r.CriticalGap -eq $true) { $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = 'Backup age exceeds tombstone lifetime -- USN rollback risk' }) }
                if ($r.DetectionTier -eq 1 -and $null -eq $r.BackupToolDetected) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = 'No backup tool detected -- verify backup coverage manually' }) }
            }
            'Get-ReplicationHealth' {
                if ($r.FailedLinkCount -gt 0) { $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.FailedLinkCount) replication links failing" }) }
                if ($r.WarningLinkCount -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.WarningLinkCount) replication links approaching threshold" }) }
            }
            'Get-PrivilegedGroupMembership' {
                if ($r.DomainAdminStatus -eq 'Critical') { $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "Domain Admin count exceeds critical threshold ($($r.DomainAdminCount) members)" }) }
                if ($r.DomainAdminStatus -eq 'Warning') { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "Domain Admin count exceeds warning threshold ($($r.DomainAdminCount) members)" }) }
            }
            'Find-DormantAccount' {
                if ($r.TotalCount -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.TotalCount) dormant accounts ($($r.ThresholdDays)-day threshold, $($r.ExcludedCount) excluded)" }) }
            }
            'Get-SiteTopology' {
                if ($r.UnassignedSubnets.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.UnassignedSubnets.Count) subnets not assigned to any site" }) }
                if ($r.EmptySites.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.EmptySites.Count) sites with no domain controllers" }) }
            }
            'Test-SRVRecordCompleteness' {
                if ($r.AllComplete -eq $false) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "Missing SRV records in $(@($r.Sites | Where-Object { $_.MissingRecords.Count -gt 0 }).Count) sites" }) }
            }
            'Get-AuditPolicyConfiguration' {
                if ($r.Consistent -eq $false) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = 'Audit policy inconsistent across domain controllers' }) }
            }
            'Get-DNSForwarderConfiguration' {
                if ($r.Consistent -eq $false) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = 'DNS forwarder configuration inconsistent across DCs' }) }
            }
            'Find-KerberoastableAccount' {
                if ($r.PrivilegedCount -gt 0) { $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.PrivilegedCount) privileged accounts with SPNs (Kerberoasting risk -- privileged)" }) }
                if ($r.TotalCount -gt 0 -and $r.PrivilegedCount -eq 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.TotalCount) accounts with SPNs — 0 privileged" }) }
            }
            'Test-ProtectedUsersGap' {
                if ($r.GapAccounts.Count -gt 0) {
                    $privGrpResult = $resultsList | Where-Object { $_.Function -eq 'Get-PrivilegedGroupMembership' } | Select-Object -First 1
                    $gapDesc = "$($r.GapAccounts.Count) privileged accounts not in Protected Users"
                    if ($privGrpResult -and $privGrpResult.Groups) {
                        $daGrp = $privGrpResult.Groups | Where-Object { $_.GroupSID -like '*-512' }
                        $eaGrp = $privGrpResult.Groups | Where-Object { $_.GroupSID -like '*-519' }
                        $daCount = if ($daGrp) { $daGrp.MemberCount } else { 0 }
                        $eaCount = if ($eaGrp) { $eaGrp.MemberCount } else { 0 }
                        $gapDesc += " — includes $daCount DAs, $eaCount EAs"
                    }
                    $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = $gapDesc })
                }
            }
            'Find-AdminCountOrphan' {
                if ($r.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.Count) AdminCount orphans (stale privilege markers)" }) }
            }
            'Export-GPOAudit' {
                if ($r.UnlinkedCount -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.UnlinkedCount) unlinked (orphaned) GPOs" }) }
            }
            'Find-ASREPRoastableAccount' {
                if ($r.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.Count) accounts with Kerberos pre-auth disabled (AS-REP roasting risk)" }) }
            }
            'Find-WeakAccountFlag' {
                if ($r.CountByFlag.ContainsKey('ReversibleEncryption') -or $r.CountByFlag.ContainsKey('DESOnly')) {
                    $desc = @()
                    if ($r.CountByFlag.ContainsKey('ReversibleEncryption')) { $desc += "$($r.CountByFlag['ReversibleEncryption']) with reversible encryption" }
                    if ($r.CountByFlag.ContainsKey('DESOnly')) { $desc += "$($r.CountByFlag['DESOnly']) with DES-only Kerberos" }
                    $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = ($desc -join ', ') })
                }
                if ($r.Findings.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.Findings.Count) accounts with weak security flags" }) }
            }
            'Find-LegacyProtocolExposure' {
                $highRisk = @($r.DCFindings | Where-Object { $_.Risk -eq 'High' })
                if ($highRisk.Count -gt 0) { $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($highRisk.Count) high-risk legacy protocol findings (NTLMv1/LM hash)" }) }
                $medRisk = @($r.DCFindings | Where-Object { $_.Risk -eq 'Medium' })
                if ($medRisk.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($medRisk.Count) legacy protocol findings on DCs" }) }
            }
            'Find-GPOPermissionAnomaly' {
                if ($r.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.Count) GPOs with non-standard editors" }) }
            }
            'Get-PasswordPolicyInventory' {
                $minLen = Get-MonarchConfigValue -Key 'MinPasswordLength'
                $reqLockout = Get-MonarchConfigValue -Key 'RequireLockoutThreshold'
                $dp = $r.DefaultPolicy
                if ($null -ne $dp) {
                    if ($dp.ReversibleEncryption -eq $true) { $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = 'Default domain policy stores passwords with reversible encryption' }) }
                    $issues = @()
                    if ($dp.MinLength -lt $minLen) { $issues += "minimum length $($dp.MinLength) (recommended $minLen)" }
                    if ($dp.ComplexityEnabled -eq $false) { $issues += 'complexity requirements disabled' }
                    if ($reqLockout -and $dp.LockoutThreshold -eq 0) { $issues += 'no account lockout threshold' }
                    if ($issues.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "Default password policy: $($issues -join '; ')" }) }
                }
            }
            'Get-DNSScavengingConfiguration' {
                $reqScav = Get-MonarchConfigValue -Key 'RequireDNSScavenging'
                if ($reqScav) {
                    $stale = @($r.Zones | Where-Object { $_.ScavengingEnabled -eq $false })
                    if ($stale.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($stale.Count) DNS zones with scavenging disabled" }) }
                }
            }
            'Get-EventLogConfiguration' {
                $minSize = Get-MonarchConfigValue -Key 'MinSecurityLogSizeKB'
                $okActions = Get-MonarchConfigValue -Key 'AcceptableOverflowActions'
                $dcSummaries = @()
                foreach ($dc in $r.DCs) {
                    $secLog = $dc.Logs | Where-Object { $_.LogName -eq 'Security' }
                    if ($null -ne $secLog) {
                        $tags = @()
                        if ($secLog.MaxSizeKB -lt $minSize) { $tags += 'undersized' }
                        if ($secLog.OverflowAction -notin $okActions) { $tags += 'overflow action' }
                        if ($tags.Count -gt 0) { $dcSummaries += "$($dc.DCName) ($($tags -join ', '))" }
                    }
                }
                if ($dcSummaries.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "Security log: $($dcSummaries -join ', ')" }) }
            }
            'Test-ZoneReplicationScope' {
                $reqDS = Get-MonarchConfigValue -Key 'RequireDSIntegration'
                if ($reqDS) {
                    $nonDS = @($r.Zones | Where-Object { $_.IsDsIntegrated -eq $false })
                    if ($nonDS.Count -gt 0) { $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($nonDS.Count) DNS zones not AD-integrated" }) }
                }
            }
            'Get-FSMORolePlacement' {
                if ($r.UnreachableCount -gt 0) { $criticals.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = "$($r.UnreachableCount) FSMO role holders unreachable" }) }
                if ($r.AllOnOneDC -eq $true) {
                    $fsmoDesc = if ($r.Roles -and $r.Roles.Count -gt 0) { "All FSMO roles held by $($r.Roles[0].Holder)" } else { 'All FSMO roles held by a single DC' }
                    $advisories.Add([PSCustomObject]@{ Domain = $r.Domain; DisplayDomain = $dn; Description = $fsmoDesc })
                }
            }
        }
    }

    $criticalCount = $criticals.Count
    $advisoryCount = $advisories.Count

    # --- CSS from design system ---
    $css = ":root{--accent-primary:${accent};--severity-critical:#C62828;--severity-critical-light:#FFF5F5;--severity-advisory:#F9A825;--severity-advisory-text:#1A1A1A;" +
        "--bg-page:#FFFFFF;--bg-card:#F8F9FA;--text-1:#1A1A1A;--text-2:#555555;--text-3:#888888;--border-1:#E0E0E0;--border-2:#CCCCCC;" +
        "--gap-micro:4px;--gap-tight:8px;--gap-related:16px;--gap-separate:32px;--t1:30px;--t2:24px;--t3:19px;--t4:15px;--t5:12px;--card-radius:4px}" +
        "*,*::before,*::after{box-sizing:border-box;margin:0;padding:0;line-height:normal}" +
        "html{font-family:'Segoe UI',system-ui,-apple-system,sans-serif;color:var(--text-1);background:var(--bg-page)}" +
        ".container{max-width:960px;margin:0 auto;padding:40px}" +
        ".report-title{font-size:var(--t1);font-weight:600;color:var(--accent-primary);line-height:1.15;margin-bottom:var(--gap-tight)}" +
        ".report-meta{font-size:var(--t5);line-height:1.3;color:var(--text-2);display:flex;flex-wrap:wrap;column-gap:24px;row-gap:var(--gap-micro);margin-bottom:var(--gap-related)}" +
        ".stats{display:flex;flex-wrap:wrap;column-gap:12px;row-gap:var(--gap-tight);padding-bottom:var(--gap-related);margin-bottom:var(--gap-related);border-bottom:2px solid var(--border-2)}" +
        ".stat{display:flex;align-items:center;gap:var(--gap-tight);padding:var(--gap-tight) 20px;border-radius:var(--card-radius)}" +
        ".stat-number{font-size:var(--t2);font-weight:700;line-height:1}" +
        ".stat-label{font-size:var(--t5);line-height:1;text-transform:uppercase;letter-spacing:0.05em;font-weight:600}" +
        ".stat.w-critical{background:var(--severity-critical)}.stat.w-critical .stat-number,.stat.w-critical .stat-label{color:#FFF}" +
        ".stat.w-advisory{background:var(--severity-advisory)}.stat.w-advisory .stat-number,.stat.w-advisory .stat-label{color:var(--severity-advisory-text)}" +
        ".stat.w-outline{border:2px solid var(--border-1)}.stat.w-outline .stat-number{color:var(--text-1)}.stat.w-outline .stat-label{color:var(--text-2)}" +
        ".stat.w-outline.zero .stat-number,.stat.w-outline.zero .stat-label{color:var(--text-3)}" +
        ".section-label{font-size:var(--t5);line-height:1;font-weight:600;text-transform:uppercase;letter-spacing:0.05em;margin-bottom:var(--gap-tight)}" +
        ".section-label.critical{color:var(--severity-critical)}.section-label.neutral{color:var(--text-2)}" +
        ".card{padding:var(--gap-tight) var(--gap-related);margin-bottom:var(--gap-tight)}" +
        ".card.w-critical{border-left:4px solid var(--severity-critical);background:var(--severity-critical-light)}" +
        ".card.w-advisory{border-left:3px solid var(--severity-advisory)}.card.w-neutral{border-left:3px solid var(--border-2)}" +
        ".card .domain-tag{font-size:var(--t5);line-height:1;color:var(--text-2);text-transform:uppercase;letter-spacing:0.04em;margin-bottom:var(--gap-micro)}" +
        ".card .description{font-size:var(--t4);line-height:1.35;font-weight:500}" +
        ".card .action-hint{font-size:var(--t5);line-height:1.4;color:var(--text-2);margin-top:var(--gap-micro)}" +
        ".card .adv-label{font-size:var(--t5);line-height:1;font-weight:600;text-transform:uppercase;letter-spacing:0.04em;color:var(--text-2);margin-bottom:var(--gap-micro)}" +
        ".critical-section{margin-bottom:var(--gap-separate)}" +
        ".domain-section{border-top:1px solid var(--border-1);padding-top:var(--gap-tight);margin-top:calc(var(--gap-separate) - var(--gap-tight))}" +
        ".domain-section h2{font-size:var(--t3);line-height:1.2;font-weight:600;color:var(--accent-primary);margin-bottom:var(--gap-tight)}" +
        ".domain-metrics{display:flex;flex-wrap:wrap;column-gap:24px;row-gap:var(--gap-micro);font-size:var(--t4);line-height:1.3;margin-bottom:var(--gap-related)}" +
        ".domain-metric{color:var(--text-1)}.domain-metric strong{font-weight:600}" +
        ".clean-domains{color:var(--text-3);font-size:var(--t4);line-height:1.3;padding:var(--gap-related) 0;border-top:1px solid var(--border-1);margin-top:var(--gap-related)}" +
        ".failures-section{margin-top:var(--gap-separate);border-top:2px solid var(--border-1);padding-top:var(--gap-related)}" +
        ".failure-item{font-family:'Cascadia Code','Consolas',monospace;font-size:var(--t5);line-height:1.4}" +
        ".failure-item .fn-name{font-weight:600;color:var(--text-1)}.failure-item .fn-error{color:var(--text-2);margin-top:var(--gap-micro)}" +
        ".card .fn-name{font-weight:600;font-size:var(--t5);color:var(--text-1);margin-bottom:var(--gap-micro)}" +
        ".card .fn-error{font-size:var(--t5);color:var(--text-2)}" +
        ".check-count{font-size:var(--t5);font-weight:400;color:var(--text-3);margin-left:8px}" +
        ".output-section{margin-top:var(--gap-separate);border-top:2px solid var(--border-1);padding-top:var(--gap-related)}" +
        ".file-tree{font-family:'Cascadia Code','Consolas',monospace;font-size:var(--t5);margin-top:var(--gap-tight)}" +
        ".file-tree .group{margin-bottom:var(--gap-related)}.file-tree .group:last-child{margin-bottom:0}" +
        ".file-tree .folder{font-weight:600;color:var(--text-1);text-decoration:none;display:block;line-height:1.3;margin-bottom:var(--gap-micro)}" +
        ".file-tree .tree-item{color:var(--text-2);line-height:1.8;position:relative}.file-tree .tree-item::before{content:'\2500 ';color:var(--text-3)}" +
        ".file-tree a.folder:hover{color:var(--accent-primary);text-decoration:underline}" +
        ".file-tree .tree-item a{color:var(--accent-primary);text-decoration:none}.file-tree .tree-item a:hover{text-decoration:underline}" +
        ".report-footer{margin-top:calc(var(--gap-separate) + var(--gap-related));padding-top:var(--gap-related);border-top:1px solid var(--border-1);" +
        "font-size:var(--t5);line-height:1;color:var(--text-3);display:flex;flex-wrap:wrap;justify-content:space-between;column-gap:var(--gap-related);row-gap:var(--gap-micro)}" +
        "@media(max-width:600px){.container{padding:var(--gap-related)}}" +
        "@media print{body{max-width:100%}.container{padding:var(--gap-related);max-width:100%}" +
        ".stat{border:1px solid #999;background:none!important}.stat .stat-number,.stat .stat-label{color:#000!important}" +
        ".stat.w-critical{border-left:4px solid #000}.stat.w-advisory{border-left:4px solid #666}" +
        ".card.w-critical{border-left:4px solid #000;background:none}.card.w-advisory{border-left:3px solid #666;background:none}" +
        ".card.w-neutral{border-left:3px solid #999;background:none}a{color:#000;text-decoration:none}" +
        "h2{page-break-after:avoid}.domain-section{page-break-inside:avoid}summary{list-style:none}summary::-webkit-details-marker{display:none}" +
        ".file-tree a::after{content:' (' attr(href) ')';font-size:9pt;color:#666}}"

    # --- Assemble HTML ---
    $html = "<!DOCTYPE html><html lang='en'><head><meta charset='UTF-8'><meta name='viewport' content='width=device-width,initial-scale=1.0'>" +
        "<title>Discovery Report -- $domain</title><style>$css</style></head><body><div class='container'>"

    # Header
    $html += "<div class='report-title'>Discovery Report -- $domain</div>"
    $html += "<div class='report-meta'><span>$dc</span><span>$dateStr</span><span>Duration: $duration</span></div>"

    # Stats
    $critClass = if ($criticalCount -gt 0) { 'stat w-critical' } else { 'stat w-outline zero' }
    $advClass = if ($advisoryCount -gt 0) { 'stat w-advisory' } else { 'stat w-outline zero' }
    $html += "<div class='stats'>" +
        "<div class='$critClass'><div class='stat-number'>$criticalCount</div><div class='stat-label'>Critical</div></div>" +
        "<div class='$advClass'><div class='stat-number'>$advisoryCount</div><div class='stat-label'>Advisory</div></div>" +
        "<div class='stat w-outline'><div class='stat-number'>$assessedCount/$totalChecks</div><div class='stat-label'>Checks</div></div>" +
        "</div>"

    # Critical findings section
    if ($criticalCount -gt 0) {
        $html += "<div class='critical-section'><div class='section-label critical'>Critical Findings</div>"
        foreach ($c in $criticals) {
            $html += "<div class='card w-critical'><div class='domain-tag'>$($c.DisplayDomain)</div><div class='description'>$($c.Description)</div></div>"
        }
        $html += "</div>"
    }

    Write-Host "report: building domain sections and metrics..." -ForegroundColor DarkGray

    # Domain sections -- domains with findings or not-assessed functions
    $findingDomains = @{}
    foreach ($f in @($criticals) + @($advisories)) {
        if (-not $findingDomains.ContainsKey($f.Domain)) { $findingDomains[$f.Domain] = [System.Collections.Generic.List[PSCustomObject]]::new() }
        $findingDomains[$f.Domain].Add($f)
    }

    # Domains that need a section: have findings OR have not-assessed functions
    $assessedDomains = @($dispositions | Where-Object { $_.Disposition -eq 'Assessed' -and $_.Domain } | ForEach-Object { $_.Domain } | Sort-Object -Unique)

    foreach ($d in $domainOrder) {
        $hasFindings = $findingDomains.ContainsKey($d)
        $hasNotAssessed = $notAssessedDomains.ContainsKey($d)
        if (-not $hasFindings -and -not $hasNotAssessed) { continue }

        $dn = if ($domainNames.ContainsKey($d)) { $domainNames[$d] } else { $d }

        # Check count for section header
        $checkStr = ''
        if ($domainCheckCounts.ContainsKey($d)) {
            $cc = $domainCheckCounts[$d]
            $checkStr = " <span class='check-count'>$($cc.Assessed)/$($cc.Total) checks</span>"
        }
        $html += "<div class='domain-section'><h2>$dn$checkStr</h2><div class='domain-metrics'>"

        # Domain-specific metrics from result data -- collect all results for this domain
        $domainResults = @($resultsList | Where-Object { $_.Domain -eq $d })
        switch ($d) {
            'BackupReadiness' {
                $domainResult = $domainResults | Where-Object { $_.Function -eq 'Get-BackupReadinessStatus' } | Select-Object -First 1
                if ($domainResult) {
                    if ($null -ne $domainResult.TombstoneLifetimeDays) { $html += "<div class='domain-metric'>Tombstone Lifetime: <strong>$($domainResult.TombstoneLifetimeDays) days</strong></div>" }
                    if ($null -ne $domainResult.RecycleBinEnabled) { $html += "<div class='domain-metric'>Recycle Bin: <strong>$(if ($domainResult.RecycleBinEnabled) {'Enabled'} else {'Disabled'})</strong></div>" }
                    if ($null -ne $domainResult.DetectionTier) { $html += "<div class='domain-metric'>Detection Tier: <strong>$($domainResult.DetectionTier) of 3</strong></div>" }
                }
            }
            'PrivilegedAccess' {
                $privGrp = $domainResults | Where-Object { $_.Function -eq 'Get-PrivilegedGroupMembership' } | Select-Object -First 1
                if ($privGrp) {
                    if ($null -ne $privGrp.DomainAdminCount) { $html += "<div class='domain-metric'>Domain Admins: <strong>$($privGrp.DomainAdminCount)</strong></div>" }
                    $eaGrp = if ($privGrp.Groups) { $privGrp.Groups | Where-Object { $_.GroupSID -like '*-519' } } else { $null }
                    if ($eaGrp) { $html += "<div class='domain-metric'>Enterprise Admins: <strong>$($eaGrp.MemberCount)</strong></div>" }
                }
                $kerb = $domainResults | Where-Object { $_.Function -eq 'Find-KerberoastableAccount' } | Select-Object -First 1
                if ($kerb    -and $null -ne $kerb.PrivilegedCount) { $html += "<div class='domain-metric'>Kerberoastable (privileged): <strong>$($kerb.PrivilegedCount)</strong></div>" }
                $orphans = $domainResults | Where-Object { $_.Function -eq 'Find-AdminCountOrphan' } | Select-Object -First 1
                if ($orphans -and $null -ne $orphans.Count)        { $html += "<div class='domain-metric'>AdminCount Orphans: <strong>$($orphans.Count)</strong></div>" }
            }
            'InfrastructureHealth' {
                $siteTopo = $domainResults | Where-Object { $_.Function -eq 'Get-SiteTopology' } | Select-Object -First 1
                if ($siteTopo) {
                    $dcTotal = ($siteTopo.Sites | Measure-Object -Property DCCount -Sum).Sum
                    if ($null -ne $dcTotal) { $html += "<div class='domain-metric'>Domain Controllers: <strong>$dcTotal</strong></div>" }
                    if ($null -ne $siteTopo.SiteCount) { $html += "<div class='domain-metric'>Sites: <strong>$($siteTopo.SiteCount)</strong></div>" }
                }
                $forestLevel = $domainResults | Where-Object { $_.Function -eq 'Get-ForestDomainLevel' } | Select-Object -First 1
                if ($forestLevel -and $null -ne $forestLevel.DomainFunctionalLevel) { $html += "<div class='domain-metric'>Functional Level: <strong>$($forestLevel.DomainFunctionalLevel)</strong></div>" }
                $fsmo = $domainResults | Where-Object { $_.Function -eq 'Get-FSMORolePlacement' } | Select-Object -First 1
                if ($fsmo) {
                    $fsmoStatus = if ($fsmo.UnreachableCount -gt 0) { "$($fsmo.UnreachableCount) unreachable" }
                                  elseif ($fsmo.AllOnOneDC) { 'Single DC' }
                                  else { 'Distributed' }
                    $html += "<div class='domain-metric'>FSMO: <strong>$fsmoStatus</strong></div>"
                }
            }
            'GroupPolicy' {
                $gpo = $domainResults | Where-Object { $_.Function -eq 'Export-GPOAudit' } | Select-Object -First 1
                if ($gpo) {
                    if ($null -ne $gpo.TotalGPOs)    { $html += "<div class='domain-metric'>Total GPOs: <strong>$($gpo.TotalGPOs)</strong></div>" }
                    if ($null -ne $gpo.UnlinkedCount) { $html += "<div class='domain-metric'>Unlinked: <strong>$($gpo.UnlinkedCount)</strong></div>" }
                    if ($gpo.HighRiskCounts) {
                        if ($null -ne $gpo.HighRiskCounts.UserRights) { $html += "<div class='domain-metric'>With User Rights: <strong>$($gpo.HighRiskCounts.UserRights)</strong></div>" }
                        if ($null -ne $gpo.HighRiskCounts.Scripts)    { $html += "<div class='domain-metric'>With Scripts: <strong>$($gpo.HighRiskCounts.Scripts)</strong></div>" }
                    }
                }
            }
            'SecurityPosture' {
                $weakFlag = $domainResults | Where-Object { $_.Function -eq 'Find-WeakAccountFlag' } | Select-Object -First 1
                if ($weakFlag) {
                    $pneCount = if ($weakFlag.CountByFlag -and $weakFlag.CountByFlag.ContainsKey('PasswordNeverExpires')) { $weakFlag.CountByFlag['PasswordNeverExpires'] } else { 0 }
                    $html += "<div class='domain-metric'>Password Never Expires: <strong>$pneCount</strong></div>"
                }
                $puGap = $domainResults | Where-Object { $_.Function -eq 'Test-ProtectedUsersGap' } | Select-Object -First 1
                if ($puGap) { $html += "<div class='domain-metric'>Protected Users Gaps: <strong>$(@($puGap.GapAccounts).Count)</strong></div>" }
                $legacy = $domainResults | Where-Object { $_.Function -eq 'Find-LegacyProtocolExposure' } | Select-Object -First 1
                if ($legacy) {
                    $affectedDCs = @($legacy.DCFindings | Where-Object { $_.Risk -in 'High', 'Medium' } | Group-Object DCName)
                    if ($affectedDCs.Count -gt 0) {
                        $dcList = ($affectedDCs | ForEach-Object { "$($_.Name) ($($_.Count))" }) -join ', '
                        $html += "<div class='domain-metric'>Legacy Exposure: <strong>$dcList</strong></div>"
                    }
                }
            }
            'IdentityLifecycle' {
                $dormant = $domainResults | Where-Object { $_.Function -eq 'Find-DormantAccount' } | Select-Object -First 1
                if ($dormant) {
                    # Defensive property access
                    $accountsCount = if ($dormant.PSObject.Properties['Accounts']) {
                        @($dormant.Accounts).Count
                    } else { 0 }

                    $html += "<div class='domain-metric'>Dormant Accounts: <strong>$accountsCount</strong></div>"

                    if ($dormant.PSObject.Properties['NeverLoggedOnCount'] -and $null -ne $dormant.NeverLoggedOnCount) {
                        $html += "<div class='domain-metric'>Never Logged On: <strong>$($dormant.NeverLoggedOnCount)</strong></div>"
                    }
                    if ($dormant.PSObject.Properties['ThresholdDays'] -and $null -ne $dormant.ThresholdDays) {
                        $html += "<div class='domain-metric'>Threshold: <strong>$($dormant.ThresholdDays) days</strong></div>"
                    }
                    if ($dormant.PSObject.Properties['ExcludedCount'] -and $null -ne $dormant.ExcludedCount) {
                        $html += "<div class='domain-metric'>Excluded: <strong>$($dormant.ExcludedCount) (service/built-in)</strong></div>"
                    }
                }
            }
        }
        $html += "</div>"

        # Advisory cards for this domain
        $domainAdvisories = @($advisories | Where-Object { $_.Domain -eq $d })
        foreach ($a in $domainAdvisories) {
            $html += "<div class='card w-advisory'><div class='adv-label'>Advisory</div><div class='description'>$($a.Description)</div></div>"
        }

        # Not-assessed cards for this domain
        if ($hasNotAssessed) {
            foreach ($na in $notAssessedDomains[$d]) {
                $html += "<div class='card w-neutral not-assessed'><div class='adv-label'>Not Assessed</div><div class='fn-name'>$($na.Function)</div><div class='fn-error'>$($na.Error)</div></div>"
            }
        }
        $html += "</div>"
    }

    # Clean domains: assessed, no findings, no not-assessed functions
    $cleanDomains = @($assessedDomains | Where-Object {
        -not $findingDomains.ContainsKey($_) -and -not $notAssessedDomains.ContainsKey($_)
    })
    if ($cleanDomains.Count -gt 0) {
        $cleanNames = ($cleanDomains | ForEach-Object { if ($domainNames.ContainsKey($_)) { $domainNames[$_] } else { $_ } }) -join ', '
        $html += "<div class='clean-domains'>No findings: $cleanNames</div>"
    }

    # Domain-less not-assessed fallback (backward compat -- failures without domain info)
    if ($domainlessNotAssessed.Count -gt 0) {
        $html += "<div class='failures-section'><div class='section-label neutral'>Not Assessed</div>"
        foreach ($na in $domainlessNotAssessed) {
            $html += "<div class='card w-neutral not-assessed'><div class='fn-name'>$($na.Function)</div><div class='fn-error'>$($na.Error)</div></div>"
        }
        $html += "</div>"
    }

    # --- File tree: scan disk, not claims ---
    Write-Host "report: scanning output files and building tree..." -ForegroundColor DarkGray
    # 1. Clean up empties under $OutputPath
    Get-ChildItem -LiteralPath $OutputPath -File -Recurse |
        Where-Object { $_.Length -eq 0 } |
        Remove-Item -Force
    # Leaf-first empty directory removal (repeat until stable)
    do {
        $emptyDirs = @(Get-ChildItem -LiteralPath $OutputPath -Directory -Recurse |
            Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0 })
        $emptyDirs | Remove-Item -Force
    } while ($emptyDirs.Count -gt 0)

    # 2. Scan remaining files as relative paths, exclude the report itself
    $reportName = '00-Discovery-Report.html'
    $baseFull = (Get-Item -LiteralPath $OutputPath).FullName.TrimEnd('\', '/')
    $verifiedPaths = @(Get-ChildItem -LiteralPath $OutputPath -File -Recurse |
        Where-Object { $_.Name -ne $reportName } |
        ForEach-Object { $_.FullName.Substring($baseFull.Length + 1) -replace '\\','/' })

    # 4. Render file tree -- sorted paths, depth-based indent, each folder name once
    if ($verifiedPaths.Count -gt 0) {
        $html += "<div class='output-section'><div class='section-label neutral'>Output Files</div><div class='file-tree'>"
        $lastSegments = @()
        foreach ($rel in ($verifiedPaths | Sort-Object)) {
            $parts = $rel -split '/'
            $fileName = $parts[-1]
            $folders = @($parts[0..($parts.Count - 2)])
            for ($i = 0; $i -lt $folders.Count; $i++) {
                if ($i -ge $lastSegments.Count -or $folders[$i] -ne $lastSegments[$i]) {
                    $indent = $i * 24
                    $href = ($folders[0..$i] -join '/') + '/'
                    $html += "<div style='padding-left:${indent}px'><a href='$href' class='folder'>$($folders[$i])/</a></div>"
                }
            }
            $lastSegments = $folders
            $fileIndent = $folders.Count * 24
            $html += "<div class='tree-item' style='padding-left:${fileIndent}px'><a href='$rel'>$fileName</a></div>"
        }
        $html += "</div></div>"
    }

    # Footer
    $html += "<div class='report-footer'><span>monarch-kit</span><span>Generated $((Get-Date).ToString('MMMM d, yyyy HH:mm'))</span></div>"
    $html += "</div></body></html>"

    Write-Host "report: assembling and writing HTML report..." -ForegroundColor DarkGray
    $html | Out-File -FilePath $reportFile -Encoding UTF8
    Write-Host "report OK: generated $(Split-Path $reportFile -Leaf) with $criticalCount critical, $advisoryCount advisory" -ForegroundColor Green

    return $reportFile
}

#endregion Reporting

#region Orchestrator
# Invoke-DomainAudit coordinates which functions run per phase.
# Start-MonarchAudit (interactive wrapper) is Plan 3.

function Invoke-DomainAudit
{
    <#
    .SYNOPSIS
        Orchestrates an audit phase by calling the appropriate API functions in sequence.
    .PARAMETER Phase
        Which audit phase to run.
    .PARAMETER Domain
        Domain FQDN. If omitted, uses the current domain.
    .PARAMETER OutputPath
        Root output directory. Defaults to Monarch-Audit-yyyyMMdd.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Discovery','Review','Remediation','Monitoring','Cleanup')]
        [string]$Phase,
        [string]$Domain,
        [string]$OutputPath
    )

    # If hashes fail, call preflight and bail
    $currentHash = (Get-FileHash "$PSScriptRoot\Monarch.psm1" -Algorithm MD5).Hash
    if ($currentHash -ne $script:_moduleHash) {
        Write-Host 'preflight: module source changed on disk, reloading...' -ForegroundColor DarkGray
        Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File ""$PSScriptRoot\preflight-win.ps1"" -AndMonarch -OutputPath ""$OutputPath"""
        exit
    }

    if ($Phase -ne 'Discovery') { throw "Phase '$Phase' is not yet implemented." }

    # Resolve DC -- fatal if fails
    $target = Resolve-MonarchDC -Domain $Domain
    $dc = $target.DCName[0]
    $startTime = Get-Date

    # Output directory structure
    if (-not $OutputPath) { $OutputPath = "Monarch-Audit-$(Get-Date -Format yyyyMMdd)" }
    if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $dirs = @{
        Baseline = Join-Path $OutputPath '01-Baseline'
        GPO      = Join-Path $OutputPath '02-GPO-Audit'
        Priv     = Join-Path $OutputPath '03-Privileged-Access'
        Dormant  = Join-Path $OutputPath '04-Dormant-Accounts'
    }
    foreach ($d in $dirs.Values) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

    # Discovery function sequence -- Domain key maps each function to its functional domain
    $calls = @(
        @{ Name = 'New-DomainBaseline';            Domain = 'AuditCompliance';      Params = @{ Server = $dc; OutputPath = $dirs.Baseline } }
        @{ Name = 'Get-FSMORolePlacement';         Domain = 'InfrastructureHealth'; Params = @{ Server = $dc } }
        @{ Name = 'Get-ReplicationHealth';         Domain = 'InfrastructureHealth'; Params = @{ Server = $dc } }
        @{ Name = 'Get-SiteTopology';              Domain = 'InfrastructureHealth'; Params = @{ Server = $dc } }
        @{ Name = 'Get-ForestDomainLevel';         Domain = 'InfrastructureHealth'; Params = @{ Server = $dc } }
        @{ Name = 'Export-GPOAudit';               Domain = 'GroupPolicy';          Params = @{ Server = $dc; OutputPath = $dirs.GPO; IncludePermissions = $true; IncludeWMIFilters = $true } }
        @{ Name = 'Find-UnlinkedGPO';              Domain = 'GroupPolicy';          Params = @{ Server = $dc } }
        @{ Name = 'Find-GPOPermissionAnomaly';     Domain = 'GroupPolicy';          Params = @{ Server = $dc } }
        @{ Name = 'Get-PrivilegedGroupMembership'; Domain = 'PrivilegedAccess';     Params = @{ Server = $dc } }
        @{ Name = 'Find-AdminCountOrphan';         Domain = 'PrivilegedAccess';     Params = @{ Server = $dc } }
        @{ Name = 'Find-KerberoastableAccount';    Domain = 'PrivilegedAccess';     Params = @{ Server = $dc } }
        @{ Name = 'Find-ASREPRoastableAccount';    Domain = 'PrivilegedAccess';     Params = @{ Server = $dc } }
        @{ Name = 'Find-DormantAccount';           Domain = 'IdentityLifecycle';    Params = @{ Server = $dc; OutputPath = $dirs.Dormant } }
        @{ Name = 'Get-PasswordPolicyInventory';   Domain = 'SecurityPosture';      Params = @{ Server = $dc } }
        @{ Name = 'Find-WeakAccountFlag';          Domain = 'SecurityPosture';      Params = @{ Server = $dc } }
        @{ Name = 'Test-ProtectedUsersGap';        Domain = 'SecurityPosture';      Params = @{ Server = $dc } }
        @{ Name = 'Find-LegacyProtocolExposure';   Domain = 'SecurityPosture';      Params = @{ Server = $dc } }
        @{ Name = 'Get-BackupReadinessStatus';     Domain = 'BackupReadiness';      Params = @{ Server = $dc } }
        @{ Name = 'Test-TombstoneGap';             Domain = 'BackupReadiness';      Params = @{ Server = $dc } }
        @{ Name = 'Get-AuditPolicyConfiguration';  Domain = 'AuditCompliance';      Params = @{ Server = $dc } }
        @{ Name = 'Get-EventLogConfiguration';     Domain = 'AuditCompliance';      Params = @{ Server = $dc } }
        @{ Name = 'Test-SRVRecordCompleteness';    Domain = 'DNS';                  Params = @{ Server = $dc } }
        @{ Name = 'Get-DNSScavengingConfiguration'; Domain = 'DNS';                 Params = @{ Server = $dc } }
        @{ Name = 'Test-ZoneReplicationScope';     Domain = 'DNS';                  Params = @{ Server = $dc } }
        @{ Name = 'Get-DNSForwarderConfiguration'; Domain = 'DNS';                  Params = @{ Server = $dc } }
    )

    # Execute with per-function error isolation and disposition tracking
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failures = [System.Collections.Generic.List[PSCustomObject]]::new()
    $dispositions = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($call in $calls) {
        try {
            $params = $call.Params
            $results.Add((& $call.Name @params))
            $dispositions.Add([PSCustomObject]@{ Function = $call.Name; Domain = $call.Domain; Disposition = 'Assessed'; Error = $null })
        } catch {
            $failures.Add([PSCustomObject]@{ Function = $call.Name; Error = $_.Exception.Message })
            $dispositions.Add([PSCustomObject]@{ Function = $call.Name; Domain = $call.Domain; Disposition = 'NotAssessed'; Error = $_.Exception.Message })
        }
    }

    # Generate report and return
    $orchestratorResult = [PSCustomObject]@{
        Phase        = 'Discovery'
        Domain       = $target.Domain
        DCUsed       = $dc
        DCSource     = $target.Source
        StartTime    = $startTime
        EndTime      = Get-Date
        OutputPath   = $OutputPath
        ReportPath   = $null
        Results      = @($results)
        Failures     = @($failures)
        Dispositions = @($dispositions)
        TotalChecks  = $calls.Count
    }
    $orchestratorResult.ReportPath = New-MonarchReport -Results $orchestratorResult -OutputPath $OutputPath
    return $orchestratorResult
}

#endregion Orchestrator

# ============================================================================
# Module Initialization
# ============================================================================

$script:_moduleHash = (Get-FileHash "$PSScriptRoot\Monarch.psm1" -Algorithm MD5).Hash
Import-MonarchConfig
